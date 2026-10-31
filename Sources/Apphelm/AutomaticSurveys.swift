import Foundation

/// An automatically shown survey's display rules, from /api/surveys/active. Who may see it,
/// the sample and the caps stay on the server, which applies them when the survey is asked for.
public struct AutoSurvey: Sendable, Equatable {
  public let id: String
  /// Shown when this event is tracked.
  public var event: String? = nil
  /// Shown when this screen is viewed (`screen(_:)` or screen autocapture).
  public var screen: String? = nil
  /// `desktop`, `tablet`, `mobile`; empty means every device.
  public var devices: [String] = []
  public var delaySeconds: Int = 0
  /// True when the program targets a web page (a URL or a CSS selector): never shown in an app.
  public var webOnly: Bool = false
}

func autoSurveys(_ data: Any?) -> [AutoSurvey] {
  (data as? [Any] ?? []).compactMap { entry in
    guard let item = entry as? OrderedJSONObject, let id = item["id"] as? String, id.hasPrefix("svp_") else { return nil }
    let display = item["display"] as? OrderedJSONObject ?? OrderedJSONObject(pairs: [])
    return AutoSurvey(
      id: id, event: display["event"] as? String, screen: display["screen"] as? String, devices: display["devices"] as? [String] ?? [],
      delaySeconds: min(300, max(0, (display["delaySeconds"] as? NSNumber)?.intValue ?? 0)),
      webOnly: display["url"] != nil || display["selector"] != nil)
  }
}

/// Whether a tracked event should show an automatic survey on this device class. A screen
/// rule matches a `$screen` with exactly that name, an event rule an event with exactly that
/// name (either one is enough when both are set). A program with neither, and no web-only
/// rule, shows on the first screen viewed.
func autoSurveyMatches(_ survey: AutoSurvey, event: String, screen: String?, device: String) -> Bool {
  if !survey.devices.isEmpty, !survey.devices.contains(device) { return false }
  if survey.screen == nil, survey.event == nil { return !survey.webOnly && event == "$screen" }
  if let rule = survey.screen, event == "$screen", screen == rule { return true }
  if let rule = survey.event, event == rule { return true }
  return false
}

/// The trigger source of an automatic survey: one per day, so the server's caps see one occurrence.
func autoTriggerSource(_ now: Date) -> String {
  "auto:" + ISO8601DateFormatter().string(from: now).prefix(10)
}

/// Shows automatic surveys: loads the product's rules once, and on each tracked event that
/// matches one, waits its delay, asks the server for that program and presents the offer.
/// One survey at a time, and each program is asked for at most once while this runs.
final class AutomaticSurveyEngine: @unchecked Sendable {
  typealias Present = @Sendable (SurveyOffer, @escaping @Sendable () -> Void) async -> Void
  private let lock = NSLock()
  private let device: @Sendable () async -> String
  private let load: @Sendable () async throws -> [AutoSurvey]
  private let ask: @Sendable (AutoSurvey, String) async throws -> SurveyOffer?
  private let present: Present
  private let sleep: @Sendable (Int) async -> Void
  private var surveys: [AutoSurvey]?
  private var deviceClass = ""
  private var loading = false
  private var lastLoad: Date?
  // Events seen while the rules load, matched once they are in.
  private var waiting: [(event: String, screen: String?)] = []
  private var asked: Set<String> = []
  private var busy = false
  private var stopped = false
  /// The task in flight, for tests.
  private(set) var pending: Task<Void, Never>?

