---
name: pull-request-review
description: Merge-readiness review for a PR in THIS repo (splash-control). Verifies scope, gates, release class, and public-repo hygiene before human merge. Use when the user asks to review a pull request or confirm a PR is ready to merge.
---

# Pull Request Review

Project: Splash Control — public GitHub repo. Human merges; the agent never
pushes `main` and never merges. Second opinion for this checklist came from a
DeepSeek cross-check; this repo's gates below stay authoritative on conflict.

## Checklist (all must hold)

Scope:
- One concern per PR; no unrelated refactors, formatting churn, or generated
  `dist/` artifacts in the diff.
- PR body states the user-visible delta, touched surfaces, and `Fixes #N`.

Correctness:
- `make verify` green on Swift tools 5.10 (check + test + lint, every one).
- Changed behavior covered by a real test in the matching layer
  (`SplashControlKitTests` for kit/DTO, `SplashControlTests` for app logic,
  `lint:` pin + screenshot for layout a unit test cannot reach).
- `Package.swift` / `Package.resolved` unchanged unless the PR is about them;
  no new external SPM dependency without explicit approval.

Gates (in order):
- `make app` from a clean tree → quit running copy → relaunch
  `dist/Splash.app` → live process path resolves inside the dist bundle.
- Screenshot per touched view, inspected, attached to the PR (not committed).

Release:
- Commit prefixes predict the tag (`feat!`/`fix!` = major, `feat` = minor,
  `fix` = patch); `[skip-release]` only when the commit ships no changed bytes.
- PR does not push `main` or mint tags out of band.

Hygiene (public repo):
- No secrets, tokens, signing identities, machine-specific paths, usernames,
  or private URLs in commits, diffs, PR text, or comments.
- Branch current with `main`, mergeable without conflict.

## Output

Verdict first: ready / ready-with-nits / not-ready. Then per-group pass/fail
with evidence (gate output, test name, screenshot, probe). File nits as
follow-ups, never silently expand the PR. End with the expected release class.
