import Foundation
import SplashControlKit
import Testing

@testable import SplashControl

@Test("compaction detection: cliff drop with request completed returns label with duration")
func compactionDropWithPrefillWallMs() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 2048, previousBlockTokens: 32, // 65,536 tokens
    currentPages: 1200, currentBlockTokens: 32,  // 38,400 tokens (-27.1K, 41% drop)
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false,
    prefillDeltaMs: 420.0, elapsedSec: 1.2
  )
  #expect(label == "Compact: 420ms (-27K)")
}

@Test("compaction detection: cliff drop with elapsed time when prefillWallMs absent")
func compactionDropWithElapsedFallback() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 2048, previousBlockTokens: 32,
    currentPages: 1000, currentBlockTokens: 32, // -33.5K (51% drop)
    previousRequestsCompleted: 5, currentRequestsCompleted: 6,
    previousRestarts: 1, currentRestarts: 1,
    weightsReleased: false, statusStale: false,
    prefillDeltaMs: nil, elapsedSec: 1.4
  )
  #expect(label == "Compact: 1.4s (-34K)")
}

@Test("compaction detection: small turn variations are ignored")
func compactionDropIgnoresSmallDrops() {
  // 5% drop, 2K tokens: normal variation between turns
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 1000, previousBlockTokens: 32,
    currentPages: 950, currentBlockTokens: 32,
    previousRequestsCompleted: 1, currentRequestsCompleted: 2,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false,
    prefillDeltaMs: 200, elapsedSec: 1.0
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when requests completed did not advance")
func compactionDropRejectsWhenNoRequestCompleted() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 2048, previousBlockTokens: 32,
    currentPages: 1000, currentBlockTokens: 32,
    previousRequestsCompleted: 5, currentRequestsCompleted: 5, // unchanged
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: false,
    prefillDeltaMs: 400, elapsedSec: 1.0
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects on server restart")
func compactionDropRejectsOnRestart() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 2048, previousBlockTokens: 32,
    currentPages: 100, currentBlockTokens: 32,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 1, // server restarted
    weightsReleased: false, statusStale: false,
    prefillDeltaMs: 100, elapsedSec: 1.0
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when current pages is zero (idle between requests)")
func compactionDropRejectsWhenCurrentPagesIsZero() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 2048, previousBlockTokens: 32,
    currentPages: 0, currentBlockTokens: 32, // idle between requests
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false,
    statusStale: false,
    prefillDeltaMs: nil, elapsedSec: 1.0
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when idle release paged out weights")
func compactionDropRejectsOnIdleRelease() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 2048, previousBlockTokens: 32,
    currentPages: 1000, currentBlockTokens: 32,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: true, // idle release
    statusStale: false,
    prefillDeltaMs: nil, elapsedSec: 30.0
  )
  #expect(label == nil)
}

@Test("compaction detection: rejects when snapshot is stale")
func compactionDropRejectsOnStaleSnapshot() {
  let label = StatsModel.evaluateCompactionDrop(
    previousPages: 2048, previousBlockTokens: 32,
    currentPages: 1000, currentBlockTokens: 32,
    previousRequestsCompleted: 10, currentRequestsCompleted: 11,
    previousRestarts: 0, currentRestarts: 0,
    weightsReleased: false, statusStale: true, // stale
    prefillDeltaMs: 400, elapsedSec: 2.0
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

