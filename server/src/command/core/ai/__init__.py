"""AI provider layer.

Today this powers note titles via a cheap OpenAI-compatible model. It is the
seed for the later agentic backend (Claude-subscription + OpenRouter/Qwen
router, tools, web search); keep new provider plumbing here.
"""

from .client import complete, enabled
from .search import SearchResult, web_search
from .titles import generate_and_save_title, generate_title

__all__ = [
    "SearchResult",
    "complete",
    "enabled",
    "generate_and_save_title",
    "generate_title",
    "web_search",
]
