---
name: splash-upstream-check
description: Check an incoai/splash release for changes affecting SplashControl (GET /status shape, spawn flags, protocol versions) using only the gh CLI against explicit tags. Use when a new splash server version is out and the tray's compatibility has to be triaged before any code changes.
---

# Splash Upstream Check

Upstream-only triage: what a new `incoai/splash` release changes on the
surfaces SplashControl consumes, classified into what must be adapted vs
what is behaviour-only vs internal. Produces a report, never code changes.

## Preconditions

- Working directory is the splash-tray repo (tray paths below are repo-relative).
- Two version arguments: old tag and new tag (e.g. `1.2.1` → `1.3.0`).
- No local splash checkout. All upstream reads go through `gh` with explicit
  `--repo incoai/splash` (or the `repos/incoai/splash/` API prefix).
  Reference documentation must stay environment-agnostic: no absolute paths.

## Workflow

1. Release notes (raw output, small):
   ```bash
   gh release view <NEW> --repo incoai/splash --json name,body,tagName
   ```
2. Scope the diff to the pinned paths (the full compare is tens of
   thousands of lines — never pull it whole):
   ```bash
   gh api repos/incoai/splash/compare/<OLD>...<NEW> --jq '[.files[].filename]'
   ```
   Pinned paths and what each answers:
   - `runtime/engine/Status.cpp` — the only file whose change adds,
     renames, or removes a published `/status` key.
   - `runtime/engine/MemoryPlan.cpp` — `memory_plan` sub-keys
     (e.g. `ane_ffn_bytes`; check whether the key is new or predates).
   - `server/protocol.py` — `STATUS_SCHEMA_VERSION` (HTTP surface we
     consume) vs `PROTOCOL_VERSION` (native engine↔server wire, internal).
   - `server/serve_options.py` — new `splash serve` flags (spawn-side
     candidates, e.g. `--disable-ane`).
   - `server/backend.py` `status()` — transport wrapper and engine-JSON
     passthrough (proves the key reaches HTTP, short of a live probe).
3. Fetch each pinned file at both tags and diff locally (avoids compare-API
   truncation):
   ```bash
   gh api 'repos/incoai/splash/contents/<PATH>?ref=<TAG>' --jq '.content' | base64 -d
   ```
4. Classify every delta:
   - **adaptation-required**: new/renamed/removed `/status` key, new spawn
     flag, schema-version bump.
   - **behaviour-only**: same keys, changed values/semantics (e.g. held
     counts now marked by admission itself; `/status` reads no longer
     mutating hysteresis).
   - **internal**: native protocol bump, kernels, error dialects, worker
     pools — no tray action.
5. Cross-check the tray side read-only (repo-relative):
   - Key-walk `Tests/Fixtures/status_schema*.json` against the engine keys;
     list DTO gaps (`Sources/SplashControlKit/StatusDTO.swift`).
   - Note pre-existing gaps separately from newly introduced ones.
6. Report in the repo's §14 8-section shape. The live probe (`brew upgrade`
   splash → restart → diff `:8000/status` vs the fixture) is out of scope
   for this check — mark unprobed schema facts ⚠️ with the reason stated.

## Guardrails

- Never edit, build, or reference a local splash checkout from this flow.
- Never present a source-read shape as confirmed on the wire — only the
  live probe confirms the published name/shape.
- `STATUS_SCHEMA_VERSION` is the HTTP contract; a `PROTOCOL_VERSION` bump
  alone requires no tray change.
- New DTO fields are always optional — never make an existing optional key
  required.
- Distinguish `state`/`share`-level display candidates from calibration
  minutiae; display scope is a follow-up decision, not part of this check.
