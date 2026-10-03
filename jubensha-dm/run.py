"""启动：python run.py
常用参数：
  --script scripts/demo     用哪个剧本（文件夹）
  --config config.yaml      配置文件
  --new                     开新局（默认会接着上次的存档继续）
  --port 8000
"""
from __future__ import annotations

import argparse
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
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))       # 不会真的发包，只是让系统选出局域网网卡
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return socket.gethostbyname(socket.gethostname())


def load_config(path: Path) -> dict:
    if not path.exists():
        example = ROOT / "config.example.yaml"
        print(f"没找到 {path.name}，先用模拟模式运行。正式使用请复制 config.example.yaml 为 config.yaml 并填写。")
        cfg = yaml.safe_load(example.read_text(encoding="utf-8")) if example.exists() else {}
        cfg.setdefault("llm", {})["provider"] = "mock"
        return cfg
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def main():
    ap = argparse.ArgumentParser(description="AI 剧本杀主持")
    ap.add_argument("--script", default="scripts/demo")
    ap.add_argument("--config", default="config.yaml")
    ap.add_argument("--new", action="store_true", help="开新局")
    ap.add_argument("--host", default=None)
    ap.add_argument("--port", type=int, default=None)
    args = ap.parse_args()

    cfg = load_config(ROOT / args.config if not Path(args.config).is_absolute() else Path(args.config))
    try:
        script = load_script(ROOT / args.script if not Path(args.script).is_absolute() else args.script)
    except ScriptError as e:
        print(e)
        sys.exit(1)
    for lvl, msg in validate(script):
        print(f"[剧本{lvl}] {msg}")

    try:
        llm = LLM(cfg.get("llm", {}))
        cheap_cfg = (cfg.get("llm") or {}).get("cheap")
        cheap = LLM({**cfg["llm"], **cheap_cfg, "cheap": None}) if cheap_cfg else None
    except LLMError as e:
        print(e)
        sys.exit(1)

    save_path = ROOT / "saves" / f"{script.folder.name}.json"
    if save_path.exists() and not args.new:
        state = GameState.load(save_path)
        print(f"已读取存档 {save_path.name}（第{state.phase_index + 1}阶段）。想开新局请加 --new")
    else:
        if save_path.exists():
            backup = save_path.with_name(f"{save_path.stem}-{time.strftime('%m%d-%H%M%S')}.json")
            shutil.move(save_path, backup)
            print(f"旧存档已备份为 {backup.name}")
        state = GameState(script_title=script.title)
        state.log_public("system", "系统", f"《{script.title}》即将开始。请用手机扫码或打开链接选择角色。")
        if script.phases and script.phases[0].dm_script:   # 第一阶段的主持词先显示在大屏上
            state.log_public("narration", "DM", script.phases[0].dm_script, script.phases[0].id)
        state.save(save_path)

    server_cfg = cfg.get("server", {}) or {}
    host = args.host or server_cfg.get("host", "0.0.0.0")
    port = args.port or int(server_cfg.get("port", 8000))
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
