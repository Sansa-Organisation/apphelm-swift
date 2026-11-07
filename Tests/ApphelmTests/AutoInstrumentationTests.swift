import CoreData
import Foundation
import Testing

@testable import Apphelm

private func spans(_ properties: [String: Any]) -> [[String: Any]] {
  guard let text = properties["spans"] as? String, let data = text.data(using: .utf8) else { return [] }
  return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
}

/// The headers each path of a test host received.
final class HeaderLog: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [String: String] = [:]
  func note(_ path: String, _ value: String) { lock.withLock { seen[path] = value } }
  var all: [String: String] { lock.withLock { seen } }
}

/// The swizzles are process-wide, so each test's client records only its own hosts' calls,
/// and every check filters by those hosts.
@Suite("Automatic URLSession, file I/O and Core Data spans", .serialized)
struct AutoInstrumentationTests {
  func options(_ recorder: Recorder, rate: Double? = 1, hosts: [String] = []) -> ApphelmOptions {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", tracesSampleRate: rate, tracePropagationHosts: hosts).quiet
    options.enableNetworkTracking = true
    options.enableNetworkBreadcrumbs = true
    options.enableFileIOTracing = true
    options.enableCoreDataTracing = true
    return options
  }

  func apiHost(_ log: HeaderLog) -> String {
    let host = "auto-\(UUID().uuidString.lowercased()).test"
    RoutedURLProtocol.register(host: host) { request in
      log.note(request.url!.path, request.value(forHTTPHeaderField: "traceparent") ?? "none")
      if request.url?.path == "/down" { throw URLError(.notConnectedToInternet) }
      return try jsonResponse(url: request.url!, status: request.url?.path == "/missing" ? 404 : 200, body: ["ok": true])
    }
    return host
  }

  func routedSession(delegate: URLSessionDelegate? = nil) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  func hostSpans(_ recorder: Recorder, _ host: String) -> [[String: Any]] {
    recorder.bodies.filter { $0["eventName"] as? String == "$transaction" }.flatMap { spans($0["properties"] as? [String: Any] ?? [:]) }
      .filter { (($0["description"] as? String) ?? "").contains(host) }
  }

  @Test("Every URLSession request is an http.client span of the active transaction; traceparent goes to listed hosts only")
  func sessionRequests() async throws {
    let recorder = Recorder(), log = HeaderLog()
    let api = apiHost(log), other = apiHost(log)
    let client = ApphelmClient(options: options(recorder, hosts: [api]), session: recorder.session(), store: MemoryStore())
    let session = routedSession()
    let tx = client.startTransaction("Checkout", op: "ui.load")
    _ = try await session.data(from: URL(string: "https://user:pw@\(api)/cart?token=abc123")!)
    var post = URLRequest(url: URL(string: "https://\(api)/missing")!)
    post.httpMethod = "POST"
    _ = try await session.data(for: post)
    await #expect(throws: URLError.self) { _ = try await session.data(from: URL(string: "https://\(api)/down")!) }
    _ = try await session.data(from: URL(string: "https://\(other)/x")!)
    // A completion-handler task records the same way.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      session.dataTask(with: URL(string: "https://\(api)/handler")!) { _, _, _ in done.resume() }.resume()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await tx.finish())
    let mine = hostSpans(recorder, api)
    #expect(mine.map { $0["description"] as? String }.sorted { ($0 ?? "") < ($1 ?? "") } == ["GET https://\(api)/cart", "GET https://\(api)/down", "GET https://\(api)/handler", "POST https://\(api)/missing"])
    let cart = try #require(mine.first { $0["description"] as? String == "GET https://\(api)/cart" })
    #expect(cart["op"] as? String == "http.client" && cart["status"] as? String == "ok")
    let data = try #require(cart["data"] as? [String: Any])
    #expect(data["http.response.status_code"] as? Int == 200 && data["url.full"] as? String == "https://\(api)/cart" && data["server.address"] as? String == api)
    #expect(mine.first { $0["description"] as? String == "POST https://\(api)/missing" }?["status"] as? String == "error")
    #expect(mine.first { $0["description"] as? String == "GET https://\(api)/down" }?["status"] as? String == "error")
    // The header named the span that measured the request.
    let parent = try #require(parseTraceparent(log.all["/cart"]))
    #expect(parent.traceId == tx.traceId && parent.parentSpanId == cart["span_id"] as? String)
    #expect(log.all["/x"] == "none")
    #expect(hostSpans(recorder, other).count == 1)
    // Apphelm's own requests are never spans.
    #expect(hostSpans(recorder, recorder.host).isEmpty)
  }

