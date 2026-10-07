#!/usr/bin/env bash
# Runs the real AgentStatus.derive/detail over a /status payload.
#   ./Scripts/check_agent_status.sh [file.json ...]   (no args: embedded cases only)
# Exists because the state chain is pure logic over StatusDTO: checkable without
# the menu bar, and every branch should be provable. Each case below is a minimal
# /status-shaped JSON, so it also exercises the decoder.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# AgentStatus lives inside StatsModel.swift (the sanctioned display-model layer,
# per AGENTS.md). Lift just the enum so the check compiles without the app target.
python3 - "$work" <<'PY'
import re, sys, pathlib
work = pathlib.Path(sys.argv[1])
src = pathlib.Path("Sources/SplashControl/StatsModel.swift").read_text()
m = re.search(r"/// Engine state read off.*?\n\}\n", src, re.S)
assert m, "AgentStatus enum not found in StatsModel.swift"
(work / "agent.swift").write_text("import Foundation\n" + m.group(0))
PY

cat > "$work/main.swift" <<'SWIFT'
import Foundation

let decoder = JSONDecoder()
var failures = 0

func check(_ name: String, _ want: String, _ got: String?) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): want=\(want) got=\(got ?? "nil")")
}

func checkNil(_ name: String, _ got: AgentStatus?) {
    let ok = got == nil
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): want=nil got=\(got?.label ?? "nil")")
}

/// The tray dot colour comes from `severity`, so BUG-3 is really an assertion
/// about this value: stale must be `warn` (orange) and never `bad` (gray), which
/// is what the bar uses for stopped/error.
func sev(_ json: String) -> String {
    switch status(json)?.severity {
    case .ok: return "ok"
    case .busy: return "busy"
    case .warn: return "warn"
    case .bad: return "bad"
    case nil: return "nil"
    }
}

/// Derives from a minimal /status-shaped JSON object.
func status(_ json: String) -> AgentStatus? {
    AgentStatus.derive(from: try? decoder.decode(StatusDTO.self, from: Data(json.utf8)))
}
func detail(_ json: String, _ s: AgentStatus) -> String? {
    guard let d = try? decoder.decode(StatusDTO.self, from: Data(json.utf8)) else { return nil }
    return AgentStatus.detail(from: d, for: s)
}

