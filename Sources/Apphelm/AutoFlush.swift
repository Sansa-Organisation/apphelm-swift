import Foundation

/// A repeating timer the client flushes on. Injected in tests.
protocol RepeatingTimer: AnyObject, Sendable {
  func cancel()
}

typealias RepeatingTimerFactory = @Sendable (_ interval: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> any RepeatingTimer

final class DispatchRepeatingTimer: RepeatingTimer, @unchecked Sendable {
  private let source: DispatchSourceTimer

  init(interval: TimeInterval, fire: @escaping @Sendable () -> Void) {
    source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
    source.setEventHandler(handler: fire)
    source.resume()
  }

  func cancel() { source.cancel() }

  deinit { source.cancel() }
}

let dispatchTimerFactory: RepeatingTimerFactory = { interval, fire in DispatchRepeatingTimer(interval: interval, fire: fire) }

/// The app's version and build, from the main bundle by default.
struct AppInfo: Sendable, Equatable {
  var version: String
  var build: String

  static func main() -> AppInfo {
    let info = Bundle.main.infoDictionary ?? [:]
    return AppInfo(version: info["CFBundleShortVersionString"] as? String ?? "", build: info["CFBundleVersion"] as? String ?? "")
  }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// UIApplication without `UIApplication.shared`, which app extensions can't call.
@MainActor
func sharedApplication() -> UIApplication? {
  let selector = NSSelectorFromString("sharedApplication")
  guard UIApplication.responds(to: selector) else { return nil }
  return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
}

/// Watches the app going to the background and becoming active.
final class LifecycleObserver: @unchecked Sendable {
  private var tokens: [NSObjectProtocol] = []

  init(client: ApphelmClient) {
    let center = NotificationCenter.default
    tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak client] _ in
      client?.applicationDidBecomeActive()
    })
    tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak client] _ in
      MainActor.assumeIsolated { client?.applicationDidEnterBackground(finish: BackgroundTask.begin()) }
    })
    // Created after the app became active (a lazy client): that launch counts as opened.
    DispatchQueue.main.async { [weak client] in
      MainActor.assumeIsolated {
        if sharedApplication()?.applicationState == .active { client?.applicationDidBecomeActive() }
      }
    }
  }

  deinit {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
  }
}

/// Background time to finish a flush after the app leaves the screen.
enum BackgroundTask {
  @MainActor
  static func begin() -> @Sendable () -> Void {
    guard let app = sharedApplication() else { return {} }
    final class Box: @unchecked Sendable {
      let lock = NSLock()
      var id: UIBackgroundTaskIdentifier = .invalid
      func take() -> UIBackgroundTaskIdentifier { lock.withLock { defer { id = .invalid }; return id } }
    }
    let box = Box()
    @MainActor func endNow() {
      let id = box.take()
      if id != .invalid { sharedApplication()?.endBackgroundTask(id) }
    }
    // The expiration handler runs on the main thread and must end the task before it returns.
    let id = app.beginBackgroundTask(withName: "apphelm.flush") { MainActor.assumeIsolated { endNow() } }
    box.lock.withLock { box.id = id }
    let end: @Sendable () -> Void = { DispatchQueue.main.async { MainActor.assumeIsolated { endNow() } } }
    return end
  }
}
#endif
