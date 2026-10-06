#!/usr/bin/env python3
"""音色一致性调参：用同一组句子跑多种合成设置，每句单独合成（和 App 里一样），存成 wav 供打分。

  .venv/bin/python tune_voice.py --model <模型> --voice <音色文件夹> --out <输出文件夹> [--configs A,B,...] [--sets tune,hold]

每个设置一个子文件夹：<out>/<设置名>/<句子集>_<NN>.wav，另有 timing.json（每句第一段声音多久出来、RTF）。
设置名里：xvec = 只用音色向量（ref_text=None）；icl = 用“自参考”——这条音色自己之前念出的一句中文（<out>/anchor.wav + anchor.txt）
当参考录音和参考文本，每句都锚定在同一段中文发音上。
"""
import argparse
import json
import os
import sys
import time

import mlx.core as mx
import numpy as np
import soundfile as sf

SENTENCES = {
    "tune": [
        "各位侦探，欢迎来到六角馆。我是今晚的主持人，八千代。",
        "凶手，就在你们之中哦。请大家拿出手机，选择自己的角色吧。",
        "这个问题现在还不能回答，再仔细想想看吧。",
        "现在进入搜证环节，每个人可以调查两个地点。",
        "请注意，案发时间是晚上十一点到十二点之间。",
        "投票结束。真相只有一个，让我们一起揭晓吧！",
        "一年前的那个夜晚，台风封锁了整座小岛。",
        "你确定要公开这条线索吗？公开之后，所有人都能看到。",
    ],
    "hold": [
        "欢迎回来，我们接着玩《六角馆的谋杀鉴赏》。",
        "推理还原比例为十比零，预计时长七到九小时。",
        "在开始之前，请容许我做出几点说明。",
        "游戏过程中无需考虑动机，仅破解手法、锁定凶手即可。",
        "有人想对这个结论提出异议吗？",
        "很遗憾，这次投票并没有选出真正的凶手。",
        "斩首需要二十分钟，从客房到书房要走十分钟。",
        "好了，各位，休息十分钟，然后进入下一幕。",
    ],
}

SENTENCES["para"] = ["".join(SENTENCES["tune"][:4]), "".join(SENTENCES["tune"][4:])]   # 整段一次合成
SENTENCES["long"] = [     # 长句压力测试：看会不会越说越快、重复、念不完
    "在正式开始之前，我要先说明三条规则：第一，每个人在搜证阶段最多只能调查两个地点；第二，拿到的线索默认只有自己知道，想公开的话要在手机上点公开；第三，向我提问时请尽量具体，含糊的问题我可能没办法回答哦。",
    "一年前的那个夜晚，台风把整座小岛和外界彻底隔开，六角馆里的七个人谁也走不了，而第二天清晨，书房的门被人从里面锁上，窗外的脚印却只有一行通向悬崖，再也没有回来。",
    "好了，各位，现在请把手机放下，看着我。接下来我会按顺序宣布每个人的投票结果，然后揭晓真正的凶手是谁，以及那天晚上究竟发生了什么，请大家做好心理准备。",
    "短句。",
    "好。",
]

