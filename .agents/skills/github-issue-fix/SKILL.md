---
name: github-issue-fix
description: End-to-end workflow for fixing a GitHub issue in THIS repo (splash-control). Covers triage, regression test, make gates, version bump, conventional commits, PR, and release verification. Use when the user asks to fix, resolve, or close a GitHub issue in this repo.
---

# GitHub Issue Fix Workflow

Project: Splash Control — public GitHub repo, macOS menu-bar app (Swift, zero external
SPM deps) controlling the local `splash` LLM server at 127.0.0.1. The runtime lives
in a separate repo (`incoai/splash`) — never edit it from here.

Gates: `make verify` (check + test + lint) · `make app` (assembles `dist/Splash.app`) ·
`make screenshot VIEW=live|metrics|stats|logs|settings|info` ·
`make run` (quit, rebuild, relaunch from dist, show process path).

Release pipeline: tag on `main` (minted by github-tag-action parsing conventional
commits since the last tag) → release with bundle zip + sha256 + auto changelog.
`feat!`/`fix!`/`!` = major · `feat` = minor · `fix` = patch · `[skip-release]` in the
subject excludes a commit · empty commit set ⇒ no tag.

Process: PR-based. A human merges. The agent pushes its branch only, never `main`, and
only with explicit user approval.

## Workflow

1. **Clean tree.** `git status --porcelain` must be empty before any work or build.
   If dirty, stop and ask.
2. **Read the issue.** `gh issue view N` with labels. Fetch the full body.
3. **Reproduce.** Live server first (`curl -s http://127.0.0.1:9000/status` — the
   user's configured port; check the config, do not assume); `Tests/Fixtures/` and
   `Scripts/sample_status.py` when the server is unavailable. Say which source you
   used in the final report.
4. **Triage.** If the defect belongs upstream in `incoai/splash`, stop and report
   *upstream*. Do not work around upstream behavior in this repo.
5. **Plan** (per AGENTS.md § 1, before any edit): an interpretation check
   ("issue says X, root cause is Y in file Z"), 2–3 approaches with a one-line
   tradeoff each, which gate will prove the fix (test name or screenshot), and a
   numbered edit list with a verification check per step. For non-trivial fixes,
   delegate to the superpowers `writing-plans` skill if it is installed; do not
   duplicate its format here.
6. **Branch** `fix/<slug>` (or `feat/<slug>`) off `main`.
7. **Regression test first** — scoped honestly by layer:
   - kit/DTO layer (`SplashControlKit`) → a real Swift Testing test in
     `Tests/SplashControlKitTests/`.
   - view/app layer (no test runner exists) → a static lint pin in the check scripts
     (`Scripts/check_core.sh` carries `lint:` greps) and/or a screenshot assertion.
   - Never fabricate a view test runner, never weaken a gate to make a fix pass.
8. **Implement** — surgical, per AGENTS.md.
9. **Gates, in order:** `make verify` → `make app` (from a clean tree) → quit the
   running copy → relaunch `dist/Splash.app` → confirm the live process path is the
   dist bundle, not `.build/` → `make screenshot` for every touched view → inspect
   the PNG. Never build from a dirty tree; never trust a stale bundle.
10. **Commits** — one concern per commit, conventional type, for humans (they become
   the changelog):
   - behavior: `fix:` / `feat:`
   - breaking: `fix!` / `feat!`
   - CI/docs/templates/meta: `chore: [skip-release]`
   - **`[skip-release]` only when the commit ships no changed bytes.**
11. **Version bump** (`Resources/Info.plist`, `CFBundleShortVersionString` +
    `CFBundleVersion`), in the same PR:
    - breaking/major → the agent writes the plist bump in a `chore: [skip-release]`
      commit **before** the `!` commit, so the release plist matches the minted tag.
    - patch/minor → never touch the plist (it moves on release only).
12. **PR.** Description: issue link, root cause, verification evidence (test name /
    screenshot / live probe), gate results, expected release class. End with
    `Fixes #N` so the issue auto-closes. Push the branch, report the URL.
13. **STOP.** Hand to the human: "ready to merge; expect release <class>".
14. **Post-merge.** Check the run: tag minted as expected, release has zip + sha256,
    changelog reads right. Then `git fetch --prune` and fetch tags carefully —
    delete any local tag whose SHA no longer matches before accepting a remote of
    the same name (SHA-collision refusal). If the release PR touched views, refresh
    the repo screenshots in a follow-up `chore: [skip-release]` PR.

## Release strategy

The pipeline already mints a release for every merged `fix:`/`feat:` commit.
Keep that: **patch and minor ship per merged fix** — the artifact is one zip +
sha256, the changelog keeps granularity, batching buys nothing at this scale.
Breaking/major ships immediately via `!`. Only introduce batching (deliberate
`[skip-release]` on patches + a later trigger commit) if more than ~5 patch
releases a week become real noise.

## Hard rules

- The pipeline mints **tags**, not plist versions — the agent owns Info.plist for
  breaking releases, the pipeline owns everything else.
- A changed `dist/Splash.app` is the only truth for UI claims: unrelaunched = unverified.
- Uncommitted changes at task end are a trap for the next session — commit or ask.
- No secrets, no tokens, no machine-specific paths in commits, PRs, or issue comments
  (public repo; everything you post is public).
- Never push `main`; never merge; the merge is the human's call.
