import Foundation

public enum SpanStatus: String, Sendable {
  case ok
  case error
}

/// Time for tracing: a monotonic clock for durations and the wall clock for `started_at`.
/// Internal so a test can pin both.
struct TraceClock: Sendable {
  var nanos: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  var date: @Sendable () -> Date = { Date() }
}

/// Lower-case hex of `bytes` random bytes. An all-zero id is invalid in W3C Trace Context.
func randomHex(_ bytes: Int) -> String {
  var generator = SystemRandomNumberGenerator()
  while true {
    let value = (0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }
    if value.contains(where: { $0 != 0 }) { return value.map { String(format: "%02x", $0) }.joined() }
  }
}

private func isLowerHex(_ text: Substring, count: Int) -> Bool {
  text.utf8.count == count && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
}

/// A 32-character lower-case hex trace id, as `captureException(traceId:)` accepts.
func isTraceId(_ value: String) -> Bool { isLowerHex(value[...], count: 32) }

/// The trace id, parent span id and sampling flag of a W3C `traceparent`, or nil when it
/// isn't one (wrong version or shape, or an all-zero id).
func parseTraceparent(_ value: String?) -> (traceId: String, parentSpanId: String, sampled: Bool)? {
  guard let value else { return nil }
  let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
  guard parts.count == 4, parts[0] == "00", isLowerHex(parts[1], count: 32), isLowerHex(parts[2], count: 16), isLowerHex(parts[3], count: 2),
        let flags = UInt8(parts[3], radix: 16) else { return nil }
  if parts[1].allSatisfy({ $0 == "0" }) || parts[2].allSatisfy({ $0 == "0" }) { return nil }
  return (String(parts[1]), String(parts[2]), flags & 1 == 1)
}

private func milliseconds(_ nanos: UInt64) -> Int { Int(nanos / 1_000_000) }

/// Whether `host` is one the app listed for `traceparent`: an entry names one host exactly,
/// or, starting with a dot (`.example.com`), every host under that domain.
func propagatesTo(_ host: String, listed: [String]) -> Bool {
  listed.contains { entry in
    let wanted = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if wanted.isEmpty { return false }
    return wanted.hasPrefix(".") ? wanted.count > 1 && host.hasSuffix(wanted) : host == wanted
  }
}

/// What an HTTP span says about a request's URL: its host, its authority (`host:port`, the
/// port always given) and `scheme://host[:port]/path`. The query, fragment and any user and
/// password are left out; they are where tokens travel. Nil when it is not an http(s) URL.
func httpTarget(_ url: URL?) -> (host: String, authority: String, shown: String)? {
  guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
        let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
        let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
  let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
  let shown = parts.port.map { "\(host):\($0)" } ?? host
  return (host, "\(host):\(parts.port ?? (scheme == "https" ? 443 : 80))", "\(scheme)://\(shown)\(path)")
}

/// A sampled unit of work (a screen load, a sync, a request) with up to 50 child spans, sent
/// as one `$transaction` event, the same shape the Node, Python and Kotlin clients send,
/// when it finishes. Unsampled transactions send nothing. Pass `traceparent()` (or
/// `propagate(&request)`) to the services you call so their work joins the same trace, and
/// link errors with `captureException(error, traceId: transaction.traceId)`.
public final class Transaction: @unchecked Sendable {
  public let traceId: String
  public let spanId: String
  public let sampled: Bool
  private let send: @Sendable ([String: Any]) async throws -> Void
  private let name: String
  private let op: String
  private let parentSpanId: String?
  private let release: String?
  private let environment: String?
  private let clock: TraceClock
  let startedAt: Date
  let startNanos: UInt64
  private let lock = NSLock()
  private var spans: [[String: Any]] = []
  private var finished = false

  /// Whether `finish` has been called: a finished transaction takes no more spans.
  public var isFinished: Bool { lock.withLock { finished } }
  var spanCount: Int { lock.withLock { spans.count } }

  init(send: @escaping @Sendable ([String: Any]) async throws -> Void, name: String, op: String, traceId: String, parentSpanId: String?, sampled: Bool, release: String?, environment: String?, clock: TraceClock) {
    self.send = send
    self.name = String(name.prefix(200))
    self.op = op
    self.traceId = traceId
    self.spanId = randomHex(8)
    self.parentSpanId = parentSpanId
    self.sampled = sampled
    self.release = release
    self.environment = environment
    self.clock = clock
    self.startedAt = clock.date()
    self.startNanos = clock.nanos()
  }

  /// Start a child span; `finish` it when the work ends. At most 50 are kept.
  public func startSpan(_ op: String, description: String? = nil) -> Span {
    Span(transaction: self, op: op, description: description, clock: clock)
  }

  /// Run `work` in a span, finished as an error if it throws (the error is rethrown).
  public func span<T>(_ op: String, description: String? = nil, _ work: (Span) throws -> T) rethrows -> T {
    let span = startSpan(op, description: description)
    do {
      let value = try work(span)
      span.finish()
      return value
    } catch {
      span.finish(.error)
      throw error
    }
  }

