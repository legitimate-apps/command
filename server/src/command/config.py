"""Environment-driven configuration.

A thin `pydantic-settings` model. Every value can be supplied via a
`COMMAND_`-prefixed env var (or a local `.env`); defaults are dev-friendly.
"""

from __future__ import annotations

import json
import os
import secrets
from functools import lru_cache
from pathlib import Path

from pydantic import AliasChoices, Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="COMMAND_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # What this server is. "self" (default): one owner's personal server — the first account
    # owns it and may set the assistant's model key from the app. "cloud": a multi-tenant
    # service (Command Cloud) whose operator supplies everything by env. Reported by
    # GET /api/server/info so the app can label the server and pick its onboarding path.
    server_kind: str = "self"

    # Storage
    db_path: str = "./data/command.db"
    # Attachment bytes live on disk (never in SQLite). Unset ⇒ <db dir>/attachments.
    attachments_dir: str | None = None
    max_attachment_bytes: int = 25 * 1024 * 1024
    max_attachments_per_entity: int = 20
    # Per-account ceilings (0 = unlimited). Sized so no real planner reaches them; they exist
    # so one account on a shared server cannot fill its disk or its database.
    max_attachment_bytes_per_account: int = 2 * 1024 * 1024 * 1024
    max_attachments_per_account: int = 5_000
    max_notes_per_account: int = 100_000
    max_assignments_per_account: int = 50_000
    max_activities_per_account: int = 200_000

    # HTTP bind (loopback in prod; the tunnel reaches it here). A bare PORT is honored too,
    # because hosts like Railway assign the listening port that way.
    http_host: str = "127.0.0.1"
    http_port: int = Field(default=8000, validation_alias=AliasChoices("COMMAND_HTTP_PORT", "PORT"))

    # Posture
    environment: str = "dev"  # dev | prod
    log_level: str = "info"

    # Auth. `session_days` is an *idle* window: a session that keeps being used slides
    # forward (see core.accounts.SessionPolicy), so only genuine inactivity signs you out.
    # `session_absolute_days` caps how long one login may live regardless of use (0 = no
    # cap); `session_renew_after_seconds` throttles how often the slide is written.
    session_days: int = 30
    session_absolute_days: int = 365
    session_renew_after_seconds: int = 86_400

    # Proactive-LLM spend guard: how many model-spending sends an account may receive before
    # it next opens the app. Opening resets the count. Tunable by env so it can be retuned
    # without a code change; 0 disables proactive spend, a negative value removes the guard
    # (self-hosted escape hatch). Counts LLM work only — plain reminder pushes are exempt.
    max_llm_sends_before_open: int = 30
    token_words: int = 4  # MCP access-token words (~55 bits); ups brute-force cost
    # Open signup, or only the very first account?
    #
    # A Command server is one person's planner, and a self-hosted one is usually reachable from
    # the internet (that is the point — the phone has to get to it). Left open, anyone who finds
    # the URL can register and start spending the instance owner's model budget. So the first
    # registration creates the owner and the door closes behind it; set this true to reopen it
    # deliberately (adding a second person, or re-running onboarding).
    allow_registration: bool = False
    # Secure session cookie. Unset/"auto": Secure exactly when the request arrived over HTTPS
    # (directly or per X-Forwarded-Proto), so one image works on a plain-http LAN and behind
    # a TLS proxy. A Secure cookie is never sent over http, which on a LAN would make sign-in
    # appear to work and then fail on the next request. true/false force it.
    cookie_secure: bool | None = None
    cookie_name: str = "command_session"
    # Login brute-force guard (per-username sliding window): lock out after
    # `login_max_attempts` failures within `login_window_seconds`.
    login_max_attempts: int = 10
    login_window_seconds: int = 300
    # Per-client-IP guards on top of the per-username one: failed logins from one address
    # across all usernames (same window as above), and registrations from one address (every
    # attempt counts, successful or not).
    login_ip_max_failures: int = 50
    register_ip_max_attempts: int = 10
    register_ip_window_seconds: int = 3600
    # How many reverse proxies in front of this server append to X-Forwarded-For. 0 (default)
    # ignores the header and uses the connection's peer address — the only safe choice when
    # nothing trusted sets it, because any client can send the header. Behind exactly one
    # proxy (Railway's edge, or one Cloudflare hop) set 1: the client is the entry it added.
    trusted_proxy_hops: int = 0

    # Operator backups: GET /api/admin/backup with `Authorization: Bearer <token>`. Unset ⇒ the
    # endpoint does not exist (404).
    backup_token: str | None = None

    # CORS (irrelevant for the native iOS client; configurable for any web use)
    cors_origins: list[str] = []

    # MCP (Phase 3)
    mcp_path: str = "/mcp"
    public_base_url: str | None = None

    # Calendar export (iCal subscription). Unset ⇒ export disabled (graceful no-op). When set,
    # it signs the stateless per-account token in the subscribe URL. Rotate to revoke all URLs.
    calendar_export_secret: str | None = None

    # AI — note titles now; agentic backend later. OpenAI-compatible endpoint
    # chosen by base_url + key + model. No key => AI titles no-op gracefully.
    ai_base_url: str = "https://openrouter.ai/api/v1"
    ai_api_key: str | None = None
    ai_title_model: str = "qwen/qwen3.8-flash"
    ai_search_model: str = "anthropic/claude-haiku-4.5"  # cheap synthesizer for web_search
    ai_request_timeout: float = 15.0

    # Agent (Phase B). Slice 1 routes BOTH models via OpenRouter using ai_api_key
    # (no new credentials); production may add a direct Anthropic key. Per-account
    # spend is hard-capped each period.
    agent_model_claude: str = "anthropic/claude-sonnet-5"
    agent_model_fast: str = "anthropic/claude-haiku-4.5"
    agent_model_opus: str = "anthropic/claude-opus-5.5"  # escalation for hard asks
    # Non-Anthropic tiers on the same OpenRouter key (refreshed 2026-09-22). GLM 5.3 is the
    # budget workhorse — ~4x cheaper than Sonnet with a 1M window — but is TEXT-ONLY on
    # OpenRouter, so it's listed in `agent_text_only_models` below. Kimi K3 and GPT-6 Sol
    # are alternates from other houses, not savings; GPT-6 Luna is OpenAI's small, cheap
    # model. The Sol tier's id stays "gpt" (it was "terra", GPT-5.6 Terra, before GPT-6) so
    # older clients keep working; "terra" and "sol" resolve to it too.
    agent_model_glm: str = "z-ai/glm-5.3"
    agent_model_kimi: str = "moonshotai/kimi-k3"
    agent_model_gpt: str = Field(
        default="openai/gpt-6-sol",
        validation_alias=AliasChoices("COMMAND_AGENT_MODEL_GPT", "COMMAND_AGENT_MODEL_TERRA"),
    )
    agent_model_gpt_luna: str = "openai/gpt-6-luna"
    agent_text_only_models: str = "z-ai/glm-5.3"
    # OpenRouter provider routing for EVERY model call (agent, note titles, web-search
    # synthesis). "deny" refuses upstream providers that may train on prompts — user
    # notes are the payload here, and a slug like GLM fans out across ~30 providers.
    # "allow" restores OpenRouter's default (wider, sometimes cheaper, pool).
    ai_provider_data_collection: str = "deny"
    # Anthropic prompt caching via an OpenRouter cache breakpoint on the tool block.
    # Cache reads bill ~0.1x and writes ~1.25x, so this is a large net win on any
    # multi-step run (the tool schemas are ~89% of each request). Off => no breakpoint.
    agent_prompt_cache: bool = True
    agent_monthly_cap_usd: float = 10.0
    agent_claude_weight: float = 0.8  # P(route to Sonnet) per run; remainder → Fast/Haiku
    agent_max_steps: int = 12

    # Billing (Phase B slice 3). Gating is OFF until billing is live, so the agent
    # never locks out before there's a way to subscribe. RevenueCat is the store of
    # record; its webhook mirrors entitlement here (token-authed).
    agent_require_subscription: bool = False
    agent_product_id: str = "command_pro_monthly"
    agent_price_display: str = "$19.99/mo"
    agent_trial_days: int = 7
    revenuecat_webhook_token: str | None = None
    # RevenueCat REST confirmation. The webhook reaches only the one server it points at; with a
    # secret API key set, GET /api/agent/entitlement also asks RevenueCat directly (at most once
    # per `revenuecat_refresh_seconds` per account), so any number of servers can share one
    # RevenueCat project. `revenuecat_entitlement_id` is the entitlement the app unlocks with.
    revenuecat_api_key: str | None = None
    revenuecat_api_base: str = "https://api.revenuecat.com/v1"
    revenuecat_entitlement_id: str = "pro"
    revenuecat_refresh_seconds: int = 600

    # Monetization — the assistant "credits" model (decision 2026-07-06). Credits are a
    # display concept: the backend tracks a REAL-USD agent budget per subscription period,
    # reset to `agent_subscription_price_usd / CREDIT_MULTIPLIER` on each RevenueCat renewal
    # and debited per turn; the client shows `budget x 3` with a `$`. OFF until set live, so
    # the gate/debit/reporting ignore the budget and every account behaves exactly as today.
    credits_enabled: bool = False
    # Gross subscription price the per-period budget is derived from (grant = price / 3).
    agent_subscription_price_usd: float = 19.99
    # Legacy consumable-credit scaffolding (integer ledger, migration 0007). Superseded by the
    # USD-budget model above; retained inert (empty ⇒ no consumable grants) to avoid churn.
    credit_products: dict[str, int] = {}

    # Push (APNs, B4). All optional — push disables gracefully (no-op) unless key path/id/team are
    # set, so a dev server without the .p8 behaves exactly as before. The .p8 is mounted into the
    # container read-only; env supplies its path + the key/team ids.
    apns_key_path: str | None = None
    apns_key_id: str | None = None                       # 10-char key id
    apns_team_id: str | None = None                      # 10-char Apple team id
    apns_topic: str = "com.legitimateapps.command"       # bundle id
    reminder_poll_seconds: int = 60                      # how often the reminder job checks for due pushes

    # Connected peer agents (A2A). Key for AES-GCM encryption of stored peer
    # bearer tokens. In prod, an unset key is generated once and kept beside the
    # database (see `_fill_instance_secrets`).
    peer_token_key: str = "dev-insecure-peer-token-key"  # == _DEV_PEER_TOKEN_KEY
    # Comma-separated hostnames the peer fetcher may reach over plain http /
    # private ranges — DEV/E2E ONLY (e.g. "10.0.0.5"). MUST stay empty in prod.
    peer_allow_http_hosts: str = ""

    @field_validator("server_kind", mode="before")
    @classmethod
    def _normalize_server_kind(cls, value: object) -> object:
        if value is None or (isinstance(value, str) and not value.strip()):
            return "self"
        if isinstance(value, str) and value.strip().lower() in SERVER_KINDS:
            return value.strip().lower()
        raise ValueError(f"COMMAND_SERVER_KIND must be one of {sorted(SERVER_KINDS)}")

    @field_validator("cookie_secure", mode="before")
    @classmethod
    def _auto_cookie_secure(cls, value: object) -> object:
        if isinstance(value, str) and value.strip().lower() in ("", "auto"):
            return None
        return value

    @property
    def is_prod(self) -> bool:
        return self.environment.lower() == "prod"

    @property
    def is_cloud(self) -> bool:
        return self.server_kind == "cloud"


