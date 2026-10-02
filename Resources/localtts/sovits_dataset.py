#!/usr/bin/env python3
"""把角色台词素材切成 GPT-SoVITS 训练集（在 GPT-SoVITS 目录下用它的 Python 运行）。

  python sovits_dataset.py --vocals 人声.wav --transcript transcript.json --out 数据集文件夹 \
      --ref-ranges "0-8.3,203.7-212.2,75.6-86.3" [--speaker yachiyo] [--lang ja]

- transcript.json：Whisper 识别结果（start/end/text/avg_logprob/no_speech_prob）
- 去掉唱歌、识别不可信、太短太长的句子
- 用说话人识别模型（ERes2NetV2）和“确定是本人”的几段（--ref-ranges）比对，去掉别的角色的声音
- 输出 out/wavs/*.wav（32kHz 单声道）和 out/train.list（路径|说话人|语言|文本）
"""
import argparse
import json
import os
import re
import sys

import librosa
import numpy as np
import soundfile as sf
import torch

sys.path.insert(0, os.getcwd())
from GPT_SoVITS.sv import SV  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--vocals", required=True)
ap.add_argument("--transcript", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--ref-ranges", required=True, help="确定是本人的时间段，秒，逗号分隔，如 0-8.3,75.6-86.3")
ap.add_argument("--speaker", default="yachiyo")
ap.add_argument("--lang", default="ja")
ap.add_argument("--min-sim", type=float, default=0.0, help="和本人的相似度下限；0 = 自动")
args = ap.parse_args()

os.makedirs(os.path.join(args.out, "wavs"), exist_ok=True)
audio, sr = librosa.load(args.vocals, sr=32000, mono=True)
a16 = librosa.resample(audio, orig_sr=32000, target_sr=16000)
segs = json.load(open(args.transcript, encoding="utf-8"))
sv = SV("cpu", False)


def emb(start, end):
    x = torch.from_numpy(a16[int(start * 16000):int(end * 16000)]).float().unsqueeze(0)
    e = sv.compute_embedding3(x)[0].numpy()
    return e / (np.linalg.norm(e) + 1e-9)


refs = [tuple(map(float, r.split("-"))) for r in args.ref_ranges.split(",")]
centroid = np.mean([emb(a, b) for a, b in refs], axis=0)
centroid /= np.linalg.norm(centroid)

rows = []
for s in segs:
    t = (s.get("text") or "").strip()
    start, end = float(s["start"]) - 0.08, float(s["end"]) + 0.12
    dur = end - start
    if not t or re.search(r"[A-Za-z]{3,}|♪", t) or dur < 1.2 or dur > 12:
        continue
    if (s.get("no_speech_prob") or 0) > 0.5 or (s.get("avg_logprob") or 0) < -1.0:
        continue
    start, end = max(0.0, start), min(end, len(audio) / 32000)
    if end - start < 1.2:
        continue
    sim = float(np.dot(emb(start, end), centroid))
    rows.append((start, end, t, sim))

sims = np.array([r[3] for r in rows])
th = args.min_sim or float(max(0.45, np.median(sims) - 2 * sims.std()))
print(f"{len(rows)} 句候选，相似度 中位数 {np.median(sims):.2f}，最低 {sims.min():.2f}，阈值 {th:.2f}", flush=True)

lines, total = [], 0.0
for n, (start, end, t, sim) in enumerate(rows):
    if sim < th:
        print(f"  去掉（像别人）：{start:.1f}s sim={sim:.2f} {t}")
        continue
    clip = audio[int(max(0, start) * 32000):int(end * 32000)]
    clip = clip / max(1e-6, float(np.abs(clip).max())) * 0.9
    p = os.path.abspath(os.path.join(args.out, "wavs", f"{args.speaker}_{n:03d}.wav"))
    sf.write(p, clip, 32000, subtype="PCM_16")
    lines.append(f"{p}|{args.speaker}|{args.lang}|{t}")
    total += end - start

with open(os.path.join(args.out, "train.list"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(f"训练集：{len(lines)} 句，共 {total:.0f} 秒 → {os.path.join(args.out, 'train.list')}")
