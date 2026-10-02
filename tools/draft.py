"""用AI把OCR出来的文字整理成 script.yaml 初稿。

用法（一般一套剧本杀是：DM手册 + 每人一本角色本 + 线索卡）：
  python -m tools.draft --out scripts/我的剧本 \\
      --dm work/DM手册.txt \\
      --char 周晴=work/周晴.txt --char 陆子川=work/陆子川.txt \\
      --clues work/线索卡.txt

  --char 可以写多次，“角色名=文件”。
  角色本按“第X幕”标题自动分幕，原文照搬，不经过AI改写。
  DM手册和线索卡交给AI提取：真相、流程、主持词、搜证地点、线索、凶手、结局。

生成的是初稿！一定要打开 script.yaml 人工检查，特别是：阶段顺序、每个搜证地点放了哪些线索、
真相是否完整、凶手是否正确。检查完运行：python -m jubensha.script scripts/我的剧本
"""
from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from jubensha.llm import LLM, LLMError, parse_json_reply  # noqa: E402

CHUNK = 6000
CN_NUM = "一二三四五六七八九十"
ACT_RE = re.compile(r"^\s*[【\[（(]?\s*第\s*([一二三四五六七八九十\d]+)\s*[幕章卷部]\s*[】\]）)]?.{0,20}$", re.M)
PAGE_RE = re.compile(r"^=== 第\d+页 ===$", re.M)


def clean(text: str) -> str:
    return PAGE_RE.sub("", text).strip()


def chunks(text: str, size: int = CHUNK) -> list[str]:
    paras, out, cur = text.split("\n"), [], ""
    for p in paras:
        if len(cur) + len(p) > size and cur:
            out.append(cur)
            cur = ""
        cur += p + "\n"
    if cur.strip():
        out.append(cur)
    return out


def cn2int(s: str) -> int:
    if s.isdigit():
        return int(s)
    if s == "十":
        return 10
    if s.startswith("十"):
        return 10 + CN_NUM.index(s[1]) + 1
    if "十" in s:
        a, _, b = s.partition("十")
        return (CN_NUM.index(a) + 1) * 10 + (CN_NUM.index(b) + 1 if b else 0)
    return CN_NUM.index(s) + 1


def split_acts(text: str) -> dict[str, str]:
    """按“第X幕”切分角色本；没有标题就整本当作 act1。"""
    marks = [(m.start(), cn2int(m.group(1))) for m in ACT_RE.finditer(text)]
    if not marks:
        return {"act1": text.strip()}
    acts: dict[str, str] = {}
    pre = text[: marks[0][0]].strip()
    for i, (pos, n) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        body = text[pos:end].strip()
        key = f"act{n}"
        acts[key] = (acts.get(key, "") + "\n\n" + body).strip()
    if pre:   # 第一幕之前的内容（人物介绍等）并进第一幕
        first = next(iter(acts))
        acts[first] = pre + "\n\n" + acts[first]
    return acts


# ---------------- AI 提取 ----------------
DM_PROMPT = """你在帮人把剧本杀的DM手册整理成结构化数据。下面是DM手册的第{i}/{n}段（OCR识别，可能有错字，请按上下文纠正）。
请提取本段中出现的信息，输出JSON（本段没有的字段给空字符串/空数组）：
{{
  "truth": "本段涉及的案件真相、作案经过、完整时间线（尽量完整保留细节）",
  "murderer": "凶手的角色名（本段没提到就空）",
  "style": "对主持风格的要求",
  "phases": [
    {{"title": "阶段名", "type": "narration/reading/discuss/search/vote/reveal 之一",
      "minutes": 建议时长数字或0,
      "dm_script": "主持人需要对玩家念的原话（尽量保留原文）",
      "dm_notes": "只给主持人看的提示、注意事项",
      "unlock": "这个阶段让玩家阅读第几幕，如'第一幕'，没有就空",
      "points": 每人搜证次数或0,
      "locations": [{{"name": "搜证地点", "clues": ["该地点可搜到的线索标题"]}}]
    }}
  ],
  "clues": [{{"title": "线索标题", "text": "线索内容原文", "location": "所在地点", "round": 第几轮搜证或0}}],
  "endings": {{"correct": "投对凶手的结局", "wrong": "投错的结局"}}
}}
type 判断：念开场/背景=narration，读剧本=reading，自我介绍/讨论=discuss，搜证=search，投票=vote，复盘/揭晓真相=reveal。
只输出JSON。

{text}"""

