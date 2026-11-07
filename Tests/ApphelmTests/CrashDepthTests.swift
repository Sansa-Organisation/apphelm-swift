import Darwin
import Foundation
import Testing

@testable import Apphelm

/// fork() is unavailable to Swift; the tests look it up, and the child only crashes.
private typealias Fork = @convention(c) () -> pid_t
private func forkProcess() throws -> pid_t {
  unsafeBitCast(try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork")), to: Fork.self)()
}

/// Wait for a child and say whether a signal ended it.
private func killedBySignal(_ child: pid_t) -> Bool {
  var status: Int32 = 0
  waitpid(child, &status, 0)
  return (status & 0x7f) != 0
}

@inline(never) func apphelmTestOverflow(_ depth: Int) -> Int {
  var padding = (depth, depth, depth, depth)
  return withUnsafeMutablePointer(to: &padding) { apphelmTestOverflow($0.pointee.0 + 1) + $0.pointee.1 }
}

private func overflowOnNewThread() {
  var thread: pthread_t?
  pthread_create(&thread, nil, { _ in _ = apphelmTestOverflow(0); return nil }, nil)
  if let thread { pthread_join(thread, nil) }
}

/// What a crashed child left: the signal report moved aside, as the next launch does.
private func childReport() throws -> [String: Any]? {
  try CrashInstaller.moveAsideActiveReport(directory: crashFolder)
  let reports = CrashInstaller.pendingReports(directory: crashFolder).filter { $0.pathExtension == "log" }
  defer {
    clearCrashFolder()
    try? CrashInstaller.openActiveFile(directory: crashFolder)
  }
  return reports.first.flatMap { CrashInstaller.exceptionProperties(report: $0) }
}

extension ClientTests {
  func freshCrashFolder() throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    try CrashInstaller.moveAsideActiveReport(directory: crashFolder)
    clearCrashFolder()
    try CrashInstaller.openActiveFile(directory: crashFolder)
  }

  @Test("A stack overflow on a thread started after install is recorded; without the thread hook it is not")
  func overflowOnOtherThread() throws {
    try freshCrashFolder()
    let child = try forkProcess()
    if child == 0 { overflowOnNewThread(); _exit(0) }
    #expect(killedBySignal(child))
    let report = try #require(try childReport())
    #expect(["SIGSEGV", "SIGBUS"].contains(report["name"] as? String))
    #expect(((report["stack"] as? String) ?? "").contains("apphelmTestOverflow"))

    // The control: a child whose new threads get no alternate stack dies without a report.
    let control = try forkProcess()
    if control == 0 {
      typealias Hook = @convention(c) (UInt32, pthread_t, UnsafeMutableRawPointer?, Int) -> Void
      typealias Install = @convention(c) (Hook) -> Hook?
      let install = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_introspection_hook_install"), to: Install.self)
      _ = install { _, _, _, _ in }
      overflowOnNewThread()
      _exit(0)
    }
    #expect(killedBySignal(control))
    #expect(try childReport() == nil)
  }

  @Test("Swift's Fatal error message is captured with the crash, scrubbed")
  func fatalErrorMessage() async throws {
    try freshCrashFolder()
    let child = try forkProcess()
    if child == 0 { fatalError("Checkout total went negative (token=abcd1234efgh)") }
    #expect(killedBySignal(child))
    try CrashInstaller.moveAsideActiveReport(directory: crashFolder)
    try CrashInstaller.openActiveFile(directory: crashFolder)
    let report = try #require(CrashInstaller.pendingReports(directory: crashFolder).first)
    let raw = try String(contentsOf: report, encoding: .utf8)
    #expect(raw.contains(CrashStore.messagePrefix))
    let properties = try #require(CrashInstaller.exceptionProperties(report: report))
    let message = try #require(properties["message"] as? String)
    #expect(message.contains("Fatal error: Checkout total went negative"))
    #expect(message.contains("token=[redacted]") && !message.contains("abcd1234efgh"))
    #expect(["SIGTRAP", "SIGILL"].contains(properties["name"] as? String))
    // The message line is not a frame.
    #expect(!((properties["stack"] as? String) ?? "").contains(CrashStore.messagePrefix))
    clearCrashFolder()
  }

  @Test("A crash with no runtime message keeps the signal's own")
  func signalWithoutMessage() throws {
    try freshCrashFolder()
    let child = try forkProcess()
    if child == 0 { raise(SIGSEGV); _exit(0) }
    #expect(killedBySignal(child))
    let report = try #require(try childReport())
    #expect(report["message"] as? String == "The app crashed with SIGSEGV")
  }

  // MARK: Watchdog terminations

  @Test("A watchdog termination is reported on the next launch with the run's scope, crashing its session")
  func watchdogReportIsSent() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    let scope: [String: Any] = ["release": "ios@2.2.0", "environment": "production", "session_hash": "sess-old", "user_hash": "u1",
                                "tags": ["plan": "pro"], "breadcrumbs": [["at": "2026-11-07T10:00:00Z", "category": "navigation", "message": "Cart"]]]
    #expect(WatchdogTerminations.writeReport(directory: crashFolder, scope: scope) != nil)
    var sent: [[String: Any]] = []
    let session = stubbedSession { request in
      sent.append((try requestJSON(request)["properties"] as? [String: Any]) ?? [:])
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    #expect(await ApphelmClient(options: releaseOptions(), session: session, store: MemoryStore()).sendPendingCrashReports(directory: crashFolder) == 1)
    let event = try #require(sent.first)
    #expect(event["name"] as? String == "WatchdogTermination")
    #expect(event["message"] as? String == "The OS watchdog terminated your app, possibly because it overused RAM.")
    #expect(event["handled"] as? Bool == false)
    #expect(event["level"] as? String == "fatal")
    #expect(event["session_hash"] as? String == "sess-old")
    // Crashed, not abnormal: sentry-cocoa's PreviousRunSessionFinalizer ends a watchdog termination's session crashed.
    #expect(event["session_status"] == nil)
    #expect(event["release"] as? String == "ios@2.2.0")
    #expect(event["tags"] as? [String: String] == ["mechanism": "watchdog_termination", "plan": "pro"])
    #expect((event["breadcrumbs"] as? [[String: String]])?.first?["message"] == "Cart")
    #expect(CrashInstaller.pendingReports(directory: crashFolder).isEmpty)
  }

  // MARK: Fatal app hangs

  func writeActiveHang(duration: Int = 3_400) throws {
    let hang: [String: Any] = ["kind": "apphang", "hang_type": "fully_blocking", "stack": ["0   Shop   0x0000000100004000 Shop + 16384"],
                               "images": [["name": "Shop", "uuid": UUID().uuidString, "base": "0x100000000", "slide": "0x0"]],
                               "duration_ms": duration, "timeout_ms": 2_000, "scope": ["release": "ios@2.2.0", "session_hash": "sess-hang"]]
    try JSONSerialization.data(withJSONObject: hang).write(to: crashFolder.appendingPathComponent(AppHangTracker.activeFile))
  }

  @Test("An app hang the run never came out of is a fatal app hang next launch, ending its session abnormal, not crashed")
  func fatalAppHang() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    try writeActiveHang()
    #expect(CrashInstaller.moveAsideAppHang(directory: crashFolder, crashed: false))
    #expect(!FileManager.default.fileExists(atPath: crashFolder.appendingPathComponent(AppHangTracker.activeFile).path))
    var sent: [[String: Any]] = []
    let session = stubbedSession { request in
      sent.append((try requestJSON(request)["properties"] as? [String: Any]) ?? [:])
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    #expect(await ApphelmClient(options: releaseOptions(), session: session, store: MemoryStore()).sendPendingCrashReports(directory: crashFolder) == 1)
    let event = try #require(sent.first)
    #expect(event["name"] as? String == "Fatal App Hang Fully Blocked")
    #expect(event["message"] as? String == "The user or the OS watchdog terminated your app while it blocked the main thread for at least 3.4 seconds.")
    #expect(event["level"] as? String == "fatal" && event["handled"] as? Bool == false)
    #expect(event["session_hash"] as? String == "sess-hang")
    #expect(event["session_status"] as? String == "abnormal")
    #expect(event["abnormal_mechanism"] as? String == "anr_foreground")
    #expect(event["release"] as? String == "ios@2.2.0")
    #expect((event["tags"] as? [String: String])?["mechanism"] == "AppHang")
    #expect((event["stack"] as? String)?.contains("Shop") == true)
    #expect((event["debug_images"] as? [[String: String]])?.first?["name"] == "Shop")
  }

  @Test("A hang ended by a crash is sent as the hang it was, handled, beside the crash")
  func hangEndedByCrash() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    try writeActiveHang()
    #expect(CrashInstaller.moveAsideAppHang(directory: crashFolder, crashed: true))
    let report = try #require(CrashInstaller.pendingReports(directory: crashFolder).first)
    let properties = try #require(CrashInstaller.exceptionProperties(report: report))
    #expect(properties["name"] as? String == "App Hang Fully Blocked")
    #expect(properties["level"] as? String == "error" && properties["handled"] as? Bool == true)
    #expect(properties["session_status"] == nil)
    clearCrashFolder()
  }

  @Test("The previous run: crashed when it left a signal or exception report, and whether a hang was under way")
  func previousRun() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-previous-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let state = AppState(release: "1", osVersion: "26", vendorId: "v", isDebugging: false, bootTime: 1, isActive: true, wasTerminated: false, isSDKRunning: true, run: "run-1")
    try JSONEncoder().encode(state).write(to: folder.appendingPathComponent(WatchdogTerminations.stateFile))
    try JSONSerialization.data(withJSONObject: ["session_hash": "s"]).write(to: folder.appendingPathComponent(CrashScopeStore.activeFile))
    var (run, signal) = try CrashInstaller.takePreviousRun(directory: folder)
    #expect(run.state == state && !run.crashed && !run.hangOngoing && signal == nil)
    #expect(run.scope?["session_hash"] as? String == "s")
    // An uncaught exception of that run.
    FileManager.default.createFile(atPath: folder.appendingPathComponent("crash-exception-run-1.json").path, contents: Data("{}".utf8))
    (run, _) = try CrashInstaller.takePreviousRun(directory: folder)
    #expect(run.crashed)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("crash-exception-run-1.json"))
    // A signal report.
    FileManager.default.createFile(atPath: folder.appendingPathComponent(CrashStore.activeFile).path, contents: Data("APPHELM-SIGNAL 11 SIGSEGV\n".utf8))
    let hang = try JSONSerialization.data(withJSONObject: ["kind": "apphang", "hang_type": "fully_blocking", "stack": [], "duration_ms": 2_400])
    try hang.write(to: folder.appendingPathComponent(AppHangTracker.activeFile))
    (run, signal) = try CrashInstaller.takePreviousRun(directory: folder)
    #expect(run.crashed && run.hangOngoing && signal != nil)
  }
}

