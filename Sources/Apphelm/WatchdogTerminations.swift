import Darwin
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Watchdog terminations (Sentry's `enableWatchdogTerminationTracking`): the system killed the
/// app while it was in the foreground, with no crash and no normal exit. Out of memory is the
/// usual cause (iOS kills a foreground app that uses too much, and nothing in the process sees
/// it coming), then the watchdog killing an app that blocked its main thread too long.
///
/// Nothing can run when it happens, so it is inferred on the next launch from the state the
/// previous run left in `app-state.json` beside the crash reports, by Sentry's rules
/// (SentryWatchdogTerminationLogic): the previous run was a watchdog termination unless
/// - there is no record of it, or this is a simulator;
/// - the release or the OS version changed (an update ends the old process), or the device
///   rebooted (the boot time moved), or the vendor id is missing or changed;
/// - a debugger was attached (stopping a run from Xcode kills it);
/// - it was terminated normally (`willTerminate`, or `exit()`, which Sentry does not watch);
/// - it crashed (a crash report was written), or Apphelm was closed (`close()`);
/// - it was not in the foreground and active (a kill in the background is the system
///   reclaiming memory, which is normal);
/// - an app hang was under way (it is sent as a fatal app hang instead).
///
/// Sent as an unhandled `$exception` named `WatchdogTermination` (mechanism
/// `watchdog_termination`, level `fatal`) with the previous run's scope, so it crashes that
/// run's session. UIKit only (iOS, tvOS, visionOS), as Sentry's.
struct AppState: Codable, Equatable, Sendable {
  var release: String
  var osVersion: String
  var vendorId: String?
  var isDebugging: Bool
  var bootTime: Double
  var isActive: Bool
  var wasTerminated: Bool
  var isSDKRunning: Bool
  /// The run's id: its uncaught-exception report is `crash-exception-<run>.json`.
  var run: String
}

enum WatchdogTerminations {
  static let stateFile = "app-state.json"
  static let name = "WatchdogTermination"
  static let message = "The OS watchdog terminated your app, possibly because it overused RAM."

  /// Whether the previous run, as `previous` describes it, ended in a watchdog termination.
  static func isWatchdogTermination(previous: AppState?, current: AppState, crashed: Bool, hangOngoing: Bool, simulator: Bool) -> Bool {
    guard let previous, !simulator else { return false }
    if previous.release != current.release || previous.osVersion != current.osVersion { return false }
    if abs(previous.bootTime - current.bootTime) > 1 { return false }
    guard let vendor = previous.vendorId, vendor == current.vendorId else { return false }
    if previous.isDebugging || previous.wasTerminated || crashed || !previous.isSDKRunning { return false }
    if !previous.isActive || hangOngoing { return false }
    return true
  }

  static func load(directory: URL) -> AppState? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(stateFile)) else { return nil }
    return try? JSONDecoder().decode(AppState.self, from: data)
  }

  /// The report the next `sendPendingCrashReports()` sends, with the run's scope (release,
  /// environment, session, tags, user hash, breadcrumbs). Returns where it was written.
  @discardableResult
  static func writeReport(directory: URL, scope: [String: Any]?, at date: Date = Date()) -> URL? {
    let report: [String: Any] = [
      "kind": "watchdog",
      "name": name,
      "reason": message,
      "at": ISO8601DateFormatter().string(from: date),
      "scope": jsonSafe(scope ?? [:]),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: report) else { return nil }
    let file = directory.appendingPathComponent("crash-watchdog-\(UUID().uuidString).json")
    return FileManager.default.createFile(atPath: file.path, contents: data) ? file : nil
  }

  static var isSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  /// The OS name and version (`Version 26.1 (Build 23B85)`).
  static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

/// This run's `AppState`, kept on disk as it changes. Each change is written at once (it is
/// a few hundred bytes), since the next state change may never come.
final class AppStateStore: @unchecked Sendable {
  static let shared = AppStateStore()
  private let lock = NSLock()
  private var state: AppState?
  private var file: URL?

  var current: AppState? { lock.withLock { state } }

  func attach(_ value: AppState, directory: URL) {
    lock.withLock {
      state = value
      file = directory.appendingPathComponent(WatchdogTerminations.stateFile)
    }
    write()
  }

  func update(_ change: (inout AppState) -> Void) {
    let changed: Bool = lock.withLock {
      guard var value = state else { return false }
      change(&value)
      if value == state { return false }
      state = value
      return true
    }
    if changed { write() }
  }

  private func write() {
    let (value, target) = lock.withLock { (state, file) }
    guard let value, let target, let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: target, options: .atomic)
  }

  /// Follow the app's state: active or not, terminated normally (`willTerminate`, `exit()`).
  func observe() {
    atexit { AppStateStore.shared.update { $0.wasTerminated = true } }
    #if canImport(UIKit) && !os(watchOS)
    let begin: @Sendable () -> Void = {
      MainActor.assumeIsolated {
        AppStateStore.shared.update { $0.isActive = sharedApplication()?.applicationState == .active }
        if let vendor = UIDevice.current.identifierForVendor?.uuidString { AppStateStore.shared.update { $0.vendorId = vendor } }
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in AppStateStore.shared.update { $0.isActive = true } }
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in AppStateStore.shared.update { $0.isActive = false } }
        _ = center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in AppStateStore.shared.update { $0.wasTerminated = true } }
      }
    }
    if Thread.isMainThread { begin() } else { DispatchQueue.main.async(execute: begin) }
    #endif
  }
}

extension ApphelmClient {
  private static let watchdogLock = NSLock()
  nonisolated(unsafe) private static var watchdogChecked = false

  /// Once per process, from `installCrashReporting`: decide whether the previous run was a
  /// watchdog termination (and leave its report; UIKit only), then start recording this
  /// run's state (on every platform: the next launch also uses its run id to tell whether
  /// this run crashed).
  func trackWatchdogTerminations(directory: URL) {
    let first: Bool = Self.watchdogLock.withLock {
      defer { Self.watchdogChecked = true }
      return !Self.watchdogChecked
    }
    guard first, let previousRun = CrashInstaller.previousRun else { return }
    var current = AppState(release: options.release ?? "\(appInfo.version) (\(appInfo.build))", osVersion: WatchdogTerminations.osVersion,
                           vendorId: nil, isDebugging: isDebuggerAttached(), bootTime: bootTime() ?? 0, isActive: false,
                           wasTerminated: false, isSDKRunning: true, run: CrashInstaller.currentRun ?? "")
    #if canImport(UIKit) && !os(watchOS)
    // UIDevice is the main thread's; installed elsewhere, the vendor id is filled in shortly
    // after (`observe`) and this launch's check goes without it.
    current.vendorId = Thread.isMainThread ? MainActor.assumeIsolated { UIDevice.current.identifierForVendor?.uuidString } : nil
    if options.enableWatchdogTerminationTracking, current.vendorId != nil,
       WatchdogTerminations.isWatchdogTermination(previous: previousRun.state, current: current, crashed: previousRun.crashed, hangOngoing: previousRun.hangOngoing, simulator: WatchdogTerminations.isSimulator) {
      WatchdogTerminations.writeReport(directory: directory, scope: previousRun.scope)
      debugLog("the previous run ended in a watchdog termination")
    }
    #endif
    AppStateStore.shared.attach(current, directory: directory)
    AppStateStore.shared.observe()
  }
}
