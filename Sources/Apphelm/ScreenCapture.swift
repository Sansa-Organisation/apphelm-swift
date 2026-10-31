import Foundation

/// A readable screen name from a view controller's type name: generic arguments and a
/// trailing `ViewController` or `Controller` dropped (`CheckoutViewController` → `Checkout`).
/// Nil for a private type (a leading underscore) or an empty name.
func screenName(fromTypeName typeName: String) -> String? {
  var name = String(typeName.prefix { $0 != "<" })
  if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
  guard !name.isEmpty, !name.hasPrefix("_") else { return nil }
  if let suffix = ["ViewController", "Controller"].first(where: { name.hasSuffix($0) }), name.count > suffix.count {
    name = String(name.dropLast(suffix.count))
  }
  return name
}

/// Clients that autocapture screens, held weakly.
enum ScreenCapture {
  private static let lock = NSLock()
  private static let clients = NSHashTable<ApphelmClient>.weakObjects()

  static func register(_ client: ApphelmClient) {
    lock.withLock { clients.add(client) }
    #if canImport(UIKit) && !os(watchOS)
    installSwizzle()
    #endif
  }

  static func unregister(_ client: ApphelmClient) {
    lock.withLock { clients.remove(client) }
  }

  static func capture(_ name: String) {
    let targets = lock.withLock { clients.allObjects }
    for client in targets { client.screen(name) }
  }
}

/// Set on a view controller to name its screen, or to return nil to leave it out.
public protocol ApphelmScreenNaming {
  var apphelmScreenName: String? { get }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

private let swizzleOnce: Void = {
  let type = UIViewController.self
  guard let original = class_getInstanceMethod(type, #selector(UIViewController.viewDidAppear(_:))),
        let replacement = class_getInstanceMethod(type, #selector(UIViewController.apphelm_viewDidAppear(_:))) else { return }
  method_exchangeImplementations(original, replacement)
}()

extension ScreenCapture {
  static func installSwizzle() { _ = swizzleOnce }

  /// The screen a view controller is, or nil for containers, children of a screen, SwiftUI
  /// hosting controllers and the system's own controllers.
  @MainActor
  static func name(of controller: UIViewController) -> String? {
    if let named = controller as? ApphelmScreenNaming { return named.apphelmScreenName }
    if controller is UINavigationController || controller is UITabBarController || controller is UISplitViewController || controller is UIPageViewController { return nil }
    // A child inside another screen: that screen is the one counted.
    if let parent = controller.parent, !(parent is UINavigationController || parent is UITabBarController || parent is UISplitViewController || parent is UIPageViewController) { return nil }
    let typeName = String(describing: type(of: controller))
    if typeName.hasPrefix("UIHostingController") { return nil }
    let bundlePath = Bundle(for: type(of: controller)).bundlePath
    if bundlePath.contains("/System/Library/") || bundlePath.hasPrefix("/usr/lib") { return nil }
    return screenName(fromTypeName: typeName)
  }
}

extension UIViewController {
  @objc dynamic func apphelm_viewDidAppear(_ animated: Bool) {
    // The implementations are exchanged: this calls UIKit's viewDidAppear.
    apphelm_viewDidAppear(animated)
    if let name = ScreenCapture.name(of: self), !name.isEmpty { ScreenCapture.capture(name) }
  }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

private struct ApphelmClientKey: EnvironmentKey {
  static let defaultValue: ApphelmClient? = nil
}

extension EnvironmentValues {
  /// The client `.apphelmScreen` sends with: `.environment(\.apphelm, client)`.
  public var apphelm: ApphelmClient? {
    get { self[ApphelmClientKey.self] }
    set { self[ApphelmClientKey.self] = newValue }
  }
}

private struct ApphelmScreenModifier: ViewModifier {
  let name: String
  let properties: [String: Any]
  let client: ApphelmClient?
  @Environment(\.apphelm) private var environmentClient

  func body(content: Content) -> some View {
    content.onAppear {
      (client ?? environmentClient ?? ApphelmClient.latest)?.screen(name, properties: properties)
    }
  }
}

extension View {
  /// Send a `$screen` each time this view appears. The client is `client`, else the one in
  /// `\.apphelm`, else the client created most recently.
  public func apphelmScreen(_ name: String, properties: [String: Any] = [:], client: ApphelmClient? = nil) -> some View {
    modifier(ApphelmScreenModifier(name: name, properties: properties, client: client))
  }
}
#endif
