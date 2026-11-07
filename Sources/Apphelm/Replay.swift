import Foundation

/// Session replay for native screens: a wireframe of the screen (boxes, colours, masked text)
/// each time it changes, sent to the replay collector. Off unless `ApphelmOptions.replay` is
/// set and the app calls `setReplayConsent(true)`. No pixels are captured.
public struct ReplayOptions: Sendable {
  /// The product's project key (`ahl_pub_…`) and an origin that key allows. Default:
  /// `surveyKey` and `surveyOrigin`. A key that is not a project key is refused.
  public var projectKey: String?
  public var origin: String?
  /// Text fields show asterisks instead of what was typed (default true). Password fields are
  /// always masked, whatever this says.
  public var maskAllTextInputs: Bool = true
  /// Labels and button titles show asterisks too (default false).
  public var maskAllText: Bool = false
  /// Sent with each recording so you can tell which consent text it was recorded under.
  public var consentPolicyVersion: String = "sdk_consent_v1"
  /// Seconds between checks for a changed screen (default 1).
  public var checkIntervalSeconds: Double = 1
  /// Seconds between uploads (default 5).
  public var flushIntervalSeconds: Double = 5
  /// Screens never recorded, by name. Sign-in, checkout, payment, billing and admin screens
  /// are never recorded either way.
  public var blockedScreens: [String] = []
  /// The share of recordings kept whole from their start, 0 to 1 (Sentry's
  /// `sessionSampleRate`). Default 1: every recording, as before 0.8.0. Decided when a
  /// recording starts: at the first screen after consent, after 30 minutes in the background,
  /// and after `reset()`.
  public var sessionSampleRate: Double = 1
  /// Replay on error (Sentry's `onErrorSampleRate`), 0 to 1; default 0, off. A recording that
  /// `sessionSampleRate` did not pick is then kept in memory only: the last
  /// `errorBufferSeconds`, nothing sent. When an exception or crash is reported, the buffer is
  /// uploaded with this probability and recording carries on as a whole recording. Messages
  /// don't upload a buffer. A buffer is cleared when the app stays in the background longer
  /// than `ApphelmOptions.sessionTrackingIntervalSeconds`.
  public var onErrorSampleRate: Double = 0
  /// How much a buffer keeps before the error, in seconds (default 30, as Sentry's mobile
  /// SDKs; 10 to 120). It also never holds more than about 2 MB of wireframes.
  public var errorBufferSeconds: Double = 30

  public init(projectKey: String? = nil, origin: String? = nil, maskAllTextInputs: Bool = true, maskAllText: Bool = false, sessionSampleRate: Double = 1, onErrorSampleRate: Double = 0, errorBufferSeconds: Double = 30) {
    self.projectKey = projectKey
    self.origin = origin
    self.maskAllTextInputs = maskAllTextInputs
    self.maskAllText = maskAllText
    self.sessionSampleRate = sessionSampleRate
    self.onErrorSampleRate = onErrorSampleRate
    self.errorBufferSeconds = errorBufferSeconds
  }
}

/// What a wireframe element is (lib/replay-format.ts `WireKind`).
enum WireKind: String, Codable, Sendable {
  case view, text, image, input, button, toggle, web, blocked
}

/// One view as the platform adapter sees it, before masking. Frames are window points.
struct ReplayViewNode {
  var id: Int
  var kind: WireKind = .view
  var x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0
  var hidden = false
  var alpha: Double = 1
  var background: String?
  var foreground: String?
  var border: String?
  var borderWidth: Double = 0
  var cornerRadius: Double = 0
  var text: String?
  var fontSize: Double?
  var isSecure = false
  var isOn: Bool?
  /// Left out of replay: drawn as an empty box, nothing inside recorded.
  var noCapture = false
  /// Its text and its children's text are masked.
  var mask = false
  var children: [ReplayViewNode] = []
}

/// One element of a wireframe (lib/replay-format.ts `WireNode`).
struct WireNode: Codable, Equatable, Sendable {
  var i: Int
  var k: WireKind
  var x: Int, y: Int, w: Int, h: Int
  var bg: String?, fg: String?, bc: String?
  var bw: Int?, r: Int?
  var t: String?
  var fs: Int?
  var o: Double?
  var on: Bool?
}

enum WireframeBuilder {
  static let maxNodes = 3_000
  static let maxText = 500
  static let secureText = "********"
  private static let leafKinds: Set<WireKind> = [.input, .button, .toggle, .image, .web, .blocked]

