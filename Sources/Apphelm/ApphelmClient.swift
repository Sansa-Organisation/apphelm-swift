import Foundation

/// Transport-level failure. Flag checks never throw: they fail closed to `false`.
public struct ApphelmError: Error, Sendable {
  public let message: String
  public let status: Int
  public let code: String
}

/// Synchronous distinct-id storage. back it with UserDefaults, Keychain, or memory in tests.
public protocol DistinctIdStore: Sendable {
  func load() -> String?
  func save(_ distinctId: String)
}

public final class UserDefaultsStore: DistinctIdStore, @unchecked Sendable {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "apphelm.distinctId") {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> String? { defaults.string(forKey: key) }
  public func save(_ distinctId: String) { defaults.set(distinctId, forKey: key) }
}

public struct ApphelmOptions: Sendable {
  public var apiKey: String
  public var baseURL: String
  public var workspaceId: String
  public var productId: String
  public var distinctId: String?
  public var timeoutSeconds: Double
  /// Your build's release id and environment, sent with every exception and crash so
  /// issues show where they happen and "resolve in next release" works.
  public var release: String?
  public var environment: String?
  /// The share of transactions started here that are kept, 0–1, or nil (the default: not
  /// set). While neither it nor `tracesSampler` is set, automatic tracing (screen loads from
  /// `enableUIViewControllerTracing`, app starts from `enableAppStartTracking`) is off, and
  /// transactions you start yourself with `startTransaction`/`startScreen` are kept at a rate
  /// of 1. Once set, it applies to both. A transaction continuing an incoming `traceparent`
  /// keeps the caller's decision instead. Each kept transaction is one event.
  public var tracesSampleRate: Double?
  /// The hosts automatic HTTP spans send `traceparent` to, so their transactions join the
  /// app's trace: your own services only, since the header tells the receiver the trace id.
  /// An entry is one host (`api.example.com`) or, with a leading dot, every host under a
  /// domain (`.example.com`). Empty by default: no request carries the header.
  public var tracePropagationHosts: [String]
  /// For surveys only: the product's project key (`ahl_pub_…`, the key the browser SDK
  /// uses) and one of the origins that key allows (`https://app.example.com`). The survey
  /// routes are the browser's and take this pair, not `apiKey`. Both are public values. A
  /// `surveyKey` that does not start with `ahl_pub_` is refused before anything is sent.
  /// Set them after `init`: `options.surveyKey = "ahl_pub_…"`.
  public var surveyKey: String? = nil
  public var surveyOrigin: String? = nil
  /// What the person agreed to for ads (nil: nothing, the default). Set it from your consent
  /// prompt; Apphelm does not ask. While set, every event carries `$ad_consent` and
  /// `recordInstall` sends the install's ad evidence for Yieldline. Change it later with
  /// `ApphelmClient.setAdsConsent`.
  public var adsConsent: AdsConsent? = nil
  /// Flush every this many seconds (default 30). 0 turns the timer off.
  public var flushIntervalSeconds: Double = 30
  /// Flush as soon as this many events are queued (default 20). 0 turns it off.
  public var flushAt: Int = 20
  /// Flush when the app goes to the background, with background time to finish the send
  /// (default true; UIKit apps).
  public var flushOnBackground: Bool = true
  /// The most events kept queued (default 1000); past it the oldest are dropped.
  public var maxQueueSize: Int = 1000
  /// Where the queue and the client's state are kept (default `.disk`: queued events
  /// survive the app being killed).
  public var persistence: ApphelmPersistence = .disk
  /// Send `$app_installed`, `$app_updated`, `$app_opened` and `$app_backgrounded`
  /// (default true). Opened and backgrounded need UIKit.
  public var captureApplicationLifecycleEvents: Bool = true
  /// Send a `$screen` each time a UIKit view controller appears (default true). SwiftUI
  /// views use `.apphelmScreen("Name")` instead.
  public var captureScreenViews: Bool = true
  /// Start opted out of analytics until `optIn()` (default false). A choice made with
  /// `optIn()` or `optOut()` is remembered and wins over this.
  public var defaultOptedOut: Bool = false
  /// Session replay of native screens as wireframes (nil, the default: off). Recording starts
  /// only after `setReplayConsent(true)`. See `ReplayOptions`.
  public var replay: ReplayOptions? = nil
  /// Called with the properties of every event before it is queued or sent: events you
  /// track, screens, identify, alias and group events, flag exposures, sessions,
  /// exceptions, messages, crash reports and transactions (the same hook as Kotlin's). The
  /// dictionary also holds the event's name as `$event_name` (read-only: it is removed
  /// before sending). Return the properties, changed or not, to send the event, or nil to
  /// drop it; a result that can't be sent as JSON also drops it. Keep it quick: it runs on
  /// the thread that tracks the event. Exceptions, messages, crash reports and transactions
  /// reach it already scrubbed: secrets and emails in messages, stack frames, tags,
  /// breadcrumbs, span names, descriptions and data are replaced (`[key]`, `[email]`,
  /// `[redacted]`…) and URLs lose their query, fragment and user info. That can't be turned
  /// off. What the hook returns is sent as it is; the server scrubs again either way.
  public var beforeSend: (@Sendable ([String: Any]) -> [String: Any]?)? = nil
  /// Called with each breadcrumb before it is kept: return it (changed or not), or nil to
  /// drop it. Automatic breadcrumbs pass through it too.
  public var beforeBreadcrumb: (@Sendable (Breadcrumb) -> Breadcrumb?)? = nil
  /// The most breadcrumbs kept on the device (default 100; 0 keeps none). Each event
  /// carries the last 30.
  public var maxBreadcrumbs: Int = 100
  /// Record breadcrumbs on their own (default true): screens (`navigation`), the app coming
  /// to the foreground and going to the background (`app.lifecycle`), low-memory warnings
  /// (`device.event`), requests made through `data(for:)` or `httpSpanDelegate()` (`http`)
  /// and, on UIKit, controls sending actions (`ui.click`, the action and the target's type,
  /// never a label's text).
  public var enableAutoBreadcrumbs: Bool = true
  /// Start release-health sessions on their own (default true; needs `release`): one when
  /// the app comes to the foreground, ended once it has been in the background for
  /// `sessionTrackingIntervalSeconds`. Without UIKit (macOS) one session runs per launch.
  /// Each session is one `$session` event. Set false to call `startSession` yourself.
  public var enableAutoSessionTracking: Bool = true
  /// How long the app may stay in the background before its session ends (default 30 s,
  /// as Sentry's).
  public var sessionTrackingIntervalSeconds: Double = 30
  /// Decides the sampling rate of each new transaction (0–1), or nil to use
  /// `tracesSampleRate` (and, when that is not set either, the default: automatic
  /// transactions unsampled, your own kept). Setting it turns automatic tracing on, as a
  /// rate does. Not asked for a transaction continuing a sampled or unsampled incoming trace.
  public var tracesSampler: (@Sendable (SamplingContext) -> Double?)? = nil
  /// The share of sampled transactions to profile, 0–1, or nil (the default: off). A
  /// background thread samples the main thread's stack every 10 ms while a profiled
  /// transaction runs (one at a time, at most 30 s), and the profile is sent to
  /// `/api/v1/profiles` when it finishes, with its id on the transaction as `profile_id`.
  /// Frames are addresses: upload your dSYMs so the server can name them. See the README,
  /// "Profiling", for the overhead.
  public var profilesSampleRate: Double? = nil
  /// Send each app start as a `$transaction` (`app.start.cold` or `app.start.warm`, with
  /// `app_start_cold_ms` or `app_start_warm_ms`), from process start to the first frame
  /// (default false: one event per launch, sampled by `tracesSampleRate`). It also needs
  /// `tracesSampleRate` or `tracesSampler`: without one nothing is measured. UIKit only.
  public var enableAppStartTracking: Bool = false
  /// Time every UIKit view controller's load as a `ui.load` transaction, from `viewDidLoad`
  /// to the first frame drawn after `viewDidAppear` (`ttid_ms`), by swizzling both (default
  /// false: one event per screen shown, sampled by `tracesSampleRate`). It also needs
  /// `tracesSampleRate` or `tracesSampler`: without one nothing is swizzled. Screens are
  /// named as `captureScreenViews` names them.
  public var enableUIViewControllerTracing: Bool = false
  /// Keep an automatic screen load open until `reportFullyDisplayed()` (`ttfd_ms`), or 30 s
  /// (default false: it finishes at the first frame).
  public var enableTimeToFullDisplayTracing: Bool = false
  /// Count slow (missed the display's refresh) and frozen (over 700 ms) frames with a
  /// `CADisplayLink`, and send them on every transaction as `frames_total`, `frames_slow`
  /// and `frames_frozen` (default true; UIKit only; adds no events).
  public var enableFramesTracking: Bool = true
  /// Detect app hangs: the main thread not answering for `appHangTimeoutInterval` seconds
  /// while the app is in the foreground (default true, as Sentry's). Starts with
  /// `installCrashReporting()`; not under a debugger. A hang the app comes out of is sent as an
  /// error (`App Hang Fully Blocked` / `App Hang Non Fully Blocked`, mechanism `AppHang`) with
  /// the main thread's stack; one it never comes out of is sent on the next launch as a fatal
  /// app hang. See the README, "App hangs".
  public var enableAppHangTracking: Bool = true
  /// How long the main thread must be blocked to count as a hang, in seconds (default 2, as
  /// Sentry's; 0 or less means 2).
  public var appHangTimeoutInterval: Double = 2
  /// Also report hangs where the main thread still drew a frame now and then but was late for
  /// the whole timeout (default true, as Sentry's). Needs the display link (UIKit with
  /// `enableFramesTracking`); without it only fully blocking hangs are found.
  public var enableReportNonFullyBlockingAppHangs: Bool = true
  /// On launch, report a previous run the system killed in the foreground without a crash or
  /// a normal exit (out of memory, the watchdog) as an unhandled `WatchdogTermination`, which
  /// crashes that run's session (default true, as Sentry's; UIKit only, not on a simulator).
  /// Starts with `installCrashReporting()`. See the README, "Watchdog terminations".
  public var enableWatchdogTerminationTracking: Bool = true
  /// False turns off every method swizzle the SDK would install: URLSession, file I/O,
  /// Core Data, UIKit screen loads and `ui.click` breadcrumbs (default true, as Sentry's).
  public var enableSwizzling: Bool = true
  /// Record every `URLSession` data, upload and download task as an `http.client` span of the
  /// active transaction, by swizzling `URLSessionTask` (default true, as Sentry's). Needs
  /// `tracesSampleRate` or `tracesSampler`. `traceparent` goes only to
  /// `tracePropagationHosts`. Requests to Apphelm itself are never recorded.
  public var enableNetworkTracking: Bool = true
  /// An `http` breadcrumb for every `URLSession` request (default true, as Sentry's; with
  /// `enableAutoBreadcrumbs`). Swizzles `URLSessionTask` even without a trace sample rate.
  public var enableNetworkBreadcrumbs: Bool = true
  /// `file.read` / `file.write` spans for `NSData` reads and writes (and `FileManager`'s
  /// `createFile` on iOS 18 / macOS 15 and later) in the active transaction (default true, as
  /// Sentry's). Needs `tracesSampleRate` or `tracesSampler`. Swift's `Data(contentsOf:)` and
  /// `Data.write(to:)` no longer go through `NSData` on recent OS versions: use
  /// `Data(contentsOfWithApphelmTracing:)` and `writeWithApphelmTracing(to:)` for those.
  public var enableFileIOTracing: Bool = true
  /// `db.sql.query` spans for Core Data fetches and `db.sql.transaction` spans for saves in
  /// the active transaction, by swizzling `NSManagedObjectContext` (default true, as
  /// Sentry's; only when the app uses Core Data). Needs `tracesSampleRate` or `tracesSampler`.
  public var enableCoreDataTracing: Bool = true
  /// Write the SDK's own diagnostics to the unified log (subsystem `dev.apphelm`, category
  /// `sdk`): why an event was dropped (disabled, `ignoreErrors`, `denyUrls`, `allowUrls`,
  /// `sampleRate`, `beforeSend`), sends that failed and requests the server refused, with their status. Never event
  /// contents beyond names, ids and reasons. Default false.
  public var debug: Bool = false
  /// False turns the client into a no-op that sends nothing: events, screens, sessions,
  /// exceptions, messages, crash reports, transactions, profiles, logs, feedback and
  /// check-ins. Captures return `false` or nil. Flag reads and surveys keep working, and
  /// `withMonitor` still runs its job. Default true.
  public var enabled: Bool = true
  /// The share of errors sent, 0–1 (default 1): exceptions, messages, `captureEvent` and crash
  /// reports. A sampled-out crash report is deleted. Transactions, sessions, analytics, logs
  /// and feedback are not affected.
  public var sampleRate: Double = 1
  /// Errors (exceptions, messages, `captureEvent`, crash reports) not to send: a pattern
  /// that matches the message, the error's type or `Type: message`. A plain string matches as
  /// a substring, `.regex("…")` by search. Matched on the device against the raw text.
  public var ignoreErrors: [ApphelmPattern] = []
  /// Errors not to send, by the binary (image) their top stack frame is in, the innermost one
  /// (`ShopKit`, `MyApp`), with the same patterns: an error whose frame matches any of them is
  /// dropped. Checked after `ignoreErrors`, before `sampleRate`. Applies to `captureException`
  /// (whose stack starts where it was called) and to `captureEvent` with a stack trace whose
  /// first line is in `Thread.callStackSymbols` form. Messages, other events and crash reports
  /// are always kept. Sentry's Cocoa SDK has no such option.
  public var denyUrls: [ApphelmPattern] = []
  /// When not empty, an error whose top frame (as for `denyUrls`) matches none of these
  /// patterns is dropped too. Errors without such a frame are kept.
  public var allowUrls: [ApphelmPattern] = []
  /// Transactions not to send, by name, with the same patterns. A matching transaction is
  /// not profiled either.
  public var ignoreTransactions: [ApphelmPattern] = []
  /// Logs (`client.logger`): lines below this level are not sent. Default `.info`.
  public var logsMinLevel: LogLevel = .info
  /// The OpenTelemetry `service.name` of logged lines (default `unknown_service`).
  public var logsService: String? = nil
  /// Change or drop (return nil) each log line before it is queued. It sees the line
  /// already scrubbed.
  public var beforeSendLog: (@Sendable (LogRecord) -> LogRecord?)? = nil
  /// Logs are sent every this many seconds (default 2) or when `logsMaxBatch` lines wait
  /// (default 500). At most `logsMaxQueue` lines wait (default 10,000; the oldest are dropped).
  public var logsFlushIntervalSeconds: Double = 2
  public var logsMaxBatch: Int = 500
  public var logsMaxQueue: Int = 10_000

