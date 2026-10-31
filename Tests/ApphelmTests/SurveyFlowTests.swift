import Foundation
import Testing

@testable import Apphelm

/// Parse an offer as the client does (its `data`).
private func offer(_ json: String) throws -> SurveyOffer {
  let data = try #require(parseJSONKeepingOrder(Data(json.utf8)) as? OrderedJSONObject)
  return try #require(surveyOffer(data))
}

private func program(_ template: String, _ question: String, followUp: String = "null", extra: String = "") -> String {
  #"{"exposureId":"svx_1","program":{"id":"svp_1","name":"Survey","templateType":"\#(template)","question":\#(question),"followUp":\#(followUp),"version":1\#(extra)},"expiresAt":1800000000}"#
}

// The NPS survey of SurveyTests.swift and tests/mobile-surveys.test.ts.
private let nps = program("nps", #"{"primary":"How likely are you to recommend us?","openText":"What is the main reason?","additional":[{"key":"plan","text":"Which plan are you on?","type":"choice","options":["Free","Pro"],"branch":{"Free":"price"}},{"key":"seats","text":"How many seats do you use?","type":"open"},{"key":"price","text":"How fair is the price?","type":"rating","scale":{"min":1,"max":5},"branch":{"4-5":"end","1":"end"}},{"key":"missing","text":"What is missing for you?","type":"open"}],"branch":{"9-10":"end","0-6":"price"}}"#, followUp: #"{"question":"May we contact you?"}"#)

/// A survey server that answers /api/surveys/active and /api/surveys/eligible.
private final class AutoServer: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [(path: String, body: [String: Any])] = []
  var active = #"{"data":[{"id":"svp_auto","display":{"screen":"Checkout","devices":["mobile"],"delaySeconds":0}}]}"#
  var offer = #"{"data":{"exposureId":"svx_9","program":{"id":"svp_auto","name":"Auto","templateType":"csat","question":{"primary":"How was checkout?"},"followUp":null,"version":1,"display":{"mode":"auto","delaySeconds":0}},"expiresAt":1800000000}}"#
  let host = "auto-\(UUID().uuidString.lowercased()).test"
  var requests: [(path: String, body: [String: Any])] { lock.withLock { seen } }

  func client() -> ApphelmClient {
    var options = ApphelmOptions(apiKey: "ahl_live_test", baseURL: "https://\(host)/", workspaceId: "org_1", productId: "prd_1", distinctId: "user-1").quiet
    options.surveyKey = "ahl_pub_test"
    options.surveyOrigin = "https://app.shop.example"
    RoutedURLProtocol.register(host: host) { [self] request in
      let body = (try? requestJSON(request)) ?? [:]
      let path = request.url?.path ?? ""
      let reply = lock.withLock { () -> String in
        seen.append((path, body))
        return path == "/api/surveys/active" ? active : path == "/api/surveys/eligible" ? offer : #"{"data":{"status":"responded"}}"#
      }
      return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "application/json"])!, Data(reply.utf8))
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedURLProtocol.self]
    return ApphelmClient(options: options, session: URLSession(configuration: configuration), store: MemoryStore())
  }
}

private final class Box<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [T] = []
  func add(_ item: T) { lock.withLock { items.append(item) } }
  var all: [T] { lock.withLock { items } }
}

private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
}

