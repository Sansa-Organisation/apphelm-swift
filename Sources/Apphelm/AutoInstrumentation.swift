import Foundation
import ObjectiveC

/// The clients the automatic URLSession, file I/O and Core Data instrumentation records for,
/// and what each wants. The swizzles are process-wide and installed once; each recorded call
/// goes to every live client that asked for it.
enum AutoInstrumentation {
  struct Wants: Sendable {
    var networkSpans = false
    var networkBreadcrumbs = false
    var fileIO = false
    var coreData = false
  }

  final class Entry: @unchecked Sendable {
    weak var client: ApphelmClient?
    let wants: Wants
    init(client: ApphelmClient, wants: Wants) {
      self.client = client
      self.wants = wants
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var entries: [Entry] = []

  /// From the client's init: what its options turn on. Spans need a trace sample rate or
  /// sampler (automatic tracing is off without one); network breadcrumbs don't.
  static func install(_ client: ApphelmClient, options: ApphelmOptions) {
    // Every client's Apphelm host, whether or not it records anything itself.
    if let own = httpTarget(URL(string: options.baseURL))?.authority { lock.withLock { _ = ownHosts.insert(own) } }
    guard options.enabled, options.enableSwizzling else { return }
    let tracing = client.tracingConfigured
    let wants = Wants(networkSpans: options.enableNetworkTracking && tracing,
                      networkBreadcrumbs: options.enableNetworkBreadcrumbs && options.enableAutoBreadcrumbs,
                      fileIO: options.enableFileIOTracing && tracing,
                      coreData: options.enableCoreDataTracing && tracing)
    guard wants.networkSpans || wants.networkBreadcrumbs || wants.fileIO || wants.coreData else { return }
    lock.withLock {
      entries.removeAll { $0.client == nil }
      entries.append(Entry(client: client, wants: wants))
    }
    if wants.networkSpans || wants.networkBreadcrumbs { NetworkInstrumentation.installOnce() }
    if wants.fileIO { FileIOInstrumentation.installOnce() }
    if wants.coreData { CoreDataInstrumentation.installOnce() }
  }

  nonisolated(unsafe) private static var ownHosts = Set<String>()

  /// Whether `authority` is an Apphelm host a client sends to.
  static func isOwnHost(_ authority: String) -> Bool { lock.withLock { ownHosts.contains(authority) } }

  static func targets(_ wanted: (Wants) -> Bool) -> [Entry] {
    lock.withLock { entries.filter { $0.client != nil && wanted($0.wants) } }
  }
}

/// A per-thread "already inside a recorded call" flag: an instrumented method that calls
/// another (`writeToFile:atomically:` writing through `writeToURL:options:error:`, a wrapper
/// calling `NSData`) is recorded once, at the outermost call.
enum InstrumentationGuard {
  private static let key: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key, nil)
    return key
  }()

  static var active: Bool { pthread_getspecific(key) != nil }

  /// Run `body` with the flag set on this thread.
  static func with<T>(_ body: () throws -> T) rethrows -> T {
    let outer = pthread_getspecific(key)
    pthread_setspecific(key, UnsafeRawPointer(bitPattern: 1))
    defer { pthread_setspecific(key, outer) }
    return try body()
  }
}

/// Replace `selector`'s implementation in `type` itself (only when `type` declares it, never
/// a superclass's), keeping the original for the replacement to call. Returns the original.
func swizzle(_ type: AnyClass, _ selector: Selector, _ make: (IMP) -> Any) -> Bool {
  var count: UInt32 = 0
  guard let methods = class_copyMethodList(type, &count) else { return false }
  defer { free(methods) }
  for index in 0..<Int(count) where method_getName(methods[index]) == selector {
    let method = methods[index]
    let original = method_getImplementation(method)
    method_setImplementation(method, imp_implementationWithBlock(make(original)))
    return true
  }
  return false
}

// MARK: - URLSession

/// Automatic `http.client` spans and `http` breadcrumbs for every `URLSession` task, as
/// Sentry's network tracking does it: `URLSessionTask.resume` starts the span (and, for a
/// host in `tracePropagationHosts`, adds `traceparent` to the task's request before it is
/// sent), and the task's `setState:` reaching `completed` finishes it with the response's
/// status. Data, upload and download tasks only (not streams or WebSockets). Requests to the
/// client's own Apphelm host are left alone, and so are the calls `data(for:)` records itself.
enum NetworkInstrumentation {
  private static var recordKey: UInt8 = 0

  /// What one task's resume started.
  final class Record: NSObject, @unchecked Sendable {
    let method: String
    let target: (host: String, authority: String, shown: String)
    let spans: [(entry: AutoInstrumentation.Entry, span: Span?)]
    private let lock = NSLock()
    private var done = false
    init(method: String, target: (host: String, authority: String, shown: String), spans: [(entry: AutoInstrumentation.Entry, span: Span?)]) {
      self.method = method
      self.target = target
      self.spans = spans
    }
    func finishOnce() -> Bool { lock.withLock { defer { done = true }; return !done } }
  }

