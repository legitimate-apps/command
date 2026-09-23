"""Web search via OpenRouter's `openrouter:web_search` server tool.

One grounded chat completion against a cheap model with web search enabled: the
model searches autonomously and returns a synthesized answer plus `url_citation`
annotations. We hand back the text, a compact source list, and the inner call's
token usage / search count so the agent layer can meter it against the user's cap.

This is the live OpenRouter shape — the older `plugins:[{id:"web"}]` form and the
`:online` model suffix are deprecated. Every failure returns `ok=False` (callers
must tolerate it); we never raise into the agent's tool loop.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import httpx

from ...config import get_settings


@dataclass
class SearchResult:
    ok: bool
    text: str = ""
    sources: list[dict[str, str]] = field(default_factory=list)  # [{title, url}]
    model: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    searches: int = 0


def web_search(query: str, *, max_results: int = 5, model: str | None = None) -> SearchResult:
    """Search the web for `query` and return a synthesized, cited answer.

    `max_results` is clamped to 1-10. Returns `SearchResult(ok=False)` on any
    failure (no key, network error, non-2xx, malformed body)."""
    settings = get_settings()
    key = settings.ai_api_key
    if not key:
        return SearchResult(ok=False)
    model = model or settings.ai_search_model
    max_results = max(1, min(max_results, 10))
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "X-Title": "Command",
    }
    payload: dict[str, object] = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are a research assistant. Search the web and answer the query "
                    "concisely with the key facts and figures. Prefer primary sources and "
                    "recent information. Cite the sources you used."
                ),
            },
            {"role": "user", "content": query},
        ],
        "tools": [
            {
                "type": "openrouter:web_search",
                "parameters": {
                    "engine": "auto",
                    "max_results": max_results,
                    "search_context_size": "medium",
                },
            }
        ],
        "max_tokens": 700,
        "temperature": 0.2,
    }
    try:
        resp = httpx.post(
            f"{settings.ai_base_url.rstrip('/')}/chat/completions",
            headers=headers,
            json=payload,
            timeout=max(settings.ai_request_timeout, 30.0),
        )
        resp.raise_for_status()
        data = resp.json()
        msg = data["choices"][0]["message"]
        text = str(msg.get("content") or "").strip()
        sources: list[dict[str, str]] = []
        for ann in msg.get("annotations") or []:
            uc = ann.get("url_citation") or {}
            url = uc.get("url")
            if url:
                sources.append({"title": str(uc.get("title") or url), "url": str(url)})
        usage = data.get("usage") or {}
        return SearchResult(
            ok=True,
            text=text,
            sources=sources,
            model=model,
            input_tokens=int(usage.get("prompt_tokens") or 0),
            output_tokens=int(usage.get("completion_tokens") or 0),
            searches=1,
        )
    except Exception:
        return SearchResult(ok=False)
