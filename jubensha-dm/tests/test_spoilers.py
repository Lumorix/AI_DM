import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import yaml
from jubensha import prompts
from jubensha.engine import Game
from jubensha.llm import LLM, LLMError
from jubensha.script import Phase, ScriptError, load_script
from jubensha.state import GameState


class StreamLLM:
    def __init__(self, pieces, fail=False):
        self.pieces = pieces
        self.fail = fail

    async def stream(self, *args, **kwargs):
        for piece in self.pieces:
            yield piece
        if self.fail:
            raise LLMError('failure containing secret')


class SpoilerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.script = load_script(Path(__file__).resolve().parents[1] / 'scripts/demo')
        self.script.phases = [Phase('intro', '开场', 'narration'),
                              Phase('early', '第一次揭晓', 'reveal'),
                              Phase('later', '后续讨论', 'discuss'),
                              Phase('final', '最终揭晓', 'reveal')]
        self.script.forbidden = ['真凶是甲@final']
        self.game = Game(self.script, GameState(script_title=self.script.title),
                         LLM({'provider': 'mock'}), {}, Path(self.temp.name) / 'save.json')
        self.game.maybe_summarize = AsyncMock()
        self.sub = self.game.bus.subscribe('screen')

    def events(self):
        result = []
        while not self.sub.queue.empty():
            result.append(self.sub.queue.get_nowait())
        return result

    def assert_no_secret(self, events):
        visible = json.dumps(events, ensure_ascii=False)
        visible += ''.join(e.text for e in self.game.state.public_log)
        self.assertNotIn('真凶是甲', visible)

    async def test_split_keyword_never_reaches_public_events(self):
        self.game.llm = StreamLLM(['真凶', '是甲'])
        result = await self.game._stream_public([{}], '请阅读第一幕。')
        self.assertEqual(result, '请阅读第一幕。')
        self.assert_no_secret(self.events())
        self.assertTrue(self.game.state.warnings)

    async def test_unsafe_generated_and_fallback_text_are_both_blocked(self):
        self.game.llm = StreamLLM(['真凶是甲'])
        self.assertEqual(await self.game._stream_public([{}], '真凶是甲'), '')
        self.assert_no_secret(self.events())
        self.assertEqual(self.game.state.public_log, [])

    async def test_verbatim_and_paused_paths_are_checked(self):
        for messages, paused in [(None, False), ([{}], True)]:
            self.game.state.ai_paused = paused
            self.assertEqual(await self.game._stream_public(messages, '真凶是甲'), '')
            self.assert_no_secret(self.events())

    async def test_stream_error_discards_partial_output_and_checks_fallback(self):
        self.game.llm = StreamLLM(['真凶是甲'], fail=True)
        self.assertEqual(await self.game._stream_public([{}], '安全原文'), '安全原文')
        self.assert_no_secret(self.events())

    async def test_stream_error_cannot_bypass_unsafe_fallback(self):
        self.game.llm = StreamLLM(['部分内容'], fail=True)
        self.assertEqual(await self.game._stream_public([{}], '真凶是甲'), '')
        self.assert_no_secret(self.events())

    async def test_buffered_output_is_not_visible_before_completion_or_after_cancel(self):
        started, finish = asyncio.Event(), asyncio.Event()
        class Slow:
            async def stream(self, *args, **kwargs):
                yield '真凶'
                started.set()
                await finish.wait()
                yield '是甲'
        self.game.llm = Slow()
        task = asyncio.create_task(self.game._stream_public([{}], '安全'))
        await started.wait()
        self.assertFalse(any(e['type'] == 'stream_delta' for e in self.events()))
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assert_no_secret(self.events())
        self.assertEqual(self.game.state.public_log, [])

    async def test_stale_phase_output_is_discarded_even_without_task_cancellation(self):
        game = self.game
        class Changing:
            async def stream(self, *args, **kwargs):
                yield '旧内容'
                game.state.phase_started_at += 1
        game.llm = Changing()
        self.assertEqual(await game._stream_public([{}], '安全'), '')
        self.assertFalse(any(e['type'] == 'stream_delta' for e in self.events()))
        self.assertEqual(game.state.public_log, [])

    async def test_safe_text_is_published_once(self):
        self.game.llm = StreamLLM(['请阅读', '第一幕。'])
        self.assertEqual(await self.game._stream_public([{}], '原文'), '请阅读第一幕。')
        deltas = [e['text'] for e in self.events() if e['type'] == 'stream_delta']
        self.assertEqual(deltas, ['请阅读第一幕。'])
        self.assertEqual(len(self.game.state.public_log), 1)

    async def test_final_reveal_releases_only_due_rules(self):
        self.game.llm = StreamLLM(['真凶是甲'])
        self.game.state.phase_index = 1
        self.assertEqual(await self.game._stream_public([{}], '真凶是甲', 'reveal'), '')
        self.game.state.phase_index = 3
        self.assertEqual(await self.game._stream_public([{}], '真凶是甲', 'reveal'), '真凶是甲')

    def test_explicit_rule_locks_before_and_unlocks_at_target(self):
        for i in range(3):
            self.assertEqual(self.script.first_forbidden('真凶， 是甲', i), '真凶是甲')
        self.assertIsNone(self.script.first_forbidden('真凶是甲', 3))
        self.assertIsNotNone(self.script.first_forbidden('真凶是甲', 0))

    def test_default_unlock_persists_after_first_reveal(self):
        self.script.forbidden = ['真凶是甲']
        self.assertIsNotNone(self.script.first_forbidden('真凶是甲', 0))
        for i in [1, 2, 3]:
            self.assertIsNone(self.script.first_forbidden('真凶是甲', i))

    def test_global_target_overrides_first_reveal(self):
        self.script.forbidden = ['真凶是甲']
        self.script.forbidden_until = 'final'
        self.assertIsNotNone(self.script.first_forbidden('真凶是甲', 1))
        self.assertIsNone(self.script.first_forbidden('真凶是甲', 3))

    def test_no_reveal_or_unknown_target_stays_locked(self):
        self.script.forbidden = ['真凶是甲']
        self.script.phases = [Phase('intro', '开场', 'narration')]
        self.assertIsNotNone(self.script.first_forbidden('真凶是甲', 0))
        self.script.forbidden_until = 'missing'
        self.assertIsNotNone(self.script.first_forbidden('真凶是甲', 0))
        self.script.forbidden = ['真凶是甲@missing']
        self.assertIsNotNone(self.script.first_forbidden('真凶是甲', 0))

    async def test_public_question_excludes_personal_secret_private_keeps_it(self):
        char = self.script.characters[0]
        char.secret_brief = 'PERSONAL_SECRET_SENTINEL'
        await self.game.join(char.id, '测试')
        args = (self.script, self.game.state, self.game.phase, char.id, '问题')
        public = json.dumps(prompts.ask_messages(*args, True, 30, 12), ensure_ascii=False)
        private = json.dumps(prompts.ask_messages(*args, False, 30, 12), ensure_ascii=False)
        self.assertNotIn(char.secret_brief, public)
        self.assertIn(char.secret_brief, private)

    def test_narration_excludes_truth_and_dm_notes(self):
        self.script.truth = 'TRUTH_SENTINEL'
        self.game.phase.dm_notes = 'HOST_SECRET_SENTINEL'
        messages = prompts.narration_messages(self.script, self.game.state, self.game.phase, '公开原文')
        serialized = json.dumps(messages, ensure_ascii=False)
        self.assertNotIn(self.script.truth, serialized)
        self.assertNotIn(self.game.phase.dm_notes, serialized)
        self.assertIn('公开原文', serialized)

    def test_yaml_loads_global_target_and_rejects_invalid_rule(self):
        source = Path(__file__).resolve().parents[1] / 'scripts/demo/script.yaml'
        data = yaml.safe_load(source.read_text(encoding='utf-8'))
        target = data['phases'][-1]['id']
        data['dm']['forbidden_until'] = target
        data['dm']['forbidden'] = ['真凶是甲@' + target]
        path = Path(self.temp.name) / 'script.yaml'
        path.write_text(yaml.safe_dump(data, allow_unicode=True), encoding='utf-8')
        self.assertEqual(load_script(path).forbidden_until, target)
        data['dm']['forbidden'] = ['真凶是甲@missing']
        path.write_text(yaml.safe_dump(data, allow_unicode=True), encoding='utf-8')
        with self.assertRaises(ScriptError):
            load_script(path)

    def test_new_game_opening_is_checked_before_initial_save(self):
        import run
        self.script.phases[0].dm_script = '真凶是甲'
        self.script.folder = Path('fixture')
        with patch.object(run, 'ROOT', Path(self.temp.name)), \
             patch.object(run, 'load_config', return_value={'llm': {'provider': 'mock'}}), \
             patch.object(run, 'load_script', return_value=self.script), \
             patch.object(run, 'lan_ip', return_value='127.0.0.1'), \
             patch('sys.argv', ['run.py']), patch('uvicorn.run'), patch('builtins.print'):
            run.main()
        saved = GameState.load(Path(self.temp.name) / 'saves/fixture.json')
        self.assertFalse(any('真凶是甲' in entry.text for entry in saved.public_log))
        self.assertTrue(saved.warnings)


if __name__ == '__main__':
    unittest.main()
