import Foundation
import os

/// A pattern for `ignoreErrors`, `ignoreTransactions`, `denyUrls` and `allowUrls`: a plain
/// string matches as a substring (`"Timeout"`), `.regex("^Network")` by regular-expression search. String
/// literals are `.contains`.
public enum ApphelmPattern: Sendable, Hashable, ExpressibleByStringLiteral {
  case contains(String)
  case regex(String)

  public init(stringLiteral value: String) { self = .contains(value) }

  /// Whether `text` matches. An invalid regular expression matches nothing.
  public func matches(_ text: String) -> Bool {
    switch self {
    case .contains(let needle):
      return !needle.isEmpty && text.contains(needle)
    case .regex(let pattern):
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
      return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
  }
}

// MARK: denyUrls / allowUrls

/// The binary (image) of a stack line in `Thread.callStackSymbols` form:
/// `3   ShopKit   0x0000000100abc123 $s7ShopKit… + 52` gives `ShopKit`. Nil for any other line.
func stackFrameImage(_ line: String) -> String? {
  let parts = line.split(whereSeparator: \.isWhitespace)
  guard parts.count >= 3, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
        let address = parts.dropFirst(2).firstIndex(where: { $0.hasPrefix("0x") }) else { return nil }
  return parts[1..<address].joined(separator: " ")
}

/// Why `denyUrls` / `allowUrls` drop an error whose top frame is `frame`, or nil to keep it:
/// `denyUrls` when any deny pattern matches it, else `allowUrls` when `allow` is not empty and
/// none of it matches. An error without a frame is kept.
func urlFilterDropReason(frame: String?, deny: [ApphelmPattern], allow: [ApphelmPattern]) -> String? {
  guard let frame else { return nil }
  if deny.contains(where: { $0.matches(frame) }) { return "denyUrls" }
  if !allow.isEmpty && !allow.contains(where: { $0.matches(frame) }) { return "allowUrls" }
  return nil
}

// MARK: setContext

let maxContexts = 10
let maxContextKeys = 10
let maxContextTags = 10
private let sensitiveContextKey = try! NSRegularExpression(pattern: "pass|secret|token|auth|cookie|session|api[_-]?key|private|email|phone|ssn|card|iban", options: [.caseInsensitive])

/// `[A-Za-z0-9_-]{1,max}`.
func isContextIdentifier(_ value: String, max: Int) -> Bool {
  !value.isEmpty && value.utf8.count <= max && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 }
}

private func isSensitiveContextKey(_ key: String) -> Bool {
  sensitiveContextKey.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
}

/// A context value as it is kept: a string scrubbed like a breadcrumb (query strings, secrets
/// and emails out) and cut to 200, a boolean or a finite number; anything else is skipped.
func contextValue(_ value: Any) -> Any? {
  switch value {
  case let text as String: return scrubbed(text, limit: 200, scrubFrame)
  case let flag as Bool: return flag
  case let number as Int: return number
  case let number as Double: return number.isFinite ? number : nil
  case let number as Float: return number.isFinite ? Double(number) : nil
  case let number as NSNumber: return number.doubleValue.isFinite ? number : nil
  default: return nil
  }
}

/// A context's kept values: at most 10, valid keys only, no secret- or contact-looking keys.
func sanitizeContext(_ context: [String: Any]) -> [String: Any] {
  var kept: [String: Any] = [:]
  for (key, value) in context.sorted(by: { $0.key < $1.key }) {
    if kept.count >= maxContextKeys { break }
    guard isContextIdentifier(key, max: 30), !isSensitiveContextKey(key), let value = contextValue(value) else { continue }
    kept[key] = value
  }
  return kept
}

/// Set (or with nil remove) context `name` in `contexts`: at most 10 contexts.
func applyContext(_ contexts: inout [String: [String: Any]], _ name: String, _ context: [String: Any]?) {
  guard isContextIdentifier(name, max: 20) else { return }
  guard let context else {
    contexts.removeValue(forKey: name)
    return
  }
  let kept = sanitizeContext(context)
  if kept.isEmpty {
    contexts.removeValue(forKey: name)
  } else if contexts[name] != nil || contexts.count < maxContexts {
    contexts[name] = kept
  }
}

