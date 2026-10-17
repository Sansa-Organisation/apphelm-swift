import Foundation
import Testing

@testable import Apphelm

private func spans(_ properties: [String: Any]) -> [[String: Any]] {
  guard let text = properties["spans"] as? String, let data = text.data(using: .utf8) else { return [] }
  return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
}

@Suite("Automatic HTTP spans")
struct HTTPSpanTests {
  func options(_ recorder: Recorder, rate: Double = 1, hosts: [String] = []) -> ApphelmOptions {
    ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", tracesSampleRate: rate, tracePropagationHosts: hosts)
  }

  @Test("traceparent goes only to listed hosts: an exact host, or a leading dot for the hosts under a domain")
  func listedHosts() {
    #expect(propagatesTo("api.shop.example", listed: [" API.shop.example "]))
    #expect(!propagatesTo("evil-api.shop.example", listed: ["api.shop.example"]))
    #expect(propagatesTo("eu.api.shop.example", listed: [".shop.example"]))
    #expect(!propagatesTo("shop.example", listed: [".shop.example"]))
    #expect(!propagatesTo("notshop.example", listed: [".shop.example"]))
    #expect(!propagatesTo("api.shop.example.evil.test", listed: ["api.shop.example", ".shop.example"]))
    #expect(!propagatesTo("anything.test", listed: ["", ".", " "]))
    #expect(!propagatesTo("api.shop.example", listed: []))
  }

