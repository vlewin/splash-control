import Darwin
import Foundation
import Testing

@testable import SplashControl

// Issue #59: the launch path stopped an external listener with a bare SIGTERM
// and spawned immediately, so the spawn raced the dying process ("already
// serving", exit 1 — or a wrongful adoption of a vanishing server).
// `terminateAndWait(pids:)` is the wait half of the fix, separated from
// listener discovery precisely so these tests need no port and no splash:
// they spawn orphan `/bin/sleep` processes and signal only those.

private struct OrphanSpawnFailed: Error {}

/// Spawns a detached `sleep 30` and returns its pid.
///
/// The `sh -c 'sleep 30 & echo $!'` double-fork is load-bearing: a direct
/// `Process` child stays a zombie in the process table until *we* reap it,
/// and `kill(pid, 0)` keeps succeeding on a zombie — the wait under test
/// would never see it die. Orphaned by the exiting `sh`, the sleep is
/// reparented and reaped by the kernel, so its exit is observable. The
/// `>/dev/null` on the background job is equally load-bearing: without it
/// the sleep inherits the stdout pipe, and `readDataToEndOfFile` below
/// blocks until the sleep exits — i.e. the pid would already be dead here.
private func spawnOrphanSleep() throws -> pid_t {
  let pipe = Pipe()
  let sh = Process()
  sh.executableURL = URL(fileURLWithPath: "/bin/sh")
  sh.arguments = ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"]
  sh.standardOutput = pipe
  sh.standardError = FileHandle.nullDevice
  try sh.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  sh.waitUntilExit()
  let text = String(data: data, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard let pid = pid_t(text), pid > 0 else {
    throw OrphanSpawnFailed()
  }
  return pid
}

@Test("terminateAndWait returns only after every pid is gone")
func terminateAndWaitWaitsForAllPids() async throws {
  let p1 = try spawnOrphanSleep()
  let p2 = try spawnOrphanSleep()
  defer { kill(p1, SIGKILL); kill(p2, SIGKILL) }  // cleanup only if the test failed early
  #expect(kill(p1, 0) == 0, "sleep \(p1) should be alive before the terminate")
  #expect(kill(p2, 0) == 0, "sleep \(p2) should be alive before the terminate")

  await SplashProcess.terminateAndWait(pids: [p1, p2])

  // The return contract: at return, no pid may still exist — ESRCH, not a
  // zombie (these pids are not our children, so the kernel reaps them).
  #expect(kill(p1, 0) == -1 && errno == ESRCH, "pid \(p1) still alive after terminateAndWait")
  #expect(kill(p2, 0) == -1 && errno == ESRCH, "pid \(p2) still alive after terminateAndWait")
}

@Test("terminateAndWait is a no-op for an empty list and for pids already gone")
func terminateAndWaitToleratesNothingToWaitFor() async {
  await SplashProcess.terminateAndWait(pids: [])
  // pid 0 is refused by the guard in `terminate`; a long-dead pid (beyond
  // any plausible live range here) must not stall the wait either.
  await SplashProcess.terminateAndWait(pids: [0, 999_999])
}

/// Spawns an orphaned `sh` that **ignores** SIGTERM and exits on its own
/// after ~0.5 s. A non-waiting `terminateAndWait` therefore cannot observe a
/// dead pid: at return the process is still alive and the test fails,
/// deterministically. The 0.5 s window is far below the 2.5 s grace, so the
/// SIGKILL escalation is never what kills it — this asserts neither
/// escalation speed nor sleep timing luck.
///
/// The `ready` handshake is load-bearing: `trap "" TERM` only shields the
/// shell once `trap` has executed, so a SIGTERM landing while the inner sh
/// still boots kills it with the default disposition (observed: the wait
/// "passed" after 0.109 s because the orphan died to its own early SIGTERM).
/// Returning only after `ready` proves the trap is installed.
private func spawnSigtermIgnoringOrphan(deadline: Double = 0.5) throws -> pid_t {
  let pipe = Pipe()
  let sh = Process()
  sh.executableURL = URL(fileURLWithPath: "/bin/sh")
  // Double-fork: outer sh backgrounds the inner one, prints its pid on
  // stdout and exits; the inner sh installs the trap, reports `ready` on
  // stderr — the same pipe — and then waits out `sleep`. The inner stdout
  // goes to /dev/null so no stray fd holds the pipe (see spawnOrphanSleep).
  sh.arguments = [
    "-c",
    "sh -c 'trap \"\" TERM; echo ready >&2; sleep \(deadline)' >/dev/null & echo $!",
  ]
  sh.standardOutput = pipe
  sh.standardError = pipe
  try sh.run()
  let reader = pipe.fileHandleForReading
  defer { sh.waitUntilExit() }
  guard let pidText = readLine(from: reader), let pid = pid_t(pidText), pid > 0,
    readLine(from: reader) == "ready"
  else {
    throw OrphanSpawnFailed()
  }
  return pid
}

/// One line from the handle, byte-wise (this SDK's `FileHandle` has no
/// `readLine(upTo:)`). Nil on EOF before a newline.
private func readLine(from handle: FileHandle) -> String? {
  var bytes: [UInt8] = []
  while let chunk = try? handle.read(upToCount: 1), let byte = chunk.first {
    if byte == 0x0A {
      return String(decoding: bytes, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    bytes.append(byte)
    if bytes.count > 64 { return nil }  // guard a runaway writer
  }
  return nil
}

@Test("terminateAndWait provably waits: a SIGTERM-immune pid must be gone at return")
func terminateAndWaitCannotReturnEarly() async throws {
  let pid = try spawnSigtermIgnoringOrphan()
  defer { kill(pid, SIGKILL) }  // cleanup only if the test fails early
  #expect(kill(pid, 0) == 0, "orphan \(pid) should be alive before the terminate")

  let began = ContinuousClock.now
  await SplashProcess.terminateAndWait(pids: [pid])
  let waited = began.duration(to: .now)

  // SIGTERM is ignored, so reaching ESRCH here is only possible by *waiting*
  // for the natural exit. A fire-and-forget implementation still sees the pid
  // alive (0.5 s lifespan vs. microseconds to this assertion) and fails.
  #expect(
    kill(pid, 0) == -1 && errno == ESRCH,
    "terminateAndWait returned while SIGTERM-immune pid \(pid) was still alive")
  // The poll loop sleeps in 100 ms steps and the first liveness check ran on
  // a guaranteed-alive pid, so at least one full step must have elapsed.
  let waitedMs =
    waited.components.seconds * 1000 + waited.components.attoseconds / 1_000_000_000_000_000
  #expect(waitedMs >= 100, "terminateAndWait returned in \(waitedMs) ms — it did not poll")
}