/// Contexts as `context.<name>.<key>` tags in the room `tags` leaves: at most 10 of them and
/// 20 tags in all, only those whose name fits in 40 characters, never replacing a tag.
func addContextTags(_ tags: inout [String: Any], _ contexts: [String: [String: Any]]) {
  var added = 0
  for (name, values) in contexts.sorted(by: { $0.key < $1.key }) {
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
      if added >= maxContextTags || tags.count >= 20 { return }
      let tag = "context.\(name).\(key)"
      if tag.utf8.count > 40 || tags[tag] != nil { continue }
      tags[tag] = value
      added += 1
    }
  }
}

// MARK: captureEvent

/// A hand-built error event for `captureEvent` (Sentry's `captureEvent`). It needs a `message`
/// or an `exception`, and is sent exactly as `captureException` (with an exception) or
/// `captureMessage` (a message only) would send it: the same scope, scrubbing and hooks.
public struct ApphelmEvent: @unchecked Sendable {
  /// An error as text: its type (`URLError`), its message and, optionally, a stack trace
  /// (one frame per line).
  public struct Exception: Sendable {
    public var type: String
    public var value: String
    public var stacktrace: String?
    public init(type: String, value: String, stacktrace: String? = nil) {
      self.type = type
      self.value = value
      self.stacktrace = stacktrace
    }
  }

  public var message: String?
  /// Default `.error` with an exception, else `.info`.
  public var level: MessageLevel?
  public var exception: Exception?
  public var fingerprint: [String]?
  public var tags: [String: String]
  /// Named groups for this event only, applied as `setContext` would.
  public var contexts: [String: [String: Any]]
  /// This event's release and environment instead of the client's.
  public var release: String?
  public var environment: String?
  /// Your own id (8–64 letters, digits, `_` or `-`); another is generated otherwise.
  public var eventId: String?

  public init(message: String? = nil, level: MessageLevel? = nil, exception: Exception? = nil, fingerprint: [String]? = nil, tags: [String: String] = [:], contexts: [String: [String: Any]] = [:], release: String? = nil, environment: String? = nil, eventId: String? = nil) {
    self.message = message
    self.level = level
    self.exception = exception
    self.fingerprint = fingerprint
    self.tags = tags
    self.contexts = contexts
    self.release = release
    self.environment = environment
    self.eventId = eventId
  }
}

/// An SDK event id: 8–64 letters, digits, `_` or `-`.
func isClientEventId(_ value: String) -> Bool { isContextIdentifier(value, max: 64) && value.utf8.count >= 8 }

private let sdkLog = Logger(subsystem: "dev.apphelm", category: "sdk")

extension ApphelmClient {
  /// Enabled and not closed: whether anything may be sent.
  var isActive: Bool { options.enabled && !lock.withLock { closed } }

  /// One line of the SDK's own diagnostics, when `debug` is on.
  func debugLog(_ message: @autoclosure () -> String) {
    guard options.debug else { return }
    let text = message()
    sdkLog.notice("Apphelm: \(text, privacy: .public)")
    debugObserver?(text)
  }

  /// A new event id (a lower-case UUID, as the Node client makes).
  func newEventId() -> String { UUID().uuidString.lowercased() }

  /// Why an error is not sent, or nil to send it: `enabled` (and `close`), then
  /// `ignoreErrors`, then `denyUrls` and `allowUrls` (on `frame`, the binary of the error's
  /// top stack frame, when it has one), then `sampleRate`, as Sentry's SDKs order them.
  func errorDropReason(type: String, message: String, frame: String? = nil) -> String? {
    if !isActive { return "disabled" }
    let candidates = type.isEmpty ? [message] : [message, type, "\(type): \(message)"]
    if options.ignoreErrors.contains(where: { pattern in candidates.contains { pattern.matches($0) } }) { return "ignoreErrors" }
    if let reason = urlFilterDropReason(frame: frame, deny: options.denyUrls, allow: options.allowUrls) { return reason }
    let rate = options.sampleRate.isNaN ? 1 : min(1, max(0, options.sampleRate))
    if rate < 1 && !(rate > 0 && Double.random(in: 0..<1) < rate) { return "sampleRate" }
    return nil
  }

