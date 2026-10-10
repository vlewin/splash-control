---
name: github-issue-create
description: Workflow for filing a GitHub issue in THIS repo (splash-control) that carries the same triage signal as the web issue forms. Use when the user asks to open, file, or create a GitHub issue in this repo.
---

# GitHub Issue Create Workflow

Project: Splash Control — public GitHub repo. Everything posted is public:
no secrets, tokens, machine-specific paths, or local usernames in titles,
bodies, or comments.

## Why this skill exists

Issue forms (`.github/ISSUE_TEMPLATE/*.yml`) are a web-UI construct —
`gh issue create` does **not** validate against them, and blank issues are
disabled (`blank_issues_enabled: false`). An agent filing via the CLI must
self-enforce the template, or the issue ships without triage signal.

## Workflow

1. **Duplicates first.** `gh issue list --search "<keywords>" --state all`.
   If a match exists, point at it and stop — do not file.
2. **Pick the template** and read the `.yml` before drafting:
   - app misbehaves → `bug_report.yml` (labels: `bug`)
   - idea → `feature_request.yml` (labels: `enhancement`)
   - server returns malformed JSON / crashes / misbehaves **without
     Splash Control running** → file upstream in `incoai/splash`, not here;
     `upstream.yml` (labels: `upstream`) is only for when the server is
     correct but Splash Control renders or handles its data wrongly.
3. **Fill every `required: true` field** from the template body, in order,
   under matching `###` headings (`What happened?`, `Steps to reproduce`,
   `App version` from the Info tab, `macOS version`, `Splash server version`
   from `splash --version`; optional `Model`, `Logs and screenshots` only
   when they add signal). Never invent versions — probe them
   (`curl -s http://127.0.0.1:8000/status`, Info tab) or mark unknown.
4. **Draft + explicit approval** (AGENTS.md §5): show title, labels, and full
   body, then wait. Never file automatically; never `gh issue create`
   without a "yes" to that draft.
5. **File.** `gh issue create --title "<title>" --label <labels> --body "<body>"`.
   Report the URL. A human closes/labels further; the agent never closes its
   own filed issue without being asked.
