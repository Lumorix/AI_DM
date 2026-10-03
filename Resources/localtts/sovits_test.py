#!/usr/bin/env python3
"""用训练好的 GPT-SoVITS 权重生成几句试听（在 GPT-SoVITS 目录下用它的 Python 运行）。

  python sovits_test.py --gpt <ckpt> --sovits <pth> --ref ref.wav --ref-text "参考录音原话" --out 输出文件夹 [--ref-lang ja]
"""
import argparse
import os
import sys

import soundfile as sf

sys.path.insert(0, os.getcwd())
sys.path.insert(0, os.path.join(os.getcwd(), "GPT_SoVITS"))
from TTS_infer_pack.TTS import TTS, TTS_Config  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--gpt", required=True)
ap.add_argument("--sovits", required=True)
ap.add_argument("--ref", required=True)
ap.add_argument("--ref-text", required=True)
ap.add_argument("--ref-lang", default="ja")
ap.add_argument("--out", required=True)
ap.add_argument("--device", default="cpu")
args = ap.parse_args()

SENTENCES = [
    "各位侦探，欢迎来到六角馆。我是今晚的主持人，八千代。",
    "凶手，就在你们之中哦。请大家拿出手机，选择自己的角色吧。",
    "这个问题现在还不能回答，再仔细想想看吧。",
]

tts = TTS(TTS_Config({"custom": {
    "device": args.device, "is_half": False, "version": "v2ProPlus",
    "t2s_weights_path": args.gpt, "vits_weights_path": args.sovits,
    "bert_base_path": "GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large",
    "cnhuhbert_base_path": "GPT_SoVITS/pretrained_models/chinese-hubert-base",
}}))
os.makedirs(args.out, exist_ok=True)
for i, text in enumerate(SENTENCES, 1):
    sr, audio = next(tts.run({
        "text": text, "text_lang": "zh", "ref_audio_path": args.ref, "prompt_text": args.ref_text,
        "prompt_lang": args.ref_lang, "text_split_method": "cut5", "batch_size": 1, "top_k": 15, "top_p": 1,
        "temperature": 1, "repetition_penalty": 1.35, "parallel_infer": False, "seed": 1234,
    }))
    p = os.path.join(args.out, f"试听{i}.wav")
    sf.write(p, audio, sr)
    print(p, flush=True)
