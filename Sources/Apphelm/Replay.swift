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

  public init(projectKey: String? = nil, origin: String? = nil, maskAllTextInputs: Bool = true, maskAllText: Bool = false) {
    self.projectKey = projectKey
    self.origin = origin
    self.maskAllTextInputs = maskAllTextInputs
    self.maskAllText = maskAllText
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
final class ReplayRecorder: @unchecked Sendable {
  typealias Sender = @Sendable (Data) async -> ReplaySendResult
  struct Person { let distinctId: String; let identified: Bool }

  static let maxEvents = 400
  static let maxBytes = 700_000
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
  private let send: Sender?
  private let encoder = replayEncoder()
  private let lock = NSLock()

  private struct Recording { let id: String; let startedAt: Date; let entryPath: String; var sequence = 0 }
  private struct Pending { let id: String; let body: Data }
  private var consent = false
  private var recording: Recording?
  private var events: [ReplayEvent] = []
  private var eventBytes = 0
  private var lastT = 0
  private var lastNodes: Data?
  private var viewport: (width: Int, height: Int)?
  private var currentPath: String?
  private var blockedScreen = false
  private var hiddenAt: Date?
  private var pending: [Pending] = []
  private var flushing = false
  /// The platform capture (UIKit) attached while recording.
  var attachment: AnyObject?

  init(options: ReplayOptions, workspaceId: String, productId: String, platform: String = "ios", now: @escaping @Sendable () -> Date = { Date() }, person: @escaping @Sendable () -> Person, sessionHash: @escaping @Sendable () -> String? = { nil }, allowed: @escaping @Sendable () -> Bool = { true }, send: Sender?) {
    self.options = options
    self.workspaceId = workspaceId
    self.productId = productId
    self.platform = platform
    self.now = now
    self.person = person
    self.sessionHash = sessionHash
    self.allowed = allowed
    self.send = send
  }

  /// False when the project key or origin is missing or not a project key.
  var isConfigured: Bool { send != nil }

  /// Recording now: configured, consent given, analytics not opted out.
  var isActive: Bool { lock.withLock { consent } && send != nil && allowed() }

  var sessionId: String? { lock.withLock { recording?.id } }

  /// The developer's declaration that the person agreed to replay. Withdrawing stops at once
  /// and discards everything not yet sent.
  func setConsent(_ granted: Bool) {
    lock.withLock {
      consent = granted
      if !granted { clearLocked() }
    }
  }

  private func clearLocked() {
    recording = nil
    events = []
    eventBytes = 0
    pending = []
    lastNodes = nil
    viewport = nil
    hiddenAt = nil
  }

  private func elapsedLocked() -> Int {
    guard let recording else { return 0 }
    let ms = Int((now().timeIntervalSince(recording.startedAt) * 1000).rounded(.down))
    lastT = min(Self.maxRecordingMs, max(lastT, ms))
    return lastT
  }

  private func appendLocked(_ event: ReplayEvent, bytes: Int = 64) {
    events.append(event)
    eventBytes += bytes
  }

  private func startIfNeededLocked() {
    if let recording, now().timeIntervalSince(recording.startedAt) * 1000 >= Double(Self.maxRecordingMs) { endLocked() }
    guard recording == nil else { return }
    let path = currentPath ?? "/"
    recording = Recording(id: "rpl_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), startedAt: now(), entryPath: path)
    events = []
    eventBytes = 0
    lastT = 0
    lastNodes = nil
    viewport = nil
    appendLocked(.navigation(t: 0, path: path))
  }

  /// Ends the recording: what is left goes out as its last chunk.
  private func endLocked() {
    if let chunk = chunkLocked(ended: true) { enqueueLocked(chunk) }
    recording = nil
    lastNodes = nil
    viewport = nil
  }

  private func enqueueLocked(_ chunk: Pending) {
    pending.append(chunk)
    if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
  }

  private func chunkLocked(ended: Bool) -> Pending? {
    guard var current = recording, !events.isEmpty else { return nil }
    let who = person()
    let hashes = personHashes(who.distinctId)
    let hash = sessionHash().flatMap { $0.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil ? $0 : nil }
    let size = viewport ?? (1, 1)
    let chunk = ReplayChunk(
      sessionId: current.id, workspaceId: workspaceId, productId: productId, sequence: current.sequence,
      startedAt: ISO8601DateFormatter().string(from: current.startedAt), entryPath: current.entryPath,
      viewport: .init(width: max(1, size.width), height: max(1, size.height)),
      consentPolicyVersion: String(options.consentPolicyVersion.prefix(80)), platform: platform,
      person: .init(distinctHash: hashes.first, distinctHash2: hashes.second, identified: who.identified),
      sessionHash: hash, ended: ended, events: events)
    guard let body = try? encoder.encode(chunk) else { return nil }
    current.sequence += 1
    recording = current
    events = []
    eventBytes = 0
    return Pending(id: "\(current.id):\(current.sequence - 1)", body: body)
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
    guard isActive, !lock.withLock({ blockedScreen }) else { return false }
    let nodes = WireframeBuilder.build(root, screenWidth: width, screenHeight: height, options: options)
    guard let encoded = try? encoder.encode(nodes) else { return false }
    return lock.withLock {
      guard consent else { return false }
      startIfNeededLocked()
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

  /// The app went to the background (true) or came back. Back after 30 minutes away starts a new recording.
  func visibility(hidden: Bool) {
    lock.withLock {
      guard consent, recording != nil else { return }
      if hidden {
        hiddenAt = now()
        appendLocked(.visibility(t: elapsedLocked(), hidden: true))
      } else {
        if let away = hiddenAt, now().timeIntervalSince(away) * 1000 >= Double(Self.idleRestartMs) {
          endLocked()
        } else {
          appendLocked(.visibility(t: elapsedLocked(), hidden: false))
        }
        hiddenAt = nil
      }
    }
  }

  /// The person changed (reset, log-out): the recording ends and the next one starts fresh.
  func personChanged() {
    lock.withLock { if recording != nil { endLocked() } }
  }

  /// Enough waiting to upload now rather than at the next timer.
  var shouldFlush: Bool { lock.withLock { events.count >= Self.maxEvents || eventBytes >= Self.maxBytes } }

  /// Upload what is waiting, oldest first. A chunk that could not be delivered is kept, with
  /// its sequence, and sent again next time.
  func flush() async {
    guard let send else { return }
    let batch: [Pending]? = lock.withLock {
      guard !flushing else { return nil }
      if consent, let chunk = chunkLocked(ended: false) { enqueueLocked(chunk) }
      guard !pending.isEmpty else { return nil }
      flushing = true
      return pending
    }
    guard let batch else { return }
    for item in batch {
      let result = await send(item.body)
      guard case .done = result else { break }
      lock.withLock { pending.removeAll { $0.id == item.id } }
    }
    lock.withLock { flushing = false }
  }

  /// For tests: what is waiting to be sent.
  var pendingCount: Int { lock.withLock { pending.count } }
  var eventCount: Int { lock.withLock { events.count } }
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
