import Foundation

/// The scrubber every AppHelm SDK runs before an event leaves the process: the union of the
/// server's two built-in scrubbers (`scrubSecretsAndEmails` in lib/event-facts.ts and
/// `redactLogText` in lib/logs/records.ts), so nothing the server would redact on any path is
/// sent in the clear. It can't be turned off; `beforeSend` sees its output.
///
/// A port of packages/sdk/src/scrub.ts: the same rules in the same order, checked against the
/// shared vectors (packages/sdk-fixtures/scrub-vectors.json, copied to
/// Tests/ApphelmTests/Fixtures). Change a rule there, in every port and in the vectors together.
///
/// JavaScript's `\b` is an ASCII word boundary; ICU's is Unicode, so each `\b` is written as the
/// ASCII lookaround it stands for. `&` is escaped inside sets because ICU reads `&&` there as
/// intersection. Lengths are left to the caller.
private let wordBefore = "(?<![A-Za-z0-9_])"
private let wordAfter = "(?![A-Za-z0-9_])"

private func rule(_ pattern: String, _ template: String, ignoreCase: Bool = false) -> (NSRegularExpression, String) {
  // The patterns are constants: a failure here is a bug caught by the vector tests.
  (try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []), template)
}

private let scrubRules: [(NSRegularExpression, String)] = [
  rule("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----", "[private key]"),
  rule(wordBefore + "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}", "[jwt]"),
  rule("ahl_[A-Za-z0-9._:-]{8,160}", "[key]"),
  rule(wordBefore + "sk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}", "[key]"),
  rule(wordBefore + "(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}", "[key]"),
  rule(wordBefore + "(?:AKIA|ASIA)[A-Z0-9]{16}" + wordAfter, "[key]"),
  rule(wordBefore + "gh[pousr]_[A-Za-z0-9]{20,}", "[key]"),
  rule(wordBefore + "xox[abpr]-[A-Za-z0-9-]{10,}", "[key]"),
  rule(wordBefore + "AIza[0-9A-Za-z_-]{35}" + wordAfter, "[key]"),
  rule(wordBefore + "(bearer|basic)(?:\\s*[:=]\\s*|\\s+)[A-Za-z0-9._~+/=-]{8,}", "$1 [redacted]", ignoreCase: true),
  rule("(password|passwd|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|client[_-]?secret|authorization|bearer|basic)([\"']?\\s*[:=]\\s*[\"']?)[^\\s\"'\\&,;}]{4,}", "$1$2[redacted]", ignoreCase: true),
  rule("([?\\&](?:token|key|secret|password|auth|signature|sig|access_token|code)=)[^\\&\\s\"']{1,400}", "$1[redacted]", ignoreCase: true),
  rule("(//[^/\\s:@]{1,100}:)[^@\\s/]{1,200}@", "$1[redacted]@"),
  rule("[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\\.[A-Za-z]{2,24}", "[email]"),
  rule(wordBefore + "[0-9a-f]{32,128}" + wordAfter, "[token]", ignoreCase: true),
]

private let frameQuery = try! NSRegularExpression(pattern: "\\?[^\\s)\"']*")
private let urlUserInfo = try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@")
private let queryOrFragment = CharacterSet(charactersIn: "?#")

private func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
  regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
}

/// Secrets and emails out of free text: exception messages, tags, crash reasons.
func scrubText(_ value: String) -> String {
  guard !value.isEmpty else { return value }
  var out = value
  for (regex, template) in scrubRules { out = replacing(regex, in: out, with: template) }
  return out
}

/// A stack frame, breadcrumb message or span description: query strings removed, then scrubbed.
func scrubFrame(_ value: String) -> String {
  scrubText(replacing(frameQuery, in: value, with: ""))
}

private let sqlStart = try! NSRegularExpression(pattern: "^\\s*(?:select|insert|update|delete|with|replace|upsert)" + wordAfter, options: [.caseInsensitive])

/// A span description or transaction name: SQL (it starts with one of the server's SQL verbs)
/// keeps its `?` placeholders and goes through `scrubText`; anything else through `scrubFrame`.
func scrubDescription(_ value: String) -> String {
  let isSQL = sqlStart.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
  return isSQL ? scrubText(value) : scrubFrame(value)
}

/// A URL as `url.full` carries it: no query, fragment or user info, then scrubbed.
func scrubUrl(_ value: String) -> String {
  let text = value as NSString
  let mark = text.rangeOfCharacter(from: queryOrFragment)
  let cut = mark.location == NSNotFound ? value : text.substring(to: mark.location)
  return scrubText(replacing(urlUserInfo, in: cut, with: "$1"))
}

/// The most of a string the scrubber reads; the caller's own, shorter cap is applied after.
let scrubInputLimit = 10_000

/// `value` scrubbed by `scrub`, then cut to `limit` characters.
func scrubbed(_ value: String, limit: Int, _ scrub: (String) -> String = scrubText) -> String {
  String(scrub(String(value.prefix(scrubInputLimit))).prefix(limit))
}
