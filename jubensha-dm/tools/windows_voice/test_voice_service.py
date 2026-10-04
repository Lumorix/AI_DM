import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from voice_service import Config, VoiceService, make_server


class FakeEngine:
    def __init__(self, cfg):
        self.calls = 0

    def synthesize(self, text):
        self.calls += 1
        if text == 'fail':
            raise RuntimeError('test error')
        return b'RIFF-test', {'audio_seconds': 1, 'generation_seconds': 0.1}


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.service = VoiceService(Config(Path('.'), Path('ref.wav'), cache_entries=1))
        self.server = make_server(self.service, port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path='/health', payload=None, origin=None):
        headers = {'Content-Type': 'application/json'}
        if origin:
            headers['Origin'] = origin
        req = urllib.request.Request(self.url+path,
            data=None if payload is None else json.dumps(payload).encode(), headers=headers)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            return response.status, response.read(), response.headers

    def test_loading_ready_and_failed_health(self):
        self.assertEqual(self.request()[0], 503)
        self.assertEqual(self.request('/v1/audio/speech', {'text':'你好'})[0], 503)
        self.service.load(FakeEngine)
        status, body, _ = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['status'], 'ready')
        def broken(cfg):
            raise RuntimeError('missing model')
        self.service.load(broken)
        self.assertEqual(json.loads(self.request()[1])['error'], 'model_load_failed')

    def test_validation_and_origin(self):
        for value in ([], {'text':''}, {'text':3}, {'text':'x'*121}):
            self.assertEqual(self.request('/v1/audio/speech', value)[0], 400)
        self.assertEqual(self.request('/v1/audio/speech', {'text':'hello'}, 'https://example.com')[0],403)
        self.assertEqual(self.request('/missing')[0],404)

    def test_cache_eviction_and_compatibility_alias(self):
        self.service.load(FakeEngine)
        self.assertEqual(self.request('/v1/audio/speech', {'text':'one'})[2]['X-Cache'], 'miss')
        self.assertEqual(self.request('/synthesize', {'text':'one'})[2]['X-Cache'], 'hit')
        self.request('/v1/audio/speech', {'text':'two'})
        self.request('/v1/audio/speech', {'text':'one'})
        self.assertEqual(self.service.engine.calls, 3)

    def test_busy_and_failure_release_lock(self):
        self.service.load(FakeEngine)
        self.service.lock.acquire()
        try:
            self.assertEqual(self.request('/v1/audio/speech', {'text':'one'})[0],429)
        finally:
            self.service.lock.release()
        self.assertEqual(self.request('/v1/audio/speech', {'text':'fail'})[0],500)
        self.assertFalse(self.service.lock.locked())
        self.assertEqual(self.request('/v1/audio/speech', {'text':'one'})[0],200)


class ConfigTests(unittest.TestCase):
    def test_paths_and_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'config.json'
            data = {'model_path':'model','reference_audio':'ref.wav'}
            path.write_text(json.dumps(data))
            self.assertEqual(Config.load(path).model_path, Path(directory).resolve()/'model')
            for change in ({'port':True}, {'temperature':float('nan')}, {'speaker_only':False},
                           {'unknown':1}, {'max_chars':0}):
                path.write_text(json.dumps(dict(data, **change)))
                with self.assertRaises((ValueError,TypeError)):
                    Config.load(path)


if __name__ == '__main__':
    unittest.main()
