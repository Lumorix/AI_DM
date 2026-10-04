"""Content-addressed, bounded, atomic voice cache; never deletes user files."""
import base64
from dataclasses import asdict
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import tempfile


def fingerprint(cfg):
    settings = asdict(cfg)
    for key in ('model_path', 'reference_audio', 'cache_dir', 'disk_cache_mib', 'cache_entries', 'port', 'max_chars'):
        settings.pop(key, None)
    versions = {}
    for package in ('qwen-tts', 'torch', 'transformers'):
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            versions[package] = 'absent'
    digest = hashlib.sha256(json.dumps({'format':1,'settings':settings,'versions':versions},sort_keys=True).encode())
    files = sorted(p for p in cfg.model_path.rglob('*') if p.is_file()
                   and not any(part.startswith('.') for part in p.relative_to(cfg.model_path).parts))
    if not files:
        raise ValueError('No model files for cache fingerprint')
    for file in [cfg.reference_audio] + files:
        name = 'reference' if file == cfg.reference_audio else file.relative_to(cfg.model_path).as_posix()
        digest.update(json.dumps([name,file.stat().st_size]).encode())
        with file.open('rb') as reader:
            for chunk in iter(lambda:reader.read(1024*1024),b''):
                digest.update(chunk)
    return digest.hexdigest()


class DiskCache:
    def __init__(self, root, namespace, limit_mib):
        self.root = Path(root)
        self.directory = self.root/namespace
        self.limit = limit_mib*1024*1024

    def path(self, text):
        return self.directory/(hashlib.sha256(text.encode()).hexdigest()+'.json')

    def get(self, text):
        try:
            path = self.path(text)
            if path.stat().st_size > 24*1024*1024:
                return None
            obj = json.loads(path.read_text(encoding='utf-8'))
            data = base64.b64decode(obj['audio'],validate=True)
            if hashlib.sha256(data).hexdigest() != obj['sha256']:
                return None
            metrics = obj['metrics']
            for key in ('audio_seconds','generation_seconds'):
                if type(metrics[key]) not in (int,float) or not 0 <= metrics[key] < 100000:
                    return None
            return data, metrics
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def put(self, text, data, metrics):
        temp = None
        try:
            body = json.dumps({'audio':base64.b64encode(data).decode(),
                'sha256':hashlib.sha256(data).hexdigest(),'metrics':metrics}).encode()
            self.directory.mkdir(parents=True,exist_ok=True)
            used = sum(p.stat().st_size for p in self.root.glob('*/*.json'))
            if used + len(body) > self.limit:
                return False
            with tempfile.NamedTemporaryFile(dir=self.directory,suffix='.tmp',delete=False) as writer:
                temp = Path(writer.name)
                writer.write(body)
            os.replace(temp,self.path(text))
            return True
        except OSError:
            return False
        finally:
            if temp is not None:
                try:
                    temp.unlink(missing_ok=True)
                except OSError:
                    pass
