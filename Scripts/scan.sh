#!/usr/bin/env bash
# Security scan gate. The PR pipeline runs this same file, so a green local run
# is a green PR run.
#
# Semgrep's registry ruleset is not vendored: the Semgrep Rules License forbids
# redistributing the rules. It is downloaded per run and checked against the
# sha256 pinned below, so a green run cannot turn red because Semgrep edited a
# rule upstream. A mismatch means: read the new rules, then `make scan-rules`.
set -euo pipefail
cd "$(dirname "$0")/.."

RULES_URL="https://semgrep.dev/c/auto"
RULES_SHA256="43b45d8719a2f40ca83a0b88750ca4bd3583baa9b48380ef9d28d4c51bae966e"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 "$RULES_URL" -o "$tmp/rules.yaml"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/rules.yaml" | cut -d' ' -f1)"
else
  actual="$(shasum -a 256 "$tmp/rules.yaml" | cut -d' ' -f1)"
fi

if [ "${1:-}" = "--refresh" ]; then
  echo "ruleset sha256: $actual"
  echo "pin it in RULES_SHA256 once a scan against it is green"
  semgrep scan --config "$tmp/rules.yaml" --error .
  exit
fi

if [ "$actual" != "$RULES_SHA256" ]; then
  echo "semgrep ruleset changed upstream: expected $RULES_SHA256, got $actual." >&2
  echo "Review the new rules against this repo, then run 'make scan-rules'." >&2
  exit 1
fi

semgrep scan --config "$tmp/rules.yaml" --error .
qlty check --all
shellcheck Scripts/*.sh
# Two different surfaces: history catches a secret that was committed then
# deleted (still leaked), the tree catches one in a file not yet committed.
gitleaks git . -v --redact
gitleaks dir . -v --redact
