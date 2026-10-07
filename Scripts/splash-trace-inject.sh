#!/usr/bin/env bash
# Inject (or revert) a per-request trace into the *installed* splash server.
#
# Why this exists: splash logs one console line per request with token counts
# and TTFT, but never the client address, the requested model, or the prompt.
# When something local is hammering the server
# there is no way to tell who is calling or what it asked for. This patches
# server.py to print one TRACE line per request when SPLASH_DEBUG=1 is set.
#
# The patch is INERT unless SPLASH_DEBUG=1, so it is safe to leave installed.
# It does NOT survive `brew upgrade splash` — re-run `apply` afterwards. That
# is the whole reason this is a script and not a hand edit.
#
# Usage: Scripts/splash-trace-inject.sh [apply|revert|status]
set -euo pipefail

BACKUP_DIR="$HOME/Library/Application Support/SplashControl/splash-trace"
MARKER="SPLASH_DEBUG"          # present in the file iff patched
CMD="${1:-status}"

splash_prefix() { brew --prefix splash 2>/dev/null; }
server_py() {
  local p; p="$(splash_prefix)/libexec/server/server.py"
  [ -f "$p" ] || { echo "error: not found: $p" >&2; exit 1; }
  printf '%s' "$p"
}
version() { splash --version 2>/dev/null | head -1; }

do_status() {
  local f; f="$(server_py)"
  echo "splash        : $(version)"
  echo "server.py     : $f"
  if grep -q "$MARKER" "$f"; then
    echo "state         : PATCHED (inactive unless SPLASH_DEBUG=1)"
  else
    echo "state         : pristine"
  fi
  if [ -f "$BACKUP_DIR/server.py.pristine" ]; then
    echo "pristine copy : $BACKUP_DIR/server.py.pristine ($(wc -c < "$BACKUP_DIR/server.py.pristine" | tr -d ' ') bytes)"
  else
    echo "pristine copy : none (revert would not be possible)"
  fi
}

do_revert() {
  local f; f="$(server_py)"
  if [ ! -f "$BACKUP_DIR/server.py.pristine" ]; then
    echo "error: no pristine copy at $BACKUP_DIR/server.py.pristine — cannot revert" >&2
    echo "       restore by reinstalling: brew reinstall splash" >&2
    exit 1
  fi
  cp "$BACKUP_DIR/server.py.pristine" "$f"
  python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$f"
  echo "reverted $f (compiles OK) — restart the server to drop the trace"
}

do_apply() {
  local f; f="$(server_py)"
  if grep -q "$MARKER" "$f"; then
    echo "already patched — nothing to do"
    do_status
    return
  fi
  mkdir -p "$BACKUP_DIR"
  [ -f "$BACKUP_DIR/server.py.pristine" ] || cp "$f" "$BACKUP_DIR/server.py.pristine"

  python3 - "$f" "$MARKER" <<'PY'
import re, sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path).read()
# Anchor on the parsed request body, tolerating upstream reindentation.
# The match must consume the WHOLE line: anchoring on the '(' alone would leave
# the rest of the original statement stranded after the injected block.
m = re.search(r'^([ \t]*)body = self\._read_json_body\([^\n]*$', src, re.M)
if not m:
    sys.exit("error: anchor 'body = self._read_json_body(' not found — splash's\n"
             "       server.py changed shape; update the patch in this script.")
if src.count(m.group(0)) != 1:
    sys.exit(f"error: anchor matched {src.count(m.group(0))} times, expected 1")
ind = m.group(1)
patch = f'''{ind}# --- TEMP trace injected by Scripts/splash-trace-inject.sh ---
{ind}# Inert unless {marker}=1. One line per request: who called, what model it
{ind}# asked for, and the tail of the last message. Re-run the script after any
{ind}# `brew upgrade splash`; revert with `--revert`.
{ind}if os.environ.get("{marker}") == "1" and isinstance(body, dict):
{ind}    try:
{ind}        _m = body.get("messages") or []
{ind}        _last = _m[-1].get("content") if _m and isinstance(_m[-1], dict) else None
{ind}        _prev = _last if isinstance(_last, str) else json.dumps(_last)
{ind}        _peer = self.client_address[:2] if self.client_address else ("?", 0)
{ind}        _n = int(os.environ.get("{marker}_PREVIEW") or 600)
{ind}        # Header values that could carry a secret are shown as present/absent only.
{ind}        _h = {{}}
{ind}        for _k, _v in self.headers.items():
{ind}            _kl = _k.lower()
{ind}            if _kl in ("authorization", "x-api-key", "cookie"):
{ind}                _h[_kl] = "<present>"
{ind}            elif _kl in ("user-agent", "x-stainless-lang", "x-stainless-runtime",
{ind}                        "x-stainless-package-version", "openai-organization"):
{ind}                _h[_kl] = _v
{ind}        print(f"TRACE {{self.command}} {{self.path}} peer={{_peer[0]}}:{{_peer[1]}} "
{ind}              f"hdrs={{_h}} model={{body.get('model')!r}} stream={{body.get('stream')}} "
{ind}              f"max_tokens={{body.get('max_tokens')}} "
{ind}              f"effort={{body.get('reasoning_effort')!r}} nmsgs={{len(_m)}} "
{ind}              f"last={{(_prev or '')[:_n]!r}}", flush=True)
{ind}    except Exception as _e:
{ind}        print(f"TRACE_ERROR {{type(_e).__name__}}: {{_e}}", flush=True)
{ind}# --- end injected trace ---
'''
open(path, "w").write(src[:m.end()] + "\n" + patch + src[m.end():])
print(f"  injected after line {src[:m.end()].count(chr(10)) + 1}")
PY

  # Never leave a broken server.py behind: validate, and roll back on failure.
  if ! python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$f"; then
    echo "error: patched server.py does not compile — rolling back" >&2
    cp "$BACKUP_DIR/server.py.pristine" "$f"
    python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$f"
    echo "       rolled back to the pristine copy" >&2
    exit 1
  fi
  echo "patched $f (compiles OK)"
  echo
  echo "Restart the server for it to take effect, with tracing on, e.g.:"
  echo "  SPLASH_DEBUG=1 ./dist/Splash.app/Contents/MacOS/SplashControl"
  echo "Trace lines land in ~/Library/Logs/SplashControl/splash-server.log"
}

case "$CMD" in
  apply)  do_apply ;;
  revert) do_revert ;;
  status) do_status ;;
  *) echo "usage: $0 [apply|revert|status]" >&2; exit 2 ;;
esac