import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from jubensha.engine import Game
from jubensha.llm import LLM, LLMError
from jubensha.script import load_script
from jubensha.state import GameState
from jubensha.stability import estimate_context, validated_summary
from tools.ocr_identity import cache_identity, read_page, write_atomic


class BudgetTests(unittest.IsolatedAsyncioTestCase):
    def model(self, **extra):
        return LLM({'provider': 'openai', 'base_url': 'https://invalid.test/v1',
                    'model': 'test', 'context_budget': 2048, **extra})

    async def test_oversized_chat_is_rejected_before_network(self):
        with patch('jubensha.llm.requests.post') as post:
            with self.assertRaises(LLMError):
                await self.model().chat([{'role': 'user', 'content': '中' * 1000}], max_tokens=100)
            post.assert_not_called()

    async def test_oversized_stream_is_rejected_before_worker(self):
        with patch('jubensha.llm.threading.Thread') as worker:
            with self.assertRaises(LLMError):
                async for _ in self.model().stream([{'role': 'user', 'content': 'x' * 5000}]):
                    self.fail('must not emit')
            worker.assert_not_called()

    def test_output_reservation_and_unicode_are_counted(self):
        messages = [{'role': 'user', 'content': '中🙂'}]
        cost = estimate_context(messages, 500)
        self.assertEqual(cost, 512 + 500 + 16 + 4 + 7)
        with self.assertRaises(LLMError):
            self.model()._payload(messages, False, 3000)

    def test_safe_request_preserves_all_text(self):
        messages = [{'role': 'system', 'content': '必须保留的规则'}, {'role': 'user', 'content': '问题'}]
        payload = self.model()._payload(messages, False, 100)
        self.assertEqual(payload['messages'], messages)

    def test_extra_body_cannot_bypass_guard(self):
        for key in ['messages', 'max_tokens', 'max_completion_tokens', 'model', 'stream']:
            with self.assertRaises(LLMError):
                self.model(extra_body={key: 'override'})
        with self.assertRaises(LLMError):
            self.model(extra_body={'tool_schema': 'x' * 3000})._payload([], False, 10)

    async def test_mock_obeys_budget(self):
        with self.assertRaises(LLMError):
            await LLM({'provider': 'mock', 'context_budget': 1024}).chat([{'role': 'user', 'content': 'x'}])

    def test_image_base64_is_not_mistaken_for_text_tokens(self):
        msg = [{'role': 'user', 'content': [{'type': 'text', 'text': 'OCR'},
                {'type': 'image_url', 'image_url': {'url': 'data:' + 'x' * 100000}}]}]
        self.assertLess(estimate_context(msg, 100), 5000)


class SummaryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        script = load_script(Path(__file__).resolve().parents[1] / 'scripts/demo')
        self.game = Game(script, GameState(script_title=script.title), LLM({'provider': 'mock'}),
                         {'game': {'memory': {'keep_recent': 1, 'private_keep': 1, 'summarize_batch': 2}}},
                         Path(self.temp.name) / 'save.json')

    async def test_overlong_summary_retries_without_truncating(self):
        model = AsyncMock()
        model.chat.side_effect = ['字' * 601, '有效摘要']
        self.assertEqual(await validated_summary(model, [{'role': 'user', 'content': '原始记录'}]), '有效摘要')
        self.assertEqual(model.chat.await_count, 2)

    async def test_invalid_public_summary_keeps_cursor_and_history(self):
        g = self.game
        g.state.summary = '旧摘要'
        for i in range(5):
            g.state.log_public('note', '玩家', str(i))
        g.cheap = AsyncMock()
        g.cheap.chat.side_effect = ['字' * 601, '']
        await g.maybe_summarize(force=True)
        self.assertEqual(g.state.summary, '旧摘要')
        self.assertEqual(g.state.summarized_upto, 0)
        self.assertEqual(len(g.state.public_log), 5)
        self.assertTrue(g.state.warnings)

    async def test_valid_summary_advances_only_bounded_batch(self):
        g = self.game
        for i in range(8):
            g.state.log_public('note', '玩家', str(i))
        g.cheap = AsyncMock()
        g.cheap.chat.return_value = '字' * 600
        await g.maybe_summarize(force=True)
        self.assertEqual(len(g.state.summary), 600)
        self.assertEqual(g.state.summarized_upto, 2)
        self.assertEqual(len(g.state.public_log), 8)

    async def test_private_failure_preserves_old_summary(self):
        g = self.game
        cid = g.script.characters[0].id
        g.state.private_summary[cid] = '旧私聊'
        for i in range(4):
            g.state.log_private(cid, 'ask', '玩家', str(i))
        g.cheap = AsyncMock()
        g.cheap.chat.side_effect = ['字' * 601, '字' * 602]
        await g.maybe_summarize(char_id=cid)
        self.assertEqual(g.state.private_summary[cid], '旧私聊')
        self.assertEqual(g.state.private_summarized_upto.get(cid, 0), 0)

    async def test_private_valid_summary_advances(self):
        g = self.game
        cid = g.script.characters[0].id
        for i in range(4):
            g.state.log_private(cid, 'ask', '玩家', str(i))
        g.cheap = AsyncMock()
        g.cheap.chat.return_value = '私聊摘要'
        await g.maybe_summarize(char_id=cid)
        self.assertEqual(g.state.private_summary[cid], '私聊摘要')
        self.assertEqual(g.state.private_summarized_upto[cid], 2)

    def test_player_act_label_and_view_work(self):
        self.assertEqual(self.game.act_label('act1'), '第一幕')


class OCRTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.pdf'
        self.source.write_bytes(b'first-content')

    def key(self, **kwargs):
        args = dict(source=self.source, engine='rapidocr', dpi=220, split=False, lang='chi_sim', cfg={}, prompt='OCR')
        args.update(kwargs)
        return cache_identity(**args)

    def test_content_change_and_same_name_different_file_invalidate(self):
        before = self.key()
        other = self.root / 'other'; other.mkdir()
        same_name = other / self.source.name; same_name.write_bytes(b'other-content')
        self.assertNotEqual(before, self.key(source=same_name))
        self.source.write_bytes(b'changed')
        self.assertNotEqual(before, self.key())

    def test_settings_change_invalidate_and_repeat_reuses(self):
        before = self.key()
        self.assertEqual(before, self.key())
        for change in [dict(dpi=300), dict(split=True), dict(lang='eng'), dict(engine='vision')]:
            self.assertNotEqual(before, self.key(**change))

    def test_vision_model_and_prompt_invalidate_credentials_do_not(self):
        base = {'llm': {'model': 'a', 'api_key': 'secret'}}
        original = self.key(engine='vision', cfg=base)
        self.assertEqual(original, self.key(engine='vision', cfg={'llm': {'model': 'a', 'api_key': 'new'}}))
        self.assertNotEqual(original, self.key(engine='vision', cfg={'llm': {'model': 'b'}}))
        self.assertNotEqual(original, self.key(engine='vision', cfg=base, prompt='new'))

    def test_directory_page_addition_and_rename_invalidate(self):
        pages = self.root / 'pages'; pages.mkdir()
        (pages / '1.png').write_bytes(b'one')
        before = self.key(source=pages)
        (pages / '2.png').write_bytes(b'two')
        self.assertNotEqual(before, self.key(source=pages))
        before = self.key(source=pages)
        (pages / '1.png').rename(pages / '3.png')
        self.assertNotEqual(before, self.key(source=pages))

    def test_invalid_cache_retries_and_atomic_write_leaves_no_temp(self):
        page = self.root / 'p.txt'
        page.write_bytes(b'\xff')
        self.assertIsNone(read_page(page))
        page.write_text('  ', encoding='utf-8')
        self.assertIsNone(read_page(page))
        write_atomic(page, '文字')
        self.assertEqual(read_page(page), '文字')
        self.assertEqual(list(self.root.glob('*.tmp')), [])

    async def test_ocr_resume_skips_completed_pages_and_preserves_legacy_output(self):
        from PIL import Image
        from tools import ocr
        source = self.root / 'page.png'; Image.new('RGB', (30, 30)).save(source)
        out = self.root / 'out'; out.mkdir()
        legacy = out / 'page.txt'; legacy.write_text('人工校对旧结果', encoding='utf-8')
        class Engine:
            calls = 0
            def recognize(self, image):
                self.calls += 1
                return '新识别结果'
        engine = Engine()
        with patch.object(ocr, 'RapidEngine', return_value=engine), patch('builtins.print'):
            first = await ocr.run([source], out, 'rapidocr', 220, False, 'chi_sim', {})
            second = await ocr.run([source], out, 'rapidocr', 220, False, 'chi_sim', {})
            third = await ocr.run([source], out, 'rapidocr', 300, False, 'chi_sim', {})
        self.assertEqual(first, second)
        self.assertNotEqual(first, third)
        self.assertEqual(engine.calls, 2)
        self.assertEqual(legacy.read_text(encoding='utf-8'), '人工校对旧结果')


if __name__ == '__main__':
    unittest.main()
