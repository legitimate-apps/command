# Epic — iPad · multi-user · device PIN lock · server recurrence/iCal · monetization scaffolding

Dated 2026-06-23. **Status: implemented.**

Constraints: thoroughly tested, landed behind **feature flags (default OFF)** so each part
can be enabled independently. PIN: **6-digit default, allow 4, + Face/Touch ID**.

---

## 0. Feature-flag system (foundation)

`ios/Command/Support/FeatureFlags.swift` — a single source of truth.

- Backed by `UserDefaults` overrides (dev toggles via launch args `-COMMAND_FF_<name> YES`)
  layered over compile-time defaults. `#if DEBUG` exposes a toggles screen in Account.
- Flags (all default **false** so the shipped/TestFlight behaviour == build 25):
  - `ipadLayout` — the adaptive `NavigationSplitView` path (compact/iPhone is unchanged either way).
  - `deviceLock` — per-user PIN + auto-lock.
  - `multiUser` — local account roster + switcher.
  - `credits` — pay-per-token credit UI.
- Server: a `settings` row `monetization.credits_enabled` (default false) gates the credit
  ledger + gating so the REST/MCP surfaces behave exactly as today until flipped.

Rule: a flag OFF must be **provably identical** to current behaviour (the `else` branch is the
existing code path, not a reimplementation).

---

## 1. iPad universal layout (`ipadLayout`)

- `ios/project.yml`: `TARGETED_DEVICE_FAMILY: '1,2'`; allow landscape on iPad only
  (`INFOPLIST_KEY_UISupportedInterfaceOrientations~ipad`). iPhone stays portrait.
- Adaptive root: on **regular** horizontal size class → `NavigationSplitView` with a sidebar of
  the five destinations (Calendar, Notes, Assistant, Tasks, People); on **compact** → the
  existing `MainTabView` unchanged. Switch on `@Environment(\.horizontalSizeClass)`.
- Audit for iPhone-assumptions: fixed widths, `UIScreen.main`, portrait-only geometry, the
  capture dock `safeAreaInset`, sheet sizing. Fix per-modality.
- Verify: iPad sim (portrait+landscape, Split View) **and** iPhone sim (no regression) via the
  screenshot harness. Flag OFF ⇒ MainTabView only.

## 2. Per-user device PIN lock (`deviceLock`)

Client-side at-rest lock over the already-authenticated session. The PIN never leaves the device.

- **Crypto** (`DeviceLock/PinCredential.swift`): verifier = PBKDF2-HMAC-SHA256(pin, salt,
  iterations≈200k) via CommonCrypto. Per-user random 16-byte salt. Store
  `{salt, iterations, verifier}` in the **Keychain**, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  no iCloud sync, keyed by account id. A 4–6 digit PIN is low-entropy → security = Keychain
  hardware protection **plus lockout**, not the hash.
- **Lockout** (`DeviceLock/LockoutPolicy.swift`): failed-attempt counter persisted in Keychain
  (survives relaunch). Exponential backoff after 5 fails; after 10 → wipe local sessions/roster
  and require full re-login. Pure, unit-tested.
- **Biometric**: `LocalAuthentication` `deviceOwnerAuthenticationWithBiometrics`; PIN is always
  the fallback. Per-user opt-in (default on if device has biometrics).
- **Lock state machine** (`DeviceLock/LockController.swift`, `@Observable`): `unlocked` ↔ `locked`.
  `scenePhase != .active` → `locked` immediately + a **privacy overlay** (opaque cover) so the
  app-switcher snapshot can't leak. Foreground → present PIN/biometric for the most-recent account.
- **Tests** (`CommandTests/DeviceLockTests.swift`): verify correct/incorrect PIN, salt uniqueness,
  lockout counting + backoff thresholds, wipe-after-N, round-trip with the Keychain stubbed.
- Flag OFF ⇒ no lock, no overlay (build 25).

## 3. Multi-user roster + switcher (`multiUser`)

Server already issues a **fresh session per login** (no single-session cap — verified in
`core/accounts.py`), so a device can hold several accounts' session tokens concurrently.

