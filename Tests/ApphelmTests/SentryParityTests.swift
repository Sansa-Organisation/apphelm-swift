import Foundation
import Testing

@testable import Apphelm

private func folder() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-sentry-tests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A session whose requests to `host` answer 200 (or 404 for `/missing`), for outgoing calls.
private func apiSession(host: String) -> URLSession {
  RoutedURLProtocol.register(host: host) { request in
    try jsonResponse(url: request.url!, status: request.url?.path == "/missing" ? 404 : 200, body: ["ok": true])
  }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [RoutedURLProtocol.self]
  return URLSession(configuration: configuration)
}

/// Wait until `condition` holds (work finished from a detached task), at most two seconds.
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
}

private func parsedSpans(_ properties: [String: Any]) -> [[String: Any]] {
  guard let text = properties["spans"] as? String else { return [] }
  return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? []
}

@Suite("Sentry parity: errors, scope, breadcrumbs, mobile measurements")
struct SentryParityTests {
  func options(_ recorder: Recorder, release: String? = "ios@3.0.0", configure: (inout ApphelmOptions) -> Void = { _ in }) -> ApphelmOptions {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: release, environment: "production").quiet
    configure(&options)
    return options
  }

  func client(_ options: ApphelmOptions, _ recorder: Recorder, frames: FrameStats = FrameStats(), scope: CrashScopeStore = CrashScopeStore(), app: AppInfo = AppInfo(version: "3.0.0", build: "300")) -> ApphelmClient {
    ApphelmClient(options: options, session: recorder.session(), store: MemoryStore(), installStore: nil, attributionToken: { nil }, appInfo: app, frames: frames, crashScope: scope)
  }

  func events(_ recorder: Recorder, _ name: String) -> [[String: Any]] {
    recorder.bodies.filter { $0["eventName"] as? String == name }.map { $0["properties"] as? [String: Any] ?? [:] }
  }

  // MARK: Breadcrumbs

  @Test("Breadcrumbs: bounded buffer, the last 30 sent with three fields, URLs stripped, categories cleaned")
  func breadcrumbBasics() {
    let buffer = BreadcrumbBuffer(capacity: 3)
    for index in 0..<5 { buffer.add(Breadcrumb(category: "c", message: "m\(index)")) }
    #expect(buffer.all.map(\.message) == ["m2", "m3", "m4"])

    let start = Date(timeIntervalSince1970: 1_772_600_767.25)
    let crumbs = (0..<40).map { Breadcrumb(category: "x", message: "\($0)", level: .warning, data: ["k": "v"], timestamp: start.addingTimeInterval(Double($0))) }
    let wire = breadcrumbWire(crumbs.reversed())
    #expect(wire.count == 30)
    #expect(wire.first?["message"] == "10" && wire.last?["message"] == "39")
    #expect(wire.allSatisfy { Set($0.keys) == ["at", "category", "message"] })
    #expect(wire.first?["at"] == "2026-03-04T05:06:17.250Z")

    #expect(strippingURLQueries("GET https://user:pw@api.example.com/v1/cart?token=abc#frag 200") == "GET https://api.example.com/v1/cart 200")
    #expect(strippingURLQueries("open myapp://orders/7?ref=push now") == "open myapp://orders/7 now")
    #expect(strippingURLQueries("no url here?really") == "no url here?really")
    #expect(breadcrumbMessage(String(repeating: "a", count: 300)).count == 200)
    #expect(breadcrumbCategory("UI Click!") == "ui_click")
    #expect(breadcrumbCategory("app.lifecycle") == "app.lifecycle")
    #expect(breadcrumbCategory("") == "default")
    #expect(breadcrumbCategory(String(repeating: "a", count: 30)).count == 20)
  }

  @Test("Exceptions carry breadcrumbs (manual, navigation, http), after beforeBreadcrumb; maxBreadcrumbs 0 keeps none")
  func breadcrumbsOnExceptions() async throws {
    struct Failed: Error {}
    let recorder = Recorder()
    let api = "api-\(UUID().uuidString.lowercased()).test"
    let apphelm = client(options(recorder) { options in
      options.beforeBreadcrumb = { crumb in
        if crumb.category == "secret" { return nil }
        var changed = crumb
        if crumb.category == "custom" { changed.message += " (seen)" }
        return changed
      }
    }, recorder)
    apphelm.addBreadcrumb(category: "custom", message: "Opened cart", level: .info, data: ["items": "3"])
    apphelm.addBreadcrumb(category: "secret", message: "dropped")
    apphelm.screen("Checkout")
    _ = try await apphelm.data(for: URLRequest(url: URL(string: "https://\(api)/v1/cart?token=abc")!), session: apiSession(host: api))
    _ = try await apphelm.data(for: URLRequest(url: URL(string: "https://\(api)/missing")!), session: apiSession(host: api))
    #expect(try await apphelm.captureException(Failed()))
    let crumbs = try #require(events(recorder, "$exception").first?["breadcrumbs"] as? [[String: String]])
    #expect(crumbs.map { $0["category"] ?? "" } == ["custom", "navigation", "http", "http"])
    #expect(crumbs[0]["message"] == "Opened cart (seen)")
    #expect(crumbs[1]["message"] == "Checkout")
    #expect(crumbs[2]["message"] == "GET https://\(api)/v1/cart 200")
    #expect(crumbs[3]["message"] == "GET https://\(api)/missing 404")

    let none = Recorder()
    let quiet = client(options(none) { $0.maxBreadcrumbs = 0 }, none)
    quiet.addBreadcrumb(category: "custom", message: "kept?")
    try await quiet.captureException(Failed())
    #expect(events(none, "$exception").first?["breadcrumbs"] == nil)

    let off = Recorder()
    let manualOnly = client(options(off) { $0.enableAutoBreadcrumbs = false }, off)
    manualOnly.screen("Checkout")
    try await manualOnly.captureMessage("hello")
    #expect(events(off, "$exception").first?["breadcrumbs"] == nil)
  }

  // MARK: Scope

  @Test("setTag and setUser go on exceptions as tags and user_hash; the call's tags win; bad keys are ignored")
  func globalScope() async throws {
    struct Failed: Error {}
    #expect(hashUserId("usr_42") == "45ad255503a478ea96fc68ec658a483a")
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder)
    apphelm.setTag("plan", "pro")
    apphelm.setTag("beta", true)
    apphelm.setTag("screen", "home")
    apphelm.setTag("bad key!", "x")
    apphelm.setTag("gone", "x")
    apphelm.setTag("gone", nil)
    apphelm.setUser(id: "usr_42")
    try await apphelm.captureException(Failed(), tags: ["screen": "checkout"])
    let first = events(recorder, "$exception")[0]
    let tags = try #require(first["tags"] as? [String: Any])
    #expect(tags["plan"] as? String == "pro" && tags["beta"] as? Bool == true && tags["screen"] as? String == "checkout")
    #expect(tags["bad key!"] == nil && tags["gone"] == nil)
    #expect(first["user_hash"] as? String == "45ad255503a478ea96fc68ec658a483a")
    #expect(!String(data: try JSONSerialization.data(withJSONObject: recorder.bodies[0]), encoding: .utf8)!.contains("usr_42"))
    apphelm.setUser(id: nil)
    try await apphelm.captureException(Failed())
    #expect(events(recorder, "$exception")[1]["user_hash"] == nil)
  }

  @Test("withScope: tags, user, breadcrumbs and transaction only for events captured inside it, child tasks included")
  func taskScope() async throws {
    struct Failed: Error {}
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder)
    apphelm.setTag("plan", "pro")
    apphelm.setUser(id: "usr_1")
    apphelm.addBreadcrumb(category: "global", message: "before")
    let scoped = apphelm.startTransaction("Job", op: "queue.process")
    let tx = apphelm.startTransaction("Other")
    try await apphelm.withScope { scope in
      scope.setTag("order", "ord_9")
      scope.setTag("plan", "team")
      scope.setUser(id: "usr_42")
      scope.transaction = scoped
      apphelm.addBreadcrumb(category: "job", message: "step 1")
      #expect(apphelm.activeTransaction === scoped)
      try await apphelm.withScope { inner in
        inner.setTag("attempt", 2)
        // A child task inherits the scope.
        _ = try await Task { try await apphelm.captureException(Failed()) }.value
      }
    }
    #expect(apphelm.activeTransaction === tx)
    try await apphelm.captureException(Failed())

    let inside = events(recorder, "$exception")[0]
    let tags = try #require(inside["tags"] as? [String: Any])
    #expect(tags["order"] as? String == "ord_9" && tags["plan"] as? String == "team" && (tags["attempt"] as? NSNumber)?.intValue == 2)
    #expect(inside["user_hash"] as? String == "45ad255503a478ea96fc68ec658a483a")
    #expect(inside["trace_id"] as? String == scoped.traceId)
    let crumbs = (inside["breadcrumbs"] as? [[String: String]] ?? []).map { $0["message"] ?? "" }
    #expect(crumbs == ["before", "step 1"])

    let outside = events(recorder, "$exception")[1]
    #expect(outside["tags"] as? [String: String] == ["plan": "pro"])
    #expect(outside["user_hash"] as? String == hashUserId("usr_1"))
    #expect(outside["trace_id"] as? String == tx.traceId)
    #expect((outside["breadcrumbs"] as? [[String: String]] ?? []).map { $0["message"] ?? "" } == ["before"])
    // The synchronous form returns the closure's value.
    #expect(apphelm.withScope { _ in 7 } == 7)
  }

  // MARK: captureMessage and beforeSend

  @Test("captureMessage sends a levelled message with the scope, session and fingerprint, and no stack")
  func captureMessage() async throws {
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder)
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try #require(apphelm.startSession(directory: directory))
    apphelm.setTag("plan", "pro")
    #expect(try await apphelm.captureMessage("Cart sync fell back to cache", level: .warning, fingerprint: ["cart-fallback"], tags: ["store": "eu"]))
    let message = events(recorder, "$exception")[0]
    #expect(message["name"] as? String == "Message")
    #expect(message["message"] as? String == "Cart sync fell back to cache")
    #expect(message["level"] as? String == "warning")
    #expect(message["fingerprint"] as? [String] == ["cart-fallback"])
    #expect(message["tags"] as? [String: String] == ["plan": "pro", "store": "eu"])
    #expect(message["session_hash"] as? String == session)
    #expect(message["release"] as? String == "ios@3.0.0")
    #expect(message["stack"] == nil && message["handled"] == nil)
    apphelm.optOut()
    #expect(try await apphelm.captureMessage("ignored") == false)
  }

  @Test("beforeSend sees every event with its name, can change or drop it, and a non-JSON result drops it")
  func beforeSend() async throws {
    let recorder = Recorder()
    let seen = Seen()
    let apphelm = client(options(recorder) { options in
      options.beforeSend = { properties in
        let name = properties["$event_name"] as? String ?? "?"
        seen.add(name)
        if name == "drop_me" || properties["message"] as? String == "drop" || properties["name"] as? String == "DroppedTx" { return nil }
        if name == "bad" { return ["value": Date()] }
        var changed = properties
        changed["$event_name"] = "renamed"
        changed["scrubbed"] = true
        return changed
      }
    }, recorder)
    apphelm.track("kept", properties: ["a": 1])
    apphelm.track("drop_me")
    apphelm.track("bad")
    apphelm.screen("Home")
    apphelm.identify("person-1")
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    apphelm.startSession(directory: directory)
    await apphelm.flush()
    #expect(try await apphelm.captureMessage("keep"))
    #expect(try await apphelm.captureMessage("drop") == false)
    #expect(await apphelm.startTransaction("Load").finish())
    #expect(await apphelm.startTransaction("DroppedTx").finish() == false)

    #expect(seen.all.sorted() == ["$exception", "$exception", "$identify", "$screen", "$session", "$transaction", "$transaction", "bad", "drop_me", "kept"])
    let names = recorder.bodies.map { $0["eventName"] as? String ?? "" }
    #expect(names == ["kept", "$screen", "$identify", "$session", "$exception", "$transaction"])
    // The hook can't rename an event, and its changes are sent.
    #expect(recorder.properties(0)["$event_name"] == nil && recorder.properties(0)["scrubbed"] as? Bool == true && recorder.properties(0)["a"] as? Int == 1)
    #expect(recorder.properties(5)["scrubbed"] as? Bool == true)
  }

  @Test("A crash report beforeSend drops is deleted and not counted as sent")
  func beforeSendDropsCrash() async throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("\(CrashStore.signalPrefix)11 SIGSEGV\n0   Shop   0x0000000100003f00 checkoutTotal + 32\n".utf8).write(to: directory.appendingPathComponent("crash-\(UUID().uuidString).log"))
    let recorder = Recorder()
    let apphelm = client(options(recorder) { $0.beforeSend = { $0["$event_name"] as? String == "$exception" ? nil : $0 } }, recorder)
    #expect(await apphelm.sendPendingCrashReports(directory: directory) == 0)
    #expect(recorder.bodies.isEmpty)
    #expect(CrashInstaller.pendingReports(directory: directory).isEmpty)
  }

  // MARK: Crash scope

  @Test("The crash scope is written beside the crash file and the next launch sends it with the crash")
  func crashScope() async throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CrashScopeStore()
    store.attach(directory: directory)
    let recorder = Recorder()
    let crashing = client(options(recorder), recorder, scope: store)
    crashing.useCrashDirectory(directory)
    crashing.setTag("plan", "pro")
    crashing.setUser(id: "usr_42")
    crashing.addBreadcrumb(category: "navigation", message: "Checkout")
    let session = try #require(crashing.startSession())
    store.drain()
    let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(CrashScopeStore.activeFile))) as? [String: Any])
    #expect(written["session_hash"] as? String == session && written["user_hash"] as? String == hashUserId("usr_42"))

    // The run crashes: a signal report is left, and the next launch moves both aside.
    try Data("\(CrashStore.signalPrefix)11 SIGSEGV\n0   Shop   0x0000000100003f00 checkoutTotal + 32\n".utf8).write(to: directory.appendingPathComponent(CrashStore.activeFile))
    try CrashInstaller.moveAsideActiveReport(directory: directory)
    let next = Recorder()
    let launch = client(options(next, release: "ios@3.1.0"), next)
    #expect(await launch.sendPendingCrashReports(directory: directory) == 1)
    let crash = try #require(events(next, "$exception").first)
    #expect(crash["session_hash"] as? String == session)
    #expect(crash["release"] as? String == "ios@3.0.0")
    #expect(crash["user_hash"] as? String == hashUserId("usr_42"))
    #expect(crash["tags"] as? [String: String] == ["mechanism": "signal", "plan": "pro"])
    #expect((crash["breadcrumbs"] as? [[String: String]])?.map { $0["message"] ?? "" } == ["Checkout"])
    #expect(crash["handled"] as? Bool == false)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    #expect(!left.contains { $0.hasPrefix("scope-") && $0 != CrashScopeStore.activeFile })
  }

  // MARK: Automatic sessions

  @Test("Automatic sessions: one per foreground, kept across a short background, a new one after 30 s")
  func automaticSessions() async throws {
    var timeout = SessionTimeout(timeout: 30)
    #expect(timeout.foreground(at: 0) == .start)
    timeout.background(at: 10)
    #expect(timeout.foreground(at: 39.9) == .keep)
    timeout.background(at: 50)
    timeout.background(at: 70) // a second background keeps the first time
    #expect(timeout.foreground(at: 80) == .restart)
    timeout.ended()
    #expect(timeout.foreground(at: 81) == .start)

    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder)
    apphelm.useCrashDirectory(directory)
    let now = Date()
    apphelm.autoSessionForeground(now: now)
    let first = try #require(apphelm.sessionId)
    apphelm.autoSessionBackground(now: now.addingTimeInterval(5))
    apphelm.autoSessionForeground(now: now.addingTimeInterval(20))
    #expect(apphelm.sessionId == first)
    apphelm.autoSessionBackground(now: now.addingTimeInterval(30))
    apphelm.autoSessionForeground(now: now.addingTimeInterval(61))
    let second = try #require(apphelm.sessionId)
    #expect(second != first)
    await apphelm.flush()
    #expect(events(recorder, "$session").map { $0["session_hash"] as? String ?? "" } == [first, second])
    #expect(SessionLedger.load(directory: directory).first { $0.hash == first }?.endedAt != nil)

    // No release, no sessions.
    let none = Recorder()
    let unreleased = client(options(none, release: nil), none)
    unreleased.autoSessionForeground()
    #expect(unreleased.sessionId == nil)
  }

  // MARK: Tracing

  @Test("Spans take data and nest; the transaction takes data and measurements")
  func spanData() async throws {
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder)
    let tx = apphelm.startTransaction("Sync")
    tx.setData("sync.kind", "full")
    tx.setMeasurement("items_loaded", value: 12)
    tx.setMeasurement("Bad-Name", value: 1)
    let query = tx.startSpan("db.sql.query", description: "SELECT * FROM carts WHERE id = ?", data: ["db.system": "sqlite", "ignored": [1, 2]])
    let cache = query.startChild("cache.get", description: "cart:7", data: ["cache.key": "cart:7"])
    cache.setData("cache.hit", true)
    cache.finish()
    query.finish()
    #expect(await tx.finish())
    let properties = recorder.properties(0)
    #expect(properties["data"] as? [String: String] == ["sync.kind": "full"])
    #expect(properties["items_loaded"] as? Int == 12 && properties["Bad-Name"] == nil)
    let spans = parsedSpans(properties)
    let db = try #require(spans.first { $0["op"] as? String == "db.sql.query" })
    let get = try #require(spans.first { $0["op"] as? String == "cache.get" })
    #expect(db["data"] as? [String: String] == ["db.system": "sqlite"])
    #expect(get["parent_span_id"] as? String == query.spanId && db["parent_span_id"] as? String == tx.spanId)
    #expect((get["data"] as? [String: Any])?["cache.hit"] as? Bool == true)
  }

  @Test("HTTP spans carry method, status code, server.address and url.full without the query")
  func httpSpanData() async throws {
    let recorder = Recorder()
    let api = "api-\(UUID().uuidString.lowercased()).test"
    let apphelm = client(options(recorder), recorder)
    let tx = apphelm.startTransaction("Checkout")
    _ = try await apphelm.data(for: URLRequest(url: URL(string: "https://\(api):8443/v1/cart?token=abc#x")!), session: apiSession(host: api))
    apphelm.recordHTTPSpan(method: "post", url: URL(string: "https://\(api)/v1/pay?card=1"), statusCode: 502, interval: DateInterval(start: Date(), duration: 0.2))
    #expect(await tx.finish())
    let spans = parsedSpans(recorder.properties(0))
    #expect(spans.count == 2)
    let get = try #require(spans.first?["data"] as? [String: Any])
    #expect(get["http.request.method"] as? String == "GET")
    #expect(get["http.response.status_code"] as? Int == 200)
    #expect(get["server.address"] as? String == api)
    #expect(get["url.full"] as? String == "https://\(api):8443/v1/cart")
    let post = try #require(spans.last?["data"] as? [String: Any])
    #expect(post["http.request.method"] as? String == "POST" && post["http.response.status_code"] as? Int == 502)
    #expect(post["url.full"] as? String == "https://\(api)/v1/pay")
    #expect(spans.last?["status"] as? String == "error")
  }

  @Test("A sentry-trace header is continued when there is no traceparent; tracesSampler decides new traces")
  func sentryTraceAndSampler() async throws {
    #expect(parseSentryTrace("4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1")?.sampled == true)
    #expect(parseSentryTrace("4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7")?.sampled == nil)
    #expect(parseSentryTrace("4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-2") == nil)
    #expect(parseSentryTrace("00000000000000000000000000000000-00f067aa0ba902b7-1") == nil)
    let recorder = Recorder()
    let apphelm = client(options(recorder) { options in
      options.tracesSampleRate = 1
      options.tracesSampler = { context in context.op == "ui.load" ? 0 : nil }
    }, recorder)
    let joined = apphelm.startTransaction("GET /cart", op: "http.server", traceparent: "4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0")
    #expect(joined.traceId == "4bf92f3577b34da6a3ce929d0e0e4736" && !joined.sampled)
    // The caller's decision wins over the sampler.
    let forced = apphelm.startTransaction("Home", op: "ui.load", traceparent: "4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1")
    #expect(forced.sampled)
    #expect(await forced.finish())
    #expect(recorder.properties(0)["parent_span_id"] as? String == "00f067aa0ba902b7")
    #expect(!apphelm.startTransaction("Home", op: "ui.load").sampled)
    #expect(apphelm.startTransaction("Sync", op: "task").sampled)
  }

  // MARK: Frames

  @Test("Frames: slow is a missed refresh at the display's rate, frozen is over 700 ms, and transactions carry the counts")
  func frames() async throws {
    var counts = FrameCounts()
    counts.record(duration: 1.0 / 60, expected: 1.0 / 60)
    counts.record(duration: 1.0 / 60 + 0.0004, expected: 1.0 / 60) // jitter
    counts.record(duration: 2.0 / 60, expected: 1.0 / 60) // one missed refresh
    counts.record(duration: 1.0 / 60, expected: 1.0 / 120) // slow on ProMotion
    counts.record(duration: 0.8, expected: 1.0 / 60) // frozen, not also slow
    #expect(counts == FrameCounts(total: 5, slow: 2, frozen: 1))

    let stats = FrameStats()
    stats.setRunning(true)
    stats.setCounting(true)
    stats.tick(duration: 1.0 / 60, expected: 1.0 / 60, at: Date()) // before the transaction
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder, frames: stats)
    let tx = apphelm.startTransaction("Feed", op: "ui.load")
    for duration in [1.0 / 60, 1.0 / 60, 0.05, 1.2] { stats.tick(duration: duration, expected: 1.0 / 60, at: Date()) }
    #expect(await tx.finish())
    let properties = recorder.properties(0)
    #expect(properties["frames_total"] as? Int == 4 && properties["frames_slow"] as? Int == 1 && properties["frames_frozen"] as? Int == 1)

    // Without a display link nothing is added.
    let idle = Recorder()
    let quiet = client(options(idle), idle, frames: FrameStats())
    #expect(await quiet.startTransaction("Feed").finish())
    #expect(idle.properties(0)["frames_total"] == nil)
    // A frame callback fires once, at the next tick.
    let fired = Seen()
    #expect(stats.onNextFrame { _ in fired.add("frame") })
    stats.tick(duration: nil, expected: 1.0 / 60, at: Date())
    stats.tick(duration: nil, expected: 1.0 / 60, at: Date())
    #expect(fired.all == ["frame"])
    #expect(!FrameStats().onNextFrame { _ in })
  }

  // MARK: TTID / TTFD

  @Test("An automatic screen load sends ttid_ms at its first frame, or waits for reportFullyDisplayed for ttfd_ms")
  func screenLoads() async throws {
    let time = PinnedClock()
    let recorder = Recorder()
    let apphelm = client(options(recorder) { $0.tracesSampleRate = 1 }, recorder)
    let tx = apphelm.screenLoadStarted("Checkout", clock: time.clock)
    time.advance(ms: 180)
    apphelm.screenLoadFirstFrame(tx)
    await waitUntil { !recorder.bodies.isEmpty }
    let first = recorder.properties(0)
    #expect(first["op"] as? String == "ui.load" && first["name"] as? String == "Checkout")
    #expect(first["ttid_ms"] as? Int == 180 && first["ttfd_ms"] == nil)
    #expect(parsedSpans(first).first?["op"] as? String == "ui.load.initial_display")

    let waiting = Recorder()
    let full = client(options(waiting) { $0.enableTimeToFullDisplayTracing = true; $0.tracesSampleRate = 1 }, waiting)
    let load = full.screenLoadStarted("Feed", clock: time.clock)
    time.advance(ms: 100)
    full.screenLoadFirstFrame(load)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(waiting.bodies.isEmpty)
    time.advance(ms: 400)
    #expect(full.reportFullyDisplayed())
    await waitUntil { !waiting.bodies.isEmpty }
    let feed = waiting.properties(0)
    #expect(feed["ttid_ms"] as? Int == 100 && feed["ttfd_ms"] as? Int == 500)
    #expect(Set(parsedSpans(feed).compactMap { $0["op"] as? String }) == ["ui.load.initial_display", "ui.load.full_display"])
    #expect(!full.reportFullyDisplayed())

    // Fully displayed before the first frame: full display is the first frame.
    let early = full.screenLoadStarted("Profile", clock: time.clock)
    time.advance(ms: 50)
    #expect(full.reportFullyDisplayed())
    time.advance(ms: 70)
    full.screenLoadFirstFrame(early)
    await waitUntil { waiting.bodies.count == 2 }
    #expect(waiting.properties(1)["ttid_ms"] as? Int == 120 && waiting.properties(1)["ttfd_ms"] as? Int == 120)

    // Never reported: the deadline finishes it without ttfd_ms.
    let late = full.screenLoadStarted("Settings", clock: time.clock)
    full.screenLoadFirstFrame(late)
    full.screenLoadDeadline(late)
    await waitUntil { waiting.bodies.count == 3 }
    #expect(waiting.properties(2)["ttid_ms"] != nil && waiting.properties(2)["ttfd_ms"] == nil)
  }

  @Test("startScreen takes reportFullyDisplayed as ttfd_ms and still finishes when you finish it")
  func manualScreenFullDisplay() async throws {
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder)
    let tx = apphelm.startScreen("Orders")
    #expect(apphelm.reportFullyDisplayed())
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(events(recorder, "$transaction").isEmpty)
    #expect(await tx.finish())
    #expect(events(recorder, "$transaction").first?["ttfd_ms"] != nil)
    #expect(!apphelm.reportFullyDisplayed())
  }

  // MARK: App start

  @Test("App start rules: cold after install, update or reboot; warm otherwise and when prewarmed; none in the background or past 180 s")
  func appStartRules() throws {
    let process = Date(timeIntervalSince1970: 1_000)
    let frame = process.addingTimeInterval(1.25)
    let current = AppStartRecord(bootTime: 500, version: "3.0.0", build: "300")
    func classify(previous: AppStartRecord?, prewarmed: Bool = false, background: Bool = false, firstFrame: Date = frame) -> AppStart? {
      AppStartRules.classify(processStart: process, sdkLoaded: process.addingTimeInterval(0.9), firstFrame: firstFrame, prewarmed: prewarmed, launchedInBackground: background, previous: previous, current: current)
    }
    #expect(classify(previous: nil) == AppStart(type: .cold, start: process, durationMs: 1250))
    #expect(classify(previous: current)?.type == .warm)
    #expect(classify(previous: AppStartRecord(bootTime: 500.4, version: "3.0.0", build: "300"))?.type == .warm)
    #expect(classify(previous: AppStartRecord(bootTime: 500, version: "2.9.0", build: "300"))?.type == .cold)
    #expect(classify(previous: AppStartRecord(bootTime: 500, version: "3.0.0", build: "299"))?.type == .cold)
    #expect(classify(previous: AppStartRecord(bootTime: 100, version: "3.0.0", build: "300"))?.type == .cold)
    #expect(classify(previous: nil, prewarmed: true) == AppStart(type: .warm, start: process.addingTimeInterval(0.9), durationMs: 350))
    #expect(classify(previous: current, background: true) == nil)
    #expect(classify(previous: current, firstFrame: process.addingTimeInterval(181)) == nil)
    #expect(classify(previous: current, firstFrame: process.addingTimeInterval(-1)) == nil)

    // The kernel's answers are sane on this machine.
    let started = try #require(processStartDate())
    #expect(started <= Date() && started > Date().addingTimeInterval(-86_400))
    #expect(try #require(bootTime()) < started.timeIntervalSince1970)
  }

  @Test("An app start is sent as an app.start.cold transaction, then warm on the next launch")
  func appStartTransaction() async throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = Recorder()
    let apphelm = client(options(recorder) { $0.tracesSampleRate = 1 }, recorder)
    let process = Date(timeIntervalSince1970: 1_772_600_767.25)
    #expect(await apphelm.reportAppStart(firstFrame: process.addingTimeInterval(0.842), launchedInBackground: false, directory: directory, processStart: process, prewarmed: false, boot: 42, oncePerProcess: false))
    let cold = recorder.properties(0)
    #expect(recorder.bodies[0]["eventName"] as? String == "$transaction")
    #expect(cold["op"] as? String == "app.start.cold" && cold["name"] as? String == "App Start Cold")
    #expect(cold["app_start_cold_ms"] as? Int == 842 && cold["duration_ms"] as? Int == 842)
    #expect(cold["started_at"] as? String == "2026-03-04T05:06:07.250Z")
    #expect(parsedSpans(cold).first?["op"] as? String == "app.start.cold")
    #expect(await apphelm.reportAppStart(firstFrame: process.addingTimeInterval(0.3), launchedInBackground: false, directory: directory, processStart: process, prewarmed: false, boot: 42, oncePerProcess: false))
    #expect(recorder.properties(1)["op"] as? String == "app.start.warm" && recorder.properties(1)["app_start_warm_ms"] as? Int == 300)
    // Launched in the background: remembered, not sent.
    #expect(await apphelm.reportAppStart(firstFrame: process, launchedInBackground: true, directory: directory, processStart: process, prewarmed: false, boot: 42, oncePerProcess: false) == false)
    #expect(recorder.bodies.count == 2)
  }

  // MARK: Sampling policy

  @Test("No rate set: automatic screen loads and app starts send nothing, but errors carry their trace id and traceparent goes out with flag 00")
  func noRateAutomaticIsUnsampled() async throws {
    struct Failed: Error {}
    let recorder = Recorder()
    let api = "api-\(UUID().uuidString.lowercased()).test"
    var headers: [String] = []
    let lock = NSLock()
    RoutedURLProtocol.register(host: api) { request in
      lock.withLock { headers.append(request.value(forHTTPHeaderField: "traceparent") ?? "none") }
      return try jsonResponse(url: request.url!, status: 200, body: ["ok": true])
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let apphelm = client(options(recorder) { $0.tracePropagationHosts = [api] }, recorder)
    #expect(!apphelm.tracingConfigured)

    let load = apphelm.screenLoadStarted("Checkout")
    #expect(!load.sampled)
    _ = try await apphelm.data(for: URLRequest(url: URL(string: "https://\(api)/cart")!), session: session)
    try await apphelm.captureException(Failed())
    apphelm.screenLoadFirstFrame(load)
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await apphelm.reportAppStart(firstFrame: Date(), launchedInBackground: false, directory: directory, processStart: Date().addingTimeInterval(-1), prewarmed: false, boot: 1, oncePerProcess: false) == false)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(events(recorder, "$transaction").isEmpty)
    #expect(events(recorder, "$exception").first?["trace_id"] as? String == load.traceId)
    let header = try #require(lock.withLock { headers.first })
    #expect(header.hasPrefix("00-\(load.traceId)-") && header.hasSuffix("-00"))
  }

  @Test("No rate set: an automatic transaction honours an incoming sampled trace, and your own transactions are kept")
  func noRateIncomingAndManual() async throws {
    let recorder = Recorder()
    let apphelm = client(options(recorder), recorder)
    let incoming = apphelm.startTransaction("GET /cart", op: "http.server", traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", clock: TraceClock(), automatic: true)
    #expect(incoming.sampled)
    #expect(await incoming.finish())
    let sentry = apphelm.startTransaction("GET /cart", op: "http.server", traceparent: "4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1", clock: TraceClock(), automatic: true)
    #expect(sentry.sampled)
    #expect(!apphelm.startTransaction("GET /cart", op: "http.server", traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00", clock: TraceClock(), automatic: true).sampled)
    #expect(!apphelm.startTransaction("Auto", op: "ui.load", traceparent: nil, clock: TraceClock(), automatic: true).sampled)
    // Manual, no rate: kept at 1, as before.
    let manual = apphelm.startTransaction("Sync")
    #expect(manual.sampled)
    #expect(await manual.finish())
    #expect(await apphelm.startScreen("Orders").finish())
    #expect(events(recorder, "$transaction").count == 3)
  }

  @Test("A rate or sampler, once set, decides automatic and manual transactions alike")
  func rateAppliesToBoth() async throws {
    let none = Recorder()
    let zero = client(options(none) { $0.tracesSampleRate = 0 }, none)
    #expect(zero.tracingConfigured)
    #expect(!zero.startTransaction("Sync").sampled)
    #expect(!zero.screenLoadStarted("Checkout").sampled)
    // An incoming sampled trace still wins over a rate of 0.
    #expect(zero.startTransaction("GET /", op: "http.server", traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", clock: TraceClock(), automatic: true).sampled)

    let all = Recorder()
    let one = client(options(all) { $0.tracesSampleRate = 1 }, all)
    #expect(one.screenLoadStarted("Checkout").sampled && one.startTransaction("Sync").sampled)

    let sampler = Recorder()
    let decided = client(options(sampler) { $0.tracesSampler = { $0.op == "ui.load" ? 1 : 0 } }, sampler)
    #expect(decided.tracingConfigured)
    #expect(decided.screenLoadStarted("Checkout").sampled)
    #expect(!decided.startTransaction("Sync").sampled)
    // A sampler that answers nil with no rate set falls back to the default.
    let fallback = client(options(sampler) { $0.tracesSampler = { _ in nil } }, sampler)
    #expect(!fallback.screenLoadStarted("Checkout").sampled && fallback.startTransaction("Sync").sampled)

    // A number still works where the rate is passed or set; NaN is 1, out-of-range is clamped.
    #expect(ApphelmOptions(apiKey: "k", workspaceId: "w", productId: "p", tracesSampleRate: 0.25).tracesSampleRate == 0.25)
    #expect(ApphelmOptions(apiKey: "k", workspaceId: "w", productId: "p", tracesSampleRate: 7).tracesSampleRate == 1)
    #expect(ApphelmOptions(apiKey: "k", workspaceId: "w", productId: "p", tracesSampleRate: .nan).tracesSampleRate == 1)
    #expect(ApphelmOptions(apiKey: "k", workspaceId: "w", productId: "p").tracesSampleRate == nil)
  }
}

