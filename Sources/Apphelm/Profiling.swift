import Foundation
import MachO
import Darwin

/// Profiling (README, "Profiling"): the main thread's stack, sampled from a background thread
/// for a share of sampled transactions (`profilesSampleRate`, off by default).
///
/// Every 10 ms the sampler suspends the main thread (`thread_suspend`), reads its program
/// counter and frame pointer (`thread_get_state`), walks the frame-pointer chain with
/// `vm_read_overwrite` (so a bad pointer is a failed read, never a crash) and resumes it.
/// Nothing is allocated and no lock is taken while the thread is suspended: the addresses go
/// into a buffer made beforehand. Frames are only addresses (`instruction_addr`); the server
/// symbolicates them with the dSYMs you upload, using the images listed in `debug_meta`.
///
/// One profile runs at a time per process: a transaction that starts while another is being
/// profiled is not profiled (it is still sent). A profile stops when its transaction finishes,
/// or after 30 seconds or 3,000 samples. Only the main thread is sampled. Arguments, locals and
/// memory beyond the frame chain are never read.
final class ProfileRecorder: @unchecked Sendable {
  static let intervalMicroseconds: UInt32 = 10_000
  static let maxSamples = 3_000
  static let maxNanos: UInt64 = 30_000_000_000
  static let maxDepth = 128
  static let maxProfileBytes = 1_000_000
  private static let lock = NSLock()
  nonisolated(unsafe) private static var running = false

  /// Whether a profile is being taken in this process now.
  static var busy: Bool { lock.withLock { running } }

  let id = randomHex(16)
  let threadId: String
  let startedAt: Date
  let startNanos: UInt64
  private let target: thread_act_t
  private let buffer: UnsafeMutablePointer<UInt64>
  private let lock = NSLock()
  private var stopped = false
  private let done = DispatchSemaphore(value: 0)
  private var addresses: [UInt64] = []
  private var addressIndex: [UInt64: Int] = [:]
  private var stacks: [[Int]] = []
  private var stackIndex: [[Int]: Int] = [:]
  private var samples: [(stack: Int, nanos: UInt64)] = []
  // How long sampling took, for the overhead the README states (read after `stop`).
  private var captureNanos: UInt64 = 0
  private var captures: UInt64 = 0
  var averageCaptureNanos: UInt64 { captures == 0 ? 0 : captureNanos / captures }

  /// Start sampling `thread` (the main thread unless a test names another), or nil when a
  /// profile is already running.
  static func start(thread: thread_act_t? = nil) -> ProfileRecorder? {
    let claimed: Bool = lock.withLock {
      if running { return false }
      running = true
      return true
    }
    guard claimed else { return nil }
    guard let target = thread ?? mainThread() else {
      lock.withLock { running = false }
      return nil
    }
    let recorder = ProfileRecorder(target: target)
    let sampler = Thread { recorder.run() }
    sampler.name = "apphelm-profiler"
    sampler.qualityOfService = QualityOfService.userInitiated
    sampler.start()
    return recorder
  }

  private static func mainThread() -> thread_act_t? { ThreadStacks.mainThreadPort }