- **Storage** (`Accounts/AccountRoster.swift`): Keychain-backed list of
  `DeviceAccount{ id, username, displayName, sessionToken, lastActiveAt }`, device-bound.
- **APIClient**: the active account's `command_session` token is applied per request (the client
  already has cookie apply/store helpers). `setActiveSession(token)` swaps it; login captures the
  Set-Cookie token to persist in the roster.
- **AppState**: `roster`, `activeAccountId`, `switchTo(_:)` (requires PIN via §2), `addUser()`
  (runs the existing login/register, appends, sets PIN). Sign-out removes that account's
  session+PIN from the device.
- **UI**: switcher in the sidebar (iPad regular) / a bottom sheet (iPhone compact) with avatars +
  "Add user." Lands on the lock screen when a switch needs a PIN.
- **Tests**: roster add/remove/switch, active-session resolution, sign-out cleanup.
- Flag OFF ⇒ single-account path (build 25) unchanged.

## 4. Server recurrence reminders + iCal export

- **iCal** (`rest/calendar_ics.py`): `GET /api/calendar.ics` (auth via session or a per-account
  signed token) → a `VCALENDAR` with `VEVENT`s for occurrences in a window (routine rrule expanded
  + sporadic), so Apple Calendar can subscribe. Pure formatting over existing `core` calendar data.
- **Reminders** (`core/reminders.py`): compute upcoming assignment reminders from rrule + lead
  time; `GET /api/reminders/upcoming`. **Delivery** (APNs push) is a separate, blocked step (no
  push cert/entitlement yet) — this builds the computation + endpoint; push is wired later.
- **Tests**: ics formatting (golden VEVENTs, escaping, TZ), reminder windowing/lead-time math.

## 5. Monetization credit scaffolding (`credits` / `monetization.credits_enabled`)

**Decision (operator to confirm):** subscription = **unlimited** Assistant; credits =
**pay-as-you-go consumable packs** for non-subscribers; gate = consent AND (subscribed OR balance>0).

- **Ledger** (`core/credits.py`): `credit_accounts(account_id, balance)` +
  `credit_transactions(account_id, delta, reason, ref, created_at)`. Decrement on agent usage by
  tokens spent (the agent already meters tokens); grant via the RevenueCat **consumable** webhook
  (extends the existing timing-safe webhook). Idempotent on transaction ref.
- **Gate**: extend `AppState.resolveGate` + the server entitlement so the paywall offers BOTH
  "Subscribe" and "Buy credits"; Assistant runs if subscribed OR balance>0; on exhaustion → paywall.
- **iOS**: a balance meter + "Buy credits" option (StoreKit consumable product ids defined in code;
  **no ASC products created** — they resolve empty until the operator creates them, by design).
- **Tests**: ledger math, idempotent grant, gate precedence (sub vs credits), exhaustion → paywall.
- Server flag OFF ⇒ entitlement/gate behave exactly as today.

---

## Verification ledger (kept honest, updated as built)

| Epic | Built | Unit tests | Sim/iPad verified | Notes |
|------|-------|-----------|-------------------|-------|
| 0 Feature flags | ✅ | n/a | ✅ build | all default OFF; UserDefaults/launch-arg resolved |
| 1 iPad layout | ✅ | n/a | ✅ iPad split + iPhone tabs (no regression) | `-COMMAND_FF_ipadLayout`; regular→split, compact→MainTabView |
| 2 PIN lock | ✅ | ✅ 9 tests | ✅ lock screen renders | crypto+lockout unit-tested; interactive lock/unlock = operator device-test |
| 3 Multi-user | — | — | — | |
| 4 Recurrence/iCal | ✅ | ✅ 9 tests | n/a | ruff+mypy clean; full suite 123 green; push delivery blocked (APNs); needs COMMAND_CALENDAR_EXPORT_SECRET to enable |
| 5 Credits | ⚙️ backend | ✅ 7 tests | — | server: ledger + migration + webhook grant + gate + entitlement balance, all behind `credits_enabled` (default off). iOS credits UI + per-token debit metering = remaining. ASC products deferred. |

Nothing is "done" until this table shows evidence. Flags OFF must equal build 25.
