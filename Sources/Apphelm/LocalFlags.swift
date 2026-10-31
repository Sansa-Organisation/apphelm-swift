import CryptoKit
import Foundation

/// Minimal JSON value so flag payloads pass through without a dependency.
public enum JSONValue: Sendable, Equatable, Decodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null; return }
    if let value = try? container.decode(Bool.self) { self = .bool(value); return }
    if let value = try? container.decode(Double.self) { self = .number(value); return }
    if let value = try? container.decode(String.self) { self = .string(value); return }
    if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
    self = .object(try container.decode([String: JSONValue].self))
  }
}

public struct FlagVariant: Sendable, Decodable {
  public let key: String
  public let percent: Double
  public let payload: JSONValue?

  public init(key: String, percent: Double, payload: JSONValue? = nil) {
    self.key = key
    self.percent = percent
    self.payload = payload
  }
}

public struct FlagRule: Sendable, Decodable {
  public let traitKey: String
  public let op: Operator
  public let value: JSONValue

  public enum Operator: String, Sendable, Decodable {
    case equals
    case inch = "in"
  }

  private enum CodingKeys: String, CodingKey {
    case traitKey
    case op = "operator"
    case value
  }

  public init(traitKey: String, op: Operator, value: JSONValue) {
    self.traitKey = traitKey
    self.op = op
    self.value = value
  }
}

public struct FlagConfig: Sendable, Decodable {
  public let key: String
  public let flagType: String
  public let status: String
  public let rolloutPercent: Double
  public let variants: [FlagVariant]
  public let environment: String?
  public let rules: [FlagRule]
  public let salt: String
  /// Set by the API when the flag targets a saved segment, whose membership only the
  /// server can resolve. Local evaluation fails closed on these.
  public let requiresServerTargeting: Bool

  public init(key: String, flagType: String = "boolean", status: String = "active", rolloutPercent: Double = 100, variants: [FlagVariant] = [], environment: String? = nil, rules: [FlagRule] = [], salt: String, requiresServerTargeting: Bool = false) {
    self.key = key
    self.flagType = flagType
    self.status = status
    self.rolloutPercent = rolloutPercent
    self.variants = variants
    self.environment = environment
    self.rules = rules
    self.salt = salt
    self.requiresServerTargeting = requiresServerTargeting
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(String.self, forKey: .key)
    flagType = try container.decodeIfPresent(String.self, forKey: .flagType) ?? "boolean"
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "disabled"
    rolloutPercent = try container.decodeIfPresent(Double.self, forKey: .rolloutPercent) ?? 0
    variants = try container.decodeIfPresent([FlagVariant].self, forKey: .variants) ?? []
    environment = try container.decodeIfPresent(String.self, forKey: .environment)
    rules = try container.decodeIfPresent([FlagRule].self, forKey: .rules) ?? []
    salt = try container.decodeIfPresent(String.self, forKey: .salt) ?? ""
    requiresServerTargeting = try container.decodeIfPresent(Bool.self, forKey: .requiresServerTargeting) ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case key, flagType, status, rolloutPercent, variants, environment, rules, salt, requiresServerTargeting
  }
}

public struct FlagEvaluation: Sendable {
  public let key: String
  public let enabled: Bool
  public let variant: String?
  public let payload: JSONValue?
  public let reason: String
  /// `"boolean"`, `"multivariate"` or `"remote_config"`. `nil` when a server before 0.7.0
  /// answered, which did not say.
  public var flagType: String? = nil

  /// What `getFeatureFlag` answers: off, on (an enabled boolean or remote config flag) or the
  /// variant of a multivariate flag. Without a `flagType`, the variant `"on"` reads as on:
  /// that is what an enabled boolean flag serves.
  public var value: FlagValue {
    guard enabled else { return .disabled }
    switch flagType {
    case "multivariate": return variant.map(FlagValue.variant) ?? .enabled
    case "boolean", "remote_config": return .enabled
    default:
      if let variant, variant != "on" { return .variant(variant) }
      return .enabled
    }
  }
}

