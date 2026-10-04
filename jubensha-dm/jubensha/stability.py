"""Conservative request guard and validated memory updates; no silent truncation."""
from __future__ import annotations

DEFAULT_CONTEXT_BUDGET = 32768
SUMMARY_CHARS = 600


def estimate_context(messages: list[dict], output_tokens: int) -> int:
    # UTF-8 byte count is intentionally conservative for text, not a model tokenizer.
    cost = 512 + output_tokens
    for message in messages:
        cost += 16 + len(str(message.get('role', '')).encode('utf-8'))
        content = message.get('content', '')
        if isinstance(content, str):
            cost += len(content.encode('utf-8'))
        elif isinstance(content, list):
            for part in content:
                if part.get('type') == 'text':
                    cost += len(part.get('text', '').encode('utf-8'))
                elif part.get('type') == 'image_url':
                    cost += 4096  # Provisional image reserve, NOT an exact token count.
                else:
                    raise ValueError('不支持的多模态内容，无法估算上下文')
        else:
            raise ValueError('不支持的消息内容，无法估算上下文')
    return cost


async def validated_summary(model, messages, max_tokens=1200):
    from .llm import LLMError
    for attempt in range(2):
        request = messages if attempt == 0 else messages + [{
            'role': 'user', 'content': '上次摘要为空或超过600字。请重新压缩为非空、600字以内的完整摘要；保留关键事实，只输出摘要。'}]
        text = (await model.chat(request, max_tokens=max_tokens)).strip()
        if 0 < len(text) <= SUMMARY_CHARS:
            return text
    raise LLMError('摘要两次未满足非空且600字以内要求，保留旧摘要及未压缩记录')
