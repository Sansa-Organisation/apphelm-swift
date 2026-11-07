import Darwin
import Foundation

// Platform-independent logic behind the mobile measurements. The UIKit glue (CADisplayLink,
// view controller and lifecycle hooks) is in UIKitInstrumentation.swift; everything it
// decides is decided here, so `swift test` on macOS covers it.

/// Rendered frames, counted as Sentry counts them: every display-link tick is a frame; a
/// frame that took longer than the display's refresh interval (it missed its deadline) is
/// slow, and one longer than 700 ms is frozen (frozen frames are not also counted as slow).
struct FrameCounts: Equatable, Sendable {
  var total = 0
  var slow = 0
  var frozen = 0

  static let frozenThreshold: Double = 0.7

  /// Count one frame that took `duration` seconds on a display refreshing every `expected`
  /// seconds (1/60 at 60 Hz, 1/120 on ProMotion). A tolerance of 5% of the interval absorbs
  /// the display link's timestamp jitter; any missed refresh is at least twice the interval.
  mutating func record(duration: Double, expected: Double) {
    guard duration > 0, expected > 0 else { return }
    total += 1
    if duration > Self.frozenThreshold {
      frozen += 1
    } else if duration > expected * 1.05 {
      slow += 1
    }
  }

  /// The frames counted since `earlier`.
  func since(_ earlier: FrameCounts) -> FrameCounts {
    FrameCounts(total: max(0, total - earlier.total), slow: max(0, slow - earlier.slow), frozen: max(0, frozen - earlier.frozen))
  }
}

/// The process-wide frame counter the UIKit display link feeds, and a transaction reads at
/// its start and finish. `running` is true while a display link ticks (it also times first
/// frames for TTID and app start); `counting` is true when its frames are attached to
/// transactions (`enableFramesTracking`). Neither is true on macOS or in tests unless set.
final class FrameStats: @unchecked Sendable {
  static let shared = FrameStats()
  private let lock = NSLock()
  private var counts = FrameCounts()
  private var _running = false
  private var _counting = false
  private var waiting: [@Sendable (Date) -> Void] = []

  var running: Bool { lock.withLock { _running } }
  var snapshot: FrameCounts { lock.withLock { counts } }

  var counting: Bool { lock.withLock { _running && _counting } }
  func setRunning(_ value: Bool) { lock.withLock { _running = value } }
  func setCounting(_ value: Bool) { lock.withLock { _counting = value } }

  /// One display-link tick: the frame before it took `duration` seconds. Callbacks waiting
  /// for the next frame are called with `at`, the wall-clock time of this one. `uptime` is
  /// when it ticked (seconds of `DispatchTime` uptime), for app-hang detection's timeline.
  func tick(duration: Double?, expected: Double, at: Date, uptime: Double = uptimeSeconds()) {
    let callbacks: [@Sendable (Date) -> Void] = lock.withLock {
      if let duration {
        counts.record(duration: duration, expected: expected)
        timeline.append(TimedFrame(end: uptime, duration: duration, expected: expected))
        if timeline.count >= 2 * Self.timelineCapacity { timeline.removeFirst(Self.timelineCapacity) }
      }
      lastTick = (uptime, expected)
      defer { waiting.removeAll() }
      return waiting
    }
    for callback in callbacks { callback(at) }
  }

  // MARK: Frame delay (app hangs)

  /// A rendered frame on the uptime clock.
  struct TimedFrame: Equatable, Sendable {
    var end: Double
    var duration: Double
    var expected: Double
  }

  /// At least 8 s of frames at 120 Hz (up to twice as many are kept): more than a hang window needs.
  static let timelineCapacity = 1_000
  private var timeline: [TimedFrame] = []
  private var lastTick: (uptime: Double, expected: Double)?

  /// The display stopped and starts again (background, return to the foreground): time away
  /// is not a frame that is late. The pending frame counts from `uptime`.
  func restartTimeline(at uptime: Double = uptimeSeconds()) {
    lock.withLock { lastTick = lastTick.map { (uptime, $0.expected) } }
  }

  /// How late frames were in `from…to` (uptime seconds), as Sentry's frames tracker measures
  /// it: the part of each frame past its expected duration that falls in the window, plus
  /// the frame being drawn now if it is already late at `now`. `frames` is how many frames
  /// contributed. Nil when no display link has ticked yet.
  func delay(from: Double, to: Double, now: Double) -> (seconds: Double, frames: Int)? {
    lock.withLock {
      guard let lastTick else { return nil }
      var seconds = 0.0
      var frames = 0
      func add(start: Double, end: Double, expected: Double) {
        let overlap = min(end, to) - max(start + expected, from)
        if overlap > 0 {
          seconds += overlap
          frames += 1
        }
      }
      for frame in timeline.reversed() {
        if frame.end <= from { break }
        add(start: frame.end - frame.duration, end: frame.end, expected: frame.expected)
      }
      add(start: lastTick.uptime, end: now, expected: lastTick.expected)
      return (seconds, frames)
    }
  }

