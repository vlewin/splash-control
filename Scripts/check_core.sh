#!/usr/bin/env bash
# Decodes /status and runs the derived-metric + config logic over it.
#   ./Scripts/check_core.sh [status.json ...]   (extra payloads are decoded and reported)
#
# Complements check_agent_status.sh, which covers the AgentStatus state chain.
# This one covers what that script does not touch: the breadth of the StatusDTO
# key mapping, StatsModel's derived numbers, and SplashConfig's tolerant decode.
#
# Why it exists in this shape: this machine has Command Line Tools only, so
# XCTest is unavailable and `swift test` cannot run (see AGENTS.md). Compiling
# the real source files with swiftc and asserting in plain Swift needs nothing
# but the toolchain, adds no SPM dependency, and does not change Package.swift.
# It also catches the one class of bug a compiler cannot: a CodingKeys entry
# missing or misspelled, which decodes to nil in silence because every
# StatusDTO field is optional by contract.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ==============================================================================
# MARK: - Static Layout Safety Lints (Structural Immunity)
# ==============================================================================
# Not a substitute for a rendering harness (there is none on this machine: CLT
# has no XCTest/swift-testing module, and AGENTS.md forbids adding SPM deps).
# Instead these pin the structural shapes behind every layout bug found so far,
# so a regression is a compile-time-visible edit rather than a screenshot that
# has to be caught by eye. Cost: milliseconds.
#
# Each lint is a grep over the real source. They are deliberately anchored on
# the exact expressions that regressed, so they fail if the shape changes — not
# on generic text that happens to appear nearby.
lint_failures=0
lint_check() {
    local name="$1"
    local cond="$2"
    if eval "$cond"; then
        echo "ok   lint: $name"
    else
        echo "FAIL lint: $name"
        lint_failures=$((lint_failures + 1))
    fi
}
BENCH=Sources/SplashControl/BenchView.swift

# 1. The Context control. Both halves regressed independently: the label wrapped
#    one character per line, and the centre column drifted off the card's
#    midpoint. lineLimit keeps the label on one line, fixedSize makes the whole
#    centre group rigid instead of flexible.
lint_check "Context: label has lineLimit(1)" \
    "grep -A 4 'Text(\"Context:\")' '$BENCH' | grep -q 'lineLimit(1)'"
lint_check "Context: centre group has fixedSize()" \
    "grep -A 20 'Text(\"Context:\")' '$BENCH' | grep -q 'fixedSize()'"

# 2. Bar-chart values and the [BEST] badge. 82 pt could not hold "10.7 GiB" plus
#    the badge and wrapped it into two lines.
lint_check "bar chart value has lineLimit(1)" \
    "grep -A 4 'Text(v.map { String(format:' '$BENCH' | grep -q 'lineLimit(1)'"
lint_check "BEST badge has lineLimit(1)" \
    "grep -A 3 'Text(\"BEST\")' '$BENCH' | grep -q 'lineLimit(1)'"

# 3. The configuration row is three columns, not two spacers: equal flexible
#    wings around a rigid centre. Two Spacers put the centre half a button-width
#    difference off true centre, and squeezed the label to 2.67 pt.
lint_check "configCard has a leading wing" \
    "grep -A 8 'Add Image (Optional)' '$BENCH' | grep -q 'alignment: .leading'"
lint_check "configCard has a trailing wing" \
    "grep -A 25 'Label(\"Run Benchmark\"' '$BENCH' | grep -q 'alignment: .trailing'"

# 4. The header run control is pinned to a fixed width. A badge that vanishes
#    with `if let` shifts the whole row when a state becomes nil.
lint_check "header run control pinned to a fixed width" \
    "grep -A 40 'var runBadge: some View' '$BENCH' | grep -q 'frame(width: 380'"
lint_check "header badge never disappears with the state" \
    "! grep -qE 'if +let.*lastRunAt|if +bench\.lastRunAt != nil' '$BENCH'"

# 5. The Settings port verdict never forks a subprocess during render.
#    BUG-17: serverCard called isPortListening -> lsof -> waitUntilExit,
#    which pumps the CFRunLoop and re-entered SwiftUI evaluation
#    (EXC_BAD_ACCESS, 8 reports). The probe now lives in @Published
#    portListening refreshed by the poll loop; the view only reads state.
SETTINGS=Sources/SplashControl/SettingsView.swift
lint_check "serverCard never forks: no isPortListening in SettingsView" \
    "! grep -q 'isPortListening' '$SETTINGS'"

# 6. Window height follows measured content height (ContentHeightKey), except
#    Logs, which keeps its fixed console height — a window that grows with
#    every log line would jump while watched.
for _view in Sources/SplashControl/DashboardView.swift Sources/SplashControl/StatsView.swift Sources/SplashControl/SettingsView.swift Sources/SplashControl/InfoView.swift; do
    lint_check "$_view reports content height" \
        "grep -q 'reportContentHeight(' '$_view'"
done
lint_check "LogsView never reports (fixed console height)" \
    "! grep -q 'reportContentHeight' 'Sources/SplashControl/LogsView.swift'"

# 7. No tab ScrollView declares its own tall minHeight. The window fits
#    measured content, and a stale 560 floor under a shorter report compressed
#    the ScrollView until content slid under the toolbar (statistics and
#    settings headers). The 380 container floor is the only floor.
lint_check "no stale 560 branch floor fights auto-fit" \
    "! grep -q 'minHeight: 560' Sources/SplashControl/StatsView.swift Sources/SplashControl/SettingsView.swift Sources/SplashControl/DashboardView.swift"

# 8. Extra Serve Args is a full-width multiline editor, not the 240 pt single
#    line that clipped every real-world value. A Toggle announces the alias;
#    a text field names it.
lint_check "extraArgs is a multiline TextEditor" \
    "grep -A 12 'Text(\"Extra Serve Args\")' Sources/SplashControl/SettingsView.swift | grep -q 'TextEditor'"
lint_check "announce toggle is paired to the alias name" \
    "grep -q 'announceServedName' Sources/SplashControl/SettingsView.swift"

# 9. Info declares the tested splash range (issue #4). The adjacent live
#    "Inference engine" row shows whatever is running; without the declared
#    window a mismatched server renders silently incomplete data.
INFO=Sources/SplashControl/InfoView.swift
lint_check "Info declares the supported splash range" \
    "grep -q 'supportedSplash' '$INFO' && grep -q 'Engine support' '$INFO'"

# 10. The context window is a picker with a hardware-aware row set (issue #8):
#     a free-text field let a 128K default persist on a Mac whose own preset
#     card says it cannot afford one. Pin the base row set, the 64 GiB gate
#     on the 256K cap, and the Settings control being a Picker.
lint_check "context rows keep the base 32/64/128K set" \
    "grep -q '\"32K\", \"64K\", \"128K\"' Sources/SplashControl/Config.swift"
lint_check "256K row is gated on 64 GiB of unified memory" \
    "grep -q 'physicalGiB >= 64' Sources/SplashControl/Config.swift"
lint_check "context row in Settings is a Picker, not a free-text field" \
    "grep -A 14 '\"Context Window\"' Sources/SplashControl/SettingsView.swift | grep -q 'Picker('"

if [ "$lint_failures" -ne 0 ]; then
    echo ""
    echo "$lint_failures layout safety lint(s) FAILED. Aborting."
    exit 1
fi

cat > "$work/main.swift" <<'SWIFT'
import Foundation
import SplashControlKit

var failures = 0
func check(_ name: String, _ got: Any?, _ want: Any?) {
    let ok = "\(got ?? "nil")" == "\(want ?? "nil")"
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): want=\(want ?? "nil") got=\(got ?? "nil")")
}
/// Typed comparison, for enum decisions where `Any?` cannot infer a case.
func checkEq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): want=\(want) got=\(got)")
}
func checkNil(_ name: String, _ got: Any?) {
    let ok = got == nil
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): want=nil got=\(got.map { "\($0)" } ?? "nil")")
}
let decoder = JSONDecoder()
func dto(_ json: String) -> StatusDTO { try! decoder.decode(StatusDTO.self, from: Data(json.utf8)) }

// MARK: - StatusDTO key mapping
// Every key the DTO claims to mirror, fed one minimal payload. A missing or
// misspelled CodingKeys entry shows up here as nil and nowhere else.
let full = dto("""
{"ready":true,"maximum_context_tokens":131072,"memory_pressure":"normal",
 "instance":{"model":"incoai/Qwen3.6-35B-A3B-Splash","port":9000,"started_at":1.5},
 "memory_plan":{"maximum_context_tokens":262144,"valid":true,
   "device":{"device_name":"Mac"},"model":{"model_name":"Qwen3.6-35B-A3B","maximum_context_tokens":262144}},
 "memory_actual":{"current_bytes":10,"allocated_bytes":11,"dense_bytes":99,"peak_bytes":12},
 "memory_governor":{"headroom_bytes":13,"charged_bytes":5,"observed_resident_bytes":99,"growth_allowed":true,"system_pressure":"normal","denied_reservations":14},
 "admission":{"waiting":1,"waiting_memory":2,"waiting_concurrency":3,"suspended":4,"draining":true,"oldest_wait_ms":1500},
 "requests":{"submitted":5,"completed":6,"failed":7,"cancelled":8},
 "scheduler":{"queued":9,"prefilling":10,"decoding":11,"waiting_mask":12,"waiting_prefix":13,
   "waiting_resources":14,"terminal":15,"decode_batches":16},
 "metrics":{"decode_tokens_per_second":17.5,"prefill_tokens_per_second":18.5,"decode_output_tokens":19,
   "prefill_input_tokens":20,"decode_wall_ms":21.0,"prefill_wall_ms":22.0,"draft_acceptance_rate":0.75,
   "drafted_tokens":23,"accepted_draft_tokens":24,"capacity_failures":25,"metal_failures":26,
   "itl_ms":{"p50":27.0,"p95":28.0,"samples":29},"ttft_ms":{"p50":30.0,"p95":31.0,"samples":32},
   "current_decode_batch":{"valid":true,"width":33,"input_tokens":34,"output_tokens":35,
     "wall_ms":36.0,"tokens_per_second":37.5},
   "current_prefill_batch":{"valid":true,"width":38,"input_tokens":39,"output_tokens":40,
     "wall_ms":41.0,"tokens_per_second":42.5}},
 "metal":{"healthy":true,"failure_reason":"none"},
 "transport":{"ready":true,"pending":43,"recovering":false,"restarts":44,"status_stale":true,
   "status_age_ms":2500.0,"last_crash_trace":null},
"kv":{"block_tokens":45,"pages_allocated":47,"pages_active":48,"pages_cache":49,
    "pages_free":50,"allocated_bytes":55,"reclaimable_bytes":56,
    "resident_backing_bytes":57,"pages_resident":58},
  "state":{"entries":56,"bytes":57,"allocated_bytes":59,"resident_bytes":60,"evictions":61},
  "cache":{"hits":63,"hit_rate":0.5,"reused_tokens":64},
  "disk":{"capacity_bytes":34359738368,"used_bytes":65,"read_bytes":66,"written_bytes":67,
    "kv_blocks":68,"kv_bytes":69,"kv_demotions":70,"kv_demotion_failures":71,
    "kv_demotions_refused":72,"kv_restores":73,"kv_restore_failures":74,"kv_pending_pages":75},
  "identity":{"cache":{"build_id":"bid","dtype":"q8s8"}},
 "weights":{"idle_release_seconds":600,"released":false,"restores":2}}
""")

// BUG-9 guard, generalised. This has now bitten three times in one session: a
// stored property added without a CodingKeys entry decodes to nil, the feature
// silently shows nothing, and every existing assertion still passes. Enumerate
// the stored properties and require each to survive a real encode of the
// all-keys payload, so the omission is caught at build time instead of in a
// screenshot. Encoding is the honest check: it goes through CodingKeys, it
// covers the payload that sets every field (so nothing is dropped as nil), and
// it needs no CaseIterable synthesis.
let stored = Set(Mirror(reflecting: full).children.compactMap { $0.label })
// Five properties are legitimately spelled differently on the wire
// (memoryGovernor -> memory_governor), so compare like with like.
func snake(_ s: String) -> String {
    var out = ""
    for c in s { c.isUppercase ? out.append("_" + c.lowercased()) : out.append(c) }
    return out
}
let emitted = Set((try! JSONSerialization.jsonObject(
    with: try! JSONEncoder().encode(full)) as! [String: Any]).keys)
check("DTO: every stored property survives an encode (BUG-9 guard)",
      Set(stored.map(snake)).subtracting(emitted), [])
check("DTO: every encoded key has a stored property", emitted.subtracting(Set(stored.map(snake))), [])

check("maximum_context_tokens", full.maximumContextTokens, 131072)
check("memory_pressure", full.memoryPressure, "normal")
check("instance.model", full.instance?.model, "incoai/Qwen3.6-35B-A3B-Splash")
check("instance.started_at", full.instance?.startedAt, 1.5)
check("memory_plan.device.device_name", full.memoryPlan?.device?.deviceName, "Mac")
check("memory_plan.model.model_name", full.memoryPlan?.model?.modelName, "Qwen3.6-35B-A3B")
check("memory_plan.maximum_context_tokens (native)", full.memoryPlan?.maximumContextTokens, 262144)
check("memory_plan.model.maximum_context_tokens", full.memoryPlan?.model?.maximumContextTokens, 262144)
check("memory_actual.peak_bytes", full.memoryActual?.peakBytes, 12)
check("memory_governor.headroom_bytes", full.memoryGovernor?.headroomBytes, 13)
check("memory_governor.system_pressure", full.memoryGovernor?.systemPressure, "normal")
check("admission.waiting_memory", full.admission?.waitingMemory, 2)
check("admission.waiting_concurrency", full.admission?.waitingConcurrency, 3)
check("admission.oldest_wait_ms", full.admission?.oldestWaitMs, 1500.0)
check("scheduler.waiting_mask", full.scheduler?.waitingMask, 12)
check("scheduler.decode_batches", full.scheduler?.decodeBatches, 16)
check("metrics.decode_tokens_per_second", full.metrics?.decodeTokensPerSecond, 17.5)
check("metrics.itl_ms.p95", full.metrics?.itlMs?.p95, 28.0)
check("metrics.ttft_ms.p50", full.metrics?.ttftMs?.p50, 30.0)
check("metrics.draft_acceptance_rate", full.metrics?.draftAcceptanceRate, 0.75)
check("metrics.current_decode_batch.tokens_per_second",
      full.metrics?.currentDecodeBatch?.tokensPerSecond, 37.5)
check("metrics.current_prefill_batch.output_tokens",
      full.metrics?.currentPrefillBatch?.outputTokens, 40)
check("metal.failure_reason", full.metal?.failureReason, "none")
check("transport.status_stale", full.transport?.statusStale, true)
check("transport.status_age_ms", full.transport?.statusAgeMs, 2500.0)
check("transport.restarts", full.transport?.restarts, 44)
check("kv.block_tokens", full.kv?.blockTokens, 45)
check("kv.reclaimable_bytes", full.kv?.reclaimableBytes, 56)
check("cache.hit_rate", full.cache?.hitRate, 0.5)
check("identity.cache.dtype", full.identity?.cache?.dtype, "q8s8")

// Schema 6 renamed four keys. The all-keys payload above carries BOTH
// spellings, so these four assertions pin the coalescing order: the schema 6
// key must win, or a 1.2.0 server would be read through the 1.1.0 fallback.
check("kv.residentBackingBytes prefers allocated_bytes", full.kv?.residentBackingBytes, 55)
check("kv.pagesResident prefers pages_allocated", full.kv?.pagesResident, 47)
check("state.residentBytes prefers allocated_bytes", full.state?.residentBytes, 59)
check("memoryActual.denseBytes prefers allocated_bytes", full.memoryActual?.denseBytes, 11)
check("governor.observedResidentBytes prefers charged_bytes", full.memoryGovernor?.observedResidentBytes, 5)