  /// The same for asynchronous work.
  public func span<T>(_ op: String, description: String? = nil, _ work: (Span) async throws -> T) async rethrows -> T {
    let span = startSpan(op, description: description)
    do {
      let value = try await work(span)
      span.finish()
      return value
    } catch {
      span.finish(.error)
      throw error
    }
  }

  /// A W3C `traceparent` header value that continues this trace in another service.
  public func traceparent() -> String { "00-\(traceId)-\(spanId)-\(sampled ? "01" : "00")" }

  /// Set `traceparent` on an outgoing request, so the service it calls joins this trace. Only
  /// call it for your own services: the header tells whoever receives it the trace id.
  public func propagate(_ request: inout URLRequest) {
    request.setValue(traceparent(), forHTTPHeaderField: "traceparent")
  }

  func add(span: [String: Any]) {
    lock.withLock { if !finished && spans.count < 50 { spans.append(span) } }
  }

  /// An `http.client` span for a request that has already finished, timed by the wall clock
  /// (`URLSessionTaskMetrics` gives dates). A request that began before the transaction is
  /// not part of it and is left out.
  func addHTTPSpan(method: String, shown: String, interval: DateInterval, ok: Bool) {
    let offset = interval.start.timeIntervalSince(startedAt)
    guard offset >= 0 else { return }
    add(span: [
      "span_id": randomHex(8),
      "parent_span_id": spanId,
      "op": "http.client",
      "description": String("\(method.uppercased().prefix(10)) \(shown)".prefix(200)),
      "start_offset_ms": Int((offset * 1000).rounded()),
      "duration_ms": Int((max(0, interval.duration) * 1000).rounded()),
      "status": (ok ? SpanStatus.ok : SpanStatus.error).rawValue,
    ])
  }

  /// Send the transaction, once. It never throws, since telemetry must not break the work it
  /// measures. Returns whether it was sent: `false` when it is unsampled, already finished,
  /// or the send failed.
  @discardableResult
  public func finish(_ status: SpanStatus = .ok) async -> Bool {
    let kept: [[String: Any]]? = lock.withLock {
      if finished { return nil }
      finished = true
      return spans
    }
    guard let kept, sampled else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var properties: [String: Any] = [
      "trace_id": traceId,
      "span_id": spanId,
      "name": name,
      "op": op,
      "status": status.rawValue,
      "started_at": formatter.string(from: startedAt),
      "duration_ms": milliseconds(clock.nanos() &- startNanos),
      // A JSON string, as the other clients send it: properties stay flat scalars.
      "spans": (try? JSONSerialization.data(withJSONObject: kept)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
    ]
    if let parentSpanId { properties["parent_span_id"] = parentSpanId }
    if let release { properties["release"] = release }
    if let environment { properties["environment"] = environment }
    do {
      try await send(properties)
      return true
    } catch {
      return false
    }
  }
}

/// A timed piece of work inside a `Transaction`: a query, an outgoing call.
public final class Span: @unchecked Sendable {
  public let spanId: String
  private let transaction: Transaction
  private let op: String
  private let description: String?
  private let clock: TraceClock
  private let startNanos: UInt64
  private let lock = NSLock()
  private var finished = false

  init(transaction: Transaction, op: String, description: String?, clock: TraceClock) {
    self.transaction = transaction
    self.op = op
    self.description = description.map { String($0.prefix(200)) }
    self.clock = clock
    self.spanId = randomHex(8)
    self.startNanos = clock.nanos()
  }

  /// A `traceparent` whose parent is this span, for the outgoing call it measures.
  public func traceparent() -> String { "00-\(transaction.traceId)-\(spanId)-\(transaction.sampled ? "01" : "00")" }

  /// Set `traceparent` on the outgoing request this span measures (your own services only).
  public func propagate(_ request: inout URLRequest) {
    request.setValue(traceparent(), forHTTPHeaderField: "traceparent")
  }

  /// Finish the span, once; later calls do nothing.
  public func finish(_ status: SpanStatus = .ok) {
    let first: Bool = lock.withLock {
      if finished { return false }
      finished = true
      return true
    }
    guard first else { return }
    var span: [String: Any] = [
      "span_id": spanId,
      "parent_span_id": transaction.spanId,
      "op": op,
      "start_offset_ms": milliseconds(startNanos &- transaction.startNanos),
      "duration_ms": milliseconds(clock.nanos() &- startNanos),
      "status": status.rawValue,
    ]
    if let description { span["description"] = description }
    transaction.add(span: span)
  }
}

/// Records every request of a `URLSession` as an `http.client` span in the client's active
/// transaction. Get one from `ApphelmClient.httpSpanDelegate()`.
public final class HTTPSpanDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  // Weak: a session keeps its delegate, and the client may keep that session.
  private weak var client: ApphelmClient?

  init(client: ApphelmClient) { self.client = client }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    client?.recordHTTPSpan(task: task, metrics: metrics)
  }
}
