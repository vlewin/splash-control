# AGENTS.md

The working contract for humans and AI agents changing this repository. Read it
in full before writing code. It is the only file you must read *at session
start*. When a task touches the runtime, the UI, or screenshots, § 13 says
which reference doc to open.

If a task prompt conflicts with this file, **stop and report the conflict**
before proceeding. Do not silently pick a side.

**Working code only. Finish the job. Plausibility is not correctness.**

## 0. Non-negotiables
These rules override everything else in this file when in conflict:

1. **No flattery, no filler.** Skip openers like "Great question", "You're absolutely right", "Excellent idea", "I'd be happy to". Start with the answer or the action.
2. **Disagree when you disagree.** If the user's premise is wrong, say so before doing the work. Agreeing with false premises to be polite is the single worst failure mode in coding agents.
3. **Never fabricate.** Not file paths, not commit hashes, not API names, not test results, not library functions. If you don't know, read the file, run the command, or say "I don't know, let me check."
4. **Stop when confused.** If the task has two plausible interpretations, resolve it by reading the code or asking (§ 8) — never pick silently and proceed.
5. **Touch only what you must.** Every changed line must trace directly to the user's request. No drive-by refactors, reformatting, or "while I was in there" cleanups.

## 1. Before writing code
**Goal: understand the problem and the codebase before producing a diff.**

- State your plan in one or two sentences before editing. For anything non-trivial, produce a numbered list of steps with a verification check for each.
- Read the files you will touch. Read the files that call the files you will touch. Use CodeGraph (tool priority in § 5.1) or subagents for exploration so the main context stays clean.
- Match existing patterns in the codebase. If the project uses pattern X, use pattern X, even if you'd do it differently in a greenfield repo.
- Surface assumptions out loud: "I'm assuming you want X, Y, Z. If that's wrong, say so." Do not bury assumptions inside the implementation.
- If two approaches exist, present both with tradeoffs. Do not pick one silently. Exception: trivial tasks (typo, rename, log line) where the diff fits in one sentence.

## 2. Writing code: simplicity first
**Goal: the minimum code that solves the stated problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code. No configurability, flexibility, or hooks that were not requested.
- No error handling for impossible scenarios. Handle the failures that can actually happen.
- If the solution runs 200 lines and could be 50, rewrite it before showing it.
- If you find yourself adding "for future extensibility", stop. Future extensibility is a future decision.
- Bias toward deleting code over adding code. Shipping less is almost always better.
- The test: would a senior engineer reading the diff call this overcomplicated? If yes, simplify.

## 3. Surgical changes
**Goal: clean, reviewable diffs. Change only what the request requires.**

- Do not "improve" adjacent code, comments, formatting, or imports that are not part of the task.
- Do not refactor code that works just because you are in the file.
- Do not delete pre-existing dead code unless asked. If you notice it, mention it in the summary.
- Do clean up orphans created by your own changes (unused imports, variables, functions your edit made obsolete).
- Match the project's existing style exactly: indentation, quotes, naming, file layout.
- The test: every changed line traces directly to the user's request. If a line fails that test, revert it.

## 4. Goal-driven execution
**Goal: define success as something you can verify, then loop until verified.**

Rewrite vague asks into verifiable goals before starting:
- "Add validation" becomes "Write tests for invalid inputs (empty, malformed, oversized), then make them pass."
- "Fix the bug" becomes "Write a failing test that reproduces the reported symptom, then make it pass."
- "Refactor X" becomes "Ensure the existing test suite passes before and after, and no public API changes."
- "Make it faster" becomes "Benchmark the current hot path, identify the bottleneck with profiling, change it, show the benchmark is faster."

For every task:
1. State the success criteria before writing code.
2. Write the verification (test, script, benchmark, screenshot diff) where practical.
3. Run the verification. Read the output. Do not claim success without checking.
4. If the verification fails, fix the cause, not the test.

## 5. Tool use, CodeGraph, and verification

### 5.1 Codebase discovery with CodeGraph
Do not maintain manual file trees in documentation — use **CodeGraph** (`.codegraph/` SQLite index & MCP server).
- **Always prefer graph tools over raw grep/find for code discovery.**
- **Tool priority**:
  1. `codegraph_explore` or `search_graph` — explore areas, find classes, methods, and call paths in one shot.
  2. `codegraph_node` or `trace_path` — inspect a symbol's implementation and its callers/callees.
  3. `get_code_snippet` — inspect targeted function or struct definitions.
  4. Fall back to grep / file searches only for string literals, shell scripts, config keys, or non-code assets.
