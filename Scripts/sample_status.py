#!/usr/bin/env python3
"""Sample http://127.0.0.1:8000/status once per second for 60 s.

Writes one JSON object per line to the output file:
  {"t": <epoch ms>, "ok": true,  "status": {...}}
  {"t": <epoch ms>, "ok": false, "error": "..."}
"""
import json
import sys
import time
import urllib.request

URL = "http://127.0.0.1:8000/status"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/splash-status-samples.jsonl"
DURATION = int(sys.argv[2]) if len(sys.argv) > 2 else 60
INTERVAL = 1.0

def fetch():
    try:
        with urllib.request.urlopen(URL, timeout=5) as r:
            return json.load(r), None
    except Exception as e:
        return None, str(e)

t0 = time.time()
n = 0
with open(OUT, "w") as f:
    next_tick = t0
    while time.time() - t0 < DURATION:
        next_tick += INTERVAL
        status, err = fetch()
        rec = {"t": round((time.time() - t0) * 1000)}
        if status is not None:
            rec["ok"] = True
            rec["status"] = status
        else:
            rec["ok"] = False
            rec["error"] = err
        f.write(json.dumps(rec) + "\n")
        f.flush()
        n += 1
        sleep_for = next_tick - time.time()
        if sleep_for > 0:
            time.sleep(sleep_for)
print(f"wrote {n} samples to {OUT}")
