import Foundation
import SplashControlKit
import Testing

// Decode guards for the schema-mirror DTOs. Every field is optional by
// contract, so a renamed or misspelled CodingKeys entry decodes to nil in
// silence — these pin the wire contract the way check_core.sh does.
//
// `swift test` needs a Swift 6.x toolchain that ships the Testing module
// (`brew install swift`); Apple's Command Line Tools do not.

private func fixture(_ name: String) throws -> Data {
  let path = "Tests/Fixtures/\(name)"
  guard let data = FileManager.default.contents(atPath: path) else {
    throw MissingFixture(path: path)
  }
  return data
}

private struct MissingFixture: Error { let path: String }

@Test("status fixture decodes the full schema")
func statusFixtureDecodes() throws {
  let s = try JSONDecoder().decode(StatusDTO.self, from: try fixture("status_schema6.json"))
  #expect(s.ready == true)
  #expect(s.maximumContextTokens == 131072)
  #expect(s.memoryPressure == "normal")
  // 1.2.x regression baseline: keys added after this capture must decode nil.
  #expect(s.weights == nil)
  #expect(s.aneFfn == nil)
  // The admission marks predate 1.3.0 (on the wire since 1.2.0).
  #expect(s.admission?.heldBehindRefusal != nil)
  #expect(s.admission?.restoring != nil)
}

@Test("1.3.0 fixture decodes the ane_ffn and admission additions")
func status130FixtureDecodes() throws {
  let s = try JSONDecoder().decode(StatusDTO.self, from: try fixture("status_schema6_1_3_0.json"))
  #expect(s.ready == true)
  // Shape pins, not values: a recapture on another machine may differ.
  #expect(s.weights != nil)
  #expect(s.aneFfn?.state != nil)
  #expect(s.aneFfn?.share != nil)
  #expect(s.aneFfn?.minimumRows != nil)
  #expect(s.aneFfn?.reason != nil)
  #expect(s.aneFfn?.splitCommands != nil)
  #expect(s.aneFfn?.reruns != nil)
  #expect(s.aneFfn?.aneMs != nil)
  #expect(s.aneFfn?.evaluations != nil)
  #expect(s.admission?.heldBehindRefusal != nil)
  #expect(s.admission?.restoring != nil)
}

@Test("1.3.1 fixture decodes thermal_state, restore_failures, and idle_context_windows")
func status131FixtureDecodes() throws {
  let s = try JSONDecoder().decode(StatusDTO.self, from: try fixture("status_schema6_1_3_1.json"))
  #expect(s.ready == true)
  #expect(s.thermalState == "fair")
  #expect(s.weights?.restoreFailures == 1)
  #expect(s.state?.idleContextWindows == 3)
}

@Test("1.3.2 fixture decodes active_requests, weights.restoring, state_format, and disk/cache additions")
func status132FixtureDecodes() throws {
  let s = try JSONDecoder().decode(StatusDTO.self, from: try fixture("status_schema6_1_3_2.json"))
  #expect(s.ready == true)
  #expect(s.weights?.restoring == true)
  #expect(s.memoryPlan?.model?.stateFormat == "bf16")
  #expect(s.memoryGovernor?.hostSpareBytes == 1073741824)
  #expect(s.memoryGovernor?.hostSpareReserveBytes == 536870912)
  #expect(s.disk?.limitBytes == 34359738368)
  #expect(s.disk?.volumeAvailableBytes == 197568491520)
  #expect(s.disk?.writesGated == "no")
  #expect(s.cache?.deduplicatedKvTokens == 1024)
  #expect(s.activeRequests?.count == 1)
  let req = try #require(s.activeRequests?.first)
  #expect(req.id == 101)
  #expect(req.phase == "prefill")
  #expect(req.promptTokens == 16384)
  #expect(req.promptProcessed == 4096)
  #expect(req.generatedTokens == 0)
  #expect(req.maxNewTokens == 1024)
  #expect(req.ageMs == 1250.0)
}

@Test("renamed key decodes to nil, not garbage")
func renamedKeyDecodesToNil() throws {
  let json = #"{"ready":true,"max_context_tokens":99999}"#
  let s = try JSONDecoder().decode(StatusDTO.self, from: Data(json.utf8))
  #expect(s.ready == true)
  #expect(s.maximumContextTokens == nil)
}

@Test("completion fixture decodes usage, timings and finish")
func completionFixtureDecodes() throws {
  let reply = try JSONDecoder().decode(
    SplashClient.Completion.self, from: try fixture("bench_reply.json"))
  #expect((reply.usage?.promptTokens ?? 0) > 0)
  #expect(reply.choices?.first?.finishReason == "stop")
  #expect(reply.error?.message == nil)
}

@Test("memory release reply decodes correctly")
func memoryReleaseReplyDecodes() throws {
  let json = #"{"released":true,"weights":{"idle_release_seconds":1800,"released":true,"restoring":false,"restores":1,"restore_failures":0}}"#
  let res = try JSONDecoder().decode(SplashClient.MemoryReleaseResult.self, from: Data(json.utf8))
  #expect(res.released == true)
  #expect(res.weights?.released == true)
  #expect(res.weights?.idleReleaseSeconds == 1800)
}
