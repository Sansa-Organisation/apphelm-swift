import Foundation
import Testing

@testable import Apphelm

/// A server that records each request (path, headers, JSON body) and answers by path:
/// feedback and check-ins as the real routes do, logs and events with 202.
final class GapServer: @unchecked Sendable {
  struct Seen {
    let path: String
    let headers: [String: String]
    let body: [String: Any]
  }

  private let lock = NSLock()
  private var seen: [Seen] = []
  private var logStatus: Int = 200
  private var logAnswer = ""
  let host = "gap-\(UUID().uuidString.lowercased()).test"
  var baseURL: String { "https://\(host)" }

  func answerLogs(_ status: Int, _ body: String = "") { lock.withLock { logStatus = status; logAnswer = body } }

  func session() -> URLSession {
    RoutedURLProtocol.register(host: host) { [self] request in
      let body = (try? requestJSON(request)) ?? [:]
      let path = request.url?.path ?? ""
      let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
      let (status, answer) = lock.withLock { () -> (Int, String) in
        seen.append(Seen(path: path, headers: headers, body: body))
        return (logStatus, logAnswer)
      }
      switch path {
      case "/api/v1/feedback":
        return try jsonResponse(url: request.url!, status: 201, body: ["object": "feedback", "data": ["id": "fb_1", "profileId": NSNull(), "replayed": false]])
      case "/api/v1/check-ins":
        return try jsonResponse(url: request.url!, status: 201, body: ["object": "check_in", "data": ["id": body["checkInId"] as? String ?? "chk_x", "monitorId": "mon_1", "status": body["status"] as? String ?? ""]])
      case "/api/v1/logs":
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!
        return (response, Data((answer.isEmpty ? "{}" : answer).utf8))
      default:
        return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true])
      }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  var requests: [Seen] { lock.withLock { seen } }
  func on(_ path: String) -> [Seen] { requests.filter { $0.path == path } }
  /// The properties of each `$exception` sent.
  var errors: [[String: Any]] { on("/api/v1/events").filter { $0.body["eventName"] as? String == "$exception" }.map { $0.body["properties"] as? [String: Any] ?? [:] } }
  /// Every log record sent, in order.
  var logRecords: [[String: Any]] {
    on("/api/v1/logs").flatMap { seen -> [[String: Any]] in
      let resource = (seen.body["resourceLogs"] as? [[String: Any]]) ?? []
      return resource.flatMap { (($0["scopeLogs"] as? [[String: Any]]) ?? []).flatMap { ($0["logRecords"] as? [[String: Any]]) ?? [] } }
    }
  }
}

private func attribute(_ record: [String: Any], _ key: String) -> [String: Any]? {
  ((record["attributes"] as? [[String: Any]]) ?? []).first { $0["key"] as? String == key }?["value"] as? [String: Any]
}

private struct GapError: Error {}

/// packages/sdk-fixtures/url-filters.json.
private struct UrlFilterCases: Decodable {
  struct Pattern: Decodable {
    let string: String?
    let regex: String?
    var pattern: ApphelmPattern { regex.map { .regex($0) } ?? .contains(string ?? "") }
  }

  struct Case: Decodable {
    let name: String
    let frame: String?
    let denyUrls: [Pattern]
    let allowUrls: [Pattern]
    let drop: String?
  }

  let cases: [Case]
}

private final class Lines: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ line: String) { lock.withLock { items.append(line) } }
  var all: [String] { lock.withLock { items } }
}

