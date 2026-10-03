#!/usr/bin/env python3
"""给变声结果打分，挑最好的一版。

  像不像（在 seed-vc 目录下用 seedvc-venv）：
    python score_voice.py sim --ref-dir 角色录音文件夹 --out sim.json 文件1.wav 文件2.wav ...
  咬字清不清（用 .venv，Whisper 识别后按拼音比对原文）：
    python score_voice.py asr --whisper <whisper模型> --texts sentences.json --out asr.json 文件1.wav ...

文件名是 NN.wav，NN 对应 sentences.json 里第 NN 句（从 1 开始）。
"""
import argparse
import glob
import json
import os
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["sim", "asr"])
ap.add_argument("files", nargs="+")
ap.add_argument("--out", required=True)
ap.add_argument("--ref-dir")
ap.add_argument("--whisper")
ap.add_argument("--texts")
args = ap.parse_args()


def sim_scores():
    sys.path.insert(0, os.getcwd())
    import librosa
    import numpy as np
    import torch
    import torchaudio
    from hf_utils import load_custom_model_from_hf
    from modules.campplus.DTDNN import CAMPPlus

    m = CAMPPlus(feat_dim=80, embedding_size=192)
    m.load_state_dict(torch.load(load_custom_model_from_hf("funasr/campplus", "campplus_cn_common.bin", None), map_location="cpu"))
    m.eval()

    @torch.no_grad()
    def emb(path):
        w = torch.tensor(librosa.load(path, sr=16000)[0]).unsqueeze(0)
        f = torchaudio.compliance.kaldi.fbank(w, num_mel_bins=80, dither=0, sample_frequency=16000)
        e = m((f - f.mean(dim=0, keepdim=True)).unsqueeze(0))[0].numpy()
        return e / (np.linalg.norm(e) + 1e-9)

    refs = np.stack([emb(p) for p in sorted(glob.glob(os.path.join(args.ref_dir, "*.wav")))])
    c = refs.mean(0)
    c /= np.linalg.norm(c)
    real = float(np.median(refs @ c))
    out = {"_real_median": real}
    for p in args.files:
        out[p] = float(emb(p) @ c)
    return out


def asr_scores():
    from mlx_audio.stt.utils import load_model
    from pypinyin import lazy_pinyin

    texts = json.load(open(args.texts, encoding="utf-8"))
    stt = load_model(args.whisper)

    def syl(s):
        s = re.sub(r"[^一-鿿0-9A-Za-z]", "", s)
        return lazy_pinyin(s)

    def dist(a, b):
        d = list(range(len(b) + 1))
        for i in range(1, len(a) + 1):
            prev, d[0] = d[0], i
            for j in range(1, len(b) + 1):
                prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
        return d[len(b)]

    out = {}
    for p in args.files:
        n = int(re.sub(r"\D", "", os.path.basename(p)) or 0)
        ref = texts[n - 1]
        hyp = stt.generate(p, language="zh", verbose=False).text.strip()
        a, b = syl(ref), syl(hyp)
        out[p] = {"text": hyp, "err": dist(a, b) / max(1, len(a))}
        print(f"{out[p]['err']:.2f}  {hyp}  ←  {p}", flush=True)
    return out


res = sim_scores() if args.mode == "sim" else asr_scores()
with open(args.out, "w", encoding="utf-8") as f:
    json.dump(res, f, ensure_ascii=False, indent=1)
print(f"→ {args.out}")
