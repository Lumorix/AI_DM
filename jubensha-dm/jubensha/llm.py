"""AI 接口：统一走 OpenAI 兼容格式。
云端（DeepSeek / 通义千问 / OpenAI / Claude 兼容接口等）和本地（Ollama / LM Studio / vLLM）
都提供这个格式，所以切换模型只需要改 config.yaml 里的 base_url 和 model。
provider: mock 时完全不调用AI，用来测试流程。
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import threading
from typing import AsyncIterator

import requests

from .stability import DEFAULT_CONTEXT_BUDGET, estimate_context

THINK_RE = re.compile(r"<think>.*?</think>", re.S)


class LLMError(Exception):
    pass


def strip_think(text: str) -> str:
    """去掉推理模型（Qwen3、DeepSeek-R1 等本地模型）输出的 <think>…</think> 部分。"""
    text = THINK_RE.sub("", text)
    if "<think>" in text:            # 没闭合：思考还没结束，正文为空
        text = text.split("<think>")[0]
    return text.strip()


def parse_json_reply(text: str) -> dict:
    """从模型输出里尽量抠出 JSON；抠不出就把整段当作回复。"""
    text = strip_think(text)
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    candidates = [fenced.group(1)] if fenced else []
    start, end = text.find("{"), text.rfind("}")
    if start != -1 and end > start:
        candidates.append(text[start:end + 1])
    for c in candidates:
        try:
            v = json.loads(c)
            if isinstance(v, dict):
                return v
        except json.JSONDecodeError:
            continue
    return {"reply": text}


class LLM:
    def __init__(self, cfg: dict):
        self.provider = cfg.get("provider", "openai")
        self.base_url = (cfg.get("base_url") or "").rstrip("/")
        self.api_key = cfg.get("api_key") or os.environ.get("JUBENSHA_API_KEY", "") or "none"
        self.model = cfg.get("model", "")
        self.temperature = float(cfg.get("temperature", 0.7))
        self.timeout = float(cfg.get("timeout", 180))
        self.max_tokens = int(cfg.get("max_tokens", 1500))
        self.extra = cfg.get("extra_body") or {}
        self.context_budget = int(cfg.get("context_budget", DEFAULT_CONTEXT_BUDGET))
        if not isinstance(self.extra, dict):
            raise LLMError("extra_body 必须是 JSON 对象")
        if set(self.extra) & {"model", "messages", "max_tokens", "max_completion_tokens", "stream"}:
            raise LLMError("extra_body 不能覆盖模型、消息、输出长度或流式参数")
        if self.context_budget < 1024 or self.max_tokens <= 0:
            raise LLMError("上下文预算至少1024，输出长度必须大于0")
        if self.provider != "mock" and (not self.base_url or not self.model):
            raise LLMError("config.yaml 里 llm.base_url 和 llm.model 不能为空（或把 provider 设为 mock 先测试）")

    @property
    def label(self) -> str:
        return "模拟模式（未接AI）" if self.provider == "mock" else f"{self.model} @ {self.base_url}"

    # ---------------- 底层 HTTP ----------------
    def _check_budget(self, messages, max_tokens):
        output = self.max_tokens if max_tokens is None else max_tokens
        try:
            if output <= 0:
                raise ValueError("输出长度必须大于0")
            cost = estimate_context(messages, output) + len(json.dumps(self.extra, ensure_ascii=False).encode('utf-8'))
            if cost > self.context_budget:
                raise ValueError(f"上下文估算 {cost} 超过预算 {self.context_budget}，请求未发送；请缩小剧本/历史，或按模型容量调整 context_budget")
        except (ValueError, TypeError, AttributeError) as exc:
            raise LLMError(str(exc)) from exc

    def _payload(self, messages: list[dict], stream: bool, max_tokens: int | None) -> dict:
        self._check_budget(messages, max_tokens)
        p = {"model": self.model, "messages": messages, "temperature": self.temperature,
             "max_tokens": max_tokens or self.max_tokens, "stream": stream}
        p.update(self.extra)
        return p

    def _headers(self) -> dict:
        return {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}

    def _chat_sync(self, messages: list[dict], max_tokens: int | None) -> str:
        try:
            r = requests.post(f"{self.base_url}/chat/completions", headers=self._headers(),
                              json=self._payload(messages, False, max_tokens), timeout=self.timeout)
        except requests.RequestException as e:
            raise LLMError(f"连不上AI接口 {self.base_url}：{e}") from e
        if r.status_code != 200:
            raise LLMError(f"AI接口返回 {r.status_code}：{r.text[:300]}")
        try:
            return r.json()["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, ValueError) as e:
            raise LLMError(f"AI返回格式看不懂：{r.text[:300]}") from e

    def _stream_sync(self, messages: list[dict], max_tokens: int | None, put) -> None:
        try:
            with requests.post(f"{self.base_url}/chat/completions", headers=self._headers(),
                               json=self._payload(messages, True, max_tokens),
                               timeout=self.timeout, stream=True) as r:
                if r.status_code != 200:
                    raise LLMError(f"AI接口返回 {r.status_code}：{r.text[:300]}")
                for line in r.iter_lines(decode_unicode=True):
                    if not line or not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        delta = json.loads(data)["choices"][0].get("delta", {}).get("content")
                    except (ValueError, KeyError, IndexError):
                        continue
                    if delta:
                        put(delta)
        except requests.RequestException as e:
            raise LLMError(f"连不上AI接口 {self.base_url}：{e}") from e

    # ---------------- 对外接口 ----------------
    async def chat(self, messages: list[dict], max_tokens: int | None = None) -> str:
        self._check_budget(messages, max_tokens)
        if self.provider == "mock":
            return _mock_reply(messages)
        text = await asyncio.to_thread(self._chat_sync, messages, max_tokens)
        return strip_think(text)

    async def stream(self, messages: list[dict], max_tokens: int | None = None) -> AsyncIterator[str]:
        """逐段产出文字；自动吞掉 <think> 部分。"""
        self._check_budget(messages, max_tokens)
        if self.provider == "mock":
            for i in range(0, len(text := _mock_reply(messages)), 6):
                await asyncio.sleep(0.02)
                yield text[i:i + 6]
            return

        loop = asyncio.get_running_loop()
        q: asyncio.Queue = asyncio.Queue()
        DONE = object()

        def worker():
            try:
                self._stream_sync(messages, max_tokens, lambda d: loop.call_soon_threadsafe(q.put_nowait, d))
                loop.call_soon_threadsafe(q.put_nowait, DONE)
            except Exception as e:  # noqa: BLE001
                loop.call_soon_threadsafe(q.put_nowait, e)

        threading.Thread(target=worker, daemon=True).start()
        buf, in_think, started = "", False, False
        while True:
            item = await q.get()
            if item is DONE:
                break
            if isinstance(item, Exception):
                raise item
            buf += item
            # 过滤 <think>…</think>
            out = ""
            while buf:
                if in_think:
                    end = buf.find("</think>")
                    if end == -1:
                        buf = buf[-8:]
                        break
                    buf, in_think = buf[end + 8:], False
                else:
                    start = buf.find("<think>")
                    if start == -1:
                        # 末尾可能是半个 "<think>"，先留着等下一段
                        keep = next((k for k in range(min(6, len(buf)), 0, -1) if "<think>".startswith(buf[-k:])), 0)
                        out, buf = out + buf[: len(buf) - keep], buf[len(buf) - keep:]
                        break
                    out, buf, in_think = out + buf[:start], buf[start + 7:], True
            if not started:
                out = out.lstrip()
                started = bool(out)
            if out:
                yield out
        if buf and not in_think:
            yield buf

    async def vision(self, image_b64: str, prompt: str, mime: str = "image/png") -> str:
        """给视觉模型发一张图（OCR 工具用）。"""
        if self.provider == "mock":
            return "（模拟OCR文字）"
        messages = [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{image_b64}"}},
        ]}]
        return await self.chat(messages, max_tokens=4000)


# ---------------- 模拟模式 ----------------
def _mock_reply(messages: list[dict]) -> str:
    sys_text = messages[0]["content"] if messages and isinstance(messages[0]["content"], str) else ""
    last = messages[-1]["content"] if messages else ""
    last = last if isinstance(last, str) else ""
    if "【任务：问答】" in sys_text:
        q = last.split("玩家的问题：")[-1].strip()[:60]
        return json.dumps({"reply": f"（模拟回答）关于“{q}”，剧本中没有更多可以告诉你的。", "give_clue": None},
                          ensure_ascii=False)
    if "【任务：摘要】" in sys_text:
        return "（模拟摘要）" + last[-300:].replace("\n", " ")
    if "【任务：旁白】" in sys_text or "【任务：复盘】" in sys_text:
        body = last.split("<<<")[-1].split(">>>")[0].strip() if "<<<" in last else last
        return body or "（模拟旁白）"
    return "（模拟回复）"