  /// Call `callback` at the next rendered frame. Returns false (and never calls it) when no
  /// display link is running.
  @discardableResult
  func onNextFrame(_ callback: @escaping @Sendable (Date) -> Void) -> Bool {
    lock.withLock {
      guard _running else { return false }
      waiting.append(callback)
      return true
    }
  }

  /// For tests.
  func reset() { lock.withLock { counts = FrameCounts(); _running = false; _counting = false; waiting.removeAll(); timeline.removeAll(); lastTick = nil } }
}

/// Seconds since boot on the clock `DispatchTime` and `CADisplayLink` use (not counting sleep).
func uptimeSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

/// `work` at the next rendered frame, or on the next main-queue turn when no display link runs.
func afterNextFrame(_ work: @escaping @Sendable () -> Void) {
  if !FrameStats.shared.onNextFrame({ _ in work() }) {
    DispatchQueue.main.async(execute: work)
  }
}

// MARK: - App start

/// What the previous launch left: the device's boot time and the app's version and build.
struct AppStartRecord: Codable, Equatable {
  var bootTime: Double
  var version: String
  var build: String
}

enum AppStartType: String, Sendable {
  case cold, warm
}

/// One app start to report.
struct AppStart: Equatable {
  var type: AppStartType
  var start: Date
  var durationMs: Int
}

/// Sentry's rules for an app start, roughly:
/// - **Cold** on the first launch after install, after an update (version or build changed)
///   and after a device reboot (the boot time moved by more than a second): the process,
///   the dynamic linker and the app's caches all start from nothing.
/// - **Warm** otherwise: the system had the app's binaries and data in its caches.
/// - A **prewarmed** process (iOS 15+ starts some apps' processes ahead of use and sets
///   `ActivePrewarm=1`) is measured from when Apphelm was loaded instead of from process
///   start, since the process may have waited minutes before the person opened the app, and
///   is reported as warm: the cold part of the work happened before the person asked.
/// - Not reported when the app was launched in the background (a background fetch, a push),
///   when the start took longer than 180 s or less than nothing, or more than once a
///   process.
/// The start ends at the first frame drawn after the app became active.
enum AppStartRules {
  static let maxDuration: Double = 180

  static func classify(processStart: Date, sdkLoaded: Date, firstFrame: Date, prewarmed: Bool, launchedInBackground: Bool, previous: AppStartRecord?, current: AppStartRecord) -> AppStart? {
    guard !launchedInBackground else { return nil }
    let start = prewarmed ? sdkLoaded : processStart
    let duration = firstFrame.timeIntervalSince(start)
    guard duration >= 0, duration <= maxDuration else { return nil }
    let type: AppStartType
    if prewarmed {
      type = .warm
    } else if let previous, previous.version == current.version, previous.build == current.build, abs(previous.bootTime - current.bootTime) <= 1 {
      type = .warm
    } else {
      type = .cold
    }
    return AppStart(type: type, start: start, durationMs: Int((duration * 1000).rounded()))
  }
}

/// When this process started, from the kernel (`kinfo_proc.p_starttime`).
func processStartDate() -> Date? {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
  guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
  let time = info.kp_proc.p_un.__p_starttime
  return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
}

/// When the device last booted (`kern.boottime`), seconds since 1970.
func bootTime() -> Double? {
  var time = timeval()
  var size = MemoryLayout<timeval>.stride
  var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
  guard sysctl(&mib, u_int(mib.count), &time, &size, nil, 0) == 0 else { return nil }
  return Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
}

/// Whether the system prewarmed this process.
func isPrewarmedProcess() -> Bool {
  ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
}

/// When Apphelm was first used in this process: the nearest Swift gets to Sentry's
/// "runtime init" without an Objective-C `+load`.
let sdkLoadedAt = Date()

enum AppStartLedger {
  static let file = "app-start.json"

  static func load(directory: URL) -> AppStartRecord? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
    return try? JSONDecoder().decode(AppStartRecord.self, from: data)
  }

  static func save(_ record: AppStartRecord, directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(record) { try? data.write(to: directory.appendingPathComponent(file), options: .atomic) }
  }
}

// MARK: - Automatic sessions

/// When automatic sessions start and end, as Sentry's mobile SDKs do: a session starts
/// when the app comes to the foreground; going to the background only notes the time, and
/// coming back after `timeout` seconds or more ends that session and starts a new one. A
/// return within the timeout continues the same session.
struct SessionTimeout: Sendable {
  enum Action: Equatable { case start, restart, keep }

  var timeout: Double
  private(set) var backgroundedAt: Double?
  private(set) var started = false

  init(timeout: Double) { self.timeout = max(0, timeout) }

  mutating func foreground(at time: Double) -> Action {
    defer { backgroundedAt = nil }
    guard started else {
      started = true
      return .start
    }
    if let backgroundedAt, time - backgroundedAt >= timeout { return .restart }
    return .keep
  }

  mutating func background(at time: Double) {
    if started && backgroundedAt == nil { backgroundedAt = time }
  }

  /// A session ended by hand: the next foreground starts one.
  mutating func ended() {
    started = false
    backgroundedAt = nil
  }
}