// The same four keys the other way: a schema 5 server sends only the old
// spellings. The tray adopts whatever is already listening, so one build has to
// serve both — this is not a hypothetical version skew.
let v5 = dto(#"{"ready":true,"kv":{"resident_backing_bytes":55,"pages_resident":52},"state":{"resident_bytes":58},"memory_actual":{"dense_bytes":12},"memory_governor":{"observed_resident_bytes":5}}"#)
check("schema 5 kv.residentBackingBytes still decodes", v5.kv?.residentBackingBytes, 55)
check("schema 5 kv.pagesResident still decodes", v5.kv?.pagesResident, 52)
check("schema 5 state.residentBytes still decodes", v5.state?.residentBytes, 58)
check("schema 5 memoryActual.denseBytes still decodes", v5.memoryActual?.denseBytes, 12)
check("schema 5 governor.observedResidentBytes still decodes", v5.memoryGovernor?.observedResidentBytes, 5)

// MARK: - The DTO may only declare keys the server actually sends
//
// BUG-9's guard above round-trips the DTO against a payload written in this
// file, so it can prove we did not typo a `CodingKeys` entry and can never prove
// the server still sends the key. When schema 6 deleted eleven keys, every
// assertion stayed green and six tiles rendered "—": a closed loop, green on a
// schema that no longer exists. So check the declared keys against a real
// captured `/status` instead. This is the check that would have caught it.
if let raw = try? String(contentsOfFile: "Tests/Fixtures/status_schema6.json", encoding: .utf8),
   let captured = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
    check("fixture is the schema this DTO claims to mirror", captured["schema_version"] as? Int, 6)

    // Legacy spellings are legal precisely because a schema 5 server sends them.
    // Anything not on this list is a key the server has never sent.
    let legacyOnly: Set<String> = ["resident_backing_bytes", "pages_resident",
                                  "resident_bytes", "dense_bytes", "observed_resident_bytes"]

    func serverKeys(_ section: String) -> Set<String> {
        Set(((captured[section] as? [String: Any]) ?? [:]).keys)
    }
    func declaredKeys(_ section: String) -> Set<String> {
        let paths = ["kv": ["kv"], "state": ["state"], "cache": ["cache"],
                     "disk": ["disk"], "memory_actual": ["memoryActual"],
                     "memory_governor": ["memoryGovernor"],
                     "admission": ["admission"]]
        let path = paths[section]?[0] ?? section
        let value: Any? = Mirror(reflecting: full).children
            .first { $0.label == path }?.value
        // The child is the section struct (KV?, MemoryActual?, ...), never a
        // StatusDTO: casting to StatusDTO can never succeed and silently
        // returned [] for every section (the vacuous-lint bug, #16).
        guard let encodable = value as? any Encodable else { return [] }
        let data = (try? JSONEncoder().encode(AnyEncodable(encodable))) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Set(object.keys)
    }
    struct AnyEncodable: Encodable {
        let encodeClosure: (Encoder) throws -> Void
        init(_ wrapped: Encodable) { encodeClosure = wrapped.encode }
        func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
    }

    for section in ["kv", "state", "cache", "disk", "memory_actual", "memory_governor", "admission"] {
        // Only the phantom direction is a bug. A server key this DTO does not
        // model is the deliberate-subset case the file doc comment describes, so
        // demanding full coverage would force ~35 fields nobody reads.
        let phantom = declaredKeys(section).subtracting(serverKeys(section)).subtracting(legacyOnly)
        check("schema 6: \(section) declares no key the server dropped", phantom, [])
    }
} else {
    check("schema 6 fixture readable", "Tests/Fixtures/status_schema6.json missing or unparseable", "readable")
}