  private init(target: thread_act_t) {
    self.target = target
    self.threadId = String(target)
    self.startedAt = Date()
    self.startNanos = DispatchTime.now().uptimeNanoseconds
    self.buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: ProfileRecorder.maxDepth)
  }

  deinit { buffer.deallocate() }

  private var shouldStop: Bool { lock.withLock { stopped } }

  private func run() {
    while !shouldStop {
      let now = DispatchTime.now().uptimeNanoseconds
      if now &- startNanos > Self.maxNanos || samples.count >= Self.maxSamples { break }
      let depth = capture()
      captureNanos &+= DispatchTime.now().uptimeNanoseconds &- now
      captures += 1
      if depth > 0 { record(depth: depth, nanos: now &- startNanos) }
      usleep(Self.intervalMicroseconds)
    }
    Self.lock.withLock { Self.running = false }
    done.signal()
  }

  /// The suspended thread's return addresses into `buffer`, innermost first (ThreadStacks).
  private func capture() -> Int {
    ThreadStacks.capture(target, into: buffer, maxDepth: Self.maxDepth)
  }

  private func record(depth: Int, nanos: UInt64) {
    var stack: [Int] = []
    stack.reserveCapacity(depth)
    for index in 0..<depth {
      let address = buffer[index]
      if let known = addressIndex[address] { stack.append(known); continue }
      addresses.append(address)
      addressIndex[address] = addresses.count - 1
      stack.append(addresses.count - 1)
    }
    let stackId: Int
    if let known = stackIndex[stack] { stackId = known } else {
      stacks.append(stack)
      stackId = stacks.count - 1
      stackIndex[stack] = stackId
    }
    samples.append((stackId, nanos))
  }

  /// Stop sampling and wait for the sampler to end. Sampler state is only read after this.
  func stop() {
    lock.withLock { stopped = true }
    done.wait()
  }

  /// Sentry's sample format v1, or nil with fewer than two samples or past 1 MB. Call after `stop`.
  func profile(name: String, traceId: String, spanId: String, release: String?, environment: String?) -> [String: Any]? {
    guard samples.count >= 2 else { return nil }
    let images = ProfileImages.loaded()
    var used: [Int: [String: Any]] = [:]
    let frames: [[String: Any]] = addresses.map { address in
      var frame: [String: Any] = ["instruction_addr": "0x" + String(address, radix: 16)]
      if let index = images.firstIndex(where: { address >= $0.start && address < $0.end }) {
        let image = images[index]
        frame["package"] = image.name
        if used.count < 64 || used[index] != nil {
          used[index] = ["type": "macho", "debug_id": image.uuid.lowercased(), "image_addr": "0x" + String(image.start, radix: 16), "image_size": image.end - image.start, "code_file": image.name]
        }
      }
      return frame
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var profile: [String: Any] = [
      "version": "1",
      "event_id": id,
      "platform": "cocoa",
      "timestamp": formatter.string(from: startedAt),
      "os": ["name": ProfileImages.osName, "version": ProcessInfo.processInfo.operatingSystemVersionString],
      "device": ["architecture": ProfileImages.architecture],
      "profile": [
        "samples": samples.map { ["stack_id": $0.stack, "thread_id": threadId, "elapsed_since_start_ns": String($0.nanos)] as [String: Any] },
        "stacks": stacks,
        "frames": frames,
        "thread_metadata": [threadId: ["name": "main"]],
      ] as [String: Any],
      "transaction": ["name": String(name.prefix(200)), "trace_id": traceId, "span_id": spanId, "active_thread_id": threadId],
      "debug_meta": ["images": used.keys.sorted().compactMap { used[$0] }],
    ]
    if let release { profile["release"] = release }
    if let environment { profile["environment"] = environment }
    guard let data = try? JSONSerialization.data(withJSONObject: profile), data.count <= Self.maxProfileBytes else { return nil }
    return profile
  }

  var sampleCount: Int { samples.count }
}

/// The loaded images with their `__TEXT` ranges, so a sampled address can name its binary.
enum ProfileImages {
  struct Image { let name: String; let uuid: String; let start: UInt64; let end: UInt64 }

  static var osName: String {
    #if os(iOS)
    return "iOS"
    #elseif os(macOS)
    return "macOS"
    #else
    return "Apple"
    #endif
  }

  static var architecture: String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
  }

  static func loaded() -> [Image] {
    var images: [Image] = []
    for index in 0..<_dyld_image_count() {
      guard let header = _dyld_get_image_header(index), let path = _dyld_get_image_name(index),
        let uuid = DebugImages.uuid(of: header), let size = textSize(of: header) else { continue }
      let name = String(URL(fileURLWithPath: String(cString: path)).lastPathComponent.prefix(100))
      let start = UInt64(UInt(bitPattern: header))
      images.append(Image(name: name, uuid: uuid, start: start, end: start + size))
    }
    return images
  }

  /// The `__TEXT` segment's size: an image's code lies in [load address, load address + size).
  static func textSize(of header: UnsafePointer<mach_header>) -> UInt64? {
    guard header.pointee.magic == MH_MAGIC_64 else { return nil }
    var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
      let load = command.assumingMemoryBound(to: load_command.self).pointee
      if load.cmd == UInt32(LC_SEGMENT_64) {
        let segment = command.assumingMemoryBound(to: segment_command_64.self).pointee
        let isText = withUnsafeBytes(of: segment.segname) { bytes in Array(bytes.prefix(7)) == Array("__TEXT\0".utf8) }
        if isText { return segment.vmsize }
      }
      guard load.cmdsize > 0 else { return nil }
      command = command.advanced(by: Int(load.cmdsize))
    }
    return nil
  }
}