  /// Asterisks for masked text: as many as the text has characters, at most 30.
  static func asterisks(_ text: String) -> String { String(repeating: "*", count: min(text.count, 30)) }

  static func validColor(_ value: String?) -> String? {
    guard let value, value.count == 7, value.hasPrefix("#"), value.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
    return value.lowercased()
  }

  /// The wireframe of a screen: paint order (parents before children), masked, bounded.
  static func build(_ root: ReplayViewNode, screenWidth: Double, screenHeight: Double, options: ReplayOptions) -> [WireNode] {
    var nodes: [WireNode] = []
    func walk(_ node: ReplayViewNode, alpha parentAlpha: Double, masked parentMasked: Bool) {
      guard nodes.count < maxNodes, !node.hidden, node.alpha > 0.01 else { return }
      let alpha = parentAlpha * min(1, node.alpha)
      let masked = parentMasked || node.mask
      let visible = node.width >= 1 && node.height >= 1 && node.x + node.width > 0 && node.y + node.height > 0 && node.x < screenWidth && node.y < screenHeight
      var wire = WireNode(i: max(1, node.id), k: node.kind, x: Int(node.x.rounded()), y: Int(node.y.rounded()), w: Int(node.width.rounded()), h: Int(node.height.rounded()))
      if node.noCapture {
        wire.k = .blocked
        if visible { nodes.append(wire) }
        return
      }
      if visible {
        wire.bg = validColor(node.background)
        wire.fg = validColor(node.foreground)
        wire.bc = validColor(node.border)
        if node.borderWidth > 0 { wire.bw = max(1, Int(node.borderWidth.rounded())) }
        if node.cornerRadius >= 1 { wire.r = Int(node.cornerRadius.rounded()) }
        if let size = node.fontSize, size > 0 { wire.fs = Int(size.rounded()) }
        if alpha < 0.99 { wire.o = (alpha * 100).rounded() / 100 }
        if node.kind == .toggle { wire.on = node.isOn ?? false }
        if node.isSecure {
          // Never the value, never its length.
          wire.k = .input
          wire.t = secureText
        } else if let text = node.text, !text.isEmpty {
          if node.kind == .input {
            wire.t = options.maskAllTextInputs ? asterisks(text) : String(text.prefix(maxText))
          } else {
            wire.t = options.maskAllText || masked ? asterisks(text) : String(text.prefix(maxText))
          }
        }
        nodes.append(wire)
      }
      // A field, button or image draws its own insides; their subviews would repeat or leak them.
      if leafKinds.contains(wire.k) { return }
      for child in node.children { walk(child, alpha: alpha, masked: masked) }
    }
    walk(root, alpha: 1, masked: false)
    return nodes
  }
}

/// Paths a recording never shows, the browser SDK's rule (packages/sdk/src/paths.ts).
let blockedReplayPath = try! NSRegularExpression(pattern: "(^|/)(auth|sign-in|sign-up|login|logout|billing|checkout|payment|admin|account/security)(/|$)", options: [.caseInsensitive])

