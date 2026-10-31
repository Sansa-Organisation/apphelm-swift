import Foundation
import Testing

@testable import Apphelm

extension ApphelmOptions {
  /// No disk, no timers, no lifecycle or screen autocapture: the client as it was before
  /// those existed, for tests about something else.
  var quiet: ApphelmOptions {
    var options = self
    options.persistence = .memory
    options.flushIntervalSeconds = 0
    options.flushAt = 0
    options.captureApplicationLifecycleEvents = false
    options.captureScreenViews = false
    return options
  }
}

/// A server whose answer to each event is chosen by `status`, by event name.
final class ScriptedServer: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [[String: Any]] = []
  private var statusFor: (String) -> Int = { _ in 202 }
  let host = "parity-\(UUID().uuidString.lowercased()).test"
  var baseURL: String { "https://\(host)" }

  func answer(_ status: @escaping (String) -> Int) { lock.withLock { statusFor = status } }

  func session() -> URLSession {
    RoutedURLProtocol.register(host: host) { [self] request in
      let body = (try? requestJSON(request)) ?? [:]
      let status = lock.withLock { () -> Int in
        seen.append(body)
        return statusFor(body["eventName"] as? String ?? "")
      }
      let ok = (200...299).contains(status)
      return try jsonResponse(url: request.url!, status: status, body: ok ? ["accepted": true, "eventId": "evt_1"] : ["error": ["code": "refused", "message": "refused"]])
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  var bodies: [[String: Any]] { lock.withLock { seen } }
  var names: [String] { bodies.map { $0["eventName"] as? String ?? "" } }
  func properties(_ name: String) -> [[String: Any]] {
    bodies.filter { $0["eventName"] as? String == name }.map { $0["properties"] as? [String: Any] ?? [:] }
  }
}

/// A timer that fires when the test says so.
final class ManualTimer: RepeatingTimer, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable () -> Void)?
  private(set) var interval: TimeInterval = 0
  private(set) var created = 0
  private(set) var cancelled = false

  var factory: RepeatingTimerFactory {
    { [self] interval, fire in
      lock.withLock {
        self.interval = interval
        handler = fire
        created += 1
      }
      return self
    }
  }

  func fire() { lock.withLock { handler }?() }
  func cancel() { lock.withLock { cancelled = true } }
}

/// A queue folder and a UserDefaults suite of their own, removed afterwards.
final class Sandbox {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-parity-\(UUID().uuidString)", isDirectory: true)
  let suite = "apphelm-parity-\(UUID().uuidString)"

  var persistence: ApphelmPersistence { .directory(directory, suiteName: suite) }
  var files: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted() }

  /// As a new process would: the shared queue of the folder is read from disk again.
  func relaunch() { EventQueue.forgetShared(directory: directory) }

  deinit {
    EventQueue.forgetShared(directory: directory)
    try? FileManager.default.removeItem(at: directory)
    UserDefaults().removePersistentDomain(forName: suite)
  }
}

/// Wait until `condition` holds, for up to two seconds.
func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  return condition()
}

