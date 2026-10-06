#!/usr/bin/env python3
"""给 tune_voice.py 的结果打“音色稳不稳”的分（用 seedvc-venv：Resemblyzer + CAM++ + librosa）。

  python score_consistency.py --tune <tune_voice 的输出文件夹> --real <角色真声 wav 文件夹> --out scores.json \\
      [--configs A,B] [--exclude tune_01,hold_04] [--pairs Bs_...:Cs_...,Ss_...:Cs_...] [--campplus <scoring 文件夹>]

两个声纹模型各算一遍（res = Resemblyzer，英文训练；cam = CAM++，中文训练，更可信）：
  pair_sim   句与句之间声纹相似度的平均值（越高越稳）；pair_p10 = 最差 10% 处（比最小值稳）
  sim_anchor 和 A 设置（用户认可的那种声音）的平均相似度；A 自己用留一法（不和自己比）
  sim_real   和角色真声（日语原声）的平均相似度
  within     句内相邻 1.6 秒片段的声纹相似度均值/最低（Resemblyzer 自己的切片方式；粗略指标）
  f0_median / f0_spread   各句音高中位数（半音）及其离散（越小越稳）
  f0_within  句内音高起伏（半音）：这是“生动程度”，太低说明念得平板，不是越低越好
  rate       每秒几个字（去掉首尾静音后）
  first_audible  第一声多久出来（第一段到达时间 + 开头静音）
声音先按 Resemblyzer 的要求预处理（-30 dBFS、去静音）再算声纹；被用作自参考的句子（--exclude）所有设置都不计分。
配对（同种子只差解码方式）：按 80 ms 码元对齐，报告分块边界处 vs 非边界处的相对误差（边界处明显大 = 流式解码器在边界出瑕疵）。
"""
import argparse
import glob
import json
import math
import os
import re
import sys

import librosa
import numpy as np
from resemblyzer import VoiceEncoder, preprocess_wav

