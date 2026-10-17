import Foundation

/// An answer to a survey question: text (an option, a category, free text) or a number.
public enum SurveyValue: Sendable, Equatable {
  case text(String)
  case number(Double)

  var json: Any {
    switch self {
    case .text(let value): return value
    case .number(let value): return value
    }
  }
}

/// Where a question's answers lead: each rule is an answer (an option, a category) or a
/// rating rule (`9`, `0-6`) with its target, a later question's key or `end`. The rules keep
/// the order the server sent them in, which decides between overlapping rating rules (see
/// `SurveyOffer.route`).
public struct SurveyBranch: Sendable, Equatable, ExpressibleByDictionaryLiteral {
  public struct Rule: Sendable, Equatable {
    public let rule: String
    public let target: String
  }

  /// The rules as written. As in a JavaScript object, a repeated rule keeps its first place
  /// and takes its last target.
  public private(set) var rules: [Rule] = []

  init(_ pairs: [(String, String)]) {
    for (rule, target) in pairs {
      if let index = rules.firstIndex(where: { $0.rule == rule }) { rules[index] = Rule(rule: rule, target: target) } else { rules.append(Rule(rule: rule, target: target)) }
    }
  }

  public init(dictionaryLiteral elements: (String, String)...) { self.init(elements) }

  /// The target of one rule, looked up by name.
  public subscript(rule: String) -> String? { rules.first { $0.rule == rule }?.target }
  public var isEmpty: Bool { rules.isEmpty }
}

/// One of a survey's additional questions, asked after the primary one.
public struct SurveyQuestion: Sendable, Equatable {
  public enum Kind: String, Sendable {
    /// Free text.
    case open
    /// One of `options`.
    case choice
    /// A whole number in `scale`.
    case rating
  }

  public let key: String
  public let text: String
  public let type: Kind
  public let options: [String]
  public let scale: ClosedRange<Int>
  /// Where an answer leads: a later question's key, or `end`. See `SurveyOffer.route`.
  public let branch: SurveyBranch
}

/// A survey the server offers this person now, from `ApphelmClient.surveyEligible`. The app
/// draws it: `question` first (answered by a category or a score, by `templateType`), then
/// `openTextPrompt` and `followUpQuestion` if present, then the `additional` questions that
/// `nextQuestion` gives, and sends everything once with `ApphelmClient.surveyRespond`.
public struct SurveyOffer: Sendable, Equatable {
  public let exposureId: String
  /// True when it was offered to an anonymous person (no `externalUserId`).
  public let anonymous: Bool
  public let programId: String
  public let name: String
  /// `pmf` (category `very_disappointed`, `somewhat_disappointed` or `not_disappointed`),
  /// `nps` (score 0–10), `csat` (1–5), `ces` (1–7) or `custom` (a category from `options`,
  /// or a score).
  public let templateType: String
  public let version: Int
  public let question: String
  public let openTextPrompt: String?
  /// A custom survey's answer options.
  public let options: [String]
  public let followUpQuestion: String?
  public let additional: [SurveyQuestion]
  /// The primary question's branch.
  public let branch: SurveyBranch
  public let expiresAt: Date
  /// The workspace's privacy notice for this survey, an https link, to show beside it as
  /// "How we use this"; nil when the workspace has none.
  public var privacyNoticeUrl: String? = nil

  /// The additional questions this person is asked, in order, given the primary answer (the
  /// category or the score) and the answers so far: an answer's branch jumps forward to a
  /// later question or ends the survey, and a question with no answer leads to the next
  /// one. The server walks the same route and refuses a response that answers a question
  /// off it.
  public func route(primaryAnswer: SurveyValue?, answers: [String: SurveyValue] = [:]) -> [SurveyQuestion] {
    let keys = additional.map(\.key)
    func jump(_ target: String?, from: Int) -> Int {
      guard let target else { return from + 1 }
      if target == "end" { return keys.count }
      return max(from + 1, keys.firstIndex(of: target) ?? -1)
    }
    var route: [SurveyQuestion] = []
    var index = jump(branchTarget(branch, answer: primaryAnswer), from: -1)
    while index < keys.count {
      route.append(additional[index])
      index = jump(branchTarget(additional[index].branch, answer: answers[keys[index]]), from: index)
    }
    return route
  }

