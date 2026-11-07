#if canImport(UIKit) && !os(watchOS)
import QuartzCore
import UIKit

/// The UIKit side of the mobile measurements and automatic breadcrumbs: a `CADisplayLink`
/// counting frames and timing first frames, `viewDidLoad`/`viewDidAppear` swizzling for
/// automatic screen loads, `UIApplication.sendAction` swizzling for `ui.click` breadcrumbs,
/// memory warnings, and the app start. What each decides is in MobileVitals.swift and the
/// client, so `swift test` covers it on macOS.
enum UIKitInstrumentation {
  private static let lock = NSLock()
  private static let clients = NSHashTable<ApphelmClient>.weakObjects()
  private static let breadcrumbClients = NSHashTable<ApphelmClient>.weakObjects()
  private static let screenClients = NSHashTable<ApphelmClient>.weakObjects()

  static func install(_ client: ApphelmClient, options: ApphelmOptions) {
    // Automatic tracing is off until a trace sample rate or sampler is set.
    let tracing = client.tracingConfigured
    let screenLoads = options.enableUIViewControllerTracing && tracing && options.enableSwizzling
    let appStart = options.enableAppStartTracking && tracing
    let needsFrames = options.enableFramesTracking || appStart || screenLoads
    lock.withLock {
      clients.add(client)
      if options.enableAutoBreadcrumbs { breadcrumbClients.add(client) }
      if screenLoads { screenClients.add(client) }
    }
    // Read on the main thread when the client is made there (the usual place, during launch).
    let launchedInBackground: Bool? = Thread.isMainThread ? MainActor.assumeIsolated { sharedApplication().map { $0.applicationState == .background } } : nil
    let onMain: @Sendable () -> Void = { [weak client] in
      MainActor.assumeIsolated {
        if needsFrames { FrameTracker.shared.start(counting: options.enableFramesTracking) }
        if screenLoads { installScreenLoadSwizzle() }
        if options.enableAutoBreadcrumbs {
          if options.enableSwizzling { installSendActionSwizzle() }
          MemoryWarnings.observe()
        }
        if appStart, let client {
          AppStartObserver.observe(client, launchedInBackground: launchedInBackground ?? (sharedApplication()?.applicationState == .background))
        }
      }
    }
    if Thread.isMainThread { onMain() } else { DispatchQueue.main.async(execute: onMain) }
  }

  static var breadcrumbTargets: [ApphelmClient] { lock.withLock { breadcrumbClients.allObjects } }
  static var screenTargets: [ApphelmClient] { lock.withLock { screenClients.allObjects } }
}

// MARK: - Frames

/// One display link for the process. Each tick is a frame; the time since the previous tick
/// is that frame's duration, and the time to the next expected tick the display's refresh
/// interval (it changes with ProMotion). The first tick after the app returns from the
/// background is not counted: its gap is time spent away, not a frozen frame.
@MainActor
final class FrameTracker: NSObject {
  static let shared = FrameTracker()
  private var link: CADisplayLink?
  private var previous: CFTimeInterval?
  private var tokens: [NSObjectProtocol] = []

  func start(counting: Bool) {
    if counting { FrameStats.shared.setCounting(true) }
    guard link == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
    FrameStats.shared.setRunning(true)
    let center = NotificationCenter.default
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
      tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.previous = nil }
        FrameStats.shared.restartTimeline()
      })
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    let now = link.timestamp
    var expected = link.targetTimestamp - link.timestamp
    if expected <= 0 {
      let fps = Double(max(1, UIScreen.main.maximumFramesPerSecond))
      expected = 1 / fps
    }
    let duration = previous.map { now - $0 }
    previous = now
    FrameStats.shared.tick(duration: duration, expected: expected, at: Date(), uptime: now)
  }
}

// MARK: - App start

@MainActor
enum AppStartObserver {
  private static var observing = false
  private static var token: NSObjectProtocol?

  /// The first time the app becomes active, wait for the next frame and report the start.
  static func observe(_ client: ApphelmClient, launchedInBackground: Bool) {
    guard !observing else { return }
    observing = true
    let report: @Sendable () -> Void = { [weak client] in
      guard let client else { return }
      afterNextFrame {
        let firstFrame = Date()
        Task { await client.reportAppStart(firstFrame: firstFrame, launchedInBackground: launchedInBackground, directory: client.crashFolder) }
      }
    }
    if sharedApplication()?.applicationState == .active {
      report()
      return
    }
    token = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
      }
      report()
    }
  }
}

