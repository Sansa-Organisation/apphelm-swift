import Foundation

/// A log line's level, as OpenTelemetry severities (trace 1, debug 5, info 9, warn 13,
/// error 17, fatal 21).
public enum LogLevel: String, Sendable, CaseIterable {
  case trace, debug, info, warn, error, fatal

  var rank: Int {
    switch self {
    case .trace: return 0
    case .debug: return 1
    case .info: return 2
    case .warn: return 3
    case .error: return 4
    case .fatal: return 5
    }
  }

  var severityNumber: Int { [1, 5, 9, 13, 17, 21][rank] }
}

/// One log line, as `beforeSendLog` sees it: already scrubbed. Attribute values are strings,
/// numbers, booleans, dates, arrays and dictionaries of them.
public struct LogRecord: @unchecked Sendable {
  public var level: LogLevel
  public var message: String
  public var attributes: [String: Any]
  public var timestamp: Date

  public init(level: LogLevel, message: String, attributes: [String: Any] = [:], timestamp: Date = Date()) {
    self.level = level
    self.message = message
    self.attributes = attributes
    self.timestamp = timestamp
  }
}

/// Structured logs to AppHelm, from `ApphelmClient.logger`: the call shape of Apple's
/// `os.Logger` (`trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`, `fault`)
/// plus attributes. Apple's `os.Logger` can't be read back by an app, so lines you want in
/// AppHelm go through this logger (log to both if you also want them in Console).
///
/// Lines are scrubbed (secrets, emails, query strings) before `beforeSendLog` sees them,
/// batched (every 2 s or 500 lines) and sent as OpenTelemetry records to `/api/v1/logs`. A
/// line logged while a transaction runs carries its trace and span id. Sending never throws.
public final class ApphelmLogger: @unchecked Sendable {
  let sink: LogSink
  let attributes: [String: Any]

  init(sink: LogSink, attributes: [String: Any]) {
    self.sink = sink
    self.attributes = attributes
  }

  /// Lines dropped because the queue was full, a batch was refused or sending failed twice.
  public var dropped: Int { sink.droppedCount }

  /// Log `message` at `level`, with `attributes` (an `Error` value becomes `exception.type`
  /// and `exception.message`).
  public func log(_ level: LogLevel, _ message: String, attributes: [String: Any] = [:]) {
    guard sink.accepting, level.rank >= sink.minLevel.rank else { return }
    var merged = self.attributes
    merged.merge(attributes) { _, own in own }
    if merged["trace_id"] == nil, let context = sink.traceContext() {
      merged["trace_id"] = context.traceId
      merged["span_id"] = context.spanId
    }
    var record: LogRecord? = LogRecord(level: level, message: scrubbed(message, limit: scrubInputLimit), attributes: scrubLogAttributes(flattenLogAttributes(merged)))
    if let hook = sink.beforeSendLog, let offered = record { record = hook(offered) }
    guard let record else {
      sink.debug("log line dropped by beforeSendLog")
      return
    }
    sink.push(record)
  }

  public func trace(_ message: String, attributes: [String: Any] = [:]) { log(.trace, message, attributes: attributes) }
  public func debug(_ message: String, attributes: [String: Any] = [:]) { log(.debug, message, attributes: attributes) }
  public func info(_ message: String, attributes: [String: Any] = [:]) { log(.info, message, attributes: attributes) }
  /// `os.Logger`'s `notice`: sent as `info`.
  public func notice(_ message: String, attributes: [String: Any] = [:]) { log(.info, message, attributes: attributes) }
  public func warning(_ message: String, attributes: [String: Any] = [:]) { log(.warn, message, attributes: attributes) }
  /// The same as `warning` (the Node and Python name).
  public func warn(_ message: String, attributes: [String: Any] = [:]) { log(.warn, message, attributes: attributes) }
  public func error(_ message: String, attributes: [String: Any] = [:]) { log(.error, message, attributes: attributes) }
  /// `os.Logger`'s `critical`: sent as `fatal`.
  public func critical(_ message: String, attributes: [String: Any] = [:]) { log(.fatal, message, attributes: attributes) }
  /// `os.Logger`'s `fault`: sent as `fatal`.
  public func fault(_ message: String, attributes: [String: Any] = [:]) { log(.fatal, message, attributes: attributes) }
  public func fatal(_ message: String, attributes: [String: Any] = [:]) { log(.fatal, message, attributes: attributes) }

  /// A logger whose lines all carry `attributes`, sharing this one's queue.
  public func child(_ attributes: [String: Any]) -> ApphelmLogger {
    var merged = self.attributes
    merged.merge(attributes) { _, own in own }
    return ApphelmLogger(sink: sink, attributes: merged)
  }

  /// Send the queued lines, waiting at most `timeout` seconds: true when all were sent (or
  /// refused for good) in time. `ApphelmClient.flush(timeout:)` and `close` include it.
  @discardableResult
  public func flush(timeout: TimeInterval = 2) async -> Bool {
    await waitAtMost(timeout) { [sink] in await sink.drainAll() }
  }