/// A screen name as a replay path: `/` and letters, digits, `_`, `-`, at most 120 characters.
func replayPath(_ screen: String) -> String {
  let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-")
  var cleaned = String(String.UnicodeScalarView(screen.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
  while cleaned.hasPrefix("/") { cleaned.removeFirst() }
  return String(("/" + cleaned).prefix(120))
}

func isBlockedReplayPath(_ path: String, extra: [String] = []) -> Bool {
  if blockedReplayPath.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil { return true }
  return extra.contains { replayPath($0).lowercased() == path.lowercased() }
}

enum ReplayEvent: Encodable, Equatable {
  case viewport(t: Int, width: Int, height: Int)
  case navigation(t: Int, path: String)
  case wireframe(t: Int, nodes: [WireNode])
  case click(t: Int, x: Int, y: Int)
  case visibility(t: Int, hidden: Bool)

  /// Milliseconds since the recording started.
  var t: Int {
    switch self {
    case let .viewport(t, _, _), let .navigation(t, _), let .wireframe(t, _), let .click(t, _, _), let .visibility(t, _): return t
    }
  }

  /// The same event at another time.
  func at(_ time: Int) -> ReplayEvent {
    switch self {
    case let .viewport(_, width, height): return .viewport(t: time, width: width, height: height)
    case let .navigation(_, path): return .navigation(t: time, path: path)
    case let .wireframe(_, nodes): return .wireframe(t: time, nodes: nodes)
    case let .click(_, x, y): return .click(t: time, x: x, y: y)
    case let .visibility(_, hidden): return .visibility(t: time, hidden: hidden)
    }
  }

  private enum Keys: String, CodingKey { case type, t, width, height, path, nodes, x, y, hidden }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case let .viewport(t, width, height):
      try container.encode("viewport", forKey: .type); try container.encode(t, forKey: .t); try container.encode(width, forKey: .width); try container.encode(height, forKey: .height)
    case let .navigation(t, path):
      try container.encode("navigation", forKey: .type); try container.encode(t, forKey: .t); try container.encode(path, forKey: .path)
    case let .wireframe(t, nodes):
      try container.encode("wireframe", forKey: .type); try container.encode(t, forKey: .t); try container.encode(nodes, forKey: .nodes)
    case let .click(t, x, y):
      try container.encode("click", forKey: .type); try container.encode(t, forKey: .t); try container.encode(x, forKey: .x); try container.encode(y, forKey: .y)
    case let .visibility(t, hidden):
      try container.encode("visibility", forKey: .type); try container.encode(t, forKey: .t); try container.encode(hidden, forKey: .hidden)
    }
  }
}

/// The body of one replay upload (the collector's chunk envelope).
struct ReplayChunk: Encodable {
  struct Viewport: Encodable { let width: Int; let height: Int }
  struct Person: Encodable { let distinctHash: String; let distinctHash2: String; let identified: Bool }
  let sessionId: String
  let workspaceId: String
  let productId: String
  let sequence: Int
  let startedAt: String
  let entryPath: String
  let viewport: Viewport
  let maskingVersion = "mobile_wireframe_v1"
  let consentPolicyVersion: String
  let mode = "mobile"
  let platform: String
  let person: Person
  let sessionHash: String?
  let ended: Bool
  let events: [ReplayEvent]
}

enum ReplaySendResult: Sendable {
  /// Stored, or refused for good (invalid, over the plan's limit): either way not sent again.
  case done
  /// Not delivered now (offline, server error, rate limit): kept and sent again.
  case retry
}

func replayEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return encoder
}

/// Records one app's screens into replay chunks and uploads them. Thread-safe; the platform
/// adapter calls `capture` and `tap` on the main thread.
///
/// Each recording is decided when it starts: kept whole (`sessionSampleRate`), buffered for an
/// error (`onErrorSampleRate` above 0), or not recorded. A buffered recording keeps only the
/// last `errorBufferSeconds` in memory and sends nothing; `errorCaptured` uploads it and the
/// recording carries on as a whole one, as Sentry's mobile SDKs do.
final class ReplayRecorder: @unchecked Sendable {
  typealias Sender = @Sendable (Data) async -> ReplaySendResult
  struct Person { let distinctId: String; let identified: Bool }

  static let maxEvents = 400
  static let maxBytes = 700_000
  /// A buffered recording holds at most this many bytes of events; the oldest go first.
  static let maxBufferBytes = 2_000_000
  static let idleRestartMs = 30 * 60_000
  static let maxRecordingMs = 86_400_000
  static let maxPending = 10

  let options: ReplayOptions
  private let workspaceId: String
  private let productId: String
  private let platform: String
  private let now: @Sendable () -> Date
  private let person: @Sendable () -> Person
  private let sessionHash: @Sendable () -> String?
  private let allowed: @Sendable () -> Bool
  private let random: @Sendable () -> Double
  private let send: Sender?
  private let encoder = replayEncoder()
  private let lock = NSLock()
  /// How long the app may stay in the background before a buffer is cleared (the client's
  /// session timeout, 30 s by default, as Sentry's).
  private let bufferResetMs: Int
  private let bufferMs: Int
  private let sessionRate: Double
  private let errorRate: Double