  /// The event id of an error that passed the gates (it becomes `lastEventId`), or nil when
  /// it is dropped. `preferred` is the caller's own id, used when it is a valid one.
  func admitError(type: String, message: String, frame: String? = nil, preferred: String? = nil) -> String? {
    if let reason = errorDropReason(type: type, message: message, frame: frame) {
      debugLog("error dropped (\(reason))")
      return nil
    }
    let id = preferred.flatMap { isClientEventId($0) ? $0 : nil } ?? newEventId()
    lock.withLock { _lastEventId = id }
    return id
  }

  /// Send a hand-built error event (Sentry's `captureEvent`): see `ApphelmEvent`. Returns its
  /// event id, or nil when it was dropped (`enabled`, `ignoreErrors`, `denyUrls`, `allowUrls`,
  /// `sampleRate`, `beforeSend`, opted out). Throws `ApphelmError` (`invalid_event`) with neither a message
  /// nor an exception, and when the server refuses it.
  @discardableResult
  public func captureEvent(_ event: ApphelmEvent) async throws -> String? {
    let message = event.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !message.isEmpty || event.exception != nil else {
      throw ApphelmError(message: "captureEvent needs a message or an exception.", status: 0, code: "invalid_event")
    }
    let type = event.exception?.type ?? ""
    let text = event.exception.map { $0.value.isEmpty ? message : $0.value } ?? message
    let frames = (event.exception?.stacktrace ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    // denyUrls / allowUrls: the binary of the first line, when it is in callStackSymbols form.
    guard let eventId = admitError(type: type, message: text, frame: frames.first.flatMap(stackFrameImage), preferred: event.eventId) else { return nil }
    var properties: [String: Any] = ["$event_id": eventId, "message": scrubbed(text, limit: 240)]
    if let exception = event.exception {
      properties["name"] = String((exception.type.isEmpty ? "Error" : exception.type).prefix(80))
      properties["level"] = (event.level ?? .error).rawValue
      if !frames.isEmpty { properties["stack"] = CrashInstaller.boundedStack(frames) }
    } else {
      properties["name"] = "Message"
      properties["level"] = (event.level ?? .info).rawValue
    }
    if let fingerprint = event.fingerprint, !fingerprint.isEmpty {
      properties["fingerprint"] = fingerprint.prefix(10).map { String($0.prefix(200)) }
    }
    if let release = event.release?.trimmingCharacters(in: .whitespacesAndNewlines), !release.isEmpty { properties["release"] = String(release.prefix(120)) }
    if let environment = event.environment?.trimmingCharacters(in: .whitespacesAndNewlines), !environment.isEmpty { properties["environment"] = String(environment.prefix(40)) }
    var own: [String: [String: Any]] = [:]
    for (name, values) in event.contexts.sorted(by: { $0.key < $1.key }) { applyContext(&own, name, values) }
    addContext(&properties, callTags: event.tags, traceId: nil, eventContexts: own)
    return try await sendException(properties, eventId: eventId) ? eventId : nil
  }
}

/// Run `work` in its own task and wait for it at most `seconds`: true when it finished in
/// time, false otherwise. The work carries on after a timeout.
func waitAtMost(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> Void) async -> Bool {
  final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func arm(_ task: Task<Void, Never>) { lock.withLock { if continuation == nil { task.cancel() } else { timer = task } } }
    func resume(_ value: Bool) {
      let (taken, timer): (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) = lock.withLock {
        defer { continuation = nil; self.timer = nil }
        return (continuation, self.timer)
      }
      if value { timer?.cancel() }
      taken?.resume(returning: value)
    }
  }
  let nanos = UInt64(max(0, seconds.isFinite ? seconds : 0) * 1_000_000_000)
  return await withCheckedContinuation { continuation in
    let once = Once(continuation)
    Task {
      await work()
      once.resume(true)
    }
    once.arm(Task {
      try? await Task.sleep(nanoseconds: nanos)
      if !Task.isCancelled { once.resume(false) }
    })
  }
}
