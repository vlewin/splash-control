# Contributing

Read [AGENTS.md](AGENTS.md) before changing code. It is the working contract for this repo and covers the workflow, verification, and report format. The short version:

- `make build`, `make check`, `make app` build, verify, and assemble `dist/Splash.app`.
- One concern per commit, with a conventional prefix (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `style:`).
- No external SPM dependencies. Swift, single `SplashControl` target.
- Bug reports go through the [issue template](.github/ISSUE_TEMPLATE/bug_report.md).

Technical detail lives in [ARCHITECTURE.md](ARCHITECTURE.md) (runtime contract, dot state machine) and [DESIGN.md](DESIGN.md) (visual tokens, layout rules).
