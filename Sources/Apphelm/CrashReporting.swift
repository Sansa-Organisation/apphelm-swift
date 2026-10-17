import Darwin
import Foundation

/// Crash capture for iOS and macOS.
///
/// A crashing process can't be trusted to send anything, so a crash is written to disk
/// while it happens and sent on the next launch by `sendPendingCrashReports()`, as an
/// unhandled `$exception` carrying the release and environment of the build that crashed.
///
/// Two kinds of crash are recorded:
/// - an uncaught Objective-C `NSException`, with its name, reason and call stack;
/// - a fatal signal (`SIGABRT`, `SIGBUS`, `SIGFPE`, `SIGILL`, `SIGSEGV`, `SIGTRAP`), which
///   covers Swift runtime traps such as `fatalError`, force-unwrapping nil and array bounds.
///
/// The signal handler does only what is safe inside a signal handler: it writes a header
/// prepared at install time and the raw backtrace (`backtrace_symbols_fd`) to a file
/// descriptor opened at install time, then restores the previous handler and re-raises, so
/// the system (and any other crash reporter installed before Apphelm) still sees the crash.
/// Frames are as the device printed them: a stripped release build shows image names and
/// addresses rather than function names. So that the server can symbolicate them from an
/// uploaded symbol table, each report also names the images its frames are in, with their
/// UUIDs and load addresses (`DebugImages`). Those belong to the launch that crashed, not
/// the one that sends the report, so they are written to disk at install, next to the file
/// the signal handler writes to, and travel with it.
enum CrashStore {
  static let signals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]

  static func signalName(_ signal: Int32) -> String {
    switch signal {
    case SIGABRT: return "SIGABRT"
    case SIGBUS: return "SIGBUS"
    case SIGFPE: return "SIGFPE"
    case SIGILL: return "SIGILL"
    case SIGSEGV: return "SIGSEGV"
    case SIGTRAP: return "SIGTRAP"
    default: return "SIG\(signal)"
    }
  }

  static let signalPrefix = "APPHELM-SIGNAL "
  static let activeFile = "crash-active.log"
  /// The images loaded in the run that owns `activeFile`.
  static let activeImagesFile = "images-active.json"
}

// Signal-handler state lives in globals set once at install: the handler is a C function
// and may not allocate, lock or touch Swift objects.
nonisolated(unsafe) private var crashFileDescriptor: Int32 = -1
nonisolated(unsafe) private var headerTable: UnsafeMutablePointer<(UnsafeMutablePointer<UInt8>?, Int)>?
nonisolated(unsafe) private var previousActions: UnsafeMutablePointer<sigaction>?
nonisolated(unsafe) private var backtraceBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
nonisolated(unsafe) private var exceptionReportPath: String?
nonisolated(unsafe) private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
nonisolated(unsafe) private var installed = false
private let installLock = NSLock()
private let tableSize = 32

/// Write the report for `signal` to the pre-opened file: the prepared header, then one
/// backtrace line per frame. Async-signal-safe calls only. Internal so tests can write a
/// report without raising a signal.
func writeSignalReport(_ signal: Int32) {
  let fd = crashFileDescriptor
  guard fd >= 0, let table = headerTable, signal >= 0, Int(signal) < tableSize, let header = table[Int(signal)].0 else { return }
  _ = write(fd, header, table[Int(signal)].1)
  if let frames = backtraceBuffer {
    let count = backtrace(frames, 64)
    backtrace_symbols_fd(frames, count, fd)
  }
  _ = fsync(fd)
}

private func apphelmSignalHandler(_ signal: Int32) {
  writeSignalReport(signal)
  // Put back whatever handled this signal before Apphelm and re-raise, so the crash still
  // terminates the process and reaches the system's (or another SDK's) crash reporter.
  if let previous = previousActions, signal >= 0, Int(signal) < tableSize {
    sigaction(signal, previous.advanced(by: Int(signal)), nil)
  } else {
    Darwin.signal(signal, SIG_DFL)
  }
  raise(signal)
}

/// Record an uncaught NSException. Not a signal context, so Foundation is allowed here.
func writeExceptionReport(_ exception: NSException) {
  guard let path = exceptionReportPath else { return }
  let report: [String: Any] = [
    "kind": "nsexception",
    "name": exception.name.rawValue,
    "reason": exception.reason ?? "",
    "stack": exception.callStackSymbols,
    "images": DebugImages.referenced(by: exception.callStackSymbols, among: DebugImages.loaded()),
    "at": ISO8601DateFormatter().string(from: Date()),
  ]
  if let data = try? JSONSerialization.data(withJSONObject: report) {
    FileManager.default.createFile(atPath: path, contents: data)
  }
}

private func apphelmExceptionHandler(_ exception: NSException) {
  writeExceptionReport(exception)
  previousExceptionHandler?(exception)
}

