import Foundation
import Testing

@testable import Apphelm

private struct NoToken: Error {}

@Suite("Ad measurement")
struct AdMeasurementTests {
  func options(_ recorder: Recorder, consent: AdsConsent? = nil) -> ApphelmOptions {
    ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: "shop@2.4.1", adsConsent: consent)
  }

  func client(_ recorder: Recorder, consent: AdsConsent? = nil, installStore: any InstallRecordStore = MemoryInstallRecordStore(), token: @escaping AttributionTokenProvider = { "apple-token-1" }) -> ApphelmClient {
    ApphelmClient(options: options(recorder, consent: consent), session: recorder.session(), store: MemoryStore(), installStore: installStore, attributionToken: token)
  }

  func events(_ recorder: Recorder, _ name: String) -> [[String: Any]] {
    recorder.bodies.filter { $0["eventName"] as? String == name }.map { $0["properties"] as? [String: Any] ?? [:] }
  }

  @Test("Without ads consent no event carries $ad_consent")
  func noConsent() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder)
    #expect(apphelm.adsConsent == nil)
    apphelm.track("checkout_completed", properties: ["plan": "pro"])
    apphelm.screen("Cart")
    await apphelm.flush()
    #expect(recorder.bodies.count == 2)
    #expect(recorder.bodies.allSatisfy { ($0["properties"] as? [String: Any])?["$ad_consent"] == nil })
  }

  @Test("With ads consent every event carries $ad_consent; setAdsConsent(nil) removes it")
  func consentOnEveryEvent() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder, consent: .measurement)
    #expect(apphelm.adsConsent == .measurement)
    apphelm.track("checkout_completed")
    apphelm.screen("Cart")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-ad-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    apphelm.startSession(directory: folder)
    try await apphelm.captureException(NoToken())
    await apphelm.flush()
    let tx = apphelm.startTransaction("Checkout")
    await tx.finish()
    #expect(recorder.bodies.count == 5)
    #expect(recorder.bodies.allSatisfy { ($0["properties"] as? [String: Any])?["$ad_consent"] as? String == "measurement" })

    apphelm.setAdsConsent(.personalization)
    apphelm.track("upgraded")
    apphelm.setAdsConsent(nil)
    #expect(apphelm.adsConsent == nil)
    apphelm.track("downgraded")
    try await apphelm.captureException(NoToken())
    await apphelm.flush()
    #expect(events(recorder, "upgraded").first?["$ad_consent"] as? String == "personalization")
    #expect(events(recorder, "downgraded").first?.keys.contains("$ad_consent") == false)
    #expect(events(recorder, "$exception").last?.keys.contains("$ad_consent") == false)
  }

  @Test("Customer signals never carry $ad_consent: their shape is strict")
  func customerSignalsUntouched() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder, consent: .measurement)
    apphelm.track("apphelm.goal", properties: ["externalUserId": "usr_1"])
    try await apphelm.identify(externalUserId: "usr_1")
    await apphelm.flush()
    #expect(recorder.bodies.count == 2)
    #expect(recorder.bodies.allSatisfy { ($0["properties"] as? [String: Any])?["$ad_consent"] == nil })
  }

  @Test("$install is sent once across launches sharing a store")
  func installOnce() async throws {
    let recorder = Recorder()
    let store = MemoryInstallRecordStore()
    let first = client(recorder, installStore: store)
    #expect(await first.recordInstall(appVersion: "2.4.1"))
    #expect(await first.recordInstall(appVersion: "2.4.1") == false)
    await first.flush()
    // The next launch: a new client, the same store.
    let second = client(recorder, installStore: store)
    #expect(await second.recordInstall(appVersion: "2.4.1") == false)
    await second.flush()
    let installs = events(recorder, "$install")
    #expect(installs.count == 1)
    #expect(store.isInstallRecorded())
    #expect(installs.first?["platform"] as? String == adPlatform)
    #expect(installs.first?["app_version"] as? String == "2.4.1")
  }

  @Test("Without ads consent $install carries no $ad, $ad_consent or token, and the token is not fetched")
  func installWithoutConsent() async throws {
    let recorder = Recorder()
    let fetched = Counter()
    let apphelm = client(recorder, token: { fetched.increment(); return "apple-token-1" })
    #expect(await apphelm.recordInstall(appVersion: "1.0"))
    await apphelm.flush()
    let install = try #require(events(recorder, "$install").first)
    #expect(install["$ad"] == nil)
    #expect(install["$ad_consent"] == nil)
    #expect(fetched.value == 0)
  }

  @Test("With ads consent $install carries the Apple Ads token in $ad")
  func installWithConsent() async throws {
    let recorder = Recorder()
    let apphelm = client(recorder, consent: .personalization)
    #expect(await apphelm.recordInstall(appVersion: "1.0"))
    await apphelm.flush()
    let install = try #require(events(recorder, "$install").first)
    let ad = try #require(install["$ad"] as? [String: Any])
    #expect(ad["platform"] as? String == adPlatform)
    #expect(ad["apple_ads_token"] as? String == "apple-token-1")
    #expect(install["$ad_consent"] as? String == "personalization")
  }

  @Test("A token the system cannot give, or one that is too long, is left out")
  func tokenFailure() async throws {
    let recorder = Recorder()
    let failing = client(recorder, consent: .measurement, token: { throw NoToken() })
    #expect(await failing.recordInstall())
    let oversized = client(recorder, consent: .measurement, token: { String(repeating: "a", count: maxAppleAdsTokenLength + 1) })
    #expect(await oversized.recordInstall())
    await failing.flush()
    await oversized.flush()
    let installs = events(recorder, "$install")
    #expect(installs.count == 2)
    for install in installs {
      let ad = try #require(install["$ad"] as? [String: Any])
      #expect(ad["apple_ads_token"] == nil)
      #expect(ad["platform"] as? String == adPlatform)
      #expect(install["$ad_consent"] as? String == "measurement")
    }
  }

  @Test("The default install record persists in UserDefaults")
  func userDefaultsRecord() throws {
    let suite = "apphelm-install-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsInstallRecordStore(defaults: defaults)
    #expect(!store.isInstallRecorded())
    store.markInstallRecorded()
    #expect(UserDefaultsInstallRecordStore(defaults: defaults).isInstallRecorded())
    #expect(defaults.bool(forKey: "apphelm.installRecorded"))
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}
