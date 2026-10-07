# ARCHITECTURE.md

Technical architecture, runtime contract, and system integration for Splash Control (`SplashControl`).

---

## 1. System boundary & Architecture overview

Splash Control is a macOS menu-bar app (SwiftUI + AppKit) that starts, monitors, and controls a running `splash` LLM server. It resolves the `splash` binary (config override → `/opt/homebrew/bin/splash` → `/usr/local/bin/splash` → `PATH`), spawns `splash serve`, polls `GET /status` on `127.0.0.1:8000`, and renders six tabs:
**Live, Metrics, Statistics, Logs, Settings, Info** (benchmark UI lives inside Statistics).

There is **no backend of our own.** The splash server is the system under observation; this app only reads it. The runtime lives in a separate repository (`incoai/splash`).

---

## 2. Locked stack & Invariants

- **Language**: Swift, `swift-tools-version:5.10`, a `SplashControl` executable target, a small `SplashControlKit` DTO library (`StatusDTO`, `SplashClient` — SPM forbids test targets from depending on executables), and a `SplashControlKitTests` target.
- **Platform floor**: `Package.swift` declares `.macOS("26.4")`, mirroring the runtime's floor (splash 1.2.x requires **Apple M3+ / macOS 26.4+**). `Resources/Info.plist`'s `LSMinimumSystemVersion` must match.
- **UI**: SwiftUI + AppKit menu-bar integration (`TrayController`).
- **Zero external SPM dependencies**: `Package.swift` has none and none get added.
- **Build**: `make build` (inner loop) · `make app` (assembles `dist/Splash.app`, ad-hoc signed) · `make check` (both assertion suites). Targets delegate to `Scripts/`; the Makefile holds no logic.
- `StatusDTO` is a **mirror of the server schema**, not our domain model. Conversions into display models happen in `StatsModel`/views.
- Dynamic auto-fit content height: tabs report inner height via `ContentHeightKey`, clamped to minimum 380pt.
- **Subprocess isolation from the render path (BUG-17):** never run synchronous subprocesses (`Process.waitUntilExit()` via `runTool`, e.g. `lsof`/`netstat`) inside a SwiftUI view body, helper, or computed getter — `waitUntilExit()` pumps the runloop and re-enters SwiftUI rendering (fatal `EXC_BAD_ACCESS`). Probe results live in `@Published` properties refreshed asynchronously by the poll loop.

---

## 3. The menu-bar dot state machine

The dot has **two independent axes**. Conflating them is the most common regression:
- **Service**: `down · starting · restarting · up · failed`
- **Agent**: `decoding · loading · idle · queued · …`

`StatsModel.trayLook(service:agent:) -> TrayLook` is the **only** place the two meet. `TrayController` calls it from `updateIcon`, `redrawDot`, and `updateTitle` alike. Never re-derive the state anywhere else.

**Service state wins only when the service is unhealthy.** When it is up, the agent decides the colour — and `up` with *no snapshot yet* is **grey ("don't know yet")**, never an empty ring. An empty ring means exactly one thing: no server.

| state | dot | meaning |
|---|---|---|
| prefill running, nothing decoded yet | ⚪️ **white, blinking** | waiting for a first token |
| `decoding` | 🟢 **green, blinking** | producing |
| `idle` | ⚪️ grey, solid | up, healthy, nothing to do |
| `queued` · `suspended` · `draining` · `recovering` · `stale` · `budgetCapped` · `memoryPressure` | 🟠 orange | needs attention |
| `error` | 🔴 red | failed |
| `starting` / `restarting` | 🟣 purple | a restart, **not** engine pressure |
| no server | **empty ring** | nothing asserts a server is there |

- Dot **size** is the primary ok-vs-warn separator (0.34 / 0.36 / 0.46 / 0.50), not hue.
- `budgetCapped` / `memoryPressure` outrank the agent phase: a green dot must never hide an active memory warning.
- Idle weight release: since 1.2.0 the engine frees weights 10 minutes after the last request and restores on the next. `weights.released` (1.2.1+) is authoritative.

---

## 4. The splash runtime contract

Everything here was traced in the `incoai/splash` source and probed against live servers.

