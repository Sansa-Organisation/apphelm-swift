import Foundation

/// AppHelm's answer to `captureFeedback`: the stored feedback's id, the customer profile it
/// was linked to (if any), and whether this was a replay of an earlier identical send.
public struct FeedbackResult: Sendable, Decodable, Equatable {
  public let id: String
  public let profileId: String?
  public let replayed: Bool
}

private struct FeedbackEnvelope: Decodable {
  let data: FeedbackResult
}

// MARK: Crons

/// A cron check-in's status.
public enum CheckInStatus: String, Sendable {
  case inProgress = "in_progress"
  case ok
  case error
}

/// When a monitored job should run: a crontab expression (`0 * * * *`) or every `minutes`
/// minutes (1 to 10,080).
public enum MonitorSchedule: Sendable, Equatable {
  case crontab(String)
  case interval(minutes: Int)
}

/// Creates or updates the monitor when sent with a check-in, so the schedule lives next to the
/// job. `name` is its display name (default: the slug); `checkinMarginMinutes` (1–1440) how late
/// a run may start before it counts as missed; `maxRuntimeMinutes` (1–1440) how long a run may
/// take before it counts as failed.
public struct MonitorConfig: Sendable, Equatable {
  public var schedule: MonitorSchedule
  public var name: String?
  public var checkinMarginMinutes: Int?
  public var maxRuntimeMinutes: Int?

  public init(schedule: MonitorSchedule, name: String? = nil, checkinMarginMinutes: Int? = nil, maxRuntimeMinutes: Int? = nil) {
    self.schedule = schedule
    self.name = name
    self.checkinMarginMinutes = checkinMarginMinutes
    self.maxRuntimeMinutes = maxRuntimeMinutes
  }

  /// The wire form, or an `ApphelmError` (`invalid_monitor_config`) naming what is wrong.
  func wire() throws -> [String: Any] {
    func invalid(_ message: String) -> ApphelmError { ApphelmError(message: message, status: 0, code: "invalid_monitor_config") }
    var schedule: [String: Any]
    switch self.schedule {
    case .crontab(let expression):
      let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw invalid("A crontab schedule needs an expression, such as \"0 * * * *\".") }
      schedule = ["type": "crontab", "value": trimmed]
    case .interval(let minutes):
      guard (1...10_080).contains(minutes) else { throw invalid("An interval schedule is 1 to 10080 minutes.") }
      schedule = ["type": "interval", "value": minutes]
    }
    var config: [String: Any] = ["schedule": schedule]
    if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { config["name"] = String(name.prefix(200)) }
    if let margin = checkinMarginMinutes {
      guard (1...1_440).contains(margin) else { throw invalid("checkinMarginMinutes is 1 to 1440.") }
      config["checkinMarginMinutes"] = margin
    }
    if let runtime = maxRuntimeMinutes {
      guard (1...1_440).contains(runtime) else { throw invalid("maxRuntimeMinutes is 1 to 1440.") }
      config["maxRuntimeMinutes"] = runtime
    }
    return config
  }
}

/// AppHelm's answer to a check-in.
public struct CheckInResult: Sendable, Decodable, Equatable {
  public let id: String
  public let monitorId: String
  public let status: String
}

private struct CheckInEnvelope: Decodable {
  let data: CheckInResult
}

/// A new check-in id: `chk_` and 32 hex characters.
public func newCheckInId() -> String { "chk_" + randomHex(16) }

private func isMonitorSlug(_ value: String) -> Bool {
  guard let first = value.utf8.first, value.utf8.count <= 64 else { return false }
  let lowerOrDigit: (UInt8) -> Bool = { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
  return lowerOrDigit(first) && value.utf8.dropFirst().allSatisfy { lowerOrDigit($0) || $0 == 95 || $0 == 45 }
}

private func isCheckInId(_ value: String) -> Bool {
  guard value.hasPrefix("chk_") else { return false }
  let rest = value.dropFirst(4)
  return (8...76).contains(rest.utf8.count) && rest.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 }
}

