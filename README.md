# Apphelm native iOS/macOS SDK

Swift Package Manager library on URLSession, with no dependencies. UIKit is used only where it
exists, for lifecycle events, screen autocapture and background flushing; no WebKit, no JavaScript.

- `ApphelmClient`: `track`, `screen` (`$screen`), `identify`, `alias`, `group`, `register`, `reset`, `optOut`, `evaluateFlags`, fail-closed `isEnabled` and `getFeatureFlag`, `captureException`. Events wait in a queue on disk and are sent on their own (below); `flush()` sends them now.
- Lifecycle events (`$app_installed`, `$app_updated`, `$app_opened`, `$app_backgrounded`) and UIKit screen views, captured automatically; `.apphelmScreen("Name")` for SwiftUI.
- Crash capture: `installCrashReporting()` and `sendPendingCrashReports()` (uncaught `NSException`s and fatal signals, sent on the next launch).
- Tracing: `startTransaction`, spans, W3C `traceparent`, and screen and `URLSession` spans without wrapping each call (below).
- Release health: `startSession` and `endSession` (below).
- Ad measurement: `adsConsent`, `setAdsConsent` and `recordInstall` (below). Off unless you set `adsConsent`.
- `evaluateLocalFlag` + `assignmentBucket`: pure local evaluation in the same assignment family as the server and every other SDK.
- Distinct ids persist through an injectable store (`UserDefaultsStore` by default).

```bash
swift test
```

Install with Swift Package Manager:

```swift
.package(url: "https://github.com/Sansa-Organisation/apphelm-swift.git", from: "0.7.0")
// target dependency: .product(name: "Apphelm", package: "apphelm-swift")
```


## Analytics: queue, lifecycle, screens, identity and opt-out

```swift
let apphelm = ApphelmClient(options: ApphelmOptions(apiKey: "ahl_live_…", workspaceId: "org_…", productId: "prd_…"))

apphelm.track("checkout_completed", properties: ["total": 42])
apphelm.screen("Checkout")                         // UIKit screens are also captured on their own
apphelm.identify(user.id, traits: ["plan": "pro"]) // at log-in
apphelm.group(type: "company", key: org.id, traits: ["name": org.name])
apphelm.register(["theme": "dark"])                // on every later event
apphelm.reset()                                    // at log-out
apphelm.optOut()                                   // analytics off until optIn(), remembered

// SwiftUI
CheckoutView().apphelmScreen("Checkout")
```

**Sending.** Events wait in a queue and are sent without a call to `flush()`:

- every `flushIntervalSeconds` (default 30; 0 turns the timer off), as soon as `flushAt`
  events are queued (default 20; 0 turns it off), and when the app goes to the background
  (`flushOnBackground`, default true), with a background task so the send can finish;
- `await flush()` still sends everything now. Flushes run one at a time.

The queue is on disk (`persistence: .disk`, the default): one small file per event in
`Application Support/Apphelm/queue-<hash>`, one folder per product, written atomically and
left out of backups. Events survive the app being killed and are sent on a later launch. It
holds `maxQueueSize` events (default 1000), the oldest dropped first. A send that fails
(offline, a 5xx) leaves that event and the ones after it queued, in order, with the same
event id and time, so nothing is lost or sent twice. An event the server refuses for good
(400, 413, 422) is dropped rather than holding up the queue. `.directory(url, suiteName:)`
puts the queue and the state somewhere else (an app group); `.memory` writes nothing.

Each event's `distinct_id`, super properties and groups are fixed when it is tracked, not
when it is sent. A property JSON can't hold is sent as text (a `Date` as ISO 8601).

**Lifecycle** (`captureApplicationLifecycleEvents`, default true):

- `$app_installed` `{version, build}` on the first launch, and `$app_updated`
  `{version, build, previous_version, previous_build}` when either changed since the last
  launch. The version seen is kept in UserDefaults (`apphelm.appVersion`, `apphelm.appBuild`).
  An app that already used an earlier Apphelm (it has a stored distinct id or install record)
  is not counted as a new install the first time this version runs. Not detected with
  `.memory`.
