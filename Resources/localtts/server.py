#!/usr/bin/env python3
"""AI 剧本杀 · 本机语音服务：Qwen3-TTS（mlx-audio）克隆音色，完全离线。

由 Mac 应用在后台启动：
  python server.py --model <模型文件夹> --voice <音色文件夹> --port 8771

音色文件夹：
  ref.wav     参考录音；ref.txt  这段录音说的原话
  voice.json  可选，这条音色的合成参数（没有就用默认：只学音色向量、温度 0.7）：
    {
      "icl": true,                 用“参考录音 + 原话”做上下文学习：每句都锚定在同一段发音上，音色最稳。
                                   参考录音必须和要说的话是同一种语言（日语录音说中文会带日语腔），
                                   所以八千代用的是她自己念过、经挑选的一句中文当参考（自参考）。
      "temperature": 0.4,          采样温度（越低越稳、越平）
      "top_k": 50, "top_p": 1.0,
      "repetition_penalty": 1.1,   icl 模式 mlx-audio 默认强制 1.5，这里可以自己定
      "acoustic_temperature": 0.4, "acoustic_top_k": 15,   可选、默认不用：只给声学码本（1~15 号）单独降温（测试里没有明显收益）
      "streaming_interval": 0.5    流式每块多少秒
    }

接口：GET /health → {"ok", "voice", "fingerprint"}
      POST /tts         {"text": "...", "voice": "可选，另一个音色文件夹"} → audio/wav
      POST /tts_stream  同样的参数 → 边合成边发：16 位单声道 PCM，采样率在 X-Sample-Rate 头里；第一段约 0.3~0.7 秒就到
模型默认压成 8 位（--bits 8）：苹果芯片上快一倍多，音质基本不变；--bits 0 用原始精度。

已修复的 mlx-audio 问题：流式解码器在每个分块边界把反卷积的偏置加了两次（每 0.48 秒一个小瑕疵）；
修复后流式输出和一次性解码逐样本一致。
"""
import argparse
import hashlib
import io
import json
import os
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mlx.core as mx
import numpy as np
from mlx_audio.tts.models.qwen3_tts import speech_tokenizer as st_mod
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio

PATCH_VERSION = "srv3"      # 服务端行为变了就改这个：App 的语音缓存会跟着作废

ap = argparse.ArgumentParser()
ap.add_argument("--model", required=True)
ap.add_argument("--voice", required=True)
ap.add_argument("--port", type=int, default=8771)
ap.add_argument("--lang", default="chinese")
ap.add_argument("--temperature", type=float, default=0.7, help="voice.json 没写温度时用这个")
ap.add_argument("--bits", type=int, default=8, help="把语言模型部分压成几位（8 / 4），0 = 不压")
ap.add_argument("--once", help="测试：只合成这一句，写到 --out 后退出")
ap.add_argument("--out", default="out.wav")
args = ap.parse_args()


# ---- 修流式解码器：DecoderBlockUpsample.step 的 overlap-add 缓冲里已经含偏置，下一块再加一次就重了 ----
def _fixed_step(self, x):
    y = self.conv(x)
    if self._overflow is not None:
        ov_len = self._overflow.shape[1]
        y = mx.concatenate([y[:, :ov_len, :] + self._overflow, y[:, ov_len:, :]], axis=1)
    if self.trim_right > 0:
        ov = y[:, -self.trim_right:, :]
        if "bias" in self.conv:
            ov = ov - self.conv.bias
        self._overflow = ov
        y = y[:, : -self.trim_right, :]
    return y


st_mod.DecoderBlockUpsample.step = _fixed_step

print("loading model…", flush=True)
model = load_model(args.model)
if args.bits:
    import mlx.nn as nn
    nn.quantize(model.talker, group_size=64, bits=args.bits,
                class_predicate=lambda _, m: isinstance(m, (nn.Linear, nn.Embedding)) and m.weight.shape[-1] % 64 == 0)
    mx.eval(model.talker.parameters())
lock = threading.Lock()
_orig_sample = model.__class__._sample_token


def set_acoustic_sampling(sub):
    """只给声学码本（code predictor）换温度/top_k：它调用 _sample_token 时不带 generated_tokens / suppress_tokens"""
    if sub is None:
        model._sample_token = _orig_sample.__get__(model)
        return
    temp, k = sub

    def patched(logits, temperature=0.9, top_k=50, top_p=1.0, repetition_penalty=1.05, repetition_context_size=64,
                generated_tokens=None, suppress_tokens=None, min_p=0.0):
        if generated_tokens is None and suppress_tokens is None:
            temperature, top_k = temp, k
        return _orig_sample(model, logits, temperature=temperature, top_k=top_k, top_p=top_p, repetition_penalty=repetition_penalty,
                            repetition_context_size=repetition_context_size, generated_tokens=generated_tokens,
                            suppress_tokens=suppress_tokens, min_p=min_p)
    model._sample_token = patched