# 设置名 → 参数。bits：0 = 原始精度 bf16，8 = 8 位。
# 可选键：sub=(温度, top_k) 只给声学码本（1~15 号，主要决定音色）降温；fix_stream=True 修流式解码器在分块边界重复加偏置的 bug；
# icl="anchorN" 用 refs/ 里的中文自参考做 ICL，配 rp=重复惩罚（不写就走 generate()，被强制成 1.5）；ref="名字" 换 refs/ 里的另一段参考录音；sets=只跑哪些句子集
CONFIGS = {
    "A_xvec_t0.7_bf16_nostream": dict(bits=0, stream=False, temperature=0.7),
    "B_xvec_t0.7_8bit_stream":   dict(bits=8, stream=True, temperature=0.7),
    "C_xvec_t0.7_8bit_nostream": dict(bits=8, stream=False, temperature=0.7),
    "D_xvec_t0.7_bf16_stream":   dict(bits=0, stream=True, temperature=0.7),
    "E_xvec_t0.4_8bit_stream":   dict(bits=8, stream=True, temperature=0.4),
    "F_xvec_t0.2_8bit_stream":   dict(bits=8, stream=True, temperature=0.2),
    "G_xvec_t0.4_k20_p0.8_8bit_stream": dict(bits=8, stream=True, temperature=0.4, top_k=20, top_p=0.8),
    "H_icl_t0.7_8bit_stream":    dict(bits=8, stream=True, temperature=0.7, icl=True),
    "I_icl_t0.4_8bit_stream":    dict(bits=8, stream=True, temperature=0.4, icl=True),
    "J_icl_t0.4_8bit_nostream":  dict(bits=8, stream=False, temperature=0.4, icl=True),
    "K_xvec_t0.4_seed_8bit_stream": dict(bits=8, stream=True, temperature=0.4, seed=1234),
    "M_xvec_t0.4_8bit_stream1.0": dict(bits=8, stream=True, temperature=0.4, interval=1.0),
    # 同一个随机种子、只差流式/非流式：用来判断流式解码器本身有没有改变声音
    "Bs_xvec_t0.7_seed_8bit_stream":   dict(bits=8, stream=True, temperature=0.7, seed=4321),
    "Cs_xvec_t0.7_seed_8bit_nostream": dict(bits=8, stream=False, temperature=0.7, seed=4321),
    # ---- 第二轮 ----
    "N_subcool0.4k15_t0.7_8bit_stream": dict(bits=8, stream=True, temperature=0.7, sub=(0.4, 15)),
    "O_subargmax_t0.7_8bit_stream":     dict(bits=8, stream=True, temperature=0.7, sub=(0.0, 1)),
    "P_para_xvec_t0.7_8bit_stream":     dict(bits=8, stream=True, temperature=0.7, sets=["para"]),
    "Q_icl1_rp1.1_t0.7_8bit_stream":    dict(bits=8, stream=True, temperature=0.7, icl="anchor1", rp=1.1),
    "R_icl2_rp1.5_t0.7_8bit_stream":    dict(bits=8, stream=True, temperature=0.7, icl="anchor2"),
    "R2_icl2_rp1.1_t0.7_8bit_stream":   dict(bits=8, stream=True, temperature=0.7, icl="anchor2", rp=1.1),
    "R3_icl3_rp1.1_t0.7_8bit_stream":   dict(bits=8, stream=True, temperature=0.7, icl="anchor3", rp=1.1),
    "S_fix_xvec_t0.7_8bit_stream":      dict(bits=8, stream=True, temperature=0.7, fix_stream=True),
    "Ss_fix_xvec_t0.7_seed_8bit_stream": dict(bits=8, stream=True, temperature=0.7, seed=4321, fix_stream=True),
    "U_ref12_xvec_t0.7_8bit_stream":    dict(bits=8, stream=True, temperature=0.7, ref="ref_xvec_12s"),
    "V_ref8_xvec_t0.7_8bit_stream":     dict(bits=8, stream=True, temperature=0.7, ref="ref_xvec_8s"),
    "W_refnorm_xvec_t0.7_8bit_stream":  dict(bits=8, stream=True, temperature=0.7, ref="ref_cur_norm"),
    "X_icl2_rp1.1_subcool_fix_t0.7_8bit_stream": dict(bits=8, stream=True, temperature=0.7, icl="anchor2", rp=1.1, sub=(0.4, 15), fix_stream=True),
    "Y_icl2_rp1.1_fix_t0.5_k20_p0.9_8bit_stream": dict(bits=8, stream=True, temperature=0.5, top_k=20, top_p=0.9, icl="anchor2", rp=1.1, fix_stream=True),
    # ---- 第三轮：决赛（用测试集之外的新锚点 anchorP，每个设置跑两个种子）----
    "Z1_iclP_rp1.5_t0.4_fix_8bit_stream":   dict(bits=8, stream=True, temperature=0.4, icl="anchorP", fix_stream=True, seed=11),
    "Z1b_iclP_rp1.5_t0.4_fix_8bit_stream":  dict(bits=8, stream=True, temperature=0.4, icl="anchorP", fix_stream=True, seed=22),
    "Z2_iclP_rp1.1_t0.4_fix_8bit_stream":   dict(bits=8, stream=True, temperature=0.4, icl="anchorP", rp=1.1, fix_stream=True, seed=11),
    "Z2b_iclP_rp1.1_t0.4_fix_8bit_stream":  dict(bits=8, stream=True, temperature=0.4, icl="anchorP", rp=1.1, fix_stream=True, seed=22),
    "Z3_iclP_rp1.1_t0.7_fix_8bit_stream":   dict(bits=8, stream=True, temperature=0.7, icl="anchorP", rp=1.1, fix_stream=True, seed=11),
    "Z3b_iclP_rp1.1_t0.7_fix_8bit_stream":  dict(bits=8, stream=True, temperature=0.7, icl="anchorP", rp=1.1, fix_stream=True, seed=22),
    "Z4_iclP_rp1.1_t0.4_sub_fix_8bit_stream":  dict(bits=8, stream=True, temperature=0.4, icl="anchorP", rp=1.1, sub=(0.4, 15), fix_stream=True, seed=11),
    "Z4b_iclP_rp1.1_t0.4_sub_fix_8bit_stream": dict(bits=8, stream=True, temperature=0.4, icl="anchorP", rp=1.1, sub=(0.4, 15), fix_stream=True, seed=22),
    "Z5_iclP_rp1.1_t0.5_k20_p0.9_fix_8bit_stream":  dict(bits=8, stream=True, temperature=0.5, top_k=20, top_p=0.9, icl="anchorP", rp=1.1, fix_stream=True, seed=11),
    "Z5b_iclP_rp1.1_t0.5_k20_p0.9_fix_8bit_stream": dict(bits=8, stream=True, temperature=0.5, top_k=20, top_p=0.9, icl="anchorP", rp=1.1, fix_stream=True, seed=22),
    "Z0_xvec_t0.4_fix_8bit_stream":  dict(bits=8, stream=True, temperature=0.4, fix_stream=True, seed=11),    # 对照：不用 ICL 的最好设置
    "Z0b_xvec_t0.4_fix_8bit_stream": dict(bits=8, stream=True, temperature=0.4, fix_stream=True, seed=22),
    # 第四轮：用 Confucius4 念的、更像她本人的中文当 ICL 参考
    "QC1_iclCFq_rp1.1_t0.4_fix_8bit_stream": dict(bits=8, stream=True, temperature=0.4, icl="anchorCFq", rp=1.1, fix_stream=True, seed=11),
    "QC2_iclCFp_rp1.1_t0.4_fix_8bit_stream": dict(bits=8, stream=True, temperature=0.4, icl="anchorCFp", rp=1.1, fix_stream=True, seed=11),
    "QC1b_iclCFq_rp1.1_t0.4_fix_8bit_stream": dict(bits=8, stream=True, temperature=0.4, icl="anchorCFq", rp=1.1, fix_stream=True, seed=22),
    # 长句 / 极短句压力测试
    "L1_iclP_rp1.5_t0.4_fix_long": dict(bits=8, stream=True, temperature=0.4, icl="anchorP", fix_stream=True, sets=["long"]),
    "L2_iclP_rp1.1_t0.4_fix_long": dict(bits=8, stream=True, temperature=0.4, icl="anchorP", rp=1.1, fix_stream=True, sets=["long"]),
    "L3_iclP_rp1.05_t0.4_fix_long": dict(bits=8, stream=True, temperature=0.4, icl="anchorP", rp=1.05, fix_stream=True, sets=["long"]),
}

