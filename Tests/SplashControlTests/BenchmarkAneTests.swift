import Foundation
import SplashControlKit
import Testing

@testable import SplashControl

// The bench's ANE extension: the provision decision (picker intent vs the
// saved value — only a real difference may touch the config, and only then
// may the restore re-spawn) and the stamp format a run carries per model.

@Test("ane provision: selection matches the config -> nothing changes")
func aneProvisionNoOp() {
  #expect(BenchmarkEngine.aneProvision(selectedOn: true, configuredDisableAne: false) == nil)
  #expect(BenchmarkEngine.aneProvision(selectedOn: false, configuredDisableAne: true) == nil)
}

@Test("ane provision: selection differs -> the value the run must use")
func aneProvisionChanges() {
  #expect(BenchmarkEngine.aneProvision(selectedOn: false, configuredDisableAne: false) == true)
  #expect(BenchmarkEngine.aneProvision(selectedOn: true, configuredDisableAne: true) == false)
}

@Test("ane summary: one word when the models agree, mixed when they do not")
func aneSummaryDerives() {
  func history(_ states: [String: String]?) -> BenchHistory {
    BenchHistory(
      finishedAt: Date(), plan: ["a"], longContextK: 32,
      results: [], prompts: [:], params: nil, aneStates: states)
  }
  #expect(history(["m1": "off", "m2": "off"]).aneSummary == "off")
  #expect(history(["m1": "split 41%", "m2": "split 55%"]).aneSummary == "split")
  #expect(history(["m1": "split 41%", "m2": "off"]).aneSummary == "mixed")
  #expect(history(nil).aneSummary == nil)
  #expect(history([:]).aneSummary == nil)
}

@Test("ane label: the stamp is the engine's verdict, share attached while splitting")
func aneLabelFormats() throws {
  func decode(_ json: String) throws -> StatusDTO.AneFfn {
    try JSONDecoder().decode(StatusDTO.AneFfn.self, from: Data(json.utf8))
  }
  #expect(try BenchmarkEngine.aneLabel(decode(#"{"state":"split","share":0.4117}"#)) == "split 41%")
  #expect(try BenchmarkEngine.aneLabel(decode(#"{"state":"off","share":0}"#)) == "off")
  #expect(try BenchmarkEngine.aneLabel(decode(#"{"state":"stopped"}"#)) == "stopped")
  #expect(try BenchmarkEngine.aneLabel(decode("{}")) == "unreported")
}