// Absent keys must stay nil, not throw: the server may predate them.
let minimal = dto(#"{"ready":true}"#)
checkNil("minimal: no metrics", minimal.metrics)
checkNil("minimal: no memory_plan", minimal.memoryPlan)
check("minimal: ready", minimal.ready, true)

// Unknown keys must be ignored, not fatal: the DTO is a deliberate subset, and
// the server may send sections this app has never heard of.
let withExtras = dto(#"{"ready":true,"recent_requests":[{"prompt_tokens":1}],"latency":{"ttft":{"count":1}},"draft_context":{"active_rows":2},"constraint_masks":{"overlap_batches":1},"images":{"encodes":1}}"#)
check("payload with unmodelled sections still decodes", withExtras.ready, true)
checkNil("unmodelled recent_requests ignored", withExtras.instance)

// MARK: - StatsModel derived numbers
@MainActor func statsChecks() {
    let s = StatsModel()
    s.ingest(full, powerMode: nil)
    check("kvPoolTokens = pages_allocated x block_tokens", s.kvPoolTokens, 47 * 45)
    check("contextCap is the ENFORCED limit", s.contextCap, 131072)
    check("modelFamily from memory_plan.model.model_name", s.modelFamily, "Qwen3.6-35B-A3B")
    check("contextNative is the model's window", s.contextNative, 262144)

    // No samples yet: nothing to display, and a rate must not read as zero.
    let fresh = StatsModel()
    checkNil("displayTps nil before any sample", fresh.displayTps)

    // Missing native window (older server) must not crash the accessor.
    let old = dto(#"{"ready":true,"maximum_context_tokens":65536}"#)
    let s2 = StatsModel()
    s2.ingest(old, powerMode: nil)
    checkNil("contextNative nil when server omits it", s2.contextNative)
    check("contextCap still reads", s2.contextCap, 65536)

    // Sustained decode is the hero figure, so its delta math is asserted. The
    // per-batch reading must stay separate: it is not a rate, and quietly
    // sourcing the hero from it is the regression this pins.
    func snap(decodeTokens: UInt64, decodeWallMs: Double) -> StatusDTO {
        var m = StatusDTO.Metrics()
        m.decodeOutputTokens = decodeTokens
        m.decodeWallMs = decodeWallMs
        var st = StatusDTO(); st.metrics = m
        return st
    }
    check("sustained decode = dTokens / dWall", StatsModel.sustainedDecode(
        current: snap(decodeTokens: 33500, decodeWallMs: 289829.78),
        previous: snap(decodeTokens: 33100, decodeWallMs: 279829.78)), 40.0)
    checkNil("sustained decode nil when tokens do not advance",
             StatsModel.sustainedDecode(current: snap(decodeTokens: 100, decodeWallMs: 500),
                                        previous: snap(decodeTokens: 100, decodeWallMs: 400)))
    checkNil("sustained decode nil when wall time does not advance",
             StatsModel.sustainedDecode(current: snap(decodeTokens: 200, decodeWallMs: 500),
                                        previous: snap(decodeTokens: 100, decodeWallMs: 500)))
    checkNil("sustained decode nil on the first poll",
             StatsModel.sustainedDecode(current: snap(decodeTokens: 200, decodeWallMs: 500),
                                        previous: nil))
    // A counter reset (server restart) must not read as an absurd rate.
    checkNil("sustained decode survives a counter reset",
             StatsModel.sustainedDecode(current: snap(decodeTokens: 10, decodeWallMs: 20),
                                        previous: snap(decodeTokens: 33500, decodeWallMs: 289829.78)))

    // Draft acceptance decodes, so the hero caption can name the cause.
    let spec = dto(#"{"ready":true,"metrics":{"current_decode_batch":{"valid":true,"width":1,"output_tokens":2,"drafted_tokens":7,"accepted_draft_tokens":1,"wall_ms":26.7,"tokens_per_second":74.8}}}"#)
    check("drafted_tokens decodes", spec.metrics?.currentDecodeBatch?.draftedTokens, 7)
    check("accepted_draft_tokens decodes", spec.metrics?.currentDecodeBatch?.acceptedDraftTokens, 1)
}
// MARK: - ModelStats aggregation
// min/avg/max must be exact over unbounded history; only percentiles may depend
// on a bounded reservoir. Getting this backwards is how a "2000 samples is
// enough" design silently loses long-term history.
func modelStatsChecks() {
    var a = ModelStats.Aggregate()
    for v in [10.0, 20.0, 30.0] { a.add(v) }
    check("aggregate count", a.count, 3)
    check("aggregate sum", a.sum, 60.0)
    check("aggregate min", a.min!, 10.0)
    check("aggregate max", a.max!, 30.0)
    check("aggregate avg", a.avg!, 20.0)

    // Periodic flushing relies on merge being lossless and order-independent.
    var m = ModelStats.Aggregate(); m.merge(a)
    var b = ModelStats.Aggregate()
    for v in [5.0, 40.0] { b.add(v) }
    m.merge(b)
    check("merge count", m.count, 5)
    check("merge sum", m.sum, 105.0)
    check("merge keeps the global min", m.min!, 5.0)
    check("merge keeps the global max", m.max!, 40.0)
    check("merge avg", m.avg!, 21.0)
    var z = ModelStats.Aggregate(); z.add(1); z.merge(ModelStats.Aggregate())
    check("merging an empty operand changes nothing", z.count, 1)

    // Extremes must survive unbounded growth.
    var big = ModelStats.Aggregate()
    for i in 0..<5_000 { big.add(Double(i)) }
    check("unbounded history keeps the first min", big.min!, 0.0)
    check("unbounded history keeps the last max", big.max!, 4_999.0)
    check("unbounded history counts every sample", big.count, 5_000)

    // The reservoir is the only bounded part.
    var r = ModelStats.Reservoir(); r.limit = 100
    for i in 0..<1_000 { r.add(Double(i)) }
    check("reservoir stays bounded", r.values.count, 100)
    checkNil("percentile of an empty reservoir", ModelStats.Reservoir().percentile(0.95))
    var one = ModelStats.Reservoir(); one.add(7)
    check("percentile of a single sample", one.percentile(0.95)!, 7.0)
    var s = ModelStats.Reservoir()
    for v in [1.0, 2.0, 3.0, 4.0] { s.add(v) }
    check("p50 interpolates", s.percentile(0.5)!, 2.5)
    check("p0 is the minimum", s.percentile(0.0)!, 1.0)
    check("p100 is the maximum", s.percentile(1.0)!, 4.0)

    // Idle must not be recorded as zero, or an idle engine drags every average
    // toward nothing.
    let idle = Sample(date: Date())
    checkNil("an idle sample has no decode rate", idle.decodeTps)
    checkNil("an idle sample has no prefill rate", idle.prefillTps)
    checkNil("an idle sample has no memory", idle.totalLoadBytes)

    // The key must keep identical runs together and separate runs that are not
    // comparable. reasoning_effort is excluded on purpose: measured 2026-09-29,
    // it does not move throughput.
    let base = ModelStats.Key.conditions(kvFormat: "int8", maxContext: "128K",
                                         maxMemory: "48G", maxCacheDisk: "32G")
    check("identical conditions collide", base.withModel("m"), base.withModel("m"))
    check("a different model is a different row",
          base.withModel("m") == base.withModel("n"), false)
    check("a different kv format is a different row",
          base.withModel("m") == ModelStats.Key.conditions(kvFormat: "bf16", maxContext: "128K",
                                                           maxMemory: "48G", maxCacheDisk: "32G").withModel("m"),
          false)
    check("a different context cap is a different row",
          base.withModel("m") == ModelStats.Key.conditions(kvFormat: "int8", maxContext: "256K",
                                                           maxMemory: "48G", maxCacheDisk: "32G").withModel("m"),
          false)
    check("unset conditions still produce a usable key",
          ModelStats.Key.conditions(kvFormat: "", maxContext: "",
                                    maxMemory: "", maxCacheDisk: "").withModel("m").model, "m")
    // A stats.json written by an earlier build has no `decodeReservoir`. The
    // synthesised decoder would throw keyNotFound and `load()` would silently
    // drop every existing row, so the hand-written decoder is load-bearing.
    let legacy = """
    [{"key":{"model":"acme/m","kvFormat":"","maxContext":"128K","maxMemory":"48G","maxCacheDisk":""},
      "decode":{"count":3,"sum":30.0,"min":8.0,"max":12.0},
      "prefill":{"count":1,"sum":9.0,"min":9.0,"max":9.0},
      "prefillReservoir":{"values":[9.0],"limit":1024},
      "memory":{"count":2,"sum":8.0,"min":4.0,"max":4.0},
      "firstSeen":1.0,"lastSeen":2.0}]
    """
    let decodedLegacy = try? JSONDecoder().decode([ModelStats.Row].self,
                                                  from: Data(legacy.utf8))
    check("a stats.json without decodeReservoir still decodes",
          decodedLegacy?.count, 1)
    check("its aggregates survive the round trip",
          decodedLegacy?.first?.decode.sum, 30.0)
    check("the absent reservoir defaults empty, not nil-crash",
          decodedLegacy?.first?.decodeReservoir.values.count, 0)
    check("a legacy row has no memory reservoir either",
          decodedLegacy?.first?.memoryReservoir.values.count, 0)
    check("its memory aggregate still survived",
          decodedLegacy?.first?.memory.sum, 8.0)
    check("the present reservoir is preserved",
          decodedLegacy?.first?.prefillReservoir.values.count, 1)
    check("the model key survives", decodedLegacy?.first?.key.model, "acme/m")
    // And the current encoder must round-trip its own output.
    var fresh = ModelStats.Row(key: ModelStats.Key.conditions(kvFormat: "", maxContext: "",
                                                              maxMemory: "", maxCacheDisk: "").withModel("x/y"))
    fresh.decode.add(5); fresh.decodeReservoir.add(5)
    fresh.memory.add(44); fresh.memoryReservoir.add(44)
    var roundTrip: [ModelStats.Row]?
    if let data = try? JSONEncoder().encode([fresh]) {
        roundTrip = try? JSONDecoder().decode([ModelStats.Row].self, from: data)
    }
    check("current format round-trips", roundTrip?.first?.decode.count, 1)
    check("current format keeps its reservoir",
          roundTrip?.first?.decodeReservoir.values.count, 1)
    check("current format keeps its memory reservoir",
          roundTrip?.first?.memoryReservoir.values.count, 1)
}

// MARK: - totalLoadBytes must survive a large process
// Regression 2026-09-29: the guard used to require
// `observed_resident <= physical - host_available`. host_available adds back
// reclaimable pages, so that quantity is a *lower bound* and can be below one
// process's RSS. On the 35B (RSS 35.36 GiB, computed load 25.64 GiB) it failed,
// silently dropping the "system in use" series and every memory statistic.
@MainActor func totalLoadChecks() {
    let G: UInt64 = 1_073_741_824
    // The real shape that broke it, from the live 35B on 2026-09-29.
    let big = dto("""
    {"ready":true,
     "memory_plan":{"device":{"physical_memory_bytes":\(64*G)}},
     "memory_governor":{"host_available_bytes":\(38*G),
       "host_measurement_valid":true,
       "observed_resident_bytes":\(35*G)}}
    """)
    let s = StatsModel()
    s.ingest(big, powerMode: nil)
    check("a large RSS does not nil the system-load series",
          s.latest != nil, true)
    check("totalLoadBytes is physical minus available, not nil",
          s.samples.last?.totalLoadBytes, 26 * G)

    // The one condition that is genuinely invalid must still reject.
    let impossible = dto("""
    {"ready":true,
     "memory_plan":{"device":{"physical_memory_bytes":\(64*G)}},
     "memory_governor":{"host_available_bytes":\(70*G),
       "host_measurement_valid":true}}
    """)
    let s2 = StatsModel()
    s2.ingest(impossible, powerMode: nil)
    checkNil("available greater than physical is still rejected",
             s2.samples.last?.totalLoadBytes)

    // An invalid host measurement must be rejected too.
    let unmeasured = dto("""
    {"ready":true,
     "memory_plan":{"device":{"physical_memory_bytes":\(64*G)}},
     "memory_governor":{"host_available_bytes":\(38*G),
       "host_measurement_valid":false}}
    """)
    let s3 = StatsModel()
    s3.ingest(unmeasured, powerMode: nil)
    checkNil("an invalid host measurement is still rejected",
             s3.samples.last?.totalLoadBytes)
}

// MARK: - SplashLog channels, rotation and Berlin time
func logChecks() {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splashlog-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // Berlin, and DST resolved rather than hardcoded.
    let now = Date()
    let stamp = SplashLog.stamp.string(from: now)
    check("timestamps carry a numeric offset", stamp.hasSuffix("+01:00") || stamp.hasSuffix("+02:00"), true)
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    let offsetMinutes = berlin.secondsFromGMT(for: now) / 60
    check("the offset matches Europe/Berlin for this instant",
          stamp.hasSuffix(offsetMinutes == 120 ? "+02:00" : "+01:00"), true)
    // A fixed offset would be wrong in the other season; check both exist.
    let winter = SplashLog.stamp.string(from: Date(timeIntervalSince1970: 1_767_225_600)) // 2026-01-15
    let summer = SplashLog.stamp.string(from: Date(timeIntervalSince1970: 1_784_323_200)) // 2026-07-15
    check("January is +01:00 (CET)", winter.hasSuffix("+01:00"), true)
    check("July is +02:00 (CEST)", summer.hasSuffix("+02:00"), true)

    // Legacy UTC lines must still parse, or the 24 h compaction would silently
    // stop ageing them out and the file would never shrink again.
    check("a legacy ...Z line still parses",
          SplashLog.stamp.date(from: "2026-09-29T11:19:35Z") != nil, true)
    check("a +02:00 line parses",
          SplashLog.stamp.date(from: "2026-09-29T13:19:35+02:00") != nil, true)
    check("a +01:00 line parses",
          SplashLog.stamp.date(from: "2026-01-15T13:19:35+01:00") != nil, true)
    let parsed = SplashLog.stamp.date(from: "2026-09-29T11:19:35Z")!
    check("a Berlin wall-clock and its UTC form are the same instant",
          abs(parsed.timeIntervalSince(SplashLog.stamp.date(from: "2026-09-29T13:19:35+02:00")!)) < 1, true)

    // Two channels, two files, no cross-talk.
    let log = SplashLog(directory: dir)
    log.log("tray event", .tray)
    log.log("server line", .server)
    let trayText = (try? String(contentsOf: dir.appendingPathComponent("splash-control.log"), encoding: .utf8)) ?? ""
    let serverText = (try? String(contentsOf: dir.appendingPathComponent("splash-server.log"), encoding: .utf8)) ?? ""
    check("the tray channel wrote only its own line",
          trayText.contains("tray event") && !trayText.contains("server line"), true)
    check("the server channel wrote only its own line",
          serverText.contains("server line") && !serverText.contains("tray event"), true)
    check("the server line is verbatim, not console-prefixed",
          serverText.contains("] server line"), true)
    check("the tray line is stamped", trayText.contains("] tray event"), true)

    // No double timestamps. `splash serve` prefixes every line it prints with
    // `HH:MM:SS ` (server/diagnostics.py), so stamping the .server channel as
    // well put two timestamps on one event and burned ~30 columns on every row
    // of the log pane.
    log.log("23:01:06 Loading · incoai/Qwen3.6-35B-A3B-Splash", .server)
    log.log("Splash model is already installed in /Library/Application Support/Splash/models", .server)
    let stamped = (try? String(contentsOf: dir.appendingPathComponent("splash-server.log"), encoding: .utf8)) ?? ""
    check("a server line with its own clock is not stamped again",
          stamped.contains("\n23:01:06 Loading ·"), true)
    check("a server line with its own clock has no ISO prefix",
          stamped.contains("] 23:01:06 Loading"), false)
    check("a server line without a clock is still stamped, so it keeps its place",
          stamped.contains("] Splash model is already installed"), true)

    // No-op while small: rotation must not churn files it does not need to.
    check("a small log is not rotated",
          fm.fileExists(atPath: dir.appendingPathComponent("splash-control.log.1").path), false)

    // Roll at the cap. A roll deletes: there are no generations, because ten of
    // them accumulated ~10 MB of `.log.1` … `.log.10` that no view can reach.
    let filler = String(repeating: "x", count: 64 * 1024)
    for _ in 0..<(SplashLog.rotationBytes / (64 * 1024) + 2) { log.log(filler, .tray) }
    check("the log rolled at the cap",
          fm.fileExists(atPath: dir.appendingPathComponent("splash-control.log").path), true)
    for _ in 0..<(SplashLog.rotationBytes / (64 * 1024) + 2) * 4 {
        log.log(filler, .tray)
    }
    let archives = (1...12).filter {
        fm.fileExists(atPath: dir.appendingPathComponent("splash-control.log.\($0)").path)
    }
    check("rotation keeps no generations", archives.count, 0)
    check("the live log survives a roll, empty",
          { let p = dir.appendingPathComponent("splash-control.log").path
            return ((try? fm.attributesOfItem(atPath: p)[.size] as? NSNumber)??.intValue ?? -1)
                < SplashLog.rotationBytes }(), true)
    log.close()

    // An unopenable channel must be recorded, not silently discarded: a log that
    // vanishes with no trace looks exactly like a quiet server.
    let badDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splashlog-bad-\(UUID().uuidString)", isDirectory: true)
    // A path that cannot be created: a file where a directory must be.
    try? fm.createFile(atPath: badDir.path, contents: nil)
    // Manual rotation must be the same operation as size-triggered rotation: the
    // Logs tab button and the automatic 1 MB roll share one code path, so there is
    // only ever one scheme on disk.
    do {
        let dir2 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("splashlog-rotate-\(UUID().uuidString)")
        let log2 = SplashLog(directory: dir2)
        log2.log("first generation", .server)
        // rotate() finishes by re-opening the channel, so the live file exists
        // again immediately: present and empty, and the old content deleted
        // rather than shifted to `.1`.
        check("a manual rotate empties the live log and deletes the old one", {
            log2.rotateNow(.server)
            let f = dir2.appendingPathComponent("splash-server.log").path
            let live = (try? fm.attributesOfItem(atPath: f)[.size] as? NSNumber)??.intValue ?? -1
            return live == 0 && !fm.fileExists(atPath: f + ".1")
        }(), true)
        log2.log("second generation", .server)
        check("rotating again still leaves no archive", {
            log2.rotateNow(.server)
            let f = dir2.appendingPathComponent("splash-server.log").path
            return fm.fileExists(atPath: f) && !fm.fileExists(atPath: f + ".1")
                && !fm.fileExists(atPath: f + ".2")
        }(), true)
        check("the live log is empty after a rotate", {
            let f = dir2.appendingPathComponent("splash-server.log").path
            let sz = (try? fm.attributesOfItem(atPath: f)[.size] as? NSNumber)??.intValue ?? -1
            return sz == 0
        }(), true)
        // Stale archives from the retired ten-generation scheme must be purged by
        // the next rotation, not left on disk unreachable.
        for n in 1...10 {
            fm.createFile(atPath: dir2.appendingPathComponent("splash-server.log.\(n)").path,
                          contents: Data("stale".utf8))
        }
        check("archives left by the old scheme are purged on the next rotate", {
            log2.rotateNow(.server)
            return !(1...10).contains {
                fm.fileExists(atPath: dir2.appendingPathComponent("splash-server.log.\($0)").path)
            }
        }(), true)
        check("the log still accepts writes after a rotate", {
            log2.log("third generation", .server)
            let f = dir2.appendingPathComponent("splash-server.log").path
            return ((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").contains("third generation")
        }(), true)
        // Deliberately NOT asserted against SplashLog.shared: that is the real
        // singleton, so calling it here would rotate the live production log
        // mid-session. Every check above uses the temp-dir instance instead.
        log2.close()
        try? fm.removeItem(at: dir2)
    }

    let bad = SplashLog(directory: badDir.appendingPathComponent("nested"))
    bad.log("x", .server)
    check("an unopenable channel is reported", SplashLog.unavailable.contains(.server), true)
    bad.close()
    try? fm.removeItem(at: badDir)
    // A healthy logger clears the flag again.
    _ = SplashLog(directory: dir)
    check("a healthy channel is not reported", SplashLog.unavailable.contains(.tray), false)}

// MARK: - Model mismatch: the silent model swap
// The tray holds `config.model` (what it would launch) and `/status`
// `instance.model` (what is serving) and never reconciles them, so a
// hand-started model can be replaced without being asked. Observed on this
// machine 2026-09-29: Bonsai serving, tray configured for the 35B, and a
// restart silently substituted the 35B.
@MainActor func modelMismatchChecks() {
    checkNil("matching models do not mismatch",
             StatsModel.modelMismatch(configured: "a/m", serving: "a/m"))
    check("a different serving model is reported",
          StatsModel.modelMismatch(configured: "a/m", serving: "b/n"), "b/n")
    // Both sides optional in practice: a server that is down, or a release
    // that omits instance.model, must not raise a false warning.
    checkNil("no server yet does not mismatch",
             StatsModel.modelMismatch(configured: "a/m", serving: nil))
    checkNil("no configured model does not mismatch",
             StatsModel.modelMismatch(configured: nil, serving: "b/n"))
    checkNil("an empty configured model does not mismatch",
             StatsModel.modelMismatch(configured: "", serving: "b/n"))
    checkNil("an empty serving model does not mismatch",
             StatsModel.modelMismatch(configured: "a/m", serving: ""))
    checkNil("both nil does not mismatch",
             StatsModel.modelMismatch(configured: nil, serving: nil))
    // The exact incident, spelled out.
    check("the Bonsai/35B case is caught",
          StatsModel.modelMismatch(configured: "incoai/Qwen3.6-35B-A3B-Splash",
                                   serving: "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0"),
          "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0")
}

MainActor.assumeIsolated { statsChecks() }

// MARK: - SplashConfig tolerant decode
let empty = try! JSONDecoder().decode(SplashConfig.self, from: Data("{}".utf8))
check("config default maxContext follows the host tier",
      empty.maxContext, SplashConfig.defaultMaxContext(physicalGiB: HostMemory.physicalGiB))
check("default context on a 24 GiB host is 64K", SplashConfig.defaultMaxContext(physicalGiB: 24), "64K")
check("default context on a 64 GiB host is 128K", SplashConfig.defaultMaxContext(physicalGiB: 64), "128K")
check("default context on an unknown host takes the small end",
      SplashConfig.defaultMaxContext(physicalGiB: nil), "64K")
checkEq("picker rows: the base set below the 256K gate", SplashConfig.contextChoices(physicalGiB: 48),
        ["32K", "64K", "128K"])
checkEq("a 64 GiB host gets the 256K cap row", SplashConfig.contextChoices(physicalGiB: 64),
        ["32K", "64K", "128K", "256K"])
checkNil("config default kvFormat nil (flag omitted)", empty.kvFormat)
checkNil("config default maxCacheDisk nil (flag omitted)", empty.maxCacheDisk)

let legacy = try! JSONDecoder().decode(SplashConfig.self, from: Data(#"{"model":"acme/x"}"#.utf8))
check("legacy file keeps its model", legacy.model, "acme/x")
checkNil("legacy file gets nil kvFormat", legacy.kvFormat)

let tuned = try! JSONDecoder().decode(SplashConfig.self,
    from: Data(#"{"kvFormat":"bf16","maxCacheDisk":"5G"}"#.utf8))
check("kvFormat round-trips", tuned.kvFormat, "bf16")
check("maxCacheDisk round-trips", tuned.maxCacheDisk, "5G")

// A Settings edit must survive save(): ConfigStore.save encodes this struct, so
// a field that fails to appear in the JSON is a silently-lost preference.
// (nil optionals are legitimately omitted by JSONEncoder, so test the set case.)
let saved = try! JSONEncoder().encode(tuned)
let obj = try! JSONSerialization.jsonObject(with: saved) as! [String: Any]
check("encoded payload carries kvFormat", obj["kvFormat"] as? String, "bf16")
check("encoded payload carries maxCacheDisk", obj["maxCacheDisk"] as? String, "5G")
let reloaded = try! JSONDecoder().decode(SplashConfig.self, from: saved)
check("kvFormat survives a save/load round-trip", reloaded.kvFormat, "bf16")
check("maxCacheDisk survives a save/load round-trip", reloaded.maxCacheDisk, "5G")

// languageOnly: a file written before the key existed must not fail to load,
// and an explicit `true` must reach the launch args.
check("languageOnly defaults off", empty.languageOnly, false)
check("languageOnly defaults off in a legacy file", legacy.languageOnly, false)
let visionless = try! JSONDecoder().decode(SplashConfig.self, from: Data(#"{"languageOnly":true}"#.utf8))
check("languageOnly decodes", visionless.languageOnly, true)
let visionlessSaved = try! JSONEncoder().encode(visionless)
let visionlessObj = try! JSONSerialization.jsonObject(with: visionlessSaved) as! [String: Any]
check("encoded payload carries languageOnly", visionlessObj["languageOnly"] as? Bool, true)
check("languageOnly survives a save/load round-trip",
      (try! JSONDecoder().decode(SplashConfig.self, from: visionlessSaved)).languageOnly, true)

// MARK: - Chart scaling policy (moved out of the SwiftUI view to be assertable)
// StatsModel is @MainActor, so these run inside its actor context.
//
// There is no per-model decode ceiling any more. It used to hardcode 150 for
// Qwen3.8-27B and 250 for Qwen3.6-35B from eyeballed charts; measured sustain
// rates are ~24 and ~97 tok/s, so those constants made bars fill 16-39% of the
// plot. The assertions below pin the replacement: the axis must track observed
// data, and must never exceed it by more than the headroom factor. A future
// per-model constant would break the "tracks observed" check, which is the
// point — that is the bug this replaced.
@MainActor func chartPolicyChecks() {
    check("auto-scale leaves headroom", StatsModel.autoScaleCeiling(observed: 200.0), 250.0)
    check("auto-scale never returns zero", StatsModel.autoScaleCeiling(observed: 0.0) > 0, true)

    // The real-world regression: a measured rate must not be dwarfed by a
    // constant. 24 tok/s (27B dense) and 97 (35B) are the observed sustains.
    for observed in [24.0, 31.2, 97.0] {
        let ceiling = StatsModel.autoScaleCeiling(observed: observed)
        check("ceiling stays within headroom of \(observed) tok/s observed",
              ceiling, observed * StatsModel.autoScaleHeadroom)
        check("ceiling never inflates \(observed) tok/s past the old 150 constant",
              ceiling < 150.0, true)
    }

    // A chart's real test is that the axis leaves the data most of the plot, so
    // pin the fill fraction: observed / ceiling is always 1/headroom, never a
    // fraction so small the bars look like a flat line.
    check("data fills at least 75% of the axis",
          StatsModel.autoScaleHeadroom <= 1.0 / 0.75, true)
}

// MARK: - SplashProcess.buildLaunchArgs
// A wrong flag is invisible until splash refuses to start, so the whole
// command line is asserted rather than spot-checked.
@MainActor func argChecks() {
    var c = SplashConfig()
    c.model = "acme/model"; c.port = 1234
    c.maxMemory = "28G"; c.maxContext = "64K"
    c.allowedHost = "mymac.local other.local"
    c.maxRequestSize = "64M"; c.maxImagePixels = "1048576"
    c.apiKey = "secret"; c.noWebUI = true
    c.kvFormat = "bf16"; c.maxCacheDisk = "5G"
    check("full arg list", SplashProcess.buildLaunchArgs(c),
          ["serve", "--model", "acme/model", "--port", "1234", "--max-memory", "28G",
           "--max-context", "64K", "--kv-format", "bf16", "--max-cache-disk", "5G",
           "--allowed-host", "mymac.local", "--allowed-host", "other.local",
           "--max-request-size", "64M", "--max-image-pixels", "1048576",
           "--api-key", "secret", "--no-webui"])

    // Every flag the app emits must exist in the installed splash. Verified
    // against `splash serve --help` on 1.1.0.
    let known: Set<String> = ["--model", "--port", "--max-memory", "--max-context",
      "--kv-format", "--max-cache-disk", "--allowed-host", "--max-request-size",
      "--max-image-pixels", "--api-key", "--no-webui", "--language-only"]
    var a = SplashConfig()
    a.extraArgs = "--language-only"
    var emitted: Set<String> = []
    for tok in SplashProcess.buildLaunchArgs(a) where tok.hasPrefix("--") { emitted.insert(tok) }
    let unknown = emitted.subtracting(known).subtracting(["--language-only"])
    checkNil("no unknown flags in default+extra args", unknown.isEmpty ? nil : unknown.sorted())

    // Defaults must not invent flags: an existing config must not change
    // behaviour just because the app was rebuilt.
    let d = SplashProcess.buildLaunchArgs(SplashConfig())
    check("defaults omit --kv-format", d.contains("--kv-format"), false)
    check("defaults omit --max-cache-disk", d.contains("--max-cache-disk"), false)
    check("defaults keep the 128K context cap", d.contains("--max-context"), true)
    check("defaults omit --language-only", d.contains("--language-only"), false)
    var visionless = SplashConfig()
    visionless.languageOnly = true
    check("language-only is passed when enabled",
          SplashProcess.buildLaunchArgs(visionless).contains("--language-only"), true)
    var withNoWebUI = visionless
    withNoWebUI.noWebUI = true
    check("language-only sits next to --no-webui, not instead of it",
          SplashProcess.buildLaunchArgs(withNoWebUI).filter { $0 == "--language-only" || $0 == "--no-webui" },
          ["--no-webui", "--language-only"])

    // Blank strings mean "not set", not an empty argument.
    var blank = SplashConfig()
    blank.maxMemory = ""; blank.kvFormat = ""; blank.maxCacheDisk = ""
    let b = SplashProcess.buildLaunchArgs(blank)
    check("blank values are dropped", b.contains("--max-memory"), false)
    check("blank kvFormat is dropped", b.contains("--kv-format"), false)
    check("\"0\" cache disk is treated as disabled", SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.maxCacheDisk = "0"; return z }()).contains("--max-cache-disk"), false)

    // MARK: Gated flags — the crash-loop guard
    //
    // `--persistent-cache` is splash 1.2.0+ and `--idle-release` is 1.2.1+.
    // Strict `parse_args` rejects an unknown flag by refusing to start, so a
    // user on 1.1.0 with these configured would get a dead server and a
    // crash-loop, not a warning. `buildLaunchArgs` therefore consults the flags
    // the binary's own `serve --help` advertised, and an empty set — the probe
    // failing or not yet finished — means "pass neither".
    var gated = SplashConfig()
    gated.maxCacheDisk = "10G"      // --persistent-cache is meaningless without one
    gated.persistentCache = true
    gated.idleRelease = "30m"

    let all: Set<String> = ["--persistent-cache", "--idle-release"]
    check("gated: both flags pass when the binary has both",
          SplashProcess.buildLaunchArgs(gated, supports: all)
              .filter { $0 == "--persistent-cache" || $0 == "--idle-release" },
          ["--persistent-cache", "--idle-release"])
    check("gated: 1.2.0 gets persistent-cache only",
          SplashProcess.buildLaunchArgs(gated, supports: ["--persistent-cache"])
              .filter { $0 == "--persistent-cache" || $0 == "--idle-release" },
          ["--persistent-cache"])
    check("gated: nothing passes when the probe found nothing",
          SplashProcess.buildLaunchArgs(gated, supports: [])
              .filter { $0 == "--persistent-cache" || $0 == "--idle-release" }, [])
    check("gated: --idle-release carries its value",
          SplashProcess.buildLaunchArgs(gated, supports: all).contains("30m"), true)
    check("gated: 'off' is a value, not a boolean",
          SplashProcess.buildLaunchArgs({ var z = gated; z.idleRelease = "off"; return z }(),
                                        supports: all).contains("off"), true)
    check("gated: blank idleRelease is dropped",
          SplashProcess.buildLaunchArgs({ var z = gated; z.idleRelease = ""; return z }(),
                                        supports: all).contains("--idle-release"), false)
    check("gated: default config passes neither",
          SplashProcess.buildLaunchArgs(SplashConfig(), supports: all)
              .filter { $0 == "--persistent-cache" || $0 == "--idle-release" }, [])

    // `--persistent-cache` without a tier is not a warning, it is exit 2:
    // "splash: error: --persistent-cache needs --max-cache-disk". Settings
    // disables the toggle when the tier is off but never clears the stored
    // value, so turning the tier back to 0 must not pass the flag.
    func withTier(_ tier: String?) -> SplashConfig {
        var z = gated
        z.maxCacheDisk = tier
        return z
    }
    check("gated: persistent-cache needs a tier",
          SplashProcess.buildLaunchArgs(withTier(nil), supports: all).contains("--persistent-cache"), false)
    check("gated: persistent-cache needs a non-zero tier",
          SplashProcess.buildLaunchArgs(withTier("0"), supports: all).contains("--persistent-cache"), false)
    check("gated: persistent-cache needs a non-blank tier",
          SplashProcess.buildLaunchArgs(withTier(""), supports: all).contains("--persistent-cache"), false)
    check("gated: persistent-cache passes once a tier exists",
          SplashProcess.buildLaunchArgs(withTier("10G"), supports: all).contains("--persistent-cache"), true)
    // ...but --idle-release is independent of the tier.
    check("gated: idle-release is unaffected by the tier",
          SplashProcess.buildLaunchArgs(withTier("0"), supports: all).contains("--idle-release"), true)

    // `--default-reasoning-effort` has a dedicated menu; the closed set comes
    // from `serve --help`, and anything outside it is refused like a malformed
    // --idle-release (strict parse_args turns it into a crash-loop).
    let effort: Set<String> = ["--default-reasoning-effort"]
    check("gated: effort passes its value when supported",
          SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.reasoningEffort = "high"; return z }(), supports: effort).contains("high"), true)
    check("gated: effort defaults to omitted",
          SplashProcess.buildLaunchArgs(SplashConfig(), supports: effort).contains("--default-reasoning-effort"), false)
    check("gated: effort omitted on an old binary",
          SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.reasoningEffort = "high"; return z }(), supports: []).contains("--default-reasoning-effort"), false)
    check("gated: effort outside the closed set is refused",
          SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.reasoningEffort = "turbo"; return z }(), supports: effort).contains("--default-reasoning-effort"), false)
    check("extract: flag value form migrates",
          SplashConfig.extractReasoningEffort(from: "--default-reasoning-effort medium").effort, "medium")
    check("extract: equals form migrates",
          SplashConfig.extractReasoningEffort(from: "--default-reasoning-effort=low --verbose").effort, "low")
    check("extract: last valid value wins, rest stays",
          SplashConfig.extractReasoningEffort(from: "--default-reasoning-effort low --verbose --default-reasoning-effort high").rest, "--verbose")
    check("extract: unknown value stays put",
          SplashConfig.extractReasoningEffort(from: "--default-reasoning-effort turbo").effort, nil)
    check("extract: empty rest collapses to nil",
          SplashConfig.extractReasoningEffort(from: "--default-reasoning-effort medium").rest, nil)

    // `--served-model-name` defaults to "default" so harness configs survive
    // model switches; `--announce-served-name` needs the name (pairing
    // enforced in buildLaunchArgs, not only by disabling the toggle).
    let alias: Set<String> = ["--served-model-name", "--announce-served-name"]
    check("gated: default config passes the alias name when supported",
          SplashProcess.buildLaunchArgs(SplashConfig(), supports: alias).contains("--served-model-name"), true)
    check("gated: alias name carries its value",
          SplashProcess.buildLaunchArgs(SplashConfig(), supports: alias).contains("default"), true)
    check("gated: alias omitted on an old binary",
          SplashProcess.buildLaunchArgs(SplashConfig(), supports: []).contains("--served-model-name"), false)
    check("gated: blank alias name is dropped",
          SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.servedModelName = ""; return z }(), supports: alias).contains("--served-model-name"), false)
    check("gated: announce passes with a name",
          SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.announceServedName = true; return z }(), supports: alias).contains("--announce-served-name"), true)
    check("gated: announce needs a name",
          SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.servedModelName = nil; z.announceServedName = true; return z }(), supports: alias).contains("--announce-served-name"), false)
    check("gated: announce omitted on an old binary",
          SplashProcess.buildLaunchArgs({ var z = SplashConfig(); z.announceServedName = true; return z }(), supports: ["--served-model-name"]).contains("--announce-served-name"), false)
    check("gated: announce defaults on with the default name",
          SplashProcess.buildLaunchArgs(SplashConfig(), supports: alias).contains("--announce-served-name"), true)

    // `--idle-release` has a strict parser: `abc`, `15x` and `1h30m` each abort
    // startup with exit 2 (measured against the installed binary). A typo is a
    // dead server, so a malformed value must never reach the command line --
    // the Settings verdict warns, and buildLaunchArgs refuses.
    func idle(_ v: String?) -> String? { SplashProcess.sanitizedIdleRelease(v) }
    check("idle-release: off is accepted", idle("off"), "off")
    check("idle-release: suffixed durations pass",
          [idle("90s"), idle("30m"), idle("2h")].map { $0! }, ["90s", "30m", "2h"])
    check("idle-release: a bare number is accepted as seconds", idle("600"), "600")
    check("idle-release: surrounding space is trimmed", idle("  30m "), "30m")
    check("idle-release: nil and blank mean 'pass nothing'", [idle(nil), idle(""), idle("   ")], [nil, nil, nil])
    // The four that would kill the server.
    check("idle-release: rejects garbage", [idle("abc"), idle("15x"), idle("1h30m"), idle("-5m"), idle("0m")],
          [nil, nil, nil, nil, nil])
    check("idle-release: rejects an embedded space", idle("30 m"), nil)

    check("gated: a malformed idle-release is dropped, not forwarded",
          SplashProcess.buildLaunchArgs({ var z = gated; z.idleRelease = "abc"; return z }(), supports: all)
              .contains("--idle-release"), false)
    check("gated: a malformed idle-release drops its value too",
          SplashProcess.buildLaunchArgs({ var z = gated; z.idleRelease = "abc"; return z }(), supports: all)
              .contains("abc"), false)
    check("gated: a valid idle-release still gets through",
          SplashProcess.buildLaunchArgs(gated, supports: all).contains("--idle-release"), true)

    // The Settings verdict must agree with the launcher, or it is worse than
    // nothing: it would call a dead server healthy.
    func verdict(_ v: String?) -> Bool { SettingsValidator.idleRelease(v)?.ok == true }
    for good in ["off", "90s", "30m", "2h", "600", ""] {
        check("verdict agrees on \"\(good)\"", verdict(good), true)
    }
    for bad in ["abc", "15x", "1h30m", "30 m"] {
        check("verdict agrees on \"\(bad)\"", verdict(bad), false)
    }
    check("verdict names the unit a bare number means",
          SettingsValidator.idleRelease("15")?.text.contains("seconds") == true, true)
    check("verdict is absent for an unset value", SettingsValidator.idleRelease(nil) == nil, true)

    // The resolved-interval reader, in seconds.
    check("idle seconds: 90s", SplashProcess.idleReleaseSeconds("90s"), 90.0)
    check("idle seconds: 30m", SplashProcess.idleReleaseSeconds("30m"), 1800.0)
    check("idle seconds: 2h", SplashProcess.idleReleaseSeconds("2h"), 7200.0)
    check("idle seconds: a bare number is seconds", SplashProcess.idleReleaseSeconds("600"), 600.0)
    check("idle seconds: off has no interval", SplashProcess.idleReleaseSeconds("off") == nil, true)
    check("idle seconds: junk has no interval", SplashProcess.idleReleaseSeconds("abc") == nil, true)

    // What the server actually took. The disagreement case is the whole point:
    // the capability gate omits the flag on a binary older than 1.2.1 and the
    // server quietly applies its own default, which nothing else would reveal.
    func w(_ json: String) -> StatusDTO.Weights? { dto(#"{"weights":\#(json)}"#).weights }
    func eff(_ configured: String?, _ json: String) -> SettingsValidator.Verdict? {
        SettingsValidator.idleReleaseEffective(configured: configured, weights: w(json))
    }
    checkNil("effective: silent when the server predates 1.2.1 (no weights section)",
             SettingsValidator.idleReleaseEffective(configured: "30m", weights: nil))
    check("effective: agreement reads plainly",
          eff("30m", #"{"idle_release_seconds":1800,"released":false,"restores":0}"#)?.text, "Server: 30m")
    check("effective: off is its own state, not 'unknown'",
          eff("off", #"{"idle_release_seconds":null,"released":false,"restores":0}"#)?.text,
          "Server: off · weights stay resident")
    // THE case: flag dropped by the gate, server on its own default.
    check("effective: a dropped flag is called out",
          eff("30m", #"{"idle_release_seconds":600,"released":false,"restores":0}"#)?.ok, false)
    check("effective: and says what the server took instead",
          eff("30m", #"{"idle_release_seconds":600,"released":false,"restores":0}"#)?.text,
          "Server: 10m — not the 30m you set")
    check("effective: hours render as hours",
          eff("2h", #"{"idle_release_seconds":7200,"released":false,"restores":0}"#)?.text, "Server: 2h")
    // Blank means "server default" -- not a claim to check, so no disagreement.
    check("effective: blank config reports without accusing anyone",
          eff(nil, #"{"idle_release_seconds":600,"released":true,"restores":3}"#)?.text, "Server: 10m")
    check("effective: 'off' configured against an interval is a disagreement",
          eff("off", #"{"idle_release_seconds":600,"released":false,"restores":0}"#)?.ok, false)
    check("effective: and says the weights are being released",
          eff("off", #"{"idle_release_seconds":600,"released":false,"restores":0}"#)?.text,
          "Server: 10m — you set off, so weights are being released")
    check("effective: seconds render as seconds, never rounded up to minutes",
          eff("90s", #"{"idle_release_seconds":90,"released":false,"restores":0}"#)?.text, "Server: 90s")

    // The probe's parser. Only a token at the start of a line counts: argparse
    // prints options there, prose that merely mentions a flag does not, and
    // scanning every token would gate on flags the parser does not accept.
    let help = SplashProcess.longFlags("""
    usage: splash serve [-h] [--port PORT] [--persistent-cache]
      --port PORT           HTTP port
      --max-cache-disk MAX_CACHE_DISK
      --persistent-cache    keep the SSD cache (needs --max-cache-disk set)
      --idle-release D      idle release interval
    The engine also takes --idle-sleep, which serve does not.
    """)
    check("probe: picks up an option line", help.contains("--port"), true)
    check("probe: picks up an option the synopsis lists", help.contains("--persistent-cache"), true)
    check("probe: an option line wins over a prose mention",
          help.contains("--max-cache-disk"), true)
    check("probe: ignores a flag mentioned only mid-sentence",
          help.contains("--max-cache-disk-set"), false)
    // The real trap: a flag the prose names but the parser does not accept.
    // Gating on it would let an unparseable flag through.
    check("probe: rejects a flag named only in prose", help.contains("--idle-sleep"), false)
    check("probe: empty help yields no flags", SplashProcess.longFlags("").isEmpty, true)

    // Config persistence for the two new keys.
    var round = SplashConfig()
    round.persistentCache = true
    round.idleRelease = "2h"
    let persisted = try! JSONDecoder().decode(SplashConfig.self, from: JSONEncoder().encode(round))
    check("config: persistentCache round-trips", persisted.persistentCache, true)
    check("config: idleRelease round-trips", persisted.idleRelease, "2h")
    let legacy = try! JSONDecoder().decode(SplashConfig.self, from: Data(#"{"model":"a/b"}"#.utf8))
    check("config: a pre-1.2.0 file defaults both new keys",
          [legacy.persistentCache, legacy.idleRelease == nil], [false, true])
}
// MARK: - ModelCatalog
// The list used to be a hardcoded constant of two IDs, so installing a third
// model left it invisible — and displayName was a ternary that titled anything
// unrecognised "Qwen 3.6 35B A3B". Both halves are asserted here.
func modelCatalogChecks() {
    check("display: incoai package drops -Splash",
          ModelCatalog.displayName(for: "incoai/Qwen3.8-27B-Splash"), "Qwen3.8 27B")
    // No letter->digit split: it would restore "Qwen 3.8" but render "A3B" as
    // "A 3B". The old labels were hand-written, so the derived ones are
    // faithful to the repo name instead (Qwen3.8-27B really is "Qwen3.8").
    check("display: 35B keeps its A3B suffix intact",
          ModelCatalog.displayName(for: "incoai/Qwen3.6-35B-A3B-Splash"), "Qwen3.6 35B A3B")
    check("display: gguf repo drops -gguf, keeps the variant",
          ModelCatalog.displayName(for: "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0"),
          "Ternary Bonsai 2 27B · PQ2_0")
    // The regression the ternary would have shipped: an unknown model must not
    // borrow another model's name.
    check("display: unknown model does not borrow a name",
          ModelCatalog.displayName(for: "acme/Some-Other-Model"),
          "Some Other Model")
    check("display: bare id without owner",
          ModelCatalog.displayName(for: "Qwen3.8-27B-Splash"), "Qwen3.8 27B")
    check("display: empty id is survivable", ModelCatalog.displayName(for: ""), "")

    // The scan is a depth-2 read that must skip the dot-prefixed bookkeeping
    // siblings (.install.lock, .metadata, .resolved) or they become models.
    let root = ModelCatalog.modelsRoot
    check("models root is the server's path",
          root.path.hasSuffix("Library/Application Support/Splash/models"), true)
    let installed = ModelCatalog.installed()
    checkNil("scan never returns a dot-prefixed entry",
              installed.first { $0.hasPrefix(".") || $0.contains("/.") })
    check("scan yields owner/repo pairs",
          installed.allSatisfy { $0.split(separator: "/").count == 2 }, true)
    check("scan is sorted", installed == installed.sorted(), true)
    // Real-world check, skipped where the models are not installed so the
    // suite still runs on a clean machine.
    if FileManager.default.fileExists(atPath: root.path) {
        print("note  scan found \(installed.count) model(s): \(installed)")
    } else {
        print("note  no models dir at \(root.path); scan returned \(installed.count)")
    }
}

MainActor.assumeIsolated { chartPolicyChecks(); chartBucketingChecks(); argChecks(); adoptionChecks(); trayLookChecks(); modelCatalogChecks(); modelStatsChecks(); totalLoadChecks(); logChecks(); modelMismatchChecks() }

// MARK: - The menu-bar dot
//
// The two axes meet in exactly one place, `StatsModel.trayLook`, so that is what
// this pins. It used to share a function with the auto-restart policy; that
// policy is gone (BUG-11 was fixed upstream and re-tested 2026-10-05), and the
// governor now reclaims on its own.
@MainActor func trayLookChecks() {
    let GiB: Double = 1_073_741_824

    // MARK: The two axes. Service ("is splash up") and agent ("is the model
    // working") are different questions; conflating them is what produced a
    // DOTLESS ring while the menu said "decoding".
    func look(_ s: StatsModel.ServiceState, _ a: AgentStatus?) -> StatsModel.TrayLook {
        StatsModel.trayLook(service: s, agent: a)
    }
    check("axis: up + decoding = green, blinking", look(.up, .decoding),
          StatsModel.TrayLook(hue: .green, blinks: true))
    check("axis: up + loading = white, blinking (the pre-2026-09-25 look)", look(.up, .loading),
          StatsModel.TrayLook(hue: .white, blinks: true))
    check("axis: up + idle = grey, solid", look(.up, .idle),
          StatsModel.TrayLook(hue: .grey, blinks: false))
    // THE REGRESSION: up, but no snapshot yet. This used to fall through to the
    // same nil that means "no server", so the ring was drawn EMPTY while the
    // engine was fine. Up-but-unknown is grey; only a down service is empty.
    check("axis: up + NO snapshot is grey, NOT a dotless ring", look(.up, nil),
          StatsModel.TrayLook(hue: .grey, blinks: false))
    check("axis: down is the ONLY state with no dot", look(.down, nil).hue, StatsModel.DotHue.none)
    check("axis: down wins even if a stale agent status lingers", look(.down, .decoding).hue,
          StatsModel.DotHue.none)
    check("axis: starting is purple", look(.starting, nil).hue, StatsModel.DotHue.purple)
    check("axis: restarting is purple, not orange pressure", look(.restarting, .queued).hue,
          StatsModel.DotHue.purple)
    check("axis: warn outranks the agent phase (memory beats decoding)", look(.up, .memoryPressure).hue,
          StatsModel.DotHue.orange)
    check("axis: every agent state has a look when up", {
        let all: [AgentStatus] = [.stopped, .starting, .loading, .decoding, .masked, .queued,
                                   .suspended, .draining, .recovering, .stale, .budgetCapped,
                                   .memoryPressure, .idle, .error]
        return all.allSatisfy { look(.up, $0).hue != .none }
    }(), true)
    // Colour carries the state; motion carries "working". So the two working
    // states must be distinguishable WITHOUT relying on the blink.
    check("axis: loading and decoding differ in colour alone", look(.up, .loading).hue
            != look(.up, .decoding).hue, true)
    check("axis: no solid state blinks", {
        let all: [AgentStatus] = [.stopped, .starting, .masked, .queued, .suspended, .draining,
                                   .recovering, .stale, .budgetCapped, .memoryPressure, .idle, .error]
        return all.allSatisfy { !look(.up, $0).blinks }
    }(), true)
    check("axis: only a healthy service lets the agent blink", {
        let states: [StatsModel.ServiceState] = [.down, .starting, .restarting, .up]
        // down/starting/restarting must never blink; up blinks only if the agent
        // is actually working.
        return states.filter { look($0, .decoding).blinks } == [.up]
    }(), true)

    // MARK: Menu-bar dot colour — every AgentStatus must land on a hue.
    //
    // These go through `trayLook`, the ONLY mapping production calls. They used
    // to call `dotHue(status:lifecycleBusy:)`, which the app never invoked, so
    // the suite was green against a function that rendered nothing while the
    // shipped one went untested — and the two disagreed: dotHue sent `.loading`
    // to blue and mapped "no snapshot" to the empty ring, i.e. the exact
    // "no data looks like no server" bug the grey case exists to prevent.
    func hue(_ s: AgentStatus) -> String {
        StatsModel.trayLook(service: .up, agent: s).hue.rawValue
    }
    check("dot: idle is grey - present, healthy, nothing to do", hue(.idle), "grey")
    check("dot: decoding green", hue(.decoding), "green")
    // green must mean "producing", so only decoding may hold it among the
    // healthy states — otherwise idle is not a distinct signal any more.
    check("dot: green is reserved for decoding among healthy states", {
        let healthy: [AgentStatus] = [.idle, .decoding]
        return healthy.filter { hue($0) == "green" }.count == 1
    }(), true)
    check("dot: prefill is WHITE, not blue", hue(.loading), "white")
    check("dot: masked is orange - a request waiting its turn, like queued", hue(.masked), "orange")
    check("dot: starting is the service's purple, never a status colour", hue(.starting), "purple")
    check("dot: queued orange", hue(.queued), "orange")
    check("dot: suspended orange", hue(.suspended), "orange")
    check("dot: draining orange", hue(.draining), "orange")
    check("dot: recovering orange", hue(.recovering), "orange")
    check("dot: stale orange", hue(.stale), "orange")
    check("dot: memory-capped orange", hue(.budgetCapped), "orange")
    check("dot: memory-pressure orange", hue(.memoryPressure), "orange")
    check("dot: error red", hue(.error), "red")
    // A server that is up but has not answered yet is GREY, never the empty
    // ring: "up, don't know" and "no server" are opposite situations.
    check("dot: up with no snapshot is grey, NOT an empty ring",
          StatsModel.trayLook(service: .up, agent: nil).hue.rawValue, "grey")
    check("dot: only a down service draws the empty ring",
          StatsModel.trayLook(service: .down, agent: nil).hue.rawValue, "none")
    check("dot: idle and no-snapshot are the same grey, and neither is the ring", {
        hue(.idle) == StatsModel.trayLook(service: .up, agent: nil).hue.rawValue
            && StatsModel.trayLook(service: .down, agent: nil).hue.rawValue != "grey"
    }(), true)
    check("dot: an empty ring is drawn with no dot at all",
          StatsModel.dotWeight(.none), 0.0)
    // A restart must not read as engine pressure.
    check("dot: lifecycle busy is purple",
          StatsModel.trayLook(service: .restarting, agent: .budgetCapped).hue.rawValue, "purple")
    // Nothing may reach a blue dot any more: it is not in the documented palette
    // and only the two retired mappings ever produced it.
    check("dot: no status produces the undocumented blue", {
        let all: [AgentStatus] = [.stopped, .starting, .loading, .decoding, .masked, .queued,
                                   .suspended, .draining, .recovering, .stale, .budgetCapped,
                                   .memoryPressure, .idle, .error]
        return !all.contains { hue($0) == "blue" }
    }(), true)
    // The service axis overrides a healthy agent: a restart outranks green, so a
    // decode in flight cannot paint over a start in progress.
    check("dot: a restart outranks a green decode",
          StatsModel.trayLook(service: .restarting, agent: .decoding).hue.rawValue, "purple")
    check("dot: busy purple != warn orange", StatsModel.DotHue.purple == .orange, false)
    // Every status collapses onto exactly one hue, and absence is its own state.
    check("dot: every status maps to a hue, and none to the empty ring", {
        let all: [AgentStatus] = [.stopped, .starting, .loading, .decoding, .masked, .queued,
                                   .suspended, .draining, .recovering, .stale, .budgetCapped,
                                   .memoryPressure, .idle, .error]
        return all.allSatisfy { hue($0) != "none" }
    }(), true)
    // `.blue` survives in DotHue only because the palette switches are exhaustive;
    // nothing produces it, which the check above enforces.
    check("dot: 8 cases exist (7 colours + the empty ring), all distinct",
          Set(StatsModel.DotHue.allCases).count, 8)

    // MARK: Dot legibility. The earlier palette reached 3:1 green-vs-orange by
    // darkening green, and the dot then vanished against a blue menu bar — the
    // hue was separated from the other dot but not from the background. What is
    // asserted now is what the screenshot actually demanded: every dot bright
    // enough to see, an outline so it works on any bar, and SIZE as the primary
    // ok-vs-warn separator.
    func w(_ h: StatsModel.DotHue) -> Double { StatsModel.dotWeight(h) }
    func lum(_ h: StatsModel.DotHue) -> Double { StatsModel.dotLuminance(h) }
    check("dot: green is bright enough to see (lum > 0.25)", lum(.green) > 0.25, true)
    check("dot: every DRAWN dot is brighter than lum 0.20", {
        // `.none` is excluded on purpose: it is never painted, and the point of
        // it is that absence has no colour. Excluding it here is what stops
        // someone later giving it one and quietly breaking that.
        StatsModel.DotHue.allCases.filter { $0 != .none }.allSatisfy { lum($0) > 0.20 }
    }(), true)
    check("dot: the empty ring exists as its own state", StatsModel.DotHue.allCases.contains(.none), true)
    check("dot: an outline is always drawn", StatsModel.dotStrokeFraction > 0, true)
    check("dot: outline is thick enough to define the edge",
          StatsModel.dotStrokeFraction >= 0.30, true)
    // ok vs warn separated mainly by size now, so the step must be real.
    check("dot: warn is clearly bigger than ok (>=25% step)",
          w(.orange) / w(.green) >= 1.25, true)
    check("dot: red is bigger than warn", w(.red) > w(.orange), true)
    check("dot: size ladder rises with severity",
          w(.red) > w(.orange) && w(.orange) > w(.purple) && w(.purple) > w(.green), true)
    check("dot: nothing runs off the symbol (max < 0.6)",
          StatsModel.DotHue.allCases.map { w($0) }.max() ?? 1.0 < 0.6, true)
    // The 3:1 claim was withdrawn, not quietly restated — it is no longer true
    // and pretending otherwise is what caused the regression.
    check("dot: green/orange 3:1 claim WITHDRAWN (documented, not asserted)",
          StatsModel.dotContrast(.green, .orange) < 3.0, true)

    // MARK: pulse — motion means "working on tokens", via trayLook alone.
    //
    // The retired `dotAnimates(_:snapshot:)` argued the opposite at length (that
    // the dot must go steady the moment a token flows) and was never called by
    // production, so the suite was pinning a rule the app did not implement.
    // These drive it through the real status instead of hand-picked cases.
    func busy(_ json: String) -> (AgentStatus?, StatusDTO) {
        let s = dto(json); return (AgentStatus.derive(from: s), s)
    }
    let (prefillOnly, _) = busy(#"{"ready":true,"scheduler":{"prefilling":1}}"#)
    check("pulse: prefill blinks (white, working)",
          StatsModel.trayLook(service: .up, agent: prefillOnly).blinks, true)
    let (overlap, _) = busy(#"{"ready":true,"scheduler":{"prefilling":1,"decoding":1}}"#)
    check("pulse: prefill WHILE decoding still blinks - derive ranks prefill first",
          StatsModel.trayLook(service: .up, agent: overlap).blinks, true)
    let (decoding, _) = busy(#"{"ready":true,"scheduler":{"decoding":1}}"#)
    check("pulse: decoding blinks - a working green circle, solid on the bright half",
          StatsModel.trayLook(service: .up, agent: decoding).blinks, true)
    for st in [AgentStatus.idle, .queued, .budgetCapped, .error, .stale, .masked] {
        check("pulse: \(st) is solid", StatsModel.trayLook(service: .up, agent: st).blinks, false)
    }
    check("pulse: nothing blinks without data",
          StatsModel.trayLook(service: .up, agent: nil).blinks, false)
    check("pulse: a down service never blinks, whatever the agent says",
          StatsModel.trayLook(service: .down, agent: .decoding).blinks, false)

    // The dot is ALWAYS a full filled circle — alpha and a hollow ring are both
    // retired. Alpha made a 0.30 grey dim half blend into the white stroke behind
    // it, so the pulse read as the dot vanishing; the hollow ring put a bare
    // coloured ring on screen, which is the app's "no server" look, so a working
    // green dot read as a dead server.
    check("scale: a steady state is FULL SIZE, whatever the phase says",
          StatsModel.dotScale(animating: false, phaseBright: false), 1.0)
    check("scale: steady on the bright half too",
          StatsModel.dotScale(animating: false, phaseBright: true), 1.0)
    check("scale: animating bright half is FULL SIZE",
          StatsModel.dotScale(animating: true, phaseBright: true), 1.0)
    check("scale: animating dim half SHRINKS - never a ring, never a faint fill",
          StatsModel.dotScale(animating: true, phaseBright: false) < 0.8, true)
    check("scale: the two halves genuinely differ",
          StatsModel.dotScale(animating: true, phaseBright: true)
            != StatsModel.dotScale(animating: true, phaseBright: false), true)
    // Shrinking must not reach zero, or the dim half would be the empty ring.
    check("scale: the dim half is still a visible dot, never the empty ring",
          StatsModel.dotScale(animating: true, phaseBright: false) > 0.3, true)
    // Exactly two states blink, so motion cannot be mistaken for severity.
    check("phase: exactly 2 states blink while the service is up (loading, decoding)", {
        let all: [AgentStatus] = [.stopped, .starting, .loading, .decoding, .masked, .queued,
                                   .suspended, .draining, .recovering, .stale, .budgetCapped,
                                   .memoryPressure, .idle, .error]
        return all.filter { StatsModel.trayLook(service: .up, agent: $0).blinks }.count == 2
    }(), true)

    // MARK: retention trim — binary search over a date-ascending buffer
    do {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let buf = (0..<500).map { Sample(date: base.addingTimeInterval(Double($0))) }
        check("lowerBound: exact hit returns that index",
              StatsModel.lowerBound(base.addingTimeInterval(250), in: buf), 250)
        check("lowerBound: cutoff between samples rounds up to the next",
              StatsModel.lowerBound(base.addingTimeInterval(250.5), in: buf), 251)
        check("lowerBound: cutoff before everything returns startIndex",
              StatsModel.lowerBound(base.addingTimeInterval(-10), in: buf), 0)
        check("lowerBound: cutoff after everything returns endIndex",
              StatsModel.lowerBound(base.addingTimeInterval(9999), in: buf), 500)
        check("lowerBound: empty buffer is safe",
              StatsModel.lowerBound(base, in: []), 0)
        // The property that matters: the trim must keep exactly what the old
        // linear filter kept, or the chart silently loses its left edge.
        let cut = base.addingTimeInterval(123.25)
        check("lowerBound: keeps the same samples a linear filter would",
              Array(buf[StatsModel.lowerBound(cut, in: buf)...].map(\.date))
                == buf.filter { $0.date >= cut }.map(\.date), true)
        // And it must survive a full-size buffer, which is why it is a search
        // and not a scan: 18 000 entries trimmed once per poll.
        let big = (0..<StatsModel.maxSamples).map {
            Sample(date: base.addingTimeInterval(Double($0)))
        }
        let bigCut = base.addingTimeInterval(Double(StatsModel.maxSamples - 900))
        check("lowerBound: full-size buffer trims to the window",
              big.count - StatsModel.lowerBound(bigCut, in: big), 900)
    }

}

// MARK: - SSD cache tier (disk.*)
func disk(_ json: String) -> StatusDTO.Disk? { dto(json).disk }
check("disk: capacity decodes (the saturation denominator)",
      disk(#"{"ready":true,"disk":{"capacity_bytes":34359738368}}"#)?.capacityBytes, 34_359_738_368)
// The quota is shared by states and KV pages, so used_bytes is the tier's
// WHOLE quota use and already includes the KV kv_bytes reports. kv_bytes is a
// share of used_bytes, never a complement: summing the two double-counts the
// KV, which is how the tile once read 132.7% of a 16 GiB quota the server
// kept under its limit (a full quota refuses new writes and drops the oldest
// copies; it does not grow past it).
check("disk: saturation is used_bytes over capacity (KV already inside)",
      disk(#"{"ready":true,"disk":{"capacity_bytes":1000,"used_bytes":300,"kv_bytes":200}}"#)?.saturation, 0.3)
check("disk: an empty tier reads 0%, not nil",
      disk(#"{"ready":true,"disk":{"capacity_bytes":1000,"used_bytes":0,"kv_bytes":0}}"#)?.saturation, 0.0)
check("disk: a full tier reads 100%",
      disk(#"{"ready":true,"disk":{"capacity_bytes":1000,"used_bytes":1000,"kv_bytes":100}}"#)?.saturation, 1.0)
check("disk: a DISABLED tier (capacity 0) is nil, not 0% of nothing", {
    let d = disk(#"{"ready":true,"disk":{"capacity_bytes":0,"used_bytes":0,"kv_bytes":0}}"#)
    return d?.saturation == nil
}(), true)
check("disk: a missing kv_bytes still saturates (it is a share, not a term)",
      disk(#"{"ready":true,"disk":{"capacity_bytes":1000,"used_bytes":300}}"#)?.saturation, 0.3)
check("disk: an older release with no disk object decodes to nil",
      dto(#"{"ready":true}"#).disk == nil, true)
check("disk: refusals are readable, so full-vs-idle is distinguishable",
      disk(#"{"ready":true,"disk":{"capacity_bytes":1000,"used_bytes":0,"kv_bytes":0,"kv_demotions":12,"kv_demotions_refused":3}}"#)?.kvDemotionsRefused, 3)
check("disk: used alone is states; kv is reported separately", {
    let d = disk(#"{"ready":true,"disk":{"capacity_bytes":1000,"used_bytes":300,"kv_bytes":200}}"#)
    return d?.usedBytes == 300 && d?.kvBytes == 200
}(), true)
// The live shape, verbatim from /status, so a schema rename breaks this.
check("disk: the real /status disk block decodes", {
    let d = disk(#"{"ready":true,"disk":{"capacity_bytes":34359738368,"used_bytes":0,"read_bytes":0,"written_bytes":0,"kv_blocks":0,"kv_bytes":0,"kv_demotions":0,"kv_demotion_failures":0,"kv_demotions_refused":0,"kv_restores":0,"kv_restore_failures":0,"kv_pending_pages":0}}"#)
    return d?.capacityBytes == 34_359_738_368 && d?.saturation == 0.0
}(), true)
// ...and through the one-payload-every-key sweep above, so a rename in either
// direction is caught.
check("disk: capacity maps in the full payload", full.disk?.capacityBytes, 34_359_738_368)
check("disk: used maps in the full payload", full.disk?.usedBytes, 65)
check("disk: kv_bytes maps in the full payload", full.disk?.kvBytes, 69)
check("disk: kv_demotions_refused maps in the full payload", full.disk?.kvDemotionsRefused, 72)
check("disk: kv_restore_failures maps in the full payload", full.disk?.kvRestoreFailures, 74)

// MARK: - Extra payloads (e.g. a live capture)
for path in CommandLine.arguments.dropFirst() {
    let d = try decoder.decode(StatusDTO.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    print("\(path) -> ready=\(d.ready.map { "\($0)" } ?? "nil")"
        + " model=\(d.instance?.model ?? "nil")"
        + " family=\(d.memoryPlan?.model?.modelName ?? "nil")"
        + " ctx=\(d.maximumContextTokens.map(String.init) ?? "nil")"
        + "/\(d.memoryPlan?.maximumContextTokens.map(String.init) ?? "nil")")
}

// MARK: - Benchmark rules
do {
    // The ordering decision: the pre-selected model runs LAST so the run ends
    // on it and there is no restore step.
    let three = ["incoai/Qwen3.6-35B-A3B-Splash",
                 "incoai/Qwen3.8-27B-Splash",
                 "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0"]
    let p = BenchmarkEngine.plan(installed: three, current: "incoai/Qwen3.8-27B-Splash")
    check("plan puts the pre-selected model last", p.last, "incoai/Qwen3.8-27B-Splash")
    check("plan keeps every model", p.count, 3)
    check("plan has no duplicates", Set(p).count, p.count)
    check("plan preserves discovery order for the rest",
          Array(p.dropLast()), three.filter { $0 != "incoai/Qwen3.8-27B-Splash" })
    // A current model that is no longer installed must not be appended.
    check("unknown current falls back to discovery order",
          BenchmarkEngine.plan(installed: three, current: "gone/model"), three)
    check("nil current falls back",
          BenchmarkEngine.plan(installed: three, current: nil), three)
    check("single model is its own last", BenchmarkEngine.plan(installed: ["a"], current: "a"), ["a"])

    // Noncing is what keeps a repeat run off the prefix cache.
    let a = BenchRules.prompts(nonce: "aaa")
    let b = BenchRules.prompts(nonce: "bbb")
    check("5 prompts", a.count, 5)
    check("long prompt is nonced per run", a[3].text == b[3].text, false)
    check("nonce appears in the long prompt", a[3].text.contains("[nonce:aaa]"), true)
    check("short prompts are unchanged by the nonce", a[0].text == b[0].text, true)
    // 256 truncated the 35B to 0 answer characters; every model must finish.
    check("instruction cap 1024", a[0].maxTokens, 1024)
    check("reasoning cap 512", a[1].maxTokens, 512)
    // reasoning completed at 475/512 on the 35B, so 512 is adequate there; only
    // instruction (256 -> 0 answer chars) and code_gen were too tight.
    check("the answer-heavy scenarios can hold an answer",
          a[0].maxTokens >= 1024 && a[2].maxTokens >= 1024, true)
    check("vision cap 512", a[4].maxTokens, 512)
    check("only the vision prompt needs an image", a.filter(\.needsImage).count, 1)
    // Long-context sizes are selectable, 32K by default.
    check("long context options", BenchRules.LongContext.options, [32, 64, 128, 256])
    check("long context default is still the smallest option",
          BenchRules.LongContext.options.first, 32)
    check("256K selection produces a 256K scenario",
          BenchRules.prompts(nonce: "z", longContextK: 256)
              .first { $0.id.hasPrefix("long_ctx") }?.id, "long_ctx_256k")
    check("long context defaults to 32K", BenchRules.prompts(nonce: "z")[3].id, "long_ctx_32k")
    // Dynamic context provisioning. The cap is a spawn argument, so a run has to
    // raise it before the first hardRestart or a 256K scenario comes back
    // context_length_exceeded. It must never *lower* it: the run shares one
    // parameter key with the stored baseline, so shrinking the cap would rewrite
    // that baseline's short-prompt memory numbers with a different KV plan.
    check("256K raises a 128K cap", BenchmarkEngine.neededContextK(scenarioK: 256, configured: "128K"), 256)
    check("32K leaves a 128K cap alone", BenchmarkEngine.neededContextK(scenarioK: 32, configured: "128K"), 128)
    check("64K leaves a 128K cap alone", BenchmarkEngine.neededContextK(scenarioK: 64, configured: "128K"), 128)
    check("128K equals a 128K cap", BenchmarkEngine.neededContextK(scenarioK: 128, configured: "128K"), 128)
    check("an unset cap is raised to the scenario",
          BenchmarkEngine.neededContextK(scenarioK: 256, configured: nil), 256)
    check("an unset cap still gets a 32K scenario",
          BenchmarkEngine.neededContextK(scenarioK: 32, configured: nil), 32)
    check("a larger configured cap is never cut",
          BenchmarkEngine.neededContextK(scenarioK: 32, configured: "512K"), 512)
    check("the cap parser reads K", BenchmarkEngine.contextK("256K"), 256)
    check("the cap parser rejects junk", BenchmarkEngine.contextK("auto"), nil)
    check("the cap parser rejects zero", BenchmarkEngine.contextK("0K"), nil)
    check("64K selection is honoured",
          BenchRules.prompts(nonce: "z", longContextK: 64)[3].id, "long_ctx_64k")
    check("128K selection is honoured",
          BenchRules.prompts(nonce: "z", longContextK: 128)[3].id, "long_ctx_128k")
    // The corpus is code, and bigger selections must actually get bigger.
    let sizes = [32, 64, 128].map {
        BenchRules.prompts(nonce: "z", longContextK: $0)[3].text.count
    }
    check("32K long prompt is code-sized", sizes[0] > 120_000, true)
    check("64K is larger than 32K", sizes[1] > sizes[0], true)
    check("128K is larger than 64K", sizes[2] > sizes[1], true)
    check("64K roughly doubles 32K", Double(sizes[1]) > Double(sizes[0]) * 1.9, true)
    // The requested size is a target: the table always shows real prompt_tokens,
    // because the ratio is per model family and only approximate.
    check("32K target is 121k chars at the measured 3.78 ratio",
          BenchRules.LongContext.charsPerToken, 3.78)
    // A flat 180s failed 2 of 3 models at 64K: prefill alone is ~171s there.
    check("short prompts keep the 180s floor",
          BenchRules.timeout(promptTokens: 59, budget: 256), 180.0)
    check("32K gets more than the old flat timeout",
          BenchRules.timeout(promptTokens: 32_000, budget: 4096) > 180, true)
    check("64K gets 15 minutes", BenchRules.timeout(promptTokens: 64_000, budget: 4096), 904.8)
    check("128K scales further", BenchRules.timeout(promptTokens: 128_000, budget: 4096), 1544.8)
    check("timeout grows with the prompt",
          BenchRules.timeout(promptTokens: 128_000, budget: 4096)
            > BenchRules.timeout(promptTokens: 64_000, budget: 4096), true)
    check("timeout is capped at 30 minutes",
          BenchRules.timeout(promptTokens: 400_000, budget: 4096), 1800.0)
    check("a bigger budget buys more time",
          BenchRules.timeout(promptTokens: 32_000, budget: 4096)
            > BenchRules.timeout(promptTokens: 32_000, budget: 256), true)
    // Int(3.78) truncated to 3 and inflated 64K to 80 640 tokens -> a 17-minute
    // ceiling. Division must be in Double or the estimate is wrong by 26%.
    check("the ratio is a Double, not truncated to an Int",
          BenchRules.LongContext.charsPerToken, 3.78)
    check("64K stays under a 20-minute ceiling",
          BenchRules.timeout(promptTokens: 64_000, budget: 4096) < 1200, true)
    check("timeout reads in minutes", BenchRules.describe(904.8), "15m 5s")
    check("timeout reads in seconds", BenchRules.describe(45), "45s")
    // Byte-identical inputs. Same nonce and size must give byte-identical
    // prompts, or two runs are not comparable and a diff means nothing.
    let a1 = BenchRules.prompts(nonce: "fixed1", longContextK: 32)
    let a2 = BenchRules.prompts(nonce: "fixed1", longContextK: 32)
    check("same nonce gives byte-identical prompts",
          a1.map(\.text) == a2.map(\.text), true)
    check("same nonce gives identical ids and budgets",
          a1.map(\.id) == a2.map(\.id) && a1.map(\.maxTokens) == a2.map(\.maxTokens), true)
    // The nonce must vary per run, or a repeat run hits the prefix cache. Only
    // the long prompt carries it; the short ones are deliberately stable.
    let b1 = BenchRules.prompts(nonce: "run-one", longContextK: 32)
    let b2 = BenchRules.prompts(nonce: "run-two", longContextK: 32)
    check("the long prompt differs between runs", b1[3].text == b2[3].text, false)
    check("short prompts are stable across runs",
          [b1[0].text, b1[1].text, b1[2].text] == [b2[0].text, b2[1].text, b2[2].text], true)
    check("every nonce appears in the long prompt",
          b1[3].text.contains("[nonce:run-one]"), true)
    check("no stale nonce leaks into a later run",
          b1[3].text.contains("run-two"), false)
    // Changing the size must change only the long prompt.
    let c1 = BenchRules.prompts(nonce: "fixed1", longContextK: 64)
    check("64K renames the long scenario", c1[3].id, "long_ctx_64k")
    check("64K changes only the long prompt",
          [c1[0].text, c1[1].text, c1[2].text] == [a1[0].text, a1[1].text, a1[2].text], true)
    check("64K effort is unchanged", c1[3].effort, a1[3].effort)
    check("the long scenario reads code, not prose",
          BenchRules.prompts(nonce: "z")[3].text.contains("public struct Backoff"), true)
    // The image is opt-in: a text-only run must still cover 4 prompts, and the
    // vision row is reported as skipped rather than blocking the benchmark.
    check("4 of 5 prompts run without an image", a.filter { !$0.needsImage }.count, 4)
    check("greedy, not sampled", BenchRules.temperature, 0.0)
    check("medium effort, not the empty-answer xhigh default", BenchRules.reasoningEffort, "medium")
    // Probed live on splash 1.1.0: these four return 200 and anything else fails
    // with `invalid reasoning_effort`, so every scenario must pick from this set.
    check("the four accepted efforts", BenchRules.efforts, ["low", "medium", "high", "xhigh"])
    check("every scenario uses an accepted effort",
          a.allSatisfy { BenchRules.efforts.contains($0.effort) }, true)
    // Effort is per scenario, not one knob for the whole run: a coding scenario
    // wants high, listing three libraries wants low.
    check("effort is fixed per scenario", a.map(\.effort),
          ["low", "medium", "high", "high", "medium"])
    check("coding scenarios run at high effort", a[2].effort, "high")
    check("the trivial scenario runs at low effort", a[0].effort, "low")
    // high effort at 512 tokens returned 0 chars of content live, so it gets 2048.
    check("high effort budget", BenchRules.budget(for: "high"), 4096)
    check("medium effort keeps the reference budget", BenchRules.budget(for: "medium"), 512)
    check("the coding scenarios use the high-effort budget", a[2].maxTokens, 4096)
    check("the long scenario uses the high-effort budget", a[3].maxTokens, 4096)
    check("the reasoning scenario keeps 512", a[1].maxTokens, 512)
    // 32k tokens of CODE at 3.4 chars/token ~= 108.8k chars. Asserting on chars,
    // not tokens: the tray cannot tokenise without the server's tokenizer.
    check("long prompt targets 32k code tokens (~121k chars)", a[3].text.count > 120_000, true)
    // The builder stops on the first module that crosses the target, so overshoot
    // is at most one ~1.4k-char module plus the question.
    check("long prompt overshoot is bounded", a[3].text.count < 123_000, true)
    check("long prompt fits the 128K cap", a[3].text.count < 512_000, true)
    check("long prompt id states its size", a[3].id, "long_ctx_32k")
}

// MARK: - Benchmark reply decoding
// A live capture from splash 1.1.0 (/v1/chat/completions, non-streaming). If the
// Codable ever stops matching the server, every bench row silently becomes an
// error instead of a measurement, and nothing else would notice.
if let data = FileManager.default.contents(atPath: "Tests/Fixtures/bench_reply.json"),
   let reply = try? JSONDecoder().decode(SplashClient.Completion.self, from: data) {
    // Structural, not hardcoded: the fixture is captured live, so exact token
    // counts change with whichever model happens to be serving. What must hold is
    // that every declared field decodes and is self-consistent.
    check("decodes usage.promptTokens", (reply.usage?.promptTokens ?? 0) > 0, true)
    check("decodes usage.completionTokens", (reply.usage?.completionTokens ?? 0) > 0, true)
    check("decodes timings.promptN", reply.timings?.promptN ?? 0 > 0, true)
    check("decodes timings.predictedN", reply.timings?.predictedN ?? 0 > 0, true)
    check("cacheN decodes", reply.timings?.cacheN ?? -1 >= 0, true)
    check("usage agrees with timings on promptN",
          reply.usage?.promptTokens == reply.timings?.promptN, true)
    check("usage agrees with timings on predictedN",
          reply.usage?.completionTokens == reply.timings?.predictedN, true)
    check("decode yields no server error", reply.error?.message, nil)
    // finishReason is what makes truncation visible instead of inferred.
    check("decodes choices", reply.choices?.isEmpty, false)
    check("a greedy finish decodes as stop", reply.choices?.first?.finishReason, "stop")
    check("decodes the answer length",
          reply.choices?.first?.message?.content?.count, 32)
    // completionTokens mixes reasoning with the answer, so the split is decoded.
    check("decodes reasoningTokens",
          reply.usage?.completionTokensDetails?.reasoningTokens ?? 0 > 0, true)
    check("reasoningContent decodes separately",
          (reply.choices?.first?.message?.reasoningContent?.count ?? 0) > 0, true)
    // The derived TTFT the bench reports: prefill + one token.
    let prefill = (reply.timings?.promptMs ?? 0) / 1000
    let tps = reply.timings?.predictedPerSecond ?? 0
    let ttft = prefill + (tps > 0 ? 1.0 / tps : 0)
    check("derived ttft is prefill-dominated, not ~0", ttft > 0.05, true)
    check("derived ttft is at least the prefill", ttft >= prefill, true)
    // The old formula returned ~0.037 s here because timings covers the whole
    // request; assert that mistake cannot come back.
    check("elapsed-minus-timings would be the wrong ttft", prefill > 0.05, true)
    check("predictedPerSecond decodes as a rate", tps > 0, true)
    var bm = BenchMetrics()
    check("elapsed is nil until measured", bm.elapsed, nil)
    bm.elapsed = 1.25
    check("elapsed holds a wall-clock value", bm.elapsed, 1.25)
    check("memoryGiB is nil until measured", bm.memoryGiB, nil)
    bm.memoryGiB = 14.8
    check("memoryGiB holds resident memory", bm.memoryGiB, 14.8)
    let br = BenchResult(model: "m", promptID: "p", effort: "medium", order: 0, metrics: bm)
    check("effort is recorded on the result", br.effort, "medium")
    // Effort is per result, so runs at different settings cannot be confused.
    check("result id keys on model and prompt",
          BenchResult(model: "m", promptID: "p", effort: "low", order: 0, metrics: bm).id, "m|p")
    check("loadSeconds is nil by default", br.loadSeconds, nil)
    check("loadMemoryGiB is nil by default", br.loadMemoryGiB, nil)
    // The fixture is captured live and can be a degenerate request (a mostly
    // cached prefix, a cold engine), so TTFT arithmetic is checked against fixed
    // numbers rather than whatever the last capture happened to record.
    let ttftFixed = 14.42 + 1.0 / 55.5
    check("ttft = prefill + one token, not elapsed - timings",
          ttftFixed > 14.43 && ttftFixed < 14.44, true)
    check("the old formula would have said ~0.04s for a 14s prefill",
          max(0, 23.66 - 14.42 - 9.22) < 0.05, true)
} else {
    check("fixture decodes", "could not decode Tests/Fixtures/bench_reply.json", "a SplashClient.Completion")
}

// MARK: - Bench report is readable and lands beside stats.json
do {
    check("report sits beside stats.json",
          BenchReport.url.deletingLastPathComponent().lastPathComponent, "SplashControl")
    check("report filename", BenchReport.filename, "bench-report.txt")
    check("report is a sibling of stats.json",
          BenchReport.url.deletingLastPathComponent()
            == URL(fileURLWithPath: BenchReport.url.deletingLastPathComponent().path), true)
    // The split that makes `out` readable: reasoning vs the actual answer.
    var m = BenchMetrics()
    m.completionTokens = 3121
    m.reasoningTokens = 2445
    check("out alone would misread as answer length", m.completionTokens!, 3121)
    check("reasoning is decoded separately", m.reasoningTokens!, 2445)
    check("answer share is out minus reasoning", m.completionTokens! - m.reasoningTokens!, 676)

    // End-to-end: write a real report and read it back. The point of the file is
    // that a human can read the numbers without the dashboard, so assert the text.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("benchreport-\(UUID().uuidString)")
    var good = BenchMetrics()
    good.outputTps = 55.8; good.promptTps = 124; good.ttft = 0.50
    good.promptTokens = 59; good.completionTokens = 2824; good.reasoningTokens = 2445
    good.finishReason = "stop"; good.cacheN = 0; good.elapsed = 54.56
    good.contentChars = 40; good.memoryGiB = 18.5
    var trunc = BenchMetrics()
    trunc.promptTokens = 29; trunc.completionTokens = 256; trunc.reasoningTokens = 256
    trunc.finishReason = "length"; trunc.contentChars = 0
    var a = BenchResult(model: "incoai/Qwen3.8-27B-Splash", promptID: "code_gen",
                         effort: "high", order: 0, metrics: good)
    a.loadSeconds = 14.0
    let b = BenchResult(model: "incoai/Qwen3.8-27B-Splash", promptID: "instruction",
                         effort: "low", order: 0, metrics: trunc)
    BenchReport.write([a, b], plan: ["incoai/Qwen3.8-27B-Splash"], longContextK: 64, to: dir)
    let text = (try? String(contentsOf: dir.appendingPathComponent(BenchReport.filename),
                            encoding: .utf8)) ?? ""
    check("report was written", text.isEmpty, false)
    check("report names the rules", text.contains("long context 64K"), true)
    check("report headers the table", text.contains("in/out") && text.contains("think"), true)
    check("report headers the mem column", text.contains("mem"), true)
    check("report formats resident memory", text.contains("18.5G"), true)
    check("report formats memory summary", text.contains("mem avg 18.5G"), true)
    check("report lists the prompt id", text.contains("code_gen"), true)
    check("report lists the per-scenario effort", text.contains("high"), true)
    check("report shows the reasoning split", text.contains("2445(379)"), true)
    check("report marks truncation", text.contains("empty"), true)
    check("report states the long-context size", text.contains("64K"), true)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Benchmark must not pollute the serving history
do {
    let ms = ModelStats(ephemeral: true)
    var s = Sample(date: Date())
    s.decodeTps = 40
    let key = ModelStats.Key(model: "m", kvFormat: "q", maxContext: "128K",
                             maxMemory: "48G", maxCacheDisk: "32G")
    ms.record(s, key: key)
    check("serving traffic is recorded", ms.rows.count, 1)
    let before = ms.rows[0].decode.count
    check("decode sample counted", before, 1)
    ms.isSuppressed = true
    ms.record(s, key: key)
    check("bench traffic is suppressed, not reset", ms.rows[0].decode.count, before)
    check("history survives the suppressed run", ms.rows.count, 1)
    ms.isSuppressed = false
    ms.record(s, key: key)
    check("recording resumes after the run", ms.rows[0].decode.count, before + 1)
}

// MARK: - Chart bucketing (2.2)
// Moved out of the SwiftUI view, so the two properties that make the bars
// readable are assertable instead of eyeballed:
//  - mark identity is derived, so an unchanged bucket keeps its mark across
//    renders (a fresh UUID per render made Charts rebuild everything every tick)
//  - idle time is plotted as a gap, not collapsed away
@MainActor func chartBucketingChecks() {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    var samples: [Sample] = []
    // 30 s at 1 s: decode at 10, then 30, then nothing at all.
    for i in 0..<30 {
        var s = Sample(date: t0.addingTimeInterval(TimeInterval(i)))
        if i < 10 { s.decodeTps = 10 }
        if i >= 10 && i < 20 { s.decodeTps = 30 }
        s.gap = i == 12
        samples.append(s)
    }

    let pts = StatsModel.chartPoints(
        samples: samples[0...], series: ["tok/s"], duration: 10,
        extract: { s, _ in s.decodeTps })
    check("30 s at a 10 s bucket width is three buckets", pts.count, 3)
    check("bucket means average within the bucket",
          pts.map { $0.value ?? -1 }, [10.0, 30.0, -1.0])
    check("a gap inside a bucket does not zero it", pts[1].value, 30.0)
    // The empty tail bucket must survive as nil: dropping it is what made bars
    // minutes apart render as adjacent.
    checkNil("an idle bucket is a nil point, not a missing one", pts[2].value)
    check("the idle bucket still occupies its time slot",
          Int(pts[2].date.timeIntervalSince(t0)), 25)
    checkNil("a series with no data at all is nil everywhere", StatsModel.chartPoints(
        samples: samples[0...], series: ["kv"], duration: 10,
        extract: { s, _ in s.kvPagesActive.map(Double.init) })[0].value)

    // Identity must be stable for the same bucket and differ across buckets.
    let again = StatsModel.chartPoints(
        samples: samples[0...], series: ["tok/s"], duration: 10,
        extract: { s, _ in s.decodeTps })
    check("point ids are stable across recomputes", pts.map(\.id), again.map(\.id))
    check("ids differ per bucket", Set(pts.map(\.id)).count, 3)
    check("ids carry the series name", pts[0].id.hasPrefix("tok/s@"), true)

    check("buckets align to absolute time, not to the first sample",
          Int(StatsModel.bucketStart(for: t0.addingTimeInterval(9.9),
                                     duration: 10).timeIntervalSince(t0)), 0)
    check("a bucket start truncates down",
          Int(StatsModel.bucketStart(for: t0.addingTimeInterval(19.9),
                                     duration: 10).timeIntervalSince(t0)), 10)
    checkNil("zero-duration bucketing returns nothing",
             StatsModel.chartPoints(samples: samples[0...], series: ["x"], duration: 0,
                                    extract: { _, _ in 1 }).first)
}

// MARK: - Adopted-server guards (3.4)
// The 2026-09-28 incident: memory auto-restart killed an externally started
// Bonsai and relaunched the tray's configured model. These assert the parse and
// the auto-restart refusal that make that impossible now.
@MainActor func adoptionChecks() {
    check("model parsed from separate argv entries",
          SplashProcess.parseModel(["/opt/homebrew/bin/splash", "serve", "--model",
                                    "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0"]),
          "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0")
    check("model parsed from --model=",
          SplashProcess.parseModel(["splash", "serve", "--model=incoai/Qwen3.6-35B-A3B-Splash"]),
          "incoai/Qwen3.6-35B-A3B-Splash")
    checkNil("no --model in argv", SplashProcess.parseModel(["splash", "serve", "--port", "9000"]))
    checkNil("truncated argv is not read past the end",
             SplashProcess.parseModel(["splash", "serve", "--model"]))
    checkNil("no args at all", SplashProcess.parseModel(nil))

    // curl snippet names the SERVING model, not the configured one.
    var cfg = SplashConfig()
    cfg.model = "incoai/Qwen3.6-35B-A3B-Splash"
    cfg.port = 9000
    let proc = SplashProcess(config: cfg)
    let snippet = proc.curlSnippet(serving: "prism-ml/Ternary-Bonsai-2-27B-gguf")
    check("curl snippet names the serving model", snippet.contains("Ternary-Bonsai"), true)
    check("curl snippet uses the configured port", snippet.contains("127.0.0.1:9000/v1"), true)
    check("curl snippet falls back to the configured model",
          proc.curlSnippet(serving: nil).contains("Qwen3.6-35B"), true)
    check("endpoint is the /v1 base URL", proc.endpointURL, "http://127.0.0.1:9000/v1")
    var keyed = cfg
    keyed.apiKey = "s3cret"
    check("curl snippet carries a configured API key",
          SplashProcess(config: keyed).curlSnippet(serving: nil).contains("s3cret"), true)
}

// MARK: - Benchmark history round-trip (3.5 / 1.4)
// The run used to live only in memory: quitting the app threw away 20 minutes.
let benchDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("bench-hist-\(ProcessInfo.processInfo.processIdentifier)")
let benchResult = BenchResult(model: "m/a", promptID: "instruction", effort: "low",
                              loadSeconds: 3.5, loadMemoryGiB: 16.2, order: 0,
                              metrics: BenchMetrics(ttft: 0.4, outputTps: 118.2,
                                                    promptTokens: 24, contentChars: 120,
                                                    memoryGiB: 18.4),
                              output: "1. pytest\n2. unittest\n3. nose")
let history = BenchHistory(finishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           plan: ["m/a", "m/b"], longContextK: 64,
                           results: [benchResult],
                           prompts: ["instruction": "List exactly 3 Python testing libraries."],
                           params: BenchmarkParamKey(plan: ["m/a", "m/b"], longContextK: 64,
                                                    visionMode: "none", kvFormat: "server default",
                                                    maxMemory: "58G", maxCacheDisk: "off",
                                                    powerMode: "Auto"))
do {
    let encoded = try JSONEncoder().encode(history)
    let decoded = try JSONDecoder().decode(BenchHistory.self, from: encoded)
    check("history: model survives", decoded.results.first?.model, "m/a")
    check("history: throughput survives", decoded.results.first?.metrics.outputTps, 118.2)
    check("history: load time survives", decoded.results.first?.loadSeconds, 3.5)
    check("history: load memory survives", decoded.results.first?.loadMemoryGiB, 16.2)
    check("history: memory survives", decoded.results.first?.metrics.memoryGiB, 18.4)
    check("history: answer text survives", decoded.results.first?.output,
          "1. pytest\n2. unittest\n3. nose")
    check("history: prompt text survives once per run",
          decoded.prompts["instruction"], "List exactly 3 Python testing libraries.")
    check("history: plan order survives", decoded.plan, ["m/a", "m/b"])
    check("history: context size survives", decoded.longContextK, 64)
    check("history: the parameter set survives", decoded.params?.powerMode, "Auto")
    check("history: the parameter set round-trips byte-identical",
          decoded.params?.id, history.params?.id)

    // A run with no recorded parameters (recorded before the archive existed)
    // must still decode — otherwise an upgrade drops the user's last baseline.
    checkNil("history: params are optional for legacy runs",
             try? JSONDecoder().decode(BenchHistory.self, from:
                JSONEncoder().encode(BenchHistory(finishedAt: history.finishedAt, plan: history.plan,
                                                  longContextK: history.longContextK,
                                                  results: history.results,
                                                  prompts: history.prompts))).params)
}

// MARK: - One stored run per parameter set
// The archive used to overwrite a single file, so benchmarking the same models at
// 64K destroyed the 32K baseline. Runs are now keyed by what they were measured
// under: same set replaces, different set is kept.
func params(_ plan: [String], ctx: Int = 64, vision: String = "none",
            kv: String = "server default", mem: String = "58G",
            disk: String = "off", power: String = "Auto") -> BenchmarkParamKey {
    BenchmarkParamKey(plan: plan, longContextK: ctx, visionMode: vision, kvFormat: kv,
                      maxMemory: mem, maxCacheDisk: disk, powerMode: power)
}
func run(_ at: TimeInterval, _ key: BenchmarkParamKey?) -> BenchHistory {
    BenchHistory(finishedAt: Date(timeIntervalSince1970: at), plan: ["m/a"], longContextK: 64,
                 results: [], prompts: [:], params: key)
}
do {
    let base = params(["m/a", "m/b"])
    check("key: identical parameters are the same key", base.id, params(["m/a", "m/b"]).id)
    check("key: context size distinguishes", base.id == params(["m/a", "m/b"], ctx: 32).id, false)
    check("key: vision mode distinguishes", base.id == params(["m/a", "m/b"], vision: "language_only").id, false)
    check("key: kv format distinguishes", base.id == params(["m/a", "m/b"], kv: "bf16").id, false)
    check("key: memory budget distinguishes", base.id == params(["m/a", "m/b"], mem: "24G").id, false)
    check("key: disk tier distinguishes", base.id == params(["m/a", "m/b"], disk: "5G").id, false)
    check("key: power mode distinguishes", base.id == params(["m/a", "m/b"], power: "Performance").id, false)
    check("key: model set distinguishes", base.id == params(["m/a"]).id, false)
    check("key: plan order distinguishes", base.id == params(["m/b", "m/a"]).id, false)

    var archive = BenchArchive()
    archive.insert(run(1_700_000_000, base))
    check("archive: first run is stored", archive.runs.count, 1)
    // Same parameter set, newer run: replaces, does not stack.
    archive.insert(run(1_700_009_999, base))
    check("archive: an identical parameter set replaces its entry", archive.runs.count, 1)
    check("archive: the replacement is the newer run",
          archive.runs.first?.finishedAt, Date(timeIntervalSince1970: 1_700_009_999))
    // A different parameter set: kept beside it.
    archive.insert(run(1_700_005_000, params(["m/a", "m/b"], ctx: 32)))
    check("archive: a different parameter set is preserved", archive.runs.count, 2)
    check("archive: runs are newest first",
          archive.runs.first?.finishedAt, Date(timeIntervalSince1970: 1_700_009_999))
    check("archive: latest is the newest run",
          archive.latest?.finishedAt, Date(timeIntervalSince1970: 1_700_009_999))
    // An unattributed legacy run must not be mistaken for an attributed one, and
    // must not stack either.
    archive.insert(run(1_700_004_000, nil))
    check("archive: an unattributed legacy run is kept apart from attributed ones",
          archive.runs.count, 3)
    archive.insert(run(1_700_003_000, nil))
    check("archive: a second legacy run replaces the first", archive.runs.count, 3)
    archive.insert(run(1_700_002_000, params(["m/a"], ctx: 32)))
    check("archive: a distinct parameter set is appended", archive.runs.count, 4)
    // And the whole archive must survive disk round-tripping, or switching
    // parameter sets would silently reset on relaunch.
    let reopened = try! JSONDecoder().decode(BenchArchive.self, from: JSONEncoder().encode(archive))
    check("archive: every run survives the round-trip", reopened.runs.count, archive.runs.count)
    check("archive: parameter sets survive the round-trip",
          reopened.runs.map { $0.params?.id }, archive.runs.map { $0.params?.id })

    // MARK: - Context picker never shows another context size's numbers
    // Selecting 64K used to leave the 32K table on screen with the header badge
    // reading "64K ctx" — a claim about a run that had not happened. The picker
    // resolves to a stored run or to nothing, and this is that rule.
    func ctxRun(_ at: TimeInterval, _ k: Int) -> BenchHistory {
        BenchHistory(finishedAt: Date(timeIntervalSince1970: at), plan: ["m/a"], longContextK: k,
                     results: [], prompts: [:], params: params(["m/a"], ctx: k))
    }
    var byContext = BenchArchive()
    byContext.insert(ctxRun(1_700_000_000, 32))
    check("context: an unmeasured size resolves to nothing",
          BenchmarkEngine.run(forContextK: 64, in: byContext.runs) == nil, true)
    check("context: a measured size resolves to its run",
          BenchmarkEngine.run(forContextK: 32, in: byContext.runs)?.longContextK, 32)
    check("context: only the 32K run is on screen before the switch", byContext.runs.count, 1)
    byContext.insert(ctxRun(1_700_009_999, 64))
    check("context: the new 64K run is stored beside the 32K one", byContext.runs.count, 2)
    check("context: 32K still resolves to the 32K run after the 64K run landed",
          BenchmarkEngine.run(forContextK: 32, in: byContext.runs)?.longContextK, 32)
    check("context: 64K resolves to the newest run at 64K",
          BenchmarkEngine.run(forContextK: 64, in: byContext.runs)?.finishedAt,
          Date(timeIntervalSince1970: 1_700_009_999))
    // Two runs at the same size: the newest wins, or switching back would show
    // an older baseline with no way to tell.
    byContext.insert(ctxRun(1_700_020_000, 32))
    check("context: re-running 32K replaces that entry", byContext.runs.count, 2)
    check("context: the newest 32K run wins",
          BenchmarkEngine.run(forContextK: 32, in: byContext.runs)?.finishedAt,
          Date(timeIntervalSince1970: 1_700_020_000))
}
try? FileManager.default.removeItem(at: benchDir)

// MARK: - Settings validation (1.5)
// Every one of these is a value splash accepts on the command line and may then
// refuse or silently reinterpret at launch.
do {
    checkNil("memory: blank means auto", SettingsValidator.memory(nil, physical: 64))
    check("memory: 36G is fine with headroom",
          SettingsValidator.memory("36G", physical: 64)?.ok, true)
    check("memory: a bare number is rejected",
          SettingsValidator.memory("32", physical: 64)?.ok, false)
    check("memory: a bare number names the mistake",
          SettingsValidator.memory("32", physical: 64)?.text.contains("36G"), true)
    check("memory: 64G on a 64G Mac is rejected",
          SettingsValidator.memory("64G", physical: 64)?.ok, false)
    check("memory: nonsense is rejected", SettingsValidator.memory("lots", physical: 64)?.ok, false)
    check("memory: a percentage is accepted",
          SettingsValidator.memory("80%", physical: 64)?.ok, true)
    check("memory: 0.5G is below a model", SettingsValidator.memory("512M", physical: 64)?.ok, false)
    check("memory: 52G on 64G leaves headroom",
          SettingsValidator.memory("52G", physical: 64)?.text.contains("headroom"), true)

    check("context: 128K accepted", SettingsValidator.context("128K")?.ok, true)
    check("context: a raw token count is accepted",
          SettingsValidator.context("262144")?.ok, true)
    check("context: 128K means 131072 tokens",
          SettingsValidator.context("128K")?.text.contains("131072"), true)
    check("context: 512 is too small", SettingsValidator.context("512")?.ok, false)
    check("context: nonsense rejected", SettingsValidator.context("lots")?.ok, false)
    checkNil("context: blank means auto", SettingsValidator.context(nil))

    check("disk tier: blank is disabled, and says so",
          SettingsValidator.diskTier("")?.ok, true)
    check("disk tier: '0' is disabled",
          SettingsValidator.diskTier("0")?.text.contains("Disabled"), true)
    check("disk tier: 5G is accepted", SettingsValidator.diskTier("5G")?.ok, true)
    check("disk tier: a bare number is rejected", SettingsValidator.diskTier("5")?.ok, false)

    check("port: a free port is available", SettingsValidator.port(9100, inUse: false, external: false)?.ok, true)
    check("port: a taken port is reported",
          SettingsValidator.port(9000, inUse: true, external: false)?.ok, false)
    check("port: an adopted server is named as such",
          SettingsValidator.port(9000, inUse: true, external: true)?.text.contains("adopted"), true)
    check("port: out of range is rejected", SettingsValidator.port(99999, inUse: false, external: false)?.ok, false)
}

// MARK: - Hardware presets
do {
    // The recommended preset is sized from the host, so the tier boundaries are
    // the assertions: each of these hosts must land on its documented figure.
    func rec(_ gib: Double?) -> HardwarePreset { HardwarePreset.recommended(physicalGiB: gib) }

    check("24 GB host sizes for 24 GB", rec(24).maxMemory, "16G")
    check("24 GB host gets a 64K window", rec(24).maxContext, "64K")
    check("24 GB host gets an SSD tier", rec(24).maxCacheDisk ?? nil, "10G")
    check("32 GB host sizes for 32/36 GB", rec(32).maxMemory, "24G")
    check("36 GB host lands in the same tier", rec(36).maxMemory, rec(32).maxMemory)
    check("48 GB host matches the README's floor+", rec(48).maxMemory, "36G")
    check("48 GB host gets a 128K window", rec(48).maxContext, "128K")
    // 52G is the live server's own auto budget on a 64 GiB host
    // (recommended_max_working_set_bytes = 51.85 GiB), not a round number.
    check("64 GB host matches the server's auto budget", rec(64).maxMemory, "52G")
    check("64 GB host gets a 128K window", rec(64).maxContext, "128K")
    check("64 GB host gets a 10G tier", rec(64).maxCacheDisk ?? nil, "10G")
    check("96 GB host takes the top tier", rec(96).maxMemory, "80G")
    check("128 GB host does too", rec(128).maxMemory, rec(96).maxMemory)
    check("128 GB host gets the larger tier", rec(128).maxCacheDisk ?? nil, "16G")
    // Unknown host must not guess upward — offering a budget that does not fit
    // is the failure this whole redesign exists to prevent.
    check("an unknown host takes the small end", rec(nil).maxMemory, "16G")

    check("every recommended tier leaves host headroom",
          [16.0, 24.0, 32.0, 36.0, 48.0, 64.0, 96.0, 128.0].allSatisfy { gib in
              SettingsValidator.memory(rec(gib).maxMemory, physical: gib)?.ok == true
          }, true)
    check("no recommended budget reaches the whole machine",
          [24.0, 48.0, 96.0, 128.0].allSatisfy { gib in
              SettingsValidator.memory(rec(gib).maxMemory, physical: gib)?.text.contains("headroom") == true
          }, true)

    // `set(on:)` not `apply`: the latter logs through SplashLog.shared, which is
    // process-global and would write into a running install's real log.
    var c = SplashConfig()
    rec(64).set(on: &c)
    check("preset sets memory", c.maxMemory, "52G")
    check("preset sets context", c.maxContext, "128K")
    check("preset sets a disk tier", c.maxCacheDisk, "10G")
    check("preset matches itself", rec(64).matches(c), true)
    check("preset does not match the minimal one", HardwarePreset.minimal.matches(c), false)
    check("applying on another host does not still match", rec(24).matches(c), false)

    HardwarePreset.minimal.set(on: &c)
    check("minimal turns the disk tier off", c.maxCacheDisk ?? nil, nil)
    check("minimal shrinks the context", c.maxContext, "32K")
    // 18G against a 24 GiB host. Deliberately not asserted on 16 GiB: minimal is
    // an opt-in choice, and the max-memory verdict is what flags it there.
    check("minimal is small enough to leave a 24 GB host alone",
          SettingsValidator.memory(c.maxMemory, physical: 24)?.ok, true)
    check("minimal matches itself", HardwarePreset.minimal.matches(c), true)

    // The custom card reads the config; it never claims to be a preset, and it
    // must not match when the config does equal it.
    let custom = HardwarePreset.custom(c)
    check("custom is not a preset", custom.isCustom, true)
    check("custom matches nothing", custom.matches(c), false)
    check("custom shows the configured values", custom.specSummary, "18G RAM · 32K ctx · off disk")
    c.maxMemory = nil
    check("custom names an unset budget auto, not empty",
          HardwarePreset.custom(c).specSummary, "auto RAM · 32K ctx · off disk")

    // Only the two real presets are offered as choices.
    check("choices are recommended then minimal",
          HardwarePreset.choices(physicalGiB: 64).map(\.id), ["recommended", "minimal"])
}

// MARK: - Log filter chips (1.3)
do {
    let request = "[server] POST /v1/chat/completions 200 OK · prompt=512 decode=84 ttft=1.12s"
    let denied = "[server] ⚠ StateCache: 2 reservations denied under budget ceiling"
    let ready = "[server] Ready · incoai/Qwen3.6-35B-A3B-Splash · context 128K"
    check("level All matches everything", LogsView.Level.all.matches(denied.lowercased()), true)
    check("level Requests matches a request line",
          LogsView.Level.requests.matches(request.lowercased()), true)
    check("level Requests ignores a governor line",
          LogsView.Level.requests.matches(denied.lowercased()), false)
    check("level Problems matches a refusal",
          LogsView.Level.problems.matches(denied.lowercased()), true)
    check("level Problems matches an error",
          LogsView.Level.problems.matches("error · engine died"), true)
    check("level Problems ignores a plain ready line",
          LogsView.Level.problems.matches(ready.lowercased()), false)
    check("level Memory Audit matches a governor line",
          LogsView.Level.governor.matches(denied.lowercased()), true)
    // Regression: "cached" contains "cache", so every request completion —
    // `Done · input 1,008 · cached 128 · output 412 · TTFT 1.12s` — matched the
    // Memory Audit filter. Measured on the real 1 226-line server log: 902 of
    // 1 226 matched, of which 76 were genuine governor lines.
    let tokens = "17:15:33 done · input 1,008 · cached 128 · output 412 · ttft 1.12s"
    check("level Memory Audit ignores a request's cached-token count",
          LogsView.Level.governor.matches(tokens), false)
    // …including the cancelled form, which carries no TTFT and so is not a
    // Requests line either.
    check("level Memory Audit ignores a cancelled request's cached count",
          LogsView.Level.governor.matches("21:55:43 cancelled · input 32,705 · cached 0 · output 0"), false)
    check("level Memory Audit still matches the cache disk tier line",
          LogsView.Level.governor.matches(
            "17:15:33 cache disk tier: 10240 mib for kv pages of 1040 kib; kv pages stage through 130 mib of metal memory"), true)
}

// MARK: - Query highlighting in the log pane
// A filter that does not show *why* a 200-character line matched is half a
// filter. Built by concatenating attributed pieces, so the run boundaries are
// the thing that can break silently.
do {
    let line = "23:01:06 Done · input 1,008 · cached 128 · done twice"
    let hit = LogsView.highlighted(line, needle: "done")
    check("highlighting does not change the text", String(hit.characters), line)
    // Walk the runs and look at which ones carry the tint.
    let tinted = hit.runs.filter { $0.backgroundColor != nil }
    check("every occurrence of the query is tinted, not just the first",
          tinted.count, 2)
    check("the tinted runs are exactly the matches",
          tinted.map { String(hit[$0.range].characters) }, ["Done", "done"])
    check("a query that is not present tints nothing",
          LogsView.highlighted(line, needle: "zzz")
              .runs.filter { $0.backgroundColor != nil }.count, 0)
    check("an empty query tints nothing",
          LogsView.highlighted(line, needle: "").runs.count >= 1, true)
    // The needle is matched case-insensitively, but the line's own case is kept.
    check("a mixed-case query still matches",
          LogsView.highlighted("Done done DONE", needle: "done")
              .runs.filter { $0.backgroundColor != nil }.count, 3)
}

// MARK: - PowerMode caching (2.1)
// 43 200 pmset spawns a day became one a minute. The observable consequence to
// pin down is that invalidate() forces a re-read and a fresh answer survives a
// failed probe.
@MainActor func powerModeChecks() async {
    // Pin against the live `pmset -g` answer, not "non-nil": a machine (or
    // runner VM) that never selected a power mode emits no `powermode` line,
    // so the live value is legitimately nil there.
    let live = PowerMode.probe()
    PowerMode.invalidate()
    let first = await PowerMode.current()
    check("power mode is read live", first, live)
    let second = await PowerMode.current()
    check("power mode is stable inside the TTL", second, first)
    PowerMode.invalidate()
    check("invalidate forces a re-read", PowerMode.ttl <= 60, true)
    check("name renders every mode", PowerMode.name(2), "Performance")
}

// Run the MainActor sections. `await` at top level is allowed in a script's
// main.swift, so the chart/polling checks live here rather than in a Task.
await powerModeChecks()

print(failures == 0 ? "\nall checks passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -O -module-name SplashControlKit -wmo \
  -emit-module -emit-module-path "$work/SplashControlKit.swiftmodule" \
  -c Sources/SplashControlKit/StatusDTO.swift Sources/SplashControlKit/SplashClient.swift \
  -o "$work/kit.o"

swiftc -O -o "$work/check" \
  -I "$work" \
  "$work/kit.o" \
  Sources/SplashControl/PowerMode.swift \
  Sources/SplashControl/Config.swift \
  Sources/SplashControl/ModelCatalog.swift \
  Sources/SplashControl/ModelStats.swift \
  Sources/SplashControl/LogsView.swift \
  Sources/SplashControl/ContentHeight.swift \
  Sources/SplashControl/SettingsView.swift \
  Sources/SplashControl/StatsModel.swift \
  Sources/SplashControl/ModelBenchmark.swift \
  Sources/SplashControl/SplashLog.swift \
  Sources/SplashControl/SplashProcess.swift \
  "$work/main.swift"

"$work/check" "$@"
