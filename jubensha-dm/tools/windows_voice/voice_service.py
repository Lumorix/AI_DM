"""Configurable, loopback-only Windows TTS API. No model downloads or training."""
import argparse
from collections import OrderedDict
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import threading
import time


@dataclass(frozen=True)
class Config:
    model_path: Path
    reference_audio: Path
    reference_text: str = ''
    speaker_only: bool = True
    language: str = 'Chinese'
    seed: int = 42
    temperature: float = 0.9
    max_new_tokens: int = 768
    whole_text: bool = False
    threads: int = 4
    max_chars: int = 120
    cache_entries: int = 32
    port: int = 8775

    @classmethod
    def load(cls, path):
        path = Path(path).resolve()
        values = json.loads(path.read_text(encoding='utf-8-sig'))
        if not isinstance(values, dict):
            raise ValueError('Config must be a JSON object')
        for key in ('model_path', 'reference_audio'):
            value = values.get(key)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f'{key} is required')
            values[key] = (path.parent / value).resolve()
        cfg = cls(**values)
        for key, low, high in [('seed',0,2**32-1), ('threads',1,64), ('max_chars',1,500),
                               ('max_new_tokens',32,2048), ('cache_entries',0,128), ('port',1024,65535)]:
            value = getattr(cfg, key)
            if type(value) is not int or not low <= value <= high:
                raise ValueError(f'Invalid {key}')
        if type(cfg.temperature) not in (float, int) or not 0.1 <= cfg.temperature <= 2:
            raise ValueError('Invalid temperature')
        if type(cfg.speaker_only) is not bool or type(cfg.whole_text) is not bool:
            raise ValueError('speaker_only and whole_text must be booleans')
        if not isinstance(cfg.reference_text, str) or (not cfg.speaker_only and not cfg.reference_text.strip()):
            raise ValueError('Full reference mode requires reference_text')
        if cfg.language != 'Chinese':
            raise ValueError('This service currently supports Chinese only')
        return cfg


class QwenEngine:
    def __init__(self, cfg):
        if not cfg.model_path.is_dir() or not cfg.reference_audio.is_file():
            raise FileNotFoundError('Configured model directory or reference audio is missing')
        import os
        os.environ['HF_HUB_OFFLINE'] = '1'
        import torch
        from qwen_tts import Qwen3TTSModel
        if not torch.cuda.is_available():
            raise RuntimeError('CUDA is unavailable')
        torch.set_num_threads(cfg.threads)
        torch.set_num_interop_threads(1)
        self.cfg = cfg
        self.model = Qwen3TTSModel.from_pretrained(str(cfg.model_path), device_map='cuda:0',
            dtype=torch.bfloat16, attn_implementation='sdpa', local_files_only=True)
        self.model.model.eval()
        with torch.inference_mode():
            self.prompt = self.model.create_voice_clone_prompt(ref_audio=str(cfg.reference_audio),
                ref_text=cfg.reference_text or None, x_vector_only_mode=cfg.speaker_only)

    def synthesize(self, text):
        import numpy as np
        import soundfile as sf
        import torch
        cfg = self.cfg
        torch.manual_seed(cfg.seed)
        start = time.perf_counter()
        with torch.inference_mode():
            wavs, sr = self.model.generate_voice_clone(text=text, language=cfg.language,
                voice_clone_prompt=self.prompt, non_streaming_mode=cfg.whole_text,
                max_new_tokens=cfg.max_new_tokens, do_sample=True, temperature=cfg.temperature,
                subtalker_dosample=True, subtalker_temperature=cfg.temperature)
        torch.cuda.synchronize()
        wav = np.asarray(wavs[0])
        if not wav.size or not np.isfinite(wav).all() or abs(wav).max() < 1e-6:
            raise RuntimeError('Model produced invalid or silent audio')
        buf = io.BytesIO()
        sf.write(buf, wav, sr, format='WAV', subtype='PCM_16')
        return buf.getvalue(), {'audio_seconds': len(wav)/sr,
                               'generation_seconds': time.perf_counter()-start}