  private enum Decision { case session, buffer, off }
  private struct Recording { let id: String; var startedAt: Date; var entryPath: String; var sequence = 0; var buffering: Bool }
  private struct Pending { let id: String; let body: Data }
  /// What a buffer dropped from its start that the screen still shows: the last viewport,
  /// path and wireframe before the kept stretch.
  private struct Carry { var viewport: (width: Int, height: Int)?; var path: String?; var nodes: [WireNode]?; var nodeBytes = 0 }
  private var consent = false
  private var decision: Decision?
  private var recording: Recording?
  private var events: [ReplayEvent] = []
  private var sizes: [Int] = []
  private var eventBytes = 0
  private var carry = Carry()
  private var droppedThrough = -1
  private var lastT = 0
  private var lastNodes: Data?
  private var viewport: (width: Int, height: Int)?
  private var currentPath: String?
  private var blockedScreen = false
  private var hiddenAt: Date?
  private var pending: [Pending] = []
  private var flushing = false
  private var dirty = false
  /// The platform capture (UIKit) attached while recording.
  var attachment: AnyObject?
  /// Where the crash snapshot goes (`ReplayCrashStore`); nil writes nothing.
  var crashSink: (@Sendable (Data?) -> Void)?

  init(options: ReplayOptions, workspaceId: String, productId: String, platform: String = "ios", now: @escaping @Sendable () -> Date = { Date() }, person: @escaping @Sendable () -> Person, sessionHash: @escaping @Sendable () -> String? = { nil }, allowed: @escaping @Sendable () -> Bool = { true }, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }, bufferResetSeconds: Double = 30, send: Sender?) {
    self.options = options
    self.workspaceId = workspaceId
    self.productId = productId
    self.platform = platform
    self.now = now
    self.person = person
    self.sessionHash = sessionHash
    self.allowed = allowed
    self.random = random
    self.send = send
    self.bufferResetMs = Int(max(0, bufferResetSeconds.isFinite ? bufferResetSeconds : 30) * 1000)
    self.bufferMs = Int(min(120, max(10, options.errorBufferSeconds.isFinite ? options.errorBufferSeconds : 30)) * 1000)
    self.sessionRate = options.sessionSampleRate.isNaN ? 1 : min(1, max(0, options.sessionSampleRate))
    self.errorRate = options.onErrorSampleRate.isNaN ? 0 : min(1, max(0, options.onErrorSampleRate))
  }

  /// False when the project key or origin is missing or not a project key.
  var isConfigured: Bool { send != nil }

  /// Recording now: configured, consent given, analytics not opted out. A recording that
  /// sampling left out still counts: replay is on, this stretch is just not kept.
  var isActive: Bool { lock.withLock { consent } && send != nil && allowed() }

  /// The running recording's id; nil while none runs, and while a buffer waits for an error
  /// (it is no replay until one is captured).
  var sessionId: String? { lock.withLock { recording.flatMap { $0.buffering ? nil : $0.id } } }

  /// True while a recording is kept in memory for an error.
  var isBuffering: Bool { lock.withLock { recording?.buffering ?? false } }

  /// False while sampling left this recording out or the screen is one never recorded: the
  /// platform capture then skips walking the screen.
  var wantsFrames: Bool { lock.withLock { !blockedScreen && !(recording == nil && decision == .off) } }

  /// The developer's declaration that the person agreed to replay. Withdrawing stops at once
  /// and discards everything not yet sent, the crash snapshot included.
  func setConsent(_ granted: Bool) {
    let cleared: Bool = lock.withLock {
      consent = granted
      if !granted { clearLocked() }
      return !granted
    }
    if cleared { crashSink?(nil) }
  }

  private func clearLocked() {
    recording = nil
    decision = nil
    resetEventsLocked()
    pending = []
    lastNodes = nil
    viewport = nil
    hiddenAt = nil
    dirty = false
  }

  private func resetEventsLocked() {
    events = []
    sizes = []
    eventBytes = 0
    carry = Carry()
    droppedThrough = -1
  }

  private func elapsedLocked() -> Int {
    guard let recording else { return 0 }
    let ms = Int((now().timeIntervalSince(recording.startedAt) * 1000).rounded(.down))
    lastT = min(Self.maxRecordingMs, max(lastT, ms))
    return lastT
  }

  private func appendLocked(_ event: ReplayEvent, bytes: Int = 64) {
    events.append(event)
    sizes.append(bytes)
    eventBytes += bytes
    dirty = true
    if recording?.buffering == true { trimBufferLocked() }
  }

  /// Keep a buffer to its last `errorBufferSeconds` and `maxBufferBytes`, dropping the oldest
  /// events first (the newest always stays). What the screen still shows is carried.
  private func trimBufferLocked() {
    let cutoff = lastT - bufferMs
    var drop = 0
    var bytes = eventBytes
    while drop < events.count - 1 && (events[drop].t < cutoff || bytes > Self.maxBufferBytes) {
      switch events[drop] {
      case let .viewport(_, width, height): carry.viewport = (width, height)
      case let .navigation(_, path): carry.path = path
      case let .wireframe(_, nodes): carry.nodes = nodes; carry.nodeBytes = sizes[drop]
      case .click, .visibility: break
      }
      bytes -= sizes[drop]
      droppedThrough = max(droppedThrough, events[drop].t)
      drop += 1
    }
    guard drop > 0 else { return }
    events.removeFirst(drop)
    sizes.removeFirst(drop)
    eventBytes = bytes
  }

  /// A buffer as it would be uploaded: starting where the kept stretch starts, with the
  /// viewport, path and screen in effect there at time 0. Changes nothing.
  private func bufferedLocked(_ current: Recording) -> (base: Int, entryPath: String, events: [ReplayEvent], sizes: [Int]) {
    guard droppedThrough >= 0 else { return (0, current.entryPath, events, sizes) }
    let base = min(events.first?.t ?? lastT, max(lastT - bufferMs, droppedThrough))
    let path = carry.path ?? current.entryPath
    var out: [ReplayEvent] = []
    var outSizes: [Int] = []
    if let size = carry.viewport { out.append(.viewport(t: 0, width: size.width, height: size.height)); outSizes.append(64) }
    out.append(.navigation(t: 0, path: path)); outSizes.append(64)
    if let nodes = carry.nodes { out.append(.wireframe(t: 0, nodes: nodes)); outSizes.append(carry.nodeBytes) }
    for (event, size) in zip(events, sizes) { out.append(event.at(max(0, event.t - base))); outSizes.append(size) }
    return (base, path, out, outSizes)
  }

  private func startIfNeededLocked() -> Bool {
    if let recording, now().timeIntervalSince(recording.startedAt) * 1000 >= Double(Self.maxRecordingMs) { endLocked() }
    guard recording == nil else { return true }
    if decision == nil {
      // Sentry's order: the session rate first; a recording it didn't pick may still be buffered.
      decision = random() < sessionRate ? .session : errorRate > 0 ? .buffer : .off
    }
    guard decision != .off else { return false }
    let path = currentPath ?? "/"
    recording = Recording(id: "rpl_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), startedAt: now(), entryPath: path, buffering: decision == .buffer)
    resetEventsLocked()
    lastT = 0
    lastNodes = nil
    viewport = nil
    appendLocked(.navigation(t: 0, path: path))
    return true
  }

  /// Ends the recording: what is left goes out as its last chunk. A buffer no error asked for
  /// is dropped.
  private func endLocked() {
    if let current = recording, !current.buffering { enqueueChunksLocked(ended: true) }
    recording = nil
    resetEventsLocked()
    lastNodes = nil
    viewport = nil
    dirty = true
  }

  private func enqueueLocked(_ chunk: Pending) {
    pending.append(chunk)
    if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
  }

  /// One chunk's body. Changes nothing.
  private func bodyLocked(_ current: Recording, sequence: Int, events slice: ArraySlice<ReplayEvent>, ended: Bool) -> Data? {
    let who = person()
    let hashes = personHashes(who.distinctId)
    let hash = sessionHash().flatMap { $0.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil ? $0 : nil }
    let size = viewport ?? (1, 1)
    let chunk = ReplayChunk(
      sessionId: current.id, workspaceId: workspaceId, productId: productId, sequence: sequence,
      startedAt: ISO8601DateFormatter().string(from: current.startedAt), entryPath: current.entryPath,
      viewport: .init(width: max(1, size.width), height: max(1, size.height)),
      consentPolicyVersion: String(options.consentPolicyVersion.prefix(80)), platform: platform,
      person: .init(distinctHash: hashes.first, distinctHash2: hashes.second, identified: who.identified),
      sessionHash: hash, ended: ended, events: Array(slice))
    return try? encoder.encode(chunk)
  }

  /// `events` in chunks of at most `maxBytes` each (an event larger than that goes alone).
  private static func split(_ sizes: [Int]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start = 0, total = 0
    for (index, size) in sizes.enumerated() {
      if index > start && (total + size > maxBytes || index - start >= maxEvents) {
        ranges.append(start..<index)
        start = index
        total = 0
      }
      total += size
    }
    if start < sizes.count { ranges.append(start..<sizes.count) }
    return ranges
  }

  /// Bodies for `list` from `sequence` on, the last marked `ended` when asked. Changes nothing.
  private func bodiesLocked(_ current: Recording, sequence: Int, events list: [ReplayEvent], sizes listSizes: [Int], ended: Bool) -> [Data] {
    let ranges = Self.split(listSizes)
    return ranges.enumerated().compactMap { index, range in
      bodyLocked(current, sequence: sequence + index, events: list[range], ended: ended && index == ranges.count - 1)
    }
  }

  /// What is recorded now, as chunks waiting to be sent; the events are cleared.
  private func enqueueChunksLocked(ended: Bool) {
    guard var current = recording, !events.isEmpty else { return }
    let bodies = bodiesLocked(current, sequence: current.sequence, events: events, sizes: sizes, ended: ended)
    for body in bodies {
      enqueueLocked(Pending(id: "\(current.id):\(current.sequence)", body: body))
      current.sequence += 1
    }
    recording = current
    events = []
    sizes = []
    eventBytes = 0
  }

  /// The screen changed (a view controller appeared, or the app named a screen).
  func screenChanged(_ name: String) {
    let path = replayPath(name)
    lock.withLock {
      currentPath = path
      blockedScreen = isBlockedReplayPath(path, extra: options.blockedScreens)
      lastNodes = nil
      guard consent, recording != nil, !blockedScreen else { return }
      appendLocked(.navigation(t: elapsedLocked(), path: path))
    }
  }

  /// Records the screen when it changed since the last wireframe. True when a wireframe was added.
  @discardableResult
  func capture(_ root: ReplayViewNode, width: Double, height: Double) -> Bool {
    guard isActive, !lock.withLock({ blockedScreen || (recording == nil && decision == .off) }) else { return false }
    let nodes = WireframeBuilder.build(root, screenWidth: width, screenHeight: height, options: options)
    guard let encoded = try? encoder.encode(nodes) else { return false }
    return lock.withLock {
      guard consent, startIfNeededLocked() else { return false }
      let size = (Int(width.rounded()), Int(height.rounded()))
      if viewport.map({ $0 != size }) ?? true {
        viewport = size
        appendLocked(.viewport(t: elapsedLocked(), width: max(1, size.0), height: max(1, size.1)))
      }
      guard encoded != lastNodes else { return false }
      lastNodes = encoded
      appendLocked(.wireframe(t: elapsedLocked(), nodes: nodes), bytes: encoded.count + 40)
      return true
    }
  }

  func tap(x: Double, y: Double) {
    guard isActive else { return }
    lock.withLock {
      guard recording != nil, !blockedScreen else { return }
      appendLocked(.click(t: elapsedLocked(), x: Int(x.rounded()), y: Int(y.rounded())))
    }
  }

  /// The app went to the background (true) or came back. Back after 30 minutes away starts a
  /// new recording (sampled afresh); a buffer is cleared after the session timeout.
  func visibility(hidden: Bool) {
    lock.withLock {
      guard consent else { return }
      if hidden {
        hiddenAt = now()
        if recording != nil { appendLocked(.visibility(t: elapsedLocked(), hidden: true)) }
        return
      }
      let away = hiddenAt.map { Int(now().timeIntervalSince($0) * 1000) }
      hiddenAt = nil
      if let away, away >= Self.idleRestartMs {
        if recording != nil { endLocked() }
        decision = nil
        return
      }
      if let away, away >= bufferResetMs, recording?.buffering == true {
        // Sentry clears a buffer after the session timeout: the next screen starts a new one.
        recording = nil
        resetEventsLocked()
        lastNodes = nil
        viewport = nil
        dirty = true
        return
      }
      if recording != nil { appendLocked(.visibility(t: elapsedLocked(), hidden: false)) }
    }
  }

  /// The person changed (reset, log-out): the recording ends and the next one starts fresh.
  func personChanged() {
    lock.withLock {
      if recording != nil { endLocked() }
      decision = nil
    }
  }

  /// An error event was kept (after `beforeSend`): the id of the replay to link it to, or nil.
  /// A whole recording is linked as it is. A buffer is linked only for an exception (not a
  /// message), with `onErrorSampleRate`'s probability: it is then queued for upload, from
  /// where its kept stretch starts, and recording carries on as a whole recording.
  func errorCaptured(isException: Bool) -> String? {
    guard isActive else { return nil }
    return lock.withLock {
      guard consent, var current = recording else { return nil }
      guard current.buffering else { return current.id }
      guard isException, random() < errorRate else { return nil }
      let buffered = bufferedLocked(current)
      current.startedAt = current.startedAt.addingTimeInterval(Double(buffered.base) / 1000)
      current.entryPath = buffered.entryPath
      current.buffering = false
      recording = current
      lastT = max(0, lastT - buffered.base)
      events = buffered.events
      sizes = buffered.sizes
      eventBytes = sizes.reduce(0, +)
      carry = Carry()
      droppedThrough = -1
      decision = .session
      enqueueChunksLocked(ended: false)
      return current.id
    }
  }

  /// Enough waiting to upload now rather than at the next timer.
  var shouldFlush: Bool { lock.withLock { recording?.buffering != true && (events.count >= Self.maxEvents || eventBytes >= Self.maxBytes) } }

  /// Upload what is waiting, oldest first. A chunk that could not be delivered is kept, with
  /// its sequence, and sent again next time. A buffer is never sent from here. Afterwards the
  /// crash snapshot is brought up to date.
  func flush() async {
    guard let send else { return }
    let batch: [Pending]? = lock.withLock {
      guard !flushing else { return nil }
      if consent, recording?.buffering == false { enqueueChunksLocked(ended: false) }
      guard !pending.isEmpty else { return nil }
      flushing = true
      return pending
    }
    if let batch {
      for item in batch {
        let result = await send(item.body)
        guard case .done = result else { break }
        lock.withLock { pending.removeAll { $0.id == item.id }; dirty = true }
      }
      lock.withLock { flushing = false }
    }
    persistCrashSnapshot()
  }

  /// Write the crash snapshot when something changed since the last one.
  func persistCrashSnapshot() {
    guard let sink = crashSink else { return }
    let changed: Bool = lock.withLock { defer { dirty = false }; return dirty }
    guard changed else { return }
    sink(crashSnapshot())
  }

  /// What a crash now would leave for the next launch (`ReplayCrashStore`): the recording's
  /// id, whether it is a buffer (and the rate an error uploads one at), and its chunks,
  /// waiting ones first, the last marked ended. Nil without consent or a recording.
  func crashSnapshot() -> Data? {
    lock.withLock {
      guard consent, let current = recording else { return nil }
      var chunks = pending.map { String(decoding: $0.body, as: UTF8.self) }
      if current.buffering {
        let buffered = bufferedLocked(current)
        var moved = current
        moved.startedAt = current.startedAt.addingTimeInterval(Double(buffered.base) / 1000)
        moved.entryPath = buffered.entryPath
        chunks += bodiesLocked(moved, sequence: 0, events: buffered.events, sizes: buffered.sizes, ended: true).map { String(decoding: $0, as: UTF8.self) }
      } else if !events.isEmpty {
        chunks += bodiesLocked(current, sequence: current.sequence, events: events, sizes: sizes, ended: true).map { String(decoding: $0, as: UTF8.self) }
      }
      // A whole recording already sent still links the crash to it.
      guard !chunks.isEmpty || !current.buffering else { return nil }
      let snapshot: [String: Any] = ["version": 1, "sessionId": current.id, "buffering": current.buffering, "onErrorSampleRate": errorRate, "chunks": chunks]
      return try? JSONSerialization.data(withJSONObject: snapshot)
    }
  }

  /// Send a crashed run's replay (`crashSnapshot`, read back on the next launch): its id when
  /// it was delivered, nil when it was not sampled, not delivered, or can't be read. A buffer
  /// is uploaded with the rate the crashed run had, as Sentry's crash recovery does.
  func sendCrashReplay(_ data: Data) async -> String? {
    guard let send, allowed(),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["sessionId"] as? String, id.range(of: "^rpl_[a-f0-9]{32}$", options: .regularExpression) != nil,
          let chunks = object["chunks"] as? [String], !chunks.isEmpty || object["buffering"] as? Bool == false else { return nil }
    if object["buffering"] as? Bool == true {
      let rate = (object["onErrorSampleRate"] as? Double).map { min(1, max(0, $0)) } ?? 0
      guard random() < rate else { return nil }
    }
    for chunk in chunks.prefix(Self.maxPending + 4) {
      guard case .done = await send(Data(chunk.utf8)) else { return nil }
    }
    return id
  }

  /// For tests: what is waiting to be sent.
  var pendingCount: Int { lock.withLock { pending.count } }
  var eventCount: Int { lock.withLock { events.count } }
  var bufferedBytes: Int { lock.withLock { eventBytes } }
}