  @Test("data(for:) records the request as a span and sends traceparent to a listed host only")
  func wrapper() async throws {
    let recorder = Recorder()
    let api = "api-\(UUID().uuidString.lowercased()).test"
    let vendor = "vendor-\(UUID().uuidString.lowercased()).test"
    let headers = SeenHeaders()
    for host in [api, vendor] {
      RoutedURLProtocol.register(host: host) { request in
        headers.note(request.url!.path, request.value(forHTTPHeaderField: "traceparent") ?? "none")
        if request.url?.path == "/down" { throw URLError(.notConnectedToInternet) }
        return try jsonResponse(url: request.url!, status: request.url?.path == "/missing" ? 404 : 200, body: ["ok": true])
      }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = ApphelmClient(options: options(recorder, hosts: [api]), session: recorder.session(), store: MemoryStore())

    // No transaction: the request is sent untouched.
    let plain = try await client.data(for: URLRequest(url: URL(string: "https://\(api)/plain")!), session: session)
    #expect((plain.1 as? HTTPURLResponse)?.statusCode == 200 && headers.all["/plain"] == "none")
    var mine = URLRequest(url: URL(string: "https://\(api)/x")!)
    #expect(!client.propagate(&mine) && mine.value(forHTTPHeaderField: "traceparent") == nil)

    let tx = client.startScreen("CheckoutScreen", properties: ["tab": "saved"])
    #expect(client.activeTransaction === tx)
    let cart = try await client.data(for: URLRequest(url: URL(string: "https://user:pw@\(api)/cart?session=abc123")!), session: session)
    #expect((cart.1 as? HTTPURLResponse)?.statusCode == 200)
    var post = URLRequest(url: URL(string: "https://\(api)/missing")!)
    post.httpMethod = "post"
    _ = try await client.data(for: post, session: session)
    await #expect(throws: URLError.self) { _ = try await client.data(for: URLRequest(url: URL(string: "https://\(api)/down")!), session: session) }
    _ = try await client.data(for: URLRequest(url: URL(string: "https://\(vendor)/tiles")!), session: session)

    // propagate(&request): the transaction as parent, to a listed host only.
    var other = URLRequest(url: URL(string: "https://\(vendor)/x")!)
    #expect(client.propagate(&mine) && mine.value(forHTTPHeaderField: "traceparent") == tx.traceparent())
    #expect(!client.propagate(&other) && other.value(forHTTPHeaderField: "traceparent") == nil)

    #expect(await tx.finish())
    let properties = recorder.properties(0)
    #expect(properties["op"] as? String == "ui.load" && properties["name"] as? String == "CheckoutScreen")
    let sent = spans(properties)
    #expect(sent.map { $0["description"] as? String } == ["GET https://\(api)/cart", "POST https://\(api)/missing", "GET https://\(api)/down", "GET https://\(vendor)/tiles"])
    #expect(sent.map { $0["status"] as? String } == ["ok", "error", "error", "ok"])
    #expect(sent.allSatisfy { $0["op"] as? String == "http.client" && $0["parent_span_id"] as? String == tx.spanId })
    let seen = headers.all
    #expect(seen["/cart"] == "00-\(tx.traceId)-\(sent[0]["span_id"] as? String ?? "")-01")
    #expect(seen["/missing"] == "00-\(tx.traceId)-\(sent[1]["span_id"] as? String ?? "")-01")
    #expect(seen["/tiles"] == "none")

    // startScreen also queued the screen view.
    await client.flush()
    let batch = String(describing: recorder.bodies.last ?? [:])
    #expect(batch.contains("page_viewed") && batch.contains("CheckoutScreen"))
  }

  @Test("An HTTP span's URL keeps scheme, host, a given port and path only")
  func target() {
    let full = httpTarget(URL(string: "https://user:secret@API.shop.example/orders/1841?token=abc#frag"))
    #expect(full?.host == "api.shop.example" && full?.authority == "api.shop.example:443" && full?.shown == "https://api.shop.example/orders/1841")
    let bare = httpTarget(URL(string: "http://10.0.2.2:8080"))
    #expect(bare?.authority == "10.0.2.2:8080" && bare?.shown == "http://10.0.2.2:8080/")
    for other in ["ftp://files.example/a", "file:///etc/hosts", "/relative/path", "mailto:a@b.example"] {
      #expect(httpTarget(URL(string: other)) == nil, "\(other)")
    }
    #expect(httpTarget(nil) == nil)
  }

  @Test("Finished requests become http.client spans in the active transaction, timed by their metrics")
  func recorded() async throws {
    let recorder = Recorder()
    let time = PinnedClock()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let cart = URL(string: "https://api.shop.example/cart?session=abc123")!
    func at(_ offsetMs: Double, _ durationMs: Double) -> DateInterval { DateInterval(start: time.start.addingTimeInterval(offsetMs / 1000), duration: durationMs / 1000) }

    #expect(client.activeTransaction == nil)
    client.recordHTTPSpan(method: "GET", url: cart, statusCode: 200, interval: at(0, 10)) // no transaction: nothing happens

    let tx = client.startTransaction("CheckoutScreen", op: "ui.load", traceparent: nil, clock: time.clock)
    #expect(client.activeTransaction === tx)
    client.recordHTTPSpan(method: "get", url: cart, statusCode: 200, interval: at(20, 30))
    client.recordHTTPSpan(method: "POST", url: URL(string: "https://api.shop.example/pay"), statusCode: 402, interval: at(60, 15))
    client.recordHTTPSpan(method: "GET", url: URL(string: "https://api.shop.example/slow"), statusCode: 503, interval: at(80, 400))
    client.recordHTTPSpan(method: "GET", url: URL(string: "https://cdn.shop.example:8443/logo.png"), statusCode: 304, interval: at(90, 5))
    client.recordHTTPSpan(method: "PUT", url: URL(string: "https://api.shop.example/offline"), statusCode: nil, interval: at(100, 7))
    // Not recorded: the client's own request, a request from before the transaction, not http.
    client.recordHTTPSpan(method: "POST", url: URL(string: "\(recorder.baseURL)/api/v1/events"), statusCode: 202, interval: at(110, 5))
    client.recordHTTPSpan(method: "GET", url: cart, statusCode: 200, interval: at(-50, 500))
    client.recordHTTPSpan(method: "GET", url: URL(string: "file:///tmp/cache.json"), statusCode: nil, interval: at(120, 1))
    #expect(tx.spanCount == 5)

    #expect(await tx.finish())
    #expect(tx.isFinished && client.activeTransaction == nil)
    let sent = spans(recorder.properties(0))
    #expect(sent.count == 5)
    #expect(sent.allSatisfy { $0["op"] as? String == "http.client" && $0["parent_span_id"] as? String == tx.spanId && isLowerHexID($0["span_id"] as? String) })
    #expect(sent.map { $0["description"] as? String } == [
      "GET https://api.shop.example/cart", "POST https://api.shop.example/pay", "GET https://api.shop.example/slow",
      "GET https://cdn.shop.example:8443/logo.png", "PUT https://api.shop.example/offline",
    ])
    #expect(sent.map { $0["status"] as? String } == ["ok", "error", "error", "ok", "error"])
    #expect(sent.map { $0["start_offset_ms"] as? Int } == [20, 60, 80, 90, 100])
    #expect(sent.map { $0["duration_ms"] as? Int } == [30, 15, 400, 5, 7])

