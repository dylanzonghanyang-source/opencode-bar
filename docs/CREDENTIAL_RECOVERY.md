# Credential Recovery Guide

Every monitored provider depends on a credential stored outside this app (a CLI
config file, a browser session, or an API key). When one expires, the provider
row in the menu shows **"Authorization expired"** and — for providers with a
known recovery flow — a **Fix:** line inside its submenu. This document is the
same guidance in long form, so future expiries can be diagnosed without
reverse-engineering logs.

## Symptom map

| Menu row shows | Meaning | Where the credential lives |
| --- | --- | --- |
| `Provider (Authorization expired)` | Credential exists but the server rejects it | See per-provider table below |
| `Provider (No Credentials)` | Credential never configured | Run the login command / set the key |
| `Provider (Rate limited)` | Server 429 | Wait; not a credential problem |
| Provider row disappears entirely (no usage, no error row) | Non-whitelisted provider with an error and no cached metric | Check the app log (Console.app, filter `OpenCode Bar`) |

## Per-provider recovery

| Provider | Credential source | Recovery command / action |
| --- | --- | --- |
| Command Code | `~/.commandcode/auth.json` (CLI API key) | `cmd logout && cmd login` — plain `cmd login` short-circuits with "Already logged in" and does **not** reissue the key |
| ChatGPT (Codex) | OpenCode-managed ChatGPT token (`~/.local/share/opencode/auth.json`) | Run `opencode` in Terminal once; OpenCode refreshes the token only while the CLI runs. The app never rewrites this file by design |
| Z.AI Coding Plan | API key in app Settings | Generate a new key at z.ai, update in Settings |
| DeepSeek | API key in app Settings | Generate a new key at platform.deepseek.com, update in Settings |
| DashScope | API key in app Settings | Generate a new DashScope key, update in Settings |
| TIMICC | API key in app Settings | Update the key in Settings |
| OpenCode Go | API key in app Settings | Update the key in Settings |
| SuperGrok | API key in app Settings | Update the key in Settings |

## Design notes (for maintainers)

- `MainMenuProviderPresentation.authorizationExpiryVisibleProviders`
  (CopilotMonitor/App/StatusBarController.swift) lists providers whose
  auth-expired row must stay visible instead of being hidden when no cached
  metric exists. Add every provider a user depends on to this set.
- `MainMenuProviderPresentation.credentialRefreshHint(for:)` maps a provider
  to the "Fix:" line rendered in its error submenu. Keep it in sync with this
  document — the menu text is the short form of the row above.
- Error classification lives in
  `isMissingCredentialError` / `isAuthorizationExpiredError` in the same file.
  "Configured but rejected" (401/403/expired) and "never configured" are
  deliberately distinct: only the former is surfaced as **Authorization
  expired**.
- The app treats credential files owned by external CLIs (`auth.json` for
  Command Code / OpenCode) as read-only: it reads them to build requests and
  reports expiry, but refresh is always the owning CLI's job.
