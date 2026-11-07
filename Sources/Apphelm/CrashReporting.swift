import Darwin
import MachO
import Foundation

/// Crash capture for iOS and macOS.
///
/// A crashing process can't be trusted to send anything, so a crash is written to disk
/// while it happens and sent on the next launch by `sendPendingCrashReports()`, as an
/// unhandled `$exception` carrying the release and environment of the build that crashed.
///
/// Two kinds of crash are recorded:
/// - an uncaught Objective-C `NSException`, with its name, reason and call stack;
/// - a fatal signal (`SIGABRT`, `SIGBUS`, `SIGFPE`, `SIGILL`, `SIGSEGV`, `SIGSYS`, `SIGTRAP`),
///   which covers Swift runtime traps such as `fatalError`, force-unwrapping nil and array
///   bounds. The handler runs on an alternate signal stack on the thread that installed it,
///   so a stack overflow on that thread (usually the main thread) is recorded too.
///
/// An `NSException` ends in `abort()`, which raises `SIGABRT`: that signal is not recorded a
/// second time. Each report also carries the crashed run's scope (release, environment,
/// session, tags, user hash and the last breadcrumbs, `CrashScopeStore`).
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
  static let signals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP]

  static func signalName(_ signal: Int32) -> String {
    switch signal {
    case SIGABRT: return "SIGABRT"
    case SIGBUS: return "SIGBUS"
    case SIGFPE: return "SIGFPE"
    case SIGILL: return "SIGILL"
    case SIGSEGV: return "SIGSEGV"
    case SIGSYS: return "SIGSYS"
    case SIGTRAP: return "SIGTRAP"
    default: return "SIG\(signal)"
    }
  }

  static let signalPrefix = "APPHELM-SIGNAL "
  /// The line of a signal report that holds the Swift runtime's fatal-error message.
  static let messagePrefix = "APPHELM-MESSAGE "
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
// Set once an uncaught NSException has been recorded: the SIGABRT its abort() raises is the
// same crash.
nonisolated(unsafe) private var exceptionRecorded: sig_atomic_t = 0
nonisolated(unsafe) private var alternateStack: UnsafeMutableRawPointer?
private let installLock = NSLock()
private let tableSize = 32

// The Swift runtime's crash annotations (`gCRAnnotations` in libswiftCore's
// `__DATA,__crash_info` section): `fatalError`, `precondition` and the runtime's own traps put
// their `Fatal error: …` text there before trapping. Found at install; read in the handler.
nonisolated(unsafe) private var swiftCrashInfo: UnsafeRawPointer?
// The message line's buffer, made at install with the prefix already in it.
nonisolated(unsafe) private var messageLine: UnsafeMutablePointer<UInt8>?
nonisolated(unsafe) private var messagePrefixLength = 0
private let messageLimit = 1_000

/// Write the report for `signal` to the pre-opened file: the prepared header, then one
/// backtrace line per frame, then (on its own line, last, since reading it is the one step
/// that touches memory the crash may have damaged) the Swift runtime's fatal-error message.
/// Async-signal-safe calls only. Internal so tests can write a report without raising a signal.
func writeSignalReport(_ signal: Int32) {
  let fd = crashFileDescriptor
  guard fd >= 0, let table = headerTable, signal >= 0, Int(signal) < tableSize, let header = table[Int(signal)].0 else { return }
  _ = write(fd, header, table[Int(signal)].1)
  if let frames = backtraceBuffer {
    let count = backtrace(frames, 64)
    backtrace_symbols_fd(frames, count, fd)
  }
  _ = fsync(fd)
  writeCrashInfoMessage(fd)
}

