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
