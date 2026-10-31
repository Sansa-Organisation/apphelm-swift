import Foundation

/// How a drawn survey looks (surveyAppearanceSchema in lib/feedback.ts). Colours are
/// `#rrggbb`; unset fields take the defaults below.
public struct SurveyAppearance: Sendable, Equatable {
  /// `bottom_right`, `bottom_left`, `bottom_center` (a sheet on mobile), `center` or `top_center` (a card).
  public var position: String = "bottom_right"
  public var backgroundColor: String = "#ffffff"
  public var textColor: String = "#1d2730"
  public var buttonColor: String = "#1f6feb"
  public var buttonTextColor: String = "#ffffff"
  public var submitText: String = "Submit"
  public var thankYouText: String? = nil
  public var placeholder: String? = nil
  public var hideBranding: Bool = false
  public var maxWidth: Int = 360

  public init() {}

  /// True when the survey is drawn as a centred card rather than a bottom sheet.
  public var isCard: Bool { position == "center" || position == "top_center" }
}

func surveyAppearance(_ data: OrderedJSONObject) -> SurveyAppearance {
  var value = SurveyAppearance()
  func color(_ key: String) -> String? { (data[key] as? String).flatMap { $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil ? $0 : nil } }
  func text(_ key: String, _ limit: Int) -> String? { (data[key] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)) }.flatMap { $0.isEmpty ? nil : $0 } }
  if let position = data["position"] as? String, ["bottom_right", "bottom_left", "bottom_center", "center", "top_center"].contains(position) { value.position = position }
  if let color = color("backgroundColor") { value.backgroundColor = color }
  if let color = color("textColor") { value.textColor = color }
  if let color = color("buttonColor") { value.buttonColor = color }
  if let color = color("buttonTextColor") { value.buttonTextColor = color }
  if let submit = text("submitText", 40) { value.submitText = submit }
  value.thankYouText = text("thankYouText", 200)
  value.placeholder = text("placeholder", 100)
  value.hideBranding = data["hideBranding"] as? Bool == true
  if let width = (data["maxWidth"] as? NSNumber)?.intValue { value.maxWidth = min(560, max(240, width)) }
  return value
}

/// One screen of a drawn survey: the primary question, the open-text prompt, the follow-up,
/// or an additional question. `key` is `$primary`, `$open_text`, `$follow_up` or the
/// additional question's key. The same steps as survey-flow.ts in the TypeScript SDK.
public struct SurveyStep: Sendable, Equatable {
  public let key: String
  public let text: String
  public let type: SurveyQuestion.Kind
  public var options: [String] = []
  /// Friendlier names for option values (PMF answers).
  public var labels: [String: String] = [:]
  public var scale: ClosedRange<Int> = 1...5
  public var display: String? = nil
  public var lowerLabel: String? = nil
  public var upperLabel: String? = nil
  public var link: String? = nil
  public var buttonText: String? = nil
  /// Whether the step can be passed without an answer.
  public let optional: Bool

  /// The text to show for an option.
  public func label(_ option: String) -> String { labels[option] ?? option }
  /// True for a rating drawn as faces (`ratingFaces`).
  public var showsFaces: Bool { type == .rating && display == "emoji" && scale.lowerBound == 1 && (scale.upperBound == 3 || scale.upperBound == 5) }
}

let pmfOptions = ["very_disappointed", "somewhat_disappointed", "not_disappointed"]
private let pmfLabels = ["very_disappointed": "Very disappointed", "somewhat_disappointed": "Somewhat disappointed", "not_disappointed": "Not disappointed"]

/// The primary question of an offer as a step.
func primaryStep(_ offer: SurveyOffer) -> SurveyStep {
  let text = String(offer.question.prefix(500))
  switch offer.templateType {
  case "pmf": return SurveyStep(key: "$primary", text: text, type: .choice, options: pmfOptions, labels: pmfLabels, optional: false)
  case "custom":
    if offer.primaryType == "open" { return SurveyStep(key: "$primary", text: text, type: .open, optional: false) }
    if offer.primaryType == "link" { return SurveyStep(key: "$primary", text: text, type: .link, link: offer.link, buttonText: offer.buttonText, optional: false) }
    return SurveyStep(key: "$primary", text: text, type: .choice, options: Array(offer.options.prefix(10)), optional: false)
  case "nps": return SurveyStep(key: "$primary", text: text, type: .rating, scale: 0...10, optional: false)
  case "csat": return SurveyStep(key: "$primary", text: text, type: .rating, scale: 1...5, optional: false)
  case "ces": return SurveyStep(key: "$primary", text: text, type: .rating, scale: 1...7, optional: false)
  default: return SurveyStep(key: "$primary", text: text, type: .rating, scale: 0...10, optional: false)
  }
}

/// Faces for a 3- or 5-point rating, lowest first.
public func ratingFaces(_ max: Int) -> [String] {
  max == 3 ? ["😞", "😐", "😊"] : ["😡", "😞", "😐", "🙂", "😍"]
}