    // After the transaction is sent, a late request is dropped.
    client.recordHTTPSpan(method: "GET", url: cart, statusCode: 200, interval: at(130, 5))
    #expect(tx.spanCount == 5)
  }

  @Test("The newest transaction is the active one, and finishing it does not bring an older one back")
  func active() async throws {
    let recorder = Recorder()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let now = DateInterval(start: Date().addingTimeInterval(1), duration: 0.01)
    let older = client.startTransaction("Sync")
    let newer = client.startTransaction("ProfileScreen")
    #expect(client.activeTransaction === newer)
    client.recordHTTPSpan(method: "GET", url: URL(string: "https://api.shop.example/profile"), statusCode: 200, interval: now)
    client.recordHTTPSpan(method: "GET", url: URL(string: "https://api.shop.example/sync"), statusCode: 200, interval: now, transaction: older)
    #expect(newer.spanCount == 1 && older.spanCount == 1)
    await newer.finish()
    #expect(client.activeTransaction == nil)
    client.recordHTTPSpan(method: "GET", url: URL(string: "https://api.shop.example/x"), statusCode: 200, interval: now)
    #expect(older.spanCount == 1)

    // A transaction nobody holds any more is not kept alive by the client.
    weak var abandoned: Transaction?
    do {
      let transaction = client.startTransaction("Abandoned")
      abandoned = transaction
      #expect(client.activeTransaction === transaction)
    }
    #expect(abandoned == nil && client.activeTransaction == nil)
  }

  @Test("A URLSession with the delegate records its requests without the call sites doing anything")
  func delegate() async throws {
    let recorder = Recorder()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let api = "api-\(UUID().uuidString.lowercased()).test"
    RoutedURLProtocol.register(host: api) { request in
      if request.url?.path == "/down" { throw URLError(.notConnectedToInternet) }
      return try jsonResponse(url: request.url!, status: request.url?.path == "/missing" ? 404 : 200, body: ["ok": true])
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    let session = URLSession(configuration: configuration, delegate: client.httpSpanDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let tx = client.startTransaction("CheckoutScreen", op: "ui.load")
    _ = try await session.data(from: URL(string: "https://\(api)/cart?session=abc123")!)
    var post = URLRequest(url: URL(string: "https://\(api)/missing")!)
    post.httpMethod = "POST"
    _ = try await session.data(for: post)
    _ = try? await session.data(from: URL(string: "https://\(api)/down")!)
    // Metrics arrive on the session's delegate queue.
    for _ in 0..<200 where tx.spanCount < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(tx.spanCount == 3)
    #expect(await tx.finish())

    let sent = spans(recorder.properties(0)).sorted { ($0["description"] as? String ?? "") < ($1["description"] as? String ?? "") }
    #expect(sent.map { $0["description"] as? String } == ["GET https://\(api)/cart", "GET https://\(api)/down", "POST https://\(api)/missing"])
    #expect(sent.map { $0["status"] as? String } == ["ok", "error", "error"])
    #expect(sent.allSatisfy { ($0["start_offset_ms"] as? Int ?? -1) >= 0 && ($0["duration_ms"] as? Int ?? -1) >= 0 && ($0["start_offset_ms"] as? Int ?? 0) < 60_000 })
    // The transaction's own send went through the client's session, not the app's: no span for it, and no span for a later request.
    #expect(recorder.bodies.count == 1)
  }
}

/// The `traceparent` each stubbed path received ("none" without one).
private final class SeenHeaders: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [String: String] = [:]
  func note(_ path: String, _ value: String) { lock.withLock { seen[path] = value } }
  var all: [String: String] { lock.withLock { seen } }
}

private func isLowerHexID(_ value: String?) -> Bool {
  guard let value else { return false }
  return value.count == 16 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}