  func drainAll() async { await sink.drainAll() }
  func shutdown() { sink.shutdown() }
}

/// Ids that look like hex tokens but name a trace or a person: never scrubbed.
private let idAttributes: Set<String> = ["trace_id", "span_id", "session_id", "$session_id", "distinct_id"]

/// Errors as OpenTelemetry exception attributes; everything else as it is.
func flattenLogAttributes(_ attributes: [String: Any]) -> [String: Any] {
  var out: [String: Any] = [:]
  for (key, value) in attributes {
    if let error = value as? Error, !(value is String), !(value is NSNumber) {
      out["exception.type"] = String(describing: type(of: error))
      out["exception.message"] = String(describing: error)
      continue
    }
    out[key] = value
  }
  return out
}

private func scrubLogValue(_ value: Any, depth: Int) -> Any {
  switch value {
  case let text as String: return scrubbed(text, limit: scrubInputLimit)
  case let list as [Any] where depth < 3: return list.map { scrubLogValue($0, depth: depth + 1) }
  case let map as [String: Any] where depth < 3: return map.mapValues { scrubLogValue($0, depth: depth + 1) }
  default: return value
  }
}

/// Every string in the attributes through the shared scrubber (Scrub.swift); a stack trace frame
/// by frame. Trace, span and person ids stay.
func scrubLogAttributes(_ attributes: [String: Any]) -> [String: Any] {
  var out: [String: Any] = [:]
  for (key, value) in attributes {
    if key == "exception.stacktrace", let stack = value as? String {
      out[key] = String(stack.prefix(8_000)).split(separator: "\n", omittingEmptySubsequences: false).map { scrubFrame(String($0)) }.joined(separator: "\n")
    } else {
      out[key] = idAttributes.contains(key) ? value : scrubLogValue(value, depth: 0)
    }
  }
  return out
}

private func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

/// An OpenTelemetry AnyValue (JSON encoding).
func otlpAnyValue(_ value: Any, depth: Int = 0) -> [String: Any] {
  switch value {
  case let text as String: return ["stringValue": text]
  case let number as NSNumber where isBoolean(number): return ["boolValue": number.boolValue]
  case let flag as Bool: return ["boolValue": flag]
  case let number as Int: return ["intValue": String(number)]
  case let number as Int64: return ["intValue": String(number)]
  case let number as Double: return number.isFinite ? ["doubleValue": number] : ["stringValue": String(number)]
  case let number as NSNumber:
    if CFNumberIsFloatType(number) { return number.doubleValue.isFinite ? ["doubleValue": number.doubleValue] : ["stringValue": number.stringValue] }
    return ["intValue": number.stringValue]
  case let date as Date:
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ["stringValue": formatter.string(from: date)]
  case let list as [Any] where depth < 3:
    return ["arrayValue": ["values": list.prefix(50).map { otlpAnyValue($0, depth: depth + 1) }]]
  case let map as [String: Any] where depth < 3:
    return ["kvlistValue": ["values": map.sorted { $0.key < $1.key }.prefix(50).map { ["key": $0.key, "value": otlpAnyValue($0.value, depth: depth + 1)] }]]
  default:
    return ["stringValue": String(describing: value)]
  }
}

/// A line as an OTLP/JSON log record. `trace_id` (32 hex) and `span_id` (16 hex) attributes
/// become the record's trace context.
func otlpLogRecord(_ record: LogRecord) -> [String: Any] {
  var attributes = record.attributes
  var out: [String: Any] = [
    "timeUnixNano": "\(Int64((record.timestamp.timeIntervalSince1970 * 1000).rounded()))000000",
    "severityNumber": record.level.severityNumber,
    "severityText": record.level.rawValue.uppercased(),
    "body": ["stringValue": record.message],
  ]
  if let trace = (attributes["trace_id"] as? String)?.lowercased(), trace.count == 32, isLowerHex(trace[...], count: 32) {
    out["traceId"] = trace
    attributes.removeValue(forKey: "trace_id")
  }
  if let span = (attributes["span_id"] as? String)?.lowercased(), span.count == 16, isLowerHex(span[...], count: 16) {
    out["spanId"] = span
    attributes.removeValue(forKey: "span_id")
  }
  out["attributes"] = attributes.sorted { $0.key < $1.key }.map { ["key": $0.key, "value": otlpAnyValue($0.value)] }
  return out
}

/// The queue behind a client's logger: bounded, batched, sent on a timer and when a batch is
/// full, one batch at a time. A batch the server throttles (429 without `log_limit`) or fails
/// (5xx, network) is tried once more; any other refusal drops it.
final class LogSink: @unchecked Sendable {
  private struct Entry {
    var record: LogRecord
    var retried = false
  }

  private weak var client: ApphelmClient?
  private let options: ApphelmOptions
  private let session: URLSession
  private let lock = NSLock()
  private var queue: [Entry] = []
  private var dropped = 0
  private var timer: DispatchSourceTimer?
  private var tail: Task<Void, Never>?
  private var stopped = false
  private var batchFlushRunning = false

