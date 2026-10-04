import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

import run
from jubensha import prompts
from jubensha.script import load_script
from jubensha.state import GameState, Player
from tools import ocr


class MemoryReviewTests(unittest.TestCase):
    def test_pending_public_events_are_not_lost_between_summary_and_recent_window(self):
        state = GameState(script_title='test')
        state.summary = '已压缩的事实'
        for i in range(60):
            state.log_public('note', '玩家', f'事件{i:03d}')
        state.summarized_upto = 10
        context = prompts.memory_block(state, recent=30)
        self.assertNotIn('事件009', context)
        self.assertIn('事件010', context)
        self.assertIn('事件059', context)
        self.assertIn('已压缩的事实', context)

    def test_private_backlog_is_included_only_for_owner_private_question(self):
        script = load_script(Path(__file__).resolve().parents[1] / 'scripts/demo')
        state = GameState(script_title=script.title)
        cid = script.characters[0].id
        state.players[cid] = Player(cid, '测试', 'token')
        for i in range(30):
            state.log_private(cid, 'ask', '玩家', f'私事{i:03d}')
        state.private_summarized_upto[cid] = 5
        args = (script, state, script.phases[0], cid, '问题')
        private = json.dumps(prompts.ask_messages(*args, False, 30, 12), ensure_ascii=False)
        public = json.dumps(prompts.ask_messages(*args, True, 30, 12), ensure_ascii=False)
        self.assertIn('私事005', private)
        self.assertNotIn('私事004', private)
        self.assertNotIn('私事005', public)


class StartupReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = load_script(Path(__file__).resolve().parents[1] / 'scripts/demo')

    def test_invalid_config_shapes_and_memory_are_rejected(self):
        for config in [[], {'llm': []}, {'llm': {'cheap': 'bad'}}, {'game': {'memory': 'bad'}},
                       {'game': {'memory': {'keep_recent': 0}}}, {'game': {'memory': {'private_keep': -1}}},
                       {'game': {'memory': {'summarize_batch': True}}}]:
            with self.subTest(config=config), self.assertRaises(ValueError):
                run.validate_config(config)

    def test_invalid_port_does_not_create_or_modify_save(self):
        cfg = self.root / 'config.yaml'; cfg.write_text('llm:\n  provider: mock\n', encoding='utf-8')
        for port in ['0', '65536', '-1']:
            with patch.object(run, 'ROOT', self.root), patch('sys.argv', ['run.py', '--port', port]), \
                 patch('builtins.print'), patch('uvicorn.run') as server:
                with self.assertRaises(SystemExit):
                    run.main()
                server.assert_not_called()
            self.assertFalse((self.root / 'saves').exists())

    def test_corrupt_save_is_preserved_and_server_not_started(self):
        path = self.root / 'saves' / f'{self.script.folder.name}.json'
        path.parent.mkdir()
        for broken in [b'{bad json', b'[]', b'{"players":[]}']:
            path.write_bytes(broken)
            with patch.object(run, 'ROOT', self.root), \
                 patch.object(run, 'load_config', return_value={'llm': {'provider': 'mock'}}), \
                 patch.object(run, 'load_script', return_value=self.script), \
                 patch('sys.argv', ['run.py']), patch('builtins.print'), patch('uvicorn.run') as server:
                with self.assertRaises(SystemExit):
                    run.main()
                server.assert_not_called()
            self.assertEqual(path.read_bytes(), broken)

    def test_save_script_and_cursor_mismatch_rejected(self):
        state = GameState(script_title=self.script.title)
        run.validate_saved_state(state, self.script)
        for field, value in [('phase_index', -1), ('phase_index', 999), ('script_title', 'other'), ('summarized_upto', 10)]:
            state = GameState(script_title=self.script.title)
            setattr(state, field, value)
            with self.assertRaises(ValueError):
                run.validate_saved_state(state, self.script)

    def test_save_missing_character_rejected(self):
        state = GameState(script_title=self.script.title)
        state.players['missing'] = Player('missing', 'test', 'token')
        with self.assertRaises(ValueError):
            run.validate_saved_state(state, self.script)

    def test_offline_lan_detection_falls_back_to_loopback(self):
        with patch('run.socket.socket', side_effect=OSError), patch('run.socket.gethostbyname', side_effect=OSError):
            self.assertEqual(run.lan_ip(), '127.0.0.1')


class OCRReviewTests(unittest.TestCase):
    def test_local_cli_reads_cache_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source.png'; source.write_bytes(b'input')
            config = Path(tmp) / 'config.yaml'; config.write_text('ocr_cache_revision: changed-model\n', encoding='utf-8')
            with patch('sys.argv', ['ocr.py', str(source), '--config', str(config)]), \
                 patch.object(ocr, 'run', new_callable=AsyncMock) as work:
                ocr.main()
                self.assertEqual(work.call_args.args[-1]['ocr_cache_revision'], 'changed-model')

    def test_tesseract_closes_tempfile_and_cleans_up_after_failure(self):
        with patch('shutil.which', return_value='tesseract'):
            engine = ocr.TesseractEngine('chi_sim')
        paths = []
        def save(path):
            paths.append(Path(path))
            Path(path).write_bytes(b'png')
        image = Mock(); image.save.side_effect = save
        for outcome in [Mock(returncode=0, stdout='测 试', stderr=''), Mock(returncode=1, stdout='', stderr='failure'), OSError('failure')]:
            kwargs = {'side_effect': outcome} if isinstance(outcome, Exception) else {'return_value': outcome}
            with patch('subprocess.run', **kwargs):
                if isinstance(outcome, Exception) or outcome.returncode:
                    with self.assertRaises((RuntimeError, OSError)):
                        engine.recognize(image)
                else:
                    self.assertEqual(engine.recognize(image), '测试')
            self.assertFalse(paths[-1].exists())


if __name__ == '__main__':
    unittest.main()
