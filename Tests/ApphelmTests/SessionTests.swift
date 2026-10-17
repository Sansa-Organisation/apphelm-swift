import Foundation
import Testing

@testable import Apphelm

/// A folder of its own per test: sessions are noted next to the crash reports.
private func temporaryFolder() -> URL {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-session-tests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}

/// A stored signal report, as a crashed run leaves it, last written at `written`.
private func storeCrashReport(in folder: URL, written: Date) throws {
  let report = folder.appendingPathComponent("crash-\(UUID().uuidString).log")
  try Data("\(CrashStore.signalPrefix)11 SIGSEGV\n0   Shop   0x0000000100003f00 checkoutTotal + 32\n".utf8).write(to: report)
  try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: report.path)
}

@Suite("Release-health sessions")
struct SessionTests {
  func options(_ recorder: Recorder, release: String? = "ios@2.3.0", environment: String? = "production") -> ApphelmOptions {
    ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: release, environment: environment)
  }

  func sessions(_ recorder: Recorder) -> [[String: Any]] {
    recorder.bodies.filter { $0["eventName"] as? String == "$session" }.map { $0["properties"] as? [String: Any] ?? [:] }
  }

  func exceptions(_ recorder: Recorder) -> [[String: Any]] {
    recorder.bodies.filter { $0["eventName"] as? String == "$exception" }.map { $0["properties"] as? [String: Any] ?? [:] }
  }

  @Test("Without a release no session is started or sent")
  func needsRelease() async throws {
    let recorder = Recorder()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = ApphelmClient(options: options(recorder, release: nil), session: recorder.session(), store: MemoryStore())
    #expect(client.startSession(directory: folder) == nil)
    #expect(client.sessionId == nil)
    #expect(client.endSession() == false)
    await client.flush()
    #expect(recorder.bodies.isEmpty)
    #expect(SessionLedger.load(directory: folder).isEmpty)
  }

  @Test("A session sends the browser's $session once, at its start; ending it sends nothing")
  func startAndEnd() async throws {
    let recorder = Recorder()
    let time = PinnedClock()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let id = try #require(client.startSession(directory: folder, clock: time.clock))
    #expect(id.count >= 8 && id.count <= 64)
    #expect(client.startSession(directory: folder, clock: time.clock) == id)
    #expect(client.sessionId == id)
    await client.flush()
    #expect(recorder.bodies.count == 1)
    #expect(recorder.bodies[0]["workspaceId"] as? String == "org_1" && recorder.bodies[0]["productId"] as? String == "prd_1")
    #expect((recorder.bodies[0]["eventId"] as? String)?.isEmpty == false)
    let start = try #require(sessions(recorder).first)
    #expect(start["session_hash"] as? String == id)
    #expect(start["release"] as? String == "ios@2.3.0")
    #expect(start["environment"] as? String == "production")
    #expect(start["distinct_id"] as? String == "user-1")
    #expect(Set(start.keys) == ["session_hash", "release", "environment", "distinct_id"])

    // Ending is local: no request, then or on the next flush.
    time.advance(ms: 42_500)
    #expect(client.endSession())
    #expect(client.sessionId == nil)
    #expect(client.endSession() == false)
    await client.flush()
    #expect(recorder.bodies.count == 1)

    // The end is noted next to the crash reports, for matching a later crash.
    let stored = SessionLedger.load(directory: folder)
    #expect(stored == [StoredSession(hash: id, release: "ios@2.3.0", environment: "production", startedAt: time.start.timeIntervalSince1970, endedAt: time.start.timeIntervalSince1970 + 42.5)])
    let next = try #require(client.startSession(directory: folder, clock: time.clock))
    #expect(next != id)
    await client.flush()
    #expect(sessions(recorder).count == 2)
  }

  @Test("Errors carry the session they happened in, and none outside one")
  func errorsCarryTheSession() async throws {
    struct CartFailed: Error {}
    let recorder = Recorder()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = ApphelmClient(options: options(recorder, environment: nil), session: recorder.session(), store: MemoryStore())

    let id = try #require(client.startSession(directory: folder))
    try await client.captureException(CartFailed())
    #expect(exceptions(recorder).last?["session_hash"] as? String == id)
    #expect(exceptions(recorder).last?["handled"] == nil)
    try await client.captureException(CartFailed(), handled: false)
    // What the server marks the session crashed by: unhandled, with its session and release.
    #expect(exceptions(recorder).last?["session_hash"] as? String == id)
    #expect(exceptions(recorder).last?["handled"] as? Bool == false)
    #expect(exceptions(recorder).last?["release"] as? String == "ios@2.3.0")

    client.endSession()
    try await client.captureException(CartFailed())
    #expect(exceptions(recorder).last?["session_hash"] == nil)
    await client.flush()
    #expect(sessions(recorder).count == 1)
    #expect(sessions(recorder).first?["environment"] == nil)
  }

  @Test("A crash sent on the next launch names the session, release and environment that crashed")
  func crashKeepsItsSession() async throws {
    let recorder = Recorder()
    let time = PinnedClock()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    // The run that crashes: a session starts, and a minute later a signal report is written.
    let crashing = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let crashed = try #require(crashing.startSession(directory: folder, clock: time.clock))
    try storeCrashReport(in: folder, written: time.start.addingTimeInterval(60))

    // The next launch, an hour later, is a newer build in another environment.
    time.advance(ms: 3_600_000)
    let launch = ApphelmClient(options: options(recorder, release: "ios@2.4.0", environment: "staging"), session: recorder.session(), store: MemoryStore())
    let current = try #require(launch.startSession(directory: folder, clock: time.clock))
    #expect(await launch.sendPendingCrashReports(directory: folder) == 1)
    let crash = try #require(exceptions(recorder).last)
    #expect(crash["name"] as? String == "SIGSEGV")
    #expect(crash["handled"] as? Bool == false)
    #expect(crash["session_hash"] as? String == crashed)
    #expect(crashed != current)
    #expect(crash["release"] as? String == "ios@2.3.0")
    #expect(crash["environment"] as? String == "production")
    #expect(CrashInstaller.pendingReports(directory: folder).isEmpty)

    // This launch's own session is sent under its own release.
    await launch.flush()
    #expect(sessions(recorder).last?["session_hash"] as? String == current)
    #expect(sessions(recorder).last?["release"] as? String == "ios@2.4.0")
  }

  @Test("A crash outside any session carries none, and the launch's own release")
  func crashOutsideSession() async throws {
    let recorder = Recorder()
    let time = PinnedClock()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let earlier = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    earlier.startSession(directory: folder, clock: time.clock)
    time.advance(ms: 30_000)
    earlier.endSession()
    // One crash before the first session ever started, one after that session had ended.
    try storeCrashReport(in: folder, written: time.start.addingTimeInterval(-10))
    try storeCrashReport(in: folder, written: time.start.addingTimeInterval(90))

    let launch = ApphelmClient(options: options(recorder, release: "ios@2.4.0"), session: recorder.session(), store: MemoryStore())
    #expect(await launch.sendPendingCrashReports(directory: folder) == 2)
    #expect(exceptions(recorder).count == 2)
    for crash in exceptions(recorder) {
      #expect(crash["session_hash"] == nil)
      #expect(crash["release"] as? String == "ios@2.4.0")
    }
  }

  @Test("The session note keeps the last ten sessions and picks the one running at a time")
  func ledger() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for index in 0..<12 {
      SessionLedger.record(StoredSession(hash: "s\(index)", release: "ios@1.0.\(index)", environment: nil, startedAt: Double(1_000 + index * 100), endedAt: nil), directory: folder)
    }
    let stored = SessionLedger.load(directory: folder)
    #expect(stored.map(\.hash) == (2..<12).map { "s\($0)" })
    #expect(SessionLedger.session(at: Date(timeIntervalSince1970: 1_250), in: stored)?.hash == "s2")
    #expect(SessionLedger.session(at: Date(timeIntervalSince1970: 1_300), in: stored)?.hash == "s3")
    #expect(SessionLedger.session(at: Date(timeIntervalSince1970: 1_199), in: stored) == nil)
    #expect(SessionLedger.session(at: Date(timeIntervalSince1970: 9_999), in: stored)?.hash == "s11")
    SessionLedger.end(hash: "s11", at: Date(timeIntervalSince1970: 2_150), directory: folder)
    let ended = SessionLedger.load(directory: folder)
    #expect(SessionLedger.session(at: Date(timeIntervalSince1970: 2_150), in: ended)?.hash == "s11")
    #expect(SessionLedger.session(at: Date(timeIntervalSince1970: 2_151), in: ended) == nil)
  }
}
