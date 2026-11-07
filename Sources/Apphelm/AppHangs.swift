import Darwin
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// App hang detection (Sentry's `enableAppHangTracking`): the main thread stopped answering
/// for `appHangTimeoutInterval` seconds or more while the app was in the foreground.
///
/// A background thread (`apphelm-app-hang`) wakes every fifth of the timeout and looks at the
/// main thread one of two ways:
/// - **Frames**, while the UIKit display link runs (Sentry's V2 tracker): how late frames were
///   over the last timeout (`FrameStats.delay`). One frame late for the whole window is a
///   **fully blocking** hang; several frames that together were late for 99% of it is a
///   **non-fully blocking** one (`enableReportNonFullyBlockingAppHangs`). The hang ends when
///   frames are late for less than 20% of the last two wake-ups.
/// - **Pings** otherwise (macOS, or `enableFramesTracking` off; Sentry's V1 tracker): a block
///   put on the main queue that has not run after the timeout is a fully blocking hang, which
///   ends when it runs.
///
/// When a hang is found, the main thread is suspended for a moment and its stack read
/// (`ThreadStacks.capture`), and the hang is written to `app-hang-active.json` beside the
/// crash reports with the scope at that moment, so a hang the app never comes out of (the
/// person or the watchdog kills it) is sent on the next launch as a fatal app hang. When it
/// ends, the file is deleted and the hang is sent as an error, with its duration. Nothing is
/// detected in the background, after the process was suspended, under a debugger (the
/// tracker is not started) or while paused (`pauseAppHangTracking`).
final class AppHangTracker: @unchecked Sendable {
  static let activeFile = "app-hang-active.json"

  enum Kind: String, Sendable {
    case fullyBlocking = "fully_blocking"
    case nonFullyBlocking = "non_fully_blocking"

    /// Sentry's exception types (SentryAppHangTypeMapper).
    func title(fatal: Bool) -> String {
      switch self {
      case .fullyBlocking: return fatal ? "Fatal App Hang Fully Blocked" : "App Hang Fully Blocked"
      case .nonFullyBlocking: return fatal ? "Fatal App Hang Non Fully Blocked" : "App Hang Non Fully Blocked"
      }
    }
  }

  /// A hang as found: what kind, the main thread's stack (`backtrace_symbols` lines) and the
  /// images its frames are in.
  struct Hang: Sendable {
    var kind: Kind
    var stack: [String]
    var images: [[String: String]]
  }

  /// How the tracker reads the main thread; tests drive their own.
  struct Target: @unchecked Sendable {
    /// The queue a ping is put on (the main queue).
    var queue: DispatchQueue
    /// The thread whose stack is read (the main thread).
    var thread: () -> thread_act_t?
    /// Frame timing, when a display link runs.
    var frames: FrameStats?
    /// Whether the app is in the foreground and active.
    var isForeground: @Sendable () -> Bool

    static var main: Target {
      Target(queue: .main, thread: { ThreadStacks.mainThreadPort }, frames: .shared, isForeground: { ApplicationActivity.isActive })
    }
  }

