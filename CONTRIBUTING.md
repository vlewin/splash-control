# Contributing

Read [AGENTS.md](AGENTS.md) before changing code. It is the working contract for this repo and covers the workflow, verification, and report format. The short version:

- `make build`, `make check`, `make app` build, verify, and assemble `dist/Splash.app`.
- One concern per commit, with a conventional prefix (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `style:`).
- Docs-only pushes never release: the pipeline mints a tag only when a commit selects a bump (`feat`/`fix`/`perf`/breaking), so `docs:`/`chore:` ride the next shippable release's changelog.
- No external SPM dependencies. Swift, single `SplashControl` target.
- Bug reports, feature requests, and upstream findings go through the [issue forms](.github/ISSUE_TEMPLATE/). Blank issues are disabled.
- Agents filing an issue: follow the `github-issue-create` skill (read the matching `.yml`, fill every required field, apply its labels, draft + explicit approval per AGENTS.md §5).

Technical detail lives in [ARCHITECTURE.md](ARCHITECTURE.md) (runtime contract, dot state machine) and [DESIGN.md](DESIGN.md) (visual tokens, layout rules).
