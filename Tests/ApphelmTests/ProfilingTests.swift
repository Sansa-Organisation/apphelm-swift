import Darwin
import Foundation
import Testing

@testable import Apphelm

@inline(never)
func profiledLeaf(_ seconds: Double) -> Double {
  var total = 0.0
  let until = Date().addingTimeInterval(seconds)
  while Date() < until { for value in 0..<500 { total += Double(value).squareRoot() } }
  return total
}

@inline(never)
func profiledCaller(_ seconds: Double) -> Double { profiledLeaf(seconds) + 1 }

/// The symbol `dladdr` finds for an address, to check the sampler walked real frames.
private func symbol(_ address: String) -> String {
  guard let value = UInt(address.dropFirst(2), radix: 16) else { return "" }
  var info = Dl_info()
  guard dladdr(UnsafeRawPointer(bitPattern: value), &info) != 0, let name = info.dli_sname else { return "" }
  return String(cString: name)
}

// Profiles run one at a time per process, so these tests take turns.
@Suite("Profiling", .serialized)
struct ProfilingTests {
  @Test("The sampler walks the sampled thread's real frames, innermost first, with their images")
  func samplesRealFrames() throws {
    let recorder = try #require(ProfileRecorder.start(thread: mach_thread_self()))
    #expect(ProfileRecorder.start() == nil)
    _ = profiledCaller(0.3)
    recorder.stop()
    print("apphelm-profiler: \(recorder.sampleCount) samples, average sample \(recorder.averageCaptureNanos / 1_000) µs")
    #expect(!ProfileRecorder.busy)
    let profile = try #require(recorder.profile(name: "Checkout", traceId: String(repeating: "a", count: 32), spanId: String(repeating: "b", count: 16), release: "shop@1", environment: "production"))
    #expect(profile["version"] as? String == "1")
    #expect(profile["platform"] as? String == "cocoa")
    #expect((profile["event_id"] as? String)?.count == 32)
    #expect(profile["release"] as? String == "shop@1")
    let body = try #require(profile["profile"] as? [String: Any])
    let samples = try #require(body["samples"] as? [[String: Any]])
    let stacks = try #require(body["stacks"] as? [[Int]])
    let frames = try #require(body["frames"] as? [[String: Any]])
    #expect(samples.count >= 5)
    let addresses = frames.map { $0["instruction_addr"] as? String ?? "" }
    #expect(addresses.allSatisfy { $0.hasPrefix("0x") })
    // Some sample's stack has the leaf above its caller.
    let named = stacks.map { stack in stack.map { symbol(addresses[$0]) } }
    let found = named.contains { names in
      guard let leaf = names.firstIndex(where: { $0.contains("profiledLeaf") }), let caller = names.firstIndex(where: { $0.contains("profiledCaller") }) else { return false }
      return leaf < caller
    }
    #expect(found)
    let transaction = try #require(profile["transaction"] as? [String: Any])
    #expect(transaction["trace_id"] as? String == String(repeating: "a", count: 32))
    #expect(transaction["span_id"] as? String == String(repeating: "b", count: 16))
    let images = try #require((profile["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]])
    #expect(!images.isEmpty)
    #expect(images.allSatisfy { $0["type"] as? String == "macho" && ($0["debug_id"] as? String)?.count == 36 && ($0["image_size"] as? UInt64 ?? 0) > 0 && !(($0["code_file"] as? String) ?? "/").contains("/") })
    let elapsed = samples.compactMap { UInt64($0["elapsed_since_start_ns"] as? String ?? "") }
    #expect(elapsed == elapsed.sorted())
  }

  @Test("A profiled transaction posts its profile and carries its id; off by default")
  func clientProfiles() async throws {
    for rate in [nil, 1.0] as [Double?] {
      let recorder = Recorder()
      var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", tracesSampleRate: 1).quiet
      options.profilesSampleRate = rate
      let client = ApphelmClient(options: options, session: recorder.session(), store: MemoryStore())
      client.profiledThread = mach_thread_self()
      let tx = client.startTransaction("Checkout")
      _ = profiledCaller(0.15)
      #expect(await tx.finish())
      let paths = recorder.sent.map { $0.url?.path ?? "" }
      if rate == nil {
        #expect(paths == ["/api/v1/events"])
        #expect(recorder.properties(0)["profile_id"] == nil)
        continue
      }
      #expect(paths == ["/api/v1/profiles", "/api/v1/events"])
      let posted = recorder.bodies[0]
      #expect(posted["productId"] as? String == "prd_1")
      let profile = try #require(posted["profile"] as? [String: Any])
      #expect(recorder.properties(1)["profile_id"] as? String == profile["event_id"] as? String)
      #expect((profile["transaction"] as? [String: Any])?["span_id"] as? String == tx.spanId)
    }
  }

  @Test("An unsampled transaction is never profiled")
  func unsampled() async {
    let recorder = Recorder()
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: recorder.baseURL, workspaceId: "org_1", productId: "prd_1", tracesSampleRate: 0).quiet
    options.profilesSampleRate = 1
    let client = ApphelmClient(options: options, session: recorder.session(), store: MemoryStore())
    let tx = client.startTransaction("Checkout")
    #expect(!ProfileRecorder.busy)
    #expect(await tx.finish() == false)
    #expect(recorder.sent.isEmpty)
  }
}
