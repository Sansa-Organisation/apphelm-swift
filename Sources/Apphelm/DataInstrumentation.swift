import Foundation
import ObjectiveC

// MARK: - File I/O

/// `file.read` / `file.write` spans for file reads and writes, as Sentry's file I/O tracing
/// records them: `NSData`'s `initWithContentsOfFile:`, `initWithContentsOfFile:options:error:`,
/// `initWithContentsOfURL:options:error:`, `writeToFile:atomically:`,
/// `writeToFile:options:error:` and `writeToURL:options:error:` (Apphelm's addition: Swift's
/// `NSData.write(to:)` goes there), and on iOS 18 / macOS 15 and later `FileManager`'s
/// `createFileAtPath:contents:attributes:` (earlier, it writes through `NSData`).
///
/// A span is recorded only inside an unfinished transaction of a client that turned it on,
/// described as Sentry does (`cart.json (1.2 KB)`), with `file.path`, `file.size` and
/// `blocked_main_thread`. Apphelm's own files (its queue, crash reports, scope and state) are
/// never recorded. A call inside a recorded one (an `NSData` method writing through another)
/// is part of the outer span.
///
/// Swift's `Data(contentsOf:)` and `Data.write(to:)` no longer go through `NSData` on recent
/// systems (checked on macOS 26); use `Data(contentsOfWithApphelmTracing:)` and
/// `writeWithApphelmTracing(to:)`, and the `FileManager` methods below, for those.
enum FileIOInstrumentation {
  /// Where Apphelm keeps its own files.
  static let ownDirectories: [String] = {
    let manager = FileManager.default
    return [manager.urls(for: .cachesDirectory, in: .userDomainMask).first, manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first]
      .compactMap { $0?.appendingPathComponent("Apphelm", isDirectory: true).standardizedFileURL.path }
  }()

  /// Whether `path` is one of Apphelm's own files. Checked before anything that takes a lock:
  /// the SDK may write its files while holding one.
  static func isOwn(_ path: String) -> Bool {
    let standard = URL(fileURLWithPath: path).standardizedFileURL.path
    return (ownDirectories + [CrashInstaller.installedDirectory].compactMap { $0 }).contains { standard == $0 || standard.hasPrefix($0 + "/") }
  }

  /// `body` inside a `file.<op>` span for every client recording file I/O now. `size` is the
  /// byte count known before (a write), `measured` reads it from the result (a read).
  /// `manual` (the `…WithApphelmTracing` methods) records for the latest client whatever its
  /// options, as Sentry's manual methods do.
  static func record<T>(_ op: String, path: String?, size: Int? = nil, manual: Bool = false, client: ApphelmClient? = nil, measured: (T) -> Int? = { _ in nil }, ok: (T) -> Bool = { _ in true }, _ body: () throws -> T) rethrows -> T {
    guard !InstrumentationGuard.active, let path, !path.isEmpty else { return try body() }
    let entries: [AutoInstrumentation.Entry] = manual
      ? (client ?? ApphelmClient.latest).map { [AutoInstrumentation.Entry(client: $0, wants: AutoInstrumentation.Wants(fileIO: true))] } ?? []
      : AutoInstrumentation.targets { $0.fileIO }
    guard !entries.isEmpty, !isOwn(path) else { return try InstrumentationGuard.with(body) }
    let open: [(Span, AutoInstrumentation.Entry)] = entries.compactMap { entry in
      guard let client = entry.client, client.options.enabled, let transaction = client.activeTransaction, !transaction.isFinished else { return nil }
      return (transaction.startSpan(op, description: nil, data: ["file.path": path, "blocked_main_thread": Thread.isMainThread]), entry)
    }
    guard !open.isEmpty else { return try InstrumentationGuard.with(body) }
    do {
      let result = try InstrumentationGuard.with(body)
      let bytes = size ?? measured(result)
      for (span, _) in open {
        span.describe(describe(path: path, size: bytes))
        if let bytes { span.setData("file.size", bytes) }
        span.finish(ok(result) ? .ok : .error)
      }
      return result
    } catch {
      for (span, _) in open {
        span.describe(describe(path: path, size: size))
        span.finish(.error)
      }
      throw error
    }
  }

