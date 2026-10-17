# Apphelm native iOS/macOS SDK

Swift Package Manager library. URLSession only — no UIKit, no WebKit, no JavaScript.

- `ApphelmClient`: `track`, `screen` (`page_viewed`), `identify`, `evaluateFlags`, fail-closed `isEnabled`, `captureException`, bounded in-memory queue with `flush`.
- Crash capture: `installCrashReporting()` and `sendPendingCrashReports()` (uncaught `NSException`s and fatal signals, sent on the next launch).
- Tracing: `startTransaction`, spans, W3C `traceparent`, and screen and `URLSession` spans without wrapping each call (below).
- Release health: `startSession` and `endSession` (below).
- `evaluateLocalFlag` + `assignmentBucket`: pure local evaluation in the same assignment family as the server and every other SDK.
- Distinct ids persist through an injectable store (`UserDefaultsStore` by default).

```bash
swift test
```

Install with Swift Package Manager:

```swift
.package(url: "https://github.com/Sansa-Organisation/apphelm-swift.git", from: "0.4.0")
// target dependency: .product(name: "Apphelm", package: "apphelm-swift")
```


## Release health

```swift
// When the app becomes active:
apphelm.startSession()
await apphelm.flush()
// When it goes to the background:
apphelm.endSession()
```

`startSession()` queues one `$session` event, the signal the browser SDK sends per page load,
with the release, the environment and a new session id. It needs `release`: the server
counts sessions per release, so without one it returns `nil` and queues nothing. Calling it
while a session is running returns that session. The event is queued like a tracked event
and is sent by `flush()`. It is the only event a session costs.

`endSession()` sends nothing. It ends the session locally, so later errors carry no session
id and the next `startSession()` starts a new session. There is no closing event because
the server needs none:

- Errors during a session are already sent as exceptions, each carrying the session id
  (`session_hash`).
- A crash is already sent as a crash report on the next launch, and an unhandled exception
  with a session id is what marks that session crashed. The release's crash-free rate is
  computed from that, from 10 sessions up.
- Session length is not tracked.

Crashes: each session's start and end are noted in a small file next to the crash reports
(`sessions.json`, the last ten sessions). When `sendPendingCrashReports()` sends a crash on
the next launch, it finds the session that was running when the report was written, by the
report file's modification time, and sends the crash with that session's id, release and
environment. A crash written when no session was running (before the first, or after
`endSession()`) is sent with this launch's release, as before. If you pass your own
`directory` to `installCrashReporting`, pass the same one to `startSession`.

Not covered: a process the system kills in the background (out of memory, watchdog) is not
a crashed session. Tracked events and screens don't carry the session id.

## Tracing

```swift
let apphelm = ApphelmClient(options: ApphelmOptions(/* … */, tracesSampleRate: 0.2))

let tx = apphelm.startTransaction("CheckoutScreen", op: "ui.load")
let cart = try await tx.span("http.client", description: "GET /api/cart") { span in
  var request = URLRequest(url: URL(string: "https://api.example.com/api/cart")!)
  span.propagate(&request) // traceparent: your backend's transaction joins this trace
  return try await URLSession.shared.data(for: request).0
}
do { try render(cart) } catch { try? await apphelm.captureException(error, traceId: tx.traceId) }
await tx.finish()
```

`startTransaction(name, op: "task", traceparent: nil)` starts a transaction, which is kept
with probability `tracesSampleRate` (default 1). If you pass a W3C `traceparent`, it
continues that trace: its trace id, parent span and sampling decision are kept. A malformed
or all-zero header starts a new trace. Spans come from `startSpan(op, description:)` and
`finish(.ok | .error)`, or from `span(op, description:) { }` (synchronous or `async`), which
finishes as an error if the closure throws and then rethrows. At most 50 are kept.
`traceparent()` and `propagate(&request)` on a transaction or span put the trace on an
outgoing call; use them only for your own services, since the header tells the receiver the
trace id. `finish()` sends one `$transaction`, the same shape the Node, Python and Kotlin
clients send, with the release and environment. It sends once and never throws, and an
unsampled transaction sends nothing. `captureException(error, traceId:)` links an issue to
its trace. Each kept transaction is one event.

