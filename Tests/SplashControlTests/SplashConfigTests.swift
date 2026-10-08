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