/// The `message` (else `message2`) of the Swift runtime's crash annotations, as one line
/// prefixed `APPHELM-MESSAGE `, newlines turned into spaces, at most 1,000 bytes. Copied byte
/// by byte into a buffer made at install: no allocation.
private func writeCrashInfoMessage(_ fd: Int32) {
  guard let info = swiftCrashInfo, let line = messageLine else { return }
  // crashreporter_annotations_t: version, message, signature_string, backtrace, message2, …
  let version = info.load(as: UInt64.self)
  guard version >= 4 && version <= 5 else { return }
  var address = UInt(info.load(fromByteOffset: 8, as: UInt64.self))
  if address == 0 { address = UInt(info.load(fromByteOffset: 32, as: UInt64.self)) }
  guard address != 0, let text = UnsafePointer<UInt8>(bitPattern: address) else { return }
  let start = messagePrefixLength
  var length = start
  while length < start + messageLimit {
    let byte = text[length - start]
    if byte == 0 { break }
    line[length] = byte == 10 || byte == 13 ? 32 : byte
    length += 1
  }
  guard length > start else { return }
  line[length] = 10
  _ = write(fd, line, length + 1)
  _ = fsync(fd)
}

/// libswiftCore's `__crash_info` section, or nil when the image or the section isn't there.
private func findSwiftCrashInfo() -> UnsafeRawPointer? {
  for index in 0..<_dyld_image_count() {
    guard let name = _dyld_get_image_name(index), String(cString: name).hasSuffix("/libswiftCore.dylib"),
          let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64 else { continue }
    var size: UInt = 0
    let section = UnsafeRawPointer(header).withMemoryRebound(to: mach_header_64.self, capacity: 1) { getsectiondata($0, "__DATA", "__crash_info", &size) }
    guard let section, size >= 40 else { return nil }
    return UnsafeRawPointer(section)
  }
  return nil
}

// MARK: Alternate signal stacks for every thread

/// A fatal signal's handler runs on the thread that faulted. After a stack overflow that
/// thread has no stack left, so the handler can only run on an alternate stack, and an
/// alternate stack (`sigaltstack`) is per thread and can only be set by the thread itself.
/// So every thread started after install sets one up as it starts, through libpthread's
/// introspection hook (`pthread_introspection_hook_install`, public in
/// <pthread/introspection.h>, which calls it on the new thread), and frees it as it ends.
/// The memory is `mmap`ed, so pages the handler never touches cost nothing. A thread that
/// already has an alternate stack keeps it. Threads that existed before install, other than
/// the installing one, have none: install early.
private let threadStackSize = max(Int(SIGSTKSZ), 128 * 1024)
private let threadStackMagic: UInt64 = 0x4150_4848_454C_4D53 // "APHHELMS"
nonisolated(unsafe) private var previousThreadHook: ThreadHook?
typealias ThreadHook = @convention(c) (UInt32, pthread_t, UnsafeMutableRawPointer?, Int) -> Void
private typealias ThreadHookInstall = @convention(c) (ThreadHook) -> ThreadHook?
private let threadStart: UInt32 = 2 // PTHREAD_INTROSPECTION_THREAD_START
private let threadTerminate: UInt32 = 3 // PTHREAD_INTROSPECTION_THREAD_TERMINATE

/// Runs on the thread itself, maybe before it is fully set up: system calls only.
private func apphelmThreadHook(_ event: UInt32, _ thread: pthread_t, _ address: UnsafeMutableRawPointer?, _ size: Int) {
  if event == threadStart {
    giveThreadAlternateStack()
  } else if event == threadTerminate {
    var current = stack_t()
    if sigaltstack(nil, &current) == 0, let base = current.ss_sp, current.ss_size == threadStackSize,
       current.ss_flags & SS_ONSTACK == 0, base.load(as: UInt64.self) == threadStackMagic {
      var off = stack_t(ss_sp: nil, ss_size: 0, ss_flags: SS_DISABLE)
      if sigaltstack(&off, nil) == 0 { munmap(base, threadStackSize) }
    }
  }
  previousThreadHook?(event, thread, address, size)
}

