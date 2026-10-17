import Darwin
import Foundation
import Testing

@testable import Apphelm

/// Crash handlers are process-wide and install once, so every crash test shares one folder.
let crashFolder: URL = {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apphelm-crash-tests-\(getpid())", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  return folder
}()

func clearCrashFolder() {
  for name in (try? FileManager.default.contentsOfDirectory(atPath: crashFolder.path)) ?? [] where name != CrashStore.activeFile {
    try? FileManager.default.removeItem(at: crashFolder.appendingPathComponent(name))
  }
}

// In the serialized transport suite: the stub URL protocol's handler is shared state.
extension ClientTests {
  func releaseOptions() -> ApphelmOptions {
    ApphelmOptions(apiKey: "ahl_live_test", workspaceId: "org_1", productId: "prd_1", distinctId: "user-1", release: "ios@2.3.0", environment: "production")
  }

  @Test("captureException sends release, environment, tags, handled and the call-site stack")
  func captureExceptionContext() async throws {
    struct CheckoutFailed: Error {}
    var properties: [String: Any] = [:]
    let session = stubbedSession { request in
      properties = (try requestJSON(request)["properties"] as? [String: Any]) ?? [:]
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    let client = ApphelmClient(options: releaseOptions(), session: session, store: MemoryStore())
    try await client.captureException(CheckoutFailed(), tags: ["screen": "checkout"], handled: false)
    #expect(properties["release"] as? String == "ios@2.3.0")
    #expect(properties["environment"] as? String == "production")
    #expect(properties["tags"] as? [String: String] == ["screen": "checkout"])
    #expect(properties["handled"] as? Bool == false)
    let stack = try #require(properties["stack"] as? String)
    // The capturing test is in the stack; Apphelm's own frames are not at its top.
    #expect(stack.contains("captureExceptionContext"))
    #expect(!(stack.split(separator: "\n").first ?? "").contains("$s7Apphelm"))
    try await client.captureException(CheckoutFailed())
    #expect(properties["handled"] == nil)
  }

  @Test("A fatal signal written during a crash is sent as an unhandled exception on the next launch")
  func signalReportIsSentNextLaunch() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    try CrashInstaller.openActiveFile(directory: crashFolder)
    writeSignalReport(SIGSEGV)
    // What the next launch's install does before opening a fresh file.
    try CrashInstaller.moveAsideActiveReport(directory: crashFolder)
    try CrashInstaller.openActiveFile(directory: crashFolder)
    #expect(CrashInstaller.pendingReports(directory: crashFolder).count == 1)
    var sent: [[String: Any]] = []
    let session = stubbedSession { request in
      sent.append((try requestJSON(request)["properties"] as? [String: Any]) ?? [:])
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    let client = ApphelmClient(options: releaseOptions(), session: session, store: MemoryStore())
    #expect(await client.sendPendingCrashReports(directory: crashFolder) == 1)
    let crash = try #require(sent.first)
    #expect(crash["name"] as? String == "SIGSEGV")
    #expect(crash["message"] as? String == "The app crashed with SIGSEGV")
    #expect(crash["handled"] as? Bool == false)
    #expect(crash["release"] as? String == "ios@2.3.0")
    #expect(crash["distinct_id"] as? String == "user-1")
    #expect(crash["tags"] as? [String: String] == ["mechanism": "signal"])
    let stack = try #require(crash["stack"] as? String)
    // The frames that wrote the report are dropped, so the crash site leads.
    #expect(!stack.isEmpty)
    #expect(!(stack.split(separator: "\n").first ?? "").contains("writeSignalReport"))
    #expect(stack.contains("signalReportIsSentNextLaunch"))
    #expect(CrashInstaller.pendingReports(directory: crashFolder).isEmpty)
  }

  @Test("A real fatal signal in a child process leaves a report and still kills the process")
  func realSignalIsRecorded() throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    try CrashInstaller.moveAsideActiveReport(directory: crashFolder)
    clearCrashFolder()
    try CrashInstaller.openActiveFile(directory: crashFolder)
    // The child inherits the installed handler and the open report file, and only makes
    // async-signal-safe calls before it dies. Swift marks fork() unavailable, so the test
    // looks it up directly; it runs only here, never in the SDK.
    typealias Fork = @convention(c) () -> pid_t
    let fork = unsafeBitCast(try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork")), to: Fork.self)
    let child = fork()
    if child == 0 { raise(SIGBUS); _exit(0) }
    #expect(child > 0)
    var status: Int32 = 0
    waitpid(child, &status, 0)
    let exitedNormally = (status & 0x7f) == 0
    #expect(!exitedNormally)
    try CrashInstaller.moveAsideActiveReport(directory: crashFolder)
    let reports = CrashInstaller.pendingReports(directory: crashFolder)
    #expect(reports.count == 1)
    let properties = try #require(reports.first.flatMap { CrashInstaller.exceptionProperties(report: $0) })
    #expect(properties["name"] as? String == "SIGBUS")
    #expect(!((properties["stack"] as? String) ?? "").isEmpty)
    clearCrashFolder()
    try CrashInstaller.openActiveFile(directory: crashFolder)
  }

  @Test("An uncaught NSException is recorded and sent; a report that fails to send is kept")
  func exceptionReportIsKeptUntilSent() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    writeExceptionReport(NSException(name: .invalidArgumentException, reason: "-[NSNull length]: unrecognized selector", userInfo: nil))
    #expect(CrashInstaller.pendingReports(directory: crashFolder).count == 1)
    let down = stubbedSession { request in try jsonResponse(url: request.url!, status: 503, body: ["error": ["code": "unavailable", "message": "down"]]) }
    #expect(await ApphelmClient(options: releaseOptions(), session: down, store: MemoryStore()).sendPendingCrashReports(directory: crashFolder) == 0)
    #expect(CrashInstaller.pendingReports(directory: crashFolder).count == 1)
    var sent: [String: Any] = [:]
    let up = stubbedSession { request in
      sent = (try requestJSON(request)["properties"] as? [String: Any]) ?? [:]
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    #expect(await ApphelmClient(options: releaseOptions(), session: up, store: MemoryStore()).sendPendingCrashReports(directory: crashFolder) == 1)
    #expect(sent["name"] as? String == "NSInvalidArgumentException")
    #expect(sent["message"] as? String == "-[NSNull length]: unrecognized selector")
    #expect(sent["tags"] as? [String: String] == ["mechanism": "nsexception"])
    #expect(CrashInstaller.pendingReports(directory: crashFolder).isEmpty)
  }

  @Test("captureException names the images its frames are in, with their UUIDs and load addresses")
  func captureExceptionImages() async throws {
    struct CheckoutFailed: Error {}
    var properties: [String: Any] = [:]
    let session = stubbedSession { request in
      properties = (try requestJSON(request)["properties"] as? [String: Any]) ?? [:]
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    try await ApphelmClient(options: releaseOptions(), session: session, store: MemoryStore()).captureException(CheckoutFailed())
    let images = try #require(properties["debug_images"] as? [[String: String]])
    let stack = try #require(properties["stack"] as? String)
    #expect(!images.isEmpty && images.count <= DebugImages.maxPerReport)
    // The frame of this test: its image is listed, and its address lies above the load
    // address the report gives for that image, which is what the server subtracts.
    let frame = try #require(stack.split(separator: "\n").map(String.init).first { $0.contains("captureExceptionImages") })
    let name = try #require(DebugImages.imageName(inFrame: frame))
    let image = try #require(images.first { $0["name"] == name })
    #expect(UUID(uuidString: image["uuid"] ?? "") != nil)
    let base = try #require(UInt64((image["base"] ?? "").dropFirst(2), radix: 16))
    let slide = try #require(UInt64((image["slide"] ?? "").dropFirst(2), radix: 16))
    let hex = try #require(frame.split(separator: " ").first { $0.hasPrefix("0x") })
    let address = try #require(UInt64(hex.dropFirst(2), radix: 16))
    #expect(address > base && address - base < 1 << 32)
    #expect(slide <= base)
    // Only images the stack names are sent, each once.
    #expect(Set(images.compactMap { $0["name"] }).count == images.count)
    #expect(images.allSatisfy { image in stack.contains(image["name"] ?? "\u{0}") })
  }

  @Test("A signal report carries the images of the run that crashed, not of the run that sends it")
  func signalReportImages() async throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    try CrashInstaller.openActiveFile(directory: crashFolder)
    // The crashed run saw this test binary loaded somewhere else (another ASLR slide).
    var crashedRun = DebugImages.loaded()
    #expect(crashedRun.count > DebugImages.maxPerReport)
    for index in crashedRun.indices { crashedRun[index]["base"] = "0x7000" + String(index, radix: 16) }
    CrashInstaller.writeActiveImages(directory: crashFolder, images: crashedRun)
    writeSignalReport(SIGSEGV)
    try CrashInstaller.moveAsideActiveReport(directory: crashFolder)
    try CrashInstaller.openActiveFile(directory: crashFolder)
    CrashInstaller.writeActiveImages(directory: crashFolder)
    let report = try #require(CrashInstaller.pendingReports(directory: crashFolder).first)
    let sidecar = try #require(CrashInstaller.imagesFile(for: report))
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
    var sent: [String: Any] = [:]
    let session = stubbedSession { request in
      sent = (try requestJSON(request)["properties"] as? [String: Any]) ?? [:]
      return try jsonResponse(url: request.url!, status: 202, body: ["accepted": true, "eventId": "evt_1"])
    }
    #expect(await ApphelmClient(options: releaseOptions(), session: session, store: MemoryStore()).sendPendingCrashReports(directory: crashFolder) == 1)
    let images = try #require(sent["debug_images"] as? [[String: String]])
    let stack = try #require(sent["stack"] as? String)
    #expect(!images.isEmpty && images.count <= DebugImages.maxPerReport)
    #expect(images.allSatisfy { ($0["base"] ?? "").hasPrefix("0x7000") })
    #expect(images.allSatisfy { image in stack.contains(image["name"] ?? "\u{0}") })
    // The image list goes when its report does; this run's own list stays for its crash.
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    #expect(FileManager.default.fileExists(atPath: crashFolder.appendingPathComponent(CrashStore.activeImagesFile).path))
    #expect(CrashInstaller.pendingReports(directory: crashFolder).isEmpty)
  }

  @Test("An uncaught NSException's report names its images; an image name may hold spaces")
  func exceptionReportImages() throws {
    try CrashInstaller.install(directory: crashFolder)
    clearCrashFolder()
    writeExceptionReport(NSException(name: .invalidArgumentException, reason: "bad", userInfo: nil))
    let report = try #require(CrashInstaller.pendingReports(directory: crashFolder).first)
    // An exception that was never raised has no call stack, so it names no images.
    #expect(CrashInstaller.exceptionProperties(report: report)?["debug_images"] == nil)
    clearCrashFolder()
    #expect(DebugImages.imageName(inFrame: "3   My Shop                             0x0000000102a3f4c8 0x102a38000 + 29896") == "My Shop")
    #expect(DebugImages.imageName(inFrame: "12  libswiftCore.dylib  0x00000001a3f4c8aa $ss17_assertionFailure + 172") == "libswiftCore.dylib")
    #expect(DebugImages.imageName(inFrame: "not a frame") == nil)
    let loaded = [["name": "My Shop", "uuid": "A", "base": "0x1", "slide": "0x0"], ["name": "Other", "uuid": "B", "base": "0x2", "slide": "0x0"]]
    let frames = ["0   My Shop   0x0000000102a3f4c8 0x102a38000 + 1", "1   My Shop   0x0000000102a3f4d0 0x102a38000 + 9", "2   Missing   0x0000000102a3f4d0 foo + 9"]
    #expect(DebugImages.referenced(by: frames, among: loaded) == [loaded[0]])
  }
}
