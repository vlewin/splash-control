---
name: session-reviewer
description: Reviews an OpenCode session in THIS repo (splash-control) against AGENTS.md process rules and recalls/stores project memory via ICM. Use when the user asks to review a session, names a session ID, or says /review-session. Manual trigger only.
---

# Session Reviewer

Process review only — never code correctness, never code changes, never builds.
Reviewer, not agent. If asked to implement, stop: that is a different task.

## 0. Memory recall (ICM, read-only)

Before touching the transcript, recall project decisions that bear on the review.
Zero-footprint CLI use: explicit DB, no init, no hooks.

```bash
icm recall "<session topic>" --no-embeddings
```

DB: `~/.local/share/icm/splash-control.db` (env `ICM_DB` may override).
If recall misses on paraphrase twice in one review, say so — that is the
defined trigger for turning embeddings on, not a failure to hide.

## 1. Rule 0 — resolve the session BEFORE any review

- Open read-only: `sqlite3 "file:$HOME/.local/share/opencode/opencode.db?mode=ro"`.
- Candidates: `SELECT id,title,agent,model,parent_id,time_created,time_updated
  FROM session_v2 WHERE directory = '<reviewer cwd>'`. Global-latest is
  FORBIDDEN as a selector. Legacy `session` table is stale — never use it.
- Exclude self: drop `--exclude <id>` if given, else any session whose latest
  user message contains the review request, else ask. Never review the review.
- Rank newest-first with id/title/agent/model/updated. Title or task-keyword
  match selects; else list top 3–5 and ask. Two close candidates = question.
- Families: if `parent_id` set or children exist, flag
  `Family: parent [id], children [ids]`; review the named session only.
- Print: `Session [id] — [title] — [agent/model] — updated [ts]`. Abort only
  on mismatch with the named/implied session; age alone never aborts.

## 2. Checklist (each: PASS / FAIL / INAPPLICABLE, evidence required)

1. plan-before-edit — every edit/write has a preceding plan in the same turn?
2. read-before-write — every write has a preceding read on the same path?
3. live-probe-before-docs — docs cited only after a live `:8000` probe attempt?
4. DESIGN.md-before-UI — UI edits only after DESIGN.md read? (else INAPPLICABLE)
5. capability sources — gating touched only after ARCHITECTURE.md §4.6 AND
   `serveFlags|buildLaunchArgs` grep? (else INAPPLICABLE)
6. rtk-never-for-existence — no `rtk` call used as an existence check?
7. two-corrections — no 2+ user `no|wrong|actually|not |incorrect` turns or
   same-region edits without an intervening plan?
8. report-format — final message matches §14 shape, no filler openers?

Reviewer obeys 6 itself: exact-match grep or raw `rg` for its own pulls.

## 3. New-tool decision rule (per struggle, in order)

1. Info available via an invoked tool? → tighter rule.
2. Via a tool not invoked? → rule + trigger (`when X, use Y`).
3. Via no existing tool? → suggest tool (e.g. openwiki, codegraph, context7).

## 4. Output shape

```text
Session [id] — updated [ts] — Family: [ids or none]
### Struggles
- [section]: [one line]
  - Evidence: [message/part id or quote]
  - Fix: [rule | trigger | tool]
### Passed — [sections]
### Inapplicable — [sections + why]
```

No fix without a message id or quote. No struggles → Passed + Inapplicable, stop.

## 5. Memory store (propose, human approves)

Durable findings become memories; session trivia does not. Draft, don't run:

```bash
icm store -t decisions-splash-control -c "<one-line rule>" -i <high|medium> --no-embeddings
```

State the draft lines; the user approves each. Forgetting is
`icm forget <id>`. The DB is outside the repo — storing changes no tracked file.