/// An alternate signal stack for the calling thread, unless it has one. Internal for tests.
@discardableResult
func giveThreadAlternateStack() -> Bool {
  var current = stack_t()
  guard sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE != 0 else { return false }
  let memory = mmap(nil, threadStackSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
  guard let memory, memory != MAP_FAILED else { return false }
  // The stack grows down from the top: the marker at its base is only reached by a handler
  // that used all of it.
  memory.storeBytes(of: threadStackMagic, as: UInt64.self)
  var stack = stack_t(ss_sp: memory, ss_size: threadStackSize, ss_flags: 0)
  if sigaltstack(&stack, nil) == 0 { return true }
  munmap(memory, threadStackSize)
  return false
}

private func installThreadHook() {
  // Globals with computed values are set up on first use: do it now, not on a new thread.
  _ = threadStackSize
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_introspection_hook_install") else { return }
  let install = unsafeBitCast(symbol, to: ThreadHookInstall.self)
  previousThreadHook = install(apphelmThreadHook)
}

private func apphelmSignalHandler(_ signal: Int32) {
  if !(signal == SIGABRT && exceptionRecorded != 0) { writeSignalReport(signal) }
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
    "scope": jsonSafe(CrashScopeStore.shared.current() ?? [:]),
  ]
  if let data = try? JSONSerialization.data(withJSONObject: report) {
    FileManager.default.createFile(atPath: path, contents: data)
  }
}

private func apphelmExceptionHandler(_ exception: NSException) {
  writeExceptionReport(exception)
  exceptionRecorded = 1
  previousExceptionHandler?(exception)
}

/// What the run before this one left, read at install before anything of it is replaced: its
/// app state (WatchdogTerminations.swift), whether it crashed, whether an app hang was under
/// way when it ended, and its scope.
struct PreviousRun {
  var state: AppState?
  var crashed: Bool
  var hangOngoing: Bool
  var scope: [String: Any]?
}

enum CrashInstaller {
  nonisolated(unsafe) private(set) static var previousRun: PreviousRun?
  nonisolated(unsafe) private(set) static var currentRun: String?
  /// The directory crash reporting was installed in, standardized.
  nonisolated(unsafe) private(set) static var installedDirectory: String?

