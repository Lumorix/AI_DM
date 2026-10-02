"""游戏引擎：流程由程序控制（状态机），AI 只负责说话和判断。"""
from __future__ import annotations

import asyncio
import re
import secrets
import time
from dataclasses import dataclass
from pathlib import Path

from . import prompts
from .llm import LLM, LLMError, parse_json_reply
from .script import Script
from .state import GameState, Player


# ---------------- 事件推送 ----------------
@dataclass
class Sub:
    audience: str              # "screen" / "admin" / "player:<char_id>"
    queue: asyncio.Queue


class Bus:
    def __init__(self):
        self.subs: list[Sub] = []

    def subscribe(self, audience: str) -> Sub:
        s = Sub(audience, asyncio.Queue())
        self.subs.append(s)
        return s

    def unsubscribe(self, s: Sub) -> None:
        if s in self.subs:
            self.subs.remove(s)

    def refresh(self) -> None:
        for s in self.subs:
            s.queue.put_nowait({"type": "refresh"})

    def send(self, event: dict, audiences: set[str] | None = None) -> None:
        for s in self.subs:
            if audiences is None or s.audience in audiences:
                s.queue.put_nowait(event)


def _norm(t: str) -> str:
    return re.sub(r"[\s，。,.！!？?：:“”\"'‘’、]", "", t)