CLUE_PROMPT = """下面是剧本杀线索卡的OCR文字（第{i}/{n}段，可能有错字，请纠正）。提取每一张线索卡，输出JSON：
{{"clues": [{{"title": "线索标题", "text": "线索内容原文", "location": "搜到的地点（卡上有写的话）", "round": 第几轮或0}}]}}
只输出JSON。

{text}"""

CHAR_PROMPT = """下面是剧本杀角色「{name}」的角色本（OCR文字，可能有错字）。输出JSON：
{{"public": "50字以内的公开简介：身份、和死者关系。不能包含任何秘密",
  "secret_brief": "150字以内，只给AI主持人看：这个角色隐瞒了什么、案发时的真实行踪、是否是凶手、有什么需要守住的秘密"}}
只输出JSON。

{text}"""


async def ask_json(llm: LLM, prompt: str, label: str) -> dict:
    try:
        raw = await llm.chat([{"role": "user", "content": prompt}], max_tokens=4000)
    except LLMError as e:
        print(f"  ⚠ {label} 失败：{e}")
        return {}
    d = parse_json_reply(raw)
    if "reply" in d and len(d) == 1:
        print(f"  ⚠ {label}：AI没有按JSON格式输出，这部分需要手动整理")
        return {}
    return d


def merge_phase(a: dict, b: dict) -> dict:
    for k, v in b.items():
        if isinstance(v, str) and len(v) > len(str(a.get(k) or "")):
            a[k] = v
        elif isinstance(v, (int, float)) and v and not a.get(k):
            a[k] = v
        elif isinstance(v, list) and v:
            a[k] = (a.get(k) or []) + v
    return a


def norm(s: str) -> str:
    return re.sub(r"[\s【】\[\]（）()《》“”\"'：:，,。.]", "", s or "")


class Block(str):
    pass