@Suite("Sentry gaps: options, captureEvent, contexts, logs, feedback, crons, lifecycle")
struct GapTests {
  func client(_ server: GapServer, configure: (inout ApphelmOptions) -> Void = { _ in }) -> ApphelmClient {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: server.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: "ios@4.0.0", environment: "production").quiet
    options.logsFlushIntervalSeconds = 0
    configure(&options)
    return ApphelmClient(options: options, session: server.session(), store: MemoryStore(), installStore: nil, attributionToken: { nil }, appInfo: AppInfo(version: "4.0.0", build: "400"), frames: FrameStats(), crashScope: CrashScopeStore())
  }

  // MARK: Contexts, tags, lastEventId

  @Test("setContext sends context.<name>.<key> tags: scalars only, scrubbed, sensitive keys dropped, bounded; nil removes")
  func contexts() async throws {
    let server = GapServer()
    let apphelm = client(server)
    apphelm.setTags(["plan": "pro", "beta": true])
    apphelm.setContext("order", ["id": "ord_7", "items": 3, "paid": false, "nested": ["a": 1], "password": "hunter2", "note": "mail bob@example.com", "bad key": "x"])
    apphelm.setContext("bad name!", ["a": "b"])
    apphelm.setContext("gone", ["a": "b"])
    apphelm.setContext("gone", nil)
    #expect(try await apphelm.captureMessage("checkout slow"))
    let tags = try #require(server.errors.first?["tags"] as? [String: Any])
    #expect(tags["plan"] as? String == "pro" && tags["beta"] as? Bool == true)
    #expect(tags["context.order.id"] as? String == "ord_7")
    #expect(tags["context.order.items"] as? Int == 3)
    #expect(tags["context.order.paid"] as? Bool == false)
    #expect(tags["context.order.note"] as? String == "mail [email]")
    #expect(tags["context.order.nested"] == nil && tags["context.order.password"] == nil && tags["context.order.bad key"] == nil)
    #expect(!tags.keys.contains { $0.hasPrefix("context.gone") || $0.hasPrefix("context.bad") })

    // At most 10 context tags, and 20 tags in all.
    let crowded = client(GapServer())
    for index in 0..<3 { crowded.setContext("c\(index)", Dictionary(uniqueKeysWithValues: (0..<10).map { ("k\($0)", $0) })) }
    var limited: [String: Any] = [:]
    addContextTags(&limited, crowded.contexts)
    #expect(limited.count == 10)
    var full: [String: Any] = Dictionary(uniqueKeysWithValues: (0..<15).map { ("t\($0)", $0) })
    addContextTags(&full, crowded.contexts)
    #expect(full.count == 20)
    #expect(sanitizeContext(Dictionary(uniqueKeysWithValues: (0..<30).map { ("k\($0)", $0) })).count == 10)
    var many: [String: [String: Any]] = [:]
    for index in 0..<12 { applyContext(&many, "n\(index)", ["a": 1]) }
    #expect(many.count == 10)
  }

  @Test("Scope contexts and tags win inside withScope; configureScope outside one changes the client's")
  func scopeContexts() async throws {
    let server = GapServer()
    let apphelm = client(server)
    apphelm.setContext("device", ["tier": "low"])
    try await apphelm.withScope { scope in
      scope.setContext("device", ["tier": "high"])
      scope.setTags(["job": "sync"])
      _ = try await apphelm.captureMessage("inside")
    }
    apphelm.configureScope { scope in
      scope.setTag("region", "eu")
      scope.setContext("app", ["mode": "offline"])
    }
    _ = try await apphelm.captureMessage("outside")
    let inside = try #require(server.errors.first?["tags"] as? [String: Any])
    #expect(inside["context.device.tier"] as? String == "high" && inside["job"] as? String == "sync")
    let outside = try #require(server.errors.last?["tags"] as? [String: Any])
    #expect(outside["context.device.tier"] as? String == "low" && outside["region"] as? String == "eu" && outside["context.app.mode"] as? String == "offline")
    #expect(outside["job"] == nil)
  }

  @Test("lastEventId is the id each error carries as $event_id and as the event id")
  func lastEventId() async throws {
    struct Broken: Error {}
    let server = GapServer()
    let apphelm = client(server)
    #expect(apphelm.lastEventId == nil)
    _ = try await apphelm.captureException(Broken())
    let first = try #require(apphelm.lastEventId)
    #expect(server.errors.last?["$event_id"] as? String == first)
    #expect(server.on("/api/v1/events").last?.body["eventId"] as? String == first)
    _ = try await apphelm.captureMessage("hello")
    #expect(apphelm.lastEventId != first)
    #expect(server.errors.last?["$event_id"] as? String == apphelm.lastEventId)
  }

  // MARK: captureEvent

  @Test("captureEvent sends a message or an exception through the same path, with its own id, release and contexts")
  func captureEvent() async throws {
    let server = GapServer()
    let apphelm = client(server)
    let id = try await apphelm.captureEvent(ApphelmEvent(message: "Quota at 90% for bob@example.com", level: .warning, fingerprint: ["quota"], tags: ["area": "billing"], contexts: ["quota": ["used": 90, "token": "x"]], eventId: "evt_custom_1"))
    #expect(id == "evt_custom_1" && apphelm.lastEventId == "evt_custom_1")
    let message = try #require(server.errors.first)
    #expect(message["name"] as? String == "Message" && message["level"] as? String == "warning")
    #expect(message["message"] as? String == "Quota at 90% for [email]")
    #expect(message["fingerprint"] as? [String] == ["quota"])
    let tags = try #require(message["tags"] as? [String: Any])
    #expect(tags["area"] as? String == "billing" && tags["context.quota.used"] as? Int == 90 && tags["context.quota.token"] == nil)
    #expect(message["release"] as? String == "ios@4.0.0" && message["environment"] as? String == "production")

    let second = try await apphelm.captureEvent(ApphelmEvent(exception: .init(type: "DecodingError", value: "bad JSON at ?token=abc", stacktrace: "0 App main + 12\n1 App load?key=secret + 4"), release: "ios@4.0.1", environment: "staging", eventId: "no"))
    let generated = try #require(second)
    #expect(generated != "no" && isClientEventId(generated))
    let exception = try #require(server.errors.last)
    #expect(exception["name"] as? String == "DecodingError" && exception["level"] as? String == "error")
    #expect(exception["release"] as? String == "ios@4.0.1" && exception["environment"] as? String == "staging")
    #expect((exception["stack"] as? String)?.contains("secret") == false)
    #expect((exception["message"] as? String)?.contains("abc") == false)

    await #expect(throws: ApphelmError.self) { try await apphelm.captureEvent(ApphelmEvent(message: "  ")) }
  }

  // MARK: Filtering

  @Test("ignoreErrors, sampleRate and beforeSend, in that order; debug says why")
  func filtering() async throws {
    struct NetworkTimeout: Error, CustomStringConvertible { var description: String { "timed out" } }
    let server = GapServer()
    let lines = Lines()
    let apphelm = client(server) { options in
      options.ignoreErrors = ["NetworkTimeout", .regex("^Cancel+ed$"), .regex("(")]
      options.debug = true
    }
    apphelm.debugObserver = { lines.add($0) }
    #expect(try await apphelm.captureException(NetworkTimeout()) == false)
    #expect(try await apphelm.captureMessage("Cancelled") == false)
    #expect(try await apphelm.captureEvent(ApphelmEvent(message: "Cancelled")) == nil)
    #expect(try await apphelm.captureMessage("Cancelled twice"))
    #expect(server.errors.count == 1)
    #expect(lines.all.filter { $0 == "error dropped (ignoreErrors)" }.count == 3)

    let sampledOut = GapServer()
    let none = client(sampledOut) { $0.sampleRate = 0 }
    #expect(try await none.captureMessage("never") == false)
    #expect(none.lastEventId == nil && sampledOut.errors.isEmpty)
    // Transactions and logs don't follow sampleRate.
    _ = await none.startTransaction("sync").finish()
    #expect(sampledOut.on("/api/v1/events").count == 1)

    #expect(ApphelmPattern.contains("time").matches("timed out"))
    #expect(!ApphelmPattern.contains("").matches("anything"))
    #expect(ApphelmPattern.regex("^a.c$").matches("abc"))
  }

  @Test("Every shared denyUrls / allowUrls case (packages/sdk-fixtures/url-filters.json) gives its expected drop")
  func sharedUrlFilters() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/url-filters.json")
    let cases = try JSONDecoder().decode(UrlFilterCases.self, from: Data(contentsOf: file)).cases
    #expect(cases.count == 20)
    for item in cases {
      let reason = urlFilterDropReason(frame: item.frame, deny: item.denyUrls.map(\.pattern), allow: item.allowUrls.map(\.pattern))
      let drop = reason.map { ["denyUrls": "deny_urls", "allowUrls": "allow_urls"][$0] ?? $0 }
      #expect(drop == item.drop, "\(item.name)")
    }
  }

  @Test("stackFrameImage reads the binary of a callStackSymbols line, and nothing else")
  func stackFrameImages() {
    #expect(stackFrameImage("3   ShopKit                             0x0000000100abc123 $s7ShopKit4CartC8checkoutyyKF + 52") == "ShopKit")
    #expect(stackFrameImage("12  My Shop App   0x0000000100abc123 main + 4") == "My Shop App")
    #expect(stackFrameImage("0 App main + 12") == nil)
    #expect(stackFrameImage("at checkout (Cart.swift:12)") == nil)
    #expect(stackFrameImage("") == nil)
  }

  @Test("denyUrls and allowUrls drop errors by their top frame's binary; no frame and messages are kept; debug says why")
  func urlFilters() async throws {
    let vendor = "0   VendorKit   0x0000000100000010 $s9VendorKit3payyyF + 8\n1   ShopKit   0x0000000100000020 $s7ShopKit3buyyyF + 4"
    let shop = "0   ShopKit   0x0000000100000020 $s7ShopKit3buyyyF + 4\n1   VendorKit   0x0000000100000010 $s9VendorKit3payyyF + 8"
    let server = GapServer()
    let lines = Lines()
    let denied = client(server) { options in
      options.denyUrls = ["VendorKit"]
      options.debug = true
    }
    denied.debugObserver = { lines.add($0) }
    #expect(try await denied.captureEvent(ApphelmEvent(exception: .init(type: "PayError", value: "declined", stacktrace: vendor))) == nil)
    #expect(try await denied.captureEvent(ApphelmEvent(exception: .init(type: "PayError", value: "declined", stacktrace: shop))) != nil)
    #expect(lines.all == ["error dropped (denyUrls)"])
    #expect(server.errors.count == 1)

    let allowedServer = GapServer()
    let allowed = client(allowedServer) { options in
      options.allowUrls = [.regex("^Shop")]
      options.debug = true
    }
    allowed.debugObserver = { lines.add($0) }
    #expect(try await allowed.captureEvent(ApphelmEvent(exception: .init(type: "PayError", value: "declined", stacktrace: vendor))) == nil)
    #expect(lines.all.last == "error dropped (allowUrls)")
    #expect(try await allowed.captureEvent(ApphelmEvent(exception: .init(type: "PayError", value: "declined", stacktrace: shop))) != nil)
    // No frame (no stack, or a first line not in callStackSymbols form) is kept, and so are messages.
    #expect(try await allowed.captureEvent(ApphelmEvent(exception: .init(type: "PayError", value: "declined"))) != nil)
    #expect(try await allowed.captureEvent(ApphelmEvent(exception: .init(type: "PayError", value: "declined", stacktrace: "at pay (Vendor.swift:3)"))) != nil)
    #expect(try await allowed.captureEvent(ApphelmEvent(message: "Quota at 90%")) != nil)
    #expect(try await allowed.captureMessage("Quota at 95%"))
    #expect(allowedServer.errors.count == 5)

    // captureException: the binary of the first frame of the stack it sends.
    let plainServer = GapServer()
    #expect(try await client(plainServer).captureException(GapError()))
    let top = try #require((plainServer.errors.first?["stack"] as? String)?.split(separator: "\n").first.map(String.init))
    let image = try #require(stackFrameImage(top))
    let keptServer = GapServer()
    #expect(try await client(keptServer) { $0.allowUrls = [.contains(image)] }.captureException(GapError()))
    #expect(try await client(keptServer) { $0.allowUrls = [.regex("^NoSuchImage$")] }.captureException(GapError()) == false)
    #expect(try await client(keptServer) { $0.denyUrls = [.regex("^\(NSRegularExpression.escapedPattern(for: image))$")] }.captureException(GapError()) == false)
    #expect(keptServer.errors.count == 1)
  }

  @Test("enabled, ignoreErrors, denyUrls, allowUrls, sampleRate: in that order")
  func urlFilterOrder() async throws {
    let stack = "0   VendorKit   0x0000000100000010 $s9VendorKit3payyyF + 8"
    let event = ApphelmEvent(exception: .init(type: "PayError", value: "declined", stacktrace: stack))
    let server = GapServer()
    let lines = Lines()
    func filtered(_ configure: (inout ApphelmOptions) -> Void) async throws {
      let apphelm = client(server) { options in
        options.debug = true
        configure(&options)
      }
      apphelm.debugObserver = { lines.add($0) }
      #expect(try await apphelm.captureEvent(event) == nil)
    }
    try await filtered { $0.enabled = false; $0.denyUrls = ["VendorKit"] }
    try await filtered { $0.ignoreErrors = ["declined"]; $0.denyUrls = ["VendorKit"] }
    try await filtered { $0.denyUrls = ["VendorKit"]; $0.allowUrls = ["VendorKit"]; $0.sampleRate = 0 }
    try await filtered { $0.allowUrls = ["ShopKit"]; $0.sampleRate = 0 }
    try await filtered { $0.allowUrls = ["VendorKit"]; $0.sampleRate = 0 }
    #expect(lines.all == ["error dropped (disabled)", "error dropped (ignoreErrors)", "error dropped (denyUrls)", "error dropped (allowUrls)", "error dropped (sampleRate)"])
    #expect(server.errors.isEmpty)
  }

  @Test("ignoreTransactions: a matching transaction is not sent")
  func ignoreTransactions() async {
    let server = GapServer()
    let apphelm = client(server) { $0.ignoreTransactions = [.regex("^health")] ; $0.tracesSampleRate = 1 }
    #expect(await apphelm.startTransaction("healthcheck").finish() == false)
    #expect(await apphelm.startTransaction("checkout").finish())
    let names = server.on("/api/v1/events").compactMap { ($0.body["properties"] as? [String: Any])?["name"] as? String }
    #expect(names == ["checkout"])
  }

  @Test("enabled false: nothing is sent, captures return false or nil, withMonitor still runs the job")
  func disabled() async throws {
    let server = GapServer()
    let apphelm = client(server) { $0.enabled = false }
    apphelm.track("opened")
    await apphelm.flush()
    #expect(try await apphelm.captureMessage("x") == false)
    #expect(try await apphelm.captureEvent(ApphelmEvent(message: "x")) == nil)
    #expect(await apphelm.startTransaction("t").finish() == false)
    apphelm.logger.error("x")
    #expect(await apphelm.flush(timeout: 1))
    #expect(try await apphelm.captureFeedback("great app") == nil)
    #expect(try await apphelm.checkIn("nightly", status: .ok) == nil)
    #expect(try await apphelm.withMonitor("nightly") { 42 } == 42)
    _ = apphelm.startSession()
    await apphelm.flush()
    #expect(server.requests.isEmpty)
  }

  // MARK: Lifecycle

  @Test("flush(timeout:) reports draining; close stops all sending and is idempotent")
  func flushAndClose() async throws {
    let server = GapServer()
    let apphelm = client(server)
    apphelm.track("opened")
    apphelm.logger.info("started")
    #expect(await apphelm.flush(timeout: 5))
    #expect(server.on("/api/v1/events").count == 1 && server.logRecords.count == 1)
    #expect(await apphelm.close(timeout: 5))
    #expect(await apphelm.close(timeout: 1))
    apphelm.track("after")
    apphelm.logger.info("after")
    #expect(try await apphelm.captureMessage("after") == false)
    #expect(try await apphelm.captureFeedback("after") == nil)
    await apphelm.flush()
    #expect(server.requests.count == 2)
    // A timeout that passes first returns false and never throws.
    #expect(await waitAtMost(0.05) { _ = try? await Task.sleep(nanoseconds: 500_000_000) } == false)
    #expect(await waitAtMost(1) {} == true)
  }

  // MARK: Logs

  @Test("Logs: one batched OTLP request, scrubbed, levels, attributes, child, trace id, headers")
  func logs() async throws {
    struct Failure: Error, CustomStringConvertible { var description: String { "token=supersecret1" } }
    let server = GapServer()
    let apphelm = client(server) { options in
      options.logsService = "checkout-ios"
      options.beforeSendLog = { record in record.message.contains("drop me") ? nil : record }
    }
    let logger = apphelm.logger
    #expect(logger === apphelm.logger)
    logger.debug("below the minimum level")
    logger.info("Signed in bob@example.com", attributes: ["count": 3, "ratio": 0.5, "ok": true, "url": "https://x.test/a?token=abc", "nested": ["key": "ahl_live_abcdefghijk"], "list": [1, "two"]])
    logger.child(["screen": "cart"]).warning("Slow", attributes: ["error": Failure()])
    logger.info("drop me")
    let transaction = apphelm.startTransaction("checkout")
    logger.fault("Crashed in checkout")
    _ = await transaction.finish()
    #expect(await logger.flush(timeout: 5))

    let requests = server.on("/api/v1/logs")
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.headers["authorization"] == "Bearer ahl_live_test" && request.headers["x-apphelm-product"] == "prd_1")
    let resource = (((request.body["resourceLogs"] as? [[String: Any]])?.first?["resource"] as? [String: Any])?["attributes"] as? [[String: Any]]) ?? []
    #expect(resource.contains { $0["key"] as? String == "service.name" && ($0["value"] as? [String: Any])?["stringValue"] as? String == "checkout-ios" })
    #expect(resource.contains { $0["key"] as? String == "service.version" })
    let records = server.logRecords
    #expect(records.count == 3)
    let first = records[0]
    #expect(first["severityText"] as? String == "INFO" && first["severityNumber"] as? Int == 9)
    #expect((first["body"] as? [String: Any])?["stringValue"] as? String == "Signed in [email]")
    #expect(attribute(first, "count")?["intValue"] as? String == "3")
    #expect(attribute(first, "ratio")?["doubleValue"] as? Double == 0.5)
    #expect(attribute(first, "ok")?["boolValue"] as? Bool == true)
    #expect((attribute(first, "url")?["stringValue"] as? String)?.contains("abc") == false)
    let nested = ((attribute(first, "nested")?["kvlistValue"] as? [String: Any])?["values"] as? [[String: Any]])?.first
    #expect((nested?["value"] as? [String: Any])?["stringValue"] as? String == "[key]")
    #expect(first["traceId"] == nil)
    let second = records[1]
    #expect(second["severityText"] as? String == "WARN")
    #expect(attribute(second, "screen")?["stringValue"] as? String == "cart")
    #expect(attribute(second, "exception.type")?["stringValue"] as? String == "Failure")
    #expect(attribute(second, "exception.message")?["stringValue"] as? String == "token=[redacted]")
    let third = records[2]
    #expect(third["severityText"] as? String == "FATAL")
    #expect(third["traceId"] as? String == transaction.traceId && third["spanId"] as? String == transaction.spanId)
    #expect(attribute(third, "trace_id") == nil)
  }

  @Test("Logs: a throttled batch is retried once, a refused one dropped; full queues drop the oldest")
  func logRetries() async {
    let server = GapServer()
    server.answerLogs(503)
    let apphelm = client(server) { $0.logsMaxQueue = 3 }
    apphelm.logger.info("one")
    #expect(await apphelm.logger.flush(timeout: 5))
    #expect(await apphelm.logger.flush(timeout: 5))
    #expect(server.on("/api/v1/logs").count == 2)
    #expect(apphelm.logger.dropped == 1)
    server.answerLogs(429, "{\"error\":{\"code\":\"log_limit\"}}")
    apphelm.logger.info("two")
    _ = await apphelm.logger.flush(timeout: 5)
    #expect(apphelm.logger.dropped == 2)
    server.answerLogs(200)
    for index in 0..<5 { apphelm.logger.info("line \(index)") }
    #expect(apphelm.logger.dropped == 4)
    _ = await apphelm.logger.flush(timeout: 5)
    let last = server.logRecords.suffix(3).compactMap { ($0["body"] as? [String: Any])?["stringValue"] as? String }
    #expect(last == ["line 2", "line 3", "line 4"])
  }

  // MARK: Feedback

  @Test("captureFeedback: scrubbed text, the event id, never name or email, an idempotency key")
  func feedback() async throws {
    let server = GapServer()
    let apphelm = client(server)
    let result = try await apphelm.captureFeedback("It crashed, write to me at bob@example.com", associatedEventId: "3b1d4c1e-1111-4222-8333-444455556666", name: "Bob", email: "bob@example.com")
    #expect(result == FeedbackResult(id: "fb_1", profileId: nil, replayed: false))
    let request = try #require(server.on("/api/v1/feedback").first)
    #expect(request.headers["idempotency-key"]?.hasPrefix("sdk-feedback-") == true)
    let body = request.body
    #expect(Set(body.keys) == ["productId", "sourceType", "sourceId", "text", "occurredAt", "permission", "metadata", "eventId"])
    #expect(body["text"] as? String == "It crashed, write to me at [email]")
    #expect(body["sourceType"] as? String == "human" && body["permission"] as? String == "private_analysis" && body["productId"] as? String == "prd_1")
    #expect(body["eventId"] as? String == "3b1d4c1e-1111-4222-8333-444455556666")
    #expect((body["sourceId"] as? String)?.hasPrefix("sdk:") == true)
    #expect((body["metadata"] as? [String: Any])?["release"] as? String == "ios@4.0.0")
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    #expect(!raw.contains("Bob") && !raw.contains("bob@example.com"))

    _ = try await apphelm.captureFeedback("no event", associatedEventId: "bad id!")
    #expect(server.on("/api/v1/feedback").last?.body["eventId"] == nil)
    await #expect(throws: ApphelmError.self) { try await apphelm.captureFeedback("   ") }
  }

  // MARK: Crons

  @Test("Crons: checkIn body, withMonitor ok and error runs, invalid slugs and configs throw")
  func crons() async throws {
    struct JobFailed: Error {}
    let server = GapServer()
    let apphelm = client(server)
    let id = newCheckInId()
    let answer = try await apphelm.checkIn("nightly-sync", status: .inProgress, checkInId: id, monitorConfig: MonitorConfig(schedule: .crontab("0 3 * * *"), name: "Nightly", checkinMarginMinutes: 5, maxRuntimeMinutes: 30))
    #expect(answer?.id == id && answer?.monitorId == "mon_1")
    let body = try #require(server.on("/api/v1/check-ins").first?.body)
    #expect(body["monitor"] as? String == "nightly-sync" && body["status"] as? String == "in_progress" && body["productId"] as? String == "prd_1")
    let config = try #require(body["monitorConfig"] as? [String: Any])
    #expect((config["schedule"] as? [String: Any])?["type"] as? String == "crontab" && config["name"] as? String == "Nightly" && config["maxRuntimeMinutes"] as? Int == 30)

    #expect(try await apphelm.withMonitor("hourly", monitorConfig: MonitorConfig(schedule: .interval(minutes: 60))) { "done" } == "done")
    await #expect(throws: JobFailed.self) { try await apphelm.withMonitor("hourly") { () async throws -> Int in throw JobFailed() } }
    let runs = server.on("/api/v1/check-ins").dropFirst().map { $0.body }
    #expect(runs.map { $0["status"] as? String } == ["in_progress", "ok", "in_progress", "error"])
    #expect(runs[0]["checkInId"] as? String == runs[1]["checkInId"] as? String)
    #expect(runs[1]["durationMs"] is Int)

    await #expect(throws: ApphelmError.self) { try await apphelm.checkIn("Bad Slug", status: .ok) }
    await #expect(throws: ApphelmError.self) { try await apphelm.checkIn("ok", status: .ok, checkInId: "nope") }
    await #expect(throws: ApphelmError.self) { try await apphelm.checkIn("ok", status: .ok, monitorConfig: MonitorConfig(schedule: .interval(minutes: 0))) }
    await #expect(throws: ApphelmError.self) { try await apphelm.withMonitor("BAD") { 1 } }
  }
}
