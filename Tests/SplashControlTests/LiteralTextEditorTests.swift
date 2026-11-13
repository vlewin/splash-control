import AppKit
import Testing

@testable import SplashControl

// Extra Serve Args must reach the config exactly as typed. SwiftUI's
// `TextEditor` applied the user's macOS substitutions (`--probe` → `—probe`),
// which corrupts every flag typed fresh.

@Test("the args text view keeps every typography substitution off")
@MainActor
func argsTextViewDisablesSubstitutions() {
  let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
  LiteralTextEditor.configure(view, scale: 1)
  #expect(!view.isAutomaticDashSubstitutionEnabled)
  #expect(!view.isAutomaticQuoteSubstitutionEnabled)
  #expect(!view.isAutomaticTextReplacementEnabled)
  #expect(!view.isAutomaticSpellingCorrectionEnabled)
  #expect(!view.isAutomaticLinkDetectionEnabled)
}

// The keystroke path goes through the input stack and cannot be driven from
// a test; this covers everything that reaches the text storage (paste, bind).
@Test("flags and doubled spaces reach the buffer verbatim")
@MainActor
func argsTextViewKeepsTextVerbatim() {
  let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
  LiteralTextEditor.configure(view, scale: 1)
  view.insertText("--probe  two  spaces", replacementRange: NSRange(location: 0, length: 0))
  #expect(view.string == "--probe  two  spaces")
}