@Suite("Watchdog termination rules")
struct WatchdogRuleTests {
  let previous = AppState(release: "shop@2.4.1", osVersion: "Version 26.1", vendorId: "V-1", isDebugging: false, bootTime: 1_000, isActive: true, wasTerminated: false, isSDKRunning: true, run: "a")
  var current: AppState {
    AppState(release: "shop@2.4.1", osVersion: "Version 26.1", vendorId: "V-1", isDebugging: false, bootTime: 1_000.4, isActive: false, wasTerminated: false, isSDKRunning: true, run: "b")
  }

  func check(_ change: (inout AppState) -> Void = { _ in }, current: AppState? = nil, crashed: Bool = false, hang: Bool = false, simulator: Bool = false) -> Bool {
    var before = previous
    change(&before)
    return WatchdogTerminations.isWatchdogTermination(previous: before, current: current ?? self.current, crashed: crashed, hangOngoing: hang, simulator: simulator)
  }

  @Test("A foreground run that ended with no crash, exit or known cause was a watchdog termination")
  func detected() { #expect(check()) }

  @Test("Each of Sentry's exclusions rules it out")
  func exclusions() {
    #expect(!WatchdogTerminations.isWatchdogTermination(previous: nil, current: current, crashed: false, hangOngoing: false, simulator: false))
    #expect(!check(simulator: true))
    var updated = current
    updated.release = "shop@2.4.2"
    #expect(!check(current: updated))
    var newOS = current
    newOS.osVersion = "Version 26.2"
    #expect(!check(current: newOS))
    var rebooted = current
    rebooted.bootTime = 5_000
    #expect(!check(current: rebooted))
    var reinstalled = current
    reinstalled.vendorId = "V-2"
    #expect(!check(current: reinstalled))
    #expect(!check { $0.vendorId = nil })
    #expect(!check { $0.isDebugging = true })
    #expect(!check { $0.wasTerminated = true })
    #expect(!check(crashed: true))
    #expect(!check { $0.isSDKRunning = false })
    #expect(!check { $0.isActive = false })
    #expect(!check(hang: true))
  }
}

@Suite("App hang detection", .serialized)
struct AppHangTests {
  /// A serial queue standing in for the main queue, and the thread serving it.
  final class Blocked: @unchecked Sendable {
    let queue = DispatchQueue(label: "apphelm-test-main")
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var port: thread_act_t?
    var thread: thread_act_t? { lock.withLock { port } }

