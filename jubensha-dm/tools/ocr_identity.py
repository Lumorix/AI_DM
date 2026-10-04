"""OCR identity includes source bytes, page order and effective recognition settings."""
import hashlib
import json
from importlib.metadata import version, PackageNotFoundError
from pathlib import Path
import os
import tempfile

IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tif', '.tiff'}


def file_digest(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def cache_identity(source, engine, dpi, split, lang, cfg, prompt):
    source = Path(source)
    files = sorted(p for p in source.iterdir() if p.suffix.lower() in IMAGE_EXTENSIONS) if source.is_dir() else [source]
    effective = {**(cfg.get('llm') or {}), **{k: v for k, v in (cfg.get('vision') or {}).items() if v}}
    # Never persist credentials or raw configuration in the output directory.
    vision = {k: effective.get(k) for k in ('provider', 'base_url', 'model', 'temperature', 'extra_body')} if engine == 'vision' else None
    packages = {}
    for name in ('pypdfium2', 'Pillow', 'rapidocr', 'rapidocr-onnxruntime'):
        try:
            packages[name] = version(name)
        except PackageNotFoundError:
            packages[name] = None
    spec = {'version': 1, 'source': [(p.name, file_digest(p)) for p in files],
            'engine': engine, 'dpi': dpi, 'split': split, 'lang': lang,
            'vision': vision, 'prompt': prompt if engine == 'vision' else None,
            'packages': packages, 'revision': cfg.get('ocr_cache_revision', '')}
    return hashlib.sha256(json.dumps(spec, sort_keys=True, ensure_ascii=False).encode('utf-8')).hexdigest()


def read_page(path):
    try:
        text = Path(path).read_text(encoding='utf-8')
        return text if text.strip() else None
    except (OSError, UnicodeError):
        return None


def write_atomic(path, text):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix=path.name + '.', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(text)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)