// MARK: - Memory warnings

@MainActor
enum MemoryWarnings {
  private static var token: NSObjectProtocol?

  static func observe() {
    guard token == nil else { return }
    token = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
      for client in UIKitInstrumentation.breadcrumbTargets {
        client.addBreadcrumb(Breadcrumb(category: "device.event", message: "Low memory", level: .warning))
      }
    }
  }
}

// MARK: - Screen loads

private var screenLoadKey: UInt8 = 0

private let screenLoadSwizzleOnce: Void = {
  let type = UIViewController.self
  for (original, replacement) in [(#selector(UIViewController.viewDidLoad), #selector(UIViewController.apphelm_tracing_viewDidLoad)),
                                  (#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.apphelm_tracing_viewDidAppear(_:)))] {
    guard let from = class_getInstanceMethod(type, original), let to = class_getInstanceMethod(type, replacement) else { continue }
    method_exchangeImplementations(from, to)
  }
}()

@MainActor
func installScreenLoadSwizzle() { _ = screenLoadSwizzleOnce }

/// The screen-load transactions one view controller started, one per tracing client.
private final class ScreenLoadBox: NSObject {
  let loads: [(client: ApphelmClient, transaction: Transaction)]
  init(_ loads: [(client: ApphelmClient, transaction: Transaction)]) { self.loads = loads }
}

extension UIViewController {
  @objc dynamic func apphelm_tracing_viewDidLoad() {
    // The implementations are exchanged: this calls UIKit's viewDidLoad. The screen load
    // starts first, so the work viewDidLoad does is inside it.
    let targets = UIKitInstrumentation.screenTargets
    if !targets.isEmpty, let name = ScreenCapture.name(of: self), !name.isEmpty {
      let loads = targets.map { (client: $0, transaction: $0.screenLoadStarted(name)) }
      objc_setAssociatedObject(self, &screenLoadKey, ScreenLoadBox(loads), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    apphelm_tracing_viewDidLoad()
  }

  @objc dynamic func apphelm_tracing_viewDidAppear(_ animated: Bool) {
    apphelm_tracing_viewDidAppear(animated)
    guard let box = objc_getAssociatedObject(self, &screenLoadKey) as? ScreenLoadBox else { return }
    objc_setAssociatedObject(self, &screenLoadKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    let loads = box.loads
    // Time to initial display: the first frame drawn after the screen appeared.
    afterNextFrame {
      for load in loads { load.client.screenLoadFirstFrame(load.transaction) }
    }
  }
}

// MARK: - ui.click

private let sendActionSwizzleOnce: Void = {
  let type = UIApplication.self
  guard let original = class_getInstanceMethod(type, #selector(UIApplication.sendAction(_:to:from:for:))),
        let replacement = class_getInstanceMethod(type, #selector(UIApplication.apphelm_sendAction(_:to:from:for:))) else { return }
  method_exchangeImplementations(original, replacement)
}()

@MainActor
func installSendActionSwizzle() { _ = sendActionSwizzleOnce }

extension UIApplication {
  /// A `ui.click` breadcrumb for each control action: the action's name and the target's
  /// type, and the sender's accessibility identifier when it has one. Never a label's text.
  @objc dynamic func apphelm_sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: UIEvent?) -> Bool {
    let handled = apphelm_sendAction(action, to: target, from: sender, for: event)
    let targets = UIKitInstrumentation.breadcrumbTargets
    if !targets.isEmpty {
      let receiver = target.map { String(describing: type(of: $0)) } ?? "first responder"
      var message = "\(NSStringFromSelector(action)) on \(receiver)"
      var data: [String: String] = ["action": NSStringFromSelector(action)]
      if let view = sender as? UIView, let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
        message += " (\(identifier))"
        data["view"] = identifier
      }
      for client in targets { client.addBreadcrumb(Breadcrumb(category: "ui.click", message: message, data: data)) }
    }
    return handled
  }
}
#endif