- **CLI fallback**: `codegraph <query|explore|node|callers|callees|impact> <symbol>` for symbol work; `codegraph status` / `codegraph sync` for index health.

### 5.2 Rust Token Killer (`rtk`) usage and exceptions
When running CLI commands via bash/zsh, use **Rust Token Killer (`rtk`)** to minimize token usage across outputs.

#### `rtk` output is compressed — never use it for existence checks
`rtk` summarises output to save tokens. For search that means a **no-match query can still return output** — adjacent lines, or the nearest symbol — reading as "found something related" instead of "not found". A query matching nothing is *not* safe to interpret as "that does not exist".

- **"Does X exist?" → exact-match Grep tool, or `rg` WITHOUT the `rtk` wrapper.** Never conclude absence from `rtk rg` output.
- `rtk rg` is fine for *finding candidate sites*, where you verify each hit.
- Precedence: the existence-check rule beats the use-`rtk` rule. `gh`/`brew` existence and small-listing output always runs raw.

### 5.3 Verification principles
- Prefer running the code to guessing about the code. If a test suite exists, run it. If a linter exists, run it.
- Never report "done" based on a plausible-looking diff alone. **Plausibility is not correctness.**
- When debugging, address root causes, not symptoms. Suppressing the error is not fixing the error.
- For UI changes, verify visually: screenshot before, screenshot after, describe the diff.
- When reading logs, errors, or stack traces, read the whole thing. Half-read traces produce wrong fixes. Every error or warning in tool output is explained in the report or filed under Open questions — never silently dropped.

## 6. Session hygiene
- Context is the constraint: long sessions with failed attempts perform worse than fresh ones. **After two failed corrections on the same issue, stop** — summarize what you learned and ask the user to reset the session with a sharper prompt.

## 7. Communication style
- **Direct, not diplomatic.** "This won't scale because X" beats "That's an interesting approach, but have you considered...".
- **Concise by default.** Two or three short paragraphs unless the user asks for depth. No padding, no restating the question, no ceremonial closings.
- When a question has a clear answer, give it. When it does not, say so and give your best read on the tradeoffs.
- Celebrate only what matters: shipping, solving genuinely hard problems, metrics that moved. Not feature ideas, not scope creep.
- No excessive bullet points, no unprompted headers, no emoji. Prose is usually clearer than structure for short answers.

## 8. When to ask, when to proceed
**Ask before proceeding when:**
- The request has two plausible interpretations and the choice materially affects the output.
- The change touches something you've been told is load-bearing, versioned, or has a migration path.
- You need a credential, a secret, or a production resource you don't have access to.
- The user's stated goal and the literal request appear to conflict.

**Proceed without asking when:**
- The task is trivial and reversible (typo, rename a local variable, add a log line).
- The ambiguity can be resolved by reading the code or running a command.
- The user has already answered the question once in this session.

## 9. Project Learnings & Self-improvement loop
This section accumulates concrete corrections. When corrected on your approach, append a concrete one-line rule below ("Always use X for Y", not "be careful with Y"). If an existing rule covers it, tighten it.

- *Learnings log*:
  - Never commit or push without explicit user approval — stage, show the diff and proposed message, wait for confirmation.
- *Rotation / prune test*: keep this log to ≤ 10 entries (fold durable rules into their section when it exceeds); every few weeks, delete any line whose removal would cause no mistake.
- *Size budget*: ≤ ~320 lines / ≤ 20 KB — 2026 guidance (vLLM caps at 200/300 lines, Codex truncates at 32 KiB). New detail goes to a reference doc, not here.

## 10. Project context & Invariant constraints

### System boundary
Splash Control (`SplashControl`) is a macOS menu-bar app that starts, monitors, and controls a running `splash` LLM server. It polls `GET /status` on `127.0.0.1:8000` and renders six tabs (**Live, Metrics, Statistics, Logs, Settings, Info**).

There is **no backend of our own.** The runtime lives in a separate repository (`incoai/splash`) — never edit it from here. Upstream findings go in the report, tagged *upstream*.

