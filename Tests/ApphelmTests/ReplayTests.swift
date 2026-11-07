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

private func recorder(_ outbox: Outbox, clock: TestClock = TestClock(), options: ReplayOptions = ReplayOptions(), identified: Bool = true, allowed: @escaping @Sendable () -> Bool = { true }, random: @escaping @Sendable () -> Double = { 0.5 }) -> ReplayRecorder {
  ReplayRecorder(options: options, workspaceId: "org_1", productId: "prd_1", now: { clock.now() },
    person: { .init(distinctId: "user-1", identified: identified) }, sessionHash: { "sess-1234-abcd" }, allowed: allowed, random: random,
    send: { outbox.send($0) })
}

/// A screen whose label says `text`, so each one is a new wireframe.
private func screen(label text: String) -> ReplayViewNode {
  var root = screen()
  root.children[0].text = text
  return root
}

/// Options for replay on error only: no whole recordings, every error uploads.
private func bufferOnly(_ rate: Double = 1, seconds: Double = 30) -> ReplayOptions {
  ReplayOptions(sessionSampleRate: 0, onErrorSampleRate: rate, errorBufferSeconds: seconds)
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

@Suite("Replay sampling and replay on error")
struct ReplayBufferTests {
  @Test("sessionSampleRate leaves a recording out: nothing is captured, built or sent")
  func sampledOut() async {
    let outbox = Outbox()
    let replay = recorder(outbox, options: ReplayOptions(sessionSampleRate: 0.2), random: { 0.5 })
    replay.setConsent(true)
    #expect(!replay.capture(screen(), width: 390, height: 844))
    replay.tap(x: 1, y: 1)
    await replay.flush()
    #expect(outbox.sent.isEmpty && replay.sessionId == nil && replay.eventCount == 0)
    #expect(replay.errorCaptured(isException: true) == nil)
    // Kept when the draw is under the rate.
    let kept = recorder(outbox, options: ReplayOptions(sessionSampleRate: 0.2), random: { 0.1 })
    kept.setConsent(true)
    #expect(kept.capture(screen(), width: 390, height: 844) && kept.sessionId != nil && !kept.isBuffering)
  }

  @Test("A buffer records into memory only: nothing is sent and it is no replay yet")
  func buffersInMemory() async {
    let outbox = Outbox()
    let replay = recorder(outbox, options: bufferOnly())
    replay.setConsent(true)
    #expect(replay.capture(screen(), width: 390, height: 844))
    replay.tap(x: 4, y: 4)
    await replay.flush()
    #expect(outbox.sent.isEmpty && replay.isBuffering && replay.sessionId == nil && replay.eventCount == 4)
    #expect(!replay.shouldFlush)
  }

  @Test("An exception uploads the last 30 seconds, starting with the screen shown then, and recording carries on")
  func errorUploadsBuffer() async throws {
    let outbox = Outbox()
    let clock = TestClock()
    let replay = recorder(outbox, clock: clock, options: bufferOnly())
    replay.screenChanged("Home")
    replay.setConsent(true)
    for second in 0..<10 {
      replay.capture(screen(label: "Screen \(second)"), width: 390, height: 844)
      clock.advance(5)
    }
    // 50 s recorded, the last screen at 45 s: what is older than 15 s is gone, and the screen
    // shown then (from 10 s) is carried to the start.
    let id = try #require(replay.errorCaptured(isException: true))
    #expect(!replay.isBuffering && replay.sessionId == id)
    await replay.flush()
    let body = try #require(outbox.sent.first)
    #expect(body["sessionId"] as? String == id && body["sequence"] as? Int == 0 && body["ended"] as? Bool == false && body["entryPath"] as? String == "/Home")
    let events = try #require(body["events"] as? [[String: Any]])
    #expect(events.prefix(3).map { $0["type"] as? String } == ["viewport", "navigation", "wireframe"])
    #expect(events.prefix(3).allSatisfy { $0["t"] as? Int == 0 })
    let times = events.compactMap { $0["t"] as? Int }
    #expect(times == times.sorted() && times.last! <= 30_000)
    let labels = events.compactMap { ($0["nodes"] as? [[String: Any]])?.first { $0["i"] as? Int == 2 }?["t"] as? String }
    #expect(labels == ["Screen 2", "Screen 3", "Screen 4", "Screen 5", "Screen 6", "Screen 7", "Screen 8", "Screen 9"])
    // The replay starts where the kept stretch does: 15 s in.
    #expect(body["startedAt"] as? String == "2027-01-15T08:00:15Z")
    // Recording continues as a whole recording, with the next sequence.
    replay.tap(x: 9, y: 9)
    await replay.flush()
    #expect(outbox.sent.count == 2 && outbox.sent[1]["sequence"] as? Int == 1 && outbox.sent[1]["sessionId"] as? String == id)
    let tap = try #require((outbox.sent[1]["events"] as? [[String: Any]])?.first)
    #expect(tap["t"] as? Int == 35_000)
    // A later error, or a message, links the same replay.
    #expect(replay.errorCaptured(isException: false) == id)
  }

  @Test("A message does not upload a buffer, and onErrorSampleRate draws per error")
  func messagesAndRate() {
    let draws = Draws([0.9, 0.9, 0.2])
    let replay = recorder(Outbox(), options: bufferOnly(0.5), random: { draws.next() })
    replay.setConsent(true)
    // The first draw is the session rate (0, so a buffer).
    replay.capture(screen(), width: 390, height: 844)
    #expect(replay.isBuffering)
    #expect(replay.errorCaptured(isException: false) == nil)
    #expect(replay.errorCaptured(isException: true) == nil && replay.isBuffering)
    #expect(replay.errorCaptured(isException: true) != nil && !replay.isBuffering)
  }

  @Test("A buffer holds at most about 2 MB, dropping the oldest wireframes first")
  func bufferBytes() {
    let clock = TestClock()
    let replay = recorder(Outbox(), clock: clock, options: bufferOnly())
    replay.setConsent(true)
    var root = ReplayViewNode(id: 1, x: 0, y: 0, width: 390, height: 844)
    for round in 0..<40 {
      root.children = (0..<2_900).map { ReplayViewNode(id: $0 + 2, kind: .text, x: 0, y: 0, width: 10, height: 10, text: "row \($0) of \(round)") }
      replay.capture(root, width: 390, height: 844)
      clock.advance(0.1)
    }
    #expect(replay.bufferedBytes <= ReplayRecorder.maxBufferBytes && replay.eventCount < 40)
  }

  @Test("A buffer is cleared after the session timeout in the background; a short visit keeps it")
  func backgroundClears() {
    let clock = TestClock()
    let replay = recorder(Outbox(), clock: clock, options: bufferOnly())
    replay.setConsent(true)
    replay.capture(screen(), width: 390, height: 844)
    replay.visibility(hidden: true)
    clock.advance(10)
    replay.visibility(hidden: false)
    #expect(replay.isBuffering && replay.eventCount == 5)
    replay.visibility(hidden: true)
    clock.advance(31)
    replay.visibility(hidden: false)
    #expect(!replay.isBuffering && replay.eventCount == 0)
    // The next screen starts a new buffer, not a whole recording.
    replay.capture(screen(), width: 390, height: 844)
    #expect(replay.isBuffering)
  }

  @Test("A buffer no error asked for is never sent, not even when the recording ends")
  func endedBufferDropped() async {
    let outbox = Outbox()
    let replay = recorder(outbox, options: bufferOnly())
    replay.setConsent(true)
    replay.capture(screen(), width: 390, height: 844)
    replay.personChanged()
    await replay.flush()
    #expect(outbox.sent.isEmpty && replay.pendingCount == 0)
  }

  @Test("A crash snapshot carries the buffer; the next launch uploads it at the crashed run's rate")
  func crashSnapshot() async throws {
    let outbox = Outbox()
    let replay = recorder(outbox, options: bufferOnly(0.5))
    #expect(replay.crashSnapshot() == nil)
    replay.setConsent(true)
    replay.capture(screen(), width: 390, height: 844)
    let data = try #require(replay.crashSnapshot())
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["buffering"] as? Bool == true && object["onErrorSampleRate"] as? Double == 0.5 && !String(decoding: data, as: UTF8.self).contains("hunter2"))
    // The next launch: drawn above the rate, not sent.
    let skipped = recorder(outbox, random: { 0.7 })
    #expect(await skipped.sendCrashReplay(data) == nil && outbox.sent.isEmpty)
    let next = recorder(outbox, random: { 0.3 })
    let id = await next.sendCrashReplay(data)
    #expect(id == object["sessionId"] as? String && outbox.sent.count == 1 && outbox.sent[0]["ended"] as? Bool == true && outbox.sent[0]["sequence"] as? Int == 0)
    // Opted out on the next launch: nothing.
    let optedOut = recorder(outbox, allowed: { false }, random: { 0 })
    #expect(await optedOut.sendCrashReplay(data) == nil && outbox.sent.count == 1)
  }

  @Test("A whole recording's crash snapshot is its unsent tail, ended, with the next sequence")
  func sessionSnapshot() async throws {
    let outbox = Outbox()
    let replay = recorder(outbox)
    replay.setConsent(true)
    replay.capture(screen(), width: 390, height: 844)
    await replay.flush()
    replay.tap(x: 2, y: 2)
    let data = try #require(replay.crashSnapshot())
    let next = recorder(outbox, random: { 0.99 })
    #expect(await next.sendCrashReplay(data) == replay.sessionId)
    #expect(outbox.sent.count == 2 && outbox.sent[1]["sequence"] as? Int == 1 && outbox.sent[1]["ended"] as? Bool == true)
    // Everything sent: the snapshot still links the crash to the recording, and sends nothing.
    await replay.flush()
    let sentAlready = try #require(replay.crashSnapshot())
    #expect(await next.sendCrashReplay(sentAlready) == replay.sessionId && outbox.sent.count == 3)
    // Withdrawn consent leaves no snapshot.
    replay.setConsent(false)
    #expect(replay.crashSnapshot() == nil)
  }
}

/// Random draws in order, then 0.5.
private final class Draws: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Double]
  init(_ values: [Double]) { self.values = values }
  func next() -> Double { lock.withLock { values.isEmpty ? 0.5 : values.removeFirst() } }
}