  /// Sentry's span description: the file's name and, when known, its size.
  static func describe(path: String, size: Int?) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    guard let size else { return name }
    return "\(name) (\(byteCount(size)))"
  }

  /// `512 bytes`, `1.2 KB`, `3.4 MB` (1,024 to a kilobyte, as Sentry's formatter).
  static func byteCount(_ bytes: Int) -> String {
    if bytes < 1_024 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(bytes) / 1_024
    var unit = 0
    while value >= 1_024 && unit < units.count - 1 {
      value /= 1_024
      unit += 1
    }
    let text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    return "\(text.hasSuffix(".0") ? String(text.dropLast(2)) : text) \(units[unit])"
  }

  private static let installed: Void = {
    let data: AnyClass = NSData.self
    typealias Object = UnsafeRawPointer
    func string(_ pointer: Object) -> String { Unmanaged<NSString>.fromOpaque(pointer).takeUnretainedValue() as String }
    func url(_ pointer: Object) -> String? { Unmanaged<NSURL>.fromOpaque(pointer).takeUnretainedValue().path }
    func length(_ pointer: Object?) -> Int? { pointer.map { Unmanaged<NSData>.fromOpaque($0).takeUnretainedValue().length } }

    // Raw pointers throughout: no retain or release of `self`, the arguments or the result,
    // so an `init…` keeps the ownership rules its caller expects.
    let writeAtomically = NSSelectorFromString("writeToFile:atomically:")
    _ = swizzle(data, writeAtomically) { original in
      let call = unsafeBitCast(original, to: (@convention(c) (Object, Selector, Object, Bool) -> Bool).self)
      let block: @convention(block) (Object, Object, Bool) -> Bool = { this, path, atomically in
        record("file.write", path: string(path), size: length(this), ok: { $0 }) { call(this, writeAtomically, path, atomically) }
      }
      return block
    }
    for name in ["writeToFile:options:error:", "writeToURL:options:error:"] {
      let selector = NSSelectorFromString(name)
      let isURL = name.hasPrefix("writeToURL")
      _ = swizzle(data, selector) { original in
        let call = unsafeBitCast(original, to: (@convention(c) (Object, Selector, Object, UInt, OpaquePointer?) -> Bool).self)
        let block: @convention(block) (Object, Object, UInt, OpaquePointer?) -> Bool = { this, target, options, error in
          record("file.write", path: isURL ? url(target) : string(target), size: length(this), ok: { $0 }) { call(this, selector, target, options, error) }
        }
        return block
      }
    }
    let readFile = NSSelectorFromString("initWithContentsOfFile:")
    _ = swizzle(data, readFile) { original in
      let call = unsafeBitCast(original, to: (@convention(c) (Object, Selector, Object) -> Object?).self)
      let block: @convention(block) (Object, Object) -> Object? = { this, path in
        record("file.read", path: string(path), measured: length, ok: { $0 != nil }) { call(this, readFile, path) }
      }
      return block
    }
    for name in ["initWithContentsOfFile:options:error:", "initWithContentsOfURL:options:error:"] {
      let selector = NSSelectorFromString(name)
      let isURL = name.contains("URL")
      _ = swizzle(data, selector) { original in
        let call = unsafeBitCast(original, to: (@convention(c) (Object, Selector, Object, UInt, OpaquePointer?) -> Object?).self)
        let block: @convention(block) (Object, Object, UInt, OpaquePointer?) -> Object? = { this, source, options, error in
          // A URL that isn't a file (a web address) is not file I/O.
          let path = isURL ? (Unmanaged<NSURL>.fromOpaque(source).takeUnretainedValue().isFileURL ? url(source) : nil) : string(source)
          return record("file.read", path: path, measured: length, ok: { $0 != nil }) { call(this, selector, source, options, error) }
        }
        return block
      }
    }
    if #available(iOS 18, macOS 15, tvOS 18, visionOS 2, *) {
      let create = NSSelectorFromString("createFileAtPath:contents:attributes:")
      _ = swizzle(FileManager.self, create) { original in
        let call = unsafeBitCast(original, to: (@convention(c) (Object, Selector, Object, Object?, Object?) -> Bool).self)
        let block: @convention(block) (Object, Object, Object?, Object?) -> Bool = { this, path, contents, attributes in
          record("file.write", path: string(path), size: length(contents) ?? 0, ok: { $0 }) { call(this, create, path, contents, attributes) }
        }
        return block
      }
    }
  }()

  static func installOnce() { _ = installed }
}