  public init(apiKey: String, baseURL: String = "https://apphelm.dev", workspaceId: String, productId: String, distinctId: String? = nil, timeoutSeconds: Double = 10, release: String? = nil, environment: String? = nil, tracesSampleRate: Double? = nil, tracePropagationHosts: [String] = [], adsConsent: AdsConsent? = nil) {
    self.adsConsent = adsConsent
    self.tracePropagationHosts = tracePropagationHosts
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.workspaceId = workspaceId
    self.productId = productId
    self.distinctId = distinctId
    self.timeoutSeconds = timeoutSeconds
    self.release = release.map { String($0.prefix(120)) }
    self.environment = environment.map { String($0.prefix(40)) }
    self.tracesSampleRate = tracesSampleRate.map { $0.isNaN ? 1 : min(1, max(0, $0)) }
  }
}

private struct EvaluationDTO: Decodable {
  let key: String
  let enabled: Bool
  let variant: String?
  let payload: JSONValue?
  let reason: String
  /// Set when a running experiment depends on the flag.
  let experiment: Bool?
  /// boolean, multivariate or remote_config; absent from servers before 0.7.0.
  let flagType: String?

  var evaluation: FlagEvaluation { FlagEvaluation(key: key, enabled: enabled, variant: variant, payload: payload, reason: reason, flagType: flagType) }
}

private struct EvaluationsEnvelope: Decodable {
  let data: [EvaluationDTO]
}

private struct ConfigsEnvelope: Decodable {
  let data: [FlagConfig]
}

struct AcceptedEnvelope: Decodable {
  let accepted: Bool?
}

/// Native iOS/macOS client on URLSession. Events are queued on disk (bounded, oldest
/// dropped) and flushed on a timer, at a queue length and when the app goes to the
/// background. UIKit is used only where it exists, for lifecycle events and screen views.
public final class ApphelmClient: Sendable {
  let options: ApphelmOptions
  let session: URLSession
  private let store: any DistinctIdStore
  private let installStore: any InstallRecordStore
  private let attributionToken: AttributionTokenProvider
  let lock = NSLock()
  private var _distinctId: String
  private let queue: EventQueue
  private let state: ClientState
  let appInfo: AppInfo
  private var _anonymousId: String
  private var _identified: Bool
  private var _superProperties: [String: Any]
  private var _groups: [String: String]
  private var _optedOut: Bool
  // Flushes run one after another; each waits for the one before.
  private var flushTail: Task<Void, Never>?
  private var thresholdFlushRunning = false
  // Set after a flush that could not reach the server, so each new event doesn't retry.
  private var thresholdSuspended = false
  private var flushTimer: (any RepeatingTimer)?
  private var lifecycleObserver: AnyObject?
  private var appActive = false
  private var wasBackgrounded = false
  private var exposed: Set<String> = []
  private var health: (hash: String, clock: TraceClock, directory: URL)?
  // The most recently started transaction, held weakly: an abandoned one is not kept alive.
  private weak var active: Transaction?
  /// The thread profiles sample: nil is the main thread. Tests name their own.
  var profiledThread: thread_act_t? = nil
  private var _adsConsent: AdsConsent?
  // Set once this client has queued (or found) the install, so it is queued at most once
  // even when the install record cannot be saved.
  private var installClaimed = false
  private var replayRecorder: ReplayRecorder?
  // Told of each event tracked while opted in (automatic surveys): its name and screen name.
  private var captureObserver: (@Sendable (String, String?) -> Void)?
  // Scope: breadcrumbs, tags and the user's hash for exceptions, messages and crashes.
  private let breadcrumbs: BreadcrumbBuffer
  private var tags: [String: Any] = [:]
  private var userHash: String?
  // setContext: named groups of scalar values, sent as `context.<name>.<key>` tags.
  var contexts: [String: [String: Any]] = [:]
  // The id of the last exception, message or event captured (lastEventId).
  var _lastEventId: String?
  // Set by close(): nothing is sent afterwards.
  var closed = false
  // The logger (`logger`), made on first use.
  var _logger: ApphelmLogger?
  // Tests: told each `debug` line.
  var debugObserver: (@Sendable (String) -> Void)?
  private var sessionTimeout: SessionTimeout
  // Set by installCrashReporting: where sessions and the crash scope are written.
  private var crashDirectory: URL?
  private var screenLoad: ScreenLoadState?
  let frames: FrameStats
  // Where the crash scope is kept (the process-wide store the crash handlers read).
  private let crashScope: CrashScopeStore
  private static let appStartLock = NSLock()
  nonisolated(unsafe) private static var appStartReported = false

  /// `installStore` remembers that `$install` was sent (`UserDefaultsInstallRecordStore` by default).
  public convenience init(options: ApphelmOptions, session: URLSession = .shared, store: (any DistinctIdStore)? = nil, installStore: (any InstallRecordStore)? = nil) {
    self.init(options: options, session: session, store: store, installStore: installStore, attributionToken: appleAdsAttributionToken)
  }

  init(options: ApphelmOptions, session: URLSession, store: (any DistinctIdStore)?, installStore: (any InstallRecordStore)?, attributionToken: @escaping AttributionTokenProvider, timerFactory: RepeatingTimerFactory = dispatchTimerFactory, appInfo: AppInfo? = nil, frames: FrameStats = .shared, crashScope: CrashScopeStore = .shared) {
    self.options = options
    self.frames = frames
    self.crashScope = crashScope
    self.breadcrumbs = BreadcrumbBuffer(capacity: options.maxBreadcrumbs)
    self.sessionTimeout = SessionTimeout(timeout: options.sessionTrackingIntervalSeconds)
    _ = sdkLoadedAt
    self.session = session
    let resolvedInstallStore = installStore ?? UserDefaultsInstallRecordStore()
    self.installStore = resolvedInstallStore
    self.attributionToken = attributionToken
    self._adsConsent = options.adsConsent
    let resolvedStore: any DistinctIdStore = store ?? UserDefaultsStore()
    self.store = resolvedStore
    // An app that used Apphelm before this version has an id or an install record already.
    let usedBefore = !(resolvedStore.load() ?? "").isEmpty || resolvedInstallStore.isInstallRecorded()
    let explicit = options.distinctId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !explicit.isEmpty {
      self._distinctId = explicit
    } else if let stored = resolvedStore.load(), !stored.isEmpty {
      self._distinctId = stored
    } else {
      let generated = UUID().uuidString
      resolvedStore.save(generated)
      self._distinctId = generated
    }
    switch options.persistence {
    case .disk:
      state = ClientState(defaults: .standard)
      queue = EventQueue.shared(directory: defaultQueueDirectory(options: options), maxSize: options.maxQueueSize)
    case .directory(let directory, let suiteName):
      state = ClientState(defaults: suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard)
      queue = EventQueue.shared(directory: directory, maxSize: options.maxQueueSize)
    case .memory:
      state = ClientState(defaults: nil)
      queue = EventQueue(directory: nil, maxSize: options.maxQueueSize)
    }
    self.appInfo = appInfo ?? AppInfo.main()
    _optedOut = state.bool(ClientState.optedOut) ?? options.defaultOptedOut
    // An id passed in options is taken as an identified person, as before.
    _identified = !explicit.isEmpty || state.bool(ClientState.identified) == true
    let storedAnonymous = state.string(ClientState.anonymousId) ?? ""
    _anonymousId = !storedAnonymous.isEmpty ? storedAnonymous : (_identified ? UUID().uuidString : _distinctId)
    _superProperties = state.object(ClientState.superProperties)
    _groups = state.object(ClientState.groups).compactMapValues { $0 as? String }
    if storedAnonymous.isEmpty { state.set(_anonymousId, ClientState.anonymousId) }

    detectInstallOrUpdate(usedBefore: usedBefore)
    if options.flushIntervalSeconds > 0 {
      flushTimer = timerFactory(options.flushIntervalSeconds) { [weak self] in
        guard let self, self.queue.count > 0 else { return }
        Task { await self.flush() }
      }
    }
    #if canImport(UIKit) && !os(watchOS)
    if options.captureApplicationLifecycleEvents || options.flushOnBackground || options.enableAutoSessionTracking || options.enableAutoBreadcrumbs { lifecycleObserver = LifecycleObserver(client: self) }
    UIKitInstrumentation.install(self, options: options)
    #else
    // No UIKit lifecycle (macOS): one automatic session per launch.
    if options.enableAutoSessionTracking { autoSessionForeground() }
    #endif
    AutoInstrumentation.install(self, options: options)
    if options.captureScreenViews { ScreenCapture.register(self) }
    if let replay = options.replay {
      let uploader = ReplayUploader(baseURL: options.baseURL, key: replay.projectKey ?? options.surveyKey, origin: replay.origin ?? options.surveyOrigin, timeout: options.timeoutSeconds, session: session)
      replayRecorder = ReplayRecorder(options: replay, workspaceId: options.workspaceId, productId: options.productId,
        person: { [weak self] in
          guard let self else { return ReplayRecorder.Person(distinctId: "", identified: false) }
          return ReplayRecorder.Person(distinctId: self.distinctId, identified: self.lock.withLock { self._identified })
        },
        sessionHash: { [weak self] in self?.sessionId },
        allowed: { [weak self] in self.map { !$0.isOptedOut && $0.isActive } ?? false },
        bufferResetSeconds: options.sessionTrackingIntervalSeconds,
        send: uploader.map { uploader -> ReplayRecorder.Sender in { body in await uploader.send(body) } })
      // A crash's replay waits on disk beside the crash reports once those are installed.
      replayRecorder?.crashSink = { ReplayCrashStore.shared.update($0) }
    }
    Self.latestLock.withLock { Self._latest = self }
  }

