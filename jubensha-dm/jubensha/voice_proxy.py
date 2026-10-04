"""Loopback game screen -> loopback TTS service. Never accept an arbitrary URL."""
import asyncio
import json
import os
import urllib.error
import urllib.request
from starlette.responses import JSONResponse, Response


async def voice_proxy(request):
    def error(status, message):
        return JSONResponse({'error': {'message': message}}, status_code=status)
    if not request.client or request.client.host not in ('127.0.0.1', '::1'):
        return error(403, '实验语音仅可在主持电脑本机大屏使用')
    origin = request.headers.get('origin')
    if origin and origin != str(request.base_url).rstrip('/'):
        return error(403, '不允许跨源请求')
    payload = None
    if request.method == 'POST':
        raw = bytearray()
        async for chunk in request.stream():
            raw.extend(chunk)
            if len(raw) > 8192:
                return error(413, '请求过大')
        try:
            body = json.loads(raw)
            text = body.get('text') if isinstance(body, dict) else None
            if not isinstance(text, str) or not 1 <= len(text.strip()) <= 120:
                raise ValueError()
            payload = json.dumps({'text': text.strip()}).encode()
        except (ValueError, UnicodeError):
            return error(400, '请输入 1–120 个字符')
    def send():
        port = int(os.environ.get('AIDM_VOICE_PORT', '8775'))
        if not 1024 <= port <= 65535:
            raise ValueError('Invalid voice port')
        path = '/health' if payload is None else '/v1/audio/speech'
        req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=payload,
                                     headers={'Content-Type': 'application/json'})
        # Ignore system HTTP proxies for local inference traffic.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            response = opener.open(req, timeout=5 if payload is None else 120)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            data = response.read(16 * 1024 * 1024 + 1)
            if len(data) > 16 * 1024 * 1024:
                raise ValueError('Voice response too large')
            return Response(data, status_code=response.status,
                            media_type=response.headers.get_content_type(),
                            headers={'Cache-Control': 'no-store'})
    try:
        return await asyncio.to_thread(send)
    except (OSError, ValueError, urllib.error.URLError):
        return error(503, '本地语音服务未连接或超时，请先启动 Windows Voice API')
