# Decision (2026-07-06): AI budget in real USD, credits as a display unit

## Model

- **The backend is USD, always.** The server tracks a real-USD AI budget per
  account (`ai_budget_usd_remaining` on the entitlement row), in the same currency
  `pricing.py` computes turn costs in.
- **Credits are display only.** One constant, `CREDIT_MULTIPLIER = 3`; the client
  shows `backend_usd × 3` with a `$` prefix. Nothing stores credits.

## Grant

On subscription activation and every renewal (RevenueCat `INITIAL_PURCHASE` /
`RENEWAL` / `PRODUCT_CHANGE`), **set** the balance to
`subscription_price_usd / CREDIT_MULTIPLIER`. It resets each period; it does not
accumulate.

## Debit

Each agent turn debits its actual real-USD API cost from the balance, in the same
block that records the cost. The next turn is gated when the balance can no longer
cover a turn.

## Display

The paywall and meter show `balance_usd × 3`, so a fresh period shows the
subscription price as the credit amount.

## Interaction with the flat cap

The older flat monthly agent cap (`agent_usage`) remains the behavior for
unsubscribed or complimentary accounts; for a subscribed account the budget
governs. Self-hosted servers leave `COMMAND_AGENT_REQUIRE_SUBSCRIPTION` off and are
not gated at all. Plumbing: `core/entitlements.py`, `POST /api/webhooks/revenuecat`,
and the gate in `rest/agent.py`.
