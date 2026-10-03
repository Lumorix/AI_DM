#!/usr/bin/env python3
"""Seed-VC 变声：把一段普通话录音变成角色的音色（在 seed-vc 目录下用 seedvc-venv 运行）。

  python vc.py --checkpoint runs/yachiyo/ft_model.pth --config <yml> --ref 参考.wav \
      --src 源录音.wav [源录音2.wav ...] --out 输出文件夹 [--steps 30] [--cfg 0.7]

也可以 import：vc = VC(checkpoint, config); wave = vc.convert(src_wave_22k, ref_path)
"""
import argparse
import os
import sys
import time

os.environ.setdefault("HF_HUB_CACHE", "./checkpoints/hf_cache")
sys.path.insert(0, os.getcwd())

import warnings  # noqa: E402

warnings.simplefilter("ignore")

import librosa  # noqa: E402
import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
import torchaudio  # noqa: E402

import inference as sv  # noqa: E402  seed-vc 自带的 inference.py（加载模型的代码）


class VC:
    def __init__(self, checkpoint, config, fp16=True):
        args = argparse.Namespace(f0_condition=False, checkpoint=checkpoint, config=config, fp16=fp16)
        (self.model, self.semantic_fn, _, self.vocoder, self.campplus,
         self.to_mel, mel_args) = sv.load_models(args)
        self.sr = mel_args["sampling_rate"]
        self.device = sv.device
        self.fp16 = fp16
        self._ref_key = None

    def load_checkpoint(self, checkpoint):
        """换一个训练出来的权重（同一个配置），不用重新加载其它模型"""
        self.model, _, _, _ = sv.load_checkpoint(self.model, None, checkpoint, load_only_params=True,
                                                 ignore_modules=[], is_distributed=False)
        for k in self.model:
            self.model[k].eval().to(self.device)
        self.model.cfm.estimator.setup_caches(max_batch_size=1, max_seq_length=8192)

    @torch.no_grad()
    def _prepare_ref(self, ref_path):
        if self._ref_key == ref_path:
            return
        ref = librosa.load(ref_path, sr=self.sr)[0][: self.sr * 25]
        ref = torch.tensor(ref).unsqueeze(0).float().to(self.device)
        ref16 = torchaudio.functional.resample(ref, self.sr, 16000)
        self.mel2 = self.to_mel(ref)
        feat = torchaudio.compliance.kaldi.fbank(ref16, num_mel_bins=80, dither=0, sample_frequency=16000)
        self.style2 = self.campplus((feat - feat.mean(dim=0, keepdim=True)).unsqueeze(0))
        s_ori = self.semantic_fn(ref16)
        self.prompt, *_ = self.model.length_regulator(s_ori, ylens=torch.LongTensor([self.mel2.size(2)]).to(self.device),
                                                      n_quantizers=3, f0=None)
        self._ref_key = ref_path

    @torch.no_grad()
    def convert(self, src, ref_path, steps=30, cfg=0.7, length_adjust=1.0):
        """src：采样率 self.sr 的单声道 numpy；返回同采样率的 numpy"""
        self._prepare_ref(ref_path)
        src = torch.tensor(src).unsqueeze(0).float().to(self.device)
        src16 = torchaudio.functional.resample(src, self.sr, 16000)
        s_alt = self.semantic_fn(src16[:, : 16000 * 30])
        mel = self.to_mel(src)
        cond, *_ = self.model.length_regulator(s_alt, ylens=torch.LongTensor([int(mel.size(2) * length_adjust)]).to(self.device),
                                               n_quantizers=3, f0=None)
        cat = torch.cat([self.prompt, cond], dim=1)
        with torch.autocast(device_type=self.device.type, dtype=torch.float16 if self.fp16 else torch.float32):
            out = self.model.cfm.inference(cat, torch.LongTensor([cat.size(1)]).to(self.device), self.mel2,
                                           self.style2, None, steps, inference_cfg_rate=cfg)
            out = out[:, :, self.mel2.size(-1):]
        return self.vocoder(out.float()).squeeze().cpu().numpy()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", nargs="+", required=True, help="可以给多个，逐个转换对比")
    ap.add_argument("--config", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--src", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--steps", type=int, nargs="+", default=[30])
    ap.add_argument("--cfg", type=float, default=0.7)
    args = ap.parse_args()

    vc = VC(args.checkpoint[0], args.config)
    for ck in args.checkpoint:
        if ck != args.checkpoint[0]:
            vc.load_checkpoint(ck)
        tag = os.path.splitext(os.path.basename(ck))[0]
        for steps in args.steps:
            d = os.path.join(args.out, f"{tag}_s{steps}")
            os.makedirs(d, exist_ok=True)
            for src in args.src:
                wav = librosa.load(src, sr=vc.sr)[0]
                t = time.time()
                y = vc.convert(wav, args.ref, steps=steps, cfg=args.cfg)
                rtf = (time.time() - t) / (len(y) / vc.sr)
                p = os.path.join(d, os.path.basename(src))
                sf.write(p, y / max(1e-6, float(np.abs(y).max())) * 0.9, vc.sr, subtype="PCM_16")
                print(f"{p}  RTF {rtf:.2f}", flush=True)


if __name__ == "__main__":
    main()