class Voice:
    def __init__(self, path):
        self.dir = os.path.abspath(path)
        self.ref_wav = os.path.join(self.dir, "ref.wav")
        cfg_path = os.path.join(self.dir, "voice.json")
        cfg = json.load(open(cfg_path, encoding="utf-8")) if os.path.exists(cfg_path) else {}
        self.icl = bool(cfg.get("icl", os.path.exists(os.path.join(self.dir, "icl"))))
        self.temperature = float(cfg.get("temperature", args.temperature))
        self.top_k = int(cfg.get("top_k", 50))
        self.top_p = float(cfg.get("top_p", 1.0))
        self.rp = float(cfg.get("repetition_penalty", 1.5 if self.icl else 1.05))
        self.sub = (float(cfg["acoustic_temperature"]), int(cfg.get("acoustic_top_k", 15))) if cfg.get("acoustic_temperature") is not None else None
        self.interval = float(cfg.get("streaming_interval", 0.5))
        self.lang = cfg.get("lang", args.lang)
        self.ref_text = None
        self.ref_audio = None
        if self.icl:
            with open(os.path.join(self.dir, "ref.txt"), encoding="utf-8") as f:
                self.ref_text = f.read().strip()
            self.ref_audio = load_audio(self.ref_wav, sample_rate=24000)
        # 指纹：这些变了，念出来的声音就不一样，App 据此决定缓存还能不能用
        h = hashlib.sha256()
        h.update(json.dumps(cfg, sort_keys=True, ensure_ascii=False).encode())
        h.update(str(os.path.getsize(self.ref_wav)).encode())
        if os.path.exists(os.path.join(self.dir, "ref.txt")):
            h.update(open(os.path.join(self.dir, "ref.txt"), "rb").read())
        h.update(f"{PATCH_VERSION}|bits{args.bits}".encode())
        self.fingerprint = h.hexdigest()[:16]

    def generate(self, text, stream):
        set_acoustic_sampling(self.sub)
        # 生成上限按文字长度定（每个文字 token 最多 6 个语音码元 ≈ 0.5 秒），最少 75、最多 640 个（约 51 秒）：
        # 万一模型卡住一直出静音，不会无限念下去把游戏挂住
        n_text = len(model.tokenizer.encode(text))
        max_tokens = int(min(640, max(75, 6 * n_text)))
        if self.icl:
            return model._generate_icl(text=text, ref_audio=self.ref_audio, ref_text=self.ref_text, language=self.lang,
                                       temperature=self.temperature, top_k=self.top_k, top_p=self.top_p, max_tokens=max_tokens,
                                       repetition_penalty=self.rp, stream=stream, streaming_interval=self.interval)
        return model.generate(text=text, ref_audio=self.ref_wav, ref_text=None, lang_code=self.lang,
                              temperature=self.temperature, top_k=self.top_k, top_p=self.top_p, repetition_penalty=self.rp,
                              max_tokens=max_tokens, split_pattern="", stream=stream, streaming_interval=self.interval)


voices = {}


def voice(path):
    path = os.path.abspath(path)
    if path not in voices:
        voices[path] = Voice(path)
    return voices[path]


def pcm16(audio):
    return (np.clip(np.asarray(audio, dtype=np.float32), -1, 1) * 32767).astype("<i2").tobytes()


def synth(text, voice_dir):
    v = voice(voice_dir)
    with lock:   # 一次只合成一句，避免显存翻倍
        parts = [np.array(r.audio, dtype=np.float32) for r in v.generate(text, stream=False)]
    audio = np.concatenate(parts) if parts else np.zeros(1, dtype=np.float32)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(model.sample_rate)
        w.writeframes(pcm16(audio))
    return buf.getvalue()


def synth_stream(text, voice_dir):
    """边合成边产出 PCM 片段"""
    v = voice(voice_dir)
    with lock:
        for r in v.generate(text, stream=True):
            yield pcm16(r.audio)


if args.once:
    with open(args.out, "wb") as f:
        f.write(synth(args.once, args.voice))
    print(args.out)
    sys.exit(0)

main_voice = voice(args.voice)
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
            self._send(200, json.dumps({"ok": True, "voice": args.voice, "fingerprint": main_voice.fingerprint,
                                        "icl": main_voice.icl, "temperature": main_voice.temperature}).encode(), "application/json")
        else:
            self._send(404, b"", "text/plain")

    def do_POST(self):
        if self.path not in ("/tts", "/tts_stream"):
            return self._send(404, b"", "text/plain")
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("text") or "").strip()
            if not text:
                return self._send(400, b'{"error":"empty text"}', "application/json")
            voice_dir = req.get("voice") or args.voice
            if self.path == "/tts":
                return self._send(200, synth(text, voice_dir), "audio/wav")
            chunks = synth_stream(text, voice_dir)
            first = next(chunks, b"")      # 第一段出来之前出错的话还能回 500
        except Exception as e:  # noqa: BLE001
            return self._send(500, json.dumps({"error": str(e)}, ensure_ascii=False).encode(), "application/json")
        # 不写 Content-Length，发完就断开连接，客户端读到结尾就知道这句完了
        self.send_response(200)
        self.send_header("Content-Type", "audio/L16")
        self.send_header("X-Sample-Rate", str(model.sample_rate))
        self.end_headers()
        try:
            self.wfile.write(first)
            self.wfile.flush()
            for c in chunks:
                self.wfile.write(c)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            chunks.close()             # 客户端不听了（比如被打断），停止合成


print(f"ready on 127.0.0.1:{args.port}", flush=True)
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