ap = argparse.ArgumentParser()
ap.add_argument("--model", required=True)
ap.add_argument("--voice", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--configs", default=",".join(CONFIGS))
ap.add_argument("--sets", default="tune,hold")
ap.add_argument("--anchor", default="", help="自参考用的 wav（默认用 A 设置的 tune_01）")
args = ap.parse_args()

from mlx_audio.tts.utils import load_model  # noqa: E402
from mlx_audio.utils import load_audio  # noqa: E402
from mlx_audio.tts.models.qwen3_tts import speech_tokenizer as st_mod  # noqa: E402

# ---- 补丁 1：流式解码器 DecoderBlockUpsample.step 在每个分块边界把卷积偏置加了两次（overlap-add 的 overflow 已含偏置）----
_orig_step = st_mod.DecoderBlockUpsample.step


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


def set_stream_fix(on):
    st_mod.DecoderBlockUpsample.step = _fixed_step if on else _orig_step


# ---- 补丁 2：只给声学码本（code predictor，1~15 号码本）降温。它的 _sample_token 调用不带 generated_tokens / suppress_tokens ----
def set_sub_sampling(m, sub):
    orig = m.__class__._sample_token
    if sub is None:
        m._sample_token = orig.__get__(m)
        return

    def patched(logits, temperature=0.9, top_k=50, top_p=1.0, repetition_penalty=1.05, repetition_context_size=64,
                generated_tokens=None, suppress_tokens=None, min_p=0.0):
        if generated_tokens is None and suppress_tokens is None:      # 声学码本
            temperature, top_k = sub
        return orig(m, logits, temperature=temperature, top_k=top_k, top_p=top_p, repetition_penalty=repetition_penalty,
                    repetition_context_size=repetition_context_size, generated_tokens=generated_tokens,
                    suppress_tokens=suppress_tokens, min_p=min_p)
    m._sample_token = patched

os.makedirs(args.out, exist_ok=True)
json.dump({k: v for k, v in SENTENCES.items()}, open(os.path.join(args.out, "sentences.json"), "w"), ensure_ascii=False, indent=1)
ref_wav = os.path.join(args.voice, "ref.wav")
sets = args.sets.split(",")
wanted = [c for c in args.configs.split(",") if c]
timing_path = os.path.join(args.out, "timing.json")
timing = json.load(open(timing_path)) if os.path.exists(timing_path) else {}

loaded = {}


def get_model(bits):
    """bf16 的设置先跑，之后原地量化成 8 位（不重新加载，内存里始终只有一份模型）"""
    if "m" not in loaded:
        loaded["m"], loaded["bits"] = load_model(args.model), 0
    if bits and loaded["bits"] != bits:
        if loaded["bits"]:
            sys.exit("同一次运行里不能从 8 位换回 bf16 / 换别的位数")
        import mlx.nn as nn
        nn.quantize(loaded["m"].talker, group_size=64, bits=bits,
                    class_predicate=lambda _, mod: isinstance(mod, (nn.Linear, nn.Embedding)) and mod.weight.shape[-1] % 64 == 0)
        mx.eval(loaded["m"].talker.parameters())
        loaded["bits"] = bits
    return loaded["m"]


def anchor(name=True):
    """自参考：这条音色自己念过的中文。True = A 设置念的第一句；"anchorN" = refs/anchorN.wav + .txt（挑出来拼好的）"""
    if name is True:
        p = args.anchor or os.path.join(args.out, "A_xvec_t0.7_bf16_nostream", "tune_01.wav")
        if not os.path.exists(p):
            sys.exit(f"自参考文件不存在，先跑 A 设置：{p}")
        return p, SENTENCES["tune"][0]
    p = os.path.join(args.out, "refs", f"{name}.wav")
    return p, open(p[:-4] + ".txt", encoding="utf-8").read().strip()


# 先跑 bf16 的，再跑 8 位的，少换一次模型
order = sorted(wanted, key=lambda c: (CONFIGS[c]["bits"] != 0, wanted.index(c)))
for name in order:
    cfg = CONFIGS[name]
    m = get_model(cfg["bits"])
    d = os.path.join(args.out, name)
    os.makedirs(d, exist_ok=True)
    if cfg.get("icl"):
        ref_audio, ref_text = anchor(cfg["icl"])
    elif cfg.get("ref"):
        ref_audio, ref_text = os.path.join(args.out, "refs", cfg["ref"] + ".wav"), None
    else:
        ref_audio, ref_text = ref_wav, None
    set_stream_fix(cfg.get("fix_stream", False))
    set_sub_sampling(m, cfg.get("sub"))
    icl_audio = load_audio(ref_audio, sample_rate=24000) if cfg.get("rp") else None
    for s in cfg.get("sets", sets):
        for i, text in enumerate(SENTENCES[s], 1):
            p = os.path.join(d, f"{s}_{i:02d}.wav")
            if os.path.exists(p):
                continue
            if "seed" in cfg:
                mx.random.seed(cfg["seed"] * 1000 + (0 if s == "tune" else 100) + i)      # 同一句话在不同设置里用同一个种子
            if cfg.get("rp"):           # 直接调 ICL 内部接口，绕开 generate() 把重复惩罚强制成 1.5
                gen = m._generate_icl(text=text, ref_audio=icl_audio, ref_text=ref_text, language="chinese",
                                      temperature=cfg["temperature"], top_k=cfg.get("top_k", 50), top_p=cfg.get("top_p", 1.0),
                                      repetition_penalty=cfg["rp"], stream=cfg["stream"], streaming_interval=cfg.get("interval", 0.5))
            else:
                kw = dict(text=text, ref_audio=ref_audio, ref_text=ref_text, lang_code="chinese",
                          temperature=cfg["temperature"], split_pattern="",
                          top_k=cfg.get("top_k", 50), top_p=cfg.get("top_p", 1.0))
                if cfg["stream"]:
                    kw.update(stream=True, streaming_interval=cfg.get("interval", 0.5))
                gen = m.generate(**kw)
            t0 = time.time()
            first = None
            parts = []
            tokens = 0
            for r in gen:
                a = np.array(r.audio, dtype=np.float32)
                if first is None:
                    first = time.time() - t0
                parts.append(a)
                tokens += int(getattr(r, "token_count", 0) or 0)
            total = time.time() - t0
            if not parts:        # 第一步就采到了结束符，什么都没念出来
                print(f"{name} {s}_{i:02d}: EMPTY output", flush=True)
                timing[f"{name}/{s}_{i:02d}"] = {"empty": True, "total": round(total, 2)}
                json.dump(timing, open(timing_path, "w"), ensure_ascii=False, indent=1)
                continue
            y = np.concatenate(parts)
            sf.write(p, y, m.sample_rate)
            timing[f"{name}/{s}_{i:02d}"] = {"first": round(first, 3), "total": round(total, 2), "tokens": tokens,
                                            "rp": cfg.get("rp", 1.5 if cfg.get("icl") else 1.05),
                                            "audio": round(len(y) / m.sample_rate, 2), "rtf": round(total / max(0.1, len(y) / m.sample_rate), 2)}
            print(f"{name} {s}_{i:02d}: first {first:.2f}s, {total:.1f}s for {len(y)/m.sample_rate:.1f}s audio, {tokens} tokens", flush=True)
            json.dump(timing, open(timing_path, "w"), ensure_ascii=False, indent=1)

set_stream_fix(False)
print("done")