  init(device: @escaping @Sendable () async -> String, load: @escaping @Sendable () async throws -> [AutoSurvey], ask: @escaping @Sendable (AutoSurvey, String) async throws -> SurveyOffer?, present: @escaping Present, sleep: @escaping @Sendable (Int) async -> Void = { seconds in if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) } }) {
    self.device = device
    self.load = load
    self.ask = ask
    self.present = present
    self.sleep = sleep
  }

  func stop() { lock.withLock { stopped = true } }

  /// Called for every tracked event (opted in only). Matched at once; only the first load of
  /// the rules waits, and the events seen meanwhile are matched when it is done.
  func captured(event: String, screen: String?) {
    enum Next { case none, load, match([AutoSurvey], String) }
    let next: Next = lock.withLock {
      if stopped || busy { return .none }
      if let surveys { return .match(surveys, deviceClass) }
      if waiting.count < 20 { waiting.append((event, screen)) }
      if loading || lastLoad.map({ Date().timeIntervalSince($0) < 60 }) == true { return .none }
      loading = true
      lastLoad = Date()
      return .load
    }
    switch next {
    case .none: return
    case .match(let surveys, let device): show(surveys, device: device, event: event, screen: screen)
    case .load:
      // Started under the lock, so `pending` is set before the task can replace it.
      lock.withLock {
        pending = Task { [self] in
          let device = await device()
          let loaded = try? await load()
          let queued: [(event: String, screen: String?)] = lock.withLock {
            loading = false
            deviceClass = device
            if let loaded { surveys = loaded }
            defer { waiting = [] }
            return loaded == nil ? [] : waiting
          }
          for item in queued { captured(event: item.event, screen: item.screen) }
        }
      }
    }
  }

  private func show(_ surveys: [AutoSurvey], device: String, event: String, screen: String?) {
    lock.withLock {
      if stopped || busy { return }
      guard let survey = surveys.first(where: { !asked.contains($0.id) && autoSurveyMatches($0, event: event, screen: screen, device: device) }) else { return }
      busy = true
      asked.insert(survey.id)
      pending = Task { [self] in
        await sleep(survey.delaySeconds)
        guard !lock.withLock({ stopped }), let offer = try? await ask(survey, device) else { return release() }
        await present(offer) { [self] in release() }
      }
    }
  }

  private func release() { lock.withLock { busy = false } }
}

extension ApphelmClient {
  /// The product's automatically shown surveys and their display rules (/api/surveys/active).
  /// Needs `surveyKey` and `surveyOrigin`, as `surveyEligible` does.
  public func surveyActive() async throws -> [AutoSurvey] {
    autoSurveys(try await surveyRequest("/api/surveys/active", [:]))
  }

  /// Show surveys set to appear automatically (display "auto" in AppHelm) when their rules
  /// match: a screen viewed (`screen(_:)` or screen autocapture) or an event tracked, on a
  /// matching device (an iPhone is `mobile`, an iPad `tablet`). After the program's delay the
  /// server is asked for it (it still checks who may see it and how often) and `present`
  /// draws the offer; call the closure it gets once the survey is closed. One survey at a
  /// time. Nothing is shown while opted out. `externalUserId` names your identified customer
  /// (nil asks for the anonymous person, for programs open to anonymous people).
  ///
  /// On iOS, `enableAutomaticSurveys(externalUserId:)` presents with the built-in sheet
  /// (`ApphelmSurveyPresenter`). Calling it again replaces the previous setup.
  public func enableAutomaticSurveys(externalUserId: (@Sendable () -> String?)? = nil, device: String? = nil, present: @escaping @Sendable (SurveyOffer, @escaping @Sendable () -> Void) async -> Void) {
    let engine = AutomaticSurveyEngine(
      device: {
        if let device { return device }
        return await currentDeviceClass()
      },
      load: { [weak self] in try await self?.surveyActive() ?? [] },
      ask: { [weak self] survey, device in
        guard let self, !self.isOptedOut else { return nil }
        return try await self.surveyEligible(triggerType: "manual", triggerSourceId: autoTriggerSource(Date()), externalUserId: externalUserId?(), programId: survey.id, device: device)
      },
      present: present)
    setCaptureObserver { name, screen in engine.captured(event: name, screen: screen) }
  }

  /// Stop showing automatic surveys.
  public func disableAutomaticSurveys() {
    setCaptureObserver(nil)
  }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// `mobile` on a phone, `tablet` on an iPad.
func currentDeviceClass() async -> String {
  await MainActor.run { UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile" }
}

extension ApphelmClient {
  /// Automatic surveys drawn by the built-in sheet (`ApphelmSurveyPresenter`), answered and
  /// dismissed through this client. See `enableAutomaticSurveys(externalUserId:device:present:)`.
  public func enableAutomaticSurveys(externalUserId: (@Sendable () -> String?)? = nil) {
    enableAutomaticSurveys(externalUserId: externalUserId) { [weak self] offer, closed in
      guard let self else { return closed() }
      await MainActor.run {
        if !ApphelmSurveyPresenter.present(offer, client: self, onClose: closed) { closed() }
      }
    }
  }
}
#else
func currentDeviceClass() async -> String { "desktop" }
#endif
