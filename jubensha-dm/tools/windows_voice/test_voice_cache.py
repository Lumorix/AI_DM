from dataclasses import replace
from pathlib import Path
import tempfile
import unittest
from voice_cache import DiskCache, fingerprint
from voice_service import Config


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        model=self.root/'model';model.mkdir()
        (model/'weights.bin').write_bytes(b'first model')
        reference=self.root/'ref.wav';reference.write_bytes(b'reference')
        self.cfg=Config(model,reference)
        self.metrics={'audio_seconds':1,'generation_seconds':2}

    def test_restart_reuses_disk_and_separates_text(self):
        first=DiskCache(self.root/'cache',fingerprint(self.cfg),1)
        self.assertTrue(first.put('你好',b'audio',self.metrics))
        second=DiskCache(self.root/'cache',fingerprint(self.cfg),1)
        self.assertEqual(second.get('你好'),(b'audio',self.metrics))
        self.assertIsNone(second.get('其他'))

    def test_changed_weights_reference_or_parameters_invalidates(self):
        initial=fingerprint(self.cfg)
        self.assertNotEqual(initial,fingerprint(replace(self.cfg,temperature=0.5)))
        self.cfg.reference_audio.write_bytes(b'new reference')
        changed=fingerprint(self.cfg)
        self.assertNotEqual(initial,changed)
        (self.cfg.model_path/'weights.bin').write_bytes(b'other model')
        self.assertNotEqual(changed,fingerprint(self.cfg))

    def test_corruption_is_miss_and_recoverable(self):
        cache=DiskCache(self.root/'cache','v1',1)
        cache.put('你好',b'audio',self.metrics)
        cache.path('你好').write_text('{broken')
        self.assertIsNone(cache.get('你好'))
        self.assertTrue(cache.put('你好',b'new',self.metrics))
        self.assertEqual(cache.get('你好')[0],b'new')

    def test_full_cache_does_not_delete_existing_files(self):
        cache=DiskCache(self.root/'cache','v1',1)
        cache.put('keep',b'audio',self.metrics)
        self.assertFalse(cache.put('large',b'x'*(1024*1024),self.metrics))
        self.assertEqual(cache.get('keep')[0],b'audio')
        self.assertEqual(list(cache.directory.glob('*.tmp')),[])

    def test_port_does_not_change_voice_identity(self):
        self.assertEqual(fingerprint(self.cfg),fingerprint(replace(self.cfg,port=9999)))


if __name__=='__main__':
    unittest.main()