class VoiceService:
    def __init__(self, cfg):
        self.cfg = cfg
        self.status = 'loading'
        self.engine = None
        self.failure = None
        self.lock = threading.Lock()
        self.cache = OrderedDict()

    def load(self, factory=QwenEngine):
        try:
            self.engine = factory(self.cfg)
            self.status = 'ready'
        except Exception as exc:
            self.failure = 'model_load_failed'
            self.status = 'error'
            print(f'Model load failed: {exc}', flush=True)


def make_server(service, port=None):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(15)

        def reply(self, code, data):
            body = json.dumps(data, ensure_ascii=False).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def error(self, status, code, message):
            self.reply(status, {'error': {'code': code, 'message': message}})

        def do_GET(self):
            if self.path != '/health':
                self.error(404, 'not_found', '接口不存在')
                return
            self.reply(200 if service.status == 'ready' else 503,
                {'status': service.status, 'busy': service.lock.locked(), 'error': service.failure,
                 'api_version': 1, 'voice': 'yachiyo-experimental', 'quality': 'experimental',
                 'streaming': False, 'max_chars': service.cfg.max_chars})

        def do_POST(self):
            if self.path not in ('/v1/audio/speech', '/synthesize'):
                self.error(404, 'not_found', '接口不存在')
                return
            origin = self.headers.get('Origin')
            local_port = self.server.server_port
            if origin not in (None, f'http://127.0.0.1:{local_port}', f'http://localhost:{local_port}'):
                self.error(403, 'origin_denied', '仅允许本机同源调用')
                return
            if self.headers.get_content_type() != 'application/json':
                self.error(415, 'invalid_content_type', '请发送 application/json')
                return
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 8192:
                    self.error(413, 'body_too_large', '请求体长度必须为 1–8192 字节')
                    return
                body = json.loads(self.rfile.read(size))
                text = body.get('text') if isinstance(body, dict) else None
                if not isinstance(text, str) or not 1 <= len(text.strip()) <= service.cfg.max_chars:
                    raise ValueError()
                text = text.strip()
            except (ValueError, UnicodeError, TimeoutError):
                self.error(400, 'invalid_text', f'请输入 1–{service.cfg.max_chars} 个字符的 text 字段')
                return
            if service.status != 'ready':
                self.error(503, service.failure or 'model_loading', '模型尚未就绪，请查看 /health 和服务日志')
                return
            if not service.lock.acquire(blocking=False):
                self.error(429, 'busy', '正在生成上一条语音，请稍后重试')
                return
            try:
                hit = text in service.cache
                if hit:
                    data, metrics = service.cache[text]
                    service.cache.move_to_end(text)
                else:
                    data, metrics = service.engine.synthesize(text)
                    if service.cfg.cache_entries:
                        service.cache[text] = (data, metrics)
                        while len(service.cache) > service.cfg.cache_entries:
                            service.cache.popitem(last=False)
            except Exception as exc:
                print(f'Synthesis failed: {exc}', flush=True)
                self.error(500, 'synthesis_failed', '生成失败，请查看服务日志；可以重试')
                return
            finally:
                service.lock.release()
            self.send_response(200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('X-Cache', 'hit' if hit else 'miss')
            self.send_header('X-Audio-Seconds', str(metrics['audio_seconds']))
            self.send_header('X-Generation-Seconds', str(metrics['generation_seconds']))
            self.end_headers()
            self.wfile.write(data)

    return ThreadingHTTPServer(('127.0.0.1', service.cfg.port if port is None else port), Handler)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', type=Path, default=Path(__file__).with_name('voice_config.example.json'))
    args = ap.parse_args()
    try:
        cfg = Config.load(args.config)
    except (ValueError, TypeError, OSError) as exc:
        ap.error(str(exc))
    service = VoiceService(cfg)
    server = make_server(service)
    threading.Thread(target=service.load, daemon=True).start()
    print(f'Voice API: http://127.0.0.1:{cfg.port}/health (experimental voice)', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
