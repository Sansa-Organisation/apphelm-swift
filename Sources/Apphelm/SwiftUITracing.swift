import Foundation

/// One SwiftUI view's screen load: started the first time the view's body is built, given
/// its initial display at the first frame after the view appeared. The same `ui.load`
/// transaction the UIKit swizzle produces (`ttid_ms`, a `ui.load.initial_display` span, and
/// with full-display waiting `ttfd_ms` from `reportFullyDisplayed()`, at most 30 s).
/// Platform-independent so `swift test` covers it; the SwiftUI glue is below.
final class SwiftUIScreenLoad: @unchecked Sendable {
  private let lock = NSLock()
  private var transaction: Transaction?
  private var span: Span?
  private weak var client: ApphelmClient?
  private var started = false
  private var appeared = false

  /// The first body build: the load starts (once per view, however often the body is built
  /// again). Nothing without a trace sample rate or sampler, as for UIKit screen loads. Inside
  /// a transaction already running (an outer traced view's, a UIKit screen load, your own),
  /// it is a `ui.load` span of that one instead, ended at its first frame, as Sentry's
  /// traced view is.
  func start(_ name: String, client: ApphelmClient?, waitForFullDisplay: Bool?) {
    let first: Bool = lock.withLock {
      defer { started = true }
      return !started
    }
    guard first, let client, client.options.enabled, client.tracingConfigured else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // A screen load that already drew its first frame (waiting for full display) is the
    // previous screen: the new view starts its own load, which ends that one.
    if let running = client.activeTransaction, !running.isFinished, !client.isShownScreenLoad(running) {
      let child = running.startSpan("ui.load", description: trimmed)
      lock.withLock {
        span = child
        self.client = client
      }
      return
    }
    let made = client.screenLoadStarted(trimmed, waitForFullDisplay: waitForFullDisplay)
    lock.withLock {
      transaction = made
      self.client = client
    }
  }

  /// The view appeared: its initial display is the next frame drawn (once).
  func appear() {
    let load: (ApphelmClient, Transaction?, Span?)? = lock.withLock {
      guard !appeared, let client, transaction != nil || span != nil else { return nil }
      appeared = true
      return (client, transaction, span)
    }
    guard let (client, transaction, span) = load else { return }
    afterNextFrame {
      span?.finish()
      if let transaction { client.screenLoadFirstFrame(transaction) }
    }
  }

  var current: Transaction? { lock.withLock { transaction } }
  var currentSpan: Span? { lock.withLock { span } }
}

#if canImport(SwiftUI)
import SwiftUI

private struct ApphelmTraceModifier: ViewModifier {
  let name: String
  let waitForFullDisplay: Bool?
  let client: ApphelmClient?
  @Environment(\.apphelm) private var environmentClient
  @State private var load = SwiftUIScreenLoad()

  func body(content: Content) -> some View {
    load.start(name, client: client ?? environmentClient ?? ApphelmClient.latest, waitForFullDisplay: waitForFullDisplay)
    return content.onAppear { load.appear() }
  }
}

extension View {
  /// Time this view's load as a `ui.load` transaction named `name`, the SwiftUI counterpart
  /// of the UIKit screen-load swizzle (Sentry's `.sentryTrace`): it starts the first time the
  /// view's body is built and records `ttid_ms` (and a `ui.load.initial_display` span) at the
  /// first frame after the view appears. With `waitForFullDisplay` (default:
  /// `enableTimeToFullDisplayTracing`) it stays open until `reportFullyDisplayed()` for
  /// `ttfd_ms`, at most 30 s. Needs `tracesSampleRate` or `tracesSampler`. One load per view;
  /// it doesn't send a `$screen` (add `.apphelmScreen(name)` for that). The client is
  /// `client`, else the one in `\.apphelm`, else the client created most recently.
  public func apphelmTrace(_ name: String, waitForFullDisplay: Bool? = nil, client: ApphelmClient? = nil) -> some View {
    modifier(ApphelmTraceModifier(name: name, waitForFullDisplay: waitForFullDisplay, client: client))
  }
}

/// A view whose content's load is timed as a `ui.load` transaction (Sentry's
/// `SentryTracedView`): `ApphelmTracedView("Checkout") { CheckoutView() }`. The same as
/// `.apphelmTrace("Checkout")` on the content.
public struct ApphelmTracedView<Content: View>: View {
  private let name: String
  private let waitForFullDisplay: Bool?
  private let client: ApphelmClient?
  private let content: () -> Content

  public init(_ name: String, waitForFullDisplay: Bool? = nil, client: ApphelmClient? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.name = name
    self.waitForFullDisplay = waitForFullDisplay
    self.client = client
    self.content = content
  }

  public var body: some View {
    content().apphelmTrace(name, waitForFullDisplay: waitForFullDisplay, client: client)
  }
}
#endif
