#!/usr/bin/env python3
"""从一段角色台词素材（视频/音频）里挑出几段干净的参考录音，给 Qwen3-TTS 克隆音色用。

  python prepare_voice.py --audio source_24k.wav --audio16 source_16k.wav --whisper <whisper模型> --out <音色文件夹> [--lang ja]

步骤：Whisper 识别原话和时间 → 把连续的说话合并成 6~14 秒的片段 → 按“片段前后安静（没有背景音乐）、识别可信度高”打分
→ 取分数最高、彼此不重叠的几段，存成 candidates/N/ref.wav + ref.txt。
"""
import argparse
import json
import os
import re

import numpy as np
from scipy.io import wavfile
from mlx_audio.stt.utils import load_model

ap = argparse.ArgumentParser()
ap.add_argument("--audio", required=True, help="24kHz 单声道 wav（克隆用）")
ap.add_argument("--audio16", required=True, help="16kHz 单声道 wav（识别用）")
ap.add_argument("--whisper", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--lang", default="ja")
ap.add_argument("--count", type=int, default=4)
args = ap.parse_args()

sr, audio = wavfile.read(args.audio)
audio = audio.astype(np.float32) / 32768.0
print(f"audio {len(audio) / sr:.1f}s", flush=True)

stt = load_model(args.whisper)
res = stt.generate(args.audio16, language=args.lang, verbose=False)
segs = [s for s in (res.segments or []) if s.get("text", "").strip()]
print(f"whisper: {len(segs)} segments", flush=True)
with open(os.path.join(args.out, "transcript.json"), "w", encoding="utf-8") as f:
    json.dump([{k: s.get(k) for k in ("start", "end", "text", "avg_logprob", "no_speech_prob")} for s in segs],
              f, ensure_ascii=False, indent=1)


def rms(a, b):
    a, b = max(0, int(a * sr)), min(len(audio), int(b * sr))
    if b <= a:
        return 0.0
    x = audio[a:b]
    return float(np.sqrt(np.mean(x * x)) + 1e-9)


def ok(s):
    t = s["text"]
    if re.search(r"[A-Za-z]{3,}|♪|〜〜|ー{3,}", t):          # 歌词、英文、拖长音：多半是唱歌
        return False
    if s.get("no_speech_prob", 0) > 0.5 or s.get("avg_logprob", 0) < -0.9:
        return False
    return True


# 合并连续的说话（间隔 < 0.7 秒），得到 6~14 秒的窗口
cands = []
for i in range(len(segs)):
    if not ok(segs[i]):
        continue
    j, text = i, segs[i]["text"].strip()
    while True:
        dur = segs[j]["end"] - segs[i]["start"]
        if 6.0 <= dur <= 14.0:
            start, end = segs[i]["start"], segs[j]["end"]
            speech = rms(start, end)
            around = (rms(start - 0.6, start - 0.05) + rms(end + 0.05, end + 0.6)) / 2   # 片段前后的底噪
            quiet = around / speech                                                      # 越小越干净
            conf = np.mean([segs[k].get("avg_logprob", -0.5) for k in range(i, j + 1)])
            score = -quiet * 3 + conf - abs(dur - 10) * 0.05
            cands.append({"start": start, "end": end, "text": text, "score": float(score),
                          "quiet": float(quiet), "conf": float(conf)})
        j += 1
        if j >= len(segs) or not ok(segs[j]) or segs[j]["start"] - segs[j - 1]["end"] > 0.7 or dur > 14:
            break
        text += segs[j]["text"].strip()

cands.sort(key=lambda c: -c["score"])
picked = []
for c in cands:
    if all(c["end"] <= p["start"] or c["start"] >= p["end"] for p in picked):
        picked.append(c)
    if len(picked) >= args.count:
        break

os.makedirs(os.path.join(args.out, "candidates"), exist_ok=True)
for n, c in enumerate(picked, 1):
    d = os.path.join(args.out, "candidates", str(n))
    os.makedirs(d, exist_ok=True)
    a, b = int(c["start"] * sr), int(c["end"] * sr)
    clip = audio[a:b]
    clip = clip / max(1e-6, float(np.max(np.abs(clip)))) * 0.9                       # 音量标准化
    wavfile.write(os.path.join(d, "ref.wav"), sr, (clip * 32767).astype("<i2"))
    with open(os.path.join(d, "ref.txt"), "w", encoding="utf-8") as f:
        f.write(c["text"])
    with open(os.path.join(d, "info.json"), "w", encoding="utf-8") as f:
        json.dump(c, f, ensure_ascii=False, indent=1)
    print(f"候选{n}: {c['start']:.1f}-{c['end']:.1f}s  quiet={c['quiet']:.2f} conf={c['conf']:.2f}  {c['text']}", flush=True)
