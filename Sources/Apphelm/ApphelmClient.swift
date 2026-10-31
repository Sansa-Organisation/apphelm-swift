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
  /// The share of transactions started here that are kept, 0–1 (default 1: every
  /// `startTransaction` is sent). A transaction continuing an incoming `traceparent` keeps
  /// the caller's decision instead. Each kept transaction is one event.
  public var tracesSampleRate: Double
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

  public init(apiKey: String, baseURL: String = "https://apphelm.dev", workspaceId: String, productId: String, distinctId: String? = nil, timeoutSeconds: Double = 10, release: String? = nil, environment: String? = nil, tracesSampleRate: Double = 1, tracePropagationHosts: [String] = [], adsConsent: AdsConsent? = nil) {
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
    self.tracesSampleRate = tracesSampleRate.isNaN ? 1 : min(1, max(0, tracesSampleRate))
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

private struct AcceptedEnvelope: Decodable {
  let accepted: Bool?
}

/// Native iOS/macOS client on URLSession. Events are queued on disk (bounded, oldest
/// dropped) and flushed on a timer, at a queue length and when the app goes to the
/// background. UIKit is used only where it exists, for lifecycle events and screen views.
public final class ApphelmClient: Sendable {
  private let options: ApphelmOptions
  private let session: URLSession
  private let store: any DistinctIdStore
  private let installStore: any InstallRecordStore
  private let attributionToken: AttributionTokenProvider
  private let lock = NSLock()
  private var _distinctId: String
  private let queue: EventQueue
  private let state: ClientState
  private let appInfo: AppInfo
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
  private var _adsConsent: AdsConsent?
  // Set once this client has queued (or found) the install, so it is queued at most once
  // even when the install record cannot be saved.
  private var installClaimed = false
  private var replayRecorder: ReplayRecorder?
  // Told of each event tracked while opted in (automatic surveys): its name and screen name.
  private var captureObserver: (@Sendable (String, String?) -> Void)?

  /// `installStore` remembers that `$install` was sent (`UserDefaultsInstallRecordStore` by default).
  public convenience init(options: ApphelmOptions, session: URLSession = .shared, store: (any DistinctIdStore)? = nil, installStore: (any InstallRecordStore)? = nil) {
    self.init(options: options, session: session, store: store, installStore: installStore, attributionToken: appleAdsAttributionToken)
  }

  init(options: ApphelmOptions, session: URLSession, store: (any DistinctIdStore)?, installStore: (any InstallRecordStore)?, attributionToken: @escaping AttributionTokenProvider, timerFactory: RepeatingTimerFactory = dispatchTimerFactory, appInfo: AppInfo? = nil) {
    self.options = options
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
    if options.captureApplicationLifecycleEvents || options.flushOnBackground { lifecycleObserver = LifecycleObserver(client: self) }
    #endif
    if options.captureScreenViews { ScreenCapture.register(self) }
    if let replay = options.replay {
      let uploader = ReplayUploader(baseURL: options.baseURL, key: replay.projectKey ?? options.surveyKey, origin: replay.origin ?? options.surveyOrigin, timeout: options.timeoutSeconds, session: session)
      replayRecorder = ReplayRecorder(options: replay, workspaceId: options.workspaceId, productId: options.productId,
        person: { [weak self] in
          guard let self else { return ReplayRecorder.Person(distinctId: "", identified: false) }
          return ReplayRecorder.Person(distinctId: self.distinctId, identified: self.lock.withLock { self._identified })
        },
        sessionHash: { [weak self] in self?.sessionId },
        allowed: { [weak self] in self.map { !$0.isOptedOut } ?? false },
        send: uploader.map { uploader -> ReplayRecorder.Sender in { body in await uploader.send(body) } })
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
    guard let fromBackground, options.captureApplicationLifecycleEvents else { return }
    enqueue("$app_opened", properties: ["from_background": fromBackground, "version": appInfo.version, "build": appInfo.build])
  }

  /// The app went to the background: `$app_backgrounded`, then a flush. `finish` is called
  /// when the flush is over (it ends the background task).
  func applicationDidEnterBackground(finish: @escaping @Sendable () -> Void = {}) {
    lock.withLock {
      appActive = false
      wasBackgrounded = true
    }
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

  private func request(path: String, body: [String: Any]?) throws -> URLRequest {
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

  private func send<T: Decodable>(path: String, body: [String: Any]?) async throws -> T {
    let request = try request(path: path, body: body)
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
    let length: Int? = lock.withLock {
      if _optedOut { return nil }
      let signal = customerSignalEvents.contains(trimmed)
      // Super properties and groups first; the event's own properties win.
      var merged: [String: Any] = signal ? [:] : _superProperties
      if !signal, !_groups.isEmpty { merged["$groups"] = _groups }
      merged.merge(properties) { _, own in own }
      // The consent the event was tracked under, not the one in force when it is flushed.
      if let consent = _adsConsent, !signal { merged["$ad_consent"] = consent.rawValue }
      // The person at track time: an event tracked before identify stays the anonymous one's.
      merged["distinct_id"] = distinctId ?? _distinctId
      // The id and time are fixed at track time, so a resend after a lost response is stored once.
      return queue.append(["eventName": trimmed, "properties": jsonSafe(merged), "eventId": UUID().uuidString, "occurredAt": ISO8601DateFormatter().string(from: Date())])
    }
    guard let length, options.flushAt > 0, length >= options.flushAt else { return }
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
    track("$screen", properties: merged)
    replayRecorder?.screenChanged(trimmed)
  }

  /// Declare that the person agreed to session replay (`ApphelmOptions.replay` must be set).
  /// With true, screens are recorded as wireframes; with false, recording stops at once and
  /// anything not yet sent is discarded. Apphelm does not ask: call it from your consent prompt.
  public func setReplayConsent(_ granted: Bool) {
    guard let recorder = replayRecorder else { return }
    recorder.setConsent(granted)
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

  /// The current replay recording's id (`rpl_…`), or nil when none is running.
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
      if isOptedOut {
        queue.release(batch.dropFirst(index).map(\.id))
        return
      }
      do {
        try await sendQueued(entry.event)
        queue.complete(entry.id)
      } catch let error as ApphelmError where [400, 413, 422].contains(error.status) {
        // Refused for good: resending can't succeed, and it would hold up the queue forever.
        queue.complete(entry.id)
      } catch {
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
  /// release's sessions and crash-free rate count this launch. Call it when the app becomes
  /// active; it is sent with the next `flush()`. Every error reported while it runs carries
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
    guard let release = options.release, !release.isEmpty else { return nil }
    let folder = directory ?? Self.defaultCrashDirectory()
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
      return health
    }
    guard let ending else { return false }
    SessionLedger.end(hash: ending.hash, at: ending.clock.date(), directory: ending.directory)
    return true
  }

  /// Report an error. Swift errors carry no stack of their own, so the stack where
  /// `captureException` was called is sent (Apphelm's own frames dropped). Apphelm groups by
  /// type, message and top app frame, or by `fingerprint` when given: every error with the
  /// same fingerprint joins one issue. `tags` are up to 20 scalar values; the server
  /// scrubs them again. `traceId` (`transaction.traceId`) links the issue to the trace it
  /// happened in; anything but a 32-character lower-case hex id is left out.
  public func captureException(_ error: Error, fingerprint: [String]? = nil, tags: [String: String] = [:], handled: Bool = true, traceId: String? = nil) async throws {
    var properties: [String: Any] = ["message": String(describing: error).prefix(240).description, "name": String(describing: type(of: error)).prefix(80).description]
    if let fingerprint, !fingerprint.isEmpty {
      properties["fingerprint"] = fingerprint.prefix(10).map { String($0.prefix(200)) }
    }
    let frames = Array(Thread.callStackSymbols.drop { $0.contains("$s7Apphelm") })
    if !frames.isEmpty {
      properties["stack"] = CrashInstaller.boundedStack(Array(frames.prefix(20)))
      // Which binaries those frames are in and where they are loaded, so the server can
      // symbolicate a stripped build from an uploaded symbol table.
      let images = DebugImages.referenced(by: Array(frames.prefix(20)), among: DebugImages.loaded())
      if !images.isEmpty { properties["debug_images"] = images }
    }
    if !tags.isEmpty { properties["tags"] = Dictionary(uniqueKeysWithValues: tags.sorted { $0.key < $1.key }.prefix(20).map { (String($0.key.prefix(40)), String($0.value.prefix(200))) }) }
    if !handled { properties["handled"] = false }
    if let traceId, isTraceId(traceId) { properties["trace_id"] = traceId }
    try await sendException(properties)
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
  /// to continue a trace started elsewhere; its trace id, parent span and sampling decision
  /// are kept. Otherwise it is kept with probability `tracesSampleRate`. Send it with
  /// `finish()`. `op` is free text such as `ui.load`, `task` or `http.client` (the server
  /// keeps letters, digits, `_`, `.` and `-`).
  public func startTransaction(_ name: String, op: String = "task", traceparent: String? = nil) -> Transaction {
    startTransaction(name, op: op, traceparent: traceparent, clock: TraceClock())
  }

  func startTransaction(_ name: String, op: String, traceparent: String?, clock: TraceClock) -> Transaction {
    let parent = parseTraceparent(traceparent)
    let sampled = parent?.sampled ?? (Double.random(in: 0..<1) < options.tracesSampleRate)
    let transaction = Transaction(send: { [self] properties in try await sendTransaction(properties) }, name: name, op: op, traceId: parent?.traceId ?? randomHex(16), parentSpanId: parent?.parentSpanId, sampled: sampled, release: options.release, environment: options.environment, clock: clock)
    lock.withLock { active = transaction }
    return transaction
  }

  /// The transaction automatic spans join: the one started most recently, until it
  /// finishes. Nil when that one has finished, even if an earlier one is still running, so
  /// it suits an app with one screen load or sync at a time.
  public var activeTransaction: Transaction? {
    lock.withLock { active }.flatMap { $0.isFinished ? nil : $0 }
  }

  /// Record a screen: queues its screen view, as `screen` does, and starts a `ui.load`
  /// transaction named after it, which becomes the `activeTransaction`, so the HTTP calls
  /// the screen makes are its spans. `finish()` it when the screen has its content. Use it
  /// in place of `screen`, not with it.
  public func startScreen(_ name: String, properties: [String: Any] = [:]) -> Transaction {
    screen(name, properties: properties)
    return startTransaction(name, op: "ui.load")
  }

  /// `session.data(for:)` inside an `http.client` span of `transaction` (by default the
  /// active one). The description is `METHOD scheme://host/path`: the query, fragment and
  /// any credentials in the URL are left out. A response from 400 up, or a thrown error
  /// (rethrown), finishes the span as an error. `traceparent` is set, naming the span, only
  /// when the host is in `tracePropagationHosts`.
  ///
  /// Without an unfinished transaction, for a URL that is not http(s), and for the client's
  /// own requests to Apphelm, it is `session.data(for:)` and nothing more. Don't also give
  /// that session `httpSpanDelegate()`, or each request is recorded twice.
  public func data(for request: URLRequest, session: URLSession = .shared, transaction: Transaction? = nil) async throws -> (Data, URLResponse) {
    guard let transaction = transaction ?? activeTransaction, !transaction.isFinished, let target = httpTarget(request.url),
          target.authority != httpTarget(URL(string: options.baseURL))?.authority else { return try await session.data(for: request) }
    let span = transaction.startSpan("http.client", description: "\((request.httpMethod ?? "GET").uppercased().prefix(10)) \(target.shown)")
    var request = request
    if propagatesTo(target.host, listed: options.tracePropagationHosts) { span.propagate(&request) }
    do {
      let result = try await session.data(for: request)
      let status = (result.1 as? HTTPURLResponse)?.statusCode
      span.finish(status.map { (100...399).contains($0) } ?? false ? .ok : .error)
      return result
    } catch {
      span.finish(.error)
      throw error
    }
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
  /// default the active one), timed by the task's metrics. The description is
  /// `METHOD scheme://host/path`: the query, fragment and any credentials in the URL are
  /// left out. A response from 400 up, or no response, is an error.
  ///
  /// Nothing is recorded when there is no unfinished transaction, when the request began
  /// before the transaction, when it is not http(s), or when it is the client's own, to
  /// Apphelm. It does not set `traceparent`: a delegate cannot change a request. Use
  /// `data(for:)`, or `propagate(&request)` before sending.
  public func recordHTTPSpan(task: URLSessionTask, metrics: URLSessionTaskMetrics, transaction: Transaction? = nil) {
    let request = task.originalRequest
    recordHTTPSpan(method: request?.httpMethod ?? "GET", url: request?.url, statusCode: (task.response as? HTTPURLResponse)?.statusCode, interval: metrics.taskInterval, transaction: transaction)
  }

  func recordHTTPSpan(method: String, url: URL?, statusCode: Int?, interval: DateInterval, transaction: Transaction? = nil) {
    guard let transaction = transaction ?? activeTransaction, let target = httpTarget(url),
          target.authority != httpTarget(URL(string: options.baseURL))?.authority else { return }
    transaction.addHTTPSpan(method: method, shown: target.shown, interval: interval, ok: statusCode.map { (100...399).contains($0) } ?? false)
  }

  /// Transactions carry no person and no stack, as in the other clients.
  private func sendTransaction(_ properties: [String: Any]) async throws {
    guard !isOptedOut else { return }
    let envelope: AcceptedEnvelope = try await send(path: "/events", body: [
      "workspaceId": options.workspaceId,
      "productId": options.productId,
      "eventName": "$transaction",
      "privacyMode": "strict",
      "properties": withAdConsent(properties),
    ])
    _ = envelope
  }

  /// `crashedIn` is the earlier session a stored crash report belongs to: the report then
  /// carries that session's id, release and environment, not this launch's.
  private func sendException(_ properties: [String: Any], crashedIn: StoredSession? = nil) async throws {
    var merged = properties
    let running = crashedIn == nil ? sessionId : nil
    if let crashedIn {
      merged["session_hash"] = crashedIn.hash
      merged["release"] = crashedIn.release
      if let environment = crashedIn.environment { merged["environment"] = environment }
    } else {
      if let release = options.release { merged["release"] = release }
      if let environment = options.environment { merged["environment"] = environment }
      // The session it happened in: an unhandled one marks that session crashed.
      if let running { merged["session_hash"] = running }
    }
    // The person, as on every other event, so the issue counts the users it affects.
    merged["distinct_id"] = distinctId
    guard !isOptedOut else { return }
    let envelope: AcceptedEnvelope = try await send(path: "/events", body: [
      "workspaceId": options.workspaceId,
      "productId": options.productId,
      "eventName": "$exception",
      "privacyMode": "strict",
      "properties": withAdConsent(merged),
    ])
    _ = envelope
  }

  /// Where crash reports wait for the next launch: `Caches/Apphelm` unless you pass one.
  public static func defaultCrashDirectory() -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Apphelm", isDirectory: true)
  }

  /// Record crashes (uncaught `NSException`s and fatal signals, including Swift traps) to
  /// disk as they happen. Call once, early in launch, then `sendPendingCrashReports()`.
  /// Installing again in the same process does nothing. Other crash reporters installed
  /// earlier still receive the crash: Apphelm calls their handlers after writing its report.
  public func installCrashReporting(directory: URL? = nil) throws {
    try CrashInstaller.install(directory: directory ?? Self.defaultCrashDirectory())
  }

  /// Send crashes recorded by earlier runs as unhandled exceptions, then delete them. A
  /// report that fails to send stays for the next launch. Returns how many were sent.
  @discardableResult
  public func sendPendingCrashReports(directory: URL? = nil) async -> Int {
    let folder = directory ?? Self.defaultCrashDirectory()
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
      properties["handled"] = false
      properties["tags"] = ["mechanism": mechanism]
      // The session that was running when the report was written, unless it is this launch's.
      let crashedIn = SessionLedger.session(forReport: report, directory: folder).flatMap { $0.hash == sessionId ? nil : $0 }
      do {
        try await sendException(properties, crashedIn: crashedIn)
        CrashInstaller.remove(report: report)
        sent += 1
      } catch {
        break
      }
    }
    return sent
  }
}

private struct ErrorEnvelope: Decodable {
  let message: String
  let code: String
}