enum CrashInstaller {
  /// Install once per process. A report left by the previous run is moved aside first so
  /// the fresh signal file can't overwrite it before it is sent.
  static func install(directory: URL) throws {
    try installLock.withLock {
      guard !installed else { return }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try moveAsideActiveReport(directory: directory)
      try openActiveFile(directory: directory)
      writeActiveImages(directory: directory)
      let table = UnsafeMutablePointer<(UnsafeMutablePointer<UInt8>?, Int)>.allocate(capacity: tableSize)
      table.initialize(repeating: (nil, 0), count: tableSize)
      for signal in CrashStore.signals {
        let bytes = Array("\(CrashStore.signalPrefix)\(signal) \(CrashStore.signalName(signal))\n".utf8)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        table[Int(signal)] = (buffer, bytes.count)
      }
      headerTable = table
      backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
      let previous = UnsafeMutablePointer<sigaction>.allocate(capacity: tableSize)
      previous.initialize(repeating: sigaction(), count: tableSize)
      previousActions = previous
      for signal in CrashStore.signals {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = apphelmSignalHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(signal, &action, previous.advanced(by: Int(signal)))
      }
      exceptionReportPath = directory.appendingPathComponent("crash-exception-\(UUID().uuidString).json").path
      previousExceptionHandler = NSGetUncaughtExceptionHandler()
      NSSetUncaughtExceptionHandler(apphelmExceptionHandler)
      installed = true
    }
  }

  /// Open the file the signal handler writes to, empty, before any crash can happen.
  static func openActiveFile(directory: URL) throws {
    let fd = open(directory.appendingPathComponent(CrashStore.activeFile).path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { throw ApphelmError(message: "Could not open the crash report file.", status: 0, code: "crash_store_unavailable") }
    let previous = crashFileDescriptor
    crashFileDescriptor = fd
    if previous >= 0 { close(previous) }
  }

  /// Record this run's loaded images, replacing the previous run's list. Best effort: a
  /// crash without it is still reported, only without the means to symbolicate it.
  static func writeActiveImages(directory: URL, images: [[String: String]] = DebugImages.loaded()) {
    guard let data = try? JSONSerialization.data(withJSONObject: images) else { return }
    try? data.write(to: directory.appendingPathComponent(CrashStore.activeImagesFile), options: .atomic)
  }

  /// Keep the signal file a previous run wrote during its crash, under its own name, and
  /// that run's image list with it (`images-<id>.json` beside `crash-<id>.log`).
  static func moveAsideActiveReport(directory: URL) throws {
    let active = directory.appendingPathComponent(CrashStore.activeFile)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: active.path), (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 {
      let id = UUID().uuidString
      try FileManager.default.moveItem(at: active, to: directory.appendingPathComponent("crash-\(id).log"))
      try? FileManager.default.moveItem(at: directory.appendingPathComponent(CrashStore.activeImagesFile), to: directory.appendingPathComponent("images-\(id).json"))
    }
  }

  /// Where the image list of a signal report is: `images-<id>.json` for `crash-<id>.log`.
  static func imagesFile(for report: URL) -> URL? {
    let name = report.lastPathComponent
    guard report.pathExtension == "log", name.hasPrefix("crash-") else { return nil }
    return report.deletingLastPathComponent().appendingPathComponent("images-" + name.dropFirst("crash-".count).dropLast(".log".count) + ".json")
  }

  /// Delete a report and, for a signal report, its image list.
  static func remove(report: URL) {
    try? FileManager.default.removeItem(at: report)
    if let images = imagesFile(for: report) { try? FileManager.default.removeItem(at: images) }
  }

  private static func images(_ value: Any?) -> [[String: String]] {
    (value as? [[String: String]]) ?? []
  }

  /// Reports waiting to be sent: moved-aside signal logs and exception reports, non-empty.
  static func pendingReports(directory: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasPrefix("crash-") && $0 != CrashStore.activeFile }.sorted().map { directory.appendingPathComponent($0) }
      .filter { ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? NSNumber)?.intValue ?? 0 > 0 }
  }

  /// The `$exception` properties for one stored report, or nil when it can't be read.
  static func exceptionProperties(report: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: report), !data.isEmpty else { return nil }
    if report.pathExtension == "json" {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let name = (object["name"] as? String) ?? "NSException"
      let stack = (object["stack"] as? [String]) ?? []
      var properties: [String: Any] = ["name": String(name.prefix(80)), "message": String(((object["reason"] as? String) ?? "Uncaught exception").prefix(240)), "stack": boundedStack(stack), "mechanism": "nsexception"]
      let loaded = Array(images(object["images"]).prefix(DebugImages.maxPerReport))
      if !loaded.isEmpty { properties["debug_images"] = loaded }
      return properties
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard let header = lines.first, header.hasPrefix(CrashStore.signalPrefix) else { return nil }
    let parts = header.dropFirst(CrashStore.signalPrefix.count).split(separator: " ")
    let name = parts.count > 1 ? String(parts[1]) : "SIGNAL"
    // The first frames are Apphelm's own handler and the system's signal trampoline.
    let frames = Array(lines.dropFirst().drop { $0.contains("$s7Apphelm") || $0.contains("_sigtramp") })
    var properties: [String: Any] = ["name": name, "message": "The app crashed with \(name)", "stack": boundedStack(frames), "mechanism": "signal"]
    // The images of the run that crashed, narrowed to the ones these frames are in.
    if let file = imagesFile(for: report), let stored = try? Data(contentsOf: file), let all = try? JSONSerialization.jsonObject(with: stored) {
      let loaded = DebugImages.referenced(by: Array(frames.prefix(40)), among: images(all))
      if !loaded.isEmpty { properties["debug_images"] = loaded }
    }
    return properties
  }

  static func boundedStack(_ frames: [String]) -> String {
    String(frames.prefix(40).map { String($0.prefix(200)) }.joined(separator: "\n").prefix(4_000))
  }
}
