---
name: pull-request-review
description: Merge-readiness review for a PR in THIS repo (splash-control). Verifies scope, gates, release class, and public-repo hygiene before human merge. Use when the user asks to review a pull request or confirm a PR is ready to merge.
---

# Pull Request Review

Project: Splash Control — public GitHub repo. Human merges; the agent never
pushes `main` and never merges.

## Checklist (all must hold)

Scope:
- One concern per PR: one user-visible change plus its required tests,
  mechanical compile fixes, and directly required call-site updates. No
  unrelated refactors, optional cleanups, formatting churn, or generated
  `dist/` artifacts in the diff.
- PR body states the user-visible delta, touched surfaces, and `Fixes #N`,
  or `Fixes: none` when no issue exists.

Correctness:
- `make verify` green on Swift tools 5.10 (check + test + lint, every one).
- Changed behavior covered by a regression test in the matching layer
  (`SplashControlKitTests` for kit/DTO, `SplashControlTests` for app logic,
  `lint:` pin + screenshot for layout a unit test cannot reach). A regression
  test counts only when it fails before the change and passes after, or
  directly exercises the changed behavior.
- `Package.swift` / `Package.resolved` unchanged unless the PR is about them;
  no new external SPM dependency without explicit approval.

Gates (in order):
- `make app` from a clean tree → quit running copy → relaunch
  `dist/Splash.app` → live process path resolves inside the dist bundle.
  Evidence must be local; CI output alone does not satisfy this gate. When the
  PR ships no app bytes, cite the byte-free diff and mark the gate N/A.
- Screenshot per touched view, inspected, described in the PR body and attached
  to the PR by the human at review (never committed).
  When no view changed, state that explicitly instead of attaching a screenshot.
  For process-only changes, cite `git diff --stat` and `git diff --check` as
  the byte-free evidence.

Release:
- Commit prefixes predict the tag (`feat!`/`fix!` = major, `feat` = minor,
  `fix` = patch); `[skip-release]` only when the commit ships no changed bytes.
  Evaluate mixed PRs per commit and take the highest class among shipping commits.
- PR does not push `main` or mint tags out of band.

Hygiene (public repo):
- Review the full diff and PR text; sampling is not sufficient. No secrets,
  tokens, signing identities, machine-specific paths, usernames, or private
  URLs in commits, diffs, PR text, or comments. Here, “usernames” means a
  personal name in file content, a path, credential, or account identifier.
  Ordinary Git authorship metadata, and an upstream handle cited as issue/PR
  ownership, are not violations.
- Branch current with `main`, mergeable without conflict.

## Output

Verdict first: ready / ready-with-nits / not-ready. Then per-group pass/fail
with evidence (gate output, test name, screenshot, probe). File nits as
follow-ups, never silently expand the PR. End with the expected release class.
