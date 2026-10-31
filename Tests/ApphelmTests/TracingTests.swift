import Foundation
import Testing

@testable import Apphelm

/// A clock a test moves by hand, so durations and dates are exact: the wall clock moves with it.
final class PinnedClock: @unchecked Sendable {
  private let lock = NSLock()
  private var nanos: UInt64 = 5_000_000_000
  // 2026-03-04T05:06:07.250Z
  let start = Date(timeIntervalSince1970: 1_772_600_767.25)

  func advance(ms: UInt64) { lock.withLock { nanos += ms * 1_000_000 } }
  var clock: TraceClock {
    TraceClock(nanos: { [self] in lock.withLock { nanos } }, date: { [self] in start.addingTimeInterval(Double(lock.withLock { nanos } - 5_000_000_000) / 1_000_000_000) })
  }
}

/// A stub that finds its handler by the request's host. `StubURLProtocol` has one global
/// handler, which suites running in parallel would overwrite for each other.
final class RoutedURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

  static func register(host: String, _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
    lock.withLock { handlers[host] = handler }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      guard let handler = Self.lock.withLock({ Self.handlers[request.url?.host ?? ""] }) else { throw URLError(.cannotFindHost) }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

/// The requests one client sent, with its own host so no other test's stub answers them.
final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [[String: Any]] = []
  private var requests: [URLRequest] = []
  private var failing = false
  let host = "stub-\(UUID().uuidString.lowercased()).test"
  var baseURL: String { "https://\(host)" }
  var fail: Bool {
    get { lock.withLock { failing } }
    set { lock.withLock { failing = newValue } }
  }

  func session() -> URLSession {
    RoutedURLProtocol.register(host: host) { [self] request in
      let body = (try? requestJSON(request)) ?? [:]
      let failed = lock.withLock { () -> Bool in seen.append(body); requests.append(request); return failing }
      return try jsonResponse(url: request.url!, status: failed ? 503 : 202, body: failed ? ["error": ["code": "unavailable", "message": "down"]] : ["accepted": true, "eventId": "evt_1"])
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  var bodies: [[String: Any]] { lock.withLock { seen } }
  var sent: [URLRequest] { lock.withLock { requests } }
  func properties(_ index: Int) -> [String: Any] { bodies[index]["properties"] as? [String: Any] ?? [:] }
}

private func isHex(_ value: String?, _ count: Int) -> Bool {
  guard let value else { return false }
  return value.count == count && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}

@Suite("Tracing")
struct TracingTests {
  func options(_ recorder: Recorder, rate: Double = 1) -> ApphelmOptions {
    ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: "shop@2.4.1", environment: "production", tracesSampleRate: rate).quiet
  }

  @Test("A transaction sends the $transaction shape the other clients send, once")
  func transactionShape() async throws {
    let recorder = Recorder()
    let time = PinnedClock()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let tx = client.startTransaction("CheckoutScreen", op: "ui.load", traceparent: nil, clock: time.clock)
    #expect(isHex(tx.traceId, 32) && isHex(tx.spanId, 16) && tx.sampled)
    #expect(tx.traceparent() == "00-\(tx.traceId)-\(tx.spanId)-01")

    time.advance(ms: 20)
    let query = tx.startSpan("db.query", description: "SELECT * FROM carts WHERE id = 7")
    time.advance(ms: 30)
    query.finish()
    query.finish(.error) // a second finish changes nothing
    struct Declined: Error {}
    var request = URLRequest(url: URL(string: "https://api.example.com/api/pay")!)
    var spanParent = ""
    do {
      try tx.span("http.client", description: "POST /api/pay") { span in
        span.propagate(&request)
        spanParent = span.traceparent()
        #expect(spanParent == "00-\(tx.traceId)-\(span.spanId)-01")
        time.advance(ms: 40)
        throw Declined()
      }
      Issue.record("span { } must rethrow")
    } catch is Declined {}
    #expect(request.value(forHTTPHeaderField: "traceparent") == spanParent)
    time.advance(ms: 10)

    #expect(await tx.finish(.error))
    #expect(await tx.finish() == false)
    #expect(recorder.bodies.count == 1)
    let body = recorder.bodies[0]
    #expect(body["eventName"] as? String == "$transaction")
    #expect(body["workspaceId"] as? String == "org_1" && body["productId"] as? String == "prd_1" && body["privacyMode"] as? String == "strict")
    let properties = recorder.properties(0)
    #expect(properties["trace_id"] as? String == tx.traceId)
    #expect(properties["span_id"] as? String == tx.spanId)
    #expect(properties["parent_span_id"] == nil)
    #expect(properties["name"] as? String == "CheckoutScreen")
    #expect(properties["op"] as? String == "ui.load")
    #expect(properties["status"] as? String == "error")
    #expect(properties["started_at"] as? String == "2026-03-04T05:06:07.250Z")
    #expect(properties["duration_ms"] as? Int == 100)
    #expect(properties["release"] as? String == "shop@2.4.1")
    #expect(properties["environment"] as? String == "production")
    // Transactions carry no person.
    #expect(properties["distinct_id"] == nil)

    let text = try #require(properties["spans"] as? String)
    let spans = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    #expect(spans.count == 2)
    #expect(spans.allSatisfy { $0["parent_span_id"] as? String == tx.spanId && isHex($0["span_id"] as? String, 16) })
    #expect(spans[0]["op"] as? String == "db.query")
    #expect(spans[0]["description"] as? String == "SELECT * FROM carts WHERE id = 7")
    #expect(spans[0]["start_offset_ms"] as? Int == 20 && spans[0]["duration_ms"] as? Int == 30)
    #expect(spans[0]["status"] as? String == "ok")
    #expect(spans[1]["op"] as? String == "http.client")
    #expect(spans[1]["start_offset_ms"] as? Int == 50 && spans[1]["duration_ms"] as? Int == 40)
    #expect(spans[1]["status"] as? String == "error")
  }

  @Test("At most 50 spans are kept, and an asynchronous span returns its value")
  func spanCap() async throws {
    let recorder = Recorder()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let tx = client.startTransaction("Sync")
    for _ in 0..<60 { tx.startSpan("task").finish() }
    let value = await tx.span("task") { _ in await Task.yield(); return 7 }
    #expect(value == 7)
    await tx.finish()
    let text = try #require(recorder.properties(0)["spans"] as? String)
    let spans = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
    #expect(spans.count == 50)
    #expect(recorder.properties(0)["op"] as? String == "task")
  }

  @Test("An incoming traceparent is continued with its trace id, parent and sampling decision")
  func continuation() async throws {
    let recorder = Recorder()
    // Rate 0: only the caller's decision can make this transaction sampled.
    let client = ApphelmClient(options: options(recorder, rate: 0), session: recorder.session(), store: MemoryStore())
    let continued = client.startTransaction("GET /cart", op: "http.server", traceparent: " 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01 ")
    #expect(continued.traceId == "4bf92f3577b34da6a3ce929d0e0e4736" && continued.sampled)
    #expect(await continued.finish())
    #expect(recorder.properties(0)["trace_id"] as? String == "4bf92f3577b34da6a3ce929d0e0e4736")
    #expect(recorder.properties(0)["parent_span_id"] as? String == "00f067aa0ba902b7")

    let fresh = client.startTransaction("Local")
    #expect(!fresh.sampled && fresh.traceparent().hasSuffix("-00"))
    #expect(await fresh.finish() == false)
    #expect(recorder.bodies.count == 1)
  }

  @Test("An unsampled parent stays unsampled, and a malformed traceparent starts a new trace")
  func unsampledAndInvalid() async throws {
    let recorder = Recorder()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let declined = client.startTransaction("GET /cart", traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")
    #expect(declined.traceId == "4bf92f3577b34da6a3ce929d0e0e4736" && !declined.sampled && declined.traceparent().hasSuffix("-00"))
    #expect(await declined.finish() == false)
    #expect(recorder.bodies.isEmpty)

    let invalid = [
      "", "garbage",
      "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", // unknown version
      "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01", // upper case
      "00-00000000000000000000000000000000-00f067aa0ba902b7-01", // all-zero trace id
      "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", // all-zero parent
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra",
      "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01",
    ]
    for header in invalid {
      let tx = client.startTransaction("x", traceparent: header)
      #expect(tx.traceId != "4bf92f3577b34da6a3ce929d0e0e4736" && isHex(tx.traceId, 32) && tx.sampled, "\(header)")
    }
  }

  @Test("A failed send returns false and never throws")
  func failedSend() async throws {
    let recorder = Recorder()
    recorder.fail = true
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let tx = client.startTransaction("Sync")
    #expect(await tx.finish() == false)
    #expect(await tx.finish() == false)
    #expect(recorder.bodies.count == 1)
  }

  @Test("captureException(traceId:) links the issue to its trace; a malformed id is left out")
  func exceptionLink() async throws {
    struct CartFailed: Error {}
    let recorder = Recorder()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let tx = client.startTransaction("CheckoutScreen")
    try await client.captureException(CartFailed(), traceId: tx.traceId)
    try await client.captureException(CartFailed(), traceId: "not-a-trace")
    try await client.captureException(CartFailed())
    #expect(recorder.bodies[0]["eventName"] as? String == "$exception")
    #expect(recorder.properties(0)["trace_id"] as? String == tx.traceId)
    #expect(recorder.properties(1)["trace_id"] == nil)
    #expect(recorder.properties(2)["trace_id"] == nil)
  }
}