### 4.1 Version pinning
The installed runtime is the Homebrew stable release `incoai/tap/splash` (`/opt/homebrew/bin/splash` → Cellar).
- Check installed release: `splash --version`.
- Live server serves **`schema_version 6`**.
- Schema 6 renames/deletions:
  - `kv.resident_backing_bytes` → `kv.allocated_bytes` (conservative floor)
  - `latency.ttft` → `latency.http_ttft` (`splash_http_ttft_seconds` in `/metrics`)
  - New section in 1.2.1: `weights` (`idle_release_seconds`, `released`, `restores`).
- `StatusDTO` must stay an **all-optional subset**: keys a release predates stay optional.

### 4.2 Model acceptance
`splash serve --model owner/repo[:VARIANT]` resolves targets from metadata alone (`config.json` or GGUF header).
- **Format**: MLX targets require affine 4-bit, group size 64. GGUF targets require native tensor types.
- **Family**: Registry matches `Qwen3.8-27B` (`qwen3_5_text`) and `Qwen3.6-35B-A3B` (`qwen3_5_moe_text`). Repository names play no part.
- Models live under `~/Library/Application Support/Splash/models/<owner>/<name>`. Model discovery is a directory scan of selection symlinks.

### 4.3 Which `/status` keys mean "the GPU is working"
The only live (not lifetime or last-batch) in-flight gauges are:
`scheduler.prefilling`, `scheduler.decoding`, `scheduler.waiting_mask`, `scheduler.queued`, `scheduler.waiting_prefix`, `scheduler.waiting_resources`, `admission.waiting{,_memory,_concurrency}`, `admission.suspended`, `admission.draining`. All read 0 on an idle server.

Traps:
- `metrics.current_{prefill,decode}_batch` are **not live** (hold the last batch and stay valid while idle).
- `frontend.active` reads 0 even mid-generation (preparation stage only).
- `cache.hit_rate` is lifetime, not a window. Read `kv.pages_cache` instead.
- There is no per-client or agent identity on any endpoint; displayed activity is aggregate engine state.

### 4.4 Stale semantics
A status query that times out under heavy GPU work returns the last snapshot with `ready: false` and `transport.status_stale: true`. Must be treated as *stale/last known*, never as *down*. Maps to severity `.warn` (orange).

### 4.5 Request metrics math
- Monotonic stamps: `arrived` → `started` → `firstToken` → `done`.
- `prefill = started → firstToken`, `decode = firstToken → done`, `wall = arrived → done`.
- TTFT includes queue wait, prefix lookup, and prefill of uncached tokens only.
- First emission batch is excluded from tok/s numerator to avoid speculative draft inflation.

### 4.6 `splash serve` CLI surface
The argument parser is strict (`parse_args`); an unknown flag causes an immediate crash-loop (exit 2).
`SplashProcess.buildLaunchArgs` passes 17 supported flags (`--model`, `--port`, `--max-memory`, `--max-context`, `--kv-format`, `--max-cache-disk`, `--allowed-host`, `--max-request-size`, `--max-image-pixels`, `--api-key`, `--no-webui`, `--language-only`, `--persistent-cache`, `--idle-release`, `--served-model-name`, `--announce-served-name`, `--default-reasoning-effort`).

Flag rules:
- `--persistent-cache` (1.2.0+) strictly requires `--max-cache-disk`.
- `--idle-release` accepts only `off` or numbers with single `s`/`m`/`h` suffix (`15` = 15 seconds).
- `extraArgs` cannot pass request parameters (e.g. `--temperature` will crash-loop).
- Reasoning effort is a prompt template variable, not an engine flag.

### 4.7 Memory, SSD cache & quotas
- State growth is charged against `memory_governor.charged_bytes`.
- The SSD quota (`--max-cache-disk`) is a reservation gate: `disk.used_bytes` is the whole use (includes KV). Pinned/adopted content may keep snapshot above 100% until swept.
- Physical prefix cache lives in `~/Library/Caches/Splash/prefix-cache` (14-day retention).

### 4.8 Console lines and request tracing
`splash serve` prints one human line per request, mirrored in `SplashLog`. Never parse console lines for data `/status` provides. For local request source tracing, `Scripts/splash-trace-inject.sh` temporarily instruments the Homebrew Cellar `server.py` with `SPLASH_DEBUG=1`.