SERVER_KINDS = frozenset({"cloud", "self"})
_DEV_PEER_TOKEN_KEY = "dev-insecure-peer-token-key"
INSTANCE_SECRETS_FILE = "instance-secrets.json"


def _fill_instance_secrets(settings: Settings) -> None:
    """Give a prod server real secrets without asking a self-hoster to invent any.

    Values not supplied by env are generated once and persisted (0600) next to the database, so
    they survive restarts and image upgrades on the same volume. An env value always wins.
    """
    missing_peer = not settings.peer_token_key or settings.peer_token_key == _DEV_PEER_TOKEN_KEY
    missing_cal = not settings.calendar_export_secret
    if not (missing_peer or missing_cal):
        return
    path = Path(settings.db_path).parent / INSTANCE_SECRETS_FILE
    try:
        stored = json.loads(path.read_text("utf-8")) if path.exists() else {}
    except (OSError, ValueError):
        stored = {}
    changed = False
    for name, missing in (("peer_token_key", missing_peer), ("calendar_export_secret", missing_cal)):
        if not missing:
            continue
        if not isinstance(stored.get(name), str) or not stored[name]:
            stored[name] = secrets.token_urlsafe(32)
            changed = True
        setattr(settings, name, stored[name])
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(stored, fh)
        os.replace(tmp, path)


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if settings.is_prod:
        _fill_instance_secrets(settings)
    return settings