extension Data {
  /// `Data(contentsOf:options:)` inside a `file.read` span of the active transaction (Sentry's
  /// `Data(contentsOfWithSentryTracing:)`). Use it where the automatic tracing can't see the
  /// read: Swift's `Data` no longer reads through `NSData` on recent systems.
  public init(contentsOfWithApphelmTracing url: URL, options: Data.ReadingOptions = [], client: ApphelmClient? = nil) throws {
    self = try FileIOInstrumentation.record("file.read", path: url.isFileURL ? url.path : nil, manual: true, client: client, measured: { $0.count }) { try Data(contentsOf: url, options: options) }
  }

  /// `write(to:options:)` inside a `file.write` span of the active transaction (Sentry's
  /// `writeWithSentryTracing`).
  public func writeWithApphelmTracing(to url: URL, options: Data.WritingOptions = [], client: ApphelmClient? = nil) throws {
    try FileIOInstrumentation.record("file.write", path: url.isFileURL ? url.path : nil, size: count, manual: true, client: client) { try write(to: url, options: options) }
  }
}

extension FileManager {
  /// `createFile(atPath:contents:attributes:)` inside a `file.write` span.
  @discardableResult
  public func createFileWithApphelmTracing(atPath path: String, contents: Data?, attributes: [FileAttributeKey: Any]? = nil, client: ApphelmClient? = nil) -> Bool {
    FileIOInstrumentation.record("file.write", path: path, size: contents?.count ?? 0, manual: true, client: client, ok: { $0 }) { createFile(atPath: path, contents: contents, attributes: attributes) }
  }

  /// `removeItem(at:)` inside a `file.delete` span.
  public func removeItemWithApphelmTracing(at url: URL, client: ApphelmClient? = nil) throws {
    try FileIOInstrumentation.record("file.delete", path: url.path, manual: true, client: client) { try removeItem(at: url) }
  }

  /// `copyItem(at:to:)` inside a `file.copy` span (described by the source).
  public func copyItemWithApphelmTracing(at source: URL, to destination: URL, client: ApphelmClient? = nil) throws {
    try FileIOInstrumentation.record("file.copy", path: source.path, manual: true, client: client) { try copyItem(at: source, to: destination) }
  }

  /// `moveItem(at:to:)` inside a `file.rename` span (described by the source).
  public func moveItemWithApphelmTracing(at source: URL, to destination: URL, client: ApphelmClient? = nil) throws {
    try FileIOInstrumentation.record("file.rename", path: source.path, manual: true, client: client) { try moveItem(at: source, to: destination) }
  }
}

// MARK: - Core Data

/// `db.sql.query` spans for Core Data fetches and `db.sql.transaction` spans for saves with
/// changes, as Sentry's Core Data tracing records them, by swizzling `NSManagedObjectContext`'s
/// `executeFetchRequest:error:` and `save:` (only when the app has Core Data loaded; Apphelm
/// does not link it). A fetch is described `SELECT 'Entity'` (with ` WHERE <predicate>` and
/// ` SORT BY key`), with `read_count`; a save `INSERTED 1 'Order', UPDATED 2 items`, with
/// `operations`. Both carry `db.system` (the stores' types: `SQLite`, `InMemory`…) and
/// `blocked_main_thread`. Recorded only inside an unfinished transaction.
enum CoreDataInstrumentation {
  private static let installed: Bool = {
    guard let context = NSClassFromString("NSManagedObjectContext") else { return false }
    typealias Object = UnsafeRawPointer
    func object(_ pointer: Object) -> NSObject { Unmanaged<NSObject>.fromOpaque(pointer).takeUnretainedValue() }
    let fetch = NSSelectorFromString("executeFetchRequest:error:")
    let fetchSwizzled = swizzle(context, fetch) { original in
      let call = unsafeBitCast(original, to: (@convention(c) (Object, Selector, Object, OpaquePointer?) -> Object?).self)
      let block: @convention(block) (Object, Object, OpaquePointer?) -> Object? = { this, request, error in
        record("db.sql.query", context: object(this), describe: { fetchDescription(object(request)) }, finish: { result, span in
          if let result { span.setData("read_count", Unmanaged<NSArray>.fromOpaque(result).takeUnretainedValue().count) }
          return result != nil
        }) { call(this, fetch, request, error) }
      }
      return block
    }
    let save = NSSelectorFromString("save:")
    let saveSwizzled = swizzle(context, save) { original in
      let call = unsafeBitCast(original, to: (@convention(c) (Object, Selector, OpaquePointer?) -> Bool).self)
      let block: @convention(block) (Object, OpaquePointer?) -> Bool = { this, error in
        let context = object(this)
        guard (context.value(forKey: "hasChanges") as? Bool) == true else { return call(this, save, error) }
        let changes = saveChanges(context)
        return record("db.sql.transaction", context: context, describe: { changes.description }, finish: { saved, span in
          if !changes.operations.isEmpty, let json = try? JSONSerialization.data(withJSONObject: changes.operations, options: [.sortedKeys]) {
            span.setData("operations", String(decoding: json, as: UTF8.self))
          }
          return saved
        }) { call(this, save, error) }
      }
      return block
    }
    return fetchSwizzled || saveSwizzled
  }()