@Suite("PostHog parity")
struct ParityTests {
  func options(_ server: ScriptedServer, _ sandbox: Sandbox?, distinctId: String? = nil, configure: (inout ApphelmOptions) -> Void = { _ in }) -> ApphelmOptions {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: server.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: distinctId)
    options.persistence = sandbox?.persistence ?? .memory
    options.flushIntervalSeconds = 0
    options.flushAt = 0
    options.captureApplicationLifecycleEvents = false
    options.captureScreenViews = false
    configure(&options)
    return options
  }

  func client(_ options: ApphelmOptions, _ server: ScriptedServer, store: MemoryStore = MemoryStore(), installStore: any InstallRecordStore = MemoryInstallRecordStore(), timer: ManualTimer = ManualTimer(), app: AppInfo = AppInfo(version: "1.0", build: "1")) -> ApphelmClient {
    ApphelmClient(options: options, session: server.session(), store: store, installStore: installStore, attributionToken: { nil }, timerFactory: timer.factory, appInfo: app)
  }

  // MARK: Persistent queue

  @Test("Queued events survive the client being re-created, and are deleted once delivered")
  func queueSurvivesRelaunch() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let store = MemoryStore()
    do {
      let first = client(options(server, sandbox), server, store: store)
      first.track("cart_opened", properties: ["items": 2])
      first.track("checkout_started")
    }
    #expect(sandbox.files.count == 2)
    #expect(server.bodies.isEmpty)
    sandbox.relaunch()
    let second = client(options(server, sandbox), server, store: store)
    await second.flush()
    #expect(server.names == ["cart_opened", "checkout_started"])
    #expect(server.properties("cart_opened").first?["items"] as? Int == 2)
    #expect(server.properties("cart_opened").first?["distinct_id"] as? String == store.load())
    #expect(sandbox.files.isEmpty)
  }

  @Test("A failed flush keeps the unsent events on disk, in order, and a relaunch sends each once")
  func failedFlushSurvivesRelaunch() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    server.answer { $0 == "second" ? 503 : 202 }
    do {
      let first = client(options(server, sandbox), server)
      first.track("first"); first.track("second"); first.track("third")
      await first.flush()
    }
    #expect(server.names == ["first", "second"])
    #expect(sandbox.files.count == 2)
    sandbox.relaunch()
    server.answer { _ in 202 }
    let second = client(options(server, sandbox), server)
    await second.flush()
    await second.flush()
    #expect(server.names == ["first", "second", "second", "third"])
    let ids = server.bodies.map { $0["eventId"] as? String ?? "" }
    #expect(ids[1] == ids[2] && !ids[1].isEmpty)
    #expect(Set(ids).count == 3)
    #expect(sandbox.files.isEmpty)
  }

  @Test("An event the server refuses for good is dropped instead of holding up the queue")
  func refusedEventDropped() async throws {
    let server = ScriptedServer()
    server.answer { $0 == "bad" ? 422 : 202 }
    let apphelm = client(options(server, nil), server)
    apphelm.track("bad"); apphelm.track("good")
    await apphelm.flush()
    await apphelm.flush()
    #expect(server.names == ["bad", "good"])
  }

  @Test("A property JSON can't hold is sent as text instead of failing every flush")
  func nonJSONProperty() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil), server)
    apphelm.track("booked", properties: ["at": Date(timeIntervalSince1970: 0), "link": URL(string: "https://example.com/a")!, "missing": Optional<String>.none as Any])
    await apphelm.flush()
    let sent = try #require(server.properties("booked").first)
    #expect(sent["at"] as? String == "1970-01-01T00:00:00Z")
    #expect(sent["link"] as? String == "https://example.com/a")
    #expect(sent["missing"] is NSNull)
  }

  @Test("The queue is bounded: past maxQueueSize the oldest are dropped, on disk too")
  func boundedQueue() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let apphelm = client(options(server, sandbox) { $0.maxQueueSize = 3 }, server)
    for index in 1...5 { apphelm.track("event_\(index)") }
    #expect(sandbox.files.count == 3)
    await apphelm.flush()
    #expect(server.names == ["event_3", "event_4", "event_5"])
  }

  @Test("The queue stays consistent under concurrent appends, and two takes never share an event")
  func concurrentQueue() throws {
    let sandbox = Sandbox()
    let queue = EventQueue(directory: sandbox.directory, maxSize: 1000)
    DispatchQueue.concurrentPerform(iterations: 200) { index in queue.append(["eventName": "e\(index)"]) }
    #expect(queue.count == 200)
    #expect(sandbox.files.count == 200)
    let first = queue.takePending()
    queue.append(["eventName": "late"])
    let second = queue.takePending()
    #expect(first.count == 200 && second.count == 1)
    #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    queue.release(first.map(\.id))
    #expect(queue.takePending().count == 200)
    // A new process reads the same events back, in order, skipping a corrupt file.
    try Data("not json".utf8).write(to: sandbox.directory.appendingPathComponent("ffffffffffffffff.json"))
    let reread = EventQueue(directory: sandbox.directory, maxSize: 1000)
    #expect(reread.count == 201)
    #expect(reread.takePending().last?.event["eventName"] as? String == "late")
    #expect(!sandbox.files.contains("ffffffffffffffff.json"))
  }

  // MARK: Auto-flush

  @Test("The timer flushes every flushIntervalSeconds; 0 creates no timer")
  func timerFlush() async throws {
    let server = ScriptedServer()
    let timer = ManualTimer()
    let apphelm = client(options(server, nil) { $0.flushIntervalSeconds = 30 }, server, timer: timer)
    #expect(timer.interval == 30 && timer.created == 1)
    apphelm.track("viewed_plan")
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(server.bodies.isEmpty)
    timer.fire()
    #expect(await eventually { server.names == ["viewed_plan"] })

    let off = ManualTimer()
    _ = client(options(server, nil), server, timer: off)
    #expect(off.created == 0)
  }

  @Test("Reaching flushAt flushes without being asked")
  func thresholdFlush() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil) { $0.flushAt = 3 }, server)
    apphelm.track("one"); apphelm.track("two")
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(server.bodies.isEmpty)
    apphelm.track("three")
    #expect(await eventually { server.names == ["one", "two", "three"] })
  }

  @Test("Going to the background sends $app_backgrounded and flushes, then ends the background task")
  func backgroundFlush() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil) { $0.captureApplicationLifecycleEvents = true }, server)
    apphelm.track("added_to_cart")
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      apphelm.applicationDidEnterBackground { done.resume() }
    }
    #expect(server.names == ["added_to_cart", "$app_backgrounded"])

    let quietServer = ScriptedServer()
    let noFlush = client(options(quietServer, nil) { $0.flushOnBackground = false }, quietServer)
    noFlush.track("added_to_cart")
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      noFlush.applicationDidEnterBackground { done.resume() }
    }
    #expect(quietServer.bodies.isEmpty)
  }

  @Test("A client the app lets go of is released: the timer, observers and flushes hold it weakly")
  func clientReleased() async throws {
    let server = ScriptedServer()
    let timer = ManualTimer()
    weak var released: ApphelmClient?
    do {
      let apphelm = client(options(server, nil) { $0.flushIntervalSeconds = 30; $0.flushAt = 1; $0.captureScreenViews = true }, server, timer: timer)
      apphelm.track("one")
      await apphelm.flush()
      released = apphelm
    }
    #expect(await eventually { released == nil })
    #expect(timer.cancelled)
  }

  // MARK: Lifecycle

  @Test("$app_installed on the first launch, nothing on the same version, $app_updated on a new one")
  func installAndUpdate() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let store = MemoryStore()
    let lifecycle = { (options: inout ApphelmOptions) in options.captureApplicationLifecycleEvents = true }
    await client(options(server, sandbox, configure: lifecycle), server, store: store, app: AppInfo(version: "1.0", build: "7")).flush()
    sandbox.relaunch()
    await client(options(server, sandbox, configure: lifecycle), server, store: store, app: AppInfo(version: "1.0", build: "7")).flush()
    sandbox.relaunch()
    await client(options(server, sandbox, configure: lifecycle), server, store: store, app: AppInfo(version: "1.1", build: "9")).flush()
    #expect(server.names == ["$app_installed", "$app_updated"])
    let installed = try #require(server.properties("$app_installed").first)
    #expect(installed["version"] as? String == "1.0" && installed["build"] as? String == "7")
    let updated = try #require(server.properties("$app_updated").first)
    #expect(updated["version"] as? String == "1.1" && updated["build"] as? String == "9")
    #expect(updated["previous_version"] as? String == "1.0" && updated["previous_build"] as? String == "7")
  }

  @Test("An app that used Apphelm before this version is not counted as a new install")
  func existingUserNotInstalled() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let store = MemoryStore()
    store.save("existing-anon")
    let apphelm = client(options(server, sandbox) { $0.captureApplicationLifecycleEvents = true }, server, store: store)
    await apphelm.flush()
    #expect(server.bodies.isEmpty)
    #expect(UserDefaults(suiteName: sandbox.suite)?.string(forKey: ClientState.appVersion) == "1.0")
  }

  @Test("Without persistence, or with lifecycle capture off, no install is sent")
  func noInstallWithoutPersistence() async throws {
    let server = ScriptedServer()
    await client(options(server, nil) { $0.captureApplicationLifecycleEvents = true }, server).flush()
    let sandbox = Sandbox()
    await client(options(server, sandbox), server).flush()
    #expect(server.bodies.isEmpty)
  }

  @Test("$app_opened once per launch and per return from the background")
  func openedAndBackgrounded() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil) { $0.captureApplicationLifecycleEvents = true; $0.flushOnBackground = false }, server, app: AppInfo(version: "2.0", build: "3"))
    apphelm.applicationDidBecomeActive()
    apphelm.applicationDidBecomeActive() // a brief interruption: no second open
    apphelm.applicationDidEnterBackground()
    apphelm.applicationDidBecomeActive()
    await apphelm.flush()
    #expect(server.names == ["$app_opened", "$app_backgrounded", "$app_opened"])
    let opened = server.properties("$app_opened")
    #expect(opened.map { $0["from_background"] as? Bool } == [false, true])
    #expect(opened.first?["version"] as? String == "2.0" && opened.first?["build"] as? String == "3")
  }

  // MARK: Screens

  @Test("screen sends $screen with $screen_name")
  func screenEvent() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil), server)
    apphelm.screen("Checkout", properties: ["step": 2])
    apphelm.screen("   ")
    await apphelm.flush()
    #expect(server.names == ["$screen"])
    let sent = try #require(server.properties("$screen").first)
    #expect(sent["$screen_name"] as? String == "Checkout" && sent["step"] as? Int == 2)
  }

  @Test("Autocaptured screens go to clients with captureScreenViews only")
  func autocaptureRouting() async throws {
    let on = ScriptedServer()
    let off = ScriptedServer()
    let capturing = client(options(on, nil) { $0.captureScreenViews = true }, on)
    let ignoring = client(options(off, nil), off)
    ScreenCapture.capture("Settings")
    await capturing.flush()
    await ignoring.flush()
    #expect(on.properties("$screen").contains { $0["$screen_name"] as? String == "Settings" })
    #expect(off.bodies.isEmpty)
  }

  @Test("A view controller's type name becomes a readable screen name")
  func screenNames() {
    #expect(screenName(fromTypeName: "CheckoutViewController") == "Checkout")
    #expect(screenName(fromTypeName: "ProfileController") == "Profile")
    #expect(screenName(fromTypeName: "Shop.OrderListViewController") == "OrderList")
    #expect(screenName(fromTypeName: "DetailViewController<Product>") == "Detail")
    #expect(screenName(fromTypeName: "ViewController") == "ViewController")
    #expect(screenName(fromTypeName: "Onboarding") == "Onboarding")
    #expect(screenName(fromTypeName: "_UIPrivateController") == nil)
  }

  // MARK: Opt-out

  @Test("optOut clears the queue and stops everything being sent; optIn resumes; it is remembered")
  func optOutAndIn() async throws {
    struct Failure: Error {}
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let apphelm = client(options(server, sandbox), server)
    #expect(!apphelm.isOptedOut)
    apphelm.track("before_opt_out")
    apphelm.optOut()
    #expect(apphelm.isOptedOut)
    #expect(sandbox.files.isEmpty)
    apphelm.track("while_opted_out")
    apphelm.screen("Hidden")
    apphelm.identify("user-9")
    try await apphelm.captureException(Failure())
    try await apphelm.identify(externalUserId: "user-9")
    #expect(await apphelm.recordInstall() == false)
    await apphelm.startTransaction("Load").finish()
    await apphelm.flush()
    #expect(server.bodies.isEmpty)

    sandbox.relaunch()
    let relaunched = client(options(server, sandbox), server)
    #expect(relaunched.isOptedOut)
    relaunched.optIn()
    relaunched.track("after_opt_in")
    await relaunched.flush()
    #expect(server.names == ["after_opt_in"])
    sandbox.relaunch()
    #expect(!client(options(server, sandbox), server).isOptedOut)
  }

  @Test("defaultOptedOut starts opted out until optIn, which is remembered")
  func defaultOptedOut() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let apphelm = client(options(server, sandbox) { $0.defaultOptedOut = true }, server)
    #expect(apphelm.isOptedOut)
    apphelm.track("ignored")
    apphelm.optIn()
    sandbox.relaunch()
    let relaunched = client(options(server, sandbox) { $0.defaultOptedOut = true }, server)
    #expect(!relaunched.isOptedOut)
    relaunched.track("kept")
    await relaunched.flush()
    #expect(server.names == ["kept"])
  }

  // MARK: Identity and groups

  @Test("identify sends $identify from the new id with $anon_distinct_id and $set, and persists the id")
  func identifyContract() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let store = MemoryStore()
    let apphelm = client(options(server, sandbox), server, store: store)
    let anonymous = apphelm.distinctId
    apphelm.track("browsed")
    apphelm.identify("user-42", traits: ["plan": "pro"])
    apphelm.track("purchased")
    apphelm.identify("user-42") // already identified, nothing new: nothing sent
    await apphelm.flush()
    #expect(server.names == ["browsed", "$identify", "purchased"])
    #expect(server.properties("browsed").first?["distinct_id"] as? String == anonymous)
    let identify = try #require(server.properties("$identify").first)
    #expect(identify["distinct_id"] as? String == "user-42")
    #expect(identify["$anon_distinct_id"] as? String == anonymous)
    #expect((identify["$set"] as? [String: Any])?["plan"] as? String == "pro")
    #expect(server.properties("purchased").first?["distinct_id"] as? String == "user-42")

    sandbox.relaunch()
    let relaunched = client(options(server, sandbox), server, store: store)
    #expect(relaunched.distinctId == "user-42")
    // Someone else, without a reset: no $anon_distinct_id, so the two are never merged.
    relaunched.identify("user-77")
    await relaunched.flush()
    let second = try #require(server.properties("$identify").last)
    #expect(second["distinct_id"] as? String == "user-77")
    #expect(second["$anon_distinct_id"] == nil && second["$set"] == nil)
  }

  @Test("The customer-signal identify still posts apphelm.identify at once, beside the new identify")
  func customerSignalIdentifyKept() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil), server)
    try await apphelm.identify(externalUserId: "cust_1", traits: ["plan": "pro"], traitSources: ["plan": ["sourceType": "auth", "sourceId": "session", "verification": "integration_verified"]])
    #expect(server.names == ["apphelm.identify"])
    #expect((server.properties("apphelm.identify").first)?["externalUserId"] as? String == "cust_1")
  }

  @Test("alias sends $create_alias from the current id")
  func aliasContract() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil, distinctId: "user-42"), server)
    apphelm.alias("legacy-7")
    apphelm.alias("user-42") // its own id: nothing
    await apphelm.flush()
    #expect(server.names == ["$create_alias"])
    let alias = try #require(server.properties("$create_alias").first)
    #expect(alias["distinct_id"] as? String == "user-42" && alias["alias"] as? String == "legacy-7")
  }

  @Test("group puts $groups on later events, persisted; traits send $groupidentify")
  func groupContract() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let apphelm = client(options(server, sandbox), server)
    apphelm.track("before_group")
    apphelm.group(type: "company", key: "acme", traits: ["name": "Acme", "seats": 12])
    apphelm.group(type: "team", key: "design")
    apphelm.track("in_group")
    await apphelm.flush()
    #expect(server.names == ["before_group", "$groupidentify", "in_group"])
    #expect(server.properties("before_group").first?["$groups"] == nil)
    let identify = try #require(server.properties("$groupidentify").first)
    #expect(identify["$group_type"] as? String == "company" && identify["$group_key"] as? String == "acme")
    let set = try #require(identify["$group_set"] as? [String: Any])
    #expect(set["name"] as? String == "Acme" && set["seats"] as? Int == 12)
    #expect(server.properties("in_group").first?["$groups"] as? [String: String] == ["company": "acme", "team": "design"])

    sandbox.relaunch()
    let relaunched = client(options(server, sandbox), server)
    #expect(relaunched.groups == ["company": "acme", "team": "design"])
  }

  @Test("Super properties go on every later event, the event's own win, and they persist")
  func superProperties() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let apphelm = client(options(server, sandbox), server)
    apphelm.register(["plan": "pro", "tier": 1])
    apphelm.track("first", properties: ["plan": "free"])
    apphelm.unregister("tier")
    apphelm.track("second")
    await apphelm.flush()
    let first = try #require(server.properties("first").first)
    #expect(first["plan"] as? String == "free" && first["tier"] as? Int == 1)
    let second = try #require(server.properties("second").first)
    #expect(second["plan"] as? String == "pro" && second["tier"] == nil)

    sandbox.relaunch()
    let relaunched = client(options(server, sandbox), server)
    relaunched.track("third")
    await relaunched.flush()
    #expect(server.properties("third").first?["plan"] as? String == "pro")
  }

  @Test("reset gives a new anonymous id and drops the identified id, super properties and groups")
  func resetContract() async throws {
    let server = ScriptedServer()
    let sandbox = Sandbox()
    let store = MemoryStore()
    let apphelm = client(options(server, sandbox), server, store: store)
    let firstAnonymous = apphelm.distinctId
    apphelm.identify("user-42")
    apphelm.register(["plan": "pro"])
    apphelm.group(type: "company", key: "acme")
    apphelm.track("as_user")
    apphelm.reset()
    #expect(apphelm.distinctId != "user-42" && apphelm.distinctId != firstAnonymous)
    #expect(apphelm.groups.isEmpty)
    let resetAnonymous = apphelm.distinctId
    apphelm.track("after_reset")
    // Identifying after a reset merges the new anonymous id, not the old one.
    apphelm.identify("user-77")
    await apphelm.flush()
    #expect(server.properties("as_user").first?["distinct_id"] as? String == "user-42")
    let after = try #require(server.properties("after_reset").first)
    #expect(after["distinct_id"] as? String == resetAnonymous)
    #expect(after["plan"] == nil && after["$groups"] == nil)
    let identify = try #require(server.properties("$identify").last)
    #expect(identify["$anon_distinct_id"] as? String == resetAnonymous)

    sandbox.relaunch()
    apphelm.reset()
    let relaunched = client(options(server, sandbox), server, store: store)
    relaunched.track("relaunched")
    await relaunched.flush()
    let relaunchedEvent = try #require(server.properties("relaunched").first)
    #expect(relaunchedEvent["distinct_id"] as? String == store.load() && relaunchedEvent["plan"] == nil)
  }

  @Test("Customer signals carry no super properties or groups")
  func customerSignalsUntouched() async throws {
    let server = ScriptedServer()
    let apphelm = client(options(server, nil), server)
    apphelm.register(["plan": "pro"])
    apphelm.group(type: "company", key: "acme")
    apphelm.track("apphelm.goal", properties: ["goal": "activated"])
    await apphelm.flush()
    let goal = try #require(server.properties("apphelm.goal").first)
    #expect(goal["plan"] == nil && goal["$groups"] == nil)
  }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

