import Foundation

/// How serious a breadcrumb is. Kept on the device for `beforeBreadcrumb`; not sent.
public enum BreadcrumbLevel: String, Sendable {
  case debug, info, warning, error, fatal
}

/// Something that happened before an error: a screen shown, a request made, a button tapped.
/// The last 30 travel with each exception, message and crash report as
/// `{"at", "category", "message"}`; `level` and `data` stay on the device, for your
/// `beforeBreadcrumb` hook to read.
public struct Breadcrumb: Sendable {
  /// Lower-case letters, digits, `_`, `.` and `-`, up to 20 (`navigation`, `http`,
  /// `ui.click`, `app.lifecycle`); anything else is replaced when it is recorded.
  public var category: String
  /// Up to 200 characters. Query strings, fragments and credentials in URLs are removed, and
  /// secrets and emails replaced (`[key]`, `[email]`…), after `beforeBreadcrumb`.
  public var message: String
  public var level: BreadcrumbLevel
  /// Extra detail for your hook, such as a request's status code. Never sent.
  public var data: [String: String]
  public var timestamp: Date

  public init(category: String, message: String, level: BreadcrumbLevel = .info, data: [String: String] = [:], timestamp: Date = Date()) {
    self.category = category
    self.message = message
    self.level = level
    self.data = data
    self.timestamp = timestamp
  }
}

/// A category the server keeps: `[a-z0-9_.-]{1,20}`, upper case lowered and anything else
/// turned into `_`. An empty one is `default`.
func breadcrumbCategory(_ raw: String) -> String {
  let allowed = raw.lowercased().unicodeScalars.map { scalar -> Character in
    let value = scalar.value
    let ok = (value >= 97 && value <= 122) || (value >= 48 && value <= 57) || value == 95 || value == 46 || value == 45
    return ok ? Character(scalar) : "_"
  }
  let text = String(String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(20))
  return text.isEmpty ? "default" : text
}

private let urlQuery = try! NSRegularExpression(pattern: "([A-Za-z][A-Za-z0-9+.-]*://)(?:[^\\s/@]*@)?([^\\s?#]*)[?#]?[^\\s]*")

/// `text` with every URL's query string, fragment and user/password removed: they are where
/// tokens travel. `GET https://api.example.com/v1/cart?token=abc 200` keeps
/// `GET https://api.example.com/v1/cart 200`.
func strippingURLQueries(_ text: String) -> String {
  guard text.contains("://") else { return text }
  let range = NSRange(text.startIndex..., in: text)
  return urlQuery.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2")
}

/// A breadcrumb message as it is kept: URLs stripped, secrets and emails scrubbed
/// (`scrubFrame`), at most 200 characters.
func breadcrumbMessage(_ raw: String) -> String {
  String(scrubFrame(strippingURLQueries(String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(scrubInputLimit)))).prefix(200))
}

/// A bounded buffer of breadcrumbs, the oldest dropped first.
final class BreadcrumbBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var crumbs: [Breadcrumb] = []
  let capacity: Int

  init(capacity: Int) { self.capacity = max(0, capacity) }

  func add(_ crumb: Breadcrumb) {
    guard capacity > 0 else { return }
    lock.withLock {
      crumbs.append(crumb)
      if crumbs.count > capacity { crumbs.removeFirst(crumbs.count - capacity) }
    }
  }

  var all: [Breadcrumb] { lock.withLock { crumbs } }
  func clear() { lock.withLock { crumbs.removeAll() } }
}

/// Breadcrumbs as an event carries them: the last `limit` by time, each with only the three
/// fields the server reads.
func breadcrumbWire(_ crumbs: [Breadcrumb], limit: Int = 30) -> [[String: String]] {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return crumbs.enumerated().sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }.suffix(limit)
    .map { ["at": formatter.string(from: $0.element.timestamp), "category": $0.element.category, "message": $0.element.message] }
}