  let timeout: Double
  let reportNonFullyBlocking: Bool
  private let directory: URL?
  private let target: Target
  private let onEnded: @Sendable (Hang, ClosedRange<Double>) -> Void
  private let lock = NSLock()
  private var stopped = false
  private var paused = false
  private let stackBuffer = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)

  // Loop state, touched only by the tracker's thread (and pings, under the lock).
  private var pingSentAt: Double?
  private var pingAnsweredAt: Double?
  private var hanging: (kind: Kind, startedAt: Double, frames: Bool, hang: Hang)?
  private var quietUntil = 0.0

  init(timeout: Double, reportNonFullyBlocking: Bool, directory: URL?, target: Target = .main, onEnded: @escaping @Sendable (Hang, ClosedRange<Double>) -> Void) {
    self.timeout = timeout > 0 ? timeout : 2
    self.reportNonFullyBlocking = reportNonFullyBlocking
    self.directory = directory
    self.target = target
    self.onEnded = onEnded
  }

  deinit { stackBuffer.deallocate() }

  var sleepInterval: Double { timeout / 5 }

  func start() {
    let thread = Thread { [self] in run() }
    thread.name = "apphelm-app-hang"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  func stop() { lock.withLock { stopped = true } }
  func setPaused(_ value: Bool) { lock.withLock { paused = value } }

  private func run() {
    var lastWake = uptimeSeconds()
    while !lock.withLock({ stopped }) {
      usleep(useconds_t(sleepInterval * 1_000_000))
      let now = uptimeSeconds()
      // Woken far later than asked: the process was suspended, and that time is no hang.
      let suspended = now - lastWake > timeout + sleepInterval
      lastWake = now
      step(now: now, suspended: suspended)
    }
  }

  /// One wake-up. Internal so tests can step the tracker on their own clock.
  func step(now: Double, suspended: Bool = false) {
    if suspended || lock.withLock({ paused }) || !target.isForeground() {
      // A hang under way when the app left the foreground is not reported: the person moved on.
      if hanging != nil { abandon() }
      lock.withLock { pingSentAt = nil; pingAnsweredAt = nil }
      return
    }
    if let current = hanging {
      if hangEnded(current, now: now) { end(now: now) } else { persist(current.hang, startedAt: current.startedAt, now: now) }
      return
    }
    guard now >= quietUntil else { return }
    if let frames = target.frames, frames.running, let delay = frames.delay(from: now - timeout, to: now, now: now) {
      lock.withLock { pingSentAt = nil; pingAnsweredAt = nil }
      if delay.frames == 1 && delay.seconds >= timeout * 0.99 {
        begin(.fullyBlocking, startedAt: now - timeout, frames: true, now: now)
      } else if delay.frames > 1 && delay.seconds > timeout * 0.99 && reportNonFullyBlocking {
        begin(.nonFullyBlocking, startedAt: now - timeout, frames: true, now: now)
      }
      return
    }
    // No display link: ping the queue.
    let (sent, answered): (Double?, Double?) = lock.withLock { (pingSentAt, pingAnsweredAt) }
    if let sent, answered == nil {
      if now - sent >= timeout { begin(.fullyBlocking, startedAt: sent, frames: false, now: now) }
      return
    }
    lock.withLock { pingSentAt = now; pingAnsweredAt = nil }
    target.queue.async { [weak self] in
      guard let self else { return }
      self.lock.withLock { if self.pingSentAt == now { self.pingAnsweredAt = uptimeSeconds() } }
    }
  }

  private func hangEnded(_ current: (kind: Kind, startedAt: Double, frames: Bool, hang: Hang), now: Double) -> Bool {
    if current.frames {
      guard let frames = target.frames, frames.running else { return true }
      let window = 2 * sleepInterval
      guard let delay = frames.delay(from: now - window, to: now, now: now) else { return true }
      return delay.seconds < window * 0.2
    }
    return lock.withLock { pingAnsweredAt != nil }
  }

  private func begin(_ kind: Kind, startedAt: Double, frames: Bool, now: Double) {
    var addresses: [UInt64] = []
    if let thread = target.thread() {
      let depth = ThreadStacks.capture(thread, into: stackBuffer, maxDepth: 128)
      addresses = (0..<depth).map { stackBuffer[$0] }
    }
    let stack = ThreadStacks.symbolicate(addresses)
    let hang = Hang(kind: kind, stack: stack, images: DebugImages.referenced(by: Array(stack.prefix(40)), among: DebugImages.loaded()))
    hanging = (kind, startedAt, frames, hang)
    persist(hang, startedAt: startedAt, now: now)
  }

  private func end(now: Double) {
    guard let current = hanging else { return }
    hanging = nil
    removeFile()
    quietUntil = now + timeout
    let answered: Double? = lock.withLock {
      defer { pingSentAt = nil; pingAnsweredAt = nil }
      return pingAnsweredAt
    }
    onEnded(current.hang, Self.duration(startedAt: current.startedAt, endedBy: now, answeredAt: current.frames ? nil : answered, timeout: timeout, sleepInterval: sleepInterval))
  }

  /// How long a hang lasted, as a range. A ping says when the main thread came back, but it
  /// may have been blocked up to one wake-up before the ping was sent. Frames say the hang
  /// was over by `now`, at some point in the last two wake-ups.
  static func duration(startedAt: Double, endedBy now: Double, answeredAt: Double?, timeout: Double, sleepInterval: Double) -> ClosedRange<Double> {
    if let answeredAt {
      let blocked = max(timeout, answeredAt - startedAt)
      return blocked...(blocked + sleepInterval)
    }
    let high = max(timeout, now - startedAt)
    return max(timeout, high - 2 * sleepInterval)...high
  }

  private func abandon() {
    hanging = nil
    removeFile()
  }

  // MARK: The file a fatal hang is sent from

  private func removeFile() {
    guard let directory else { return }
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.activeFile))
  }

  /// Rewritten on every wake-up of a hang, so a fatal one knows how long it lasted.
  private func persist(_ hang: Hang, startedAt: Double, now: Double) {
    guard let directory else { return }
    let report: [String: Any] = [
      "kind": "apphang",
      "hang_type": hang.kind.rawValue,
      "stack": hang.stack,
      "images": hang.images,
      "duration_ms": Int(((now - startedAt) * 1000).rounded()),
      "timeout_ms": Int((timeout * 1000).rounded()),
      "run": CrashInstaller.currentRun ?? "",
      "at": ISO8601DateFormatter().string(from: Date()),
      "scope": jsonSafe(CrashScopeStore.shared.current() ?? [:]),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: report) else { return }
    try? data.write(to: directory.appendingPathComponent(Self.activeFile), options: .atomic)
  }

  /// Seconds as Sentry words a hang's duration: one decimal.
  static func seconds(_ value: Double) -> String { String(format: "%.1f", value) }

  /// The message of a hang that ended: "App hanging between 2.4 and 2.8 seconds." (Sentry's).
  static func message(duration: ClosedRange<Double>) -> String {
    let low = seconds(duration.lowerBound), high = seconds(duration.upperBound)
    return low == high ? "App hanging for \(low) seconds." : "App hanging between \(low) and \(high) seconds."
  }
}

