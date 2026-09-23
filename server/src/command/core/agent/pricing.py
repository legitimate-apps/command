"""USD cost from token counts for the agent's models.

Rates are per 1M tokens (input, output) for the OpenRouter-routed slugs. This is a
soft-cap accounting table — reconcile real charges against the provider console out
of band; the $10/month cap is a friendly cutoff, not a billing ledger.
"""

from __future__ import annotations

_RATES: dict[str, tuple[float, float]] = {
    # Current tiers (verified against OpenRouter's /models, 2026-09-22).
    "anthropic/claude-sonnet-5": (2.0, 10.0),
    "anthropic/claude-opus-5.5": (4.0, 20.0),
    "anthropic/claude-haiku-4.5": (1.0, 5.0),
    # Non-Anthropic tiers (OpenRouter list price, 2026-09-22). GLM is the only real
    # discount here — Kimi K3 is priced above Sonnet, GPT-6 Sol level with it.
    "z-ai/glm-5.3": (0.56, 1.76),
    "moonshotai/kimi-k3": (3.0, 15.0),
    "openai/gpt-6-sol": (2.0, 10.0),
    # Superseded slugs kept so already-recorded usage rows still price correctly.
    "anthropic/claude-opus-5": (5.0, 25.0),
    "z-ai/glm-5.2": (0.70, 2.20),
    "openai/gpt-5.6-terra": (2.5, 15.0),
    "anthropic/claude-opus-4.8": (5.0, 25.0),
    "anthropic/claude-sonnet-4.6": (3.0, 15.0),
}
_DEFAULT = (2.0, 10.0)  # assume current Sonnet-class if a slug isn't in the table

# Flat surcharge OpenRouter bills per web search (Exa/Parallel engines, ~$0.005);
# folded into the metered run cost on top of the search model's token cost.
WEB_SEARCH_FEE_USD = 0.005
FETCH_URL_FEE_USD = 0.001


# Anthropic prompt-cache multipliers on the INPUT rate, verified against OpenRouter's
# own reported `usage.cost` to the cent (2026-07-25): a cached read bills at a tenth,
# writing the cache costs a quarter extra. Pricing a read at the full input rate
# over-charges it by 6.3x, which would burn a user's cap ~6x too fast now that the
# tool block is cached on every request.
CACHE_READ_MULTIPLIER = 0.1
CACHE_WRITE_MULTIPLIER = 1.25


def cost_usd(
    model: str,
    input_tokens: int,
    output_tokens: int,
    *,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
) -> float:
    """USD for one model call.

    `input_tokens` is the provider's total prompt count, which INCLUDES any cached
    tokens — so the cached portions are split out and re-priced rather than added.
    """
    in_rate, out_rate = _RATES.get(model, _DEFAULT)
    cached = max(0, cache_read_tokens) + max(0, cache_write_tokens)
    uncached = max(0, input_tokens - cached)
    return (
        uncached * in_rate
        + max(0, cache_read_tokens) * in_rate * CACHE_READ_MULTIPLIER
        + max(0, cache_write_tokens) * in_rate * CACHE_WRITE_MULTIPLIER
        + output_tokens * out_rate
    ) / 1_000_000
