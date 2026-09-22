# MLX Desk Improvement Tracker

Last updated: 2026-08-14

Status meanings: **Done** is implemented and verified; **Partial** has useful implementation but remaining acceptance criteria; **Blocked** requires external credentials or infrastructure; **Planned** has not started.

| # | Recommendation | Status | Acceptance criteria | Evidence / remaining work |
|---|---|---|---|---|
| 1 | Supervised runtime state machine | Done | Explicit phases, operation identity, stale-result rejection, cancellation, bounded recovery, restart circuit breaker | Implemented phase detail, operation IDs, cancellation, cleanup, and a tested restart circuit breaker. |
| 2 | Real liveness and readiness checks | Done | Process check, HTTP liveness, one-token readiness, no health traffic during generation | Native-container readiness and legacy process/endpoint/one-token probes are separately surfaced in Diagnostics. |
| 3 | Native MLX Swift runtime | Done | Default inference path uses `mlx-swift-lm`; Python server is optional fallback; no localhost dependency in native mode | `mlx-swift-lm` 3.31.4 is the default. Set `MLX_DESK_USE_LEGACY_SERVER=1` only for compatibility. |
| 4 | Model validation and trust | Done | Manifest/config/tokenizer checks, trusted-source label, smoke generation, incompatible model quarantine, revision recorded | Cache structure/tokenizer validation, trust filtering, revision display, and revision-scoped automatic quarantine with manual reset are implemented. |
| 5 | Resource preflight and lifecycle | Done | Disk, RAM, cache integrity, port/process ownership, sleep/wake, memory pressure, unload policy | Disk/RAM/cache checks, safe legacy port ownership, sleep unload/wake recovery, and critical-memory-pressure unload are implemented and tested. |
| 6 | Loading and progress feedback | Done | Download, verify, load, warm-up, readiness phases; cancellation; bytes and elapsed time | Phase, percent, bytes, elapsed time, explicit cancellation, and stale-result cleanup are implemented. |
| 7 | Actionable error experience | Done | Plain-language category, recovery actions, details, copy/export support bundle, prompt redaction | Recovery UI, readiness action, diagnostic detail, and redacted JSON support bundle are implemented. |
| 8 | Distribution for other users | Blocked | Proper app bundle, Developer ID signing, notarization, sandbox/entitlements decision, updater, privacy disclosure, licenses | Repeatable bundle/sign/zip script and privacy disclosure added. Public notarization and updater require a Developer ID certificate, release URL, and update signing key. |
| 9 | Fault and endurance testing | Done | Automated kill, timeout, corrupt cache, low disk, model switch, sleep/wake, long output, cancellation, multi-launch, soak tests | Deterministic launch/generation/stall faults, low disk, corrupt cache, model switching, sleep/wake, cancellation, single-instance enforcement, and repeated-generation soak coverage are implemented. |
| 10 | Production diagnostics | Done | Structured `OSLog`, operation IDs, performance events, local crash/hang reports, opt-in telemetry boundary | Structured local events, redacted export, and local-only MetricKit crash/hang payload retention are implemented. |

## Current Baseline

- Native SwiftUI macOS interface targeting macOS 14.
- Native `mlx-swift-lm` 3.31.4 runtime by default; Python server is an opt-in fallback.
- Dynamic MLX model catalog powered by bundled llmfit.
- 35 automated tests passing after the reliability, lifecycle, and productization passes.
- Packaged app is ad-hoc signed; no valid Developer ID signing identity is installed on this Mac.
- Known production risk: upstream documentation says `mlx_lm.server` is not recommended for production.

## Release Gate

All engineering release gates are Done. Broad public distribution remains blocked only on item 8's external Apple signing/notarization credentials and hosted update infrastructure; the current build is an ad-hoc-signed development preview.

## Credential-Free Productization Backlog

| Enhancement | Status | Evidence |
|---|---|---|
| Sparkle updater integration | Done (dormant) | Sparkle 2.9.5 is embedded and code-signed; updater starts only with a valid HTTPS feed and EdDSA public key. |
| Check for Updates and release channel UI | Done | Settings exposes Stable/Preview and a safely disabled update action until configured. |
| Release and notarization automation | Done (credential-gated) | `release-preview.sh` builds/signs/DMGs now and automatically notarizes when the two credential variables exist. |
| DMG installer | Done | Repeatable compressed DMG includes MLX Desk and an Applications shortcut. |
| First-launch onboarding | Done | Non-dismissible privacy/hardware/compatibility guide routes directly to the ranked model catalog. |
| Model storage manager | Done | MLX-owned caches only; size/status, verify, reveal, pause/resume, and confirmed deletion. |
| Interrupted download recovery | Done | Pause cancels safely; native Hugging Face cache resumes incomplete downloads on the next start. |
| Configurable idle unloading | Done | Never/5/15/30/60 minute policy persisted in Settings. |
| Battery and thermal safeguards | Done | Low Power Mode and serious/critical thermal pressure can unload an idle model. |
| Performance history | Done | Local rolling history of tokens/sec and first-token latency, with clear action and no prompt content. |
| Compatibility report | Done | Redacted JSON export includes hardware, revision, preflight, health, and owned cached-model identifiers. |
| UI/accessibility coverage | Done | Deterministic UI-state tests plus packaged accessibility smoke flows for onboarding, catalog, Settings, storage, performance, diagnostics, copy/download, and cancellation. |
| Localization infrastructure | Done | Standard English and Spanish `.lproj` resources with localized primary productization titles. |
| Third-party notices | Done | Notices are regenerated from resolved checkout licenses during every package build and bundled with the app. |
