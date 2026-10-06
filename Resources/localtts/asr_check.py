#!/usr/bin/env python3
"""普通话咬字检查：用 Whisper 把合成的句子听写出来，按拼音和原文比对（用 .venv）。

  .venv/bin/python asr_check.py --whisper <whisper模型> --tune <tune_voice 的输出文件夹> --out asr.json [--configs A,B] [--exclude tune_01]

每个设置：err = 平均音节错误率（不看声调；0 = 全部听对），tone_err = 连声调一起比的错误率，perfect = 全对的句数，
worst = 最差的一句和听写结果。所有设置都错的句子会单独列出来（多半是听写模型自己的问题，不算合成的错）。
听写时提示“以下是普通话”并给出专有名词，让 Whisper 尽量输出简体；残留的繁体用一张小表转回简体；数字先换成汉字；“两”和“二”算同一个。
"""
import argparse
import glob
import json
import os
import re
from collections import defaultdict

from mlx_audio.stt.utils import load_model
from pypinyin import Style, lazy_pinyin

ap = argparse.ArgumentParser()
ap.add_argument("--whisper", required=True)
ap.add_argument("--tune", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--configs", default="")
ap.add_argument("--exclude", default="")
args = ap.parse_args()

sentences = json.load(open(os.path.join(args.tune, "sentences.json"), encoding="utf-8"))
exclude = set(x for x in args.exclude.split(",") if x)
stt = load_model(args.whisper)
PROMPT = "以下是普通话的句子。六角馆、八千代、侦探、凶手、搜证、线索、投票、复盘。"
digits = "零一二三四五六七八九"
TRAD = str.maketrans(
    "還時長點間兩個們這問題現說請選擇證環節調結讓揭曉歲鎖島確條線開後體驗預計幾遊戲過無機僅議異遺並沒斬鐘從書進歡謀殺鑒賞許動兇麼嗎發颱風與偵館誰離續於為會來對學習裡頭聲音聽見視頻網絡電腦雲端數據據賬號登錄備註釋語備",
    "还时长点间两个们这问题现说请选择证环节调结让揭晓岁锁岛确条线开后体验预计几游戏过无机仅议异遗并没斩钟从书进欢谋杀鉴赏许动凶么吗发台风与侦馆谁离续于为会来对学习里头声音听见视频网络电脑云端数据据账号登录备注释语备")


def cn_num(m):
    n = int(m.group())
    if n < 10:
        return digits[n]
    if n < 100:
        return ("" if n < 20 else digits[n // 10]) + "十" + (digits[n % 10] if n % 10 else "")
    return "".join(digits[int(c)] for c in m.group())


def norm(s):
    s = s.translate(TRAD)
    s = re.sub(r"\d+", cn_num, s)
    s = s.replace("两", "二")
    return re.sub(r"[^一-鿿]", "", s)


def syl(s, tone=False):
    return lazy_pinyin(norm(s), style=Style.TONE3 if tone else Style.NORMAL)


def dist(a, b):
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
    return d[len(b)]


out, per_sentence = {}, defaultdict(dict)
configs = [c for c in sorted(os.listdir(args.tune)) if os.path.isdir(os.path.join(args.tune, c)) and c != "refs"]
if args.configs:
    configs = [c for c in configs if c in args.configs.split(",")]
for c in configs:
    errs, tones, worst = [], [], (0, "", "")
    for p in sorted(glob.glob(os.path.join(args.tune, c, "*.wav"))):
        m = re.match(r"^([a-z]+)_(\d+)\.wav$", os.path.basename(p))
        if not m or m.group(1) not in sentences or os.path.basename(p)[:-4] in exclude:
            continue
        ref = sentences[m.group(1)][int(m.group(2)) - 1]
        hyp = stt.generate(p, language="zh", verbose=False, temperature=0.0, condition_on_previous_text=False,
                           initial_prompt=PROMPT).text.strip()
        a = syl(ref)
        e = dist(a, syl(hyp)) / max(1, len(a))
        te = dist(syl(ref, True), syl(hyp, True)) / max(1, len(a))
        errs.append(e)
        tones.append(te)
        per_sentence[os.path.basename(p)[:-4]][c] = (e, hyp)
        if e > worst[0]:
            worst = (e, ref, hyp)
    if not errs:
        continue
    out[c] = {"err": round(sum(errs) / len(errs), 4), "tone_err": round(sum(tones) / len(tones), 4),
              "perfect": sum(1 for e in errs if e == 0), "n": len(errs),
              "worst_err": round(worst[0], 3), "worst_ref": worst[1], "worst_hyp": worst[2]}
    print(f"{c:44s} 音节错 {out[c]['err']:.3f}  声调错 {out[c]['tone_err']:.3f}  全对 {out[c]['perfect']}/{len(errs)}  最差: {worst[2]}", flush=True)

# 所有设置都错的句子 = 听写模型的问题（地板），单独列出
floor = {}
for sid, d in per_sentence.items():
    if len(d) == len(out) and all(e > 0 for e, _ in d.values()):
        floor[sid] = sorted(set(h for _, h in d.values()))[:3]
if floor:
    print("\n所有设置都听错的句子（多半是听写模型的问题，不算合成错）：")
    for sid, hs in floor.items():
        print(f"  {sid}: {hs}")
out["_floor"] = floor
json.dump(out, open(args.out, "w"), ensure_ascii=False, indent=1)
print(f"→ {args.out}")