ap = argparse.ArgumentParser()
ap.add_argument("--tune", required=True)
ap.add_argument("--real", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--configs", default="")
ap.add_argument("--exclude", default="", help="不计分的句子，如 tune_01,hold_04（被拿去做自参考的）")
ap.add_argument("--pairs", default="", help="同种子配对 a:b，逗号分隔")
ap.add_argument("--campplus", default="", help="scoring 文件夹（含 campplus/ 和 campplus_cn_common.bin）")
ap.add_argument("--chunk-tokens", type=int, default=6, help="流式每块多少个码元（0.5 s → 6）")
args = ap.parse_args()

sentences = json.load(open(os.path.join(args.tune, "sentences.json"), encoding="utf-8"))
timing = json.load(open(os.path.join(args.tune, "timing.json"), encoding="utf-8"))
exclude = set(x for x in args.exclude.split(",") if x)

enc = VoiceEncoder("cpu", verbose=False)
cam = None
if args.campplus and os.path.exists(os.path.join(args.campplus, "campplus_cn_common.bin")):
    import torch
    import torchaudio
    sys.path.insert(0, args.campplus)
    from modules.campplus.DTDNN import CAMPPlus
    cam = CAMPPlus(feat_dim=80, embedding_size=192)
    cam.load_state_dict(torch.load(os.path.join(args.campplus, "campplus_cn_common.bin"), map_location="cpu"))
    cam.eval()


def unit(e):
    return e / (np.linalg.norm(e) + 1e-9)


def prep(w16):
    """Resemblyzer 的标准预处理：-30 dBFS、去掉长静音"""
    return preprocess_wav(w16, source_sr=16000)


def emb_res(wp):
    return unit(enc.embed_utterance(wp))


def emb_cam(wp):
    if cam is None:
        return None
    with torch.no_grad():
        f = torchaudio.compliance.kaldi.fbank(torch.tensor(wp).unsqueeze(0), num_mel_bins=80, dither=0, sample_frequency=16000)
        return unit(cam((f - f.mean(dim=0, keepdim=True)).unsqueeze(0))[0].numpy())


def within_res(wp):
    """Resemblyzer 自己的 1.6 s 切片（每 0.5 s 一片），相邻片的相似度"""
    if len(wp) < 16000 * 1.6:
        return []
    _, partials, _ = enc.embed_utterance(wp, return_partials=True, rate=2.0)
    P = partials / (np.linalg.norm(partials, axis=1, keepdims=True) + 1e-9)
    return [float(P[i] @ P[i + 1]) for i in range(len(P) - 1)]


def f0_semitones(w):
    f0, voiced, _ = librosa.pyin(w, fmin=100, fmax=600, sr=16000, frame_length=1024)
    f0 = f0[voiced & ~np.isnan(f0)]
    return 12 * np.log2(f0 / 440) if len(f0) else np.array([])


def lead_silence(w, thr=0.01):
    idx = np.where(np.abs(w) > thr)[0]
    return (idx[0] / 16000) if len(idx) else len(w) / 16000


def clean(v):
    return None if isinstance(v, float) and (math.isnan(v) or math.isinf(v)) else v


def stats(xs):
    xs = [x for x in xs if x is not None and not (isinstance(x, float) and math.isnan(x))]
    return float(np.mean(xs)) if xs else float("nan")


# ---- 真声 ----
real_files = sorted(glob.glob(os.path.join(args.real, "*.wav")))
R_res, R_cam = [], []
for p in real_files:
    wp = prep(librosa.load(p, sr=16000)[0])
    R_res.append(emb_res(wp))
    if cam is not None:
        R_cam.append(emb_cam(wp))
R_res = np.stack(R_res)
real_c_res = unit(R_res.mean(0))
real_c_cam = unit(np.stack(R_cam).mean(0)) if cam is not None else None
iu = np.triu_indices(len(R_res), 1)
baseline = {"real_pairwise_res": float((R_res @ R_res.T)[iu].mean())}
if cam is not None:
    Rc = np.stack(R_cam)
    baseline["real_pairwise_cam"] = float((Rc @ Rc.T)[iu].mean())

# ---- 各设置 ----
all_dirs = sorted(d for d in os.listdir(args.tune) if os.path.isdir(os.path.join(args.tune, d)) and d != "refs")
if args.configs:
    all_dirs = [c for c in all_dirs if c in args.configs.split(",")]
pat = re.compile(r"^([a-z]+)_(\d+)\.wav$")
data = {}
for c in all_dirs:
    files = []
    for p in sorted(glob.glob(os.path.join(args.tune, c, "*.wav"))):
        m = pat.match(os.path.basename(p))
        if not m or m.group(1) not in sentences:
            print(f"跳过无关文件 {p}")
            continue
        if os.path.basename(p)[:-4] in exclude:
            continue
        files.append((p, m.group(1), int(m.group(2))))
    if len(files) < 2:
        print(f"{c}: 只有 {len(files)} 句，不计")
        continue
    rows = []
    for p, s, i in files:
        w = librosa.load(p, sr=16000)[0]
        if len(w) < 16000 * 0.5:
            print(f"{c}/{s}_{i:02d}: 太短，跳过")
            continue
        wp = prep(w)
        st = f0_semitones(wp)
        wt, _ = librosa.effects.trim(w, top_db=40)
        text = sentences[s][i - 1]
        chars = len(re.sub(r"[^一-鿿]", "", text))
        t = timing.get(f"{c}/{s}_{i:02d}", {})
        rows.append({
            "id": f"{s}_{i:02d}", "res": emb_res(wp), "cam": emb_cam(wp), "within": within_res(wp),
            "f0m": float(np.median(st)) if len(st) else float("nan"), "f0w": float(np.std(st)) if len(st) else float("nan"),
            "rate": chars / max(0.5, len(wt) / 16000),
            "first_audible": (t.get("first", 0) or 0) + lead_silence(w), "rtf": t.get("rtf"), "lead": lead_silence(w),
        })
    data[c] = rows
    print(c, len(rows), "句", flush=True)

configs = list(data)
if not configs:
    sys.exit("没有可计分的设置")

# 锚点：A 设置的声纹中心（A 自己用留一法）
anchor_name = next((c for c in configs if c.startswith("A_")), configs[0])
A_res = np.stack([r["res"] for r in data[anchor_name]])
A_cam = np.stack([r["cam"] for r in data[anchor_name]]) if cam is not None else None


def anchor_sims(c, key, A):
    X = np.stack([r[key] for r in data[c]])
    if c == anchor_name:
        out = []
        for k in range(len(X)):
            cen = unit(np.delete(A, k, axis=0).mean(0))
            out.append(float(X[k] @ cen))
        return out
    cen = unit(A.mean(0))
    return [float(x @ cen) for x in X]


out = {"_baseline": baseline, "_excluded": sorted(exclude), "_anchor": anchor_name}
for c in configs:
    rows = data[c]
    r = {"n": len(rows)}
    for key, real_c, A in [("res", real_c_res, A_res), ("cam", real_c_cam, A_cam)]:
        if rows[0][key] is None:
            continue
        X = np.stack([x[key] for x in rows])
        S = X @ X.T
        pairs = S[np.triu_indices(len(X), 1)]
        r[f"pair_sim_{key}"] = float(pairs.mean())
        r[f"pair_p10_{key}"] = float(np.percentile(pairs, 10))
        r[f"sim_anchor_{key}"] = stats(anchor_sims(c, key, A))
        r[f"sim_real_{key}"] = float((X @ real_c).mean())
    within = [v for x in rows for v in x["within"]]
    r["within_mean"] = stats(within)
    r["within_min"] = float(np.min(within)) if within else float("nan")
    f0m = [x["f0m"] for x in rows]
    r["f0_median"] = stats(f0m)
    r["f0_spread"] = float(np.nanstd(np.array(f0m, dtype=float)))
    r["f0_within"] = stats([x["f0w"] for x in rows])
    r["rate"] = stats([x["rate"] for x in rows])
    r["rate_sd"] = float(np.std([x["rate"] for x in rows]))
    r["first_audible"] = stats([x["first_audible"] for x in rows])
    r["lead_silence_frac"] = float(np.mean([x["lead"] > 0.3 for x in rows]))
    r["rtf"] = stats([x["rtf"] for x in rows])
    out[c] = {k: clean(v) for k, v in r.items()}

# ---- 同种子配对：按码元对齐看分块边界 ----
TOK = 1920   # 24 kHz 下每个码元的采样数
for pair in [p for p in args.pairs.split(",") if p]:
    a, b = pair.split(":")
    if a not in data or b not in data:
        continue
    pos_err = {k: [] for k in range(args.chunk_tokens)}
    corr_all, n_same, n_pairs = [], 0, 0
    for ra in data[a]:
        pa = os.path.join(args.tune, a, ra["id"] + ".wav")
        pb = os.path.join(args.tune, b, ra["id"] + ".wav")
        if not os.path.exists(pb):
            continue
        ya, yb = librosa.load(pa, sr=24000)[0], librosa.load(pb, sr=24000)[0]
        n_pairs += 1
        ta, tb = len(ya) // TOK, len(yb) // TOK
        if abs(ta - tb) > 1:
            continue           # 码不一样（采样分叉了），不比
        n_same += 1
        n = min(ta, tb)
        for t in range(n):
            xa, xb = ya[t * TOK:(t + 1) * TOK], yb[t * TOK:(t + 1) * TOK]
            denom = np.sqrt(np.mean(xb ** 2)) + 1e-6
            pos_err[t % args.chunk_tokens].append(float(np.sqrt(np.mean((xa - xb) ** 2)) / denom))
            if np.std(xa) > 1e-6 and np.std(xb) > 1e-6:
                corr_all.append(float(np.corrcoef(xa, xb)[0, 1]))
    rep = {"pairs": n_pairs, "same_codes": n_same,
           "boundary_err_median": clean(float(np.median(pos_err[0]))) if pos_err[0] else None,
           "boundary_err_p90": clean(float(np.percentile(pos_err[0], 90))) if pos_err[0] else None,
           "nonboundary_err_median": clean(float(np.median([v for k in range(1, args.chunk_tokens) for v in pos_err[k]]))) if n_same else None,
           "per_position_median": [clean(float(np.median(pos_err[k]))) if pos_err[k] else None for k in range(args.chunk_tokens)],
           "token_corr_p10": clean(float(np.percentile(corr_all, 10))) if corr_all else None}
    out[f"_pair {a} vs {b}"] = rep

json.dump(out, open(args.out, "w"), ensure_ascii=False, indent=1)

cols = ["pair_sim_cam", "pair_p10_cam", "sim_anchor_cam", "sim_real_cam", "pair_sim_res", "sim_anchor_res", "within_min",
        "f0_spread", "f0_within", "rate", "first_audible", "rtf"]
print(f"\n真声彼此相似度：Resemblyzer {baseline['real_pairwise_res']:.3f}" + (f"  CAM++ {baseline['real_pairwise_cam']:.3f}" if cam else ""))
print(f"不计分的句子：{sorted(exclude)}\n")
print(f"{'设置':44s}" + "".join(f"{c[:12]:>13s}" for c in cols))
for c in configs:
    r = out[c]
    print(f"{c:44s}" + "".join(f"{(r.get(k) if r.get(k) is not None else float('nan')):13.3f}" for k in cols))
for k, v in out.items():
    if k.startswith("_pair"):
        print(f"\n{k}: {v}")
print(f"→ {args.out}")
