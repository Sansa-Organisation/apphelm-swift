import Foundation
import Testing

@testable import Apphelm

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      guard let handler = Self.handler else { throw URLError(.unknown) }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class MemoryStore: DistinctIdStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  func load() -> String? { lock.withLock { value } }
  func save(_ distinctId: String) { lock.withLock { value = distinctId } }
}

func stubbedSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
  StubURLProtocol.handler = handler
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return URLSession(configuration: configuration)
}

/// URLProtocol stubs receive POST bodies as a stream, not `httpBody`.
func requestJSON(_ request: URLRequest) throws -> [String: Any] {
  if let body = request.httpBody, !body.isEmpty {
    return try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
  }
  guard let stream = request.httpBodyStream else { throw URLError(.zeroByteResource) }
  stream.open()
  defer { stream.close() }
  var data = Data()
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
  defer { buffer.deallocate() }
  while stream.hasBytesAvailable {
    let count = stream.read(buffer, maxLength: 4096)
    if count <= 0 { break }
    data.append(buffer, count: count)
  }
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

func jsonResponse(url: URL, status: Int, body: [String: Any]) throws -> (HTTPURLResponse, Data) {
  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!
  return (response, try JSONSerialization.data(withJSONObject: body))
}

@Suite("Local flag evaluation")
struct LocalFlagTests {
  let config = FlagConfig(key: "new-checkout", rolloutPercent: 100, salt: "salt-1")

  @Test("Bucket matches the server assignment family")
  func bucketMatchesServer() {
    let bucket = assignmentBucket(flagKey: "new-checkout", distinctId: "user-42", salt: "salt-1")
    #expect(abs(bucket - 72.35737442970276) < 1e-9)
  }

  @Test("Active flag at full rollout is enabled")
  func enabledAtFullRollout() {
    let result = evaluateLocalFlag(config, distinctId: "user-42")
    #expect(result.enabled && result.reason == "enabled")
  }

  @Test("Bucket outside rollout is off")
  func offOutsideRollout() {
    let result = evaluateLocalFlag(config, distinctId: "user-42")
    #expect(result.enabled)
    let narrow = evaluateLocalFlag(FlagConfig(key: "new-checkout", rolloutPercent: 50, salt: "salt-1"), distinctId: "user-42")
    #expect(!narrow.enabled && narrow.reason == "rollout")
  }

  @Test("Killed and environment-gated flags stay off")
  func killedAndEnvironment() {
    #expect(evaluateLocalFlag(FlagConfig(key: "k", status: "killed", salt: "s"), distinctId: "u").reason == "killed")
    #expect(evaluateLocalFlag(FlagConfig(key: "k", environment: "production", salt: "s"), distinctId: "u", environment: "staging").reason == "environment_excluded")
    #expect(evaluateLocalFlag(FlagConfig(key: "k", environment: "production", salt: "s"), distinctId: "u", environment: "production").enabled)
  }

  @Test("Trait rules gate on profile traits")
  func traitRules() {
    let rules = [FlagRule(traitKey: "plan", op: .equals, value: .string("builder"))]
    let flag = FlagConfig(key: "k", rules: rules, salt: "s")
    #expect(!evaluateLocalFlag(flag, distinctId: "u", traits: ["plan": .string("free")]).enabled)
    #expect(evaluateLocalFlag(flag, distinctId: "u", traits: ["plan": .string("builder")]).enabled)
    #expect(!evaluateLocalFlag(flag, distinctId: "u").enabled)
  }

  @Test("Segment-targeted flags stay off instead of serving everyone in the rollout")
  func serverTargetingFailsClosed() {
    let segmented = FlagConfig(key: "k", rolloutPercent: 100, salt: "salt-1", requiresServerTargeting: true)
    let result = evaluateLocalFlag(segmented, distinctId: "user-42")
    #expect(!result.enabled && result.reason == "server_evaluation_required")
  }

  @Test("A config without an assignment salt stays off")
  func missingSaltFailsClosed() {
    let result = evaluateLocalFlag(FlagConfig(key: "k", rolloutPercent: 100, salt: ""), distinctId: "user-42")
    #expect(!result.enabled && result.reason == "missing_salt")
  }

  @Test("Numeric traits match a rule value sent as a string")
  func traitScalarsCompareAcrossTypes() {
    let flag = FlagConfig(key: "k", rules: [FlagRule(traitKey: "seats", op: .equals, value: .string("5"))], salt: "s")
    #expect(evaluateLocalFlag(flag, distinctId: "u", traits: ["seats": .number(5)]).enabled)
    #expect(!evaluateLocalFlag(flag, distinctId: "u", traits: ["seats": .number(6)]).enabled)
    let list = FlagConfig(key: "k", rules: [FlagRule(traitKey: "seats", op: .inch, value: .array([.string("4"), .string("5")]))], salt: "s")
    #expect(evaluateLocalFlag(list, distinctId: "u", traits: ["seats": .number(5)]).enabled)
  }

  @Test("Decoding a config defaults requiresServerTargeting and tolerates a missing salt")
  func decodesServerTargetingFlag() throws {
    let payload = Data(#"{"key":"k","flagType":"boolean","status":"active","rolloutPercent":100,"variants":[],"environment":null,"rules":[],"salt":"s","requiresServerTargeting":true}"#.utf8)
    let decoded = try JSONDecoder().decode(FlagConfig.self, from: payload)
    #expect(decoded.requiresServerTargeting)
    let without = try JSONDecoder().decode(FlagConfig.self, from: Data(#"{"key":"k","status":"active","rolloutPercent":100,"salt":"s"}"#.utf8))
    #expect(!without.requiresServerTargeting)
  }
}

@Suite("Client transport", .serialized)
struct ClientTests {
  func options() -> ApphelmOptions {
    ApphelmOptions(apiKey: "ahl_live_test", workspaceId: "org_1", productId: "prd_1", distinctId: "user-1")
  }

  @Test("Ingest posts to the events endpoint with a bearer key")
  func ingestPostsEvents() async throws {
    var observed: (url: String, auth: String?, eventName: String?)?
    let session = stubbedSession { request in
      let body = try requestJSON(request)
      observed = (request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "authorization"), (body["properties"] as? [String: Any])?["distinct_id"] as? String)
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    let client = ApphelmClient(options: options(), session: session, store: MemoryStore())
    client.track("signup_completed")
    await client.flush()
    #expect(observed?.url == "https://apphelm.dev/api/v1/events")
    #expect(observed?.auth == "Bearer ahl_live_test")
  }

  @Test("captureException sends a custom fingerprint")
  func captureExceptionFingerprint() async throws {
    struct PaymentTimeout: Error {}
    var fingerprint: [String]?
    let session = stubbedSession { request in
      let body = try requestJSON(request)
      fingerprint = (body["properties"] as? [String: Any])?["fingerprint"] as? [String]
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    let client = ApphelmClient(options: options(), session: session, store: MemoryStore())
    try await client.captureException(PaymentTimeout(), fingerprint: ["payments", "timeout"])
    #expect(fingerprint == ["payments", "timeout"])
  }

  @Test("Flag checks fail closed when the API is down")
  func failClosed() async throws {
    let up = stubbedSession { request in
      try jsonResponse(url: request.url!, status: 200, body: ["object": "flag_evaluations", "data": [["key": "new-checkout", "enabled": true, "variant": "on", "payload": true, "reason": "enabled"]], "failClosed": true])
    }
    let client = ApphelmClient(options: options(), session: up, store: MemoryStore())
    #expect(await client.isEnabled("new-checkout"))
    let down = stubbedSession { request in
      try jsonResponse(url: request.url!, status: 503, body: ["error": ["code": "unavailable", "message": "down"]])
    }
    let offline = ApphelmClient(options: options(), session: down, store: MemoryStore())
    #expect(await offline.isEnabled("new-checkout") == false)
  }

  @Test("An experiment flag check queues one exposure; a plain flag check queues none")
  func experimentExposure() async throws {
    let lock = NSLock()
    var exposures: [[String: Any]] = []
    let session = stubbedSession { request in
      if request.url?.path.hasSuffix("/flags/evaluate") == true {
        let key = try requestJSON(request)["flagKey"] as? String ?? ""
        return try jsonResponse(url: request.url!, status: 200, body: ["object": "flag_evaluations", "failClosed": true, "data": [
          key == "new-checkout"
            ? ["key": "new-checkout", "enabled": true, "variant": "test", "payload": NSNull(), "reason": "variant", "experiment": true]
            : ["key": key, "enabled": true, "variant": "on", "payload": true, "reason": "enabled"],
        ]])
      }
      let body = try requestJSON(request)
      if body["eventName"] as? String == "apphelm.flag_evaluated" { lock.withLock { exposures.append(body["properties"] as? [String: Any] ?? [:]) } }
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    let client = ApphelmClient(options: options(), session: session, store: MemoryStore())
    #expect(await client.isEnabled("new-checkout"))
    #expect(await client.isEnabled("new-checkout"))
    #expect(await client.isEnabled("dark-mode"))
    await client.flush()
    let sent = lock.withLock { exposures }
    #expect(sent.count == 1)
    #expect(sent.first?["flag_key"] as? String == "new-checkout")
    #expect(sent.first?["variant"] as? String == "test")
    #expect(sent.first?["distinct_id"] as? String == "user-1")
  }

  @Test("A failed flush retries only the events not yet accepted")
  func retryWithoutDuplicates() async throws {
    let lock = NSLock()
    var accepted: [String] = []
    var failNext = "second"
    let session = stubbedSession { request in
      let name = try requestJSON(request)["eventName"] as? String ?? ""
      let fail = lock.withLock { () -> Bool in
        if name == failNext { failNext = ""; return true }
        accepted.append(name)
        return false
      }
      return try jsonResponse(url: request.url!, status: fail ? 503 : 202, body: fail ? ["error": ["code": "unavailable", "message": "down"]] : ["accepted": true, "eventId": "evt_1"])
    }
    let client = ApphelmClient(options: options(), session: session, store: MemoryStore())
    client.track("first"); client.track("second"); client.track("third")
    await client.flush()
    await client.flush()
    #expect(lock.withLock { accepted } == ["first", "second", "third"])
  }

  @Test("A resend after a failure keeps the event's id and time")
  func resendKeepsEventId() async throws {
    let lock = NSLock()
    var bodies: [[String: Any]] = []
    var fail = true
    let session = stubbedSession { request in
      let body = try requestJSON(request)
      let failing = lock.withLock { () -> Bool in bodies.append(body); let now = fail; fail = false; return now }
      return try jsonResponse(url: request.url!, status: failing ? 503 : 202, body: failing ? ["error": ["code": "unavailable", "message": "down"]] : ["accepted": true, "eventId": "evt_1"])
    }
    let client = ApphelmClient(options: options(), session: session, store: MemoryStore())
    client.track("checkout_completed")
    await client.flush()
    await client.flush()
    let sent = lock.withLock { bodies }
    #expect(sent.count == 2)
    #expect((sent[0]["eventId"] as? String)?.isEmpty == false)
    #expect(sent[0]["eventId"] as? String == sent[1]["eventId"] as? String)
    #expect(sent[0]["occurredAt"] as? String == sent[1]["occurredAt"] as? String)
  }

  @Test("Distinct id persists through injected storage")
  func distinctIdPersists() async throws {
    let store = MemoryStore()
    let client = ApphelmClient(options: options(), session: .shared, store: store)
    #expect(client.distinctId == "user-1")
    let generated = ApphelmClient(options: ApphelmOptions(apiKey: "k", workspaceId: "o", productId: "p"), session: .shared, store: store)
    #expect(store.load() == generated.distinctId)
  }
}