@Suite("Drawn and automatic surveys")
struct SurveyFlowTests {
  @Test("New question types, the custom primary's type, the display and the appearance decode")
  func decoding() throws {
    let decoded = try offer(program("custom", #"{"primary":"Read our news","primaryType":"link","link":"https://shop.example/news","buttonText":"Read it","additional":[{"key":"tools","text":"Which tools do you use?","type":"multiple_choice","options":["Slack","Jira","Linear"]},{"key":"mood","text":"How do you feel?","type":"rating","scale":{"min":1,"max":5},"display":"emoji","lowerLabel":"Bad","upperLabel":"Great"},{"key":"docs","text":"See the docs","type":"link","link":"https://shop.example/docs","buttonText":"Docs"}]}"#,
      extra: ##","display":{"mode":"auto","delaySeconds":5},"appearance":{"position":"center","backgroundColor":"#101820","textColor":"#ffffff","buttonColor":"#ffcc00","buttonTextColor":"#000000","submitText":"Send","thankYouText":"Thanks!","placeholder":"Tell us","hideBranding":true,"maxWidth":420}"##))
    #expect(decoded.primaryType == "link" && decoded.link == "https://shop.example/news" && decoded.buttonText == "Read it")
    #expect(decoded.additional.map(\.type) == [.multipleChoice, .rating, .link])
    #expect(decoded.additional[0].options == ["Slack", "Jira", "Linear"])
    #expect(decoded.additional[1].display == "emoji" && decoded.additional[1].lowerLabel == "Bad" && decoded.additional[1].upperLabel == "Great")
    #expect(decoded.additional[2].link == "https://shop.example/docs" && decoded.additional[2].buttonText == "Docs")
    #expect(decoded.displayMode == "auto" && decoded.delaySeconds == 5)
    let look = try #require(decoded.appearance)
    #expect(look.position == "center" && look.isCard && look.backgroundColor == "#101820" && look.textColor == "#ffffff" && look.buttonColor == "#ffcc00" && look.buttonTextColor == "#000000")
    #expect(look.submitText == "Send" && look.thankYouText == "Thanks!" && look.placeholder == "Tell us" && look.hideBranding && look.maxWidth == 420)

    // Without them: no appearance, host display, and the defaults for anything malformed.
    let plain = try offer(nps)
    #expect(plain.appearance == nil && plain.displayMode == nil && plain.delaySeconds == 0 && plain.primaryType == nil)
    let odd = try offer(program("nps", #"{"primary":"Recommend us?"}"#, extra: #","appearance":{"position":"sideways","backgroundColor":"red","maxWidth":9000}"#))
    #expect(odd.appearance == SurveyAppearance().with { $0.maxWidth = 560 })
  }

  @Test("The flow walks the NPS survey's route and builds the response survey-flow.ts builds")
  func npsFlow() throws {
    var flow = SurveyFlow(try offer(nps))
    #expect(flow.current?.key == "$primary" && flow.current?.type == .rating && flow.current?.scale == 0...10 && flow.current?.optional == false)
    #expect(flow.progress == (1, 7))
    // A required step stays without an answer.
    #expect(flow.answer(nil)?.key == "$primary")
    #expect(flow.answer(.number(7))?.key == "$open_text")
    #expect(flow.current?.text == "What is the main reason?" && flow.current?.optional == true)
    #expect(flow.answer(.text("  Fast exports  "))?.key == "$follow_up")
    #expect(flow.answer(.text("   "))?.key == "plan")
    #expect(flow.answer(.text("Free"))?.key == "price")
    #expect(flow.answer(.number(5)) == nil && flow.isDone)
    #expect(flow.response == SurveyAnswer(numericScore: 7, openText: "Fast exports", answers: ["plan": .text("Free"), "price": .number(5)]))

    // Skips go on in order and leave the answer out.
    var skipping = SurveyFlow(try offer(nps))
    skipping.answer(.number(8))
    skipping.answer(nil)
    skipping.answer(nil)
    #expect(skipping.answer(nil)?.key == "seats")
    #expect(skipping.answer(.text("  "))?.key == "price")
    #expect(skipping.answer(.number(3))?.key == "missing")
    #expect(skipping.answer(.text(" SSO ")) == nil)
    #expect(skipping.response == SurveyAnswer(numericScore: 8, answers: ["price": .number(3), "missing": .text("SSO")]))

    // A promoter's branch ends after the follow-up.
    var promoter = SurveyFlow(try offer(nps))
    promoter.answer(.number(10))
    promoter.answer(nil)
    #expect(promoter.answer(nil) == nil && promoter.isDone && promoter.response == SurveyAnswer(numericScore: 10))
  }

  @Test("PMF, custom choice, open and link primaries, and a follow-up without open text")
  func primaries() throws {
    var pmf = SurveyFlow(try offer(program("pmf", #"{"primary":"How would you feel?"}"#, followUp: #"{"question":"Why?"}"#)))
    let first = try #require(pmf.current)
    #expect(first.type == .choice && first.options == ["very_disappointed", "somewhat_disappointed", "not_disappointed"] && first.label("very_disappointed") == "Very disappointed")
    #expect(pmf.answer(.text("somewhat_disappointed"))?.text == "Anything to add? (optional)")
    #expect(pmf.answer(.text("Exports"))?.key == "$follow_up")
    pmf.answer(.text("Speed"))
    #expect(pmf.isDone && pmf.response == SurveyAnswer(category: "somewhat_disappointed", openText: "Exports", followUpAnswer: "Speed"))

    var open = SurveyFlow(try offer(program("custom", #"{"primary":"What should we build?","primaryType":"open","openText":"Ignored for open"}"#, followUp: #"{"question":"Why?"}"#)))
    #expect(open.current?.type == .open)
    #expect(open.answer(.text("  "))?.key == "$primary")
    // The open primary is the open text: the next step is the follow-up.
    #expect(open.answer(.text("Dark mode"))?.key == "$follow_up")
    open.answer(nil)
    #expect(open.response == SurveyAnswer(openText: "Dark mode"))

    var link = SurveyFlow(try offer(program("custom", #"{"primary":"Read our news","primaryType":"link","link":"https://shop.example/news"}"#)))
    #expect(link.current?.type == .link && link.current?.link == "https://shop.example/news")
    #expect(link.answer(.text("clicked")) == nil && link.response == SurveyAnswer(category: "clicked"))

    var choice = SurveyFlow(try offer(program("custom", #"{"primary":"Which?","customOptions":["A","B"],"branch":{"B":"end"},"additional":[{"key":"why","text":"Why that one?","type":"open"}]}"#)))
    #expect(choice.current?.options == ["A", "B"])
    #expect(choice.answer(.text("B")) == nil && choice.response == SurveyAnswer(category: "B"))
  }

  @Test("Multiple choice answers a list, link answers clicked, and progress follows the route")
  func additionalTypes() throws {
    var flow = SurveyFlow(try offer(program("csat", #"{"primary":"Happy?","additional":[{"key":"tools","text":"Which tools?","type":"multiple_choice","options":["Slack","Jira"]},{"key":"docs","text":"See the docs","type":"link","link":"https://shop.example/docs"},{"key":"mood","text":"Mood?","type":"rating","scale":{"min":1,"max":3},"display":"emoji"}]}"#)))
    #expect(flow.progress == (1, 4))
    flow.answer(.number(4))
    #expect(flow.current?.type == .multipleChoice && flow.progress == (2, 4))
    flow.answer(.list(["Jira", "Slack"]))
    #expect(flow.current?.type == .link)
    flow.answer(.text("clicked"))
    #expect(flow.current?.showsFaces == true && ratingFaces(3) == ["😞", "😐", "😊"])
    flow.answer(.number(3))
    #expect(flow.isDone && flow.response == SurveyAnswer(numericScore: 4, answers: ["tools": .list(["Jira", "Slack"]), "docs": .text("clicked"), "mood": .number(3)]))

    var empty = SurveyFlow(try offer(program("csat", #"{"primary":"Happy?","additional":[{"key":"tools","text":"Which tools?","type":"multiple_choice","options":["Slack","Jira"]}]}"#)))
    empty.answer(.number(2))
    empty.answer(.list([]))
    #expect(empty.isDone && empty.response.answers.isEmpty)
    #expect(safeSurveyLink("https://shop.example/x") != nil && safeSurveyLink("http://shop.example") == nil && safeSurveyLink("javascript:alert(1)") == nil)
  }

  @Test("A list answer is sent as an array")
  func listAnswer() async throws {
    let server = AutoServer()
    let client = server.client()
    try await client.surveyRespond(exposureId: "svx_1", answer: SurveyAnswer(numericScore: 4, answers: ["tools": .list(["Slack", "Jira"])]))
    let body = try #require(server.requests.last?.body)
    #expect((body["answers"] as? [String: Any])?["tools"] as? [String] == ["Slack", "Jira"])
  }

  @Test("Active surveys decode, and their rules match screens, events and devices")
  func matching() {
    let rules = autoSurveys(parseJSONKeepingOrder(Data(#"[{"id":"svp_a","display":{"screen":"Checkout","delaySeconds":3}},{"id":"svp_b","display":{"event":"order_placed","devices":["tablet"],"delaySeconds":999}},{"id":"svp_c","display":{"delaySeconds":0}},{"id":"svp_d","display":{"url":{"match":"contains","value":"/pricing"},"delaySeconds":0}},{"id":"bad"}]"#.utf8)))
    #expect(rules.map(\.id) == ["svp_a", "svp_b", "svp_c", "svp_d"])
    #expect(rules[0].delaySeconds == 3 && rules[1].delaySeconds == 300 && rules[1].devices == ["tablet"] && rules[3].webOnly)
    #expect(autoSurveyMatches(rules[0], event: "$screen", screen: "Checkout", device: "mobile"))
    #expect(!autoSurveyMatches(rules[0], event: "$screen", screen: "checkout", device: "mobile"))
    #expect(!autoSurveyMatches(rules[0], event: "Checkout", screen: nil, device: "mobile"))
    #expect(autoSurveyMatches(rules[1], event: "order_placed", screen: nil, device: "tablet"))
    #expect(!autoSurveyMatches(rules[1], event: "order_placed", screen: nil, device: "mobile"))
    #expect(autoSurveyMatches(rules[2], event: "$screen", screen: "Home", device: "mobile") && !autoSurveyMatches(rules[2], event: "order_placed", screen: nil, device: "mobile"))
    #expect(!autoSurveyMatches(rules[3], event: "$screen", screen: "/pricing", device: "mobile"))
    #expect(autoTriggerSource(Date(timeIntervalSince1970: 1_800_000_000)) == "auto:2027-01-15")
  }

  @Test("The engine waits the delay, asks once per program and shows one survey at a time")
  func engine() async throws {
    let base = try offer(nps)
    let asked = Box<String>(), slept = Box<Int>(), shown = Box<String>(), closers = Box<@Sendable () -> Void>()
    let engine = AutomaticSurveyEngine(
      device: { "mobile" },
      load: { [AutoSurvey(id: "svp_a", screen: "Checkout", delaySeconds: 2), AutoSurvey(id: "svp_b", event: "order_placed")] },
      ask: { survey, device in asked.add("\(survey.id):\(device)"); return base },
      present: { offer, closed in shown.add(offer.exposureId); closers.add(closed) },
      sleep: { slept.add($0) })
    // Events seen while the rules load are matched once they are in, none dropped.
    engine.captured(event: "$app_opened", screen: nil)
    engine.captured(event: "$screen", screen: "Home")
    await engine.pending?.value
    #expect(asked.all.isEmpty)
    engine.captured(event: "$screen", screen: "Checkout")
    await engine.pending?.value
    #expect(asked.all == ["svp_a:mobile"] && slept.all == [2] && shown.all == ["svx_1"])

    let early = Box<String>()
    let second = AutomaticSurveyEngine(
      device: { "mobile" }, load: { [AutoSurvey(id: "svp_a", screen: "Checkout")] },
      ask: { survey, _ in early.add(survey.id); return base }, present: { _, _ in }, sleep: { _ in })
    second.captured(event: "$app_opened", screen: nil)
    second.captured(event: "$screen", screen: "Checkout")
    await second.pending?.value
    await second.pending?.value
    #expect(early.all == ["svp_a"])
    // Still showing: another match waits.
    engine.captured(event: "order_placed", screen: nil)
    await engine.pending?.value
    #expect(asked.all.count == 1)
    closers.all.first?()
    engine.captured(event: "$screen", screen: "Checkout")
    await engine.pending?.value
    #expect(asked.all.count == 1)
    engine.captured(event: "order_placed", screen: nil)
    await engine.pending?.value
    #expect(asked.all == ["svp_a:mobile", "svp_b:mobile"])
  }

  @Test("Automatic surveys ask for the program by id on a matching screen, and not while opted out")
  func automatic() async throws {
    let server = AutoServer()
    let client = server.client()
    let shown = Box<SurveyOffer>()
    client.enableAutomaticSurveys(externalUserId: { "customer-42" }, device: "mobile") { offer, closed in shown.add(offer); closed() }
    client.optOut()
    client.screen("Checkout")
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(server.requests.isEmpty)
    client.optIn()
    client.screen("Checkout")
    await waitUntil { !shown.all.isEmpty }
    let eligible = try #require(server.requests.first { $0.path == "/api/surveys/eligible" }?.body)
    #expect(eligible["programId"] as? String == "svp_auto" && eligible["triggerType"] as? String == "manual" && eligible["device"] as? String == "mobile" && eligible["externalUserId"] as? String == "customer-42")
    #expect((eligible["triggerSourceId"] as? String)?.hasPrefix("auto:") == true && (eligible["triggerSourceId"] as? String)?.count == 15)
    #expect(server.requests.first?.path == "/api/surveys/active" && shown.all.first?.exposureId == "svx_9" && shown.all.first?.displayMode == "auto")
    client.disableAutomaticSurveys()
  }

  #if canImport(SwiftUI)
  @Test("The view model answers, sends once at the end, and leaves with a partial response or a dismissal")
  @MainActor
  func viewModel() throws {
    var responses: [SurveyAnswer] = [], dismissed = 0, closed = 0
    let model = SurveyViewModel(offer: try offer(nps), onRespond: { responses.append($0) }, onDismiss: { dismissed += 1 }, onClose: { closed += 1 })
    model.text = "  "
    model.submit()
    #expect(model.step?.key == "$primary")
    model.answer(.number(9))
    model.text = "Great"
    #expect(model.canSubmit)
    model.submit()
    #expect(model.step?.key == "$follow_up" && model.text.isEmpty)
    model.submit()
    #expect(model.finished && responses == [SurveyAnswer(numericScore: 9, openText: "Great")])
    model.leave()
    #expect(responses.count == 1 && dismissed == 0 && closed == 1)

    var left: [SurveyAnswer] = []
    let early = SurveyViewModel(offer: try offer(nps), onRespond: { left.append($0) }, onDismiss: { dismissed += 1 }, onClose: { closed += 1 })
    early.leave()
    early.leave()
    #expect(dismissed == 1 && left.isEmpty && closed == 2)

    let partial = SurveyViewModel(offer: try offer(nps), onRespond: { left.append($0) }, onDismiss: { dismissed += 1 }, onClose: {})
    partial.answer(.number(3))
    partial.leave()
    #expect(left == [SurveyAnswer(numericScore: 3)] && dismissed == 1)

    let multiple = SurveyViewModel(offer: try offer(program("csat", #"{"primary":"Happy?","additional":[{"key":"tools","text":"Which tools?","type":"multiple_choice","options":["Slack","Jira"]}]}"#)), onRespond: { left.append($0) }, onDismiss: {}, onClose: {})
    multiple.answer(.number(5))
    multiple.toggle("Jira")
    multiple.toggle("Slack")
    multiple.toggle("Jira")
    multiple.toggle("Jira")
    multiple.submit()
    #expect(left.last?.answers["tools"] == .list(["Slack", "Jira"]))
  }
  #endif
}

extension SurveyAppearance {
  fileprivate func with(_ change: (inout SurveyAppearance) -> Void) -> SurveyAppearance {
    var copy = self
    change(&copy)
    return copy
  }
}
