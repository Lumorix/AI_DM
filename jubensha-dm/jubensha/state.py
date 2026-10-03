"""游戏状态：所有会变的东西都在这里，随时存成 JSON，断电/关机后可以读档继续。"""
from __future__ import annotations

import json
import secrets
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path


@dataclass
class Player:
    char_id: str
    name: str
    token: str
    clues: list[str] = field(default_factory=list)       # 自己持有的线索
    search_left: int = 0                                 # 当前阶段剩余搜证次数
    vote: str | None = None
    claimable: bool = False                              # 被管理员释放，等新手机认领


@dataclass
class LogEntry:
    t: float
    kind: str        # narration / ask / answer / note / clue / system / search
    who: str         # 显示名，如 "DM"、"周晴"
    text: str
    phase: str = ""


@dataclass
class GameState:
    script_title: str
    admin_token: str = field(default_factory=lambda: secrets.token_urlsafe(8))
    phase_index: int = 0
    phase_started_at: float = field(default_factory=time.time)
    players: dict[str, Player] = field(default_factory=dict)          # char_id -> Player
    public_clues: list[str] = field(default_factory=list)
    found_by: dict[str, str] = field(default_factory=dict)            # clue_id -> char_id
    location_progress: dict[str, int] = field(default_factory=dict)   # "phase:loc" -> 已搜出数量
    public_log: list[LogEntry] = field(default_factory=list)
    private_log: dict[str, list[LogEntry]] = field(default_factory=dict)
    # 记忆：公开事件摘要 + 每个玩家的私聊摘要
    summary: str = ""
    summarized_upto: int = 0                  # public_log 中已并入摘要的条数
    private_summary: dict[str, str] = field(default_factory=dict)
    private_summarized_upto: dict[str, int] = field(default_factory=dict)
    votes_revealed: bool = False
    ai_paused: bool = False
    warnings: list[str] = field(default_factory=list)                 # 给管理员看的拦截/错误记录

    # ---------- 存档 ----------
    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(self), ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(path)

    @classmethod
    def load(cls, path: Path) -> "GameState":
        d = json.loads(path.read_text(encoding="utf-8"))
        d["players"] = {k: Player(**v) for k, v in d.get("players", {}).items()}
        d["public_log"] = [LogEntry(**e) for e in d.get("public_log", [])]
        d["private_log"] = {k: [LogEntry(**e) for e in v] for k, v in d.get("private_log", {}).items()}
        return cls(**d)

    # ---------- 小工具 ----------
    def player_by_token(self, token: str | None) -> Player | None:
        if not token:
            return None
        return next((p for p in self.players.values() if p.token == token), None)

    def log_public(self, kind: str, who: str, text: str, phase: str = "") -> LogEntry:
        e = LogEntry(time.time(), kind, who, text, phase)
        self.public_log.append(e)
        return e

    def log_private(self, char_id: str, kind: str, who: str, text: str, phase: str = "") -> LogEntry:
        e = LogEntry(time.time(), kind, who, text, phase)
        self.private_log.setdefault(char_id, []).append(e)
        return e

    def warn(self, msg: str) -> None:
        self.warnings.append(time.strftime("%H:%M:%S ") + msg)
        self.warnings = self.warnings[-50:]