  deinit {
    flushTimer?.cancel()
  }

  private static let latestLock = NSLock()
  nonisolated(unsafe) private static weak var _latest: ApphelmClient?
  /// The client created most recently, for `.apphelmScreen` without a client.
  static var latest: ApphelmClient? { latestLock.withLock { _latest } }

  /// `$app_installed` on the first launch, `$app_updated` when the version or build changed
  /// since the last one. The version seen is kept in the state, so this needs persistence.
  /// An app that used Apphelm before this version is not counted as a new install.
  private func detectInstallOrUpdate(usedBefore: Bool) {
    guard state.isPersistent else { return }
    let previousVersion = state.string(ClientState.appVersion)
    let previousBuild = state.string(ClientState.appBuild)
    state.set(appInfo.version, ClientState.appVersion)
    state.set(appInfo.build, ClientState.appBuild)
    guard options.captureApplicationLifecycleEvents else { return }
    if previousVersion == nil && previousBuild == nil {
      if !usedBefore { enqueue("$app_installed", properties: ["version": appInfo.version, "build": appInfo.build]) }
    } else if previousVersion != appInfo.version || previousBuild != appInfo.build {
      enqueue("$app_updated", properties: ["version": appInfo.version, "build": appInfo.build, "previous_version": previousVersion ?? "", "previous_build": previousBuild ?? ""])
    }
  }

  /// The app became active: `$app_opened`, once per launch and once per return from the
  /// background (not after a brief interruption such as a call alert).
  func applicationDidBecomeActive() {
    let fromBackground: Bool? = lock.withLock {
      if appActive { return nil }
      appActive = true
      return wasBackgrounded
    }
    replayRecorder?.visibility(hidden: false)
    guard let fromBackground else { return }
    if options.enableAutoSessionTracking { autoSessionForeground() }
    if options.enableAutoBreadcrumbs { addBreadcrumb(category: "app.lifecycle", message: "foreground") }
    guard options.captureApplicationLifecycleEvents else { return }
    enqueue("$app_opened", properties: ["from_background": fromBackground, "version": appInfo.version, "build": appInfo.build])
  }

  /// An automatic session for the app coming to the foreground at `now`.
  func autoSessionForeground(now: Date = Date()) {
    let action = lock.withLock { sessionTimeout.foreground(at: now.timeIntervalSince1970) }
    switch action {
    case .start:
      startSession()
    case .restart:
      endSession()
      lock.withLock { _ = sessionTimeout.foreground(at: now.timeIntervalSince1970) }
      startSession()
    case .keep:
      // A session ended by hand while in the background: start the next one.
      if sessionId == nil { startSession() }
    }
  }

  /// The app went to the background at `now`: its automatic session ends if it stays there.
  func autoSessionBackground(now: Date = Date()) {
    lock.withLock { sessionTimeout.background(at: now.timeIntervalSince1970) }
  }

  /// The app went to the background: `$app_backgrounded`, then a flush. `finish` is called
  /// when the flush is over (it ends the background task).
  func applicationDidEnterBackground(finish: @escaping @Sendable () -> Void = {}) {
    lock.withLock {
      appActive = false
      wasBackgrounded = true
    }
    if options.enableAutoSessionTracking { autoSessionBackground() }
    if options.enableAutoBreadcrumbs { addBreadcrumb(category: "app.lifecycle", message: "background") }
    if options.captureApplicationLifecycleEvents { enqueue("$app_backgrounded", properties: [:]) }
    replayRecorder?.visibility(hidden: true)
    if let replay = replayRecorder { Task { await replay.flush() } }
    guard options.flushOnBackground else { finish(); return }
    Task {
      await self.flush()
      finish()
    }
  }

  public var distinctId: String {
    lock.withLock { _distinctId }
  }

  func request(path: String, body: [String: Any]?) throws -> URLRequest {
    guard let url = URL(string: options.baseURL + "/api/v1" + path) else {
      throw ApphelmError(message: "Invalid base URL.", status: 0, code: "invalid_base_url")
    }
    var request = URLRequest(url: url, timeoutInterval: options.timeoutSeconds)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("Bearer \(options.apiKey)", forHTTPHeaderField: "authorization")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    return request
  }

  func send<T: Decodable>(path: String, body: [String: Any]?, headers: [String: String] = [:]) async throws -> T {
    var request = try request(path: path, body: body)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ApphelmError(message: "Non-HTTP response.", status: 0, code: "request_failed")
    }
    guard (200...299).contains(http.statusCode) else {
      if let envelope = try? JSONDecoder().decode([String: ErrorEnvelope].self, from: data),
         let details = envelope["error"] {
        throw ApphelmError(message: details.message, status: http.statusCode, code: details.code)
      }
      throw ApphelmError(message: "Apphelm request failed (\(http.statusCode)).", status: http.statusCode, code: "request_failed")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  /// Enqueue one event. Past `maxQueueSize` queued, the oldest are dropped. Nothing is
  /// queued while opted out.
  public func track(_ name: String, properties: [String: Any] = [:]) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    enqueue(trimmed, properties: properties)
    if let observer = lock.withLock({ _optedOut ? nil : captureObserver }) { observer(trimmed, properties["$screen_name"] as? String) }
  }

  /// Set or clear the observer of tracked events (one at a time).
  func setCaptureObserver(_ observer: (@Sendable (String, String?) -> Void)?) {
    lock.withLock { captureObserver = observer }
  }

  /// `distinctId` overrides the current id (for `$identify`).
  private func enqueue(_ trimmed: String, properties: [String: Any], distinctId: String? = nil) {
    let prepared: [String: Any]? = lock.withLock {
      if _optedOut || closed || !options.enabled { return nil }
      let signal = customerSignalEvents.contains(trimmed)
      // Super properties and groups first; the event's own properties win.
      var merged: [String: Any] = signal ? [:] : _superProperties
      if !signal, !_groups.isEmpty { merged["$groups"] = _groups }
      merged.merge(properties) { _, own in own }
      // The consent the event was tracked under, not the one in force when it is flushed.
      if let consent = _adsConsent, !signal { merged["$ad_consent"] = consent.rawValue }
      // The person at track time: an event tracked before identify stays the anonymous one's.
      merged["distinct_id"] = distinctId ?? _distinctId
      return jsonSafe(merged) as? [String: Any]
    }
    // beforeSend runs outside the lock, so a hook that calls the client can't deadlock.
    guard let prepared, let kept = keptByBeforeSend(trimmed, prepared), !isOptedOut else { return }
    // The id and time are fixed at track time, so a resend after a lost response is stored once.
    let length = queue.append(["eventName": trimmed, "properties": kept, "eventId": UUID().uuidString, "occurredAt": ISO8601DateFormatter().string(from: Date())])
    guard options.flushAt > 0, length >= options.flushAt else { return }
    let start: Bool = lock.withLock {
      if thresholdFlushRunning || thresholdSuspended { return false }
      thresholdFlushRunning = true
      return true
    }
    guard start else { return }
    Task {
      await self.flush()
      self.lock.withLock { self.thresholdFlushRunning = false }
    }
  }

  /// Whether analytics is off for this person: nothing is queued or sent.
  public var isOptedOut: Bool {
    lock.withLock { _optedOut }
  }

  /// Stop analytics: queued events are deleted, and nothing is queued or sent (events,
  /// screens, exceptions, crash reports, transactions, identify) until `optIn()`. Flags and
  /// surveys still work. Remembered across launches.
  public func optOut() {
    lock.withLock {
      _optedOut = true
      state.set(true, ClientState.optedOut)
      queue.clear()
    }
  }

  /// Turn analytics back on. Remembered across launches.
  public func optIn() {
    lock.withLock {
      _optedOut = false
      state.set(false, ClientState.optedOut)
    }
  }

