"""网页服务：大屏 /screen、玩家 /player、管理 /admin。用 SSE 推送实时更新（手机浏览器都支持，断线自动重连）。"""
from __future__ import annotations

import asyncio
import json
import mimetypes
from pathlib import Path

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from .engine import Game

STATIC = Path(__file__).parent / "static"


def create_app(game: Game, lan_url: str = "") -> Starlette:
    st = game.state

    def page(name):
        async def handler(request: Request):
            return FileResponse(STATIC / name, headers={"Cache-Control": "no-cache"})
        return handler

    async def static_file(request: Request):
        name = request.path_params["name"]
        f = (STATIC / name).resolve()
        if STATIC.resolve() not in f.parents or not f.is_file():
            return Response(status_code=404)
        return FileResponse(f, headers={"Cache-Control": "no-cache"})

    async def body(request: Request) -> dict:
        try:
            data = await request.json()
            return data if isinstance(data, dict) else {}
        except (json.JSONDecodeError, ValueError):
            return {}

    def player_of(data: dict):
        return st.player_by_token(data.get("token"))

    def is_admin(request: Request, data: dict | None = None) -> bool:
        tok = request.headers.get("x-admin") or request.query_params.get("admin") or (data or {}).get("admin")
        return tok == st.admin_token

    def err(msg: str, code: int = 400):
        return JSONResponse({"ok": False, "msg": msg}, status_code=code)

    # ---------- 实时推送 ----------
    async def events(request: Request):
        role = request.query_params.get("role", "screen")
        session_token = request.query_params.get("token")
        def session_valid():
            if role != "player":
                return True
            player = st.player_by_token(session_token)
            return player is not None and audience == f"player:{player.char_id}"
        if role == "admin":
            if not is_admin(request):
                return err("管理密码不对", 403)
            audience, view = "admin", game.view_admin
        elif role == "player":
            p = st.player_by_token(request.query_params.get("token"))
            if not p:
                return err("请先选择角色", 401)
            audience, view = f"player:{p.char_id}", (lambda cid=p.char_id: game.view_player(cid))
        else:
            audience, view = "screen", game.view_public

        sub = game.bus.subscribe(audience)

        async def gen():
            try:
                if not session_valid():
                    yield 'data: {"type": "kicked"}\n\n'
                    return
                yield f"data: {json.dumps({'type': 'view', 'data': view(), 'lan_url': lan_url}, ensure_ascii=False)}\n\n"
                while True:
                    try:
                        ev = await asyncio.wait_for(sub.queue.get(), timeout=15)
                    except asyncio.TimeoutError:
                        if not session_valid():
                            yield 'data: {"type": "kicked"}\n\n'
                            break
                        if await request.is_disconnected():
                            break
                        yield ": ping\n\n"
                        continue
                    # Bind every event to the authenticated device, not only its character.
                    if not session_valid():
                        yield 'data: {"type": "kicked"}\n\n'
                        break
                    if ev["type"] == "refresh":
                        yield f"data: {json.dumps({'type': 'view', 'data': view(), 'lan_url': lan_url}, ensure_ascii=False)}\n\n"
                    else:
                        yield f"data: {json.dumps(ev, ensure_ascii=False)}\n\n"
            finally:
                game.bus.unsubscribe(sub)

        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    # ---------- 玩家 ----------
    async def lobby(request: Request):
        return JSONResponse({"title": game.script.title, "intro": game.script.intro,
                             "players": game._players_view(), "phase": game._phase_view()})

    async def join(request: Request):
        d = await body(request)
        try:
            p = await game.join(str(d.get("char_id", "")), str(d.get("name", "")), d.get("token"))
        except ValueError as e:
            return err(str(e))
        return JSONResponse({"ok": True, "token": p.token, "char_id": p.char_id})

    async def me(request: Request):
        p = player_of(await body(request))
        if not p:
            return JSONResponse({"ok": False, "code": 401})
        return JSONResponse({"ok": True, "char_id": p.char_id})

    async def search(request: Request):
        d = await body(request)
        p = player_of(d)
        if not p:
            return err("请先选择角色", 401)
        return JSONResponse(await game.search(p.char_id, str(d.get("location", ""))))

    async def ask(request: Request):
        d = await body(request)
        p = player_of(d)
        if not p:
            return err("请先选择角色", 401)
        return JSONResponse(await game.ask(p.char_id, str(d.get("text", "")), bool(d.get("public"))))

    async def publish(request: Request):
        d = await body(request)
        p = player_of(d)
        if not p:
            return err("请先选择角色", 401)
        return JSONResponse(await game.publish_clue(p.char_id, str(d.get("clue", ""))))

    async def vote(request: Request):
        d = await body(request)
        p = player_of(d)
        if not p:
            return err("请先选择角色", 401)
        return JSONResponse(await game.vote(p.char_id, str(d.get("option", ""))))

    async def clue_image(request: Request):
        cid = request.path_params["cid"]
        clue = game.script.clues.get(cid)
        if not clue or not clue.image:
            return Response(status_code=404)
        token = request.query_params.get("token")
        p = st.player_by_token(token)
        allowed = cid in st.public_clues or (p and cid in p.clues) or token == st.admin_token
        if not allowed:
            return Response(status_code=403)
        f = (game.script.folder / clue.image).resolve()
        if game.script.folder.resolve() not in f.parents or not f.is_file():
            return Response(status_code=404)
        return FileResponse(f, media_type=mimetypes.guess_type(f.name)[0] or "image/jpeg")

    async def qr(request: Request):
        url = request.query_params.get("url") or lan_url
        try:
            import segno
        except ImportError:
            return Response(status_code=404)
        import io
        buf = io.BytesIO()
        segno.make(url, error="m").save(buf, kind="svg", scale=6, border=2)
        return Response(buf.getvalue(), media_type="image/svg+xml")

    # ---------- 管理 ----------
    async def admin(request: Request):
        d = await body(request)
        if not is_admin(request, d):
            return err("管理密码不对", 403)
        action = request.path_params["action"]
        if action == "next":
            await game.goto(st.phase_index + 1)
        elif action == "prev":
            await game.goto(st.phase_index - 1, narrate=False)
        elif action == "goto":
            await game.goto(int(d.get("index", 0)), narrate=bool(d.get("narrate", True)))
        elif action == "replay":
            game.start_narration()
        elif action == "pause":
            st.ai_paused = True
            game.changed()
        elif action == "resume":
            st.ai_paused = False
            game.changed()
        elif action == "note":
            if not str(d.get("text", "")).strip():
                return err("内容是空的")
            await game.add_note(str(d["text"]))
        elif action == "say":
            if not str(d.get("text", "")).strip():
                return err("内容是空的")
            await game.narrate_custom(str(d["text"]), polish=bool(d.get("polish")))
        elif action == "give":
            return JSONResponse(await game.give_clue(str(d.get("target", "")), str(d.get("clue", ""))))
        elif action == "release":
            await game.release(str(d.get("char_id", "")))
        elif action == "reveal_votes":
            st.votes_revealed = True
            st.log_public("system", "投票", "投票结果：\n" + game.vote_summary()[0], game.phase.id)
            game.changed()
        elif action == "narration_mode":
            game.narration_mode = "verbatim" if game.narration_mode == "ai" else "ai"
            game.changed()
        elif action == "summarize":
            await game.maybe_summarize(force=True)
        elif action == "clear_warnings":
            st.warnings.clear()
            game.changed()
        else:
            return err("未知操作")
        return JSONResponse({"ok": True})

    async def index(request: Request):
        return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-cache"})

    routes = [
        Route("/", index),
        Route("/screen", page("screen.html")),
        Route("/player", page("player.html")),
        Route("/admin", page("admin.html")),
        Route("/static/{name:path}", static_file),
        Route("/api/events", events),
        Route("/api/lobby", lobby),
        Route("/api/join", join, methods=["POST"]),
        Route("/api/me", me, methods=["POST"]),
        Route("/api/search", search, methods=["POST"]),
        Route("/api/ask", ask, methods=["POST"]),
        Route("/api/publish", publish, methods=["POST"]),
        Route("/api/vote", vote, methods=["POST"]),
        Route("/api/clue-image/{cid}", clue_image),
        Route("/api/qr.svg", qr),
        Route("/api/admin/{action}", admin, methods=["POST"]),
    ]
    return Starlette(routes=routes)
