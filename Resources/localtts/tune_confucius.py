#!/usr/bin/env python3
"""用 Confucius4-TTS（网易有道，专做跨语种克隆）合成同一组测试句，输出格式和 tune_voice.py 一样，方便用同一套打分。

  .venv/bin/python tune_confucius.py --model <模型文件夹> --out <tune 文件夹> --refs 名字=参考.wav,... [--temps 0.8,0.6]
"""
import argparse
import json
import os
import time

import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model

ap = argparse.ArgumentParser()
ap.add_argument("--model", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--refs", required=True)
ap.add_argument("--temps", default="0.8")
ap.add_argument("--sets", default="tune,hold")
args = ap.parse_args()

S = json.load(open(os.path.join(args.out, "sentences.json"), encoding="utf-8"))
tp = os.path.join(args.out, "timing.json")
timing = json.load(open(tp)) if os.path.exists(tp) else {}
m = load_model(args.model)
for item in args.refs.split(","):
    rname, ref = item.split("=")
    for t in [float(x) for x in args.temps.split(",")]:
        name = f"CF_{rname}_t{t}"
        d = os.path.join(args.out, name)
        os.makedirs(d, exist_ok=True)
        for s in args.sets.split(","):
            for i, text in enumerate(S[s], 1):
                p = os.path.join(d, f"{s}_{i:02d}.wav")
                if os.path.exists(p):
                    continue
                t0 = time.time()
                rs = list(m.generate(text=text, ref_audio=ref, lang="zh", temperature=t, seed=1000 + i))
                y = np.concatenate([np.array(r.audio, dtype=np.float32) for r in rs]) if rs else None
                total = time.time() - t0
                if y is None or len(y) < 100:
                    print(f"{name} {s}_{i:02d}: EMPTY", flush=True)
                    continue
                sr = rs[0].sample_rate
                sf.write(p, y, sr)
                timing[f"{name}/{s}_{i:02d}"] = {"first": round(total, 2), "total": round(total, 2), "audio": round(len(y) / sr, 2),
                                                "rtf": round(total / max(0.1, len(y) / sr), 2)}
                json.dump(timing, open(tp, "w"), ensure_ascii=False, indent=1)
                print(f"{name} {s}_{i:02d}: {total:.1f}s for {len(y)/sr:.1f}s audio", flush=True)
print("done")
