"""剧本加载与校验。剧本是一个文件夹，里面有 script.yaml，可选 assets/ 放线索图片。"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

PHASE_TYPES = {"narration", "reading", "discuss", "search", "vote", "reveal"}


class ScriptError(Exception):
    pass


@dataclass
class Clue:
    id: str
    title: str
    text: str
    public: bool = False          # 搜到后自动公开
    image: str | None = None      # 相对剧本文件夹的图片路径
    condition: str = ""           # 给AI看的发放条件（grantable 线索用）


@dataclass
class Character:
    id: str
    name: str
    public: str = ""              # 所有人可见的简介
    secret_brief: str = ""        # 只给AI：该角色的秘密摘要
    book: dict[str, str] = field(default_factory=dict)   # {幕id: 剧本正文}


@dataclass
class Location:
    id: str
    name: str
    clues: list[str]


@dataclass
class Phase:
    id: str
    title: str
    type: str
    minutes: int = 0
    dm_script: str = ""           # 本阶段主持词
    dm_notes: str = ""            # 只给AI的提示
    unlock: list[str] = field(default_factory=list)   # 本阶段解锁的角色本幕
    search_points: int = 0
    locations: list[Location] = field(default_factory=list)
    grantable: list[str] = field(default_factory=list)  # AI可以在问答中发放的线索
    vote_question: str = ""
    vote_answer: str | None = None


@dataclass
class Script:
    folder: Path
    title: str
    intro: str
    players: int
    truth: str
    style: str
    forbidden: list[str]
    characters: list[Character]
    clues: dict[str, Clue]
    phases: list[Phase]
    endings: dict[str, str]

    def character(self, cid: str) -> Character | None:
        return next((c for c in self.characters if c.id == cid), None)

    def clue(self, cid: str) -> Clue | None:
        return self.clues.get(cid)

    def unlocked_acts(self, phase_index: int) -> list[str]:
        acts: list[str] = []
        for p in self.phases[: phase_index + 1]:
            for a in p.unlock:
                if a not in acts:
                    acts.append(a)
        return acts


def _as_list(v) -> list[str]:
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    return [str(x) for x in v]


def _s(v) -> str:
    return "" if v is None else str(v).strip()


def load_script(folder: str | Path) -> Script:
    folder = Path(folder)
    path = folder / "script.yaml" if folder.is_dir() else folder
    if path.is_file() and folder.is_file():
        folder = folder.parent
    if not path.exists():
        raise ScriptError(f"找不到剧本文件：{path}")
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as e:
        raise ScriptError(f"YAML 格式错误（多半是缩进或冒号问题）：\n{e}") from e

    meta = raw.get("meta") or {}
    dm = raw.get("dm") or {}

    characters = []
    for c in raw.get("characters") or []:
        book = {str(k): _s(v) for k, v in (c.get("book") or {}).items()}
        characters.append(Character(
            id=str(c.get("id")), name=_s(c.get("name")), public=_s(c.get("public")),
            secret_brief=_s(c.get("secret_brief")), book=book))

    clues = {}
    for c in raw.get("clues") or []:
        clue = Clue(id=str(c.get("id")), title=_s(c.get("title")), text=_s(c.get("text")),
                    public=bool(c.get("public", False)), image=c.get("image"),
                    condition=_s(c.get("condition")))
        clues[clue.id] = clue

    phases = []
    for p in raw.get("phases") or []:
        search = p.get("search") or {}
        vote = p.get("vote") or {}
        locs = [Location(id=str(l.get("id")), name=_s(l.get("name")), clues=_as_list(l.get("clues")))
                for l in search.get("locations") or []]
        phases.append(Phase(
            id=str(p.get("id")), title=_s(p.get("title")) or str(p.get("id")),
            type=_s(p.get("type")) or "discuss", minutes=int(p.get("minutes") or 0),
            dm_script=_s(p.get("dm_script")), dm_notes=_s(p.get("dm_notes")),
            unlock=_as_list(p.get("unlock")), search_points=int(search.get("points") or 0),
            locations=locs, grantable=_as_list(p.get("grantable")),
            vote_question=_s(vote.get("question")) or "谁是凶手？",
            vote_answer=vote.get("answer")))

    script = Script(
        folder=folder, title=_s(meta.get("title")) or folder.name, intro=_s(meta.get("intro")),
        players=int(meta.get("players") or len(characters)), truth=_s(dm.get("truth")),
        style=_s(dm.get("style")), forbidden=_as_list(dm.get("forbidden")),
        characters=characters, clues=clues, phases=phases,
        endings={str(k): _s(v) for k, v in (raw.get("endings") or {}).items()})
    problems = validate(script)
    errors = [m for lvl, m in problems if lvl == "错误"]
    if errors:
        raise ScriptError("剧本有以下错误：\n- " + "\n- ".join(errors))
    return script


def validate(s: Script) -> list[tuple[str, str]]:
    """返回 [(级别, 信息)]，级别为 错误 / 提醒。"""
    out: list[tuple[str, str]] = []
    E = lambda m: out.append(("错误", m))
    W = lambda m: out.append(("提醒", m))

    if not s.characters:
        E("没有角色（characters）")
    if not s.phases:
        E("没有阶段（phases）")
    if not s.truth:
        W("dm.truth 为空：AI不知道真相，问答和复盘会很弱")

    ids = [c.id for c in s.characters]
    for dup in {i for i in ids if ids.count(i) > 1}:
        E(f"角色id重复：{dup}")
    all_acts = set()
    for c in s.characters:
        if not c.name:
            E(f"角色 {c.id} 没有 name")
        if not c.book:
            W(f"角色 {c.name or c.id} 没有角色本（book）")
        all_acts.update(c.book.keys())

    pids = [p.id for p in s.phases]
    for dup in {i for i in pids if pids.count(i) > 1}:
        E(f"阶段id重复：{dup}")

    unlocked = set()
    used_clues = set()
    for p in s.phases:
        if p.type not in PHASE_TYPES:
            E(f"阶段 {p.id} 的 type '{p.type}' 无效，可选：{', '.join(sorted(PHASE_TYPES))}")
        for a in p.unlock:
            unlocked.add(a)
            if a not in all_acts:
                W(f"阶段 {p.id} 解锁了幕 '{a}'，但没有任何角色本里有这一幕")
        if p.type == "search":
            if not p.locations:
                E(f"搜证阶段 {p.id} 没有搜证地点（search.locations）")
            if p.search_points <= 0:
                W(f"搜证阶段 {p.id} 的搜证次数（search.points）为0")
        for loc in p.locations:
            for cid in loc.clues:
                used_clues.add(cid)
                if cid not in s.clues:
                    E(f"阶段 {p.id} 地点 {loc.name} 引用了不存在的线索 {cid}")
        for cid in p.grantable:
            used_clues.add(cid)
            if cid not in s.clues:
                E(f"阶段 {p.id} 的 grantable 引用了不存在的线索 {cid}")
        if p.type == "vote" and p.vote_answer and p.vote_answer not in ids:
            W(f"投票阶段 {p.id} 的答案 '{p.vote_answer}' 不是角色id（如果答案不是角色，可以忽略）")

    for a in all_acts - unlocked:
        W(f"角色本里的幕 '{a}' 从来没有被任何阶段 unlock，玩家看不到")
    for cid in set(s.clues) - used_clues:
        W(f"线索 {cid}（{s.clues[cid].title}）没有放在任何地点或 grantable 里，只能由管理员手动发放")
    for cid, c in s.clues.items():
        if c.image and not (s.folder / c.image).exists():
            W(f"线索 {cid} 的图片不存在：{c.image}")
    if not any(p.type == "reveal" for p in s.phases):
        W("没有 reveal（复盘）阶段")
    return out


if __name__ == "__main__":
    # 用法：python -m jubensha.script scripts/我的剧本
    target = sys.argv[1] if len(sys.argv) > 1 else "scripts/demo"
    try:
        sc = load_script(target)
    except ScriptError as e:
        print(e)
        sys.exit(1)
    print(f"《{sc.title}》 {len(sc.characters)}个角色 · {len(sc.phases)}个阶段 · {len(sc.clues)}条线索")
    probs = validate(sc)
    for lvl, m in probs:
        print(f"[{lvl}] {m}")
    if not probs:
        print("没有发现问题 ✓")