- `$app_opened` `{from_background, version, build}`: once at launch (`from_background:
  false`) and on each return from the background (`true`). A brief interruption, such as a
  call alert, is not an open. `$app_backgrounded` when the app goes to the background. These
  two need UIKit.
- `$install` from `recordInstall()` is separate: it is the ad-measurement install (below).

**Screens.** `screen(name, properties:)` sends `$screen` with `$screen_name`. With
`captureScreenViews` (default true) every UIKit view controller that appears sends one too:
`viewDidAppear` is swizzled once, and the name is the type name without `ViewController`
(`CheckoutViewController` → `Checkout`). Navigation, tab, split and page controllers, a child
inside another screen, SwiftUI hosting controllers and the system's own controllers are left
out. A controller can name itself, or opt out by returning nil, with `ApphelmScreenNaming`
(`var apphelmScreenName: String?`). In SwiftUI, `.apphelmScreen("Name", properties:)` sends a
`$screen` each time the view appears, with the client in `.environment(\.apphelm, client)`,
or else the client created most recently.

**Identity and groups**, the same contract as the server and the other SDKs:

- `identify(distinctId, traits:)` sends `$identify` with `distinct_id` set to the new id,
  `$anon_distinct_id` set to the anonymous id used until then, and `$set` with the traits.
  Later events carry the new id, which is kept across launches. Identifying again as the
  same person without traits sends nothing; identifying as someone else while identified
  sends no `$anon_distinct_id`, so two people are never merged. Call `reset()` at log-out.
- `alias(alias)` sends `$create_alias` with `alias`, from the current id.
- `group(type:key:traits:)` puts `$groups` `{type: key}` on every later event (kept across
  launches; `groups` reads them) and, with traits, sends `$groupidentify` with `$group_type`,
  `$group_key` and `$group_set`.
- `register(properties)` / `unregister(key)`: super properties on every later event, kept
  across launches. An event's own properties win.
- `reset()`: a new anonymous id, and no identified id, super properties or groups. Opt-out is
  kept. A `distinctId` passed in `ApphelmOptions` still wins on the next launch.
- `identify(externalUserId:traits:traitSources:)` is unchanged: it posts the
  provenance-checked customer profile (`apphelm.identify`) at once and does not change the
  distinct id. Use both when you keep customer profiles: the first for analytics identity,
  the second for the profile.

Customer signals (`apphelm.identify`, `apphelm.group`, `apphelm.goal`, `apphelm.outcome`)
carry no super properties, groups or `$ad_consent`: the server holds them to a strict shape.

**Opt-out.** `optOut()` deletes the queue and stops everything being queued or sent: events,
screens, lifecycle events, exceptions, crash reports (deleted, not sent later),
transactions and both identifies. `optIn()` turns it back on. The choice is kept in
UserDefaults (`apphelm.optedOut`); `defaultOptedOut: true` starts opted out until `optIn()`.
Flag checks and surveys still work while opted out.

**Flags.** `getFeatureFlag(_:)` (0.7.0) answers as PostHog's does: `.enabled` (PostHog's
`true`) for an enabled boolean or remote config flag, `.variant("test")` for a multivariate one,
`.disabled` otherwise or on any failure; `.anyValue` gives `true`, `false` or the variant string.
`FlagEvaluation.value` gives the same for a row from `evaluateFlags` or `evaluateLocalFlag`. For an
experiment flag it queues the exposure with the variant the server served (`"on"` for a boolean
flag). There is no `beforeSend` hook in the Swift SDK.

Upgrading from 0.5: `screen` sends `$screen` with `$screen_name` (it was `page_viewed` with
`path`), events are sent without calling `flush()`, and the queue is on disk and holds 1000.

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
and is sent with the next flush. It is the only event a session costs.

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

## Ad measurement

Installs and conversions reach the ad platforms through Apphelm, with no Firebase, Meta SDK
or MMP in the app: Apphelm forwards them to Yieldline, which reports them to Apple, Google,
Meta and the others. It is off unless you set `adsConsent`. Asking the person is your app's
job; Apphelm takes the answer you pass and switches the rest on from it.