/// The link when it is https, else nil: only https links are opened.
public func safeSurveyLink(_ value: String?) -> URL? {
  guard let value, value.range(of: "^https://[^\\s<>\"]+$", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
  return URL(string: value)
}

/// Walks a survey offer one step at a time, in the order the server checks: the primary
/// question, the open-text prompt, the follow-up, then the additional questions on the route
/// their branches pick. Every drawn survey (the SwiftUI view, the Kotlin and React Native
/// ones, the browser widget) walks this order and builds the same `SurveyAnswer`.
///
/// ```swift
/// var flow = SurveyFlow(offer)
/// flow.answer(.number(9))   // the NPS score
/// flow.answer(nil)          // skip the open text
/// if flow.isDone { try await client.surveyRespond(exposureId: offer.exposureId, answer: flow.response) }
/// ```
public struct SurveyFlow: Sendable, Equatable {
  private enum Phase: Sendable, Equatable { case primary, extras, additional, done }

  public let offer: SurveyOffer
  private let primary: SurveyStep
  private let extras: [SurveyStep]
  private let additional: [SurveyQuestion]
  private var phase: Phase = .primary
  private var extraIndex = 0
  private var index = -1
  private var answered = 0
  private var primaryAnswer: SurveyValue?
  private var answer = SurveyAnswer()

  public init(_ offer: SurveyOffer) {
    self.offer = offer
    primary = primaryStep(offer)
    additional = Array(offer.additional.prefix(4))
    var extras: [SurveyStep] = []
    // A custom open question already is the open text.
    if let prompt = offer.openTextPrompt, primary.type != .open {
      extras.append(SurveyStep(key: "$open_text", text: String(prompt.prefix(500)), type: .open, optional: true))
    } else if offer.followUpQuestion != nil, primary.type != .open {
      extras.append(SurveyStep(key: "$open_text", text: "Anything to add? (optional)", type: .open, optional: true))
    }
    if let followUp = offer.followUpQuestion { extras.append(SurveyStep(key: "$follow_up", text: String(followUp.prefix(500)), type: .open, optional: true)) }
    self.extras = extras
  }

  /// The step to show now, or nil when the survey is finished.
  public var current: SurveyStep? {
    switch phase {
    case .primary: return primary
    case .extras: return extraIndex < extras.count ? extras[extraIndex] : nil
    case .additional:
      guard index >= 0, index < additional.count else { return nil }
      let item = additional[index]
      return SurveyStep(key: item.key, text: item.text, type: item.type, options: item.options, scale: item.scale, display: item.display, lowerLabel: item.lowerLabel, upperLabel: item.upperLabel, link: item.link, buttonText: item.buttonText, optional: true)
    case .done: return nil
    }
  }

  public var isDone: Bool { phase == .done }
  /// True once the primary question is answered: from then on the response is worth sending.
  public var hasAnswer: Bool { phase != .primary }

  /// 1-based position and an estimate of the steps on this route.
  public var progress: (step: Int, total: Int) { (answered + 1, max(answered + 1, 1 + extras.count + additional.count)) }

  /// The response to send once finished (or, after the primary question, when the person leaves early).
  public var response: SurveyAnswer { answer }

  private func jump(_ target: String?, from: Int) -> Int {
    guard let target else { return from + 1 }
    if target == "end" { return additional.count }
    return max(from + 1, additional.firstIndex { $0.key == target } ?? -1)
  }

  private mutating func settle() {
    if phase == .extras, extraIndex >= extras.count { phase = .additional; index = jump(branchTarget(offer.branch, answer: primaryAnswer), from: -1) }
    if phase == .additional, index >= additional.count { phase = .done }
  }

  /// Answer the current step; nil passes an optional step. A required step left empty stays
  /// where it is. Returns the next step.
  @discardableResult
  public mutating func answer(_ value: SurveyValue?) -> SurveyStep? {
    guard let step = current else { return nil }
    if !step.optional {
      switch value {
      case nil: return step
      case .text(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return step
      case .list(let items) where items.isEmpty: return step
      default: break
      }
    }
    answered += 1
    switch phase {
    case .primary:
      primaryAnswer = value
      switch (step.type, value) {
      case (.rating, .number(let score)?): answer.numericScore = score
      case (.open, .text(let text)?): answer.openText = String(text.prefix(2_000))
      case (.link, _): answer.category = "clicked"
      case (_, .text(let text)?): answer.category = text
      default: break
      }
      phase = .extras
    case .extras:
      var text = ""
      if case .text(let raw)? = value { text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)) }
      if !text.isEmpty, step.key == "$open_text" { answer.openText = text }
      if !text.isEmpty, step.key == "$follow_up" { answer.followUpAnswer = text }
      extraIndex += 1
    case .additional:
      let item = additional[index]
      var kept = value
      if case .text(let text)? = value, item.type == .open { kept = .text(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))) }
      switch kept {
      case nil, .text("")?, .list([])?: break
      case let kept?: answer.answers[item.key] = kept
      }
      index = jump(branchTarget(item.branch, answer: kept), from: index)
    case .done: break
    }
    settle()
    return current
  }

  public static func == (left: SurveyFlow, right: SurveyFlow) -> Bool {
    left.offer == right.offer && left.phase == right.phase && left.extraIndex == right.extraIndex && left.index == right.index && left.answered == right.answered && left.answer == right.answer
  }
}
