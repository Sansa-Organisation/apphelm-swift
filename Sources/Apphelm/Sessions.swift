import Foundation

/// A session as remembered on disk, so a crash sent on the next launch can name the session,
/// release and environment it happened in rather than those of the launch that sends it.
struct StoredSession: Codable, Equatable {
  var hash: String
  var release: String
  var environment: String?
  /// Seconds since 1970.
  var startedAt: Double
  var endedAt: Double?
}

/// The last few sessions, kept next to the crash reports. A crash report is matched to the
/// session that was running when it was written, by the report file's modification time: the
/// crash report format carries no session, and a signal handler can't add one safely.
enum SessionLedger {
  static let file = "sessions.json"
  static let kept = 10

  static func load(directory: URL) -> [StoredSession] {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return [] }
    return (try? JSONDecoder().decode([StoredSession].self, from: data)) ?? []
  }

  private static func save(_ sessions: [StoredSession], directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(Array(sessions.suffix(kept))) {
      try? data.write(to: directory.appendingPathComponent(file), options: .atomic)
    }
  }

  static func record(_ session: StoredSession, directory: URL) {
    save(load(directory: directory).filter { $0.hash != session.hash } + [session], directory: directory)
  }

  static func end(hash: String, at date: Date, directory: URL) {
    var sessions = load(directory: directory)
    guard let index = sessions.firstIndex(where: { $0.hash == hash }) else { return }
    sessions[index].endedAt = date.timeIntervalSince1970
    save(sessions, directory: directory)
  }

  /// The session running at `date`: the latest one started at or before it that had not
  /// already ended by then.
  static func session(at date: Date, in sessions: [StoredSession]) -> StoredSession? {
    let time = date.timeIntervalSince1970
    guard let candidate = sessions.filter({ $0.startedAt <= time }).max(by: { $0.startedAt < $1.startedAt }) else { return nil }
    if let ended = candidate.endedAt, ended < time { return nil }
    return candidate
  }

  /// The session a stored crash report belongs to, or nil when none was running.
  static func session(forReport report: URL, directory: URL) -> StoredSession? {
    guard let written = (try? FileManager.default.attributesOfItem(atPath: report.path))?[.modificationDate] as? Date else { return nil }
    return session(at: written, in: load(directory: directory))
  }
}