final class CheckoutViewController: UIViewController {}
final class RenamedViewController: UIViewController, ApphelmScreenNaming {
  var apphelmScreenName: String? { "Pay" }
}

/// Runs on an iOS simulator (`xcodebuild test`), not in `swift test` on macOS.
@Suite("UIKit screen autocapture")
struct UIKitScreenTests {
  @MainActor
  @Test("viewDidAppear sends a $screen named after the controller; containers and children are left out")
  func swizzledViewDidAppear() async throws {
    let server = ScriptedServer()
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: server.baseURL, workspaceId: "org_1", productId: "prd_1").quiet
    options.captureScreenViews = true
    let apphelm = ApphelmClient(options: options, session: server.session(), store: MemoryStore())
    func appear(_ controller: UIViewController) {
      controller.beginAppearanceTransition(true, animated: false)
      controller.endAppearanceTransition()
    }
    let checkout = CheckoutViewController()
    let navigation = UINavigationController(rootViewController: checkout)
    appear(navigation)
    appear(checkout)
    let parent = RenamedViewController()
    let child = CheckoutViewController()
    parent.addChild(child)
    appear(child)
    appear(parent)
    await apphelm.flush()
    // Another suite's ScreenCapture.capture("Settings") may reach this client too.
    #expect(server.properties("$screen").compactMap { $0["$screen_name"] as? String }.filter { $0 != "Settings" } == ["Checkout", "Pay"])
  }
}
#endif