  static func installOnce() { _ = installed }

  private static func record<T>(_ op: String, context: NSObject, describe: () -> String, finish: (T, Span) -> Bool, _ body: () -> T) -> T {
    guard !InstrumentationGuard.active else { return body() }
    let entries = AutoInstrumentation.targets { $0.coreData }.compactMap { entry -> Transaction? in
      guard let transaction = entry.client?.activeTransaction, !transaction.isFinished else { return nil }
      return transaction
    }
    guard !entries.isEmpty else { return InstrumentationGuard.with(body) }
    var data: [String: Any] = ["blocked_main_thread": Thread.isMainThread]
    if let system = storeTypes(context) { data["db.system"] = system }
    let description = describe()
    let spans = entries.map { $0.startSpan(op, description: description, data: data) }
    let result = InstrumentationGuard.with(body)
    for span in spans { span.finish(finish(result, span) ? .ok : .error) }
    return result
  }

  /// `SELECT 'Order' WHERE status == "open" SORT BY createdAt DESCENDING`, as Sentry words it.
  static func fetchDescription(_ request: NSObject) -> String {
    let entity = (request.value(forKey: "entityName") as? String) ?? ((request.value(forKey: "entity") as? NSObject)?.value(forKey: "name") as? String) ?? "?"
    var text = "SELECT '\(entity)'"
    if let predicate = request.value(forKey: "predicate") as? NSPredicate { text += " WHERE \(predicate.predicateFormat)" }
    let sorts = ((request.value(forKey: "sortDescriptors") as? [NSSortDescriptor]) ?? []).compactMap { sort in sort.key.map { $0 + (sort.ascending ? "" : " DESCENDING") } }
    if !sorts.isEmpty { text += " SORT BY \(sorts.joined(separator: ", "))" }
    return text
  }

  /// `INSERTED 1 'Order', UPDATED 3 items`, and the counts per entity behind it.
  static func saveChanges(_ context: NSObject) -> (description: String, operations: [String: [String: Int]]) {
    var parts: [String] = []
    var operations: [String: [String: Int]] = [:]
    for (key, verb) in [("insertedObjects", "INSERTED"), ("updatedObjects", "UPDATED"), ("deletedObjects", "DELETED")] {
      guard let objects = context.value(forKey: key) as? NSSet, objects.count > 0 else { continue }
      var counts: [String: Int] = [:]
      for case let item as NSObject in objects {
        let name = ((item.value(forKey: "entity") as? NSObject)?.value(forKey: "name") as? String) ?? "?"
        counts[name, default: 0] += 1
      }
      operations[verb] = counts
      parts.append(counts.count == 1 ? "\(verb) \(objects.count) '\(counts.keys.first!)'" : "\(verb) \(objects.count) items")
    }
    return (parts.joined(separator: ", "), operations)
  }

  /// The context's stores' types joined by `;` (`SQLite`), as Sentry sends `db.system`.
  static func storeTypes(_ context: NSObject) -> String? {
    guard let coordinator = context.value(forKey: "persistentStoreCoordinator") as? NSObject,
          let stores = coordinator.value(forKey: "persistentStores") as? [NSObject], !stores.isEmpty else { return nil }
    return stores.compactMap { $0.value(forKey: "type") as? String }.joined(separator: ";")
  }
}