  /// The question to ask next: the first on the `route` when `after` is nil, otherwise the
  /// one that follows the question with the key `after`. Nil when the survey is over. Pass
  /// the answers given so far; leave a skipped question out of them.
  public func nextQuestion(primaryAnswer: SurveyValue?, answers: [String: SurveyValue] = [:], after: String? = nil) -> SurveyQuestion? {
    let route = route(primaryAnswer: primaryAnswer, answers: answers)
    guard let after else { return route.first }
    guard let asked = route.firstIndex(where: { $0.key == after }), asked + 1 < route.count else { return nil }
    return route[asked + 1]
  }
}

/// What the person answered. `category` or `numericScore` answers the primary question,
/// `answers` the additional ones by key. `permission` is how the answer may be used.
public struct SurveyAnswer: Sendable, Equatable {
  public enum Permission: String, Sendable {
    case privateAnalysis = "private_analysis"
    case attributedInternal = "attributed_internal"
    case quotable
  }

  public var category: String?
  public var numericScore: Double?
  public var openText: String?
  public var followUpAnswer: String?
  public var answers: [String: SurveyValue]
  public var permission: Permission

  public init(category: String? = nil, numericScore: Double? = nil, openText: String? = nil, followUpAnswer: String? = nil, answers: [String: SurveyValue] = [:], permission: Permission = .privateAnalysis) {
    self.category = category
    self.numericScore = numericScore
    self.openText = openText
    self.followUpAnswer = followUpAnswer
    self.answers = answers
    self.permission = permission
  }
}

