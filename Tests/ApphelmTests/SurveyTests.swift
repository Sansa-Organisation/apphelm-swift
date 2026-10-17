import Foundation
import Testing

@testable import Apphelm

// The offer the server sends for a five-question NPS survey with branches (the shape of
// offerEligibleSurvey in lib/feedback.ts). tests/mobile-surveys.test.ts has the server walk
// the same survey.
private let surveyOfferJSON = """
{"data":{"exposureId":"svx_4f1c2d3e","program":{"id":"svp_1","name":"Checkout NPS","templateType":"nps","question":{"primary":"How likely are you to recommend us?","openText":"What is the main reason?","additional":[{"key":"plan","text":"Which plan are you on?","type":"choice","options":["Free","Pro"],"branch":{"Free":"price"}},{"key":"seats","text":"How many seats do you use?","type":"open"},{"key":"price","text":"How fair is the price?","type":"rating","scale":{"min":1,"max":5},"branch":{"4-5":"end","1":"end"}},{"key":"missing","text":"What is missing for you?","type":"open"}],"branch":{"9-10":"end","0-6":"price"}},"followUp":{"question":"May we contact you?"},"version":3},"expiresAt":1800000000}}
"""

/// A stubbed Apphelm that answers survey requests with whatever the test set, and keeps them.
private final class SurveyServer: @unchecked Sendable {
  struct Seen { let path: String; let key: String?; let origin: String?; let authorization: String?; let body: [String: Any]; let raw: String }
  private let lock = NSLock()
  private var seen: [Seen] = []
  private var status = 200
  private var reply = surveyOfferJSON
  let host = "surveys-\(UUID().uuidString.lowercased()).test"

  func answer(_ status: Int = 200, _ reply: String) { lock.withLock { self.status = status; self.reply = reply } }
  var requests: [Seen] { lock.withLock { seen } }
  var last: Seen { requests[requests.count - 1] }