extension ApphelmClient {
  /// Feedback from a person, optionally about an error (Sentry's `captureFeedback`): pass the
  /// id `lastEventId` (or `captureEvent`) gave, and the feedback shows on that error's issue.
  /// It is stored as `human` feedback with `private_analysis` permission
  /// (`POST /api/v1/feedback`; the key needs `feedback:write`). Emails, keys and tokens in the
  /// message are scrubbed first, and it is cut to 5,000 characters.
  ///
  /// `name` and `email` are accepted so Sentry calls compile, and are never sent: AppHelm keeps
  /// no contact details with feedback (its Sentry endpoint drops them too).
  ///
  /// Returns AppHelm's answer, or nil when the client is disabled, closed or opted out. Throws
  /// `ApphelmError` (`invalid_feedback`) for an empty message, and when the server refuses it.
  @discardableResult
  public func captureFeedback(_ message: String, associatedEventId: String? = nil, name: String? = nil, email: String? = nil) async throws -> FeedbackResult? {
    _ = (name, email)
    let text = scrubbed(message.trimmingCharacters(in: .whitespacesAndNewlines), limit: 5_000).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw ApphelmError(message: "captureFeedback needs a message.", status: 0, code: "invalid_feedback") }
    guard isActive, !isOptedOut else {
      debugLog("feedback dropped (disabled)")
      return nil
    }
    let id = UUID().uuidString.lowercased()
    var metadata: [String: Any] = ["source": "apphelm-sdk"]
    if let release = options.release { metadata["release"] = release }
    if let environment = options.environment { metadata["environment"] = environment }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var body: [String: Any] = [
      "productId": options.productId, "sourceType": "human", "sourceId": "sdk:\(id)", "text": text,
      "occurredAt": formatter.string(from: Date()), "permission": "private_analysis", "metadata": metadata,
    ]
    if let eventId = associatedEventId?.trimmingCharacters(in: .whitespacesAndNewlines), isClientEventId(eventId) { body["eventId"] = eventId }
    do {
      let envelope: FeedbackEnvelope = try await send(path: "/feedback", body: body, headers: ["idempotency-key": "sdk-feedback-\(id)"])
      return envelope.data
    } catch {
      debugLog("sending feedback failed: \(error)")
      throw error
    }
  }

  /// Send one cron check-in (`POST /api/v1/check-ins`; the key needs `events:write`):
  /// `.inProgress` when a run starts, then `.ok` or `.error` with the same `checkInId`
  /// (`newCheckInId()`) and `durationMs`; or one `.ok`/`.error` alone, which closes the
  /// monitor's newest open run. `monitorConfig` creates or updates the monitor. `withMonitor`
  /// does a whole run for you. The same call as the Kotlin client's.
  ///
  /// Throws `ApphelmError` for a malformed `monitor` slug (a lower-case letter or digit, then up
  /// to 63 of `a-z 0-9 _ -`), `checkInId` (`chk_` and 8 to 76 of `A-Z a-z 0-9 _ -`), negative
  /// duration or invalid config. Delivery never throws: returns AppHelm's answer, or nil when
  /// the check-in could not be delivered, was refused, or the client is disabled or closed.
  /// Check-ins carry no event data and skip `beforeSend`.
  @discardableResult
  public func checkIn(_ monitor: String, status: CheckInStatus, checkInId: String? = nil, durationMs: Int? = nil, monitorConfig: MonitorConfig? = nil) async throws -> CheckInResult? {
    guard isMonitorSlug(monitor) else {
      throw ApphelmError(message: "The monitor slug \"\(monitor)\" must be a lowercase letter or digit, then up to 63 of a-z, 0-9, _ and -.", status: 0, code: "invalid_monitor")
    }
    if let checkInId, !isCheckInId(checkInId) {
      throw ApphelmError(message: "A check-in id is \"chk_\" and 8 to 76 of A-Z, a-z, 0-9, _ and -; use newCheckInId().", status: 0, code: "invalid_check_in_id")
    }
    if let durationMs, durationMs < 0 { throw ApphelmError(message: "durationMs can't be negative.", status: 0, code: "invalid_duration") }
    var body: [String: Any] = ["productId": options.productId, "monitor": monitor, "status": status.rawValue]
    if let checkInId { body["checkInId"] = checkInId }
    if let durationMs { body["durationMs"] = durationMs }
    if let monitorConfig { body["monitorConfig"] = try monitorConfig.wire() }
    guard isActive else {
      debugLog("check-in dropped (disabled)")
      return nil
    }
    do {
      let envelope: CheckInEnvelope = try await send(path: "/check-ins", body: body)
      return envelope.data
    } catch {
      debugLog("check-in for \(monitor) failed: \(error)")
      return nil
    }
  }

  /// Run `job` as one monitored run of a cron job: an `.inProgress` check-in with a new id (and
  /// `monitorConfig`, to create or update the monitor), then `.ok` with the run's duration, or
  /// `.error` when `job` throws, which is then rethrown. Returns what `job` returns. A check-in
  /// that can't be delivered never fails the job; a malformed slug or config throws before it
  /// runs.
  public func withMonitor<T>(_ monitor: String, monitorConfig: MonitorConfig? = nil, _ job: () async throws -> T) async throws -> T {
    guard isMonitorSlug(monitor) else {
      throw ApphelmError(message: "The monitor slug \"\(monitor)\" must be a lowercase letter or digit, then up to 63 of a-z, 0-9, _ and -.", status: 0, code: "invalid_monitor")
    }
    if let monitorConfig { _ = try monitorConfig.wire() }
    let id = newCheckInId()
    _ = try? await checkIn(monitor, status: .inProgress, checkInId: id, monitorConfig: monitorConfig)
    let started = DispatchTime.now().uptimeNanoseconds
    func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000) }
    let result: T
    do {
      result = try await job()
    } catch {
      _ = try? await checkIn(monitor, status: .error, checkInId: id, durationMs: elapsed())
      throw error
    }
    _ = try? await checkIn(monitor, status: .ok, checkInId: id, durationMs: elapsed())
    return result
  }
}