  /// Install once per process. A report left by the previous run is moved aside first so
  /// the fresh signal file can't overwrite it before it is sent.
  static func install(directory: URL) throws {
    try installLock.withLock {
      guard !installed else { return }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let (lastRun, signalReport) = try takePreviousRun(directory: directory)
      previousRun = lastRun
      // A crashed run's replay snapshot goes with its report; this run gets its own.
      let run = UUID().uuidString
      currentRun = run
      installedDirectory = directory.standardizedFileURL.path
      ReplayCrashStore.moveAside(directory: directory, signalReport: signalReport)
      ReplayCrashStore.shared.attach(directory: directory, run: run)
      try openActiveFile(directory: directory)
      writeActiveImages(directory: directory)
      CrashScopeStore.shared.attach(directory: directory)
      installAlternateStack()
      installThreadHook()
      swiftCrashInfo = findSwiftCrashInfo()
      let prefix = Array(CrashStore.messagePrefix.utf8)
      let line = UnsafeMutablePointer<UInt8>.allocate(capacity: prefix.count + messageLimit + 1)
      line.initialize(from: prefix, count: prefix.count)
      messagePrefixLength = prefix.count
      messageLine = line
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
        // On the thread's alternate stack when it has one (every thread started after
        // install, and the installing thread); on its own stack otherwise.
        action.sa_flags = SA_ONSTACK
        sigaction(signal, &action, previous.advanced(by: Int(signal)))
      }
      exceptionReportPath = directory.appendingPathComponent("crash-exception-\(run).json").path
      previousExceptionHandler = NSGetUncaughtExceptionHandler()
      NSSetUncaughtExceptionHandler(apphelmExceptionHandler)
      installed = true
    }
  }

  /// Read what the previous run left and move its reports aside: its app state and scope
  /// (before this run's replace them), its signal report, and an app hang it was in.
  static func takePreviousRun(directory: URL) throws -> (PreviousRun, signalReport: URL?) {
    let state = WatchdogTerminations.load(directory: directory)
    let scope = (try? Data(contentsOf: directory.appendingPathComponent(CrashScopeStore.activeFile))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let signalReport = try moveAsideActiveReport(directory: directory)
    // Crashed: a fatal signal was written, or an uncaught exception (named after the run).
    let crashed = signalReport != nil || state.map { FileManager.default.fileExists(atPath: directory.appendingPathComponent("crash-exception-\($0.run).json").path) } ?? false
    let hangOngoing = moveAsideAppHang(directory: directory, crashed: crashed)
    return (PreviousRun(state: state, crashed: crashed, hangOngoing: hangOngoing, scope: scope), signalReport)
  }

  /// A stack for the signal handler on this thread, so a stack overflow (which leaves no
  /// room on the thread's own stack) can still be recorded. Best effort. Threads started
  /// later get theirs from the thread hook (`giveThreadAlternateStack`).
  static func installAlternateStack() {
    var current = stack_t()
    // The thread may already have one (another crash reporter's): keep it.
    if sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE == 0 { return }
    let size = max(Int(SIGSTKSZ), 64 * 1024)
    guard let memory = malloc(size) else { return }
    var stack = stack_t(ss_sp: memory, ss_size: size, ss_flags: 0)
    if sigaltstack(&stack, nil) == 0 { alternateStack = memory } else { free(memory) }
  }

  /// Move an app hang the previous run was in when it ended (`app-hang-active.json`) aside as
  /// a report to send: a fatal app hang, unless that run also crashed, in which case the
  /// crash is what ended it and the hang is sent as it was found. Returns whether there was one.
  static func moveAsideAppHang(directory: URL, crashed: Bool) -> Bool {
    let active = directory.appendingPathComponent(AppHangTracker.activeFile)
    guard let data = try? Data(contentsOf: active) else { return false }
    try? FileManager.default.removeItem(at: active)
    guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
    object["fatal"] = !crashed
    if let updated = try? JSONSerialization.data(withJSONObject: object) {
      FileManager.default.createFile(atPath: directory.appendingPathComponent("crash-apphang-\(UUID().uuidString).json").path, contents: updated)
    }
    return true
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
  /// that run's image list with it (`images-<id>.json` beside `crash-<id>.log`). Returns the
  /// report it moved, if any.
  @discardableResult
  static func moveAsideActiveReport(directory: URL) throws -> URL? {
    let active = directory.appendingPathComponent(CrashStore.activeFile)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: active.path), (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 {
      let id = UUID().uuidString
      let report = directory.appendingPathComponent("crash-\(id).log")
      try FileManager.default.moveItem(at: active, to: report)
      try? FileManager.default.moveItem(at: directory.appendingPathComponent(CrashStore.activeImagesFile), to: directory.appendingPathComponent("images-\(id).json"))
      try? FileManager.default.moveItem(at: directory.appendingPathComponent(CrashScopeStore.activeFile), to: directory.appendingPathComponent("scope-\(id).json"))
      return report
    }
    return nil
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
    if let scope = CrashScopeStore.file(for: report) { try? FileManager.default.removeItem(at: scope) }
    if let replay = ReplayCrashStore.file(for: report) { try? FileManager.default.removeItem(at: replay) }
  }

  /// The scope of the run that wrote `report` (release, environment, session_hash, tags,
  /// user_hash, breadcrumbs), or nil when it has none (a report from before 0.8.0).
  static func scope(report: URL) -> [String: Any]? {
    if report.pathExtension == "json" {
      guard let data = try? Data(contentsOf: report), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let scope = object["scope"] as? [String: Any], !scope.isEmpty else { return nil }
      return scope
    }
    guard let file = CrashScopeStore.file(for: report), let data = try? Data(contentsOf: file),
          let scope = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !scope.isEmpty else { return nil }
    return scope
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
      switch object["kind"] as? String {
      case "watchdog":
        // No stack: nothing ran when the process was killed.
        return ["name": WatchdogTerminations.name, "message": WatchdogTerminations.message, "stack": "", "mechanism": "watchdog_termination", "level": "fatal"]
      case "apphang":
        return appHangProperties(object)
      default:
        break
      }
      let name = (object["name"] as? String) ?? "NSException"
      let stack = (object["stack"] as? [String]) ?? []
      var properties: [String: Any] = ["name": String(name.prefix(80)), "message": scrubbed((object["reason"] as? String) ?? "Uncaught exception", limit: 240), "stack": boundedStack(stack), "mechanism": "nsexception"]
      let loaded = Array(images(object["images"]).prefix(DebugImages.maxPerReport))
      if !loaded.isEmpty { properties["debug_images"] = loaded }
      return properties
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard let header = lines.first, header.hasPrefix(CrashStore.signalPrefix) else { return nil }
    let parts = header.dropFirst(CrashStore.signalPrefix.count).split(separator: " ")
    let name = parts.count > 1 ? String(parts[1]) : "SIGNAL"
    // The Swift runtime's `Fatal error: …`, when it left one.
    let runtimeMessage = lines.first { $0.hasPrefix(CrashStore.messagePrefix) }.map { String($0.dropFirst(CrashStore.messagePrefix.count)) }
    // The first frames are Apphelm's own handler and the system's signal trampoline.
    let frames = Array(lines.dropFirst().filter { !$0.hasPrefix(CrashStore.messagePrefix) }.drop { $0.contains("$s7Apphelm") || $0.contains("_sigtramp") })
    let message = runtimeMessage.map { scrubbed($0, limit: 240) } ?? "The app crashed with \(name)"
    var properties: [String: Any] = ["name": name, "message": message, "stack": boundedStack(frames), "mechanism": "signal"]
    // The images of the run that crashed, narrowed to the ones these frames are in.
    if let file = imagesFile(for: report), let stored = try? Data(contentsOf: file), let all = try? JSONSerialization.jsonObject(with: stored) {
      let loaded = DebugImages.referenced(by: Array(frames.prefix(40)), among: images(all))
      if !loaded.isEmpty { properties["debug_images"] = loaded }
    }
    return properties
  }

  /// An app hang the previous run left (AppHangs.swift). A fatal one (the run ended during the
  /// hang) is Sentry's fatal app hang: level `fatal`, unhandled, worded as a termination. It
  /// ends that run's session `abnormal`, not crashed, as sentry-cocoa's
  /// PreviousRunSessionFinalizer does: it is sent with the session id and
  /// `session_status: abnormal`. A hang ended by a crash is sent as it was found: level `error`.
  static func appHangProperties(_ object: [String: Any]) -> [String: Any] {
    let fatal = (object["fatal"] as? Bool) ?? false
    let kind = AppHangTracker.Kind(rawValue: (object["hang_type"] as? String) ?? "") ?? .fullyBlocking
    let blocked = Double((object["duration_ms"] as? Int) ?? (object["timeout_ms"] as? Int) ?? 2_000) / 1000
    let message = fatal
      ? "The user or the OS watchdog terminated your app while it blocked the main thread for at least \(AppHangTracker.seconds(blocked)) seconds."
      : "App hanging for at least \(AppHangTracker.seconds(blocked)) seconds."
    let stack = (object["stack"] as? [String]) ?? []
    var properties: [String: Any] = ["name": kind.title(fatal: fatal), "message": message, "stack": boundedStack(stack), "mechanism": "AppHang", "level": fatal ? "fatal" : "error", "handled": !fatal, "app_hang_duration_ms": Int((blocked * 1000).rounded())]
    // Sentry-cocoa names a fatal app hang's session `anr_foreground` (captureFatalAppHangEvent), for the ANR rate.
    if fatal { properties["session_status"] = "abnormal"; properties["abnormal_mechanism"] = "anr_foreground" }
    let loaded = Array(images(object["images"]).prefix(DebugImages.maxPerReport))
    if !loaded.isEmpty { properties["debug_images"] = loaded }
    return properties
  }

  /// The stack as an event carries it: the first 40 frames, each scrubbed (`scrubFrame`) and
  /// cut to 200 characters, at most 4,000 in all. A crash report's frames are scrubbed here,
  /// when it is sent, never in the signal handler.
  static func boundedStack(_ frames: [String]) -> String {
    String(frames.prefix(40).map { scrubbed($0, limit: 200, scrubFrame) }.joined(separator: "\n").prefix(4_000))
  }
}
