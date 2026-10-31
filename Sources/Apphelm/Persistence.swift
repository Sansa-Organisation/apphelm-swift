import CryptoKit
import Foundation

/// Where the client keeps its event queue and its state (opt-out, anonymous id, super
/// properties, groups, the last app version seen).
public enum ApphelmPersistence: Sendable, Equatable {
  /// The default: the queue in `Application Support/Apphelm`, one folder per product, and
  /// the state in `UserDefaults.standard`. Queued events survive the app being killed.
  case disk
  /// The queue in `directory` and the state in the UserDefaults suite `suiteName`
  /// (`UserDefaults.standard` when nil). For an app group, or to keep two clients apart.
  case directory(URL, suiteName: String? = nil)
  /// Nothing is written. Queued events are lost when the app is killed, opt-out, super
  /// properties and groups last as long as the process, and installs and updates are not
  /// detected.
  case memory
}

/// Key-value state, backed by UserDefaults or by memory.
final class ClientState: @unchecked Sendable {
  static let optedOut = "apphelm.optedOut"
  static let anonymousId = "apphelm.anonymousId"
  static let identified = "apphelm.identified"
  static let superProperties = "apphelm.superProperties"
  static let groups = "apphelm.groups"
  static let appVersion = "apphelm.appVersion"
  static let appBuild = "apphelm.appBuild"

  private let defaults: UserDefaults?
  private let lock = NSLock()
  private var memory: [String: Any] = [:]

  /// Nil keeps everything in memory.
  init(defaults: UserDefaults?) { self.defaults = defaults }

  var isPersistent: Bool { defaults != nil }

  private func value(_ key: String) -> Any? {
    if let defaults { return defaults.object(forKey: key) }
    return lock.withLock { memory[key] }
  }

  func set(_ value: Any?, _ key: String) {
    if let defaults {
      if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      return
    }
    lock.withLock { memory[key] = value }
  }

  func string(_ key: String) -> String? { value(key) as? String }
  func bool(_ key: String) -> Bool? { value(key) as? Bool }

  /// A JSON object kept as data, so values UserDefaults can't hold (null) survive.
  func object(_ key: String) -> [String: Any] {
    guard let data = value(key) as? Data else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }

  func setObject(_ object: [String: Any], _ key: String) {
    if object.isEmpty { set(nil, key); return }
    set(try? JSONSerialization.data(withJSONObject: jsonSafe(object)), key)
  }
}

/// A value JSONSerialization can write: dates become ISO 8601 text, URLs their string, and
/// anything else that is not JSON its description. A property that can't be written would
/// otherwise make its event fail every flush.
func jsonSafe(_ value: Any) -> Any {
  switch value {
  case let value as String: return value
  case let value as NSNumber:
    let double = value.doubleValue
    return double.isFinite ? value : String(describing: value)
  case let value as Int: return value
  case let value as Double: return value.isFinite ? value : String(value)
  case let value as Bool: return value
  case is NSNull: return NSNull()
  case let value as Date: return ISO8601DateFormatter().string(from: value)
  case let value as URL: return value.absoluteString
  case let value as UUID: return value.uuidString
  case let value as [String: Any]: return value.mapValues(jsonSafe)
  case let value as [Any]: return value.map(jsonSafe)
  case let value as JSONValue: return value.any
  default:
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional { return mirror.children.first.map { jsonSafe($0.value) } ?? NSNull() }
    return String(describing: value)
  }
}

extension JSONValue {
  var any: Any {
    switch self {
    case .string(let value): return value
    case .number(let value): return value
    case .bool(let value): return value
    case .null: return NSNull()
    case .array(let values): return values.map(\.any)
    case .object(let values): return values.mapValues(\.any)
    }
  }
}

