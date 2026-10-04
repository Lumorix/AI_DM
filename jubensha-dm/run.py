"""启动：python run.py
常用参数：
  --script scripts/demo     用哪个剧本（文件夹）
  --config config.yaml      配置文件
  --new                     开新局（默认会接着上次的存档继续）
  --port 8000
"""
from __future__ import annotations

import argparse
import json
import uuid
import shutil
import socket
import sys
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT))

from jubensha.engine import Game  # noqa: E402
from jubensha.llm import LLM, LLMError  # noqa: E402
from jubensha.script import ScriptError, load_script, validate  # noqa: E402
from jubensha.state import GameState  # noqa: E402


def lan_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))  # 只选择网卡，不发送数据
            return s.getsockname()[0]
    except OSError:
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return "127.0.0.1"


def load_config(path: Path) -> dict:
    if not path.exists():
        example = ROOT / "config.example.yaml"
        print(f"没找到 {path.name}，先用模拟模式运行。正式使用请复制 config.example.yaml 为 config.yaml 并填写。")
        cfg = yaml.safe_load(example.read_text(encoding="utf-8")) if example.exists() else {}
        cfg.setdefault("llm", {})["provider"] = "mock"
        return cfg
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def validate_config(cfg):
    if not isinstance(cfg, dict):
        raise ValueError("配置顶层必须是 YAML 对象")
    for key in ("llm", "game", "server"):
        if cfg.get(key) is not None and not isinstance(cfg[key], dict):
            raise ValueError(f"{key} 必须是对象")
    llm = cfg.get("llm") or {}
    if llm.get("cheap") is not None and not isinstance(llm["cheap"], dict):
        raise ValueError("llm.cheap 必须是对象")
    memory = (cfg.get("game") or {}).get("memory") or {}
    if not isinstance(memory, dict):
        raise ValueError("game.memory 必须是对象")
    for key in ("keep_recent", "private_keep", "summarize_batch"):
        if key in memory and (type(memory[key]) is not int or memory[key] <= 0):
            raise ValueError(f"game.memory.{key} 必须是正整数")


def validate_saved_state(state, script):
    if type(state.phase_index) is not int or not 0 <= state.phase_index < len(script.phases):
        raise ValueError("存档阶段不在当前剧本范围内")
    if state.script_title != script.title:
        raise ValueError("存档剧本标题与当前剧本不一致")
    if type(state.summarized_upto) is not int or not 0 <= state.summarized_upto <= len(state.public_log):
        raise ValueError("公开摘要游标超出记录范围")
    for cid, cursor in state.private_summarized_upto.items():
        if type(cursor) is not int or not 0 <= cursor <= len(state.private_log.get(cid, [])):
            raise ValueError("私聊摘要游标超出记录范围")
    for cid, player in state.players.items():
        if not script.character(cid) or player.char_id != cid:
            raise ValueError("存档角色与剧本不一致")
        if any(clue not in script.clues for clue in player.clues):
            raise ValueError("存档持有的线索不在当前剧本中")
    if any(clue not in script.clues for clue in state.public_clues):
        raise ValueError("存档公开线索不在当前剧本中")


def main():
    ap = argparse.ArgumentParser(description="AI 剧本杀主持")
    ap.add_argument("--script", default="scripts/demo")
    ap.add_argument("--config", default="config.yaml")
    ap.add_argument("--new", action="store_true", help="开新局")
    ap.add_argument("--host", default=None)
    ap.add_argument("--port", type=int, default=None)
    args = ap.parse_args()

    try:
        cfg = load_config(ROOT / args.config if not Path(args.config).is_absolute() else Path(args.config))
        validate_config(cfg)
        server_cfg = cfg.get("server") or {}
        host = args.host or server_cfg.get("host", "0.0.0.0")
        port = args.port if args.port is not None else server_cfg.get("port", 8000)
        if not isinstance(host, str) or not host.strip():
            raise ValueError("server.host 必须是非空字符串")
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError("端口必须是1至65535的整数")
    except (OSError, ValueError, TypeError, yaml.YAMLError) as exc:
        print(f"配置无效，未启动或修改存档：{exc}")
        sys.exit(1)
    try:
        script = load_script(ROOT / args.script if not Path(args.script).is_absolute() else args.script)
    except ScriptError as e:
        print(e)
        sys.exit(1)
    for lvl, msg in validate(script):
        print(f"[剧本{lvl}] {msg}")

    try:
        llm = LLM(cfg.get("llm") or {})
        cheap_cfg = (cfg.get("llm") or {}).get("cheap")
        cheap = LLM({**cfg["llm"], **cheap_cfg, "cheap": None}) if cheap_cfg else None
    except (LLMError, ValueError, TypeError) as e:
        print(e)
        sys.exit(1)

    save_path = ROOT / "saves" / f"{script.folder.name}.json"
    if save_path.exists() and not args.new:
        try:
            state = GameState.load(save_path)
            validate_saved_state(state, script)
        except (OSError, ValueError, TypeError, KeyError) as exc:
            print(f"存档无法安全恢复，原文件未修改：{exc}。请检查存档；需要新局可使用 --new（会备份）。")
            sys.exit(1)
        print(f"已读取存档 {save_path.name}（第{state.phase_index + 1}阶段）。想开新局请加 --new")
    else:
        if save_path.exists():
            backup = save_path.with_name(f"{save_path.stem}-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.json")
            shutil.move(save_path, backup)
            print(f"旧存档已备份为 {backup.name}")
        state = GameState(script_title=script.title)
        state.log_public("system", "系统", f"《{script.title}》即将开始。请用手机扫码或打开链接选择角色。")
        if script.phases and script.phases[0].dm_script:   # 第一阶段的主持词先显示在大屏上
            opening = script.phases[0].dm_script
            if script.first_forbidden(opening, 0):
                state.warn("开局旁白命中禁用词，已在公开前拦截，请主持人检查")
            else:
                state.log_public("narration", "DM", opening, script.phases[0].id)
        state.save(save_path)

    ip = lan_ip()
    base = f"http://{ip}:{port}"

    game = Game(script, state, llm, cfg, save_path, cheap)
    from jubensha.server import create_app
    app = create_app(game, lan_url=f"{base}/player")

    line = "=" * 56
    print(f"\n{line}\n  《{script.title}》  AI：{llm.label}")
    print(f"  大屏（投到电视/电脑上）：{base}/screen")
    print(f"  玩家（手机打开或扫大屏二维码）：{base}/player")
    print(f"  管理（别给玩家看）：{base}/admin?admin={state.admin_token}")
    print(f"{line}\n  手机打不开？确认手机和电脑连的是同一个WiFi，并允许防火墙放行 Python。\n")

    import uvicorn
    uvicorn.run(app, host=host, port=port, log_level="warning")


if __name__ == "__main__":
    main()