```swift
var options = ApphelmOptions(/* … */, adsConsent: userAgreedToAds ? .measurement : nil)
// .personalization when they also agreed to ads personalised from it
let apphelm = ApphelmClient(options: options)

// Early on every launch: queued the first time only, sent with the next flush.
await apphelm.recordInstall()
await apphelm.flush()

// When the person answers (or changes their answer) later:
apphelm.setAdsConsent(.measurement) // or nil to stop
```

- While `adsConsent` is set, every event carries `$ad_consent` (`measurement` or
  `personalization`), so Yieldline knows what each conversion may be used for. With nil,
  events carry nothing ad-related. Events already queued keep the consent they were tracked
  under. Identify, group, goal and outcome signals never carry it.
- `recordInstall(appVersion:)` queues `$install` once per install, remembered in
  `installStore` (`UserDefaultsInstallRecordStore`, key `apphelm.installRecorded`, by
  default). It carries `platform` (`ios` or `macos`) and `app_version` (by default the
  bundle's `CFBundleShortVersionString`), and is sent with or without consent: without it,
  it is an ordinary analytics event.
- With consent, `$install` also carries `$ad`: the platform and the Apple Ads attribution
  token from AdServices (`AAAttribution.attributionToken()`), which Yieldline exchanges with
  Apple to attribute the install to a Search Ads campaign. When the system gives no token
  (a simulator, an older OS, an error) `$ad` is sent without it.
- No App Tracking Transparency prompt, and no advertising identifier (IDFA) is read: the
  attribution token does not need either. AdServices is a system framework; the package
  still has no dependencies.

## Session replay (wireframe)

Replay records each screen as a wireframe: the position, size and colours of its views, their
text (masked as below) and taps. It is not video and no pixels are captured. A new wireframe is
taken only when the screen changes (checked once a second); chunks upload every few seconds and
when the app goes to the background.

It is off until you set `replay` and declare the person's consent. Consent is yours to collect;
Apphelm does not ask.

```swift
var options = ApphelmOptions(apiKey: "ahl_live_…", workspaceId: "org_…", productId: "prd_…")
options.replay = ReplayOptions(projectKey: "ahl_pub_…", origin: "https://app.example.com")
let client = ApphelmClient(options: options)

// From your consent prompt:
client.setReplayConsent(true)   // starts recording
client.setReplayConsent(false)  // stops at once and discards anything not yet sent
```

- **Key and origin.** Replay uploads to the browser collector (`/api/replay`) with the product's
  project key (`ahl_pub_…`) and one of the origins that key allows, like surveys. Without
  `projectKey`/`origin` the `surveyKey`/`surveyOrigin` pair is used. A key that is not a project
  key is refused: replay stays off and nothing is sent. Add the origin to the key's allowed
  origins in Setup.
- **Masking (defaults).** Text fields show asterisks (`maskAllTextInputs`, default true).
  Password fields (`isSecureTextEntry`, or a password content type) are always `********`, never
  their value or length. `maskAllText: true` masks labels and button titles too. Images are
  drawn as placeholders and web views as empty boxes.
- **Blocking and masking a view.** `view.apphelmReplayNoCapture = true` draws the view as an
  empty box and records nothing inside it; `view.apphelmReplayMask = true` masks its text and
  its children's. An `accessibilityIdentifier` containing `ph-no-capture`/`apphelm-no-capture`
  or `ph-mask`/`apphelm-mask` does the same.
- **Screens not recorded.** Sign-in, sign-up, checkout, payment, billing and admin screens are
  paused, as on the web; add more by name with `blockedScreens`. Screen names come from
  `screen(_:)` (UIKit screens are captured on their own).
- **Lifecycle.** `reset()` ends the recording; coming back after 30 minutes in the background
  starts a new one. Opting out of analytics stops replay too. `isReplayActive` and
  `replaySessionId` tell you the state; `flushReplay()` uploads now.
- **Not captured.** Keyboard, alerts and other windows than the key window, scroll offsets
  inside a view beyond its frame, and SwiftUI content that is not backed by UIKit views (it shows
  as the boxes of its hosting views, without its text).

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
