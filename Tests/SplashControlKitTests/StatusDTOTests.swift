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
