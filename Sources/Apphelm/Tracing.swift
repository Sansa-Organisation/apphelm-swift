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

func isLowerHex(_ text: Substring, count: Int) -> Bool {
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

func milliseconds(_ nanos: UInt64) -> Int { Int(nanos / 1_000_000) }

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

/// Sentry's `sentry-trace` header (`<32 hex trace>-<16 hex span>[-<0|1>]`), read when there is
/// no `traceparent`, so a call from a Sentry-instrumented client still joins its trace. A
/// header without the sampled flag leaves the decision to this client (`sampled` nil).
func parseSentryTrace(_ value: String?) -> (traceId: String, parentSpanId: String, sampled: Bool?)? {
  guard let value else { return nil }
  let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
  guard parts.count == 2 || parts.count == 3, isLowerHex(parts[0], count: 32), isLowerHex(parts[1], count: 16) else { return nil }
  if parts[0].allSatisfy({ $0 == "0" }) || parts[1].allSatisfy({ $0 == "0" }) { return nil }
  var sampled: Bool?
  if parts.count == 3 {
    guard parts[2] == "0" || parts[2] == "1" else { return nil }
    sampled = parts[2] == "1"
  }
  return (String(parts[0]), String(parts[1]), sampled)
}

/// What a `tracesSampler` is asked about a new transaction.
public struct SamplingContext: Sendable {
  public let name: String
  public let op: String
  /// The caller's decision, when the transaction continues an incoming trace that has one.
  public let parentSampled: Bool?
}

/// Span `data` keys whose value is a URL: scrubbed with `scrubUrl` (no query, fragment or
/// user info) rather than `scrubText`.
let spanURLKeys: Set<String> = ["url.full", "http.url", "url"]

/// Span `data` as the server indexes it: string keys, JSON scalar values (strings scrubbed,
/// then cut to 200).
func spanData(_ data: [String: Any]) -> [String: Any] {
  var kept: [String: Any] = [:]
  for (key, value) in data.prefix(30) {
    let name = String(key.prefix(64))
    guard !name.isEmpty else { continue }
    switch value {
    case let text as String: kept[name] = scrubbed(text, limit: 200, spanURLKeys.contains(name) ? scrubUrl : scrubText)
    case let flag as Bool: kept[name] = flag
    case let number as Int: kept[name] = number
    case let number as Double where number.isFinite: kept[name] = number
    case let number as NSNumber where number.doubleValue.isFinite: kept[name] = number
    default: continue
    }
  }
  return kept
}

/// A span description cut to fit its transaction, as the browser and Node SDKs do: each span
/// keeps up to 2,000 characters, but those past the first 200 share 8,000 per transaction, so
/// one with many long statements stays inside AppHelm's request limit. `kept` are the
/// transaction's spans already kept, in order.
func fitDescription(_ text: String, kept: [[String: Any]]) -> String {
  var room = 8_000
  for span in kept { if let description = span["description"] as? String { room -= max(0, description.count - 200) } }
  return String(text.prefix(min(2_000, 200 + max(0, room))))
}

/// The span `data` keys of an HTTP request (Sentry and OpenTelemetry names): method, status
/// code, host and `scheme://host[:port]/path`.
func httpSpanData(method: String, target: (host: String, authority: String, shown: String), statusCode: Int?) -> [String: Any] {
  var data: [String: Any] = ["http.request.method": String(method.uppercased().prefix(10)), "server.address": target.host, "url.full": target.shown]
  if let statusCode { data["http.response.status_code"] = statusCode }
  return data
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
  private let send: @Sendable ([String: Any]) async throws -> Bool
  private let name: String
  let op: String
  private let parentSpanId: String?
  private let release: String?
  private let environment: String?
  let clock: TraceClock
  let startedAt: Date
  let startNanos: UInt64
  private let lock = NSLock()
  private var spans: [[String: Any]] = []
  private var finished = false
  private var data: [String: Any] = [:]
  private var measurements: [String: Int] = [:]
  // Frame counts when the transaction started, while a display link is counting.
  private let framesAtStart: FrameCounts?
  // Called once, when the transaction finishes (the client forgets a finished screen load).
  var onFinish: (@Sendable (Transaction) -> Void)?
  // Its profile (Profiling.swift), when this transaction is profiled, and how to send it.
  var profiler: ProfileRecorder?
  var sendProfile: (@Sendable ([String: Any]) async -> Void)?

  /// Whether `finish` has been called: a finished transaction takes no more spans.
  public var isFinished: Bool { lock.withLock { finished } }
  var spanCount: Int { lock.withLock { spans.count } }

  init(send: @escaping @Sendable ([String: Any]) async throws -> Bool, name: String, op: String, traceId: String, parentSpanId: String?, sampled: Bool, release: String?, environment: String?, clock: TraceClock, frames: FrameStats = .shared) {
    self.send = send
    self.name = scrubbed(name, limit: 200, scrubDescription)
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
    self.framesAtStart = frames.counting ? frames.snapshot : nil
    self.frames = frames
  }

  private let frames: FrameStats

  /// Start a child span; `finish` it when the work ends. At most 50 are kept. `data` holds
  /// attributes the server indexes, such as `http.response.status_code`, `db.system`,
  /// `cache.hit`, `cache.key` or `messaging.destination.name` (scalar values only).
  public func startSpan(_ op: String, description: String? = nil, data: [String: Any] = [:]) -> Span {
    Span(transaction: self, parentSpanId: spanId, op: op, description: description, data: data, clock: clock)
  }

  /// Run `work` in a span, finished as an error if it throws (the error is rethrown).
  public func span<T>(_ op: String, description: String? = nil, data: [String: Any] = [:], _ work: (Span) throws -> T) rethrows -> T {
    let span = startSpan(op, description: description, data: data)
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
  public func span<T>(_ op: String, description: String? = nil, data: [String: Any] = [:], _ work: (Span) async throws -> T) async rethrows -> T {
    let span = startSpan(op, description: description, data: data)
    do {
      let value = try await work(span)
      span.finish()
      return value
    } catch {
      span.finish(.error)
      throw error
    }
  }

  /// An attribute of the transaction itself, sent as its `data` (scalar values only).
  public func setData(_ key: String, _ value: Any) {
    let kept = spanData([key: value])
    lock.withLock { data.merge(kept) { _, new in new } }
  }

  /// A measurement sent as a flat whole-number property, such as `ttfd_ms` or your own
  /// `items_loaded`. Lower-case letters, digits and `_`, up to 40 characters.
  public func setMeasurement(_ name: String, value: Int) {
    guard !name.isEmpty, name.count <= 40, name.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }) else { return }
    lock.withLock { if !finished { measurements[name] = value } }
  }

  func measurement(_ name: String) -> Int? { lock.withLock { measurements[name] } }

  /// The screen drew its first frame: `ttid_ms` and a `ui.load.initial_display` span from
  /// the start of the transaction. Once.
  @discardableResult
  func markInitialDisplay(at nanos: UInt64? = nil) -> Bool {
    markDisplay(measurement: "ttid_ms", op: "ui.load.initial_display", description: "\(name) initial display", at: nanos)
  }

  /// The screen has its content (`reportFullyDisplayed`): `ttfd_ms` and a
  /// `ui.load.full_display` span. Once.
  @discardableResult
  func markFullDisplay(at nanos: UInt64? = nil) -> Bool {
    markDisplay(measurement: "ttfd_ms", op: "ui.load.full_display", description: "\(name) full display", at: nanos)
  }

  private func markDisplay(measurement: String, op: String, description: String, at nanos: UInt64?) -> Bool {
    let end = nanos ?? clock.nanos()
    let elapsed = milliseconds(end &- startNanos)
    let fresh: Bool = lock.withLock {
      if finished || measurements[measurement] != nil { return false }
      measurements[measurement] = elapsed
      return true
    }
    guard fresh else { return false }
    add(span: ["span_id": randomHex(8), "parent_span_id": spanId, "op": op, "description": String(description.prefix(200)), "start_offset_ms": 0, "duration_ms": elapsed, "status": SpanStatus.ok.rawValue])
    return true
  }

  /// A W3C `traceparent` header value that continues this trace in another service.
  public func traceparent() -> String { "00-\(traceId)-\(spanId)-\(sampled ? "01" : "00")" }

  /// Set `traceparent` on an outgoing request, so the service it calls joins this trace. Only
  /// call it for your own services: the header tells whoever receives it the trace id.
  public func propagate(_ request: inout URLRequest) {
    request.setValue(traceparent(), forHTTPHeaderField: "traceparent")
  }

  func add(span: [String: Any]) {
    lock.withLock {
      guard !finished && spans.count < 50 else { return }
      var span = span
      if let text = span["description"] as? String { span["description"] = fitDescription(text, kept: spans) }
      spans.append(span)
    }
  }

  /// An `http.client` span for a request that has already finished, timed by the wall clock
  /// (`URLSessionTaskMetrics` gives dates). A request that began before the transaction is
  /// not part of it and is left out.
  func addHTTPSpan(method: String, target: (host: String, authority: String, shown: String), statusCode: Int?, interval: DateInterval, ok: Bool) {
    let offset = interval.start.timeIntervalSince(startedAt)
    guard offset >= 0 else { return }
    add(span: [
      "span_id": randomHex(8),
      "parent_span_id": spanId,
      "op": "http.client",
      "description": scrubbed("\(method.uppercased().prefix(10)) \(target.shown)", limit: 2_000, scrubDescription),
      "start_offset_ms": Int((offset * 1000).rounded()),
      "duration_ms": Int((max(0, interval.duration) * 1000).rounded()),
      "status": (ok ? SpanStatus.ok : SpanStatus.error).rawValue,
      "data": spanData(httpSpanData(method: method, target: target, statusCode: statusCode)),
    ])
  }

  /// Send the transaction, once. It never throws, since telemetry must not break the work it
  /// measures. Returns whether it was sent: `false` when it is unsampled, already finished,
  /// dropped by `beforeSend`, or the send failed.
  @discardableResult
  public func finish(_ status: SpanStatus = .ok) async -> Bool {
    await finish(status, endNanos: nil)
  }

  /// `endNanos` ends it at a time already past (an app start ends at its first frame).
  func finish(_ status: SpanStatus, endNanos: UInt64?) async -> Bool {
    let end = endNanos ?? clock.nanos()
    let taken: (spans: [[String: Any]], data: [String: Any], measurements: [String: Int])? = lock.withLock {
      if finished { return nil }
      finished = true
      return (spans, data, measurements)
    }
    guard let taken else { return false }
    onFinish?(self)
    var profile: [String: Any]? = nil
    if let profiler {
      profiler.stop()
      profile = profiler.profile(name: name, traceId: traceId, spanId: spanId, release: release, environment: environment)
      self.profiler = nil
    }
    guard sampled else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var properties: [String: Any] = [
      "trace_id": traceId,
      "span_id": spanId,
      "name": name,
      "op": op,
      "status": status.rawValue,
      "started_at": formatter.string(from: startedAt),
      "duration_ms": min(3_600_000, milliseconds(end &- startNanos)),
      // A JSON string, as the other clients send it: properties stay flat scalars.
      "spans": (try? JSONSerialization.data(withJSONObject: taken.spans)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
    ]
    if !taken.data.isEmpty { properties["data"] = taken.data }
    for (key, value) in taken.measurements where properties[key] == nil { properties[key] = value }
    if let framesAtStart {
      let counted = frames.snapshot.since(framesAtStart)
      if counted.total > 0 {
        properties["frames_total"] = counted.total
        properties["frames_slow"] = counted.slow
        properties["frames_frozen"] = counted.frozen
      }
    }
    if let parentSpanId { properties["parent_span_id"] = parentSpanId }
    if let release { properties["release"] = release }
    if let environment { properties["environment"] = environment }
    if let profile, let id = profile["event_id"] as? String {
      properties["profile_id"] = id
      await sendProfile?(profile)
    }
    do {
      return try await send(properties)
    } catch {
      return false
    }
  }
}

/// A timed piece of work inside a `Transaction`: a query, an outgoing call.
public final class Span: @unchecked Sendable {
  public let spanId: String
  private let transaction: Transaction
  private let parentSpanId: String
  private let op: String
  private var description: String?
  private let clock: TraceClock
  private let startNanos: UInt64
  private let lock = NSLock()
  private var finished = false
  private var data: [String: Any]

  init(transaction: Transaction, parentSpanId: String, op: String, description: String?, data: [String: Any], clock: TraceClock) {
    self.transaction = transaction
    self.parentSpanId = parentSpanId
    self.op = op
    self.description = description.map { scrubbed($0, limit: 2_000, scrubDescription) }
    self.clock = clock
    self.spanId = randomHex(8)
    self.startNanos = clock.nanos()
    self.data = spanData(data)
  }

  /// A span inside this one (its `parent_span_id` is this span). It counts towards the
  /// transaction's 50.
  public func startChild(_ op: String, description: String? = nil, data: [String: Any] = [:]) -> Span {
    Span(transaction: transaction, parentSpanId: spanId, op: op, description: description, data: data, clock: clock)
  }

  /// An attribute the server indexes (`http.response.status_code`, `db.system`,
  /// `cache.hit`…): a string, number or boolean.
  public func setData(_ key: String, _ value: Any) {
    let kept = spanData([key: value])
    lock.withLock { data.merge(kept) { _, new in new } }
  }

  /// Set the description once the work is done (a file's size is known after it is read).
  func describe(_ text: String) {
    let scrubbedText = scrubbed(text, limit: 2_000, scrubDescription)
    lock.withLock { description = scrubbedText }
  }

  /// A `traceparent` whose parent is this span, for the outgoing call it measures.
  public func traceparent() -> String { "00-\(transaction.traceId)-\(spanId)-\(transaction.sampled ? "01" : "00")" }

  /// Set `traceparent` on the outgoing request this span measures (your own services only).
  public func propagate(_ request: inout URLRequest) {
    request.setValue(traceparent(), forHTTPHeaderField: "traceparent")
  }

  /// Finish the span, once; later calls do nothing.
  public func finish(_ status: SpanStatus = .ok) {
    let kept: [String: Any]? = lock.withLock {
      if finished { return nil }
      finished = true
      return data
    }
    guard let kept else { return }
    var span: [String: Any] = [
      "span_id": spanId,
      "parent_span_id": parentSpanId,
      "op": op,
      "start_offset_ms": milliseconds(startNanos &- transaction.startNanos),
      "duration_ms": milliseconds(clock.nanos() &- startNanos),
      "status": status.rawValue,
    ]
    if let description = lock.withLock({ description }) { span["description"] = description }
    if !kept.isEmpty { span["data"] = kept }
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
