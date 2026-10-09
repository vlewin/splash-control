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
  #expect(SplashConfig.contextChoices(physicalGiB: 64) == ["32K", "64K", "128K", "256K"])
  #expect(SplashConfig.contextChoices(physicalGiB: 128) == ["32K", "64K", "128K", "256K"])
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