  func options(key: String? = "ahl_pub_test", origin: String? = "https://app.shop.example") -> ApphelmOptions {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: "https://\(host)/", workspaceId: "org_1", productId: "prd_1", distinctId: "user-1")
    options.surveyKey = key
    options.surveyOrigin = origin
    return options
  }

  func session() -> URLSession {
    RoutedURLProtocol.register(host: host) { [self] request in
      let body = (try? requestJSON(request)) ?? [:]
      let raw = String(data: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
      let (status, reply) = lock.withLock { () -> (Int, String) in
        seen.append(Seen(path: request.url?.path ?? "", key: request.value(forHTTPHeaderField: "x-apphelm-key"), origin: request.value(forHTTPHeaderField: "origin"), authorization: request.value(forHTTPHeaderField: "authorization"), body: body, raw: raw))
        return (self.status, self.reply)
      }
      return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!, Data(reply.utf8))
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private func same(_ body: [String: Any], _ json: String) -> Bool {
  guard let expected = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
  return NSDictionary(dictionary: body).isEqual(to: expected)
}

@Suite("Headless surveys")
struct SurveyTests {
  @Test("The anonymous person hashes are the ones the browser and the server compute")
  func hashes() {
    #expect(personHashes("user-1") == ("f5537974", "34443f86"))
    #expect(personHashes("3F2504E0-4F89-11D3-9A0C-0305E82C3301") == ("da1b48a0", "7b8d10e1"))
    #expect(personHashes("a\u{f1}\u{1F600} visitor") == ("5471edec", "24abbad8"))
    #expect(personHashes("a") == ("e40c292c", "453f6523"))
  }

  @Test("A branch sends a text answer by name and a number by the rating rule that holds it")
  func branches() {
    #expect(branchTarget(["Free": "price"], answer: .text("Free")) == "price")
    #expect(branchTarget(["Free": "price"], answer: .text("Pro")) == nil)
    let score: SurveyBranch = ["0-6": "price", "9-10": "end"]
    #expect(branchTarget(score, answer: .number(6)) == "price" && branchTarget(score, answer: .number(7)) == nil && branchTarget(score, answer: .number(10)) == "end")
    #expect(branchTarget(["3": "end"], answer: .number(3)) == "end" && branchTarget(["3": "end"], answer: .number(4)) == nil)
    #expect(branchTarget(score, answer: nil) == nil && branchTarget([:], answer: .text("x")) == nil)
    #expect(branchTarget(["6-0": "end", "abc": "end", "100": "end", "1-2-3": "end", "-3": "end"], answer: .number(3)) == nil)
  }

  @Test("Overlapping rules are read in JavaScript's order: whole numbers ascending, then the rest as written")
  func overlapping() {
    #expect(branchTarget(["0-10": "a", "7": "b", "3": "c"], answer: .number(7)) == "b" && branchTarget(["0-10": "a", "7": "b", "3": "c"], answer: .number(5)) == "a")
    #expect(branchTarget(["5-9": "a", "0-9": "b"], answer: .number(6)) == "a" && branchTarget(["0-9": "b", "5-9": "a"], answer: .number(6)) == "b")
    #expect(branchTarget(["07": "a", "7": "b"], answer: .number(7)) == "b")
    // A rule written twice keeps its first place and its last target, as in a JavaScript object.
    let repeated = SurveyBranch([("5-9", "a"), ("0-9", "b"), ("5-9", "c")])
    #expect(repeated.rules.map(\.rule) == ["5-9", "0-9"] && branchTarget(repeated, answer: .number(6)) == "c")
  }

  @Test("An offer's branches keep the order the server sent, so overlapping rules route as the server does")
  func overlappingOffer() async throws {
    let server = SurveyServer()
    let client = ApphelmClient(options: server.options(), session: server.session(), store: MemoryStore())
    // tests/mobile-surveys.test.ts walks these branches with the server; each list is the
    // route lib/feedback.ts surveyRoute gives for the scores 0 to 10.
    let all = ["plan", "seats", "price", "missing"], price = ["price", "missing"], missing = ["missing"]
    let cases: [(branch: String, routes: [[String]])] = [
      (#"{"0-10":"missing","7":"price","3":"end"}"#, [missing, missing, missing, [], missing, missing, missing, price, missing, missing, missing]),
      (#"{"5-9":"price","0-9":"missing"}"#, [missing, missing, missing, missing, missing, price, price, price, price, price, all]),
      (#"{"0-9":"missing","5-9":"price"}"#, [missing, missing, missing, missing, missing, missing, missing, missing, missing, missing, all]),
      (#"{"07":"price","7":"missing"}"#, [all, all, all, all, all, all, all, missing, all, all, all]),
    ]
    let primary = #""branch":{"9-10":"end","0-6":"price"}"#
    #expect(surveyOfferJSON.contains(primary))
    for (branch, routes) in cases {
      server.answer(200, surveyOfferJSON.replacingOccurrences(of: primary, with: #""branch":"# + branch))
      let offer = try #require(try await client.surveyEligible(triggerType: "manual", triggerSourceId: "x", externalUserId: "customer-42"))
      for score in 0...10 {
        #expect(offer.route(primaryAnswer: .number(Double(score))).map(\.key) == routes[score], "\(branch) at \(score)")
      }
    }
  }

  @Test("The ordered parse reads JSON as JSONSerialization does and refuses what is not JSON")
  func orderedParse() throws {
    let text = #" {"b":[1,2.5,true,null,"a\"é😀"],"a":{"z":"1","y":{}},"c":[] } "#
    let parsed = try #require(parseJSONKeepingOrder(Data(text.utf8)) as? OrderedJSONObject)
    #expect(parsed.pairs.map(\.key) == ["b", "a", "c"] && (parsed["a"] as? OrderedJSONObject)?.pairs.map(\.key) == ["z", "y"] && (parsed["c"] as? [Any])?.isEmpty == true)
    let list = try #require(parsed["b"] as? [Any])
    #expect((list[0] as? NSNumber)?.intValue == 1 && (list[1] as? NSNumber)?.doubleValue == 2.5 && list[2] as? Bool == true && list[3] is NSNull && list[4] as? String == "a\"\u{e9}\u{1F600}")
    let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
    for broken in ["", "{", #"{"a":}"#, #"{"a":1,}"#, "[1,]", #"{"a" 1}"#, #""open"#, "{} {}", "nul", "{1:2}", deep] {
      #expect(parseJSONKeepingOrder(Data(broken.utf8)) == nil, "\(broken)")
    }
  }

  @Test("An offer carries the workspace's privacy notice link, and only an https one")
  func privacyNotice() async throws {
    let server = SurveyServer()
    let client = ApphelmClient(options: server.options(), session: server.session(), store: MemoryStore())
    let withNotice = surveyOfferJSON.replacingOccurrences(of: #""expiresAt":1800000000}"#, with: #""expiresAt":1800000000,"privacyNotice":{"purpose":"customer_communication","url":"https://shop.example/privacy"}}"#)
    #expect(withNotice != surveyOfferJSON)
    server.answer(200, withNotice)
    #expect(try await client.surveyEligible(triggerType: "manual", triggerSourceId: "x", externalUserId: "customer-42")?.privacyNoticeUrl == "https://shop.example/privacy")
    server.answer(200, withNotice.replacingOccurrences(of: "https://shop.example/privacy", with: "javascript:alert(1)"))
    #expect(try await client.surveyEligible(triggerType: "manual", triggerSourceId: "y", externalUserId: "customer-42")?.privacyNoticeUrl == nil)
    server.answer(200, surveyOfferJSON)
    #expect(try await client.surveyEligible(triggerType: "manual", triggerSourceId: "z", externalUserId: "customer-42")?.privacyNoticeUrl == nil)
  }

  @Test("surveyEligible makes the browser's request and reads the offer")
  func eligible() async throws {
    let server = SurveyServer()
    let client = ApphelmClient(options: server.options(), session: server.session(), store: MemoryStore())
    let offer = try #require(try await client.surveyEligible(triggerType: "after_outcome", triggerSourceId: "order-1841", triggerKey: "checkout", screen: "CheckoutScreen", externalUserId: " customer-42 "))
    let asked = server.last
    // The browser survey route, with the project key and its origin, not the server key.
    #expect(asked.path == "/api/surveys/eligible" && asked.key == "ahl_pub_test" && asked.origin == "https://app.shop.example" && asked.authorization == nil)
    #expect(same(asked.body, #"{"workspaceId":"org_1","productId":"prd_1","triggerType":"after_outcome","triggerSourceId":"order-1841","triggerKey":"checkout","externalUserId":"customer-42","path":"CheckoutScreen"}"#), "\(asked.raw)")

    #expect(offer.exposureId == "svx_4f1c2d3e" && !offer.anonymous && offer.programId == "svp_1" && offer.name == "Checkout NPS" && offer.templateType == "nps" && offer.version == 3)
    #expect(offer.question == "How likely are you to recommend us?" && offer.openTextPrompt == "What is the main reason?" && offer.followUpQuestion == "May we contact you?")
    #expect(offer.expiresAt == Date(timeIntervalSince1970: 1_800_000_000) && offer.options.isEmpty && offer.branch == ["9-10": "end", "0-6": "price"])
    #expect(offer.additional.map(\.key) == ["plan", "seats", "price", "missing"] && offer.additional.map(\.type) == [.choice, .open, .rating, .open])
    #expect(offer.additional[0].options == ["Free", "Pro"] && offer.additional[0].branch == ["Free": "price"])
    #expect(offer.additional[2].scale == 1...5 && offer.additional[2].branch == ["4-5": "end", "1": "end"] && offer.additional[3].branch.isEmpty)

    // Branching, as surveyRoute in lib/feedback.ts walks it.
    func keys(_ primary: SurveyValue?, _ answers: [String: SurveyValue] = [:]) -> [String] { offer.route(primaryAnswer: primary, answers: answers).map(\.key) }
    #expect(keys(.number(10)).isEmpty && keys(.number(9)).isEmpty && offer.nextQuestion(primaryAnswer: .number(9)) == nil)
    #expect(keys(.number(3)) == ["price", "missing"] && keys(.number(0)) == ["price", "missing"] && keys(.number(6)) == ["price", "missing"])
    #expect(keys(.number(7)) == ["plan", "seats", "price", "missing"] && keys(.number(8)) == keys(nil))
    #expect(keys(.number(7), ["plan": .text("Free")]) == ["plan", "price", "missing"] && keys(.number(7), ["plan": .text("Pro")]) == ["plan", "seats", "price", "missing"])
    #expect(keys(.number(7), ["plan": .text("Free"), "price": .number(5)]) == ["plan", "price"] && keys(.number(3), ["price": .number(1)]) == ["price"] && keys(.number(3), ["price": .number(2)]) == ["price", "missing"])

    // The server never jumps backwards: a target that is an earlier question, or no question at all, leads to the next in order.
    let backwards = SurveyOffer(
      exposureId: offer.exposureId, anonymous: false, programId: offer.programId, name: offer.name, templateType: offer.templateType, version: offer.version, question: offer.question,
      openTextPrompt: nil, options: [], followUpQuestion: nil,
      additional: offer.additional.map { $0.key == "price" ? SurveyQuestion(key: $0.key, text: $0.text, type: $0.type, options: $0.options, scale: $0.scale, branch: ["2": "plan", "3": "price"]) : $0 },
      branch: ["0-10": "nowhere"], expiresAt: offer.expiresAt)
    #expect(backwards.route(primaryAnswer: .number(5)).map(\.key) == ["plan", "seats", "price", "missing"])
    #expect(backwards.route(primaryAnswer: .number(5), answers: ["price": .number(2)]).map(\.key) == ["plan", "seats", "price", "missing"])
    #expect(backwards.route(primaryAnswer: .number(5), answers: ["price": .number(3)]).map(\.key) == ["plan", "seats", "price", "missing"])

    #expect(offer.nextQuestion(primaryAnswer: .number(7))?.key == "plan")
    #expect(offer.nextQuestion(primaryAnswer: .number(7), answers: ["plan": .text("Free")], after: "plan")?.key == "price")
    #expect(offer.nextQuestion(primaryAnswer: .number(7), answers: ["plan": .text("Pro")], after: "plan")?.key == "seats")
    // "seats" was skipped: it is left out of the answers and the next in order follows.
    #expect(offer.nextQuestion(primaryAnswer: .number(7), answers: ["plan": .text("Pro")], after: "seats")?.key == "price")
    #expect(offer.nextQuestion(primaryAnswer: .number(7), answers: ["plan": .text("Pro"), "price": .number(4)], after: "price") == nil)
    #expect(offer.nextQuestion(primaryAnswer: .number(7), answers: ["plan": .text("Pro"), "price": .number(3)], after: "price")?.key == "missing")
    #expect(offer.nextQuestion(primaryAnswer: .number(7), answers: ["plan": .text("Pro"), "price": .number(3), "missing": .text("SSO")], after: "missing") == nil)
    // A question that is not on the route has nothing after it.
    #expect(offer.nextQuestion(primaryAnswer: .number(7), answers: ["plan": .text("Free")], after: "seats") == nil)
  }

  @Test("surveyRespond and surveyDismiss make the browser's requests")
  func respond() async throws {
    let server = SurveyServer()
    let client = ApphelmClient(options: server.options(), session: server.session(), store: MemoryStore())
    server.answer(200, #"{"data":{"id":"svr_1","feedbackId":"fbi_1","status":"responded","replay":false}}"#)
    let stored = try await client.surveyRespond(exposureId: "svx_4f1c2d3e", answer: SurveyAnswer(numericScore: 7, openText: "Fast exports", followUpAnswer: "Yes", answers: ["plan": .text("Free"), "price": .number(4)]))
    #expect(stored && server.last.path == "/api/surveys/respond" && server.last.key == "ahl_pub_test" && server.last.origin == "https://app.shop.example" && server.last.authorization == nil)
    #expect(same(server.last.body, #"{"workspaceId":"org_1","productId":"prd_1","exposureId":"svx_4f1c2d3e","action":"respond","permission":"private_analysis","numericScore":7,"openText":"Fast exports","followUpAnswer":"Yes","answers":{"plan":"Free","price":4}}"#), "\(server.last.raw)")
    // Whole numbers go out as integers: the server refuses a score that is not one.
    #expect(server.last.raw.contains(#""numericScore":7,"#) && server.last.raw.contains(#""price":4"#), "\(server.last.raw)")

    try await client.surveyRespond(exposureId: "svx_2", answer: SurveyAnswer(category: "very_disappointed", permission: .quotable))
    #expect(same(server.last.body, #"{"workspaceId":"org_1","productId":"prd_1","exposureId":"svx_2","action":"respond","permission":"quotable","category":"very_disappointed"}"#), "\(server.last.raw)")

    try await client.surveyRespond(exposureId: "svx_3", answer: SurveyAnswer(numericScore: 5, openText: String(repeating: "x", count: 2_500), answers: ["missing": .text(String(repeating: "y", count: 1_200))]))
    #expect((server.last.body["openText"] as? String)?.count == 2_000 && ((server.last.body["answers"] as? [String: Any])?["missing"] as? String)?.count == 1_000)

    server.answer(200, #"{"data":{"status":"dismissed"}}"#)
    #expect(try await client.surveyDismiss(exposureId: "svx_4f1c2d3e"))
    #expect(same(server.last.body, #"{"workspaceId":"org_1","productId":"prd_1","exposureId":"svx_4f1c2d3e","action":"dismiss","permission":"private_analysis"}"#), "\(server.last.raw)")

    // Not stored: collection paused or the request filtered.
    server.answer(202, #"{"accepted":false,"reason":"collection_paused"}"#)
    #expect(try await !client.surveyRespond(exposureId: "svx_5", answer: SurveyAnswer(numericScore: 5)))
    #expect(try await !client.surveyDismiss(exposureId: "svx_5"))

    // Refused: the server's error.
    server.answer(410, #"{"error":{"code":"survey_exposure_expired","message":"survey exposure expired"}}"#)
    do {
      try await client.surveyRespond(exposureId: "svx_6", answer: SurveyAnswer(numericScore: 5))
      Issue.record("an expired exposure should throw")
    } catch let error as ApphelmError {
      #expect(error.status == 410 && error.code == "survey_exposure_expired")
    }
  }

  @Test("An anonymous person is asked by the two hashes of the distinct id, never the id")
  func anonymous() async throws {
    let server = SurveyServer()
    let client = ApphelmClient(options: server.options(), session: server.session(), store: MemoryStore())
    server.answer(200, #"{"data":{"exposureId":"sva_9","anonymous":true,"program":{"id":"svp_2","name":"Visitor poll","templateType":"custom","question":{"primary":"What brought you here?","customOptions":["Search","A friend"]},"followUp":null,"version":1},"expiresAt":1800000000}}"#)
    let offer = try #require(try await client.surveyEligible(triggerType: "manual", triggerSourceId: "home-1"))
    #expect(same(server.last.body, #"{"workspaceId":"org_1","productId":"prd_1","triggerType":"manual","triggerSourceId":"home-1","distinctHash":"f5537974","distinctHash2":"34443f86"}"#), "\(server.last.raw)")
    #expect(!server.last.raw.contains("user-1"))
    #expect(offer.anonymous && offer.exposureId == "sva_9" && offer.options == ["Search", "A friend"] && offer.followUpQuestion == nil && offer.openTextPrompt == nil)
    #expect(offer.additional.isEmpty && offer.route(primaryAnswer: .text("Search")).isEmpty)

    // A blank external id is an anonymous request.
    _ = try await client.surveyEligible(triggerType: "manual", triggerSourceId: "home-2", externalUserId: "  ")
    #expect(server.last.body["distinctHash"] as? String == "f5537974" && server.last.body["externalUserId"] == nil)

    // Nothing to ask, and a filtered request.
    server.answer(200, #"{"data":null}"#)
    #expect(try await client.surveyEligible(triggerType: "manual", triggerSourceId: "home-3") == nil)
    server.answer(200, #"{"data":null,"reason":"bot_filtered"}"#)
    #expect(try await client.surveyEligible(triggerType: "manual", triggerSourceId: "home-4") == nil)
  }

  @Test("A surveyKey that is not a project key is refused locally, so a server key is never sent to the survey routes")
  func serverKeyRefused() async throws {
    let server = SurveyServer()
    let session = server.session()
    for wrong in ["ahl_live_secret", "ahl_test_secret", "sk_live_x", "AHL_PUB_x"] {
      let client = ApphelmClient(options: server.options(key: wrong), session: session, store: MemoryStore())
      var codes: [String] = []
      do { _ = try await client.surveyEligible(triggerType: "manual", triggerSourceId: "x") } catch let error as ApphelmError { codes.append(error.message.contains(wrong) ? "leaked" : error.code) }
      do { try await client.surveyRespond(exposureId: "svx_1", answer: SurveyAnswer(numericScore: 5)) } catch let error as ApphelmError { codes.append(error.message.contains(wrong) ? "leaked" : error.code) }
      do { try await client.surveyDismiss(exposureId: "svx_1") } catch let error as ApphelmError { codes.append(error.message.contains(wrong) ? "leaked" : error.code) }
      #expect(codes == ["survey_key_not_public", "survey_key_not_public", "survey_key_not_public"], "\(wrong): \(codes)")
    }
    #expect(server.requests.isEmpty)
  }

  @Test("Surveys need both the project key and its origin, and send nothing without them")
  func unconfigured() async throws {
    let server = SurveyServer()
    let session = server.session()
    for (key, origin) in [(nil, nil), ("ahl_pub_test", nil), (nil, "https://app.shop.example"), (" ", " ")] as [(String?, String?)] {
      let client = ApphelmClient(options: server.options(key: key, origin: origin), session: session, store: MemoryStore())
      do {
        _ = try await client.surveyEligible(triggerType: "manual", triggerSourceId: "x")
        Issue.record("surveys without a key and origin should throw")
      } catch let error as ApphelmError {
        #expect(error.code == "survey_not_configured")
      }
    }
    #expect(server.requests.isEmpty)
  }
}
