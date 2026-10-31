import Foundation
import Testing

@testable import Apphelm

/// A hand-moved clock.
private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)
  func now() -> Date { lock.withLock { current } }
  func advance(_ seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Bodies a recorder sent, answered with `result`.
private final class Outbox: @unchecked Sendable {
  private let lock = NSLock()
  private var bodies: [Data] = []
  var result: ReplaySendResult = .done
  var sent: [[String: Any]] { lock.withLock { bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } } }
  var raw: [String] { lock.withLock { bodies.map { String(decoding: $0, as: UTF8.self) } } }
  func send(_ body: Data) -> ReplaySendResult { lock.withLock { bodies.append(body); return result } }
}

private func screen(fieldText: String = "hunter2", secure: Bool = true) -> ReplayViewNode {
  var root = ReplayViewNode(id: 1, x: 0, y: 0, width: 390, height: 844, background: "#FFFFFF")
  root.children = [
    ReplayViewNode(id: 2, kind: .text, x: 16.4, y: 60.6, width: 200, height: 24, foreground: "#111111", text: "Welcome back", fontSize: 17.2),
    ReplayViewNode(id: 3, kind: .input, x: 16, y: 100, width: 358, height: 44, border: "#cccccc", borderWidth: 1, cornerRadius: 8, text: "ada@example.com"),
    ReplayViewNode(id: 4, kind: .input, x: 16, y: 160, width: 358, height: 44, text: fieldText, isSecure: secure),
    ReplayViewNode(id: 5, kind: .button, x: 16, y: 220, width: 358, height: 50, background: "#0a84ff", foreground: "#ffffff", text: "Sign in", children: [ReplayViewNode(id: 9, kind: .text, x: 20, y: 230, width: 50, height: 20, text: "Sign in")]),
    ReplayViewNode(id: 6, kind: .toggle, x: 16, y: 290, width: 51, height: 31, isOn: true),
  ]
  return root
}

private func recorder(_ outbox: Outbox, clock: TestClock = TestClock(), options: ReplayOptions = ReplayOptions(), identified: Bool = true, allowed: @escaping @Sendable () -> Bool = { true }) -> ReplayRecorder {
  ReplayRecorder(options: options, workspaceId: "org_1", productId: "prd_1", now: { clock.now() },
    person: { .init(distinctId: "user-1", identified: identified) }, sessionHash: { "sess-1234-abcd" }, allowed: allowed,
    send: { outbox.send($0) })
}

@Suite("Wireframe replay")
struct ReplayTests {
  @Test("A wireframe has the collector's keys, rounded points and paint order, parents first")
  func shape() throws {
    let nodes = WireframeBuilder.build(screen(), screenWidth: 390, screenHeight: 844, options: ReplayOptions())
    #expect(nodes.map(\.i) == [1, 2, 3, 4, 5, 6])
    let json = String(decoding: try replayEncoder().encode(nodes), as: UTF8.self)
    #expect(json.hasPrefix(##"[{"bg":"#ffffff","h":844,"i":1,"k":"view","w":390,"x":0,"y":0},{"fg":"#111111","fs":17,"h":24,"i":2,"k":"text","t":"Welcome back","w":200,"x":16,"y":61}"##))
    #expect(json.contains(##"{"bc":"#cccccc","bw":1,"h":44,"i":3,"k":"input","r":8,"t":"***************","w":358,"x":16,"y":100}"##))
    #expect(json.contains(#""k":"toggle","on":true"#))
  }