def block_repr(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|" if "\n" in data else None)


yaml.add_representer(Block, block_repr, Dumper=yaml.SafeDumper)


def B(s: str):
    s = (s or "").strip()
    return Block(s + "\n") if "\n" in s else s


async def main_async(a):
    cfg_path = Path(a.config)
    if not cfg_path.exists():
        raise SystemExit("需要先配置 config.yaml（llm 部分），整理剧本要用AI。")
    cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
    llm = LLM({**(cfg.get("llm") or {}), "max_tokens": 4000})
    print(f"使用模型：{llm.label}")

    # ---- 角色本：原文分幕 ----
    characters, all_acts = [], []
    for i, spec in enumerate(a.char, 1):
        if "=" not in spec:
            raise SystemExit(f"--char 格式应为 角色名=文件，收到：{spec}")
        name, path = spec.split("=", 1)
        text = clean(Path(path).read_text(encoding="utf-8"))
        acts = split_acts(text)
        for k in acts:
            if k not in all_acts:
                all_acts.append(k)
        print(f"角色本《{name}》：{len(text)}字，分成 {len(acts)} 幕（{', '.join(acts)}）")
        sample = text[:7000] + ("\n……\n" + text[-2500:] if len(text) > 9500 else "")
        info = await ask_json(llm, CHAR_PROMPT.format(name=name, text=sample), f"角色《{name}》简介")
        characters.append({"id": f"r{i}", "name": name.strip(),
                           "public": info.get("public", "") or "TODO：公开简介",
                           "secret_brief": info.get("secret_brief", "") or "TODO：给AI看的秘密摘要",
                           "book": {k: B(v) for k, v in acts.items()}})
    all_acts.sort(key=lambda k: int(k[3:]) if k[3:].isdigit() else 99)

    # ---- DM手册 ----
    truth_parts, phases, clues_raw = [], [], []
    murderer, style, endings = "", "", {"correct": "", "wrong": ""}
    if a.dm:
        text = clean(Path(a.dm).read_text(encoding="utf-8"))
        cs = chunks(text)
        print(f"DM手册：{len(text)}字，分 {len(cs)} 段交给AI")
        for i, c in enumerate(cs, 1):
            d = await ask_json(llm, DM_PROMPT.format(i=i, n=len(cs), text=c), f"DM手册第{i}段")
            print(f"  第{i}/{len(cs)}段：{len(d.get('phases') or [])}个阶段，{len(d.get('clues') or [])}条线索")
            if d.get("truth"):
                truth_parts.append(str(d["truth"]))
            murderer = murderer or str(d.get("murderer") or "")
            style = style or str(d.get("style") or "")
            for k in ("correct", "wrong"):
                v = (d.get("endings") or {}).get(k)
                if v and len(v) > len(endings[k]):
                    endings[k] = v
            for p in d.get("phases") or []:
                if not isinstance(p, dict) or not p.get("title"):
                    continue
                same = next((x for x in phases if norm(x["title"]) == norm(p["title"])), None)
                if same:
                    merge_phase(same, p)
                else:
                    phases.append(p)
            clues_raw += [c for c in d.get("clues") or [] if isinstance(c, dict) and c.get("title")]

    # ---- 线索卡 ----
    for path in a.clues:
        text = clean(Path(path).read_text(encoding="utf-8"))
        cs = chunks(text)
        print(f"线索卡 {Path(path).name}：{len(text)}字，分 {len(cs)} 段")
        for i, c in enumerate(cs, 1):
            d = await ask_json(llm, CLUE_PROMPT.format(i=i, n=len(cs), text=c), f"线索卡第{i}段")
            clues_raw += [x for x in d.get("clues") or [] if isinstance(x, dict) and x.get("title")]

    # ---- 合并线索 ----
    clues: list[dict] = []
    for c in clues_raw:
        same = next((x for x in clues if norm(x["title"]) == norm(c["title"])), None)
        if same:
            if len(str(c.get("text") or "")) > len(same["text"]):
                same["text"] = str(c["text"])
            same["location"] = same["location"] or str(c.get("location") or "")
            same["round"] = same["round"] or int(c.get("round") or 0)
        else:
            clues.append({"id": f"c{len(clues) + 1}", "title": str(c["title"]).strip(), "text": str(c.get("text") or ""),
                          "location": str(c.get("location") or ""), "round": int(c.get("round") or 0)})

    def find_clue(title: str):
        t = norm(title)
        return next((c for c in clues if norm(c["title"]) == t), None) or \
            next((c for c in clues if t and (t in norm(c["title"]) or norm(c["title"]) in t)), None)

    # ---- 组装阶段 ----
    if not phases:
        phases = [{"title": "开场", "type": "narration", "dm_script": "TODO"},
                  {"title": "阅读第一幕", "type": "reading", "unlock": "第一幕"},
                  {"title": "搜证", "type": "search", "points": 2, "locations": []},
                  {"title": "讨论", "type": "discuss"},
                  {"title": "投票", "type": "vote"}, {"title": "复盘", "type": "reveal"}]
    out_phases, used, search_n, reading_n = [], set(), 0, 0
    for i, p in enumerate(phases, 1):
        ptype = p.get("type") if p.get("type") in {"narration", "reading", "discuss", "search", "vote", "reveal"} else "discuss"
        ph = {"id": f"p{i}", "title": str(p["title"]), "type": ptype, "minutes": int(p.get("minutes") or 0)}
        if p.get("dm_script"):
            ph["dm_script"] = B(str(p["dm_script"]))
        if p.get("dm_notes"):
            ph["dm_notes"] = B(str(p["dm_notes"]))
        # 解锁哪一幕
        unlock = str(p.get("unlock") or "")
        m = re.search(r"第\s*([一二三四五六七八九十\d]+)\s*[幕章]", unlock)
        if m:
            ph["unlock"] = f"act{cn2int(m.group(1))}"
        elif ptype == "reading" and reading_n < len(all_acts):
            ph["unlock"] = all_acts[reading_n]
        if ptype == "reading":
            reading_n += 1
        if ptype == "search":
            search_n += 1
            locs = []
            for l in p.get("locations") or []:
                ids = []
                for t in l.get("clues") or []:
                    c = find_clue(str(t))
                    if c and c["id"] not in used:
                        ids.append(c["id"])
                        used.add(c["id"])
                locs.append({"name": str(l.get("name") or "未命名地点"), "clues": ids})
            # 线索卡上写了轮次/地点、但DM手册没列出的，补进去
            for c in clues:
                if c["id"] in used or (c["round"] and c["round"] != search_n) or (not c["round"] and not c["location"]):
                    continue
                if not c["round"] and search_n > 1:
                    continue
                loc = next((l for l in locs if c["location"] and norm(c["location"]) == norm(l["name"])), None)
                if not loc:
                    loc = {"name": c["location"] or "其他", "clues": []}
                    locs.append(loc)
                loc["clues"].append(c["id"])
                used.add(c["id"])
            ph["search"] = {"points": int(p.get("points") or 2),
                            "locations": [{"id": f"l{search_n}_{j}", **l} for j, l in enumerate(locs, 1)]}
        if ptype == "vote":
            ph["vote"] = {"question": "谁是凶手？"}
            mm = next((c for c in characters if murderer and (c["name"] in murderer or murderer in c["name"])), None)
            if mm:
                ph["vote"]["answer"] = mm["id"]
        out_phases.append(ph)
    if not any(p["type"] == "reveal" for p in out_phases):
        out_phases.append({"id": f"p{len(out_phases) + 1}", "title": "真相复盘", "type": "reveal"})

    mname = next((c["name"] for c in characters if murderer and (c["name"] in murderer or murderer in c["name"])), murderer)
    forbidden = [f"凶手是{mname}", f"{mname}是凶手", f"{mname}就是凶手", f"是{mname}杀的", f"{mname}杀了"] if mname else []

    script = {
        "meta": {"title": a.title or Path(a.out).name, "players": len(characters), "intro": "TODO：一句话简介（所有人可见）"},
        "dm": {"truth": B("\n\n".join(truth_parts) or "TODO：完整真相"),
               "style": B(style or "语气沉稳，有悬念感。不抢玩家的推理。"),
               "forbidden": forbidden},
        "characters": characters,
        "clues": [{k: (B(v) if k == "text" else v) for k, v in c.items() if k in ("id", "title", "text")} for c in clues],
        "phases": out_phases,
        "endings": {k: B(v) for k, v in endings.items() if v},
    }
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    target = out / "script.yaml"
    if target.exists() and not a.force:
        target = out / "script.draft.yaml"
        print(f"\n{out / 'script.yaml'} 已存在，初稿写到 {target}（加 --force 覆盖）")
    header = ("# 由 tools/draft.py 自动生成的初稿，请人工检查！\n"
              "# 重点：阶段顺序 / 每个搜证地点的线索 / 真相是否完整 / 凶手(vote.answer) / forbidden 防剧透词\n"
              "# 检查命令：python -m jubensha.script " + str(out) + "\n\n")
    target.write_text(header + yaml.safe_dump(script, allow_unicode=True, sort_keys=False, width=100000),
                      encoding="utf-8")
    unused = [c for c in clues if c["id"] not in used]
    print(f"\n写入 {target}")
    print(f"  {len(characters)}个角色 · {len(out_phases)}个阶段 · {len(clues)}条线索 · 凶手：{mname or '未识别'}")
    if unused:
        print(f"  ⚠ {len(unused)}条线索没分配到搜证地点：{', '.join(c['title'] for c in unused[:8])}"
              "（可以放进某阶段的 search.locations 或 grantable，或留给管理员手动发）")
    from jubensha.script import ScriptError, load_script, validate
    try:
        for lvl, msg in validate(load_script(target)):
            print(f"  [{lvl}] {msg}")
    except ScriptError as e:
        print(e)


def main():
    ap = argparse.ArgumentParser(description="OCR文字 → script.yaml 初稿")
    ap.add_argument("--out", required=True, help="输出剧本文件夹，如 scripts/我的剧本")
    ap.add_argument("--dm", help="DM手册文字")
    ap.add_argument("--char", action="append", default=[], help="角色名=角色本文字文件，可多次")
    ap.add_argument("--clues", action="append", default=[], help="线索卡文字，可多次")
    ap.add_argument("--title")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--config", default=str(ROOT / "config.yaml"))
    a = ap.parse_args()
    if not a.char:
        raise SystemExit("至少需要一个 --char 角色名=文件")
    asyncio.run(main_async(a))


if __name__ == "__main__":
    main()