### Locked stack
- **Language**: Swift, `swift-tools-version:5.10`, app target `SplashControl` + `SplashControlKit` DTO library (hosts the test target; SPM 5.5+ allows test→executable deps, so the kit exists to keep tests cross-platform while the app stays macOS-gated).
- **Platform floor**: `Package.swift` declares `.macOS("26.4")`, mirroring the runtime's floor (splash 1.2.x requires **Apple M3+ / macOS 26.4+** — installed release 1.2.1, verified 2026-10-07). Keep `Resources/Info.plist`'s `LSMinimumSystemVersion` in agreement.
- **UI**: SwiftUI + AppKit menu-bar integration (`TrayController`).
- **Zero external SPM dependencies.** `Package.swift` has none; adding one needs a tradeoff analysis and explicit approval (see §15).
- **Build**: `make build` (inner loop) · `make verify` (all hard gates) · `make app` (assembles `dist/Splash.app`, ad-hoc signed) · `make check` (script suites) · `make test` (DTO suite). Targets delegate to `Scripts/`; the Makefile holds no logic.

### Core invariants & house rules
- `StatusDTO` is a **mirror of the server schema**, not our domain model. Conversions happen in `StatsModel`/views.
- One concern per file. If a view file grows past ~600 lines of new UI, split it.
- Never commit `.build/`, `dist/`, `*.log`, or `issues/` (all gitignored).
- **Reference documentation must stay environment-agnostic.** No absolute home paths, machine names, local usernames, or "the user's Mac". Write `~/…` or a repo-relative path.
- **Don't commit the injected `server.py`** (throwaway local instrumentation inside Homebrew Cellar).
- Incidental cleanups must be minimal, in-task, and explicitly listed with file paths in the report.

### Task state
No transient checklist file is kept in this repo. Session state lives in git history; the per-task report goes to chat in §14 format.

## 11. Verifying your work

The **DTO mirror** (`StatusDTO`, `SplashClient` completion types) is covered
by a Swift Testing target (`make test`), as is the **app logic**
(`SplashConfig` and friends, via the macOS-gated `SplashControlTests`
target — SPM 5.5+ lets test targets depend on executable targets). Both need
a toolchain with the `Testing` module: CLT ships none, so the Makefile
defaults to Homebrew Swift (`SWIFT_TOOLCHAIN=…` overrides). The **rendering
layer** still has no runner (CLT has no `xctest`, `XCUITest` needs Xcode,
zero SPM deps is a hard rule) and is defended by **construction plus static
lints**.

### Checks

```bash
make build    # fast inner loop
make check    # script suites (core + agent-status)
make test     # swift-testing suite (DTO mirror + app logic)
make lint     # formatter gate (strict, zero warnings)
make verify   # all hard gates: check + test + lint, every one green
make app      # assemble dist/Splash.app
```

`make lint` is expected to be clean: the DTOs carry the server's snake_case JSON keys in explicit `CodingKeys` rather than in property names, so the formatter never fights the wire schema. Any warning it emits is new drift to fix, not a baseline to tolerate.

Both check scripts compile the sources with `swiftc` and run assertions; fixtures live in `Tests/Fixtures/`.

### `dist/Splash.app` is the app; `.build/` is not

`swift build` writes `.build/`. The bundle a person actually runs is
`dist/Splash.app`, and **only** `Scripts/make-app.sh` produces it. A debug
binary proves the code compiles; a stale bundle is worse than no build.

After any change to behaviour, UI or Settings:

1. `make app` — not `make build` alone.
2. Quit the running copy, then `open dist/Splash.app`.
3. Confirm the live process path (`ps -Ao pid,command`) really is
   `dist/Splash.app/Contents/MacOS/SplashControl`, not a `.build/` path.
4. Only then report it done, and state the bundle path so a mismatch is obvious.

### Screenshots

```bash
make screenshot VIEW=settings   # live|metrics|stats|logs|settings|info (default: live)
```

Window-targeted; inspect the PNG with your image-viewing tool. **Do not**
parse pixels, probe the accessibility tree, or blind-click by coordinate
(full protocol: § 13).

### Layout safety rules

Read [DESIGN.md](DESIGN.md) before touching any SwiftUI view (which sections: § 13). If code disagrees with it, fix the code.

`check_core.sh` carries static `lint:` greps that pin these shapes. They run in milliseconds; run them.

### Commit on completion

A task is not complete until `make verify` is green, `make-app.sh` has assembled the
bundle, the running app has been relaunched and inspected, and every modified
or new implementation file is committed. A verified change that lives only in
the working tree is one `git checkout` away from gone — the next session
inherits a diff it cannot date.

### Commit format and versioning

- Commit messages: subject under 72 chars, conventional prefix (`feat:`, `fix:`,
  `docs:`, `refactor:`, `chore:`, `style:`, `test:`), body explains the why.
  One concern per commit.