for path in CommandLine.arguments.dropFirst() {
    let dto = try decoder.decode(StatusDTO.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let s = AgentStatus.derive(from: dto)
    print("\(path) -> \(s?.label ?? "nil")\(s.flatMap { AgentStatus.detail(from: dto, for: $0) }.map { " · \($0)" } ?? "")")
}

// Branch coverage. `ready:true` alone must be idle; every other case flips one key.
checkNil("no data", AgentStatus.derive(from: nil))
check("idle", "idle", status(#"{"ready":true}"#)?.label)
check("loading", "loading", status(#"{"ready":true,"scheduler":{"prefilling":1}}"#)?.label)
check("decoding", "decoding", status(#"{"ready":true,"scheduler":{"decoding":1}}"#)?.label)
check("masked", "masked", status(#"{"ready":true,"scheduler":{"waiting_mask":1}}"#)?.label)
check("queued", "queued", status(#"{"ready":true,"admission":{"waiting":2}}"#)?.label)
check("queued via scheduler", "queued", status(#"{"ready":true,"scheduler":{"queued":1}}"#)?.label)
check("suspended", "suspended", status(#"{"ready":true,"admission":{"suspended":1}}"#)?.label)
check("draining", "draining", status(#"{"ready":true,"admission":{"draining":true}}"#)?.label)
check("recovering", "recovering", status(#"{"ready":true,"transport":{"recovering":true}}"#)?.label)
check("metal dead", "recovering", status(#"{"ready":true,"metal":{"healthy":false}}"#)?.label)
check("host pressure is NOT capped", "memory-pressure", status(#"{"ready":true,"memory_pressure":"warning"}"#)?.label)
check("governor refusal IS capped", "memory-capped", status(#"{"ready":true,"memory_governor":{"growth_allowed":false}}"#)?.label)
// Budget exhaustion outranks plain host pressure: only the former is actionable.
check("budget outranks host pressure", "memory-capped", status(#"{"ready":true,"memory_pressure":"warning","memory_governor":{"growth_allowed":false}}"#)?.label)
// The detail must name the ENGINE budget, not the host.
check("capped detail names engine headroom", "engine 0.3 GiB headroom · 132 denied", detail(#"{"ready":true,"memory_governor":{"growth_allowed":false,"headroom_bytes":322122547,"denied_reservations":132}}"#, .budgetCapped) ?? "nil")
check("host pressure detail names host headroom", "warning · host 11.2 GiB headroom", detail(#"{"ready":true,"memory_pressure":"warning","memory_governor":{"host_headroom_bytes":12025908428}}"#, .memoryPressure) ?? "nil")
check("capped severity is warn", "warn", sev(#"{"ready":true,"memory_governor":{"growth_allowed":false}}"#))
check("host pressure severity is warn", "warn", sev(#"{"ready":true,"memory_pressure":"warning"}"#))
// Memory constraint outranks the phase gauges. It used to sit BELOW them, so a
// green "decoding" dot hid an active memory warning - the confusion seen on
// 2026-09-28, where the dot read green while the dashboard tile warned. Nothing
// pinned that ordering, which is how it survived.
check("host pressure outranks decoding", "memory-pressure", status(#"{"ready":true,"memory_pressure":"warning","scheduler":{"decoding":1}}"#)?.label)
check("engine cap outranks decoding", "memory-capped", status(#"{"ready":true,"memory_governor":{"growth_allowed":false},"scheduler":{"decoding":1}}"#)?.label)
check("host pressure outranks prefill", "memory-pressure", status(#"{"ready":true,"memory_pressure":"warning","scheduler":{"prefilling":1}}"#)?.label)
check("engine cap outranks a queued request", "memory-capped", status(#"{"ready":true,"memory_governor":{"growth_allowed":false},"scheduler":{"queued":2}}"#)?.label)
// ...and no regression: with healthy memory the phase is still what is reported.
check("decoding with healthy memory still reports decoding", "decoding", status(#"{"ready":true,"scheduler":{"decoding":1}}"#)?.label)
check("prefill with healthy memory still reports prefill", "loading", status(#"{"ready":true,"scheduler":{"prefilling":1}}"#)?.label)
// Reordering must not lose the phase: the constraint is reported, the work is too.
check("constrained detail still names the decode", "warning · host 11.2 GiB headroom · decode 1", detail(#"{"ready":true,"memory_pressure":"warning","scheduler":{"decoding":1},"memory_governor":{"host_headroom_bytes":12025908428}}"#, .memoryPressure) ?? "nil")
check("constrained detail names both phases when both run", "engine 0.3 GiB headroom · 132 denied · prefill 1 · decode 1", detail(#"{"ready":true,"memory_governor":{"growth_allowed":false,"headroom_bytes":322122547,"denied_reservations":132},"scheduler":{"prefilling":1,"decoding":1}}"#, .budgetCapped) ?? "nil")
check("constrained detail adds nothing when idle", "warning · host 11.2 GiB headroom", detail(#"{"ready":true,"memory_pressure":"warning","memory_governor":{"host_headroom_bytes":12025908428}}"#, .memoryPressure) ?? "nil")
check("starting", "starting", status(#"{"ready":false}"#)?.label)
// Precedence: a stale snapshot must not read as decoding, and ready:false wins
// over in-flight work (the snapshot predates the work).
check("stale beats decoding", "stale", status(#"{"ready":true,"transport":{"status_stale":true},"scheduler":{"decoding":1}}"#)?.label)
check("not-ready beats decoding", "starting", status(#"{"ready":false,"scheduler":{"decoding":1}}"#)?.label)
// BUG-3: the shape ARCHITECTURE.md actually documents for a stale snapshot is
// ready:false + status_stale:true. It must read as stale, never as "starting"
// (which the tray dot renders as warn) and never as "down" (bad/gray).
check("stale beats not-ready", "stale", status(#"{"ready":false,"transport":{"status_stale":true}}"#)?.label)
check("stale + in-flight work", "stale", status(#"{"ready":false,"transport":{"status_stale":true},"scheduler":{"prefilling":1,"decoding":1}}"#)?.label)
check("stale + memory pressure", "stale", status(#"{"ready":false,"transport":{"status_stale":true},"memory_pressure":"critical"}"#)?.label)
// The icon colour is decided by severity, so assert that: stale must be warn
// (orange), never bad (gray = stopped/error) which is the BUG-3 flapper.
check("stale severity is warn", "warn", sev(#"{"ready":false,"transport":{"status_stale":true}}"#))
check("not-ready alone is busy (starting, blue)", "busy", sev(#"{"ready":false}"#))
check("idle severity is ok", "ok", sev(#"{"ready":true}"#))
check("decoding severity is ok (not a warning)", "ok", sev(#"{"ready":true,"scheduler":{"decoding":1}}"#))
check("prefill beats decode", "loading", status(#"{"ready":true,"scheduler":{"prefilling":1,"decoding":1}}"#)?.label)

check("queued detail", "2 waiting · 1 memory · 1 concurrency · oldest 1.5s",
      detail(#"{"ready":true,"admission":{"waiting":2,"waiting_memory":1,"waiting_concurrency":1,"oldest_wait_ms":1500}}"#, .queued) ?? "nil")
check("decode detail", "prefill 0 · decode 3 · batched ×3",
      detail(#"{"ready":true,"scheduler":{"decoding":3}}"#, .decoding) ?? "nil")
check("stale detail", "snapshot 2.5s old",
      detail(#"{"ready":true,"transport":{"status_stale":true,"status_age_ms":2500}}"#, .stale) ?? "nil")
check("masked detail", "1 on mask",
      detail(#"{"ready":true,"scheduler":{"waiting_mask":1}}"#, .masked) ?? "nil")
check("idle detail", "nil", detail(#"{"ready":true}"#, .idle) ?? "nil")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -O -o "$work/check" \
  Sources/SplashControlKit/StatusDTO.swift \
  "$work/agent.swift" \
  "$work/main.swift"

"$work/check" "$@"