/// The event queue: in memory, mirrored to one file per event when it has a directory, so
/// events survive the app being killed. Bounded, the oldest dropped first. Events handed to
/// a flush are marked in flight, so two flushes never send one event twice; a failed send
/// puts them back and a delivered one is deleted.
final class EventQueue: @unchecked Sendable {
  struct Entry {
    let id: String
    let event: [String: Any]
  }

  private static let registryLock = NSLock()
  private static var registry: [String: EventQueue] = [:]

  /// One queue per folder in a process, so clients sharing a folder share its events.
  static func shared(directory: URL, maxSize: Int) -> EventQueue {
    registryLock.withLock {
      let key = directory.standardizedFileURL.path
      if let queue = registry[key] {
        queue.lock.withLock { queue.maxSize = max(1, maxSize) }
        return queue
      }
      let queue = EventQueue(directory: directory, maxSize: maxSize)
      registry[key] = queue
      return queue
    }
  }

  /// For tests: forget the shared queue of a folder, as a new process would.
  static func forgetShared(directory: URL) {
    _ = registryLock.withLock { registry.removeValue(forKey: directory.standardizedFileURL.path) }
  }

  let directory: URL?
  private let lock = NSLock()
  private var maxSize: Int
  private var entries: [Entry] = []
  private var inFlight: Set<String> = []
  private var sequence: UInt64 = 0

  init(directory: URL?, maxSize: Int) {
    self.directory = directory
    self.maxSize = max(1, maxSize)
    guard let directory else { return }
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let names = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    for name in names {
      let file = directory.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: file), let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let number = UInt64(name.dropLast(5), radix: 16) else {
        try? manager.removeItem(at: file)
        continue
      }
      sequence = max(sequence, number)
      entries.append(Entry(id: name, event: event))
    }
    trim()
  }

  var count: Int { lock.withLock { entries.count } }

  /// Add one event; returns the queue's length after it.
  @discardableResult
  func append(_ event: [String: Any]) -> Int {
    lock.withLock {
      sequence += 1
      let id = String(format: "%016llx.json", sequence)
      if let directory, let data = try? JSONSerialization.data(withJSONObject: event) {
        // Kept in memory even when the write fails (a full disk): it is still sent this run.
        try? data.write(to: directory.appendingPathComponent(id), options: .atomic)
      }
      entries.append(Entry(id: id, event: event))
      trim()
      return entries.count
    }
  }

  /// Drop the oldest past the bound. Called with the lock held.
  private func trim() {
    while entries.count > maxSize {
      let dropped = entries.removeFirst()
      inFlight.remove(dropped.id)
      deleteFile(dropped.id)
    }
  }

  private func deleteFile(_ id: String) {
    guard let directory else { return }
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
  }

  /// The events no flush is sending, oldest first, now marked in flight.
  func takePending() -> [Entry] {
    lock.withLock {
      let pending = entries.filter { !inFlight.contains($0.id) }
      inFlight.formUnion(pending.map(\.id))
      return pending
    }
  }

  /// Delivered (or refused for good): removed for good.
  func complete(_ id: String) {
    lock.withLock {
      inFlight.remove(id)
      entries.removeAll { $0.id == id }
      deleteFile(id)
    }
  }

  /// Not sent: back in the queue, in their place, for the next flush.
  func release(_ ids: [String]) {
    lock.withLock { inFlight.subtract(ids) }
  }

  func clear() {
    lock.withLock {
      for entry in entries { deleteFile(entry.id) }
      entries = []
      inFlight = []
    }
  }
}

/// `Application Support/Apphelm/queue-<hash>`: one folder per server, workspace and product,
/// left out of backups.
func defaultQueueDirectory(options: ApphelmOptions) -> URL {
  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  var root = support.appendingPathComponent("Apphelm", isDirectory: true)
  try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  try? root.setResourceValues(values)
  let digest = SHA256.hash(data: Data("\(options.baseURL)\0\(options.workspaceId)\0\(options.productId)".utf8))
  let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  return root.appendingPathComponent("queue-\(hash)", isDirectory: true)
}