  private static let installed: Bool = {
    let resume = NSSelectorFromString("resume")
    let setState = NSSelectorFromString("setState:")
    // The classes of real tasks and their superclasses, each swizzled where it declares the
    // method (today that is URLSessionTask itself; older systems had private subclasses).
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let probe = URL(string: "https://apphelm.invalid/")!
    let samples: [URLSessionTask] = [session.dataTask(with: probe), session.downloadTask(with: probe), session.uploadTask(with: URLRequest(url: probe), from: Data())]
    var seen = Set<ObjectIdentifier>()
    var any = false
    for sample in samples {
      var type: AnyClass? = object_getClass(sample)
      while let current = type, current != NSObject.self {
        if seen.insert(ObjectIdentifier(current)).inserted {
          any = swizzle(current, resume) { original in
            let call = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> Void).self)
            let block: @convention(block) (AnyObject) -> Void = { task in
              NetworkInstrumentation.willResume(task)
              call(task, resume)
            }
            return block
          } || any
          _ = swizzle(current, setState) { original in
            let call = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector, Int) -> Void).self)
            let block: @convention(block) (AnyObject, Int) -> Void = { task, state in
              call(task, setState, state)
              if state == URLSessionTask.State.completed.rawValue { NetworkInstrumentation.didComplete(task) }
            }
            return block
          }
        }
        type = class_getSuperclass(current)
      }
    }
    for sample in samples { sample.cancel() }
    return any
  }()

  static func installOnce() { _ = installed }

  /// Calls through `data(for:)`, which records its own span and breadcrumb (task-local).
  @TaskLocal static var recordedByWrapper = false

  static func isTracked(_ task: URLSessionTask) -> Bool { objc_getAssociatedObject(task, &recordKey) != nil }

  /// Whether this instrumentation records `task`'s span and breadcrumb for `client`.
  static func recorded(_ task: URLSessionTask, for client: ApphelmClient) -> (span: Bool, breadcrumb: Bool) {
    guard let record = objc_getAssociatedObject(task, &recordKey) as? Record,
          let mine = record.spans.first(where: { $0.entry.client === client }) else { return (false, false) }
    return (mine.span != nil, mine.entry.wants.networkBreadcrumbs)
  }

  static func willResume(_ object: AnyObject) {
    guard let task = object as? URLSessionTask, !recordedByWrapper, !isTracked(task),
          task is URLSessionDataTask || task is URLSessionDownloadTask || task is URLSessionUploadTask,
          !(task is URLSessionStreamTask) else { return }
    if task is URLSessionWebSocketTask { return }
    let request = task.currentRequest ?? task.originalRequest
    guard let target = httpTarget(request?.url) else { return }
    let entries = AutoInstrumentation.targets { $0.networkSpans || $0.networkBreadcrumbs }
    // Apphelm's own requests (events, replay, profiles), from any client, are never recorded.
    guard !entries.isEmpty, !AutoInstrumentation.isOwnHost(target.authority) else { return }
    let method = (request?.httpMethod ?? "GET").uppercased()
    var spans: [(entry: AutoInstrumentation.Entry, span: Span?)] = []
    var propagated = false
    for entry in entries {
      guard let client = entry.client else { continue }
      var span: Span?
      if entry.wants.networkSpans, let transaction = client.activeTransaction, !transaction.isFinished {
        let started = transaction.startSpan("http.client", description: "\(method.prefix(10)) \(target.shown)", data: httpSpanData(method: method, target: target, statusCode: nil))
        span = started
        if !propagated, propagatesTo(target.host, listed: client.options.tracePropagationHosts) {
          propagated = setHeader(task, "traceparent", started.traceparent())
        }
      }
      spans.append((entry, span))
    }
    objc_setAssociatedObject(task, &recordKey, Record(method: method, target: target, spans: spans), .OBJC_ASSOCIATION_RETAIN)
  }

  /// The task's request is an `NSMutableURLRequest` until it is sent; a header set on it
  /// before `resume` goes out with it (what Sentry relies on too). False when it isn't.
  private static func setHeader(_ task: URLSessionTask, _ name: String, _ value: String) -> Bool {
    guard let request = (task as NSObject).value(forKey: "currentRequest") as AnyObject? as? NSMutableURLRequest else { return false }
    request.setValue(value, forHTTPHeaderField: name)
    return true
  }

  static func didComplete(_ object: AnyObject) {
    guard let task = object as? URLSessionTask, let record = objc_getAssociatedObject(task, &recordKey) as? Record, record.finishOnce() else { return }
    let status = (task.response as? HTTPURLResponse)?.statusCode
    let ok = task.error == nil && (status.map { (100...399).contains($0) } ?? false)
    for (entry, span) in record.spans {
      if let span {
        if let status { span.setData("http.response.status_code", status) }
        span.finish(ok ? .ok : .error)
      }
      if entry.wants.networkBreadcrumbs { entry.client?.httpBreadcrumb(method: record.method, target: record.target, statusCode: status) }
    }
  }
}
