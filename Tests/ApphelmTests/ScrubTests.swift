import Foundation
import Testing

@testable import Apphelm

private struct Vector: Decodable {
  let fn: String
  let input: String
  let expected: String
}

private struct Vectors: Decodable {
  let vectors: [Vector]
}

private func scrubFolder() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-scrub-tests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// What `beforeSend` was given, by event name.
private final class Offered: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [[String: Any]] = []
  func add(_ properties: [String: Any]) { lock.withLock { seen.append(properties) } }
  func named(_ name: String) -> [[String: Any]] { lock.withLock { seen.filter { $0["$event_name"] as? String == name } } }
}

private struct LeakyError: Error, CustomStringConvertible {
  var description: String { "login failed for bob@example.com with key ahl_live_abcdefgh12345678" }
}

@Suite("Scrubbing secrets and emails before beforeSend")
struct ScrubTests {
  @Test("Every shared vector (packages/sdk-fixtures/scrub-vectors.json) gives its expected output")
  func sharedVectors() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/scrub-vectors.json")
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file)).vectors
    #expect(vectors.count == 76)
    #expect(vectors.filter { $0.fn == "description" }.count == 9)
    for vector in vectors {
      let actual: String
      switch vector.fn {
      case "text": actual = scrubText(vector.input)
      case "frame": actual = scrubFrame(vector.input)
      case "url": actual = scrubUrl(vector.input)
      case "description": actual = scrubDescription(vector.input)
      default: Issue.record("unknown fn \(vector.fn)"); continue
      }
      #expect(actual == vector.expected, "\(vector.fn): \(vector.input)")
    }
  }

  fileprivate func options(_ recorder: Recorder, _ offered: Offered) -> ApphelmOptions {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: "ios@3.0.0", environment: "production").quiet
    options.beforeSend = { properties in
      offered.add(properties)
      return properties
    }
    return options
  }

  fileprivate func client(_ recorder: Recorder, _ offered: Offered) -> ApphelmClient {
    ApphelmClient(options: options(recorder, offered), session: recorder.session(), store: MemoryStore(), installStore: nil, attributionToken: { nil }, appInfo: AppInfo(version: "3.0.0", build: "300"), frames: FrameStats(), crashScope: CrashScopeStore())
  }

  @Test("An exception's message, tags and breadcrumbs arrive scrubbed, and beforeSend sees them scrubbed")
  func exceptionScrubbed() async throws {
    let recorder = Recorder()
    let offered = Offered()
    let apphelm = client(recorder, offered)
    apphelm.setTag("contact", "ops@example.com")
    apphelm.addBreadcrumb(category: "auth", message: "Signed in with password=hunter22 as jo@example.com")
    apphelm.addBreadcrumb(category: "http", message: "GET https://api.example.com/v1/cart?token=abc 200")
    #expect(try await apphelm.captureException(LeakyError(), tags: ["header": "Bearer abcdefghijklmnop"]))

    let sent = try #require(recorder.bodies.first?["properties"] as? [String: Any])
    let hooked = try #require(offered.named("$exception").first)
    for properties in [sent, hooked] {
      #expect(properties["message"] as? String == "login failed for [email] with key [key]")
      #expect(properties["name"] as? String == "LeakyError")
      #expect(properties["tags"] as? [String: String] == ["contact": "[email]", "header": "Bearer [redacted]"])
      #expect((properties["breadcrumbs"] as? [[String: String]])?.map { $0["message"] ?? "" } == ["Signed in with password=[redacted] as [email]", "GET https://api.example.com/v1/cart 200"])
      #expect(properties["distinct_id"] as? String == "user-1" && properties["release"] as? String == "ios@3.0.0")
    }
  }

  @Test("captureMessage text is scrubbed before beforeSend, and cut to 240 after scrubbing")
  func messageScrubbed() async throws {
    let recorder = Recorder()
    let offered = Offered()
    let apphelm = client(recorder, offered)
    #expect(try await apphelm.captureMessage("Webhook signed with sk_live_0123456789abcdef for a@b.io"))
    #expect(offered.named("$exception").first?["message"] as? String == "Webhook signed with [key] for [email]")
    #expect(recorder.properties(0)["message"] as? String == "Webhook signed with [key] for [email]")
    // A key straddling the cap is replaced whole, not cut into a leak.
    #expect(try await apphelm.captureMessage(String(repeating: "x", count: 230) + " ahl_live_abcdefgh12345678"))
    #expect(recorder.properties(1)["message"] as? String == String(repeating: "x", count: 230) + " [key]")
  }

  @Test("A crash report's reason and frames are scrubbed when it is sent, before beforeSend; debug images are not")
  func crashReportScrubbed() async throws {
    let directory = scrubFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = ["name": "Shop", "uuid": "0123456789ABCDEF0123456789ABCDEF", "base": "0x100000000", "slide": "0x0"]
    let report: [String: Any] = [
      "kind": "nsexception",
      "name": "NSInvalidArgumentException",
      "reason": "bad token=abcdef123456 for carol@example.com",
      "stack": ["0   Shop   0x0000000100003f00 openURL https://x.test/a?sig=secret&u=dan@example.com + 32", "1   Shop   0x0000000100003f80 main + 8"],
      "images": [image],
    ]
    try JSONSerialization.data(withJSONObject: report).write(to: directory.appendingPathComponent("crash-exception-\(UUID().uuidString).json"))
    try Data("\(CrashStore.signalPrefix)11 SIGSEGV\n0   Shop   0x0000000100003f00 load?user=erin@example.com + 4\n".utf8).write(to: directory.appendingPathComponent("crash-\(UUID().uuidString).log"))

    let recorder = Recorder()
    let offered = Offered()
    let apphelm = client(recorder, offered)
    #expect(await apphelm.sendPendingCrashReports(directory: directory) == 2)
    let hooked = offered.named("$exception")
    #expect(hooked.count == 2)
    let exception = try #require(hooked.first { $0["name"] as? String == "NSInvalidArgumentException" })
    #expect(exception["message"] as? String == "bad token=[redacted] for [email]")
    #expect(exception["stack"] as? String == "0   Shop   0x0000000100003f00 openURL https://x.test/a + 32\n1   Shop   0x0000000100003f80 main + 8")
    #expect(exception["debug_images"] as? [[String: String]] == [image])
    let signal = try #require(hooked.first { $0["name"] as? String == "SIGSEGV" })
    #expect(signal["stack"] as? String == "0   Shop   0x0000000100003f00 load + 4")
    #expect(recorder.bodies.compactMap { ($0["properties"] as? [String: Any])?["stack"] as? String }.allSatisfy { !$0.contains("@") && !$0.contains("?") })
  }

  @Test("Transaction names, span descriptions and data are scrubbed; SQL keeps its ? placeholders; url.full loses its query and user info")
  func spansScrubbed() async throws {
    let recorder = Recorder()
    let offered = Offered()
    let apphelm = client(recorder, offered)
    let transaction = apphelm.startTransaction("Sync for frank@example.com", op: "task")
    transaction.setData("note", "api_key=abcd1234efgh")
    let span = transaction.startSpan("http.client", description: "GET https://api.example.com/v1/items?token=abc", data: ["url.full": "https://user:pw@api.example.com/v1/items?token=abc#top", "db.statement": "select * where email = 'gina@example.com'"])
    span.setData("http.url", "https://api.example.com/v2?key=1")
    span.finish()
    // SQL keeps its `?` placeholders; the rest of the description is still scrubbed.
    transaction.startSpan("db.sql.query", description: "SELECT * FROM users WHERE id = ? AND email = 'hal@example.com'").finish()
    #expect(await transaction.finish())

    let hooked = try #require(offered.named("$transaction").first)
    let sent = recorder.properties(0)
    for properties in [hooked, sent] {
      #expect(properties["name"] as? String == "Sync for [email]")
      #expect(properties["data"] as? [String: String] == ["note": "api_key=[redacted]"])
      let spans = (try? JSONSerialization.jsonObject(with: Data(((properties["spans"] as? String) ?? "[]").utf8)) as? [[String: Any]]) ?? []
      let first = try #require(spans.first)
      #expect(first["description"] as? String == "GET https://api.example.com/v1/items")
      #expect(first["data"] as? [String: String] == ["url.full": "https://api.example.com/v1/items", "http.url": "https://api.example.com/v2", "db.statement": "select * where email = '[email]'"])
      #expect(spans.dropFirst().first?["description"] as? String == "SELECT * FROM users WHERE id = ? AND email = '[email]'")
    }
    #expect(sent["trace_id"] as? String == transaction.traceId)
  }
}