/// Whether the app is in the foreground and active, for app-hang detection: on UIKit from
/// `didBecomeActive` / `willResignActive`; always true without UIKit (macOS).
enum ApplicationActivity {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var active = true
  nonisolated(unsafe) private static var observing = false

  static var isActive: Bool { lock.withLock { active } }
  static func set(_ value: Bool) { lock.withLock { active = value } }

  /// Start following the app's state (once).
  static func observe() {
    #if canImport(UIKit) && !os(watchOS)
    let first: Bool = lock.withLock {
      defer { observing = true }
      return !observing
    }
    guard first else { return }
    let begin: @Sendable () -> Void = {
      MainActor.assumeIsolated {
        set(sharedApplication()?.applicationState == .active)
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in set(true) }
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in set(false) }
      }
    }
    // Not active until the main thread says so.
    set(false)
    if Thread.isMainThread { begin() } else { DispatchQueue.main.async(execute: begin) }
    #endif
  }
}

/// Whether a debugger is attached to this process (`P_TRACED`), as Sentry checks before it
/// tracks app hangs or calls a termination a watchdog's.
func isDebuggerAttached() -> Bool {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
  guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
  return info.kp_proc.p_flag & P_TRACED != 0
}

// MARK: - The client side

extension ApphelmClient {
  private static let hangLock = NSLock()
  nonisolated(unsafe) private static var hangTracker: AppHangTracker?

  /// Start app-hang detection once per process (from `installCrashReporting`).
  func startAppHangTracking(directory: URL) {
    guard options.enableAppHangTracking, !isDebuggerAttached() else { return }
    let tracker: AppHangTracker? = Self.hangLock.withLock {
      guard Self.hangTracker == nil else { return nil }
      let made = AppHangTracker(timeout: options.appHangTimeoutInterval, reportNonFullyBlocking: options.enableReportNonFullyBlockingAppHangs, directory: directory) { [weak self] hang, duration in
        guard let self else { return }
        Task { await self.reportAppHang(hang, duration: duration) }
      }
      Self.hangTracker = made
      return made
    }
    guard let tracker else { return }
    ApplicationActivity.observe()
    tracker.start()
  }

  /// Stop detecting app hangs until `resumeAppHangTracking()`, around work you know blocks
  /// the main thread (Sentry's `pauseAppHangTracking`). A hang under way is dropped.
  public func pauseAppHangTracking() { Self.hangLock.withLock { Self.hangTracker }?.setPaused(true) }

  /// Detect app hangs again after `pauseAppHangTracking()`.
  public func resumeAppHangTracking() { Self.hangLock.withLock { Self.hangTracker }?.setPaused(false) }

  /// Send a hang that ended as an error event (`App Hang Fully Blocked` or `App Hang Non
  /// Fully Blocked`, mechanism `AppHang`, level `error`), with the main thread's stack at the
  /// hang, through the same gates as an exception. Returns whether it was sent.
  @discardableResult
  func reportAppHang(_ hang: AppHangTracker.Hang, duration: ClosedRange<Double>) async -> Bool {
    let name = hang.kind.title(fatal: false)
    let message = AppHangTracker.message(duration: duration)
    guard let eventId = admitError(type: name, message: message) else { return false }
    var properties: [String: Any] = ["message": message, "name": name, "level": "error", "$event_id": eventId]
    if !hang.stack.isEmpty { properties["stack"] = CrashInstaller.boundedStack(hang.stack) }
    if !hang.images.isEmpty { properties["debug_images"] = Array(hang.images.prefix(DebugImages.maxPerReport)) }
    properties["app_hang_duration_ms"] = Int((duration.upperBound * 1000).rounded())
    addContext(&properties, callTags: ["mechanism": "AppHang"], traceId: nil)
    return (try? await sendException(properties, eventId: eventId)) ?? false
  }
}