- `Resources/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`)
  moves on release only, never per commit. A batch of verified changes lands
  first; the version bump closes it.

## 12. Sources of truth

In priority order. If a lower source contradicts a higher one, flag it — do not
copy the mistake forward.

1. **This file & [ARCHITECTURE.md](ARCHITECTURE.md)** — process, conventions, and runtime contract.
2. **[DESIGN.md](DESIGN.md)** — design system tokens, colors, typography, and optical alignment.
3. **The live server** — for anything about schema or behaviour, probe it:
   `curl -s http://127.0.0.1:8000/status`. For schema facts this outranks what
   any file says, including ARCHITECTURE.md § 4: docs go stale, the server does not.
4. **`incoai/splash` source** — read the code, don't guess. A local checkout is
   a moving target; pin it against the installed release before trusting it.
5. **Existing code** — for style consistency only.

### Do not answer from memory

For anything that may have moved since your training data — upstream changes,
the current macOS/SwiftUI API surface:

1. `context7` MCP first (`resolve-library-id`, then `query-docs`).
2. Then web search against official sources.
3. If both come up empty, say so and mark the claim unverified. Never present a
   remembered fact as if it had been checked. For CLI surface (`gh`, `brew`),
   check `gh <cmd> --help` before assuming a subcommand exists.

## 13. Reference docs — when to read them

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — read when touching the runtime schema, model gates, the dot, or the process layer. **§ 2**: locked stack & invariants (incl. subprocess isolation). **§ 3**: dot state machine. **§ 4**: splash runtime contract.
- **[DESIGN.md](DESIGN.md)** — read before touching any SwiftUI view or verifying a UI change. Design tokens (§ 1–2), layout safety (§ 2.11), heights (§ 2.9), bar charts (§ 2.7), screenshots (§ 4).

## 14. Report format

Precedence: §14 governs task-report shape; ponytail governs diff size only.

Reply with these eight sections, in this order. Do not reorder or omit:

1. **Files read** — each file touched + one line of its pre-edit state.
2. **Plan** — the plan written before implementing.
3. **Changes** — file-by-file: what changed and why.
4. **Verification** — `swift build`; check scripts; runtime probe (live `:8000` server, or `Scripts/sample_status.py` if unavailable — say which); UI check with the `dist/Splash.app` bundle path; stale/nil handling only if touching `StatusDTO`/polling. Cite evidence per claim; for behaviour, state the observation method — unobserved behaviour is ⚠️ with the reason stated. Source-only confirmation is inference, not verification.
5. **Acceptance criteria** — each: ✅ (machine-checked) / ⚠️ (reasoned but unobserved) / ❌, with evidence.
6. **Deviations from AGENTS.md** — anything done differently and why. "None" is valid. A skipped required step counts as a deviation — declare it here, never as "not needed" elsewhere.
7. **New issues / incidental cleanups** — unrelated touch-ups with file paths, never silent.
8. **Open questions / risks** — anything needing a decision, including upstream findings.

## 15. Boundaries

### Never
- Do not make an optional `StatusDTO` key required.
- Do not treat `ready: false` + `status_stale` as server death.
- Do not edit or build the splash runtime repo from this repo's tasks.
- Do not claim success from `swift build` alone — assemble, relaunch, observe.
- Do not leave changes uncommitted upon completing a task.
- Do not commit or merge unless `make verify` is green — check, test, lint, no exceptions.
- Do not commit on `main` — feature branches + PR; the agent may push its branch for review but only a human merges to `main`. Direct or force-push to `main` needs explicit approval.
- Do not report a change as visible until `dist/Splash.app` is rebuilt **and** relaunched.
- Do not parse `splash serve` console lines for data `/status` provides.
- Do not put a sampling flag in `extraArgs` — it crash-loops the server.
- Do not add outbound network calls from the app; its only peer is the local splash server on `127.0.0.1`.
- Do not use `current_*_batch` or `frontend.active` as live in-flight gauges.
- Do not conflate the **service** and **agent** axes; `trayLook` is the only place they meet.
- Do not render an empty ring for "no data yet" — only for a down service.
- Do not make two dot states differ only by blinking.
- Do not put machine-specific paths, usernames or hardware in this file or any other reference doc.

### Ask first
- SPM dependencies: none get added without explicit approval.

## 16. Provenance

Shape follows the FerroxLabs template: Karpathy's four principles (think-first, simplicity, surgical, goal-driven), Cherny's pruning discipline, Anthropic's verification loops, and the [AGENTS.md](https://agents.md) open standard.