### Screens and HTTP calls without wrapping each one

```swift
let apphelm = ApphelmClient(options: ApphelmOptions(/* … */, tracePropagationHosts: ["api.example.com"]))

let tx = apphelm.startScreen("CheckoutScreen") // in place of screen("CheckoutScreen")
let (cart, _) = try await apphelm.data(for: URLRequest(url: cartURL)) // a span, and traceparent to a listed host
await tx.finish()

// Or record every request of a session, with no change at the call sites:
let session = URLSession(configuration: .default, delegate: apphelm.httpSpanDelegate(), delegateQueue: nil)
```

- `startScreen(name, properties:)` queues the screen view that `screen` queues and starts
  a `ui.load` transaction named after the screen. Finish it when the screen has its content.
- `activeTransaction` is the transaction started most recently, until it finishes. It is
  nil once that one has finished, even if an earlier one is still running, so it suits an
  app with one screen load or sync at a time. The client holds it weakly.
- `data(for:session:transaction:)` is `session.data(for:)` inside an `http.client` span
  described as `METHOD scheme://host/path`: the query, fragment and any credentials in the
  URL are left out, and the server replaces ids in the path. A response from 400 up, or a
  thrown error (rethrown), is an error span. It sets `traceparent`, naming the span, only
  when the host is in `tracePropagationHosts`: an exact host (`api.example.com`) or, with a
  leading dot, every host under a domain (`.example.com`). Empty by default.
- `httpSpanDelegate()` records every task of a `URLSession` from its
  `URLSessionTaskMetrics`, as the session's delegate or per request
  (`session.data(for:delegate:)`). If the session has its own delegate, call
  `recordHTTPSpan(task:metrics:)` from its `urlSession(_:task:didFinishCollecting:)`. A
  delegate cannot change a request, so it sends no `traceparent`; `propagate(&request)` on
  the client sets the active transaction's on a request to a listed host. A request that
  began before the transaction is not recorded.
- Nothing is recorded without an unfinished transaction, for a URL that is not http(s), or
  for the client's own requests to Apphelm. Use the wrapper or the delegate on a session,
  not both, or each request is recorded twice.

Not covered: nothing swizzles `URLSession`, so requests outside the wrapper or a session
with the delegate are not recorded; there are no database spans; a screen's transaction
ends when you finish it, not when a frame is drawn.

Verified with `swift test` on macOS only; not yet run on an iOS device or simulator.

## Surveys (headless)

```swift
var options = ApphelmOptions(/* … */)
options.surveyKey = "ahl_pub_…"
options.surveyOrigin = "https://app.example.com"
let apphelm = ApphelmClient(options: options)

guard let offer = try await apphelm.surveyEligible(triggerType: "after_outcome", triggerSourceId: order.id, screen: "CheckoutScreen", externalUserId: user.id) else { return }
let score = SurveyValue.number(await askScore(offer.question)) // your UI
var answers: [String: SurveyValue] = [:]
var question = offer.nextQuestion(primaryAnswer: score, answers: answers)
while let asking = question {
  if let answer = await ask(asking) { answers[asking.key] = answer } // nil if skipped
  question = offer.nextQuestion(primaryAnswer: score, answers: answers, after: asking.key)
}
try await apphelm.surveyRespond(exposureId: offer.exposureId, answer: SurveyAnswer(numericScore: 9, answers: answers))
// or, if the person closes it: try await apphelm.surveyDismiss(exposureId: offer.exposureId)
```

The client fetches the survey and sends the answers; the app draws it. These are the
requests the browser SDK makes, so everything the server does for a web survey holds:
targeting, frequency caps, expiry, and one stored response per offer.

- `surveyEligible(triggerType:triggerSourceId:triggerKey:screen:externalUserId:)` returns a
  `SurveyOffer` or nil. `screen` is matched against programs targeted at a page path. With
  `externalUserId` the person is your identified customer. Without it they are anonymous:
  the request carries two hashes of the distinct id, never the id, and only programs opened
  to anonymous people are offered. Ask an anonymous person only if they agreed to
  analytics; the client keeps no consent state.
