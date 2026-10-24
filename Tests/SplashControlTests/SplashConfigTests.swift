import Foundation
import Testing

@testable import SplashControl

// Regression guard for the 1.0.0 breaking change: the default port follows
// splash's own default (8000, `splash serve --port`'s fallback) so a vanilla
// server and the app agree, while a saved config keeps the port it chose.
// The app is macOS-gated in Package.swift, so this target is too.

@Test("fresh config defaults to splash's port 8000")
func freshConfigDefaultsToSplashPort() {
  #expect(SplashConfig().port == 8000)
}

@Test("saved port survives decode (0.9.0 files keep 9000)")
func savedPortSurvivesDecode() throws {
  let cfg = try JSONDecoder().decode(SplashConfig.self, from: Data(#"{"port":9000}"#.utf8))
  #expect(cfg.port == 9000)
}

@Test("missing port key falls back to the default")
func missingPortFallsBackToDefault() throws {
  let cfg = try JSONDecoder().decode(SplashConfig.self, from: Data("{}".utf8))
  #expect(cfg.port == 8000)
}

// Issue #8: the context window picker. The row set, the 64 GiB gate on the
// 256K cap, and the hardware-aware fresh default — a small Mac must not be
// handed a window its own preset card says it cannot afford.

@Test("picker rows are 32K/64K/128K on hosts below the 256K gate")
func contextRowsBelowGate() {
  #expect(SplashConfig.contextChoices(physicalGiB: 24) == ["32K", "64K", "128K"])
  #expect(SplashConfig.contextChoices(physicalGiB: 48) == ["32K", "64K", "128K"])
}

@Test("the 256K cap row is offered only to 64 GiB hosts and up")
func contextRowGate() {
  #expect(SplashConfig.contextChoices(physicalGiB: 63.9) == ["32K", "64K", "128K"])
  #expect(SplashConfig.contextChoices(physicalGiB: 64) == ["32K", "64K", "128K", "256K", "512K", "1M"])
  #expect(SplashConfig.contextChoices(physicalGiB: 128) == ["32K", "64K", "128K", "256K", "512K", "1M"])
}

@Test("fresh default follows the recommended preset tier")
func freshDefaultFollowsPresetTier() {
  #expect(SplashConfig.defaultMaxContext(physicalGiB: 24) == "64K")
  #expect(SplashConfig.defaultMaxContext(physicalGiB: 40) == "64K")
  #expect(SplashConfig.defaultMaxContext(physicalGiB: 52) == "128K")
  #expect(SplashConfig.defaultMaxContext(physicalGiB: 96) == "128K")
  #expect(SplashConfig.defaultMaxContext(physicalGiB: nil) == "64K")
}

@Test("saved context window survives decode")
func savedContextSurvivesDecode() throws {
  let cfg = try JSONDecoder().decode(SplashConfig.self, from: Data(#"{"maxContext":"64K"}"#.utf8))
  #expect(cfg.maxContext == "64K")
}

@Test("missing context key falls back to the host's tier")
func missingContextFallsBackToHostTier() throws {
  let cfg = try JSONDecoder().decode(SplashConfig.self, from: Data("{}".utf8))
  #expect(cfg.maxContext == SplashConfig.defaultMaxContext(physicalGiB: HostMemory.physicalGiB))
}

@Test("saved stateFormat survives decode")
func savedStateFormatSurvivesDecode() throws {
  let cfg = try JSONDecoder().decode(SplashConfig.self, from: Data(#"{"stateFormat":"bf16"}"#.utf8))
  #expect(cfg.stateFormat == "bf16")
}

@Test("buildLaunchArgs passes --state-format when supported and config sets it")
func buildLaunchArgsStateFormat() {
  var cfg = SplashConfig()
  cfg.stateFormat = "bf16"
  let supports: Set<String> = ["--state-format"]
  let args = SplashProcess.buildLaunchArgs(cfg, supports: supports)
  #expect(args.contains("--state-format"))
  #expect(args.contains("bf16"))

  // When flag is not supported by probed binary, it is dropped
  let argsUnsupported = SplashProcess.buildLaunchArgs(cfg, supports: [])
  #expect(!argsUnsupported.contains("--state-format"))
}

@Test("buildLaunchArgs passes --max-cache-disk for auto, explicit size, and 0")
func buildLaunchArgsMaxCacheDisk() {
  var cfg = SplashConfig()
  cfg.maxCacheDisk = "auto"
  #expect(SplashProcess.buildLaunchArgs(cfg).contains("auto"))

  cfg.maxCacheDisk = "16G"
  #expect(SplashProcess.buildLaunchArgs(cfg).contains("16G"))

  cfg.maxCacheDisk = "0"
  #expect(SplashProcess.buildLaunchArgs(cfg).contains("0"))

  cfg.maxCacheDisk = ""
  #expect(!SplashProcess.buildLaunchArgs(cfg).contains("--max-cache-disk"))
}

// splash 1.4.0: streaming stores (--expert-memory, --ple-memory,
// --sparse-kv-memory), draft verification, and the 1M context ceiling.
@Test("store sizes that splash accepts pass the launcher's sanitizer")
func storeSizesThatSplashAccepts() {
  #expect(SplashProcess.sanitizedStoreSize("16G", allowOff: true) == "16G")
  #expect(SplashProcess.sanitizedStoreSize("2.5G", allowOff: true) == "2.5G")
  #expect(SplashProcess.sanitizedStoreSize("1200M", allowOff: false) == "1200M")
  #expect(SplashProcess.sanitizedStoreSize("512K", allowOff: false) == "512K")
  #expect(SplashProcess.sanitizedStoreSize("off", allowOff: true) == "off")
  #expect(SplashProcess.sanitizedStoreSize("auto", allowOff: true) == nil)
}

@Test("store sizes splash would reject are dropped, not forwarded")
func storeSizesThatSplashRejects() {
  // Each of these is an argparse exit 2: a dead server, not a warning.
  #expect(SplashProcess.sanitizedStoreSize("16Gx", allowOff: true) == nil)
  #expect(SplashProcess.sanitizedStoreSize(".5G", allowOff: true) == nil)
  #expect(SplashProcess.sanitizedStoreSize("0", allowOff: true) == nil)
  #expect(SplashProcess.sanitizedStoreSize("16 G", allowOff: true) == nil)
  #expect(SplashProcess.sanitizedStoreSize("off", allowOff: false) == nil)
}

@Test("the 1.4.0 flags are gated on the probed binary like every other one")
func streamingFlagsGate() {
  var cfg = SplashConfig()
  cfg.expertMemory = "16G"
  cfg.verifyRows = "all"
  let supports: Set<String> = ["--expert-memory", "--verify-rows"]
  let args = SplashProcess.buildLaunchArgs(cfg, supports: supports)
  #expect(args.contains("--expert-memory"))
  #expect(args.contains("16G"))
  #expect(args.contains("--verify-rows"))
  #expect(!SplashProcess.buildLaunchArgs(cfg, supports: []).contains("--expert-memory"))
  cfg.verifyRows = "turbo"
  #expect(!SplashProcess.buildLaunchArgs(cfg, supports: supports).contains("--verify-rows"))
}

@Test("the context validator reads M as a million, not a mebibyte")
func contextCeiling() {
  #expect(SettingsValidator.context("1M")?.text == "Window: 1000000 tokens")
  #expect(SettingsValidator.context("1.1M")?.ok == false)
  #expect(SettingsValidator.context("512K")?.ok == true)
}

@Test("a fresh install takes the recommended preset's memory and disk tier")
func freshMemoryAndDiskFollowPreset() {
  let rec = HardwarePreset.recommended(physicalGiB: HostMemory.physicalGiB)
  #expect(SplashConfig().maxMemory == rec.maxMemory)
  #expect(SplashConfig().maxCacheDisk == rec.maxCacheDisk)
}

@Test("a saved auto disk tier (absent key) stays auto on decode")
func savedAutoDiskTierSurvivesDecode() throws {
  let cfg = try JSONDecoder().decode(SplashConfig.self, from: Data("{}".utf8))
  #expect(cfg.maxCacheDisk == nil)
}
