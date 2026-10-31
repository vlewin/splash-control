import Foundation
import SplashControlKit
import Testing

@testable import SplashControl

@Test("compaction detection: cliff drop from ceiling to baseline returns drop label")
func compactionDropDetectedAtCeiling() {
  // 256K cap model (262,144 tokens): dropped from 210K (~80% of cap) down to 15K (~6% of cap)
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 6562, previousBlockTokens: 32, // 209,984 tokens (~80% cap)
    currentPages: 468, currentBlockTokens: 32, // 14,976 tokens (~5.7% cap)
    maxContextTokens: 262_144,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false
  )
  #expect(label == "Compact: -195K")
}

@Test("compaction detection: rejects drops that start below ceiling threshold")
func compactionDropRejectsLowContextPreDrop() {
  // 256K cap: 50K tokens (~19% of cap) is far below the 70% context ceiling gate
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 1562, previousBlockTokens: 32, // ~50K tokens
    currentPages: 468, currentBlockTokens: 32, // ~15K tokens
    maxContextTokens: 262_144,
    previousRequestsCompleted: 5, currentRequestsCompleted: 6,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects drops whose post-drop context remains high")
func compactionDropRejectsHighFloorPostDrop() {
  // 256K cap: drops from 260K to 140K (~53% of cap) — an intermediate turn, not compaction
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 8125, previousBlockTokens: 32, // 260K tokens
    currentPages: 4375, currentBlockTokens: 32, // 140K tokens
    maxContextTokens: 262_144,
    previousRequestsCompleted: 5, currentRequestsCompleted: 6,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false
  )
  #expect(label == nil)
}

@Test("compaction detection: small turn variations are ignored")
func compactionDropIgnoresSmallDrops() {
  // 5% drop, 2K tokens: normal variation between turns
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 1000, previousBlockTokens: 32,
    currentPages: 950, currentBlockTokens: 32,
    maxContextTokens: 262_144,
    previousRequestsCompleted: 1, currentRequestsCompleted: 2,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when requests completed did not advance")
func compactionDropRejectsWhenNoRequestCompleted() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 6562, previousBlockTokens: 32,
    currentPages: 468, currentBlockTokens: 32,
    maxContextTokens: 262_144,
    previousRequestsCompleted: 5, currentRequestsCompleted: 5, // unchanged
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects on server restart")
func compactionDropRejectsOnRestart() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 6562, previousBlockTokens: 32,
    currentPages: 468, currentBlockTokens: 32,
    maxContextTokens: 262_144,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 1, // server restarted
    weightsReleased: false, statusStale: false
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when current pages is zero (idle between requests)")
func compactionDropRejectsWhenCurrentPagesIsZero() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 6562, previousBlockTokens: 32,
    currentPages: 0, currentBlockTokens: 32, // idle between requests
    maxContextTokens: 262_144,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when idle release paged out weights")
func compactionDropRejectsOnIdleRelease() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 6562, previousBlockTokens: 32,
    currentPages: 468, currentBlockTokens: 32,
    maxContextTokens: 262_144,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: true, // idle release
    statusStale: false
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when snapshot is stale")
func compactionDropRejectsOnStaleSnapshot() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 6562, previousBlockTokens: 32,
    currentPages: 468, currentBlockTokens: 32,
    maxContextTokens: 262_144,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: true // stale
  )
  #expect(label == nil)
}

@Test("activePrefillProgress computes token progress and fraction")
func activePrefillProgressComputes() {
  let p = StatsModel.PrefillProgress(processed: 4096, total: 16384)
  #expect(p.fraction == 0.25)
  #expect(p.percentText == "25%")
}

@Test("activePrefillProgress clamps safely")
func activePrefillProgressClamps() {
  let pZero = StatsModel.PrefillProgress(processed: 100, total: 0)
  #expect(pZero.fraction == 0.0)
  #expect(pZero.percentText == "0%")

  let pOver = StatsModel.PrefillProgress(processed: 20000, total: 10000)
  #expect(pOver.fraction == 1.0)
  #expect(pOver.percentText == "100%")
}

@Test("Marker.compactDuration extracts duration from label")
func markerCompactDurationExtracts() {
  let m1 = Marker(date: Date(), label: "Compact: 420ms (-27K)", automatic: true)
  #expect(m1.compactDuration == "420ms")

  let m2 = Marker(date: Date(), label: "Compact: 1.4s (-34K)", automatic: true)
  #expect(m2.compactDuration == "1.4s")

  let m3 = Marker(date: Date(), label: "Compact: -34K", automatic: true)
  #expect(m3.compactDuration == nil)

  let m4 = Marker(date: Date(), label: "Thermal: Serious", automatic: true)
  #expect(m4.compactDuration == nil)

  let m5 = Marker(date: Date(), label: "Power: Low Power", automatic: true)
  #expect(m5.compactDuration == nil)
}

