import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock
from starlette.requests import Request
from jubensha.engine import Game
from jubensha.llm import LLM
from jubensha.script import load_script
from jubensha.state import GameState
from jubensha.server import create_app


class SlowLLM:
    def __init__(self):
        self.started=asyncio.Event()
        self.finish=asyncio.Event()
        self.calls=0

    async def chat(self,*args,**kwargs):
        self.calls+=1
        self.started.set()
        await self.finish.wait()
        return json.dumps({'reply':'这是旧阶段的回答'})

    async def stream(self,*args,**kwargs):
        yield '旧阶段开头'
        self.started.set()
        await self.finish.wait()
        yield '旧阶段结尾'


class GameFlowTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        script=load_script(Path(__file__).resolve().parents[1]/'scripts/demo')
        self.game=Game(script,GameState(script_title=script.title),LLM({'provider':'mock'}),{},Path(self.temp.name)/'save.json')
        self.game.maybe_summarize=AsyncMock()

    async def test_complete_game_and_save_restore(self):
        g=self.game
        players=[await g.join(c.id,c.name) for c in g.script.characters]
        with self.assertRaises(ValueError):
            await g.join(players[0].char_id,'duplicate')
        self.assertFalse((await g.search(players[0].char_id,'invalid'))['ok'])
        search=next(i for i,p in enumerate(g.script.phases) if p.type=='search')
        await g.goto(search,narrate=False)
        p=players[0];loc=g.phase.locations[0]
        before=p.search_left
        result=await g.search(p.char_id,loc.id)
        self.assertTrue(result['ok'])
        self.assertEqual(p.search_left,before-1)
        self.assertFalse((await g.publish_clue(players[1].char_id,result['clue']))['ok'])
        if result['clue'] not in g.state.public_clues:
            self.assertTrue((await g.publish_clue(p.char_id,result['clue']))['ok'])
        old_token=p.token;clues=list(p.clues);left=p.search_left
        await g.release(p.char_id)
        replacement=await g.join(p.char_id,'replacement')
        self.assertNotEqual(old_token,replacement.token)
        self.assertIsNone(g.state.player_by_token(old_token))
        self.assertEqual(replacement.clues,clues)
        self.assertEqual(replacement.search_left,left)
        restored=GameState.load(g.save_path)
        self.assertEqual(restored.players[p.char_id].clues,clues)
        vote=next(i for i,ph in enumerate(g.script.phases) if ph.type=='vote')
        await g.goto(vote,narrate=False)
        for player in players:
            self.assertTrue((await g.vote(player.char_id,players[0].char_id))['ok'])
        self.assertTrue(g.state.votes_revealed)
        self.assertFalse((await g.vote(p.char_id,players[0].char_id))['ok'])

    async def test_no_narration_transition_cancels_old_stream(self):
        g=self.game;g.llm=SlowLLM();origin=g.phase.id
        g._narr_task=asyncio.create_task(g._stream_public([{}],'fallback'))
        await g.llm.started.wait()
        task=g._narr_task
        await g.goto(1,narrate=False)
        with self.assertRaises(asyncio.CancelledError):
            await task
        entries=[e for e in g.state.public_log if e.kind=='narration']
        self.assertEqual(entries[-1].phase,origin)
        self.assertNotIn('旧阶段结尾',entries[-1].text)

    async def _pending_question(self):
        g=self.game;p=await g.join(g.script.characters[0].id,'test')
        g.llm=SlowLLM()
        task=asyncio.create_task(g.ask(p.char_id,'你知道什么？',False))
        await g.llm.started.wait()
        return p,task

    async def test_late_answer_after_phase_change_is_discarded(self):
        p,task=await self._pending_question();g=self.game
        await g.goto(1,narrate=False);g.llm.finish.set()
        self.assertFalse((await task)['ok'])
        self.assertFalse(any(e.kind=='answer' for e in g.state.private_log[p.char_id]))
        self.assertNotIn(p.char_id,g.busy)

    async def test_late_answer_after_device_replacement_is_discarded(self):
        p,task=await self._pending_question();g=self.game
        await g.release(p.char_id);await g.join(p.char_id,'new device');g.llm.finish.set()
        self.assertFalse((await task)['ok'])
        self.assertFalse(any(e.kind=='answer' for e in g.state.private_log[p.char_id]))

    async def test_concurrent_question_reserves_busy_under_lock(self):
        g=self.game;p=await g.join(g.script.characters[0].id,'test');g.llm=SlowLLM()
        await g.lock.acquire()
        first=asyncio.create_task(g.ask(p.char_id,'one',False))
        second=asyncio.create_task(g.ask(p.char_id,'two',False))
        await asyncio.sleep(0);g.lock.release()
        await g.llm.started.wait();g.llm.finish.set()
        results=await asyncio.gather(first,second)
        self.assertEqual(sum(r['ok'] for r in results),1)
        self.assertEqual(g.llm.calls,1)

    async def test_invalid_admin_phase_is_400(self):
        g=self.game;app=create_app(g)
        endpoint=next(r.endpoint for r in app.routes if r.path=='/api/admin/{action}')
        for index in (None,True,'bad',{},-1,999):
            async def receive():
                return {'type':'http.request','body':json.dumps({'admin':g.state.admin_token,'index':index}).encode()}
            req=Request({'type':'http','method':'POST','path':'/api/admin/goto','path_params':{'action':'goto'},
                         'headers':[],'query_string':b''},receive)
            self.assertEqual((await endpoint(req)).status_code,400)