- A `SurveyOffer` has the primary `question` (answered by `category` or `numericScore`, by
  `templateType`), `openTextPrompt`, `followUpQuestion`, a custom survey's `options`, and up
  to four `additional` questions (`.open`, `.choice`, `.rating`).
- Branching: `offer.route(primaryAnswer:answers:)` is the list of additional questions this
  person is asked, and `nextQuestion(primaryAnswer:answers:after:)` walks it one question at
  a time. An answer can jump to a later question or end the survey. The server walks the
  same route and refuses a response that answers a question off it. When rules of one
  branch overlap, both read them in the server's order: single numbers ascending, then the
  ranges as written (`branch.rules` keeps the order the server sent).
- `surveyRespond(exposureId:answer:)` sends everything once and returns whether it was
  stored; `surveyDismiss(exposureId:)` records a close. A refused request throws
  `ApphelmError` (`survey_exposure_expired`, `invalid_survey_response`, …), and calling any
  of the three without `surveyKey` and `surveyOrigin` throws `survey_not_configured`. A
  `surveyKey` that does not start with `ahl_pub_` throws `survey_key_not_public` before
  anything is sent, so a server key put there by mistake never leaves the app.

The survey routes are the browser SDK's, so they take the product's **project key**
(`ahl_pub_…`) and an `Origin` that key allows, not the server key. Both are public values.
In an app the origin is a label you send, not something a browser enforces, so the key's
origin list does not restrict who can call; the per-key and per-address rate limits and
the workspace's collection switch still apply. The server refuses a request with no
`User-Agent`, or one that names a bot or a plain HTTP tool.

Verified with `swift test` on macOS against a stubbed server, and `tests/mobile-surveys.test.ts`
puts the same request bodies through the server's schemas. Not run on a device, and not run
against a deployed Apphelm.

## Symbolicating stripped builds

A release build is stripped, so a crash reports addresses (`0  Shop  0x0000000104935a98 Shop + 6808`).
Apphelm's server can't read a dSYM, so a script turns it into a small symbol table on your
build machine and uploads that:

```bash
APPHELM_API_KEY=ahl_… Scripts/apphelm-symbols.sh \
  "$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME" --upload --product prd_… --release ios@2.3.0 --lines
```

- It uses Xcode's own tools: `dwarfdump --uuid` for each binary's UUID, `otool -l` for
  where it is linked to load, `nm` for the functions, `swift-demangle` for readable names
  and, with `--lines`, `atos` for the file and line each function is declared at (slower).
  Without `--upload` it writes `<UUID>.apphelm-symbols` to `--out` and sends nothing.
- Run it for every dSYM in the archive: the app's and each embedded framework's. A
  universal dSYM gives one table per architecture.
- The client does the other half. Every exception and crash carries `debug_images`: the
  name, UUID, load address and slide of each binary its frames are in. For a crash they
  are recorded at `installCrashReporting()` in the launch that crashes, next to the report,
  because the next launch loads everything somewhere else. The server subtracts the load
  address from each frame's address and looks the offset up in the table with that UUID,
  so a table can only ever be applied to the build it came from.
- The issue view marks each frame symbolicated or not and, when a stripped image has no
  table, names the dSYM (image and UUID) to upload for the release. A table uploaded later
  still applies to issues already stored. Crashes received after the upload group on the
  function; ones received before it grouped on the image offset and stay where they are.
- Limits: 16 MB and a million functions per table, 200 files and 1 GB per product, 60
  uploads an hour, kept 365 days. `GET /api/v1/symbols?productId=` lists them and
  `DELETE /api/v1/symbols/{id}` removes one.

Not covered: line numbers inside a function (a frame shows the function and, with
`--lines`, where it is declared, not the line that crashed), inlined calls, images loaded
with `dlopen` after `installCrashReporting()`, and Apple's own frameworks, which show
whatever the device printed.


For Android and the JVM, use the Kotlin client (`com.sansavision:apphelm`).