/// A rating rule: one whole number (`9`) or a range (`0-6`), each of one or two digits.
private func ratingRule(_ rule: String) -> ClosedRange<Int>? {
  let parts = rule.split(separator: "-", omittingEmptySubsequences: false)
  guard parts.count == 1 || parts.count == 2,
        parts.allSatisfy({ (1...2).contains($0.utf8.count) && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
        let low = Int(parts[0]), let high = Int(parts[parts.count - 1]), low <= high else { return nil }
  return low...high
}

/// A key JavaScript treats as an array index (`7`, not `07` or `+7`): Object.entries gives
/// those first, ascending, and every other key in the order it was written.
private func isIndexKey(_ key: String) -> Bool {
  guard let index = UInt32(key) else { return false }
  return index < UInt32.max && String(index) == key
}

/// Where a branch sends an answer: a question key, `end`, or nil for "the next in order".
/// A text answer is looked up by name; a number takes the first rating rule (`9`, `0-6`)
/// that holds it, in the order the server's JavaScript reads them (lib/feedback.ts
/// branchTarget): whole-number rules ascending, then the rest as written.
func branchTarget(_ branch: SurveyBranch, answer: SurveyValue?) -> String? {
  switch answer {
  case nil: return nil
  case .text(let value): return branch[value]
  case .number(let value):
    let indexed = branch.rules.filter { isIndexKey($0.rule) }.sorted { UInt32($0.rule)! < UInt32($1.rule)! }
    let written = branch.rules.filter { !isIndexKey($0.rule) }
    return (indexed + written).first { rule in ratingRule(rule.rule).map { value >= Double($0.lowerBound) && value <= Double($0.upperBound) } ?? false }?.target
  }
}

/// The two person hashes an anonymous survey request carries in place of the raw id: the
/// ones the server keeps on that person's events (distinctHashOf and distinctHash2Of in
/// lib/event-facts.ts), over the id's UTF-16 code units as JavaScript computes them.
func personHashes(_ distinctId: String) -> (first: String, second: String) {
  let units = Array(distinctId.utf16)
  var first: UInt32 = 2_166_136_261
  for unit in units { first = (first ^ UInt32(unit)) &* 16_777_619 }
  var second: UInt32 = 0x9747_b28c ^ UInt32(truncatingIfNeeded: units.count)
  for unit in units {
    second = (second ^ UInt32(unit)) &* 0x5bd1_e995
    second ^= second >> 15
  }
  return (String(format: "%08x", first), String(format: "%08x", second))
}

/// A JSON object with its keys in the order they were written. JSONSerialization drops the
/// order, and a branch's overlapping rules are read in it.
struct OrderedJSONObject {
  let pairs: [(key: String, value: Any)]
  subscript(key: String) -> Any? { pairs.last { $0.key == key }?.value }
}

/// Parse JSON as JSONSerialization does (strings, NSNumber, NSNull, arrays), except that an
/// object is an `OrderedJSONObject`. Nil for anything that is not one JSON value.
func parseJSONKeepingOrder(_ data: Data) -> Any? {
  let bytes = [UInt8](data)
  var at = 0
  func skipSpace() { while at < bytes.count, [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
  func next(_ byte: Character) -> Bool {
    skipSpace()
    guard at < bytes.count, bytes[at] == byte.asciiValue else { return false }
    at += 1
    return true
  }
  // A string or a number is handed to JSONSerialization, so it decodes exactly as before.
  func scalar(_ start: Int) -> Any? { at <= bytes.count ? try? JSONSerialization.jsonObject(with: Data(bytes[start..<at]), options: .fragmentsAllowed) : nil }
  func value(_ depth: Int) -> Any? {
    skipSpace()
    guard at < bytes.count, depth < 64 else { return nil }
    let start = at
    switch bytes[at] {
    case UInt8(ascii: "{"):
      at += 1
      var pairs: [(key: String, value: Any)] = []
      if next("}") { return OrderedJSONObject(pairs: pairs) }
      repeat {
        skipSpace()
        guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), let key = value(depth + 1) as? String, next(":"), let item = value(depth + 1) else { return nil }
        pairs.append((key, item))
      } while next(",")
      return next("}") ? OrderedJSONObject(pairs: pairs) : nil
    case UInt8(ascii: "["):
      at += 1
      var items: [Any] = []
      if next("]") { return items }
      repeat {
        guard let item = value(depth + 1) else { return nil }
        items.append(item)
      } while next(",")
      return next("]") ? items : nil
    case UInt8(ascii: "\""):
      at += 1
      while at < bytes.count, bytes[at] != UInt8(ascii: "\"") { at += bytes[at] == UInt8(ascii: "\\") ? 2 : 1 }
      at += 1
      return scalar(start)
    default:
      while at < bytes.count, !"{}[],:\" \t\r\n".utf8.contains(bytes[at]) { at += 1 }
      return scalar(start)
    }
  }
  let result = value(0)
  skipSpace()
  return at == bytes.count ? result : nil
}

func surveyOffer(_ data: OrderedJSONObject) -> SurveyOffer? {
  guard let exposureId = data["exposureId"] as? String, let program = data["program"] as? OrderedJSONObject else { return nil }
  let question = program["question"] as? OrderedJSONObject ?? OrderedJSONObject(pairs: [])
  func whole(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
  // Targets that are not text are left out, as the Kotlin client does.
  func branch(_ of: OrderedJSONObject?) -> SurveyBranch { SurveyBranch((of?["branch"] as? OrderedJSONObject)?.pairs.compactMap { rule in (rule.value as? String).map { (rule.key, $0) } } ?? []) }
  let additional: [SurveyQuestion] = (question["additional"] as? [Any] ?? []).compactMap { entry in
    guard let item = entry as? OrderedJSONObject, let key = item["key"] as? String else { return nil }
    let scale = item["scale"] as? OrderedJSONObject
    let low = whole(scale?["min"]) ?? 1
    return SurveyQuestion(
      key: key, text: item["text"] as? String ?? "", type: SurveyQuestion.Kind(rawValue: item["type"] as? String ?? "") ?? .open,
      options: item["options"] as? [String] ?? [], scale: low...max(low, whole(scale?["max"]) ?? 5), branch: branch(item))
  }
  return SurveyOffer(
    exposureId: exposureId, anonymous: data["anonymous"] as? Bool == true, programId: program["id"] as? String ?? "", name: program["name"] as? String ?? "",
    templateType: program["templateType"] as? String ?? "", version: whole(program["version"]) ?? 0, question: question["primary"] as? String ?? "",
    openTextPrompt: question["openText"] as? String, options: question["customOptions"] as? [String] ?? [],
    followUpQuestion: (program["followUp"] as? OrderedJSONObject)?["question"] as? String, additional: additional, branch: branch(question),
    expiresAt: Date(timeIntervalSince1970: (data["expiresAt"] as? NSNumber)?.doubleValue ?? 0),
    privacyNoticeUrl: ((data["privacyNotice"] as? OrderedJSONObject)?["url"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil })
}
