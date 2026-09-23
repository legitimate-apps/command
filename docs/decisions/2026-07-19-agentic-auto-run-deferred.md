# Decision: agentic auto-run stays deferred (2026-07-19)

**Status: deferred — do not build.**

"Auto-run" means AI delegatees executing their assignments on a schedule, without
anyone tapping a button. It is deferred for three reasons:

- **Cost.** Unattended runs are still too expensive at current API pricing to fire
  on a schedule.
- **When it lands, it lands fully capable.** No output-only interim version that
  would have to be rebuilt; AI delegatees get real, scoped tool power.
- **Containment is the design center.** Nothing may run away: unattended triggering
  needs hard budget, frequency and permission fences before the first run fires.

## What exists already

The manual-trigger machinery ships: `core/agent/` (bounded pydantic-ai tool loop,
threads, tools, pricing and the real-USD budget), AI delegatees on the roster, and
A2A peer channels. Nothing triggers a run without a user action, and that invariant
holds until this decision is revisited.