  /// Link this device's events to a person: sends `$identify` with `distinct_id` set to
  /// `distinctId` and `$anon_distinct_id` set to the anonymous id used until now, plus
  /// `$set` with `traits` when given. Later events carry `distinctId`, kept across
  /// launches. Identifying as someone else while already identified sends no
  /// `$anon_distinct_id`, so two people are never merged; call `reset()` at log-out.
  ///
  /// For the provenance-checked customer profile, use `identify(externalUserId:traits:traitSources:)`.
  public func identify(_ distinctId: String, traits: [String: Any] = [:]) {
    let id = distinctId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return }
    let anonymous: String?? = lock.withLock {
      if _identified && _distinctId == id && traits.isEmpty { return .none }
      // Only an anonymous person is merged: re-identifying, or switching people, merges nothing.
      let previous: String? = _identified ? nil : _anonymousId
      _distinctId = id
      _identified = true
      return .some(previous)
    }
    guard case .some(let previous) = anonymous else { return }
    store.save(id)
    state.set(true, ClientState.identified)
    var properties: [String: Any] = [:]
    if let previous, previous != id { properties["$anon_distinct_id"] = previous }
    if !traits.isEmpty { properties["$set"] = traits }
    enqueue("$identify", properties: properties, distinctId: id)
  }

  /// Tell Apphelm `alias` is another id of the current person: sends `$create_alias` with
  /// `alias`, from the current id.
  public func alias(_ alias: String) {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != distinctId else { return }
    enqueue("$create_alias", properties: ["alias": trimmed])
  }

  /// Put this person in a group (`type` such as `company`, `key` its id): every later event
  /// carries `$groups` `{type: key}`, kept across launches. With `traits`, also sends
  /// `$groupidentify` with `$group_type`, `$group_key` and `$group_set`.
  public func group(type: String, key: String, traits: [String: Any] = [:]) {
    let groupType = type.trimmingCharacters(in: .whitespacesAndNewlines)
    let groupKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !groupType.isEmpty, !groupKey.isEmpty else { return }
    let groups: [String: String] = lock.withLock {
      _groups[groupType] = groupKey
      return _groups
    }
    state.setObject(groups, ClientState.groups)
    if !traits.isEmpty { enqueue("$groupidentify", properties: ["$group_type": groupType, "$group_key": groupKey, "$group_set": traits]) }
  }

  /// The groups later events carry as `$groups`.
  public var groups: [String: String] {
    lock.withLock { _groups }
  }

  /// Super properties: sent with every later event, kept across launches. An event's own
  /// properties win over them.
  public func register(_ properties: [String: Any]) {
    let all: [String: Any] = lock.withLock {
      _superProperties.merge(jsonSafe(properties) as? [String: Any] ?? [:]) { _, new in new }
      return _superProperties
    }
    state.setObject(all, ClientState.superProperties)
  }

  /// Stop sending one super property.
  public func unregister(_ key: String) {
    let all: [String: Any] = lock.withLock {
      _superProperties.removeValue(forKey: key)
      return _superProperties
    }
    state.setObject(all, ClientState.superProperties)
  }

  /// At log-out: a new anonymous id, and no identified id, super properties or groups.
  /// Events already queued keep the id they were tracked with. Opt-out is kept.
  public func reset() {
    let fresh = UUID().uuidString
    lock.withLock {
      _distinctId = fresh
      _anonymousId = fresh
      _identified = false
      _superProperties = [:]
      _groups = [:]
      exposed = []
    }
    store.save(fresh)
    state.set(fresh, ClientState.anonymousId)
    state.set(false, ClientState.identified)
    state.set(nil, ClientState.superProperties)
    state.set(nil, ClientState.groups)
    // A new person: the recording so far ends, and the next one starts fresh.
    if let replay = replayRecorder {
      replay.personChanged()
      Task { await replay.flush() }
    }
  }

  /// What the person agreed to for ads, or nil: `ApphelmOptions.adsConsent` until changed.
  public var adsConsent: AdsConsent? {
    lock.withLock { _adsConsent }
  }

  /// Change the ads consent, after your consent prompt or when the person changes their mind.
  /// Events tracked from now on carry it as `$ad_consent`; with nil they carry nothing
  /// ad-related. Events already queued keep the consent they were tracked under.
  public func setAdsConsent(_ consent: AdsConsent?) {
    lock.withLock { _adsConsent = consent }
  }

  /// `properties` with `$ad_consent` while ads consent is set.
  private func withAdConsent(_ properties: [String: Any]) -> [String: Any] {
    guard let consent = adsConsent else { return properties }
    var merged = properties
    merged["$ad_consent"] = consent.rawValue
    return merged
  }

  /// Queue `$install`, once per install: call it on every launch, early. It is sent with the
  /// next `flush()`. It carries the platform and `appVersion` (by default the bundle's
  /// `CFBundleShortVersionString`), and is useful analytics on its own.
  ///
  /// With ads consent it also carries `$ad`: the platform and the Apple Ads attribution token
  /// (AdServices), which Yieldline exchanges with Apple to attribute the install to a Search
  /// Ads campaign. The token needs no App Tracking Transparency prompt, and no advertising
  /// identifier is read. When the system gives no token, `$ad` is sent without one.
  ///
  /// The install is remembered in `installStore`; when that cannot be saved it is still
  /// queued at most once per client. Returns whether it was queued by this call.
  @discardableResult
  public func recordInstall(appVersion: String? = nil) async -> Bool {
    guard !isOptedOut else { return false }
    let claimed: Bool = lock.withLock {
      if installClaimed { return false }
      installClaimed = true
      return true
    }
    guard claimed, !installStore.isInstallRecorded() else { return false }
    var properties: [String: Any] = ["platform": adPlatform]
    let version = (appVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !version.isEmpty { properties["app_version"] = String(version.prefix(120)) }
    if adsConsent != nil {
      var evidence: [String: String] = ["platform": adPlatform]
      let token = ((try? await attributionToken()) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !token.isEmpty, token.count <= maxAppleAdsTokenLength { evidence["apple_ads_token"] = token }
      // Consent may have been withdrawn while the token was fetched.
      if adsConsent != nil { properties["$ad"] = evidence }
    }
    enqueue("$install", properties: properties)
    installStore.markInstallRecorded()
    return true
  }

  /// Screen view: `$screen` with the name as `$screen_name`.
  public func screen(_ name: String, properties: [String: Any] = [:]) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var merged = properties
    merged["$screen_name"] = String(trimmed.prefix(300))
    if options.enableAutoBreadcrumbs { addBreadcrumb(category: "navigation", message: trimmed) }
    track("$screen", properties: merged)
    replayRecorder?.screenChanged(trimmed)
  }

  /// Declare that the person agreed to session replay (`ApphelmOptions.replay` must be set).
  /// With true, screens are recorded as wireframes; with false, recording stops at once and
  /// anything not yet sent is discarded. Apphelm does not ask: call it from your consent prompt.
  public func setReplayConsent(_ granted: Bool) {
    guard let recorder = replayRecorder else { return }
    recorder.setConsent(granted)
    // Withdrawn: a crashed run's replay waiting on disk is not sent either.
    if !granted { ReplayCrashStore.removeAll(directory: crashFolder) }
    #if canImport(UIKit) && !os(watchOS)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        if granted && recorder.isConfigured { ReplayUIKitCapture.start(recorder) } else { ReplayUIKitCapture.stop(recorder) }
      }
    }
    #endif
  }

  /// True while screens are being recorded: replay configured, consent given, not opted out.
  public var isReplayActive: Bool { replayRecorder?.isActive ?? false }

  /// The current replay recording's id (`rpl_…`), or nil when none is running (and while a
  /// replay-on-error buffer waits for an error).
  public var replaySessionId: String? { replayRecorder?.sessionId }

  /// Send the replay chunks waiting now (they are also sent every few seconds on their own).
  public func flushReplay() async {
    await replayRecorder?.flush()
  }

  /// For tests: the recorder.
  var replayRecorderForTests: ReplayRecorder? { replayRecorder }

  /// Send queued events now. Events that fail to send stay queued, in order, for the next
  /// flush; flushes run one at a time, so none is sent twice. The client also flushes on
  /// its own (`flushIntervalSeconds`, `flushAt`, `flushOnBackground`).
  public func flush() async {
    let task: Task<Void, Never> = lock.withLock {
      let previous = flushTail
      let task = Task {
        await previous?.value
        await self.drain()
      }
      flushTail = task
      return task
    }
    await task.value
  }

  /// One request per event, so a failure part-way through puts back only the events not
  /// yet accepted. Re-queuing the whole batch sent every earlier event a second time.
  private func drain() async {
    let batch = queue.takePending()
    guard !batch.isEmpty else { return }
    for (index, entry) in batch.enumerated() {
      if isOptedOut || !isActive {
        queue.release(batch.dropFirst(index).map(\.id))
        return
      }
      do {
        try await sendQueued(entry.event)
        queue.complete(entry.id)
      } catch let error as ApphelmError where [400, 413, 422].contains(error.status) {
        // Refused for good: resending can't succeed, and it would hold up the queue forever.
        debugLog("event \(entry.event["eventName"] as? String ?? "?") refused (\(error.status) \(error.code)); dropped")
        queue.complete(entry.id)
      } catch {
        debugLog("sending queued events failed (\(error)); \(batch.count - index) kept for the next flush")
        queue.release(batch.dropFirst(index).map(\.id))
        lock.withLock { thresholdSuspended = true }
        return
      }
    }
    lock.withLock { thresholdSuspended = false }
  }

  private func sendQueued(_ event: [String: Any]) async throws {
    var properties = (event["properties"] as? [String: Any]) ?? [:]
    if properties["distinct_id"] == nil { properties["distinct_id"] = distinctId }
    let envelope: AcceptedEnvelope = try await send(path: "/events", body: [
      "workspaceId": options.workspaceId,
      "productId": options.productId,
      "eventName": event["eventName"] as? String ?? "unknown_event",
      "privacyMode": "strict",
      "properties": properties,
      "eventId": event["eventId"] as? String ?? UUID().uuidString,
      "occurredAt": event["occurredAt"] as? String ?? ISO8601DateFormatter().string(from: Date()),
    ])
    _ = envelope
  }

  /// Identify a person. Every trait needs explicit provenance: the API rejects a trait
  /// without a matching `traitSources` entry, so this throws rather than posting a request
  /// that cannot succeed. A source entry is
  /// `["sourceType": "auth", "sourceId": "session", "verification": "integration_verified"]`.
  public func identify(externalUserId: String, traits: [String: Any] = [:], traitSources: [String: [String: Any]] = [:]) async throws {
    let missing = traits.keys.filter { traitSources[$0] == nil }.sorted()
    if !missing.isEmpty {
      throw ApphelmError(message: "Every trait requires provenance in traitSources. Missing: \(missing.joined(separator: ", "))", status: 0, code: "trait_provenance_required")
    }
    let unmatched = traitSources.keys.filter { traits[$0] == nil }.sorted()
    if !unmatched.isEmpty {
      throw ApphelmError(message: "traitSources has no matching trait value for: \(unmatched.joined(separator: ", "))", status: 0, code: "trait_provenance_orphaned")
    }
    guard !isOptedOut else { return }
    let envelope: AcceptedEnvelope = try await send(path: "/events", body: [
      "workspaceId": options.workspaceId,
      "productId": options.productId,
      "eventName": "apphelm.identify",
      "privacyMode": "strict",
      "properties": ["externalUserId": externalUserId, "traits": traits, "traitSources": traitSources, "consent": [Any](), "isAccountAdmin": false, "isChampion": false],
    ])
    _ = envelope
  }

  public func listFlagConfigs() async throws -> [FlagConfig] {
    let envelope: ConfigsEnvelope = try await send(path: "/flags?productId=\(options.productId)", body: nil)
    return envelope.data
  }

  private func evaluationRows(flagKey: String?, environment: String?) async throws -> [EvaluationDTO] {
    var body: [String: Any] = ["productId": options.productId, "distinctId": distinctId]
    if let flagKey { body["flagKey"] = flagKey }
    if let environment { body["environment"] = environment }
    let envelope: EvaluationsEnvelope = try await send(path: "/flags/evaluate", body: body)
    return envelope.data
  }

  public func evaluateFlags(flagKey: String? = nil, environment: String? = nil) async throws -> [FlagEvaluation] {
    try await evaluationRows(flagKey: flagKey, environment: environment).map(\.evaluation)
  }

  /// The flag's answer, as PostHog's `getFeatureFlag`: `.enabled` (PostHog's `true`) for an
  /// enabled boolean or remote config flag, `.variant(key)` for a multivariate one, else
  /// `.disabled`. Fail-closed: any transport or API failure is `.disabled`. Never throws.
  /// For a flag a running experiment depends on, it also queues the exposure, with the
  /// variant the server served (`"on"` for a boolean flag).
  public func getFeatureFlag(_ flagKey: String, environment: String? = nil) async -> FlagValue {
    do {
      guard let row = try await evaluationRows(flagKey: flagKey, environment: environment).first(where: { $0.key == flagKey }) else { return .disabled }
      if row.experiment == true { recordExposure(flagKey: row.key, variant: row.variant ?? (row.enabled ? "on" : "off")) }
      return row.evaluation.value
    } catch {
      return .disabled
    }
  }

  /// Fail-closed: any transport or API failure returns `false`. Never throws.
  /// For a flag a running experiment depends on, it also queues the exposure the
  /// experiment's results divide by (see `recordExposure`).
  public func isEnabled(_ flagKey: String, environment: String? = nil) async -> Bool {
    do {
      guard let row = try await evaluationRows(flagKey: flagKey, environment: environment).first(where: { $0.key == flagKey }) else { return false }
      if row.experiment == true { recordExposure(flagKey: row.key, variant: row.variant ?? (row.enabled ? "on" : "off")) }
      return row.enabled
    } catch {
      return false
    }
  }

  /// Queue an `apphelm.flag_evaluated` exposure: this person was served this variant.
  /// Experiment results count only exposed people, so without it a mobile user is never in
  /// an experiment. `isEnabled` calls it for experiment flags; call it yourself after
  /// local evaluation. Sent with the next `flush`, once per flag and variant per client.
  public func recordExposure(flagKey: String, variant: String) {
    let fresh = lock.withLock { exposed.insert("\(flagKey)\u{0}\(variant)").inserted }
    if fresh { track("apphelm.flag_evaluated", properties: ["flag_key": flagKey, "variant": variant]) }
  }

  /// The id of the release-health session in progress, or nil when there is none.
  public var sessionId: String? {
    lock.withLock { health?.hash }
  }

  /// Start a release-health session: queues one `$session` event, the signal the browser SDK
  /// sends per page load, carrying the release, environment and a fresh session id, so the
  /// release's sessions and crash-free rate count this launch. With
  /// `enableAutoSessionTracking` (the default) the client calls it itself; otherwise call it
  /// when the app becomes active. It is sent with the next `flush()`. Every error reported while it runs carries
  /// the session id, and an unhandled one marks the session crashed on the server. The
  /// session is also noted in `directory` (the crash report folder by default), so a crash
  /// sent on the next launch names the session, release and environment it happened in.
  ///
  /// Returns the session id, or nil without a `release`: the server counts sessions per
  /// release, so nothing is queued. Calling it while a session is running returns that
  /// session and queues nothing.
  @discardableResult
  public func startSession(directory: URL? = nil) -> String? {
    startSession(directory: directory, clock: TraceClock())
  }

  func startSession(directory: URL?, clock: TraceClock) -> String? {
    guard options.enabled, let release = options.release, !release.isEmpty else { return nil }
    let folder = directory ?? lock.withLock { crashDirectory } ?? Self.defaultCrashDirectory()
    let hash = UUID().uuidString.lowercased()
    let running: String? = lock.withLock {
      if let health { return health.hash }
      health = (hash, clock, folder)
      return nil
    }
    if let running { return running }
    SessionLedger.record(StoredSession(hash: hash, release: release, environment: options.environment, startedAt: clock.date().timeIntervalSince1970, endedAt: nil), directory: folder)
    var properties: [String: Any] = ["session_hash": hash, "release": release]
    if let environment = options.environment { properties["environment"] = environment }
    enqueue("$session", properties: properties)
    persistScope()
    return hash
  }

  /// End the session, locally: nothing is sent. Later errors carry no session id, and the
  /// next `startSession` starts a new session. Call it when the app goes to the background.
  /// Returns `false` when no session is running.
  ///
  /// There is no closing event because the server has nothing to do with one: it already
  /// has every error reported during the session, and a crash report sent on the next
  /// launch marks the session crashed. Session length is not tracked. The end is noted next
  /// to the crash reports, so a crash after it is not counted against this session.
  @discardableResult
  public func endSession() -> Bool {
    let ending = lock.withLock { () -> (hash: String, clock: TraceClock, directory: URL)? in
      defer { health = nil }
      sessionTimeout.ended()
      return health
    }
    guard let ending else { return false }
    SessionLedger.end(hash: ending.hash, at: ending.clock.date(), directory: ending.directory)
    persistScope()
    return true
  }

  // MARK: Scope: tags, user, breadcrumbs

  /// A tag sent with every later exception, message and crash (a string, number or boolean;
  /// nil removes it), like Sentry's `setTag`. At most 20 are kept; keys are letters, digits,
  /// `_`, `.` and `-`, up to 40 (others are ignored). A tag passed to `captureException`
  /// or set in `withScope` wins over it.
  public func setTag(_ key: String, _ value: Any?) {
    guard let name = tagKey(key) else { return }
    lock.withLock {
      if let scalar = tagValue(value) {
        if tags.count < 20 || tags[name] != nil { tags[name] = scalar }
      } else {
        tags.removeValue(forKey: name)
      }
    }
    persistScope()
  }

  /// `setTag` for each entry (Sentry's `setTags`).
  public func setTags(_ values: [String: Any?]) {
    for (key, value) in values.sorted(by: { $0.key < $1.key }) { setTag(key, value) }
  }

  /// A named group of values sent with every later exception, message and crash (Sentry's
  /// `setContext`), as tags named `context.<name>.<key>`: tags are what an issue keeps of an
  /// event. Names and keys are letters, digits, `_` and `-` (name up to 20, key up to 30).
  /// Only strings, finite numbers and booleans are kept (nested dictionaries and arrays are
  /// skipped); strings are scrubbed like breadcrumbs and cut to 200 characters, and keys that
  /// look like secrets or contact details (`password`, `token`, `email`…) are dropped. At most
  /// 10 contexts of 10 values; an event carries at most 10 context tags, in the room its other
  /// tags leave of 20, and only those whose whole name fits in 40 characters. nil removes it.
  /// Inside `withScope`, use `scope.setContext`.
  public func setContext(_ name: String, _ context: [String: Any]?) {
    lock.withLock { applyContext(&contexts, name, context) }
    persistScope()
  }

  /// Change the scope events are captured with now (Sentry's `configureScope`): inside
  /// `withScope` that scope, otherwise the client's own (tags, contexts, user, breadcrumbs
  /// and the transaction automatic spans join).
  public func configureScope(_ body: (ApphelmScope) -> Void) {
    if let current = ScopeContext.current {
      body(current)
      return
    }
    let scratch = ApphelmScope(parent: nil, maxBreadcrumbs: options.maxBreadcrumbs, accept: { [weak self] crumb in self?.acceptBreadcrumb(crumb) })
    body(scratch)
    let own = scratch.own
    for (key, value) in own.tags { setTag(key, value) }
    if !own.contexts.isEmpty { lock.withLock { for (name, values) in own.contexts { contexts[name] = values } } }
    if case .some(let hash) = own.user { lock.withLock { userHash = hash } }
    if let transaction = own.transaction { lock.withLock { active = transaction } }
    for crumb in scratch.breadcrumbs.all { breadcrumbs.add(crumb) }
    persistScope()
  }

  /// The id of the last exception, message or event this client captured (Sentry's
  /// `lastEventId`), or nil before the first. Set once the error passed `enabled`,
  /// `ignoreErrors` and `sampleRate`, even when the send then fails. Pass it to
  /// `captureFeedback(_:associatedEventId:)`.
  public var lastEventId: String? { lock.withLock { _lastEventId } }

  /// Structured logs to AppHelm (`/api/v1/logs`, batched OpenTelemetry records): the same
  /// call shape as `os.Logger`, plus attributes, for example
  /// `apphelm.logger.error("Payment failed", attributes: ["order": id, "error": error])`.
  /// Lines carry the running transaction's trace id. The key needs `logs:write` (or
  /// `events:write`).
  public var logger: ApphelmLogger {
    lock.withLock {
      if let existing = _logger { return existing }
      let made = ApphelmLogger(sink: LogSink(client: self), attributes: [:])
      _logger = made
      return made
    }
  }

  /// Send everything queued (events, log lines and replay chunks) and wait at most `timeout`
  /// seconds. True when everything was sent (or failed for good) in time, false on timeout;
  /// the sends carry on either way. Never throws.
  @discardableResult
  public func flush(timeout: TimeInterval) async -> Bool {
    await waitAtMost(timeout) { [self] in
      await self.flush()
      await self.lock.withLock({ self._logger })?.drainAll()
      await self.replayRecorder?.flush()
    }
  }

  /// `flush(timeout:)`, then stop: later events, exceptions, messages, transactions, logs,
  /// feedback and check-ins are dropped without a request (captures return false or nil) and
  /// the flush timer stops. Flag reads still work. Calling it again is harmless. Returns what
  /// the flush returned.
  @discardableResult
  public func close(timeout: TimeInterval = 2) async -> Bool {
    let flushed = await flush(timeout: timeout)
    let logger: ApphelmLogger? = lock.withLock {
      closed = true
      flushTimer?.cancel()
      flushTimer = nil
      return _logger
    }
    logger?.shutdown()
    // A run that closed Apphelm is not one the watchdog killed.
    AppStateStore.shared.update { $0.isSDKRunning = false }
    return flushed
  }

  /// The signed-in user, so each issue counts the people it affects. Only a hash is sent
  /// (`user_hash`): SHA-256 of `apphelm-user:<id>`, the first 32 hex characters, the hash
  /// the Node, Python and Kotlin clients send. nil (at log-out) clears it. The device's
  /// `distinctId` is sent with every exception either way.
  public func setUser(id: String?) {
    let hash = id.flatMap { $0.isEmpty ? nil : hashUserId($0) }
    lock.withLock { userHash = hash }
    persistScope()
  }

  /// Record a breadcrumb: the last 30 travel with each later exception, message and crash
  /// report. Inside `withScope` it belongs to that scope only. `beforeBreadcrumb` may change
  /// or drop it.
  public func addBreadcrumb(_ crumb: Breadcrumb) {
    if let scope = ScopeContext.current {
      scope.addBreadcrumb(crumb)
      return
    }
    guard let kept = acceptBreadcrumb(crumb) else { return }
    breadcrumbs.add(kept)
    persistScope()
  }

  /// `addBreadcrumb(Breadcrumb(category:message:level:data:))`.
  public func addBreadcrumb(category: String, message: String, level: BreadcrumbLevel = .info, data: [String: String] = [:]) {
    addBreadcrumb(Breadcrumb(category: category, message: message, level: level, data: data))
  }

  /// Forget the client's breadcrumbs (not a scope's).
  public func clearBreadcrumbs() {
    breadcrumbs.clear()
    persistScope()
  }

  /// A breadcrumb after `beforeBreadcrumb`, its category and message made safe to send.
  func acceptBreadcrumb(_ crumb: Breadcrumb) -> Breadcrumb? {
    guard options.maxBreadcrumbs > 0 else { return nil }
    let hooked: Breadcrumb? = options.beforeBreadcrumb.map { $0(crumb) } ?? crumb
    guard var kept = hooked else { return nil }
    kept.category = breadcrumbCategory(kept.category)
    kept.message = breadcrumbMessage(kept.message)
    return kept
  }

  /// Run `body` with a scope of its own: tags, a user, breadcrumbs and a transaction for the
  /// events captured inside it (and in the child tasks it starts), on top of the client's.
  /// Nested scopes stack, the innermost winning. For example:
  /// `try await apphelm.withScope { scope in scope.setTag("order", id); try await checkout() }`.
  public func withScope<T>(_ body: (ApphelmScope) throws -> T) rethrows -> T {
    let scope = makeScope()
    return try ScopeContext.$current.withValue(scope) { try body(scope) }
  }

  /// The same for asynchronous work.
  public func withScope<T>(_ body: (ApphelmScope) async throws -> T) async rethrows -> T {
    let scope = makeScope()
    return try await ScopeContext.$current.withValue(scope) { try await body(scope) }
  }

  private func makeScope() -> ApphelmScope {
    ApphelmScope(parent: ScopeContext.current, maxBreadcrumbs: options.maxBreadcrumbs, accept: { [weak self] crumb in self?.acceptBreadcrumb(crumb) })
  }

  /// The breadcrumbs an event captured now carries: the client's and the current scope's.
  var currentBreadcrumbs: [Breadcrumb] {
    breadcrumbs.all + (ScopeContext.current?.allBreadcrumbs ?? [])
  }

  /// Keep the crash scope on disk up to date, once crash reporting is installed here.
  func persistScope() {
    let snapshot: [String: Any]? = lock.withLock {
      guard crashDirectory != nil else { return nil }
      var value: [String: Any] = [:]
      if let release = options.release { value["release"] = release }
      if let environment = options.environment { value["environment"] = environment }
      if let health { value["session_hash"] = health.hash }
      var crashTags = tags
      addContextTags(&crashTags, contexts)
      if !crashTags.isEmpty { value["tags"] = crashTags }
      if let userHash { value["user_hash"] = userHash }
      return value
    }
    guard var snapshot else { return }
    let crumbs = breadcrumbWire(breadcrumbs.all)
    if !crumbs.isEmpty { snapshot["breadcrumbs"] = crumbs }
    crashScope.update(snapshot)
  }

  /// Tags, user hash, breadcrumbs and trace id for an exception or message captured now.
  /// Tags are merged most specific first: the call's, then the scope's, then `setTag`'s.
  func addContext(_ properties: inout [String: Any], callTags: [String: Any], traceId: String?, eventContexts: [String: [String: Any]] = [:]) {
    let scope = ScopeContext.current
    var merged: [String: Any] = [:]
    func add(_ key: String, _ value: Any) {
      guard merged.count < 20, let name = tagKey(String(key.prefix(40))), merged[name] == nil, let scalar = tagValue(value) else { return }
      merged[name] = scalar
    }
    for (key, value) in callTags.sorted(by: { $0.key < $1.key }) { add(key, value) }
    for (key, value) in (scope?.allTags ?? [:]).sorted(by: { $0.key < $1.key }) { add(key, value) }
    let (globalTags, globalUser, globalContexts) = lock.withLock { (tags, userHash, contexts) }
    for (key, value) in globalTags.sorted(by: { $0.key < $1.key }) { add(key, value) }
    // setContext groups as `context.<name>.<key>` tags in the room left: the event's own
    // (captureEvent), then the scope's, then the client's.
    var allContexts = globalContexts
    allContexts.merge(scope?.allContexts ?? [:]) { _, own in own }
    allContexts.merge(eventContexts) { _, own in own }
    addContextTags(&merged, allContexts)
    if !merged.isEmpty { properties["tags"] = merged }
    let user: String?
    if let scoped = scope?.userHash { user = scoped } else { user = globalUser }
    if let user { properties["user_hash"] = user }
    let crumbs = breadcrumbWire(currentBreadcrumbs)
    if !crumbs.isEmpty { properties["breadcrumbs"] = crumbs }
    // The trace it happened in: the given id, else the transaction running now.
    if let traceId, isTraceId(traceId) {
      properties["trace_id"] = traceId
    } else if let running = activeTransaction {
      properties["trace_id"] = running.traceId
    }
  }

  /// Report an error. Swift errors carry no stack of their own, so the stack where
  /// `captureException` was called is sent (Apphelm's own frames dropped). Apphelm groups by
  /// type, message and top app frame, or by `fingerprint` when given: every error with the
  /// same fingerprint joins one issue. `tags` are up to 20 scalar values; the server
  /// scrubs them again. `traceId` (`transaction.traceId`) links the issue to the trace it
  /// happened in; anything but a 32-character lower-case hex id is left out.
  ///
  /// It also carries the tags from `setTag` and `withScope`, the user's hash (`setUser`), the
  /// last 30 breadcrumbs and, when `traceId` is not given, the trace of the transaction
  /// running now. Returns false when `beforeSend` dropped it or the client is opted out.
  @discardableResult
  public func captureException(_ error: Error, fingerprint: [String]? = nil, tags: [String: String] = [:], handled: Bool = true, traceId: String? = nil) async throws -> Bool {
    let rawMessage = String(describing: error), typeName = String(describing: type(of: error))
    let frames = Array(Thread.callStackSymbols.drop { $0.contains("$s7Apphelm") })
    // denyUrls / allowUrls match the binary of the top frame: the code that called this.
    guard let eventId = admitError(type: typeName, message: rawMessage, frame: frames.first.flatMap(stackFrameImage)) else { return false }
    var properties: [String: Any] = ["message": scrubbed(rawMessage, limit: 240), "name": typeName.prefix(80).description, "$event_id": eventId]
    if let fingerprint, !fingerprint.isEmpty {
      properties["fingerprint"] = fingerprint.prefix(10).map { String($0.prefix(200)) }
    }
    if !frames.isEmpty {
      properties["stack"] = CrashInstaller.boundedStack(Array(frames.prefix(20)))
      // Which binaries those frames are in and where they are loaded, so the server can
      // symbolicate a stripped build from an uploaded symbol table.
      let images = DebugImages.referenced(by: Array(frames.prefix(20)), among: DebugImages.loaded())
      if !images.isEmpty { properties["debug_images"] = images }
    }
    if !handled { properties["handled"] = false }
    addContext(&properties, callTags: tags, traceId: traceId)
    return try await sendException(properties, eventId: eventId)
  }

  /// Report a message rather than an error: something noteworthy with no error object, such
  /// as a fallback taken or a limit reached (Sentry's `captureMessage`). It becomes an issue
  /// grouped by its text (numbers and ids normalised) or by `fingerprint`, with `level`. No
  /// stack. It carries the same release, environment, session, tags, user hash, breadcrumbs
  /// and trace as an exception. Returns false when `beforeSend` dropped it or the client is
  /// opted out; throws `ApphelmError` when the server refuses it.
  @discardableResult
  public func captureMessage(_ message: String, level: MessageLevel = .info, fingerprint: [String]? = nil, tags: [String: String] = [:]) async throws -> Bool {
    guard let eventId = admitError(type: "", message: message) else { return false }
    var properties: [String: Any] = ["message": scrubbed(message, limit: 240), "name": "Message", "level": level.rawValue, "$event_id": eventId]
    if let fingerprint, !fingerprint.isEmpty {
      properties["fingerprint"] = fingerprint.prefix(10).map { String($0.prefix(200)) }
    }
    addContext(&properties, callTags: tags, traceId: nil)
    return try await sendException(properties, eventId: eventId)
  }

  /// A survey request: the browser survey routes, with the project key and its origin.
  /// Returns the response's `data`, or nil when there is none.
  private func surveyPost(_ path: String, _ fields: [String: Any]) async throws -> OrderedJSONObject? {
    try await surveyRequest(path, fields) as? OrderedJSONObject
  }

  /// A survey request's `data`, whatever its shape.
  func surveyRequest(_ path: String, _ fields: [String: Any]) async throws -> Any? {
    let key = options.surveyKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let origin = options.surveyOrigin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty, !origin.isEmpty, let url = URL(string: options.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
      throw ApphelmError(message: "Surveys need surveyKey and surveyOrigin.", status: 0, code: "survey_not_configured")
    }
    // The survey routes take the public project key. A server key must never be sent to them.
    guard key.hasPrefix("ahl_pub_") else {
      throw ApphelmError(message: "surveyKey must be the product's project key (ahl_pub_…), not a server key.", status: 0, code: "survey_key_not_public")
    }
    var request = URLRequest(url: url, timeoutInterval: options.timeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(key, forHTTPHeaderField: "x-apphelm-key")
    request.setValue(origin, forHTTPHeaderField: "origin")
    var body = fields
    body["workspaceId"] = options.workspaceId
    body["productId"] = options.productId
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ApphelmError(message: "Non-HTTP response.", status: 0, code: "request_failed") }
    // Read with its keys in order: a survey branch's rules are taken in the order they were sent.
    let payload = parseJSONKeepingOrder(data) as? OrderedJSONObject ?? OrderedJSONObject(pairs: [])
    guard (200...299).contains(http.statusCode) else {
      let details = payload["error"] as? OrderedJSONObject
      throw ApphelmError(message: details?["message"] as? String ?? "Apphelm survey request failed (\(http.statusCode)).", status: http.statusCode, code: details?["code"] as? String ?? "request_failed")
    }
    return payload["data"]
  }

  /// Ask whether there is a survey for this person now, the request the browser SDK's
  /// `surveys.eligible` makes. `triggerType` is the moment (`after_first_value`,
  /// `after_outcome`, `after_friction`, `after_incident`, `after_inactivity_return`,
  /// `after_feature_adoption`, `before_cancellation` or `manual`), `triggerSourceId` your id
  /// for this occurrence of it (an order, a session), and `triggerKey` the key a program's
  /// trigger may name. `screen` is matched against programs targeted at a page path.
  ///
  /// With `externalUserId` the person is your identified customer. Without it they are
  /// anonymous: the request carries two hashes of `distinctId`, never the id, and only
  /// programs opened to anonymous people are offered. Ask an anonymous person only if they
  /// have agreed to analytics; the client keeps no consent state.
  ///
  /// Returns the offer to draw, or nil when there is nothing to ask. The app draws it;
  /// nothing is shown by the client. Throws `ApphelmError` when the request fails, and
  /// with the code `survey_not_configured` without `surveyKey` and `surveyOrigin`, and
  /// `survey_key_not_public` for a key that is not a project key.
  ///
  /// `programId` asks for one automatically shown program (its trigger is not matched), and
  /// `device` (`mobile`, `tablet`) is the device class its display rules target; automatic
  /// surveys (`enableAutomaticSurveys`) send both.
  public func surveyEligible(triggerType: String, triggerSourceId: String, triggerKey: String? = nil, screen: String? = nil, externalUserId: String? = nil, programId: String? = nil, device: String? = nil) async throws -> SurveyOffer? {
    var body: [String: Any] = ["triggerType": triggerType, "triggerSourceId": triggerSourceId]
    if let triggerKey { body["triggerKey"] = triggerKey }
    if let programId { body["programId"] = programId }
    if let device { body["device"] = device }
    let customer = externalUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !customer.isEmpty {
      body["externalUserId"] = customer
    } else {
      let hashes = personHashes(distinctId)
      body["distinctHash"] = hashes.first
      body["distinctHash2"] = hashes.second
    }
    if let screen, !screen.isEmpty { body["path"] = String(screen.prefix(500)) }
    return try await surveyPost("/api/surveys/eligible", body).flatMap(surveyOffer)
  }

  /// Send the person's answers, once, when the survey is over: the request the browser
  /// SDK's `surveys.respond` makes. Returns whether the server stored it (`false` when
  /// collection is paused or the request was filtered). Throws `ApphelmError` when it is
  /// refused: `survey_exposure_expired`, `survey_exposure_not_found`,
  /// `survey_consent_unavailable`, or `invalid_survey_response` for an answer the survey
  /// does not ask (including a question off the person's `SurveyOffer.route`).
  @discardableResult
  public func surveyRespond(exposureId: String, answer: SurveyAnswer) async throws -> Bool {
    var body: [String: Any] = ["exposureId": exposureId, "action": "respond", "permission": answer.permission.rawValue]
    if let category = answer.category { body["category"] = category }
    if let score = answer.numericScore { body["numericScore"] = score }
    if let text = answer.openText { body["openText"] = String(text.prefix(2_000)) }
    if let text = answer.followUpAnswer { body["followUpAnswer"] = String(text.prefix(2_000)) }
    if !answer.answers.isEmpty {
      body["answers"] = answer.answers.mapValues { value -> Any in
        if case .text(let text) = value { return String(text.prefix(1_000)) }
        return value.json
      }
    }
    return try await surveyPost("/api/surveys/respond", body)?["status"] as? String == "responded"
  }

  /// Record that the person closed the survey without answering. Returns whether the server recorded it.
  @discardableResult
  public func surveyDismiss(exposureId: String) async throws -> Bool {
    try await surveyPost("/api/surveys/respond", ["exposureId": exposureId, "action": "dismiss", "permission": "private_analysis"])?["status"] as? String == "dismissed"
  }

  /// Start a transaction: a screen load, a sync, a request. Pass an incoming `traceparent`
  /// (or, failing that, a Sentry `sentry-trace` header value) to continue a trace started
  /// elsewhere; its trace id, parent span and sampling decision are kept. Otherwise it is
  /// kept with the probability `tracesSampler` returns, else `tracesSampleRate`, else (no rate
  /// set) always. Send it with
  /// `finish()`. `op` is free text such as `ui.load`, `task` or `http.client` (the server
  /// keeps letters, digits, `_`, `.` and `-`).
  public func startTransaction(_ name: String, op: String = "task", traceparent: String? = nil) -> Transaction {
    startTransaction(name, op: op, traceparent: traceparent, clock: TraceClock())
  }

  /// `automatic`: started by an integration (a screen load, an app start), which is unsampled
  /// while no rate or sampler is set, unless an incoming trace was sampled.
  func startTransaction(_ name: String, op: String, traceparent: String?, clock: TraceClock, automatic: Bool = false) -> Transaction {
    let transaction = makeTransaction(name, op: op, traceparent: traceparent, clock: clock, frames: frames, automatic: automatic)
    lock.withLock { active = transaction }
    return transaction
  }

  /// Whether a trace sample rate or sampler is set: automatic tracing is off until one is.
  var tracingConfigured: Bool { options.tracesSampleRate != nil || options.tracesSampler != nil }

  private func makeTransaction(_ name: String, op: String, traceparent: String?, clock: TraceClock, frames: FrameStats, automatic: Bool) -> Transaction {
    let w3c = parseTraceparent(traceparent)
    let sentry = w3c == nil ? parseSentryTrace(traceparent) : nil
    let parentSampled: Bool? = w3c?.sampled ?? sentry?.sampled
    let sampled: Bool
    if let parentSampled {
      sampled = parentSampled
    } else {
      let asked = options.tracesSampler?(SamplingContext(name: name, op: op, parentSampled: nil))
      // No rate set: automatic transactions are unsampled (they still carry a trace id for
      // errors and propagation); your own are kept, as before 0.8.0.
      let rate = asked.map { $0.isNaN ? 0 : min(1, max(0, $0)) } ?? options.tracesSampleRate ?? (automatic ? 0 : 1)
      sampled = rate > 0 && Double.random(in: 0..<1) < rate
    }
    // ignoreTransactions: kept as a trace (ids, propagation) but never sent or profiled.
    let ignored = options.ignoreTransactions.contains { $0.matches(name) }
    let transaction = Transaction(send: { [weak self] properties in
      guard let self else { return false }
      if ignored {
        self.debugLog("transaction dropped (ignoreTransactions)")
        return false
      }
      return try await self.sendTransaction(properties)
    }, name: name, op: op, traceId: w3c?.traceId ?? sentry?.traceId ?? randomHex(16), parentSpanId: w3c?.parentSpanId ?? sentry?.parentSpanId, sampled: sampled, release: options.release, environment: options.environment, clock: clock, frames: frames)
    // Profiled only when sampled, by its own rate (off by default), one at a time.
    let profileRate = options.profilesSampleRate.map { $0.isNaN ? 0 : min(1, max(0, $0)) } ?? 0
    if sampled, !ignored, isActive, profileRate > 0, Double.random(in: 0..<1) < profileRate, let profiler = ProfileRecorder.start(thread: profiledThread) {
      transaction.profiler = profiler
      transaction.sendProfile = { [weak self] profile in await self?.sendProfile(profile) }
    }
    return transaction
  }

  /// The transaction automatic spans and captured exceptions join: the current
  /// `withScope` scope's `transaction` when it has one, else the one started most recently,
  /// until it finishes. Nil when that one has finished, even if an earlier one is still
  /// running, so it suits an app with one screen load or sync at a time.
  public var activeTransaction: Transaction? {
    if let scoped = ScopeContext.current?.transaction, !scoped.isFinished { return scoped }
    return lock.withLock { active }.flatMap { $0.isFinished ? nil : $0 }
  }

  /// Record a screen: queues its screen view, as `screen` does, and starts a `ui.load`
  /// transaction named after it, which becomes the `activeTransaction`, so the HTTP calls
  /// the screen makes are its spans. `finish()` it when the screen has its content. Use it
  /// in place of `screen`, not with it. `reportFullyDisplayed()` before `finish()` adds
  /// `ttfd_ms`.
  public func startScreen(_ name: String, properties: [String: Any] = [:]) -> Transaction {
    screen(name, properties: properties)
    let transaction = startTransaction(name, op: "ui.load")
    trackScreenLoad(transaction, automatic: false)
    return transaction
  }

  // MARK: Screen loads (TTID / TTFD)

  private func trackScreenLoad(_ transaction: Transaction, automatic: Bool, waitForFullDisplay: Bool? = nil) {
    let previous: ScreenLoadState? = lock.withLock {
      defer { screenLoad = ScreenLoadState(transaction: transaction, automatic: automatic, waitForFullDisplay: waitForFullDisplay) }
      return screenLoad
    }
    transaction.onFinish = { [weak self] finished in
      self?.lock.withLock { if self?.screenLoad?.transaction === finished { self?.screenLoad = nil } }
    }
    // A new screen while the last automatic one still waited for full display: that one ends.
    if let previous, previous.automatic, let old = previous.transaction, !old.isFinished { Task { await old.finish() } }
  }

  /// Whether `transaction` is the current automatic screen load and its screen is already
  /// shown (it only waits for full display).
  func isShownScreenLoad(_ transaction: Transaction) -> Bool {
    lock.withLock { screenLoad.map { $0.transaction === transaction && $0.automatic && $0.initialDisplayed } ?? false }
  }

  /// A screen load the UIKit integration started at `viewDidLoad`.
  func screenLoadStarted(_ name: String, clock: TraceClock = TraceClock(), waitForFullDisplay: Bool? = nil) -> Transaction {
    let transaction = startTransaction(name, op: "ui.load", traceparent: nil, clock: clock, automatic: true)
    trackScreenLoad(transaction, automatic: true, waitForFullDisplay: waitForFullDisplay)
    return transaction
  }

  /// The first frame after an automatic screen load's `viewDidAppear`: `ttid_ms`, and the
  /// transaction finishes unless it waits for `reportFullyDisplayed()`.
  func screenLoadFirstFrame(_ transaction: Transaction, at nanos: UInt64? = nil) {
    let end = nanos ?? transaction.clock.nanos()
    transaction.markInitialDisplay(at: end)
    let state: ScreenLoadState? = lock.withLock {
      guard screenLoad?.transaction === transaction else { return nil }
      screenLoad?.initialDisplayed = true
      return screenLoad
    }
    guard let state, state.automatic else {
      // Not the current screen any more: nothing waits for it.
      if !transaction.isFinished && lock.withLock({ screenLoad?.transaction !== transaction }) { Task { await transaction.finish() } }
      return
    }
    if let fullAt = state.fullyDisplayedAt {
      // Fully displayed before its first frame: full display is the first frame.
      transaction.markFullDisplay(at: max(fullAt, end))
      Task { await transaction.finish() }
    } else if !(state.waitForFullDisplay ?? options.enableTimeToFullDisplayTracing) {
      Task { await transaction.finish() }
    } else {
      DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self, weak transaction] in
        if let transaction { self?.screenLoadDeadline(transaction) }
      }
    }
  }

  /// 30 s after the first frame without `reportFullyDisplayed()`: the screen load finishes
  /// without `ttfd_ms`, as Sentry's does.
  func screenLoadDeadline(_ transaction: Transaction) {
    guard !transaction.isFinished else { return }
    Task { await transaction.finish(.ok) }
  }

  /// Tell Apphelm the current screen has all its content (Sentry's
  /// `reportFullyDisplayed`): its `ui.load` transaction gets `ttfd_ms` and a
  /// `ui.load.full_display` span. An automatic screen load waiting for it
  /// (`enableTimeToFullDisplayTracing`) then finishes; one from `startScreen` still
  /// finishes when you call `finish()`. Returns false when no screen load is running.
  @discardableResult
  public func reportFullyDisplayed() -> Bool {
    reportFullyDisplayed(clockNanos: nil)
  }

  func reportFullyDisplayed(clockNanos: UInt64?) -> Bool {
    let state: ScreenLoadState? = lock.withLock { screenLoad }
    guard let state, let transaction = state.transaction, !transaction.isFinished else { return false }
    let now = clockNanos ?? transaction.clock.nanos()
    if state.automatic && !state.initialDisplayed {
      lock.withLock { if screenLoad?.transaction === transaction { screenLoad?.fullyDisplayedAt = now } }
      return true
    }
    transaction.markFullDisplay(at: now)
    if state.automatic { Task { await transaction.finish() } }
    return true
  }

  // MARK: App start

  /// Report this launch's app start, once per process, from process start (or, when the
  /// system prewarmed the process, from when Apphelm was loaded) to `firstFrame`, under
  /// `AppStartRules`. The launch is remembered in `directory` so the next one can tell cold
  /// from warm. Returns the transaction, or nil when nothing is reported.
  @discardableResult
  func reportAppStart(firstFrame: Date, launchedInBackground: Bool, directory: URL, processStart: Date? = processStartDate(), prewarmed: Bool = isPrewarmedProcess(), boot: Double? = bootTime(), sdkLoaded: Date = sdkLoadedAt, oncePerProcess: Bool = true) async -> Bool {
    if oncePerProcess {
      let first: Bool = Self.appStartLock.withLock {
        defer { Self.appStartReported = true }
        return !Self.appStartReported
      }
      guard first else { return false }
    }
    let current = AppStartRecord(bootTime: boot ?? 0, version: appInfo.version, build: appInfo.build)
    let previous = AppStartLedger.load(directory: directory)
    AppStartLedger.save(current, directory: directory)
    guard let processStart, let start = AppStartRules.classify(processStart: processStart, sdkLoaded: sdkLoaded, firstFrame: firstFrame, prewarmed: prewarmed, launchedInBackground: launchedInBackground, previous: previous, current: current) else { return false }
    let op = "app.start.\(start.type.rawValue)"
    let transaction = makeTransaction(start.type == .cold ? "App Start Cold" : "App Start Warm", op: op, traceparent: nil, clock: TraceClock(nanos: { 0 }, date: { start.start }), frames: FrameStats(), automatic: true)
    transaction.setMeasurement("app_start_\(start.type.rawValue)_ms", value: start.durationMs)
    let nanos = UInt64(start.durationMs) * 1_000_000
    transaction.add(span: ["span_id": randomHex(8), "parent_span_id": transaction.spanId, "op": op, "description": start.type == .cold ? "Cold Start" : "Warm Start", "start_offset_ms": 0, "duration_ms": start.durationMs, "status": SpanStatus.ok.rawValue])
    return await transaction.finish(.ok, endNanos: nanos)
  }

  // MARK: HTTP

  /// `session.data(for:)` inside an `http.client` span of `transaction` (by default the
  /// active one). The description is `METHOD scheme://host/path`: the query, fragment and
  /// any credentials in the URL are left out. The span's `data` carries
  /// `http.request.method`, `http.response.status_code`, `server.address` and `url.full`.
  /// A response from 400 up, or a thrown error (rethrown), finishes the span as an error.
  /// `traceparent` is set, naming the span, only when the host is in
  /// `tracePropagationHosts`. Each request also leaves an `http` breadcrumb
  /// (`GET https://host/path 200`), with or without a transaction.
  ///
  /// Without an unfinished transaction, for a URL that is not http(s), and for the client's
  /// own requests to Apphelm, no span is recorded. Don't also give that session
  /// `httpSpanDelegate()`, or each request is recorded twice.
  public func data(for request: URLRequest, session: URLSession = .shared, transaction: Transaction? = nil) async throws -> (Data, URLResponse) {
    guard let target = httpTarget(request.url), target.authority != httpTarget(URL(string: options.baseURL))?.authority else { return try await session.data(for: request) }
    let method = (request.httpMethod ?? "GET").uppercased()
    guard let transaction = transaction ?? activeTransaction, !transaction.isFinished else {
      do {
        let result = try await NetworkInstrumentation.$recordedByWrapper.withValue(true) { try await session.data(for: request) }
        httpBreadcrumb(method: method, target: target, statusCode: (result.1 as? HTTPURLResponse)?.statusCode)
        return result
      } catch {
        httpBreadcrumb(method: method, target: target, statusCode: nil)
        throw error
      }
    }
    let span = transaction.startSpan("http.client", description: "\(method.prefix(10)) \(target.shown)", data: httpSpanData(method: method, target: target, statusCode: nil))
    var request = request
    if propagatesTo(target.host, listed: options.tracePropagationHosts) { span.propagate(&request) }
    do {
      let result = try await NetworkInstrumentation.$recordedByWrapper.withValue(true) { try await session.data(for: request) }
      let status = (result.1 as? HTTPURLResponse)?.statusCode
      if let status { span.setData("http.response.status_code", status) }
      span.finish(status.map { (100...399).contains($0) } ?? false ? .ok : .error)
      httpBreadcrumb(method: method, target: target, statusCode: status)
      return result
    } catch {
      span.finish(.error)
      httpBreadcrumb(method: method, target: target, statusCode: nil)
      throw error
    }
  }

  /// `GET https://host/path 200` (or `failed` without a response), category `http`.
  func httpBreadcrumb(method: String, target: (host: String, authority: String, shown: String), statusCode: Int?) {
    guard options.enableAutoBreadcrumbs else { return }
    var data = ["method": String(method.prefix(10)), "url": target.shown]
    if let statusCode { data["status_code"] = String(statusCode) }
    addBreadcrumb(Breadcrumb(category: "http", message: "\(method.prefix(10)) \(target.shown) \(statusCode.map(String.init) ?? "failed")", level: (statusCode.map { $0 < 400 } ?? false) ? .info : .warning, data: data))
  }

  /// Set `traceparent` on a request you send yourself (for instance through a session with
  /// `httpSpanDelegate()`, which cannot change requests), when there is an active
  /// transaction and the request's host is in `tracePropagationHosts`. Returns whether it
  /// was set. The parent is the transaction, not the request's span.
  @discardableResult
  public func propagate(_ request: inout URLRequest) -> Bool {
    guard let transaction = activeTransaction, let target = httpTarget(request.url), propagatesTo(target.host, listed: options.tracePropagationHosts) else { return false }
    transaction.propagate(&request)
    return true
  }

  /// A delegate that records every request of a `URLSession` as an `http.client` span in
  /// the active transaction, so no call site wraps its own request:
  /// `URLSession(configuration: .default, delegate: apphelm.httpSpanDelegate(), delegateQueue: nil)`,
  /// or per request, `session.data(for: request, delegate: apphelm.httpSpanDelegate())`.
  /// If the session already has a delegate, call `recordHTTPSpan(task:metrics:)` from its
  /// `urlSession(_:task:didFinishCollecting:)` instead.
  public func httpSpanDelegate() -> HTTPSpanDelegate { HTTPSpanDelegate(client: self) }

  /// Record a finished `URLSession` task as an `http.client` span in `transaction` (by
  /// default the active one), timed by the task's metrics, with the same description and
  /// `data` as `data(for:)`, and an `http` breadcrumb. A response from 400 up, or no
  /// response, is an error.
  ///
  /// No span is recorded when there is no unfinished transaction or the request began
  /// before the transaction; nothing at all when it is not http(s), or when it is the
  /// client's own, to Apphelm. It does not set `traceparent`: a delegate cannot change a
  /// request. Use `data(for:)`, or `propagate(&request)` before sending.
  public func recordHTTPSpan(task: URLSessionTask, metrics: URLSessionTaskMetrics, transaction: Transaction? = nil) {
    let request = task.originalRequest
    // What the automatic URLSession instrumentation already records for this client is not
    // recorded twice.
    let automatic = NetworkInstrumentation.recorded(task, for: self)
    recordHTTPSpan(method: request?.httpMethod ?? "GET", url: request?.url, statusCode: (task.response as? HTTPURLResponse)?.statusCode, interval: metrics.taskInterval, transaction: transaction, breadcrumb: !automatic.breadcrumb, span: !automatic.span)
  }

  func recordHTTPSpan(method: String, url: URL?, statusCode: Int?, interval: DateInterval, transaction: Transaction? = nil, breadcrumb: Bool = true, span: Bool = true) {
    guard let target = httpTarget(url), target.authority != httpTarget(URL(string: options.baseURL))?.authority else { return }
    if breadcrumb { httpBreadcrumb(method: method.uppercased(), target: target, statusCode: statusCode) }
    guard span, let transaction = transaction ?? activeTransaction else { return }
    transaction.addHTTPSpan(method: method, target: target, statusCode: statusCode, interval: interval, ok: statusCode.map { (100...399).contains($0) } ?? false)
  }

  // MARK: Sending

  /// `beforeSend` for event `name`: the properties to send, or nil when the hook dropped the
  /// event or returned something that can't be sent as JSON.
  func keptByBeforeSend(_ name: String, _ properties: [String: Any]) -> [String: Any]? {
    guard let hook = options.beforeSend else { return properties }
    var offered = properties
    offered[Self.eventNameKey] = name
    guard var kept = hook(offered) else { return nil }
    kept.removeValue(forKey: Self.eventNameKey)
    guard JSONSerialization.isValidJSONObject(kept) else { return nil }
    return kept
  }

  /// The event's name, in the dictionary `beforeSend` is given; never sent.
  static let eventNameKey = "$event_name"

  /// Transactions carry no person and no stack, as in the other clients. False when opted
  /// out or dropped by `beforeSend`.
  /// Post one profile (Profiling.swift). A failed send is dropped: profiling never breaks the app.
  func sendProfile(_ profile: [String: Any]) async {
    guard !isOptedOut, isActive else { return }
    let _: AcceptedEnvelope? = try? await send(path: "/profiles", body: ["workspaceId": options.workspaceId, "productId": options.productId, "profile": profile])
  }

  private func sendTransaction(_ properties: [String: Any]) async throws -> Bool {
    guard !isOptedOut, isActive else { return false }
    guard let kept = keptByBeforeSend("$transaction", properties) else {
      debugLog("transaction dropped by beforeSend")
      return false
    }
    let envelope: AcceptedEnvelope = try await send(path: "/events", body: [
      "workspaceId": options.workspaceId,
      "productId": options.productId,
      "eventName": "$transaction",
      "privacyMode": "strict",
      "properties": withAdConsent(kept),
    ])
    _ = envelope
    return true
  }

  /// `origin` describes the earlier run a stored crash report belongs to: the report then
  /// carries that run's session id, release and environment, not this launch's. False when
  /// opted out or dropped by `beforeSend`.
  ///
  /// Once `beforeSend` keeps it, the event is linked to session replay (`replay_session_id`):
  /// the running recording, or a replay-on-error buffer, which an exception (not a message)
  /// uploads. A crash report links the crashed run's replay through `crashReplay`.
  func sendException(_ properties: [String: Any], origin: CrashOrigin? = nil, eventId: String? = nil, crashReplay: (() async -> String?)? = nil) async throws -> Bool {
    var merged = properties
    if let origin {
      if let hash = origin.sessionHash { merged["session_hash"] = hash }
      if let release = origin.release ?? options.release { merged["release"] = release }
      if let environment = origin.release == nil ? options.environment : origin.environment { merged["environment"] = environment }
    } else {
      // captureEvent may name its own release and environment.
      if merged["release"] == nil, let release = options.release { merged["release"] = release }
      if merged["environment"] == nil, let environment = options.environment { merged["environment"] = environment }
      // The session it happened in: an unhandled one marks that session crashed.
      if let running = sessionId { merged["session_hash"] = running }
    }
    // The person, as on every other event, so the issue counts the users it affects.
    merged["distinct_id"] = distinctId
    guard !isOptedOut, isActive else { return false }
    guard var kept = keptByBeforeSend("$exception", jsonSafe(merged) as? [String: Any] ?? merged) else {
      debugLog("error \(eventId ?? "") dropped by beforeSend")
      return false
    }
    if origin != nil {
      if let crashReplay, let replayId = await crashReplay() { kept["replay_session_id"] = replayId }
    } else if let recorder = replayRecorder, let replayId = recorder.errorCaptured(isException: (kept["name"] as? String) != "Message") {
      kept["replay_session_id"] = replayId
      Task { await recorder.flush() }
    }
    var body: [String: Any] = [
      "workspaceId": options.workspaceId,
      "productId": options.productId,
      "eventName": "$exception",
      "privacyMode": "strict",
      "properties": withAdConsent(kept),
    ]
    if let eventId { body["eventId"] = eventId }
    do {
      let envelope: AcceptedEnvelope = try await send(path: "/events", body: body)
      _ = envelope
    } catch {
      debugLog("sending error \(eventId ?? "") failed: \(error)")
      throw error
    }
    return true
  }

  /// Where crash reports wait for the next launch: `Caches/Apphelm` unless you pass one.
  public static func defaultCrashDirectory() -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Apphelm", isDirectory: true)
  }

  /// Record crashes (uncaught `NSException`s and fatal signals, including Swift traps with the
  /// runtime's `Fatal error: …` message, and stack overflows on the installing thread and on
  /// every thread started after it) to disk as they happen, with this client's scope: release,
  /// environment, session, tags, user hash and breadcrumbs. It also starts app-hang detection
  /// (`enableAppHangTracking`) and, on UIKit, watchdog-termination tracking
  /// (`enableWatchdogTerminationTracking`). Call once, early in launch, then
  /// `sendPendingCrashReports()`. Installing again in the same process does nothing. Other
  /// crash reporters installed earlier still receive the crash: Apphelm calls their handlers
  /// after writing its report. Automatic sessions and the app-start record are kept in the
  /// same directory.
  public func installCrashReporting(directory: URL? = nil) throws {
    guard options.enabled else { return }
    let folder = directory ?? Self.defaultCrashDirectory()
    try CrashInstaller.install(directory: folder)
    useCrashDirectory(folder)
    trackWatchdogTerminations(directory: folder)
    startAppHangTracking(directory: folder)
  }

  /// Keep sessions and the crash scope in `folder` from now on; a session already running
  /// is noted there too.
  func useCrashDirectory(_ folder: URL) {
    let moved: (hash: String, clock: TraceClock)? = lock.withLock {
      crashDirectory = folder
      guard let running = health, running.directory != folder else { return nil }
      health = (running.hash, running.clock, folder)
      return (running.hash, running.clock)
    }
    if let moved, let release = options.release {
      SessionLedger.record(StoredSession(hash: moved.hash, release: release, environment: options.environment, startedAt: moved.clock.date().timeIntervalSince1970, endedAt: nil), directory: folder)
    }
    persistScope()
  }

  /// The directory `installCrashReporting` was given, else the default one.
  var crashFolder: URL { lock.withLock { crashDirectory } ?? Self.defaultCrashDirectory() }

  /// Send crashes recorded by earlier runs as unhandled exceptions, then delete them. Each
  /// carries the crashed run's release, environment, session, tags, user hash and last
  /// breadcrumbs. A report that fails to send stays for the next launch; one `beforeSend`
  /// drops is deleted. Returns how many were sent.
  @discardableResult
  public func sendPendingCrashReports(directory: URL? = nil) async -> Int {
    guard options.enabled, !lock.withLock({ closed }) else { return 0 }
    let folder = directory ?? crashFolder
    var sent = 0
    for report in CrashInstaller.pendingReports(directory: folder) {
      // Opted out: the crash is not sent later either.
      if isOptedOut {
        CrashInstaller.remove(report: report)
        continue
      }
      guard var properties = CrashInstaller.exceptionProperties(report: report) else {
        CrashInstaller.remove(report: report)
        continue
      }
      let mechanism = properties.removeValue(forKey: "mechanism") as? String ?? "crash"
      // Crashes and watchdog terminations are unhandled; a hang the app came out of is not.
      let handled = properties.removeValue(forKey: "handled") as? Bool ?? false
      // ignoreErrors and sampleRate: a crash report they drop is deleted. Not denyUrls or
      // allowUrls: a crash's innermost frame is usually the system's (CoreFoundation for an
      // NSException, libsystem_kernel for abort), so a crash report passes no frame.
      if let reason = errorDropReason(type: properties["name"] as? String ?? "", message: properties["message"] as? String ?? "") {
        debugLog("crash report dropped (\(reason))")
        CrashInstaller.remove(report: report)
        continue
      }
      let crashEventId = newEventId()
      properties["$event_id"] = crashEventId
      if !handled { properties["handled"] = false }
      var tags: [String: Any] = ["mechanism": mechanism]
      let origin: CrashOrigin
      if let scope = CrashInstaller.scope(report: report) {
        // The run's own scope, written while it ran (0.8.0 and later).
        for (key, value) in ((scope["tags"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) where tags.count < 20 && tags[key] == nil {
          if let name = tagKey(key), let scalar = tagValue(value) { tags[name] = scalar }
        }
        if let user = scope["user_hash"] as? String { properties["user_hash"] = user }
        // Scrubbed again: a report written by an earlier SDK kept them as recorded.
        if let crumbs = scope["breadcrumbs"] as? [[String: String]], !crumbs.isEmpty {
          properties["breadcrumbs"] = crumbs.suffix(30).map { crumb in crumb.merging(crumb["message"].map { ["message": scrubbed($0, limit: 200, scrubFrame)] } ?? [:]) { _, new in new } }
        }
        // A fatal app hang carries `session_status: abnormal` (CrashReporting.swift): it ends this
        // session abnormal, a crash or watchdog termination ends it crashed, as in Sentry.
        let hash = (scope["session_hash"] as? String).flatMap { $0 == sessionId ? nil : $0 }
        origin = CrashOrigin(sessionHash: hash, release: scope["release"] as? String, environment: scope["environment"] as? String)
      } else {
        // The session that was running when the report was written, unless it is this launch's.
        origin = SessionLedger.session(forReport: report, directory: folder).flatMap { $0.hash == sessionId ? nil : CrashOrigin(sessionHash: $0.hash, release: $0.release, environment: $0.environment) }
          // None: this launch's release, and no session (never this launch's own).
          ?? CrashOrigin()
      }
      properties["tags"] = tags
      do {
        // The crashed run's replay, sent first and linked when it arrived.
        let replayFile = ReplayCrashStore.file(for: report)
        let recorder = replayRecorder
        let crashReplay: (() async -> String?)? = recorder.flatMap { recorder in
          replayFile.flatMap { file in (try? Data(contentsOf: file)).map { data in { await recorder.sendCrashReplay(data) } } }
        }
        if try await sendException(properties, origin: origin, eventId: crashEventId, crashReplay: crashReplay) { sent += 1 }
        // Sent, or dropped by beforeSend: either way it is done with.
        CrashInstaller.remove(report: report)
      } catch {
        break
      }
    }
    return sent
  }
}

/// The run a stored crash report came from.
struct CrashOrigin {
  var sessionHash: String? = nil
  var release: String? = nil
  var environment: String? = nil
}

/// The screen load `reportFullyDisplayed` applies to.
struct ScreenLoadState {
  weak var transaction: Transaction?
  var automatic: Bool
  var initialDisplayed = false
  var fullyDisplayedAt: UInt64?
  /// Wait for `reportFullyDisplayed()` (a SwiftUI view's `waitForFullDisplay`), or nil for
  /// `enableTimeToFullDisplayTracing`.
  var waitForFullDisplay: Bool?

  init(transaction: Transaction, automatic: Bool, waitForFullDisplay: Bool? = nil) {
    self.transaction = transaction
    self.automatic = automatic
    self.waitForFullDisplay = waitForFullDisplay
  }
}

/// A `captureMessage` level, sent as `level`.
public enum MessageLevel: String, Sendable {
  case fatal, error, warning, info, debug
}

private struct ErrorEnvelope: Decodable {
  let message: String
  let code: String
}