/// Names seen by a hook, in order.
final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  func add(_ name: String) { lock.withLock { names.append(name) } }
  var all: [String] { lock.withLock { names } }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

final class OrdersViewController: UIViewController {}

/// Runs on an iOS simulator (`xcodebuild test`), not in `swift test` on macOS.
@Suite("UIKit screen loads")
struct UIKitScreenLoadTests {
  @MainActor
  @Test("viewDidLoad starts a ui.load transaction; the first frame after viewDidAppear sends ttid_ms")
  func automaticScreenLoad() async throws {
    let recorder = Recorder()
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1").quiet
    options.enableUIViewControllerTracing = true
    options.tracesSampleRate = 1
    let apphelm = ApphelmClient(options: options, session: recorder.session(), store: MemoryStore())
    let controller = OrdersViewController()
    controller.loadViewIfNeeded()
    controller.beginAppearanceTransition(true, animated: false)
    controller.endAppearanceTransition()
    func load() -> [String: Any]? {
      recorder.bodies.map { $0["properties"] as? [String: Any] ?? [:] }.first { $0["op"] as? String == "ui.load" && $0["name"] as? String == "Orders" }
    }
    await waitUntil { load() != nil }
    let properties = try #require(load())
    #expect(properties["ttid_ms"] is Int)
    #expect(parsedSpans(properties).contains { $0["op"] as? String == "ui.load.initial_display" })
    withExtendedLifetime(apphelm) {}
  }
}
#endif