/// A flag's answer, as PostHog's `getFeatureFlag` gives it: `false`, `true`, or the variant.
public enum FlagValue: Sendable, Equatable {
  /// Off (the `control` variant counts as off), or not known: flags fail closed.
  case disabled
  /// An enabled boolean or remote config flag: PostHog's `true`.
  case enabled
  /// The variant of a multivariate flag.
  case variant(String)

  /// `true` unless the flag is off.
  public var isEnabled: Bool { self != .disabled }
  /// The variant, for a multivariate flag.
  public var variant: String? {
    if case .variant(let key) = self { return key }
    return nil
  }
  /// PostHog's shape: `false`, `true` or the variant string.
  public var anyValue: any Sendable {
    switch self {
    case .disabled: return false
    case .enabled: return true
    case .variant(let key): return key
    }
  }
}

/// Same assignment family as the server and every other SDK:
/// sha256(flagKey + NUL + distinctId + NUL + salt), first 4 bytes as a 0–100 bucket.
public func assignmentBucket(flagKey: String, distinctId: String, salt: String) -> Double {
  let input = Data("\(flagKey)\0\(distinctId)\0\(salt)".utf8)
  let digest = SHA256.hash(data: input)
  let prefix = digest.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  return Double(prefix) / 4_294_967_296.0 * 100.0
}

private func off(_ flag: FlagConfig, reason: String) -> FlagEvaluation {
  FlagEvaluation(key: flag.key, enabled: false, variant: flag.flagType == "multivariate" ? "control" : nil, payload: nil, reason: reason, flagType: flag.flagType)
}

/// Mirrors the server's scalar comparison so `42` and `"42"` target the same profile:
/// traits are written by many sources and their JSON types differ.
private func sameTraitScalar(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
  if actual == expected { return true }
  func text(_ value: JSONValue) -> String? {
    switch value {
    case .string(let inner): return inner
    case .bool(let inner): return inner ? "true" : "false"
    case .number(let inner): return inner == inner.rounded() && abs(inner) < 1e15 ? String(Int64(inner)) : String(inner)
    default: return nil
    }
  }
  guard let left = text(actual), let right = text(expected) else { return false }
  return left == right
}

/// Pure local evaluation. Mirrors the server. Fail-closed on any doubt.
public func evaluateLocalFlag(_ flag: FlagConfig, distinctId: String, environment: String? = nil, traits: [String: JSONValue]? = nil) -> FlagEvaluation {
  guard flag.status == "active" else { return off(flag, reason: flag.status.isEmpty ? "disabled" : flag.status) }
  // Segment membership is server state. Treating a segment-targeted flag as untargeted
  // here would switch it on for everyone inside the rollout.
  if flag.requiresServerTargeting { return off(flag, reason: "server_evaluation_required") }
  if flag.salt.isEmpty { return off(flag, reason: "missing_salt") }
  if let required = flag.environment, required != environment { return off(flag, reason: "environment_excluded") }
  for rule in flag.rules {
    guard let actual = traits?[rule.traitKey] else { return off(flag, reason: "rule_excluded") }
    let match: Bool
    switch (rule.op, rule.value) {
    case (.inch, .array(let candidates)): match = candidates.contains { sameTraitScalar(actual, $0) }
    default: match = sameTraitScalar(actual, rule.value)
    }
    if !match { return off(flag, reason: "rule_excluded") }
  }
  let bucket = assignmentBucket(flagKey: flag.key, distinctId: distinctId, salt: flag.salt)
  if bucket >= flag.rolloutPercent { return off(flag, reason: "rollout") }
  if flag.flagType == "boolean" || flag.variants.isEmpty {
    return FlagEvaluation(key: flag.key, enabled: true, variant: "on", payload: .bool(true), reason: "enabled", flagType: "boolean")
  }
  var cursor = 0.0
  for variant in flag.variants {
    cursor += max(0, variant.percent)
    if bucket < cursor / 100.0 * flag.rolloutPercent || cursor >= 100 {
      return FlagEvaluation(key: flag.key, enabled: variant.key != "control", variant: variant.key, payload: variant.payload, reason: "variant", flagType: "multivariate")
    }
  }
  let fallback = flag.variants[0]
  return FlagEvaluation(key: flag.key, enabled: fallback.key != "control", variant: fallback.key, payload: fallback.payload, reason: "variant", flagType: "multivariate")
}
