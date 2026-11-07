import Darwin
import Foundation
import Testing

@testable import Apphelm

private func simpleScreen(_ label: String = "Basket") -> ReplayViewNode {
  var root = ReplayViewNode(id: 1, x: 0, y: 0, width: 390, height: 844, background: "#ffffff")
  root.children = [ReplayViewNode(id: 2, kind: .text, x: 16, y: 60, width: 200, height: 24, text: label)]
  return root
}

/// Requests a stubbed session saw, by path, with their JSON bodies.
private final class Requests: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [(path: String, body: [String: Any])] = []
  func add(_ request: URLRequest) throws { let body = try requestJSON(request); lock.withLock { seen.append((request.url?.path ?? "", body)) } }
  func bodies(_ path: String) -> [[String: Any]] { lock.withLock { seen.filter { $0.path == path }.map(\.body) } }
  var paths: [String] { lock.withLock { seen.map(\.path) } }
}

// In the serialized transport suite: the stub URL protocol's handler is shared state.
extension ClientTests {
  private func replayClient(_ replay: ReplayOptions, requests: Requests) -> ApphelmClient {
    let session = stubbedSession { request in
      try requests.add(request)
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    var options = releaseOptions()
    var replay = replay
    replay.projectKey = "ahl_pub_mobile"
    replay.origin = "https://app.shop.example"
    options.replay = replay
    return ApphelmClient(options: options, session: session, store: MemoryStore())
  }

  @Test("An exception uploads the replay-on-error buffer and carries its id; a message does not")
  func exceptionLinksBuffer() async throws {
    struct CheckoutFailed: Error {}
    let requests = Requests()
    let client = replayClient(ReplayOptions(sessionSampleRate: 0, onErrorSampleRate: 1), requests: requests)
    client.setReplayConsent(true)
    let recorder = try #require(client.replayRecorderForTests)
    recorder.capture(simpleScreen(), width: 390, height: 844)
    #expect(recorder.isBuffering && client.replaySessionId == nil)
    try await client.captureMessage("Fell back to the cached basket")
    #expect(requests.bodies("/api/v1/events").last.flatMap { ($0["properties"] as? [String: Any])?["replay_session_id"] } == nil)
    #expect(recorder.isBuffering)
    try await client.captureException(CheckoutFailed())
    let exception = try #require(requests.bodies("/api/v1/events").last?["properties"] as? [String: Any])
    let id = try #require(exception["replay_session_id"] as? String)
    #expect(id.hasPrefix("rpl_") && client.replaySessionId == id)
    await client.flushReplay()
    let chunk = try #require(requests.bodies("/api/replay").first)
    #expect(chunk["sessionId"] as? String == id && chunk["sequence"] as? Int == 0)
  }

  @Test("beforeSend dropping an exception leaves the buffer in memory")
  func droppedExceptionKeepsBuffer() async throws {
    struct CheckoutFailed: Error {}
    let requests = Requests()
    let session = stubbedSession { request in
      try requests.add(request)
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    var options = releaseOptions()
    options.replay = ReplayOptions(projectKey: "ahl_pub_mobile", origin: "https://app.shop.example", sessionSampleRate: 0, onErrorSampleRate: 1)
    options.beforeSend = { _ in nil }
    let client = ApphelmClient(options: options, session: session, store: MemoryStore())
    client.setReplayConsent(true)
    client.replayRecorderForTests?.capture(simpleScreen(), width: 390, height: 844)
    try await client.captureException(CheckoutFailed())
    await client.flushReplay()
    #expect(client.replayRecorderForTests?.isBuffering == true && requests.bodies("/api/replay").isEmpty)
  }

  @Test("A whole recording links every error event, messages included")
  func sessionLinksMessages() async throws {
    let requests = Requests()
    let client = replayClient(ReplayOptions(), requests: requests)
    client.setReplayConsent(true)
    client.replayRecorderForTests?.capture(simpleScreen(), width: 390, height: 844)
    try await client.captureMessage("Fell back to the cached basket")
    let message = try #require(requests.bodies("/api/v1/events").last?["properties"] as? [String: Any])
    #expect(message["replay_session_id"] as? String == client.replaySessionId)
  }

  @Test("A crash's stored replay is uploaded on the next launch and linked to the crash report")
  func crashReplayIsSentNextLaunch() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    try CrashInstaller.openActiveFile(directory: crashFolder)
    writeSignalReport(SIGSEGV)
    let report = try #require(try CrashInstaller.moveAsideActiveReport(directory: crashFolder))
    try CrashInstaller.openActiveFile(directory: crashFolder)
    // The crashed run's buffer, as its replay flush left it.
    let crashed = ReplayRecorder(options: ReplayOptions(sessionSampleRate: 0, onErrorSampleRate: 1), workspaceId: "org_1", productId: "prd_1",
      person: { .init(distinctId: "user-1", identified: true) }, send: { _ in .done })
    crashed.setConsent(true)
    crashed.capture(simpleScreen(), width: 390, height: 844)
    let snapshot = try #require(crashed.crashSnapshot())
    let stored = try #require(ReplayCrashStore.file(for: report))
    try snapshot.write(to: stored)
    let requests = Requests()
    // The next launch: replay set up, no consent asked yet.
    let client = replayClient(ReplayOptions(), requests: requests)
    #expect(await client.sendPendingCrashReports(directory: crashFolder) == 1)
    #expect(requests.paths == ["/api/replay", "/api/v1/events"])
    let replayId = try #require(requests.bodies("/api/replay").first?["sessionId"] as? String)
    let crash = try #require(requests.bodies("/api/v1/events").first?["properties"] as? [String: Any])
    #expect(crash["name"] as? String == "SIGSEGV" && crash["replay_session_id"] as? String == replayId)
    #expect(!FileManager.default.fileExists(atPath: stored.path))
  }

  @Test("Withdrawing replay consent deletes a crashed run's stored replay")
  func withdrawalDeletesStoredReplay() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    let stored = crashFolder.appendingPathComponent("replay-exception-ABC.json")
    try Data("{}".utf8).write(to: stored)
    let client = replayClient(ReplayOptions(), requests: Requests())
    client.useCrashDirectory(crashFolder)
    client.setReplayConsent(false)
    #expect(!FileManager.default.fileExists(atPath: stored.path))
  }
}

@Suite("Replay crash store")
struct ReplayCrashStoreTests {
  @Test("At install a snapshot follows its run's crash report, and is deleted when the run did not crash")
  func moveAside() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-replay-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func active(_ run: String) -> URL { folder.appendingPathComponent("replay-active-\(run).json") }
    // An uncaught exception in run A, a signal in run B (moved aside as crash-S.log), run C clean.
    try Data("{}".utf8).write(to: folder.appendingPathComponent("crash-exception-A.json"))
    try Data("a".utf8).write(to: active("A"))
    ReplayCrashStore.moveAside(directory: folder, signalReport: nil)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("replay-exception-A.json").path))
    try Data("b".utf8).write(to: active("B"))
    ReplayCrashStore.moveAside(directory: folder, signalReport: folder.appendingPathComponent("crash-S.log"))
    #expect(String(decoding: try Data(contentsOf: folder.appendingPathComponent("replay-S.json")), as: UTF8.self) == "b")
    try Data("c".utf8).write(to: active("C"))
    ReplayCrashStore.moveAside(directory: folder, signalReport: nil)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(names == ["crash-exception-A.json", "replay-S.json", "replay-exception-A.json"])
    #expect(ReplayCrashStore.file(for: folder.appendingPathComponent("crash-exception-A.json"))?.lastPathComponent == "replay-exception-A.json")
  }
}
