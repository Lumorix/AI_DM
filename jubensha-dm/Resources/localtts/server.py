#!/usr/bin/env python3
"""AI 剧本杀 · 本机语音服务：Qwen3-TTS（mlx-audio）克隆音色，完全离线。

由 Mac 应用在后台启动：
  python server.py --model <模型文件夹> --voice <音色文件夹> --port 8771
音色文件夹里放 ref.wav（参考录音）和 ref.txt（这段录音说的原话）。
默认只学音色（speaker embedding）：参考录音是日语、要说中文时必须这样，否则会用日语读音念中文。
参考录音和要说的话是同一种语言时，可以在音色文件夹里放一个空文件 icl，改用“连语气一起学”的模式。
接口：GET /health ；POST /tts  {"text": "...", "voice": "可选，另一个音色文件夹"}  → audio/wav
"""
import argparse
import io
import json
import os
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from mlx_audio.tts.utils import load_model

ap = argparse.ArgumentParser()
ap.add_argument("--model", required=True)
ap.add_argument("--voice", required=True)
ap.add_argument("--port", type=int, default=8771)
ap.add_argument("--lang", default="chinese")
ap.add_argument("--temperature", type=float, default=0.7)
ap.add_argument("--once", help="测试：只合成这一句，写到 --out 后退出")
ap.add_argument("--out", default="out.wav")
args = ap.parse_args()

print("loading model…", flush=True)
model = load_model(args.model)
lock = threading.Lock()
voices = {}


def voice(path):
    path = os.path.abspath(path)
    if path not in voices:
        ref_text = None
        if os.path.exists(os.path.join(path, "icl")):
            with open(os.path.join(path, "ref.txt"), encoding="utf-8") as f:
                ref_text = f.read().strip()
        voices[path] = (os.path.join(path, "ref.wav"), ref_text)
    return voices[path]


def synth(text, voice_dir):
    ref_audio, ref_text = voice(voice_dir)
    with lock:   # 一次只合成一句，避免显存翻倍
        parts = [np.array(r.audio, dtype=np.float32) for r in model.generate(
            text=text, ref_audio=ref_audio, ref_text=ref_text, lang_code=args.lang,
            temperature=args.temperature, split_pattern="")]
    audio = np.concatenate(parts) if parts else np.zeros(1, dtype=np.float32)
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(model.sample_rate)
        w.writeframes(pcm)
    return buf.getvalue()


if args.once:
    with open(args.out, "wb") as f:
        f.write(synth(args.once, args.voice))
    print(args.out)
    sys.exit(0)

voice(args.voice)
synth("你好。", args.voice)   # 预热，第一句不会卡


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, json.dumps({"ok": True, "voice": args.voice}).encode(), "application/json")
        else:
            self._send(404, b"", "text/plain")

    def do_POST(self):
        if self.path != "/tts":
            return self._send(404, b"", "text/plain")
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("text") or "").strip()
            if not text:
                return self._send(400, b'{"error":"empty text"}', "application/json")
            self._send(200, synth(text, req.get("voice") or args.voice), "audio/wav")
        except Exception as e:  # noqa: BLE001
            self._send(500, json.dumps({"error": str(e)}, ensure_ascii=False).encode(), "application/json")


print(f"ready on 127.0.0.1:{args.port}", flush=True)
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
