import Foundation
import Testing

@testable import SplashControl

// Issue #59: `stopExternal()` SIGTERMs and returns immediately, so the launch
// path could spawn `splash serve` into a port the dying server still owned —
// splash refused with "already serving (PID …)", the child exited 1, and no
// server was left running. The launch path now awaits `stopExternalAndWait()`,
// whose contract this test pins: the listener is gone when it returns.

@Test("stopExternalAndWait leaves the port free when it returns")
@MainActor
func stopExternalWait() async throws {
  let port = try freePort()
  var cfg = SplashConfig()
  cfg.port = port
  let process = SplashProcess(config: cfg)

  // A listener that takes its time dying, so the difference is visible: a
  // fire-and-forget SIGTERM returns while this still holds the port, which is
  // exactly what used to make the app's own `serve` fail with
  // "already serving". A plain `nc` exits too fast to catch the regression.
  let listener = Process()
  listener.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  listener.arguments = [
    "-c",
    """
    import signal, socket, sys, time
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", \(port)))
    s.listen(1)
    signal.signal(signal.SIGTERM, lambda *a: (time.sleep(0.8), sys.exit(0)))
    time.sleep(30)
    """,
  ]
  try listener.run()
  defer { if listener.isRunning { kill(listener.processIdentifier, SIGKILL) } }

  try await waitUntilListening(port: port)
  #expect(isListening(port))

  let started = Date()
  await process.stopExternalAndWait()
  let elapsed = Date().timeIntervalSince(started)

  #expect(!isListening(port), "listener survived stopExternalAndWait")
  #expect(process.state == .stopped)
  #expect(elapsed < 4, "waited \(elapsed)s; the SIGTERM grace is bounded at 2.5s")
}

// MARK: - helpers

/// A port nothing is bound to: ask the kernel for an ephemeral one, then
/// release it.
private func freePort() throws -> Int {
  struct FreePort: Error {}
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  defer { close(fd) }
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  addr.sin_port = 0
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
  }
  guard bound == 0 else { throw FreePort() }
  let named = withUnsafeMutablePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
  }
  guard named == 0 else { throw FreePort() }
  return Int(UInt16(bigEndian: addr.sin_port))
}

private func isListening(_ port: Int) -> Bool {
  let lsof = Process()
  lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
  lsof.arguments = ["-nP", "-i", ":\(port)", "-t", "-sTCP:LISTEN"]
  let out = Pipe()
  lsof.standardOutput = out
  lsof.standardError = FileHandle.nullDevice
  try? lsof.run()
  lsof.waitUntilExit()
  let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func waitUntilListening(port: Int) async throws {
  for _ in 0..<30 {
    if isListening(port) { return }
    try await Task.sleep(for: .milliseconds(100))
  }
  Issue.record("no listener appeared on port \(port)")
}
