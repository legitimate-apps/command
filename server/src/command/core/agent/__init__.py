"""The AI agent (Phase B): a lean pydantic-ai dual-model runner over the planning
domain, with a per-account usage meter + monthly cap.

`runner` and `tools` import pydantic-ai (heavy) — import them lazily where used, not
at app startup, to keep idle RSS lean. `usage` and `pricing` are light.
"""

from . import pricing, threads, usage

__all__ = ["pricing", "threads", "usage"]
