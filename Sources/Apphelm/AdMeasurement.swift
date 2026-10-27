import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// What the person agreed to for ads, as your consent prompt recorded it. Apphelm takes your
/// word for it: asking, and what you ask, is the app's responsibility. While it is set, every
/// event carries `$ad_consent`, and `recordInstall` sends the install's ad evidence (`$ad`).
/// Without it nothing ad-related is collected or sent.
public enum AdsConsent: String, Sendable {
  /// Ads may be measured: installs and conversions are attributed to the ads that led to them.
  case measurement
  /// Measurement, and the ad platforms may also use it to personalise ads.
  case personalization
}

/// Remembers that `$install` was sent, so it is sent once per app install.
public protocol InstallRecordStore: Sendable {
  func isInstallRecorded() -> Bool
  func markInstallRecorded()
}

/// The default install record: a flag in UserDefaults (`apphelm.installRecorded`).
public final class UserDefaultsInstallRecordStore: InstallRecordStore, @unchecked Sendable {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "apphelm.installRecorded") {
    self.defaults = defaults
    self.key = key
  }

  public func isInstallRecorded() -> Bool { defaults.bool(forKey: key) }
  public func markInstallRecorded() { defaults.set(true, forKey: key) }
}

/// An install record that lasts as long as the process: for tests.
public final class MemoryInstallRecordStore: InstallRecordStore, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = false

  public init() {}

  public func isInstallRecorded() -> Bool { lock.withLock { recorded } }
  public func markInstallRecorded() { lock.withLock { recorded = true } }
}

/// The platform `$install` and `$ad` name.
let adPlatform: String = {
  #if os(macOS) || targetEnvironment(macCatalyst)
  return "macos"
  #elseif os(Linux)
  return "linux"
  #elseif os(Windows)
  return "windows"
  #else
  return "ios"
  #endif
}()

/// Customer signals have a strict shape on the server, so they never carry `$ad_consent`.
let customerSignalEvents: Set<String> = ["apphelm.identify", "apphelm.group", "apphelm.goal", "apphelm.outcome"]

/// The longest Apple Ads token sent; a longer one is not a token and is left out.
let maxAppleAdsTokenLength = 4096

/// Fetches the Apple Ads attribution token. It needs no App Tracking Transparency prompt and
/// reads no advertising identifier. Throws when the system has none to give.
typealias AttributionTokenProvider = @Sendable () async throws -> String?

let appleAdsAttributionToken: AttributionTokenProvider = {
  #if canImport(AdServices)
  return try AAAttribution.attributionToken()
  #else
  return nil
  #endif
}