/// The crash snapshot of a recording (`ReplayRecorder.crashSnapshot`) on disk beside the crash
/// reports, so a crashed run's replay can be sent on the next launch. The running process
/// writes `replay-active-<run>.json`; the crash installer of the next launch renames it after
/// the crash report it belongs to (`replay-<report>.json`) or deletes it when the run did not
/// crash. Written from the replay flush (every `flushIntervalSeconds`), never from a signal
/// handler, so the last seconds before a crash can be missing.
final class ReplayCrashStore: @unchecked Sendable {
  static let shared = ReplayCrashStore()
  static let activePrefix = "replay-active-"

  private let lock = NSLock()
  private var file: URL?
  private let queue = DispatchQueue(label: "dev.apphelm.replay-crash", qos: .utility)

  /// The file for this run, after the previous run's has been moved aside.
  func attach(directory: URL, run: String) {
    lock.withLock { file = directory.appendingPathComponent(Self.activePrefix + run + ".json") }
  }

  /// Write `data`, or delete the file when it is nil. In order, off the caller's thread.
  func update(_ data: Data?) {
    guard let target = lock.withLock({ file }) else { return }
    queue.async {
      if let data { try? data.write(to: target, options: .atomic) } else { try? FileManager.default.removeItem(at: target) }
    }
  }