  @Test("Without a trace sample rate requests leave breadcrumbs but no spans; data(for:) and the delegate aren't recorded twice")
  func breadcrumbsAndDedupe() async throws {
    let recorder = Recorder(), log = HeaderLog()
    let api = apiHost(log)
    let client = ApphelmClient(options: options(recorder, rate: nil), session: recorder.session(), store: MemoryStore())
    let session = routedSession()
    _ = try await session.data(from: URL(string: "https://\(api)/a?secret=1")!)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(client.currentBreadcrumbs.filter { $0.message.contains(api) }.map(\.message) == ["GET https://\(api)/a 200"])

    // A transaction of your own still gets the wrapper's span, once, and the delegate's, once.
    let tx = client.startTransaction("Sync")
    _ = try await client.data(for: URLRequest(url: URL(string: "https://\(api)/wrapped")!), session: session)
    let delegated = routedSession(delegate: client.httpSpanDelegate())
    _ = try await delegated.data(from: URL(string: "https://\(api)/delegated")!)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await tx.finish())
    #expect(hostSpans(recorder, api).compactMap { $0["description"] as? String }.sorted() == ["GET https://\(api)/delegated", "GET https://\(api)/wrapped"])
    let crumbs = client.currentBreadcrumbs.filter { $0.message.contains(api) }.map(\.message)
    #expect(crumbs == ["GET https://\(api)/a 200", "GET https://\(api)/wrapped 200", "GET https://\(api)/delegated 200"])
  }

  @Test("enableNetworkTracking and enableSwizzling off record nothing")
  func optOut() async throws {
    let recorder = Recorder(), log = HeaderLog()
    let api = apiHost(log)
    var off = options(recorder)
    off.enableSwizzling = false
    let client = ApphelmClient(options: off, session: recorder.session(), store: MemoryStore())
    let tx = client.startTransaction("Sync")
    _ = try await routedSession().data(from: URL(string: "https://\(api)/a")!)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await tx.finish())
    #expect(hostSpans(recorder, api).isEmpty)
    #expect(client.currentBreadcrumbs.filter { $0.message.contains(api) }.isEmpty)
  }

  // MARK: File I/O

  func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name)
  }

  func fileSpans(_ recorder: Recorder, _ marker: String) -> [[String: Any]] {
    recorder.bodies.filter { $0["eventName"] as? String == "$transaction" }.flatMap { spans($0["properties"] as? [String: Any] ?? [:]) }
      .filter { ((($0["data"] as? [String: Any])?["file.path"] as? String) ?? "").contains(marker) }
  }

  @Test("NSData reads and writes are file.read / file.write spans with the file's name, size and path")
  func fileSpans() async throws {
    let recorder = Recorder()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let marker = UUID().uuidString
    let file = tempFile("cart-\(marker).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let tx = client.startTransaction("Load")
    let bytes = Data(repeating: 7, count: 1_500) as NSData
    #expect(bytes.write(toFile: file.path, atomically: true))
    try bytes.write(to: file, options: [])
    #expect(NSData(contentsOfFile: file.path)?.length == 1_500)
    #expect(try NSData(contentsOf: file, options: []).length == 1_500)
    #expect(NSData(contentsOfFile: file.path + ".missing") == nil)
    // Swift's own Data, through the explicit methods.
    try Data([1, 2, 3]).writeWithApphelmTracing(to: file, client: client)
    #expect(try Data(contentsOfWithApphelmTracing: file, client: client).count == 3)
    #expect(await tx.finish())
    let recorded = fileSpans(recorder, marker)
    #expect(recorded.map { $0["op"] as? String } == ["file.write", "file.write", "file.read", "file.read", "file.read", "file.write", "file.read"])
    let first = try #require(recorded.first)
    #expect(first["description"] as? String == "cart-\(marker).json (1.5 KB)")
    let data = try #require(first["data"] as? [String: Any])
    #expect(data["file.size"] as? Int == 1_500)
    #expect(data["blocked_main_thread"] as? Bool == false)
    #expect(recorded[4]["status"] as? String == "error")
    #expect(recorded.last?["description"] as? String == "cart-\(marker).json (3 bytes)")
  }

  @Test("Apphelm's own files are never file spans, and sizes read as Sentry writes them")
  func ownFilesAndSizes() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    #expect(FileIOInstrumentation.isOwn(caches.appendingPathComponent("Apphelm/scope-active.json").path))
    #expect(!FileIOInstrumentation.isOwn(caches.appendingPathComponent("ApphelmOther/x").path))
    #expect(FileIOInstrumentation.byteCount(1) == "1 byte")
    #expect(FileIOInstrumentation.byteCount(512) == "512 bytes")
    #expect(FileIOInstrumentation.byteCount(1_024) == "1 KB")
    #expect(FileIOInstrumentation.byteCount(3_565_158) == "3.4 MB")
  }

  // MARK: Core Data

  func container() throws -> NSPersistentContainer {
    let model = NSManagedObjectModel()
    let order = NSEntityDescription()
    order.name = "Order"
    order.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    let status = NSAttributeDescription()
    status.name = "status"
    status.attributeType = .stringAttributeType
    order.properties = [status]
    model.entities = [order]
    let container = NSPersistentContainer(name: "Shop-\(UUID().uuidString)", managedObjectModel: model)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    var failure: Error?
    container.loadPersistentStores { _, error in failure = error }
    if let failure { throw failure }
    return container
  }

  @Test("Core Data saves are db.sql.transaction spans and fetches db.sql.query spans, as Sentry describes them")
  func coreData() async throws {
    let recorder = Recorder()
    let client = ApphelmClient(options: options(recorder), session: recorder.session(), store: MemoryStore())
    let store = try container()
    let context = store.newBackgroundContext()
    let tx = client.startTransaction("Orders")
    try context.performAndWait {
      for value in ["open", "open", "paid"] {
        let item = NSEntityDescription.insertNewObject(forEntityName: "Order", into: context)
        item.setValue(value, forKey: "status")
      }
      try context.save()
      // Nothing to save: no span.
      try context.save()
      let request = NSFetchRequest<NSManagedObject>(entityName: "Order")
      request.predicate = NSPredicate(format: "status == %@", "open")
      request.sortDescriptors = [NSSortDescriptor(key: "status", ascending: false)]
      #expect(try context.fetch(request).count == 2)
    }
    #expect(await tx.finish())
    let recorded = recorder.bodies.filter { $0["eventName"] as? String == "$transaction" && ($0["properties"] as? [String: Any])?["name"] as? String == "Orders" }
      .flatMap { spans($0["properties"] as? [String: Any] ?? [:]) }.filter { ($0["op"] as? String)?.hasPrefix("db.") == true }
    #expect(recorded.map { $0["op"] as? String } == ["db.sql.transaction", "db.sql.query"])
    #expect(recorded.first?["description"] as? String == "INSERTED 3 'Order'")
    #expect((recorded.first?["data"] as? [String: Any])?["operations"] as? String == #"{"INSERTED":{"Order":3}}"#)
    #expect(recorded.last?["description"] as? String == #"SELECT 'Order' WHERE status == "open" SORT BY status DESCENDING"#)
    let fetch = try #require(recorded.last?["data"] as? [String: Any])
    #expect(fetch["read_count"] as? Int == 2 && fetch["db.system"] as? String == "InMemory")
  }
}
