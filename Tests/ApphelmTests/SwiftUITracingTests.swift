import Foundation
import Testing

@testable import Apphelm

private func load(_ recorder: Recorder, _ name: String) -> [String: Any]? {
  recorder.bodies.map { $0["properties"] as? [String: Any] ?? [:] }.first { $0["op"] as? String == "ui.load" && $0["name"] as? String == name }
}

private func spanOps(_ properties: [String: Any]) -> [String] {
  guard let text = properties["spans"] as? String else { return [] }
  return ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? []).compactMap { $0["op"] as? String }
}

@Suite("SwiftUI screen loads")
struct SwiftUITracingTests {
  func client(_ recorder: Recorder, rate: Double? = 1, fullDisplay: Bool = false) -> ApphelmClient {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", tracesSampleRate: rate).quiet
    options.enableTimeToFullDisplayTracing = fullDisplay
    return ApphelmClient(options: options, session: recorder.session(), store: MemoryStore())
  }

  @Test("A traced view starts one ui.load per view and sends ttid_ms at the first frame after it appears")
  func initialDisplay() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder)
    let screen = SwiftUIScreenLoad()
    screen.start("Basket", client: apphelm, waitForFullDisplay: nil)
    let transaction = try #require(screen.current)
    // The body built again, the view appearing again: still the one load.
    screen.start("Basket", client: apphelm, waitForFullDisplay: nil)
    #expect(screen.current === transaction)
    #expect(apphelm.activeTransaction === transaction)
    screen.appear()
    screen.appear()
    #expect(await eventually { load(recorder, "Basket") != nil })
    let properties = try #require(load(recorder, "Basket"))
    #expect(properties["ttid_ms"] is Int && properties["ttfd_ms"] == nil)
    #expect(spanOps(properties) == ["ui.load.initial_display"])
    #expect(recorder.bodies.filter { ($0["properties"] as? [String: Any])?["op"] as? String == "ui.load" }.count == 1)
  }

  @Test("A traced view inside a running transaction is a ui.load span of it")
  func nested() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder, fullDisplay: true)
    let outer = SwiftUIScreenLoad(), inner = SwiftUIScreenLoad()
    outer.start("Shop", client: apphelm, waitForFullDisplay: nil)
    inner.start("ProductGrid", client: apphelm, waitForFullDisplay: nil)
    #expect(inner.current == nil && inner.currentSpan != nil)
    inner.appear()
    outer.appear()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(apphelm.reportFullyDisplayed())
    #expect(await eventually { load(recorder, "Shop") != nil })
    let properties = try #require(load(recorder, "Shop"))
    let text = try #require(properties["spans"] as? String)
    let spans = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    #expect(spans.contains { $0["op"] as? String == "ui.load" && $0["description"] as? String == "ProductGrid" })
    #expect(load(recorder, "ProductGrid") == nil)
  }

  @Test("The next screen, once the last one is shown, starts its own load and ends that one")
  func nextScreen() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder, fullDisplay: true)
    let first = SwiftUIScreenLoad()
    first.start("Home", client: apphelm, waitForFullDisplay: nil)
    first.appear()
    let home = try #require(first.current)
    #expect(await eventually { apphelm.isShownScreenLoad(home) })
    let second = SwiftUIScreenLoad()
    second.start("Detail", client: apphelm, waitForFullDisplay: nil)
    #expect(second.current != nil && second.currentSpan == nil)
    #expect(await eventually { load(recorder, "Home") != nil })
    #expect(load(recorder, "Home")?["ttfd_ms"] == nil)
  }

  @Test("waitForFullDisplay keeps it open for reportFullyDisplayed; no rate, no load")
  func fullDisplay() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder)
    let screen = SwiftUIScreenLoad()
    screen.start("Orders", client: apphelm, waitForFullDisplay: true)
    screen.appear()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(load(recorder, "Orders") == nil)
    #expect(apphelm.reportFullyDisplayed())
    #expect(await eventually { load(recorder, "Orders") != nil })
    let properties = try #require(load(recorder, "Orders"))
    #expect(properties["ttid_ms"] is Int && properties["ttfd_ms"] is Int)
    #expect(Set(spanOps(properties)) == ["ui.load.initial_display", "ui.load.full_display"])

    let untraced = Recorder()
    let none = SwiftUIScreenLoad()
    none.start("Orders", client: client(untraced, rate: nil), waitForFullDisplay: nil)
    #expect(none.current == nil)
  }
}

#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// Runs on an iOS simulator (`xcodebuild test`), not in `swift test` on macOS.
@Suite("SwiftUI screen loads in a window")
struct SwiftUIHostedTests {
  @MainActor
  @Test(".apphelmTrace on a hosted view sends its ui.load with ttid_ms")
  func hosted() async throws {
    let recorder = Recorder()
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", tracesSampleRate: 1).quiet
    options.enableTimeToFullDisplayTracing = false
    let apphelm = ApphelmClient(options: options, session: recorder.session(), store: MemoryStore())
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    window.rootViewController = UIHostingController(rootView: ApphelmTracedView("Wishlist", client: apphelm) { Text("Saved for later") })
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    await waitFor { load(recorder, "Wishlist") != nil }
    let properties = try #require(load(recorder, "Wishlist"))
    #expect(properties["ttid_ms"] is Int)
    #expect(spanOps(properties).contains("ui.load.initial_display"))
    window.isHidden = true
    withExtendedLifetime(apphelm) {}
  }

  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
  }
}
#endif
