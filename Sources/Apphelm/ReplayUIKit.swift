#if canImport(UIKit) && !os(watchOS)
import UIKit

private nonisolated(unsafe) var noCaptureKey: UInt8 = 0
private nonisolated(unsafe) var maskKey: UInt8 = 0
private nonisolated(unsafe) var replayIdKey: UInt8 = 0
@MainActor private var nextReplayId = 0

public extension UIView {
  /// Leave this view and everything inside it out of session replay: it is drawn as an empty
  /// box. An `accessibilityIdentifier` containing `ph-no-capture` or `apphelm-no-capture` does the same.
  var apphelmReplayNoCapture: Bool {
    get { (objc_getAssociatedObject(self, &noCaptureKey) as? Bool) ?? false }
    set { objc_setAssociatedObject(self, &noCaptureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }

  /// Mask the text of this view and the views inside it (asterisks). An `accessibilityIdentifier`
  /// containing `ph-mask` or `apphelm-mask` does the same.
  var apphelmReplayMask: Bool {
    get { (objc_getAssociatedObject(self, &maskKey) as? Bool) ?? false }
    set { objc_setAssociatedObject(self, &maskKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }
}

private func hex(_ color: UIColor?) -> String? {
  guard let color else { return nil }
  var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
  guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.01 else { return nil }
  func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
  return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
}

/// Walks the key window on the main thread and feeds the recorder.
@MainActor
final class ReplayUIKitCapture: NSObject, UIGestureRecognizerDelegate {
  private let recorder: ReplayRecorder
  private var timer: Timer?
  private var flushTimer: Timer?
  private weak var tappedWindow: UIWindow?
  private var recognizer: UITapGestureRecognizer?

  init(recorder: ReplayRecorder) {
    self.recorder = recorder
  }

  static func start(_ recorder: ReplayRecorder) {
    guard recorder.attachment == nil else { return }
    let capture = ReplayUIKitCapture(recorder: recorder)
    recorder.attachment = capture
    capture.begin()
  }

  static func stop(_ recorder: ReplayRecorder) {
    (recorder.attachment as? ReplayUIKitCapture)?.end()
    recorder.attachment = nil
  }

  private func begin() {
    timer = Timer.scheduledTimer(withTimeInterval: max(0.25, recorder.options.checkIntervalSeconds), repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    let recorder = self.recorder
    flushTimer = Timer.scheduledTimer(withTimeInterval: max(1, recorder.options.flushIntervalSeconds), repeats: true) { _ in
      Task { await recorder.flush() }
    }
    tick()
  }

  private func end() {
    timer?.invalidate()
    flushTimer?.invalidate()
    timer = nil
    flushTimer = nil
    if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
    recognizer = nil
  }

  private func keyWindow() -> UIWindow? {
    sharedApplication()?.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
  }

  func tick() {
    guard recorder.isActive, let window = keyWindow() else { return }
    if tappedWindow !== window {
      if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      tap.cancelsTouchesInView = false
      tap.delaysTouchesEnded = false
      tap.delegate = self
      window.addGestureRecognizer(tap)
      recognizer = tap
      tappedWindow = window
    }
    recorder.capture(describe(window, in: window), width: Double(window.bounds.width), height: Double(window.bounds.height))
    if recorder.shouldFlush {
      let recorder = self.recorder
      Task { await recorder.flush() }
    }
  }

  @objc private func tapped(_ gesture: UITapGestureRecognizer) {
    guard let window = gesture.view else { return }
    let point = gesture.location(in: window)
    recorder.tap(x: Double(point.x), y: Double(point.y))
  }

  nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

  private func id(of view: UIView) -> Int {
    if let id = objc_getAssociatedObject(view, &replayIdKey) as? Int { return id }
    nextReplayId += 1
    objc_setAssociatedObject(view, &replayIdKey, nextReplayId, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return nextReplayId
  }

  func describe(_ view: UIView, in window: UIWindow) -> ReplayViewNode {
    let frame = view.convert(view.bounds, to: window)
    var node = ReplayViewNode(id: id(of: view))
    node.x = Double(frame.minX); node.y = Double(frame.minY); node.width = Double(frame.width); node.height = Double(frame.height)
    node.hidden = view.isHidden
    node.alpha = Double(view.alpha)
    node.background = hex(view.backgroundColor)
    if view.layer.borderWidth > 0, let border = view.layer.borderColor { node.border = hex(UIColor(cgColor: border)); node.borderWidth = Double(view.layer.borderWidth) }
    node.cornerRadius = Double(view.layer.cornerRadius)
    let identifier = view.accessibilityIdentifier ?? ""
    node.noCapture = view.apphelmReplayNoCapture || identifier.contains("ph-no-capture") || identifier.contains("apphelm-no-capture")
    node.mask = view.apphelmReplayMask || identifier.contains("ph-mask") || identifier.contains("apphelm-mask")
    switch view {
    case let field as UITextField:
      node.kind = .input
      node.isSecure = field.isSecureTextEntry || field.textContentType == .password || field.textContentType == .newPassword
      node.text = field.text
      node.foreground = hex(field.textColor)
      node.fontSize = field.font.map { Double($0.pointSize) }
    case let text as UITextView:
      node.kind = text.isEditable ? .input : .text
      node.isSecure = text.isSecureTextEntry
      node.text = text.text
      node.foreground = hex(text.textColor)
      node.fontSize = text.font.map { Double($0.pointSize) }
    case let label as UILabel:
      node.kind = .text
      node.text = label.text
      node.foreground = hex(label.textColor)
      node.fontSize = Double(label.font.pointSize)
    case let button as UIButton:
      node.kind = .button
      node.text = button.title(for: .normal) ?? button.titleLabel?.text
      node.foreground = hex(button.titleColor(for: .normal))
      node.fontSize = button.titleLabel.map { Double($0.font.pointSize) }
    case let toggle as UISwitch:
      node.kind = .toggle
      node.isOn = toggle.isOn
      node.background = hex(toggle.isOn ? (toggle.onTintColor ?? .systemGreen) : toggle.backgroundColor)
    case is UIImageView:
      node.kind = .image
    default:
      // WebKit is not linked for this check; the class name is enough.
      if NSStringFromClass(type(of: view)).contains("WKWebView") { node.kind = .web }
    }
    if ![.input, .button, .toggle, .image, .web].contains(node.kind) && !node.noCapture {
      node.children = view.subviews.map { describe($0, in: window) }
    }
    return node
  }
}
#endif