  @Test("A password field is always eight asterisks, never its value or length, whatever the options")
  func password() throws {
    var options = ReplayOptions(maskAllTextInputs: false)
    options.maskAllText = false
    for value in ["hunter2", "a-much-longer-secret-value-here", ""] {
      let nodes = WireframeBuilder.build(screen(fieldText: value), screenWidth: 390, screenHeight: 844, options: options)
      #expect(nodes.first { $0.i == 4 }?.t == "********")
      let json = String(decoding: try replayEncoder().encode(nodes), as: UTF8.self)
      if !value.isEmpty { #expect(!json.contains(value)) }
    }
  }

  @Test("Text inputs are masked by default and shown only when the app turns masking off")
  func inputs() {
    let masked = WireframeBuilder.build(screen(), screenWidth: 390, screenHeight: 844, options: ReplayOptions())
    #expect(masked.first { $0.i == 3 }?.t == String(repeating: "*", count: 15))
    let open = WireframeBuilder.build(screen(), screenWidth: 390, screenHeight: 844, options: ReplayOptions(maskAllTextInputs: false))
    #expect(open.first { $0.i == 3 }?.t == "ada@example.com")
    let long = WireframeBuilder.build(screen(fieldText: String(repeating: "x", count: 80), secure: false), screenWidth: 390, screenHeight: 844, options: ReplayOptions())
    #expect(long.first { $0.i == 4 }?.t == String(repeating: "*", count: 30))
  }

  @Test("maskAllText and a mask marker turn labels and titles into asterisks")
  func maskAllText() {
    let all = WireframeBuilder.build(screen(), screenWidth: 390, screenHeight: 844, options: ReplayOptions(maskAllText: true))
    #expect(all.first { $0.i == 2 }?.t == "************" && all.first { $0.i == 5 }?.t == "*******")
    var marked = screen()
    marked.mask = true
    let inherited = WireframeBuilder.build(marked, screenWidth: 390, screenHeight: 844, options: ReplayOptions())
    #expect(inherited.first { $0.i == 2 }?.t == "************")
  }

  @Test("A blocked view is an empty box: nothing inside it is recorded")
  func blocked() throws {
    var root = screen()
    root.children[0].noCapture = true
    root.children[0].children = [ReplayViewNode(id: 77, kind: .text, x: 20, y: 62, width: 100, height: 20, text: "Card 4242")]
    let nodes = WireframeBuilder.build(root, screenWidth: 390, screenHeight: 844, options: ReplayOptions())
    let box = try #require(nodes.first { $0.i == 2 })
    #expect(box.k == .blocked && box.t == nil && box.fg == nil)
    #expect(!nodes.contains { $0.i == 77 })
    #expect(!String(decoding: try replayEncoder().encode(nodes), as: UTF8.self).contains("Card"))
  }

  @Test("Hidden, transparent, empty and off-screen views are left out; fields and buttons have no children")
  func skipped() {
    var root = screen()
    root.children.append(ReplayViewNode(id: 20, x: 0, y: 0, width: 10, height: 10, hidden: true, children: [ReplayViewNode(id: 21, x: 0, y: 0, width: 5, height: 5)]))
    root.children.append(ReplayViewNode(id: 22, x: 0, y: 0, width: 10, height: 10, alpha: 0))
    root.children.append(ReplayViewNode(id: 23, x: 500, y: 0, width: 10, height: 10))
    root.children.append(ReplayViewNode(id: 24, x: 0, y: 0, width: 0, height: 0, children: [ReplayViewNode(id: 25, x: 1, y: 1, width: 5, height: 5, alpha: 0.5)]))
    let nodes = WireframeBuilder.build(root, screenWidth: 390, screenHeight: 844, options: ReplayOptions())
    let ids = Set(nodes.map(\.i))
    #expect(!ids.contains(20) && !ids.contains(21) && !ids.contains(22) && !ids.contains(23) && !ids.contains(24) && !ids.contains(9))
    #expect(nodes.first { $0.i == 25 }?.o == 0.5)
  }

  @Test("At most 3,000 nodes, and text cut at 500 characters")
  func bounds() {
    var root = ReplayViewNode(id: 1, x: 0, y: 0, width: 390, height: 844)
    root.children = (0..<4_000).map { ReplayViewNode(id: $0 + 2, kind: .text, x: 0, y: 0, width: 10, height: 10, text: String(repeating: "a", count: 900)) }
    let nodes = WireframeBuilder.build(root, screenWidth: 390, screenHeight: 844, options: ReplayOptions())
    #expect(nodes.count == 3_000 && nodes[1].t?.count == 500)
  }

  @Test("Screen names become safe paths, and sign-in, checkout and payment screens are never recorded")
  func paths() {
    #expect(replayPath("Order Details") == "/Order_Details")
    #expect(replayPath("/settings/profile") == "/settings/profile")
    #expect(replayPath("Café Menu") == "/Caf__Menu")
    #expect(replayPath(String(repeating: "a", count: 300)).count == 120)
    #expect(isBlockedReplayPath("/Checkout") && isBlockedReplayPath("/login") && isBlockedReplayPath("/Payment/Card") && !isBlockedReplayPath("/Cart"))
    #expect(isBlockedReplayPath("/Vault", extra: ["Vault"]))
  }

  @Test("Nothing is captured or sent without replay consent, or while opted out")
  func consent() async {
    let outbox = Outbox()
    let replay = recorder(outbox)
    #expect(!replay.capture(screen(), width: 390, height: 844))
    replay.tap(x: 10, y: 10)
    await replay.flush()
    #expect(outbox.sent.isEmpty && replay.sessionId == nil)
    let optedOut = recorder(outbox, allowed: { false })
    optedOut.setConsent(true)
    #expect(!optedOut.capture(screen(), width: 390, height: 844))
    await optedOut.flush()
    #expect(outbox.sent.isEmpty)
  }

  @Test("The same screen twice adds one wireframe; a change adds another")
  func changes() {
    let replay = recorder(Outbox())
    replay.setConsent(true)
    #expect(replay.capture(screen(), width: 390, height: 844))
    #expect(!replay.capture(screen(), width: 390, height: 844))
    var changed = screen()
    changed.children[0].text = "Welcome back, Ada"
    #expect(replay.capture(changed, width: 390, height: 844))
    // navigation, viewport, two wireframes
    #expect(replay.eventCount == 4)
  }

  @Test("A chunk is the collector's envelope: ids, mode, platform, masking, person and events in order")
  func envelope() async throws {
    let outbox = Outbox()
    let clock = TestClock()
    let replay = recorder(outbox, clock: clock)
    replay.screenChanged("Order Details")
    replay.setConsent(true)
    replay.capture(screen(), width: 390.4, height: 844)
    clock.advance(1.25)
    replay.tap(x: 20.6, y: 240.2)
    clock.advance(1)
    replay.screenChanged("Cart")
    await replay.flush()
    let body = try #require(outbox.sent.first)
    #expect((body["sessionId"] as? String)?.range(of: "^rpl_[a-f0-9]{32}$", options: .regularExpression) != nil)
    #expect(body["workspaceId"] as? String == "org_1" && body["productId"] as? String == "prd_1" && body["sequence"] as? Int == 0)
    #expect(body["mode"] as? String == "mobile" && body["platform"] as? String == "ios" && body["maskingVersion"] as? String == "mobile_wireframe_v1")
    #expect(body["consentPolicyVersion"] as? String == "sdk_consent_v1" && body["entryPath"] as? String == "/Order_Details" && body["ended"] as? Bool == false)
    #expect(body["startedAt"] as? String == "2027-01-15T08:00:00Z")
    #expect(body["sessionHash"] as? String == "sess-1234-abcd")
    #expect(NSDictionary(dictionary: body["viewport"] as? [String: Any] ?? [:]).isEqual(to: ["width": 390, "height": 844]))
    #expect(NSDictionary(dictionary: body["person"] as? [String: Any] ?? [:]).isEqual(to: ["distinctHash": "f5537974", "distinctHash2": "34443f86", "identified": true]))
    let events = try #require(body["events"] as? [[String: Any]])
    #expect(events.map { $0["type"] as? String } == ["navigation", "viewport", "wireframe", "click", "navigation"])
    #expect(events.map { $0["t"] as? Int } == [0, 0, 0, 1250, 2250])
    #expect(events[3]["x"] as? Int == 21 && events[3]["y"] as? Int == 240 && events[4]["path"] as? String == "/Cart")
    #expect(!outbox.raw[0].contains("hunter2") && !outbox.raw[0].contains("ada@example.com"))
    // The next chunk carries the next sequence.
    replay.tap(x: 1, y: 1)
    await replay.flush()
    #expect(outbox.sent.count == 2 && outbox.sent[1]["sequence"] as? Int == 1 && outbox.sent[1]["sessionId"] as? String == body["sessionId"] as? String)
  }

  @Test("Checkout screens are paused: no wireframe, tap or navigation is kept there")
  func blockedScreen() {
    let replay = recorder(Outbox())
    replay.setConsent(true)
    replay.screenChanged("Home")
    replay.capture(screen(), width: 390, height: 844)
    let before = replay.eventCount
    replay.screenChanged("Checkout")
    #expect(!replay.capture(screen(fieldText: "4242"), width: 390, height: 844))
    replay.tap(x: 5, y: 5)
    #expect(replay.eventCount == before)
  }

  @Test("Withdrawing consent stops at once and discards what was not sent, retries included")
  func withdraw() async {
    let outbox = Outbox()
    outbox.result = .retry
    let replay = recorder(outbox)
    replay.setConsent(true)
    replay.capture(screen(), width: 390, height: 844)
    await replay.flush()
    #expect(replay.pendingCount == 1)
    replay.capture(screen(fieldText: "x", secure: false), width: 390, height: 844)
    replay.setConsent(false)
    #expect(replay.pendingCount == 0 && replay.eventCount == 0 && replay.sessionId == nil)
    outbox.result = .done
    await replay.flush()
    #expect(outbox.sent.count == 1)
  }

  @Test("A chunk that could not be delivered is sent again with the same sequence")
  func retry() async {
    let outbox = Outbox()
    outbox.result = .retry
    let replay = recorder(outbox)
    replay.setConsent(true)
    replay.capture(screen(), width: 390, height: 844)
    await replay.flush()
    outbox.result = .done
    replay.tap(x: 3, y: 3)
    await replay.flush()
    #expect(outbox.sent.map { $0["sequence"] as? Int } == [0, 0, 1])
    #expect(replay.pendingCount == 0)
  }

  @Test("A reset ends the recording; back after 30 minutes away starts a new one")
  func endings() async {
    let outbox = Outbox()
    let clock = TestClock()
    let replay = recorder(outbox, clock: clock)
    replay.setConsent(true)
    replay.capture(screen(), width: 390, height: 844)
    let first = replay.sessionId
    replay.personChanged()
    await replay.flush()
    #expect(outbox.sent.last?["ended"] as? Bool == true && replay.sessionId == nil)
    replay.capture(screen(), width: 390, height: 844)
    let second = replay.sessionId
    #expect(second != nil && second != first)
    replay.visibility(hidden: true)
    clock.advance(31 * 60)
    replay.visibility(hidden: false)
    #expect(replay.sessionId == nil)
    await replay.flush()
    #expect(outbox.sent.last?["ended"] as? Bool == true)
  }

  @Test("The client sends replay with the project key and origin, and never with a server key")
  func client() async throws {
    let host = "replay-\(UUID().uuidString.lowercased()).test"
    final class Seen: @unchecked Sendable { let lock = NSLock(); var requests: [URLRequest] = [] }
    let seen = Seen()
    RoutedURLProtocol.register(host: host) { request in
      seen.lock.withLock { seen.requests.append(request) }
      return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(#"{"accepted":true}"#.utf8))
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    var options = ApphelmOptions(apiKey: "ahl_live_server", baseURL: "https://\(host)/", workspaceId: "org_1", productId: "prd_1", distinctId: "user-1").quiet
    options.replay = ReplayOptions(projectKey: "ahl_pub_mobile", origin: "https://app.shop.example")
    let client = ApphelmClient(options: options, session: session)
    #expect(!client.isReplayActive)
    client.setReplayConsent(true)
    #expect(client.isReplayActive)
    client.screen("Home")
    client.replayRecorderForTests?.capture(screen(), width: 390, height: 844)
    await client.flushReplay()
    let request = try #require(seen.lock.withLock { seen.requests.first })
    #expect(request.url?.path == "/api/replay" && request.value(forHTTPHeaderField: "x-apphelm-key") == "ahl_pub_mobile" && request.value(forHTTPHeaderField: "origin") == "https://app.shop.example")
    #expect(request.value(forHTTPHeaderField: "authorization") == nil)
    let body = try requestJSON(request)
    #expect(body["entryPath"] as? String == "/Home" && (body["person"] as? [String: Any])?["identified"] as? Bool == true)

    var serverKey = options
    serverKey.replay = ReplayOptions(projectKey: "ahl_live_server", origin: "https://app.shop.example")
    let refused = ApphelmClient(options: serverKey, session: session)
    refused.setReplayConsent(true)
    #expect(!refused.isReplayActive)
    refused.replayRecorderForTests?.capture(screen(), width: 390, height: 844)
    await refused.flushReplay()
    #expect(seen.lock.withLock { seen.requests.count } == 1)
  }
}