  init(client: ApphelmClient) {
    self.client = client
    self.options = client.options
    self.session = client.session
  }

  deinit { timer?.cancel() }

  var minLevel: LogLevel { options.logsMinLevel }
  var beforeSendLog: (@Sendable (LogRecord) -> LogRecord?)? { options.beforeSendLog }
  var droppedCount: Int { lock.withLock { dropped } }
  private var maxBatch: Int { max(1, options.logsMaxBatch) }
  private var maxQueue: Int { max(1, options.logsMaxQueue) }

  /// Whether a line may be queued: the client exists, is enabled and not closed.
  var accepting: Bool {
    guard let client, client.isActive else { return false }
    return !lock.withLock { stopped }
  }

  func traceContext() -> (traceId: String, spanId: String)? {
    guard let transaction = client?.activeTransaction else { return nil }
    return (transaction.traceId, transaction.spanId)
  }

  func debug(_ message: @autoclosure () -> String) { client?.debugLog(message()) }

  func push(_ record: LogRecord) {
    let flushNow: Bool = lock.withLock {
      if stopped { return false }
      queue.append(Entry(record: record))
      if queue.count > maxQueue {
        dropped += queue.count - maxQueue
        queue.removeFirst(queue.count - maxQueue)
      }
      if timer == nil, options.logsFlushIntervalSeconds > 0 { startTimer() }
      if queue.count >= maxBatch, !batchFlushRunning {
        batchFlushRunning = true
        return true
      }
      return false
    }
    if flushNow {
      Task {
        await self.drainAll()
        self.lock.withLock { self.batchFlushRunning = false }
      }
    }
  }

  /// Called with the lock held.
  private func startTimer() {
    let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    let interval = options.logsFlushIntervalSeconds
    source.schedule(deadline: .now() + interval, repeating: interval)
    source.setEventHandler { [weak self] in
      guard let self, self.lock.withLock({ !self.queue.isEmpty }) else { return }
      Task { await self.drainAll() }
    }
    source.resume()
    timer = source
  }

  /// Send everything queued now, after any send already running.
  func drainAll() async {
    let task: Task<Void, Never> = lock.withLock {
      let previous = tail
      let task = Task {
        await previous?.value
        await self.drain()
      }
      tail = task
      return task
    }
    await task.value
  }

  private func drain() async {
    while true {
      let batch: [Entry] = lock.withLock {
        let count = min(maxBatch, queue.count)
        defer { queue.removeFirst(count) }
        return Array(queue.prefix(count))
      }
      if batch.isEmpty { return }
      guard client?.isActive ?? false else {
        // Disabled or closed while lines waited: they are not sent.
        lock.withLock { dropped += batch.count }
        return
      }
      // After a failure the rest waits for the next flush, so a down endpoint is not hammered.
      if !(await send(batch)) { return }
    }
  }

  private func body(_ batch: [Entry]) -> [String: Any] {
    var resource: [[String: Any]] = [["key": "service.name", "value": ["stringValue": options.logsService?.isEmpty == false ? options.logsService! : "unknown_service"]]]
    if let release = options.release, !release.isEmpty { resource.append(["key": "service.version", "value": ["stringValue": release]]) }
    if let environment = options.environment, !environment.isEmpty { resource.append(["key": "deployment.environment", "value": ["stringValue": environment]]) }
    return ["resourceLogs": [["resource": ["attributes": resource], "scopeLogs": [["scope": ["name": "apphelm-swift"], "logRecords": batch.map { otlpLogRecord($0.record) }]]]]]
  }

  private func send(_ batch: [Entry]) async -> Bool {
    guard let url = URL(string: options.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/logs"),
          let data = try? JSONSerialization.data(withJSONObject: body(batch)) else {
      lock.withLock { dropped += batch.count }
      return false
    }
    var request = URLRequest(url: url, timeoutInterval: options.timeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("Bearer \(options.apiKey)", forHTTPHeaderField: "authorization")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(options.productId, forHTTPHeaderField: "x-apphelm-product")
    request.httpBody = data
    do {
      let (answer, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if (200...299).contains(status) { return true }
      let text = String(decoding: answer.prefix(300), as: UTF8.self)
      if (status == 429 && !text.contains("log_limit")) || status >= 500 { requeue(batch) } else { lock.withLock { dropped += batch.count } }
      debug("AppHelm refused \(batch.count) log lines (\(status))")
    } catch {
      requeue(batch)
      debug("sending \(batch.count) log lines failed: \(error)")
    }
    return false
  }

  private func requeue(_ batch: [Entry]) {
    lock.withLock {
      let again = batch.filter { !$0.retried }.map { entry -> Entry in
        var copy = entry
        copy.retried = true
        return copy
      }
      dropped += batch.count - again.count
      let room = max(0, maxQueue - queue.count)
      dropped += max(0, again.count - room)
      queue.insert(contentsOf: again.prefix(room), at: 0)
    }
  }

  /// Stop the timer and take no more lines (after `close`).
  func shutdown() {
    lock.withLock {
      stopped = true
      timer?.cancel()
      timer = nil
    }
  }
}
