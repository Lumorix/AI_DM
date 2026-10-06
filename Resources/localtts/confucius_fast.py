#!/usr/bin/env python3
"""Confucius4-TTS（网易有道，跨语种克隆）的提速封装：参考录音的特征只算一次；音色阶段用较短的参考片段、较少步数；声码器用半精度。

  from confucius_fast import FastConfucius
  tts = FastConfucius("models/Confucius4-TTS-mlx-int8", "ref.wav", prompt_seconds=5, steps=10, half_vocoder=True)
  wav, sr = tts.generate("各位侦探，欢迎来到六角馆。", seed=1)
"""
import time

import mlx.core as mx
import numpy as np
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio

import mlx_audio.tts.models.confucius4.confucius4 as C


class FastConfucius:
    def __init__(self, model_path, ref_path, prompt_seconds=0.0, steps=25, half_vocoder=False, cfg=0.7,
                 temperature=0.8, top_k=30, top_p=0.8, repetition_penalty=10.0, model=None):
        self.m = model or load_model(model_path)
        self.steps, self.cfg = steps, cfg
        self.sampling = dict(temperature=temperature, top_k=top_k, top_p=top_p, rep_pen=repetition_penalty)
        if half_vocoder and not getattr(self.m.voc, "_half", False):
            self.m.voc.W = {k: v.astype(mx.float16) for k, v in self.m.voc.W.items()}
            self.m.voc._half = True
        audio = np.asarray(load_audio(ref_path, sample_rate=16000))
        m = self.m
        feats = m._fbank(mx.array(audio), m._mel, m._win)
        h17 = np.array(m.w2v.hidden17(feats))
        self.cond_emb = m.prefix.cond_emb(mx.array((h17 - m.stats["mean"]) / m.stats["std"]))
        self.style = mx.array(np.array(m.camp.inference(mx.array(audio))).reshape(1, 192))
        # 音色阶段的参考：只取开头一段（越短越快），音色向量和内容提示仍用整段
        prompt_audio = audio[: int(prompt_seconds * 16000)] if prompt_seconds else audio
        self.ref_mel = mx.array(C._ref_mel(prompt_audio))
        mx.eval(self.cond_emb, self.style, self.ref_mel)
        self.sample_rate = m.sample_rate

    def generate(self, text, seed=0, timings=None):
        m = self.m
        t0 = time.time()
        ids = m._tok.encode(f"You are a helpful assistant. {C.LANGUAGE_TOKEN['zh']}:{text}").ids
        text_emb = m.prefix.text_emb(mx.array([ids]))
        codes, latent = m.t2s.generate(self.cond_emb, text_emb, seed=seed, **self.sampling)
        t1 = time.time()
        T_ref = self.ref_mel.shape[1]
        mu = m.s2a.build_mu(mx.array(codes[None]), mx.array(latent), T_ref)
        mx.random.seed(seed)
        z = mx.random.normal((1, 80, mu.shape[1]))
        mel = m.s2a.solve_euler(z, mx.transpose(self.ref_mel, (0, 2, 1)), mu, self.style,
                                mx.linspace(0, 1, self.steps + 1), cfg=self.cfg)[:, :, T_ref:]
        mx.eval(mel)
        t2 = time.time()
        voc_in = mel.astype(mx.float16) if getattr(m.voc, "_half", False) else mel
        wav = m.voc(voc_in)
        mx.eval(wav)
        y = np.array(wav.astype(mx.float32)).reshape(-1)
        t3 = time.time()
        if timings is not None:
            timings.update(t2s=t1 - t0, s2a=t2 - t1, vocoder=t3 - t2, total=t3 - t0, audio=len(y) / self.sample_rate, codes=len(codes))
        return y, self.sample_rate