class Game:
    def __init__(self, script: Script, state: GameState, llm: LLM, cfg: dict, save_path: Path,
                 cheap_llm: LLM | None = None):
        self.script = script
        self.state = state
        self.llm = llm
        self.cheap = cheap_llm or llm          # 摘要可以交给便宜/本地模型
        self.save_path = save_path
        gc = cfg.get("game", {}) or {}
        mem = gc.get("memory", {}) or {}
        self.narration_mode = gc.get("narration", "ai")          # ai / verbatim
        self.keep_recent = int(mem.get("keep_recent", 30))
        self.summarize_batch = int(mem.get("summarize_batch", 20))
        self.private_keep = int(mem.get("private_keep", 12))
        self.lock = asyncio.Lock()
        self.bus = Bus()
        self._narr_task: asyncio.Task | None = None
        self._sum_lock = asyncio.Lock()
        self.busy: set[str] = set()            # 正在等AI回答的玩家

    # ---------------- 基础 ----------------
    @property
    def phase(self):
        return self.script.phases[self.state.phase_index]

    def changed(self) -> None:
        self.state.save(self.save_path)
        self.bus.refresh()

    def name_of(self, char_id: str) -> str:
        p = self.state.players.get(char_id)
        c = self.script.character(char_id)
        return f"{c.name}" if c else (p.name if p else char_id)

    def leaks(self, text: str, exempt_char: str | None = None) -> str | None:
        """复盘前检查是否出现禁用词。私聊给角色本人时，涉及本人名字的禁用词不算（凶手本人知道自己是凶手）。"""
        if self.phase.type == "reveal":
            return None
        exempt_name = self.script.character(exempt_char).name if exempt_char and self.script.character(exempt_char) else None
        nt = _norm(text)
        for f in self.script.forbidden:
            if exempt_name and exempt_name in f:
                continue
            if _norm(f) and _norm(f) in nt:
                return f
        return None

    # ---------------- 玩家加入 ----------------
    async def join(self, char_id: str, name: str, token: str | None = None) -> Player:
        async with self.lock:
            if not self.script.character(char_id):
                raise ValueError("没有这个角色")
            existing = self.state.players.get(char_id)
            if existing:
                if (token and existing.token == token) or existing.claimable:
                    if existing.claimable:   # 换手机重新认领：继承原来的线索和进度
                        existing.token = secrets.token_urlsafe(12)
                        existing.claimable = False
                        self.state.log_public("system", "系统", f"{name or existing.name} 重新接管了角色【{self.name_of(char_id)}】")
                    existing.name = name.strip()[:12] or existing.name
                    self.changed()
                    return existing
                raise ValueError("这个角色已经被选了。如果是你本人换了手机，请让管理员在管理页面释放该角色。")
            p = Player(char_id=char_id, name=name.strip()[:12] or self.name_of(char_id),
                       token=secrets.token_urlsafe(12))
            if self.phase.type == "search":
                p.search_left = self.phase.search_points
            self.state.players[char_id] = p
            self.state.log_public("system", "系统", f"{p.name} 选择了角色【{self.name_of(char_id)}】")
            self.changed()
            return p

    async def release(self, char_id: str) -> None:
        async with self.lock:
            p = self.state.players.get(char_id)
            if p:
                # 不删数据：旧手机失效，新手机选这个角色时继承线索和进度
                p.token = "released-" + secrets.token_urlsafe(6)
                p.claimable = True
                self.state.log_public("system", "系统", f"角色【{self.name_of(char_id)}】已释放，可以在新手机上重新选择")
                self.changed()

    # ---------------- 阶段推进 ----------------
    async def goto(self, index: int, narrate: bool = True) -> None:
        async with self.lock:
            index = max(0, min(index, len(self.script.phases) - 1))
            forward = index > self.state.phase_index
            self.state.phase_index = index
            self.state.phase_started_at = time.time()
            ph = self.phase
            if ph.type == "search":
                for p in self.state.players.values():
                    p.search_left = ph.search_points
            else:
                for p in self.state.players.values():
                    p.search_left = 0
            self.state.log_public("system", "系统", f"—— 进入阶段：{ph.title} ——", ph.id)
            if ph.unlock and forward:
                self.state.log_public("system", "系统", "新的剧本内容已解锁，请在手机上查看。", ph.id)
            self.changed()
        # 换阶段时把记忆压缩一下
        asyncio.create_task(self.maybe_summarize(force=True))
        if narrate:
            self.start_narration()

    def start_narration(self) -> None:
        if self._narr_task and not self._narr_task.done():
            self._narr_task.cancel()
        ph = self.phase
        if ph.type == "reveal":
            self._narr_task = asyncio.create_task(self._reveal())
        elif ph.dm_script:
            self._narr_task = asyncio.create_task(self._narrate(ph.dm_script))

    async def _stream_public(self, messages: list[dict] | None, fallback: str, kind: str = "narration") -> str:
        """把一段话流式推到大屏和所有手机上，结束后写入公开记录。"""
        sid = secrets.token_hex(4)
        self.bus.send({"type": "stream_start", "id": sid, "who": "DM", "kind": kind})
        text = ""
        try:
            if messages is None or self.state.ai_paused:
                raise LLMError("verbatim")
            async for delta in self.llm.stream(messages, max_tokens=2500):
                text += delta
                self.bus.send({"type": "stream_delta", "id": sid, "text": delta})
        except asyncio.CancelledError:
            self.bus.send({"type": "stream_end", "id": sid, "cancelled": True})
            if text:
                self.state.log_public(kind, "DM", text + "……", self.phase.id)
                self.changed()
            raise
        except LLMError as e:
            if str(e) != "verbatim":
                self.state.warn(f"AI旁白失败，改为直接念原文：{e}")
            if not text:
                text = fallback
                self.bus.send({"type": "stream_delta", "id": sid, "text": fallback})
        self.bus.send({"type": "stream_end", "id": sid})
        if leak := self.leaks(text):
            self.state.warn(f"旁白里出现了禁用词「{leak}」，请检查剧本或改用原文念白（game.narration: verbatim）")
        self.state.log_public(kind, "DM", text, self.phase.id)
        self.changed()
        return text

    async def _narrate(self, script_text: str) -> None:
        msgs = None
        if self.narration_mode == "ai":
            msgs = prompts.narration_messages(self.script, self.state, self.phase, script_text)
        await self._stream_public(msgs, script_text)

    async def narrate_custom(self, text: str, polish: bool) -> None:
        msgs = prompts.narration_messages(self.script, self.state, self.phase, text) if polish else None
        if self._narr_task and not self._narr_task.done():
            self._narr_task.cancel()
        self._narr_task = asyncio.create_task(self._stream_public(msgs, text))

    # ---------------- 搜证 ----------------
    async def search(self, char_id: str, loc_id: str) -> dict:
        async with self.lock:
            ph = self.phase
            p = self.state.players[char_id]
            if ph.type != "search":
                return {"ok": False, "msg": "现在不是搜证阶段"}
            loc = next((l for l in ph.locations if l.id == loc_id), None)
            if not loc:
                return {"ok": False, "msg": "没有这个地点"}
            if p.search_left <= 0:
                return {"ok": False, "msg": "你本阶段的搜证次数已经用完了"}
            key = f"{ph.id}:{loc.id}"
            n = self.state.location_progress.get(key, 0)
            remaining = [c for c in loc.clues[n:]]
            if not remaining:
                return {"ok": False, "msg": f"{loc.name}已经搜不出新东西了（没有扣次数）"}
            cid = remaining[0]
            clue = self.script.clues[cid]
            self.state.location_progress[key] = n + 1
            p.search_left -= 1
            if cid not in p.clues:
                p.clues.append(cid)
            self.state.found_by.setdefault(cid, char_id)
            self.state.log_private(char_id, "clue", "搜证", f"在{loc.name}搜到【{clue.title}】：{clue.text}", ph.id)
            if clue.public and cid not in self.state.public_clues:
                self.state.public_clues.append(cid)
                self.state.log_public("clue", "线索", f"{self.name_of(char_id)} 在{loc.name}搜到【{clue.title}】（自动公开）：{clue.text}", ph.id)
            else:
                self.state.log_public("search", "搜证", f"{self.name_of(char_id)} 搜查了{loc.name}", ph.id)
            self.changed()
        asyncio.create_task(self.maybe_summarize())
        return {"ok": True, "clue": cid, "title": clue.title, "text": clue.text}

    async def publish_clue(self, char_id: str, cid: str) -> dict:
        async with self.lock:
            p = self.state.players[char_id]
            if cid not in p.clues:
                return {"ok": False, "msg": "你没有这条线索"}
            if cid in self.state.public_clues:
                return {"ok": False, "msg": "已经公开过了"}
            clue = self.script.clues[cid]
            self.state.public_clues.append(cid)
            self.state.log_public("clue", "线索", f"{self.name_of(char_id)} 公开了线索【{clue.title}】：{clue.text}", self.phase.id)
            self.changed()
        return {"ok": True}

    async def give_clue(self, target: str, cid: str) -> dict:
        """管理员手动发线索。target 为角色id，或 'public' 直接公开。"""
        async with self.lock:
            clue = self.script.clues.get(cid)
            if not clue:
                return {"ok": False, "msg": "没有这条线索"}
            if target == "public":
                if cid not in self.state.public_clues:
                    self.state.public_clues.append(cid)
                self.state.log_public("clue", "线索", f"DM 公开了线索【{clue.title}】：{clue.text}", self.phase.id)
            else:
                p = self.state.players.get(target)
                if not p:
                    return {"ok": False, "msg": "这个角色还没有玩家"}
                if cid not in p.clues:
                    p.clues.append(cid)
                self.state.found_by.setdefault(cid, target)
                self.state.log_private(target, "clue", "DM", f"你获得了线索【{clue.title}】：{clue.text}", self.phase.id)
                self.state.log_public("system", "系统", f"DM 给了 {self.name_of(target)} 一条线索", self.phase.id)
            self.changed()
        return {"ok": True}

    # ---------------- 问答 ----------------
    async def ask(self, char_id: str, question: str, public: bool) -> dict:
        question = question.strip()[:500]
        if not question:
            return {"ok": False, "msg": "问题是空的"}
        if char_id in self.busy:
            return {"ok": False, "msg": "DM还在回答你上一个问题"}
        who = self.name_of(char_id)
        async with self.lock:
            if public:
                self.state.log_public("ask", who, question, self.phase.id)
            else:
                self.state.log_private(char_id, "ask", who, question, self.phase.id)
            self.changed()

        if self.state.ai_paused:
            reply = "DM暂时离开了，请稍后再问，或直接问在场的管理员。"
            return await self._post_answer(char_id, reply, None, public)

        self.busy.add(char_id)
        self.bus.refresh()
        try:
            reply, give = "", None
            for attempt in range(2):
                msgs = prompts.ask_messages(self.script, self.state, self.phase, char_id, question, public,
                                            self.keep_recent, self.private_keep, strict=attempt > 0)
                try:
                    raw = await self.llm.chat(msgs, max_tokens=800)
                except LLMError as e:
                    self.state.warn(f"AI回答失败：{e}")
                    reply, give = "（DM这边网络有点问题，请稍后再问一次）", None
                    break
                data = parse_json_reply(raw)
                reply = str(data.get("reply") or "").strip() or "……"
                give = data.get("give_clue")
                leak = self.leaks(reply, exempt_char=None if public else char_id)
                if not leak:
                    break
                self.state.warn(f"拦截了一次可能的剧透（{who}问：{question[:30]}；命中「{leak}」）")
                reply, give = "这个问题现在还不能回答。继续推理吧。", None
            # 线索发放由程序把关：只能给本阶段 grantable 里、对方还没有的
            if give and isinstance(give, str):
                give = give.strip()
                ok = (give in self.phase.grantable and give in self.script.clues
                      and give not in self.state.players[char_id].clues and give not in self.state.public_clues)
                if not ok:
                    give = None
            else:
                give = None
            return await self._post_answer(char_id, reply, give, public)
        finally:
            self.busy.discard(char_id)
            self.bus.refresh()

    async def _post_answer(self, char_id: str, reply: str, give: str | None, public: bool) -> dict:
        async with self.lock:
            ph = self.phase.id
            if public:
                self.state.log_public("answer", "DM", f"（回答{self.name_of(char_id)}）{reply}", ph)
                self.bus.send({"type": "speak", "text": reply}, {"screen"})
            else:
                self.state.log_private(char_id, "answer", "DM", reply, ph)
            clue_info = None
            if give:
                clue = self.script.clues[give]
                p = self.state.players[char_id]
                p.clues.append(give)
                self.state.found_by.setdefault(give, char_id)
                self.state.log_private(char_id, "clue", "DM", f"你获得了线索【{clue.title}】：{clue.text}", ph)
                self.state.log_public("system", "系统", f"{self.name_of(char_id)} 从DM那里获得了一条线索", ph)
                clue_info = {"id": give, "title": clue.title, "text": clue.text}
            self.changed()
        asyncio.create_task(self.maybe_summarize(char_id=None if public else char_id))
        return {"ok": True, "reply": reply, "clue": clue_info}

    # ---------------- 线下讨论记录 ----------------
    async def add_note(self, text: str, who: str = "记录") -> None:
        async with self.lock:
            self.state.log_public("note", who, text.strip()[:1000], self.phase.id)
            self.changed()
        asyncio.create_task(self.maybe_summarize())

    # ---------------- 投票 ----------------
    async def vote(self, char_id: str, option: str) -> dict:
        async with self.lock:
            if self.phase.type != "vote":
                return {"ok": False, "msg": "现在不是投票阶段"}
            if not self.script.character(option):
                return {"ok": False, "msg": "无效选项"}
            p = self.state.players[char_id]
            if p.vote:
                return {"ok": False, "msg": "你已经投过票了"}
            p.vote = option
            self.state.log_public("system", "投票", f"{self.name_of(char_id)} 已投票", self.phase.id)
            if all(pl.vote for pl in self.state.players.values()):
                self.state.votes_revealed = True
                self.state.log_public("system", "投票", "所有人都已投票。\n" + self.vote_summary()[0], self.phase.id)
            self.changed()
        return {"ok": True}

    def vote_summary(self) -> tuple[str, bool | None]:
        tally: dict[str, list[str]] = {}
        for p in self.state.players.values():
            if p.vote:
                tally.setdefault(p.vote, []).append(self.name_of(p.char_id))
        lines = [f"{self.name_of(k)}：{len(v)}票（{'、'.join(v)}）"
                 for k, v in sorted(tally.items(), key=lambda kv: -len(kv[1]))]
        vp = next((ph for ph in self.script.phases if ph.type == "vote"), None)
        correct = None
        if vp and vp.vote_answer and tally:
            top = max(len(v) for v in tally.values())
            leaders = [k for k, v in tally.items() if len(v) == top]
            correct = leaders == [vp.vote_answer]
        return ("\n".join(lines) or "没有人投票"), correct

    async def _reveal(self) -> None:
        self.state.votes_revealed = True
        lines, correct = self.vote_summary()
        msgs = prompts.reveal_messages(self.script, self.state, lines, correct)
        ending = self.script.endings.get("correct" if correct else "wrong", "") if correct is not None else ""
        fallback = f"投票结果：\n{lines}\n\n真相：\n{self.script.truth}\n\n{ending}"
        await self._stream_public(msgs, fallback, kind="reveal")

    # ---------------- 记忆压缩 ----------------
    async def maybe_summarize(self, force: bool = False, char_id: str | None = None) -> None:
        """公开记录超过阈值，就把最早的一批折叠进摘要；私聊同理。保证每次给AI的上下文长度恒定。"""
        if self._sum_lock.locked():
            return
        async with self._sum_lock:
            st = self.state
            pending = len(st.public_log) - st.summarized_upto
            threshold = self.keep_recent + self.summarize_batch
            if pending > threshold or (force and pending > self.keep_recent):
                upto = len(st.public_log) - self.keep_recent
                batch = st.public_log[st.summarized_upto:upto]
                try:
                    new = await self.cheap.chat(prompts.summary_messages(st.summary, batch), max_tokens=1200)
                    if new.strip():
                        async with self.lock:
                            st.summary, st.summarized_upto = new.strip(), upto
                            self.changed()
                except LLMError as e:
                    st.warn(f"记忆压缩失败（不影响游戏，下次再试）：{e}")
            if char_id:
                log = st.private_log.get(char_id, [])
                done = st.private_summarized_upto.get(char_id, 0)
                if len(log) - done > self.private_keep * 2:
                    upto = len(log) - self.private_keep
                    try:
                        new = await self.cheap.chat(prompts.summary_messages(
                            st.private_summary.get(char_id, ""), log[done:upto], self.name_of(char_id)), max_tokens=800)
                        if new.strip():
                            async with self.lock:
                                st.private_summary[char_id] = new.strip()
                                st.private_summarized_upto[char_id] = upto
                                self.changed()
                    except LLMError as e:
                        st.warn(f"私聊记忆压缩失败：{e}")

    # ---------------- 视图（每种页面看到的内容不同） ----------------
    def act_label(self, act: str) -> str:
        m = re.fullmatch(r"act(\d+)", act)
        if m:
            n = int(m.group(1))
            return "第" + ("一二三四五六七八九十"[n - 1] if 1 <= n <= 10 else str(n)) + "幕"
        return act

    def _phase_view(self) -> dict:
        ph = self.phase
        return {"index": self.state.phase_index, "total": len(self.script.phases), "id": ph.id,
                "title": ph.title, "type": ph.type, "minutes": ph.minutes,
                "started_at": self.state.phase_started_at}

    def _clue_view(self, cid: str) -> dict:
        c = self.script.clues[cid]
        return {"id": cid, "title": c.title, "text": c.text, "has_image": bool(c.image),
                "public": cid in self.state.public_clues}

    def _log_view(self, entries, n=80) -> list[dict]:
        return [{"t": e.t, "kind": e.kind, "who": e.who, "text": e.text} for e in entries[-n:]]

    def _players_view(self) -> list[dict]:
        out = []
        for c in self.script.characters:
            p = self.state.players.get(c.id)
            out.append({"char_id": c.id, "char_name": c.name, "public": c.public,
                        "player": p.name if p else None, "voted": bool(p and p.vote),
                        "claimable": bool(p and p.claimable), "busy": c.id in self.busy})
        return out

    def _vote_view(self) -> dict | None:
        vp = self.phase if self.phase.type in ("vote", "reveal") else None
        if not vp:
            return None
        v = {"question": next((ph.vote_question for ph in self.script.phases if ph.type == "vote"), "谁是凶手？"),
             "revealed": self.state.votes_revealed,
             "voted": sum(1 for p in self.state.players.values() if p.vote),
             "total": len(self.state.players)}
        if self.state.votes_revealed:
            v["result"] = self.vote_summary()[0]
        return v

    def view_public(self) -> dict:
        return {"title": self.script.title, "intro": self.script.intro, "phase": self._phase_view(),
                "players": self._players_view(),
                "public_clues": [self._clue_view(c) for c in self.state.public_clues if c in self.script.clues],
                "log": self._log_view(self.state.public_log), "vote": self._vote_view(),
                "ai_paused": self.state.ai_paused, "now": time.time()}

    def view_player(self, char_id: str) -> dict:
        v = self.view_public()
        p = self.state.players.get(char_id)
        c = self.script.character(char_id)
        if not p or not c:
            return v
        acts = self.script.unlocked_acts(self.state.phase_index)
        ph = self.phase
        locations = []
        if ph.type == "search":
            for l in ph.locations:
                n = self.state.location_progress.get(f"{ph.id}:{l.id}", 0)
                locations.append({"id": l.id, "name": l.name, "left": max(0, len(l.clues) - n)})
        v["me"] = {
            "char_id": char_id, "char_name": c.name, "name": p.name, "public": c.public,
            "book": [{"act": self.act_label(a), "text": c.book[a]} for a in acts if a in c.book],
            "clues": [self._clue_view(x) for x in p.clues if x in self.script.clues],
            "search_left": p.search_left, "locations": locations, "vote": p.vote,
            "private_log": self._log_view(self.state.private_log.get(char_id, []), 60),
            "busy": char_id in self.busy,
        }
        return v

    def view_admin(self) -> dict:
        v = self.view_public()
        v["admin"] = {
            "phases": [{"title": p.title, "type": p.type, "minutes": p.minutes} for p in self.script.phases],
            "clues": [{"id": cid, "title": c.title,
                       "holder": self.name_of(self.state.found_by[cid]) if cid in self.state.found_by else None,
                       "public": cid in self.state.public_clues} for cid, c in self.script.clues.items()],
            "warnings": self.state.warnings[-20:], "narration_mode": self.narration_mode,
            "model": self.llm.label, "summary": self.state.summary,
            "log_size": len(self.state.public_log), "summarized_upto": self.state.summarized_upto,
        }
        return v
