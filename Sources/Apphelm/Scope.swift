import CryptoKit
import Foundation

/// How a user id travels with an exception: SHA-256 of `apphelm-user:<id>` (the id cut to 200
/// UTF-16 units, an unpaired surrogate written as U+FFFD), first 32 hex characters. The Node,
/// Python and Kotlin clients and the server compute the same hash.
func hashUserId(_ id: String) -> String {
  let cut = String(decoding: Array(id.utf16.prefix(200)), as: UTF16.self)
  return SHA256.hash(data: Data("apphelm-user:\(cut)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
}

private func isTagKey(_ key: String) -> Bool {
  !key.isEmpty && key.utf8.count <= 40 && key.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 46 || $0 == 45 }
}

/// A tag value the server keeps (a string up to 200, a boolean or a finite number), or nil.
func tagValue(_ value: Any?) -> Any? {
  switch value {
  case let text as String: return scrubbed(text, limit: 200)
  case let flag as Bool: return flag
  case let number as Int: return number
  case let number as Double: return number.isFinite ? number : nil
  case let number as NSNumber: return number.doubleValue.isFinite ? number : nil
  default: return nil
  }
}

/// A tag key the server keeps (`[A-Za-z0-9_.-]{1,40}` after trimming), or nil.
func tagKey(_ key: String) -> String? {
  let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
  return isTagKey(name) ? name : nil
}

/// Tags, a user and breadcrumbs for the events captured inside `ApphelmClient.withScope`,
/// on top of the client's own (`setTag`, `setUser`, `addBreadcrumb`). A scope belongs to
/// the task that runs the closure and the child tasks it starts (Swift task-locals), so two
/// requests or jobs running at once each report their own. It can also hold the
/// transaction automatic spans join (`transaction`).
public final class ApphelmScope: @unchecked Sendable {
  private let lock = NSLock()
  let parent: ApphelmScope?
  private var tags: [String: Any] = [:]
  private var contexts: [String: [String: Any]] = [:]
  private var user: String??
  private var _transaction: Transaction?
  let breadcrumbs: BreadcrumbBuffer
  private let accept: @Sendable (Breadcrumb) -> Breadcrumb?

  init(parent: ApphelmScope?, maxBreadcrumbs: Int, accept: @escaping @Sendable (Breadcrumb) -> Breadcrumb?) {
    self.parent = parent
    self.breadcrumbs = BreadcrumbBuffer(capacity: maxBreadcrumbs)
    self.accept = accept
  }

  /// A tag for the events captured in this scope (a string, number or boolean; nil removes
  /// it). It wins over the client's tag of the same name.
  public func setTag(_ key: String, _ value: Any?) {
    guard let name = tagKey(key) else { return }
    lock.withLock {
      if let scalar = tagValue(value) {
        if tags.count < 20 || tags[name] != nil { tags[name] = scalar }
      } else {
        tags.removeValue(forKey: name)
      }
    }
  }

  /// `setTag` for each entry.
  public func setTags(_ values: [String: Any?]) {
    for (key, value) in values { setTag(key, value) }
  }

  /// A named group of values for the events captured in this scope, sent as
  /// `context.<name>.<key>` tags (see `ApphelmClient.setContext`); nil removes it. It wins
  /// over the client's context of the same name.
  public func setContext(_ name: String, _ context: [String: Any]?) {
    lock.withLock { applyContext(&contexts, name, context) }
  }

  /// The signed-in user for the events captured in this scope; only its hash is sent. nil
  /// sends no user from this scope, even when the client has one.
  public func setUser(id: String?) {
    let hash: String? = id.flatMap { $0.isEmpty ? nil : hashUserId($0) }
    lock.withLock { user = .some(hash) }
  }

  /// A breadcrumb for the events captured in this scope (after `beforeBreadcrumb`).
  public func addBreadcrumb(_ crumb: Breadcrumb) {
    if let kept = accept(crumb) { breadcrumbs.add(kept) }
  }

  /// The transaction automatic spans and captured exceptions join inside this scope,
  /// instead of the client's `activeTransaction`.
  public var transaction: Transaction? {
    get { lock.withLock { _transaction } ?? parent?.transaction }
    set { lock.withLock { _transaction = newValue } }
  }

  /// This scope's tags over its parents', the innermost winning.
  var allTags: [String: Any] {
    var merged = parent?.allTags ?? [:]
    merged.merge(lock.withLock { tags }) { _, own in own }
    return merged
  }

  /// This scope's contexts over its parents', the innermost winning.
  var allContexts: [String: [String: Any]] {
    var merged = parent?.allContexts ?? [:]
    merged.merge(lock.withLock { contexts }) { _, own in own }
    return merged
  }

  /// This scope's own tags, contexts, user and breadcrumbs (configureScope copies them to the client).
  var own: (tags: [String: Any], contexts: [String: [String: Any]], user: String??, transaction: Transaction?) {
    lock.withLock { (tags, contexts, user, _transaction) }
  }

  /// `.some(hash)` when this scope or a parent set the user (`.some(nil)`: cleared).
  var userHash: String?? {
    if let own = lock.withLock({ user }) { return .some(own) }
    return parent?.userHash
  }

  var allBreadcrumbs: [Breadcrumb] { (parent?.allBreadcrumbs ?? []) + breadcrumbs.all }
}

enum ScopeContext {
  @TaskLocal static var current: ApphelmScope?
}

/// What a crash report needs to know about the run that crashed: its release, environment,
/// session, tags, user hash and breadcrumbs. A signal handler can't serialise anything, so
/// the client keeps it written to `scope-active.json` beside the crash file (rewritten in
/// the background each time it changes), and the next launch moves it aside with the crash.
/// An uncaught `NSException` embeds it in its report.
final class CrashScopeStore: @unchecked Sendable {
  static let shared = CrashScopeStore()
  static let activeFile = "scope-active.json"

  private let lock = NSLock()
  private var snapshot: [String: Any] = [:]
  private var file: URL?
  private var writing = false
  private let queue = DispatchQueue(label: "dev.apphelm.crash-scope", qos: .utility)

  /// Replace the snapshot; written to disk soon after, once crash reporting is installed.
  func update(_ value: [String: Any]) {
    let schedule: Bool = lock.withLock {
      snapshot = value
      if file == nil || writing { return false }
      writing = true
      return true
    }
    if schedule { queue.async { self.write() } }
  }

  /// Called by the crash installer after the previous run's file has been moved aside.
  func attach(directory: URL) {
    lock.withLock { file = directory.appendingPathComponent(Self.activeFile) }
    queue.sync { write() }
  }

  private func write() {
    let (value, target): ([String: Any], URL?) = lock.withLock {
      writing = false
      return (snapshot, file)
    }
    guard let target, !value.isEmpty, let data = try? JSONSerialization.data(withJSONObject: jsonSafe(value)) else { return }
    try? data.write(to: target, options: .atomic)
  }

  /// The snapshot now, for an uncaught exception's report. A lock held elsewhere (the
  /// crashing thread may hold it) gives nil rather than a deadlock.
  func current() -> [String: Any]? {
    guard lock.try() else { return nil }
    defer { lock.unlock() }
    return snapshot.isEmpty ? nil : snapshot
  }

  /// Wait for pending writes (tests).
  func drain() { queue.sync {} }

  /// Where the scope of signal report `crash-<id>.log` is: `scope-<id>.json`.
  static func file(for report: URL) -> URL? {
    let name = report.lastPathComponent
    guard report.pathExtension == "log", name.hasPrefix("crash-") else { return nil }
    return report.deletingLastPathComponent().appendingPathComponent("scope-" + name.dropFirst("crash-".count).dropLast(".log".count) + ".json")
  }
}
