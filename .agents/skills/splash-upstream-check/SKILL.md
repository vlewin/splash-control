---
name: splash-upstream-check
description: Check an incoai/splash release for changes affecting SplashControl (GET /status shape, spawn flags, protocol versions) against explicit tags, using the gh CLI or a read-only local splash checkout. Use when a new splash server version is out and the tray's compatibility has to be triaged before any code changes.
---

# Splash Upstream Check

Upstream-only triage: what a new `incoai/splash` release changes on the
surfaces SplashControl consumes, classified into what must be adapted vs
what is behaviour-only vs internal. Produces a report, never code changes.

## Preconditions

- Working directory is the splash-tray repo (tray paths below are repo-relative).
- Two version arguments: old tag and new tag (e.g. `1.2.1` → `1.4.0`).
- Upstream reads are tag-pinned: `gh api 'repos/incoai/splash/contents/<PATH>?ref=<TAG>'`
  with explicit `--repo incoai/splash`, **or** a local splash checkout read with
  `git show "<TAG>:<path>"`. A checkout is read-only here — never edit, build, or
  switch branches in it, and pin it to the tag before trusting it (its `HEAD` is
  not the installed release).
- Reference documentation must stay environment-agnostic: no absolute paths,
  machine names, or usernames.

## Workflow

1. Release notes (raw output, small):
   ```bash
   gh release view <NEW> --repo incoai/splash --json name,body,tagName
   ```
2. Pinned paths — fetch each at **both** tags and diff locally. Do not use the
   compare API to decide *which* of these changed: it returns at most 300 files
   and silently drops the remainder (measured on 1.3.2 → 1.4.0: exactly 300
   files, `server/serve_options.py` absent although it changed by 134 lines).
   ```bash
   gh api 'repos/incoai/splash/contents/<PATH>?ref=<TAG>' --jq '.content' | base64 -d
   # or, with a checkout: git show "${TAG}:<PATH>"   # quote it: zsh reads $TAG:r as a modifier
   ```
   Pinned paths and what each answers:
   - `runtime/engine/Status.cpp` — the only file whose change adds, renames, or
     removes a published `/status` key (nested keys come from
     `runtime/engine/MemoryPlan.cpp` too).
   - `server/serve_options.py` — every `splash serve` flag, its parser, and its
     ceiling (`MAX_YARN_CONTEXT_TOKENS`, `_SIZE_UNITS`).
   - `server/protocol.py` — `STATUS_SCHEMA_VERSION` (HTTP surface we consume) vs
     `PROTOCOL_VERSION` (native engine↔server wire, internal).
   - `server/backend.py` `status()` — transport wrapper and engine-JSON
     passthrough (proves a key reaches HTTP, short of a live probe).
3. Flag delta, stated as a table, never as prose:
   ```bash
   for t in <OLD> <NEW>; do git show "${t}:server/serve_options.py" | rg -o '"--[a-z-]+' | sort -u > flags_$t.txt; done
   comm -13 flags_<OLD>.txt flags_<NEW>.txt   # new upstream flags
   comm -23 flags_<OLD>.txt flags_<NEW>.txt   # removed upstream flags
   ```
   Then cross-check against what the tray actually emits
   (`Sources/SplashControl/SplashProcess.swift` `buildLaunchArgs`, `gatedFlags`)
   and what it can store (`Sources/SplashControl/Config.swift`, `SplashConfig`).
   Any upstream flag the tray never emits is a **gap**, not a break: `extraArgs`
   already passes arbitrary flags through. A gap only becomes adaptation-required
   when the flag changes a ceiling the tray hard-codes (context, memory, cache).
4. `/status` key delta, same way:
   ```bash
   for t in <OLD> <NEW>; do
     for f in runtime/engine/Status.cpp runtime/engine/MemoryPlan.cpp; do
       git show "${t}:$f" | rg -o '\\"[a-z_]+\\":' | sed 's/\\//g'
     done | sort -u > keys_$t.txt
   done
   comm -13 keys_<OLD>.txt keys_<NEW>.txt   # additive keys
   comm -23 keys_<OLD>.txt keys_<NEW>.txt   # removed keys → BREAKING
   ```
   Removed or renamed keys are the only schema break; additive keys are display
   candidates. Key-walk `Tests/Fixtures/status_schema*.json` against
   `Sources/SplashControlKit/StatusDTO.swift` for DTO gaps, and note pre-existing
   gaps separately from newly introduced ones. Fixtures are hand-trimmed to the
   keys the tray reads, so they are not a source of truth for upstream's key set.
5. Classify every delta:
   - **adaptation-required**: removed/renamed `/status` key, a changed ceiling
     the tray hard-codes, a schema-version bump.
   - **behaviour-only**: same keys, changed values/semantics (e.g. `--max-cache-disk`
     auto moved to a quarter of free space over a 10G floor; held counts now
     marked by admission itself).
   - **internal**: `PROTOCOL_VERSION` bump, kernels, error dialects, worker pools
     — no tray action.
   - **gap**: a new flag with no Settings field. Report it as a decision, not a
     break.
6. Live probe when a server is up — it outranks every file (AGENTS.md §12):
   ```bash
   curl -s http://127.0.0.1:<port>/status | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['schema_version'], sorted(d))"
   ```
   `<port>` is `config.port`, not necessarily 8000. If nothing is listening, mark
   schema facts ⚠️ unprobed and say why.
7. Report in the repo's §14 8-section shape, with the flag table and the
   removed-keys list.

## Guardrails

- A local splash checkout is read-only in this flow: no edits, no builds, no
  branch switches, no running its tests.
- Never present a source-read shape as confirmed on the wire — only the live
  probe confirms the published name/shape.
- `STATUS_SCHEMA_VERSION` is the HTTP contract; a `PROTOCOL_VERSION` bump alone
  requires no tray change.
- New DTO fields are always optional — never make an existing optional key
  required.
- Flags are gated on the binary's own `serve --help` output (`probeServeFlags`).
  A flag added upstream must be gated the same way, or an older binary crash-loops
  on strict `parse_args`.
- Distinguish `state`/`share`-level display candidates from calibration minutiae;
  display scope is a follow-up decision, not part of this check.