  /// Wait for pending writes (tests).
  func drain() { queue.sync {} }

  /// `replay-<id>.json` for `crash-<id>.log`, `replay-exception-<run>.json` for `crash-exception-<run>.json`.
  static func file(for report: URL) -> URL? {
    let name = report.lastPathComponent
    guard name.hasPrefix("crash-") else { return nil }
    let stem = name.dropFirst("crash-".count).dropLast(report.pathExtension.count + 1)
    return report.deletingLastPathComponent().appendingPathComponent("replay-" + stem + ".json")
  }

  /// At install: the previous runs' snapshots go with their crash. A signal crash (its report
  /// just moved aside as `signalReport`) takes the snapshot; an uncaught exception's report
  /// (`crash-exception-<run>.json`) takes its own run's; any other snapshot is from a run
  /// that did not crash and is deleted.
  static func moveAside(directory: URL, signalReport: URL?) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(activePrefix) && name.hasSuffix(".json") {
      let source = directory.appendingPathComponent(name)
      let run = String(name.dropFirst(activePrefix.count).dropLast(".json".count))
      let exceptionReport = directory.appendingPathComponent("crash-exception-\(run).json")
      let target: URL?
      if FileManager.default.fileExists(atPath: exceptionReport.path) { target = file(for: exceptionReport) }
      else if let signalReport { target = file(for: signalReport) }
      else { target = nil }
      if let target, !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.moveItem(at: source, to: target) }
      else { try? FileManager.default.removeItem(at: source) }
    }
  }

  /// Delete every stored snapshot (consent withdrawn).
  static func removeAll(directory: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix("replay-") && name.hasSuffix(".json") {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}

/// Sends replay chunks to `/api/replay` with the project key and its origin.
struct ReplayUploader: Sendable {
  let url: URL
  let key: String
  let origin: String
  let timeout: Double
  let session: URLSession

  /// Nil unless the key is a project key and the origin and URL are usable.
  init?(baseURL: String, key: String?, origin: String?, timeout: Double, session: URLSession) {
    let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // A server key must never reach a browser collector route.
    guard key.hasPrefix("ahl_pub_"), !origin.isEmpty, let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/replay") else { return nil }
    self.url = url
    self.key = key
    self.origin = origin
    self.timeout = timeout
    self.session = session
  }

  func send(_ body: Data) async -> ReplaySendResult {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue(key, forHTTPHeaderField: "x-apphelm-key")
    request.setValue(origin, forHTTPHeaderField: "origin")
    request.httpBody = body
    guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return .retry }
    if (200...299).contains(http.statusCode) { return .done }
    // Rate limits and server errors are retried; anything else would fail again.
    return http.statusCode == 429 || http.statusCode >= 500 ? .retry : .done
  }
}