    func block() {
      queue.async { [self] in
        lock.withLock { port = mach_thread_self() }
        started.signal()
        release.wait()
      }
      started.wait()
    }
  }

  final class Ended: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [(AppHangTracker.Hang, ClosedRange<Double>)] = []
    func add(_ hang: AppHangTracker.Hang, _ range: ClosedRange<Double>) { lock.withLock { value.append((hang, range)) } }
    var all: [(AppHangTracker.Hang, ClosedRange<Double>)] { lock.withLock { value } }
  }

  func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-hang-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Pings: a queue that doesn't answer for the timeout is a fully blocking hang, with the blocked thread's stack, ended when it answers")
  func pingHang() throws {
    let blocked = Blocked(), ended = Ended(), directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = AppHangTracker.Target(queue: blocked.queue, thread: { blocked.thread }, frames: nil, isForeground: { true })
    let tracker = AppHangTracker(timeout: 2, reportNonFullyBlocking: true, directory: directory, target: target) { ended.add($0, $1) }
    blocked.block()
    tracker.step(now: 100)       // ping sent
    tracker.step(now: 101.6)     // not yet the timeout
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(AppHangTracker.activeFile).path))
    tracker.step(now: 102.1)     // the hang
    let file = directory.appendingPathComponent(AppHangTracker.activeFile)
    let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(stored["kind"] as? String == "apphang" && stored["hang_type"] as? String == "fully_blocking")
    let stack = try #require(stored["stack"] as? [String])
    // The blocked thread waits in the kernel on the semaphore.
    #expect(stack.first?.contains("libsystem_kernel.dylib") == true)
    #expect(stack.allSatisfy { DebugImages.imageName(inFrame: $0) != nil })
    #expect(ended.all.isEmpty)
    blocked.release.signal()
    blocked.queue.sync {}
    tracker.step(now: 102.5)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let hang = try #require(ended.all.first)
    #expect(hang.0.kind == .fullyBlocking && !hang.0.stack.isEmpty)
    #expect(hang.1.lowerBound >= 2)
  }

  @Test("The tracker's own thread finds a real 1.2 s block with a 0.5 s timeout and times it")
  func realTimeHang() async throws {
    let blocked = Blocked(), ended = Ended()
    let target = AppHangTracker.Target(queue: blocked.queue, thread: { blocked.thread }, frames: nil, isForeground: { true })
    let tracker = AppHangTracker(timeout: 0.5, reportNonFullyBlocking: true, directory: nil, target: target) { ended.add($0, $1) }
    tracker.start()
    defer { tracker.stop() }
    try await Task.sleep(nanoseconds: 300_000_000)
    blocked.block()
    try await Task.sleep(nanoseconds: 1_200_000_000)
    blocked.release.signal()
    #expect(await eventually { !ended.all.isEmpty })
    let hang = try #require(ended.all.first)
    #expect(hang.0.kind == .fullyBlocking && !hang.0.stack.isEmpty)
    // Blocked about 1.2 s; the ping may have gone out up to one wake-up (0.1 s) after the block began.
    #expect(hang.1.lowerBound > 0.9 && hang.1.upperBound < 1.6)
    #expect(ended.all.count == 1)
  }

  @Test("No hang in the background, and pauses drop a hang under way")
  func backgroundAndPause() throws {
    let blocked = Blocked(), ended = Ended()
    final class Flag: @unchecked Sendable { var on = false }
    let foreground = Flag()
    let target = AppHangTracker.Target(queue: blocked.queue, thread: { blocked.thread }, frames: nil, isForeground: { foreground.on })
    let tracker = AppHangTracker(timeout: 2, reportNonFullyBlocking: true, directory: nil, target: target) { ended.add($0, $1) }
    blocked.block()
    tracker.step(now: 0)
    tracker.step(now: 3)
    foreground.on = true
    tracker.step(now: 4)
    tracker.setPaused(true)
    tracker.step(now: 7)
    tracker.setPaused(false)
    blocked.release.signal()
    blocked.queue.sync {}
    tracker.step(now: 8)
    tracker.step(now: 8.4)
    #expect(ended.all.isEmpty)
  }

  @Test("Frames: one frame late for the whole window is fully blocking; many late frames are non-fully blocking, if reported")
  func frameHangs() throws {
    let stats = FrameStats()
    stats.setRunning(true)
    let expected = 1.0 / 60
    // Smooth frames up to t = 10.
    var t = 9.0
    while t < 10 { t += expected; stats.tick(duration: expected, expected: expected, at: Date(), uptime: t) }
    #expect(stats.delay(from: 8, to: 10, now: 10)?.seconds ?? 1 < 0.01)
    // Nothing drawn since: the frame being drawn is late by everything after its first 1/60 s.
    let ongoing = try #require(stats.delay(from: 10.5, to: 12.5, now: 12.5))
    #expect(ongoing.frames == 1 && abs(ongoing.seconds - 2) < 0.001)

    let ended = Ended()
    let fully = AppHangTracker(timeout: 2, reportNonFullyBlocking: true, directory: nil, target: .init(queue: .global(), thread: { nil }, frames: stats, isForeground: { true })) { ended.add($0, $1) }
    fully.step(now: 11.5)  // late for 1.5 s only
    fully.step(now: 12.5)
    // The display draws again: the hang is over once the last two wake-ups are smooth.
    t = 12.5
    while t < 13.4 { t += expected; stats.tick(duration: t == 12.5 + expected ? 2.5 : expected, expected: expected, at: Date(), uptime: t) }
    fully.step(now: 13.4)
    let hang = try #require(ended.all.first)
    #expect(hang.0.kind == .fullyBlocking)
    #expect(hang.1.upperBound >= 2.8 && hang.1.lowerBound >= 2)

    // One frame drawn in the middle of the window, late frames on both sides of it: late for
    // more than 99% of the window, by two frames.
    let slow = FrameStats()
    slow.setRunning(true)
    slow.tick(duration: expected, expected: expected, at: Date(), uptime: 20)
    slow.tick(duration: 2, expected: expected, at: Date(), uptime: 22)
    t = 23.5
    let late = try #require(slow.delay(from: t - 2, to: t, now: t))
    #expect(late.frames == 2 && late.seconds > 1.98)
    let quiet = Ended()
    AppHangTracker(timeout: 2, reportNonFullyBlocking: false, directory: nil, target: .init(queue: .global(), thread: { nil }, frames: slow, isForeground: { true })) { quiet.add($0, $1) }.step(now: t)
    let loud = AppHangTracker(timeout: 2, reportNonFullyBlocking: true, directory: nil, target: .init(queue: .global(), thread: { nil }, frames: slow, isForeground: { true })) { quiet.add($0, $1) }
    loud.step(now: t)
    slow.tick(duration: 1.5, expected: expected, at: Date(), uptime: t)
    for _ in 0..<60 { t += expected; slow.tick(duration: expected, expected: expected, at: Date(), uptime: t) }
    loud.step(now: t)
    #expect(quiet.all.count == 1 && quiet.all.first?.0.kind == .nonFullyBlocking)
  }

  @Test("Durations are worded as Sentry words them")
  func wording() {
    #expect(AppHangTracker.message(duration: 2.4...2.8) == "App hanging between 2.4 and 2.8 seconds.")
    #expect(AppHangTracker.message(duration: 3.0...3.02) == "App hanging for 3.0 seconds.")
    #expect(AppHangTracker.message(duration: AppHangTracker.duration(startedAt: 10, endedBy: 13, answeredAt: 12.6, timeout: 2, sleepInterval: 0.4)) == "App hanging between 2.6 and 3.0 seconds.")
    #expect(AppHangTracker.message(duration: AppHangTracker.duration(startedAt: 10, endedBy: 13, answeredAt: nil, timeout: 2, sleepInterval: 0.4)) == "App hanging between 2.2 and 3.0 seconds.")
    #expect(AppHangTracker.Kind.nonFullyBlocking.title(fatal: true) == "Fatal App Hang Non Fully Blocked")
  }

  @Test("A hang that ended is sent as an error with mechanism AppHang and the client's scope")
  func reportHang() async throws {
    let recorder = Recorder()
    let client = ApphelmClient(options: ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: "ios@2.3.0").quiet, session: recorder.session(), store: MemoryStore())
    client.setTag("plan", "pro")
    let hang = AppHangTracker.Hang(kind: .fullyBlocking, stack: ["0   Shop   0x0000000100004000 Shop + 16384"], images: [["name": "Shop", "uuid": UUID().uuidString, "base": "0x100000000", "slide": "0x0"]])
    #expect(await client.reportAppHang(hang, duration: 2.4...2.8))
    let event = recorder.properties(0)
    #expect(recorder.bodies[0]["eventName"] as? String == "$exception")
    #expect(event["name"] as? String == "App Hang Fully Blocked")
    #expect(event["message"] as? String == "App hanging between 2.4 and 2.8 seconds.")
    #expect(event["level"] as? String == "error" && event["handled"] == nil)
    #expect(event["tags"] as? [String: String] == ["mechanism": "AppHang", "plan": "pro"])
    #expect(event["release"] as? String == "ios@2.3.0")
    #expect((event["debug_images"] as? [[String: String]])?.count == 1)
  }
}
