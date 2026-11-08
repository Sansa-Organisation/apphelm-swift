# Apphelm native iOS/macOS SDK

Swift Package Manager library on URLSession, with no dependencies. UIKit is used only where it
exists, for lifecycle events, screen autocapture and background flushing; no WebKit, no JavaScript.

- `ApphelmClient`: `track`, `screen` (`$screen`), `identify`, `alias`, `group`, `register`, `reset`, `optOut`, `evaluateFlags`, fail-closed `isEnabled` and `getFeatureFlag`, `captureException`. Events wait in a queue on disk and are sent on their own (below); `flush()` sends them now.
- Lifecycle events (`$app_installed`, `$app_updated`, `$app_opened`, `$app_backgrounded`) and UIKit screen views, captured automatically; `.apphelmScreen("Name")` for SwiftUI.
- Crash capture: `installCrashReporting()` and `sendPendingCrashReports()` (uncaught `NSException`s and fatal signals, sent on the next launch with the crashed run's scope and breadcrumbs).
- Errors: `captureException`, `captureMessage`, `beforeSend`, breadcrumbs (`addBreadcrumb`, `beforeBreadcrumb`, automatic ones), `setTag`, `setTags`, `setContext`, `setUser`, `withScope`, `configureScope`, `captureEvent`, `lastEventId`, and the `sampleRate`, `ignoreErrors`, `ignoreTransactions`, `denyUrls`, `allowUrls`, `debug` and `enabled` options (below).
- Structured logs (`logger`), user feedback (`captureFeedback`), cron monitors (`checkIn`, `withMonitor`), and `flush(timeout:)` / `close(timeout:)` (below).
- Tracing: `startTransaction`, spans with `data`, W3C `traceparent` (and Sentry's `sentry-trace`), and screen and `URLSession` spans without wrapping each call (below).
- Mobile measurements: app start (cold/warm), screen loads with TTID/TTFD, and slow and frozen frames (below).
- Release health: automatic sessions, or `startSession` and `endSession` (below).
- Ad measurement: `adsConsent`, `setAdsConsent` and `recordInstall` (below). Off unless you set `adsConsent`.
- `evaluateLocalFlag` + `assignmentBucket`: pure local evaluation in the same assignment family as the server and every other SDK.
- Distinct ids persist through an injectable store (`UserDefaultsStore` by default).

```bash
swift test
```

Install with Swift Package Manager:

```swift
.package(url: "https://github.com/Sansa-Organisation/apphelm-swift.git", from: "0.8.1")
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
(any 4xx but 408 and 429: invalid, too large, a wrong or revoked key, a missing scope) is
dropped rather than holding up the queue. `.directory(url, suiteName:)`
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
flag).

Upgrading from 0.5: `screen` sends `$screen` with `$screen_name` (it was `page_viewed` with
`path`), events are sent without calling `flush()`, and the queue is on disk and holds 1000.

## Errors: messages, beforeSend, breadcrumbs and scope

```swift
var options = ApphelmOptions(apiKey: "ahl_live_…", workspaceId: "org_…", productId: "prd_…", release: "shop@2.4.1", environment: "production")
options.beforeSend = { properties in
  // Every event passes through here; nil drops it. `$event_name` says which event it is.
  if properties["$event_name"] as? String == "$exception", (properties["message"] as? String)?.contains("cancelled") == true { return nil }
  return properties
}
options.beforeBreadcrumb = { crumb in crumb.category == "http" && crumb.message.contains("/health") ? nil : crumb }
options.maxBreadcrumbs = 100 // kept on the device; each event carries the last 30
let apphelm = ApphelmClient(options: options)
try apphelm.installCrashReporting()
Task { await apphelm.sendPendingCrashReports() }

apphelm.setUser(id: user.id)          // only a hash is sent (user_hash)
apphelm.setTag("plan", "pro")         // on every later exception, message and crash
apphelm.addBreadcrumb(category: "cart", message: "Added SKU-42")

try await apphelm.captureMessage("Cart sync fell back to cache", level: .warning)
do { try await checkout() } catch { try await apphelm.captureException(error) }

// Tags, user, breadcrumbs and transaction for one piece of work (and its child tasks):
try await apphelm.withScope { scope in
  scope.setTag("order", order.id)
  try await process(order)              // an error captured in here carries order=…
}
```

- `captureMessage(message, level:, fingerprint:, tags:)` reports something noteworthy with no
  error object. It becomes an issue grouped by its text (or `fingerprint`), with its `level`
  (`fatal`, `error`, `warning`, `info`, `debug`) and no stack. `captureException` and
  `captureMessage` return `false` when `beforeSend` dropped the event or the client is opted
  out, and throw `ApphelmError` when the server refuses it.
- `beforeSend` (new in 0.8.0, the same hook as Kotlin's) is called with the properties of
  **every** event before it is queued or sent: tracked events, screens, identify, alias and
  group events, flag exposures, sessions, exceptions, messages, crash reports and
  transactions. The event's name is in `$event_name` (read-only: removed before sending).
  Return the properties, changed or not, or nil to drop the event; a result that can't be
  sent as JSON drops it too. A crash report it drops is deleted. Keep it quick: it runs on
  the thread that tracks the event.
- Scrubbing (always on, the same rules as every AppHelm SDK and the server): before
  `beforeSend` runs, secrets and emails in exception and crash messages, stack frames, tags,
  breadcrumb messages, transaction names and span descriptions and data become `[key]`,
  `[jwt]`, `[private key]`, `[email]`, `[token]` or `[redacted]`; frames, breadcrumbs and
  span descriptions lose query strings (SQL descriptions keep their `?` placeholders), and `url.full` / `http.url` / `url` span data lose the
  query, fragment and user info. A crash report is scrubbed when it is sent on the next
  launch, not while the app crashes. Ids, release, environment and debug images are left as
  they are. What `beforeSend` returns is sent as it is; the server scrubs again.
- Exceptions, messages and crash reports carry `tags` (the call's, then the scope's, then
  `setTag`'s, up to 20; keys of letters, digits, `_`, `.` and `-` up to 40, others ignored),
  `user_hash` (SHA-256 of `apphelm-user:<id>`, first 32 hex characters; the raw id is never
  sent), the last 30 `breadcrumbs` as `{at, category, message}`, and the `trace_id` of the
  transaction running when they were captured (or the one you pass).
- Breadcrumbs: `addBreadcrumb(Breadcrumb(category:message:level:data:))` or
  `addBreadcrumb(category:message:)`. Categories are cut to `[a-z0-9_.-]{1,20}`, messages to 200
  characters, and query strings, fragments and credentials are removed from URLs in them.
  `level` and `data` stay on the device for `beforeBreadcrumb`. Automatic ones
  (`enableAutoBreadcrumbs`, default true): `navigation` for each screen, `app.lifecycle`
  (`foreground`, `background`), `device.event` (`Low memory`), `http`
  (`GET https://api.example.com/v1/cart 200`, for requests through `data(for:)` or
  `httpSpanDelegate()`) and, on UIKit, `ui.click` (`checkout: on CheckoutViewController`, plus
  the sender's accessibility identifier; never a label's text).
- `withScope { scope in … }` (synchronous or `async`) gives the work inside it, and the child
  tasks it starts (Swift task-locals), its own tags, user, breadcrumbs and `transaction`,
  on top of the client's. Scopes nest; the innermost wins. `addBreadcrumb` inside a scope
  adds to that scope only.
- Crashes: `installCrashReporting()` keeps the scope (release, environment, session, tags,
  user hash, breadcrumbs) written beside the crash file (`scope-active.json`, rewritten in
  the background when it changes), and the next launch sends the crash with it. Breadcrumbs
  added in the last moments before a crash may be missing. Fatal signals are `SIGABRT`,
  `SIGBUS`, `SIGFPE`, `SIGILL`, `SIGSEGV`, `SIGSYS` and `SIGTRAP` (Swift traps such as
  `fatalError` and force-unwrapping nil). An uncaught `NSException` is reported once, not
  again as the `SIGABRT` its `abort()` raises.
- **Swift's `Fatal error: …` message:** `fatalError`, `precondition` and the runtime's own
  traps write their message into libswiftCore's crash annotations (`__DATA,__crash_info`,
  the text Apple's crash reports show) before trapping. The signal handler copies it into
  the report (at most 1,000 bytes, read last, after the frames), and the next launch sends it
  as the crash's `message` (`MyApp/Cart.swift:42: Fatal error: Total went negative`),
  scrubbed like any message, in place of `The app crashed with SIGTRAP`. As Sentry does, from
  libswiftCore only. An optimised (`-O`) build keeps `fatalError`'s message but compiles
  force-unwrapping nil and failed `precondition`s to bare traps with none, so those still read
  `The app crashed with SIGTRAP` (or `SIGILL`).
- **Stack overflows on any thread:** the signal handler of a crashed thread runs on that
  thread, and after a stack overflow it has no stack left, so it needs an alternate signal
  stack, which only the thread itself can set up. The thread that calls
  `installCrashReporting()` gets one at once; every thread started after it (`Thread`,
  `pthread_create`, Dispatch's worker threads) gets one as it starts, through libpthread's
  public introspection hook (`pthread_introspection_hook_install`), freed as it ends; a hook
  installed before Apphelm's is still called. Each started thread's 128 KB is `mmap`ed, so only
  the pages a crash handler touches use memory; the installing thread's is 64 KB (or
  `SIGSTKSZ` if larger), and is left alone when that thread already has one. Threads that were already running at install (other
  than the installing one) have none, so an overflow on them is not recorded: install early.
  This replaces Sentry's Mach exception handler for this case; see "What is different from
  Sentry's crash reporter" below.

### App hangs and watchdog terminations

```swift
var options = ApphelmOptions(/* … */, release: "shop@2.4.1")
options.appHangTimeoutInterval = 2              // default; enableAppHangTracking is on by default
options.enableReportNonFullyBlockingAppHangs = true
options.enableWatchdogTerminationTracking = true  // default
let apphelm = ApphelmClient(options: options)
try apphelm.installCrashReporting()             // starts both
Task { await apphelm.sendPendingCrashReports() }

apphelm.pauseAppHangTracking()                  // around work you know blocks the main thread
apphelm.resumeAppHangTracking()
```

- **App hangs** (`enableAppHangTracking`, default true, `appHangTimeoutInterval` 2 s, as
  Sentry's): a background thread wakes every fifth of the timeout. While the UIKit display
  link runs (`enableFramesTracking`), it measures how late frames were over the last timeout,
  as Sentry's V2 tracker does: one frame late for the whole of it is a **fully blocking**
  hang (`App Hang Fully Blocked`); two or more frames that together were late for 99% of it
  is a **non-fully blocking** one (`App Hang Non Fully Blocked`,
  `enableReportNonFullyBlockingAppHangs`, default true). Without the display link (macOS, or
  frames tracking off) it puts a block on the main queue and calls it a fully blocking hang
  when the block hasn't run after the timeout (Sentry's V1). When a hang is found, the main
  thread is suspended for a moment and its stack read from outside it (frame pointers, as the
  profiler does), so the issue shows where the main thread was stuck, symbolicated with your
  dSYMs like a crash. When the hang ends, it is sent as an error (level `error`, mechanism
  `AppHang`, `App hanging between 2.4 and 2.8 seconds.`) with the scope at that moment,
  through `ignoreErrors`, `sampleRate` and `beforeSend`. Nothing is detected while the app
  is not active, after the process was suspended, under a debugger (the tracker doesn't start
  when one is attached) or while paused; a hang under way when the app leaves the foreground
  is dropped.
- **Fatal app hangs:** a hang is written beside the crash reports while it lasts
  (`app-hang-active.json`, with the stack, its duration so far and the scope). If the app never
  comes out of it (the person or the watchdog kills it), the next launch sends it as `Fatal App
  Hang Fully Blocked` (level `fatal`, unhandled, `The user or the OS watchdog terminated your app
  while it blocked the main thread for at least 3.4 seconds.`) with that run's release and
  scope and session. It ends that session **abnormal**, not crashed (the event carries
  `session_status: abnormal` and `abnormal_mechanism: anr_foreground`, as sentry-cocoa names it,
  so it counts in the Releases page's ANR rate), as Sentry does: release health lists abnormal sessions beside
  crashed ones and leaves them out of crash-free rates. If the run crashed during the hang, the crash is sent and the hang is sent as it was found (level
  `error`).
- **Watchdog terminations** (`enableWatchdogTerminationTracking`, default true, iOS, tvOS and
  visionOS, as Sentry's): iOS kills a foreground app that uses too much memory, or that keeps
  its main thread blocked too long, and nothing in the process sees it. The next launch infers
  it from `app-state.json` (beside the crash reports), by Sentry's rules: the previous run is
  reported unless there is no record of it, this is a simulator, the release or OS version
  changed, the device rebooted, the vendor id is missing or changed, a debugger was attached,
  the app was terminated normally (`willTerminate`, or `exit()`, which Sentry doesn't watch),
  it crashed, Apphelm was closed (`close()`), it was not in the foreground and active, or an
  app hang was under way (sent as a fatal app hang instead). It is sent as an unhandled
  `WatchdogTermination` (level `fatal`, mechanism `watchdog_termination`, `The OS watchdog
  terminated your app, possibly because it overused RAM.`) with that run's scope, so it marks
  that run's session crashed, as Sentry's does. It has no stack: nothing ran when it happened.
- The state file is rewritten when the app becomes or stops being active and when it
  terminates (a few hundred bytes each time). A kill in the background (the system reclaiming
  memory) is not reported, as in Sentry. Call `installCrashReporting()` on the main thread, as
  at launch: the vendor id is read from `UIDevice` there, and a launch that installs on
  another thread skips the check.

### What is different from Sentry's crash reporter

- **No Mach exception handler.** SentryCrash also catches Mach exceptions (`EXC_BAD_ACCESS`
  and the like) on a dedicated thread, which is how it records a stack overflow on any
  thread, and it turns its crash handlers off under a debugger. Apphelm records the same
  crashes through signals (the kernel turns those exceptions into `SIGSEGV`, `SIGBUS`,
  `SIGILL`, `SIGFPE` and `SIGTRAP`), and covers stack overflows with a per-thread alternate
  stack instead. A Mach handler would have to run in the crashing process without allocating
  while every other thread may hold the allocator's lock, which Swift can't promise. The
  difference that remains: an overflow on a thread that was already running before
  `installCrashReporting()` (other than the installing one) is not recorded. Apphelm's signal
  handlers stay installed under a debugger, which stops at the crash before they run.
- C++ exceptions are reported as the `SIGABRT` of `std::terminate`, without the exception's
  type or message (SentryCrash reads them).
- Only the crashed thread's stack is sent, and only the main thread's for a hang (Sentry sends
  every thread).

### Filtering, sampling, `debug` and `enabled`

```swift
var options = ApphelmOptions(apiKey: "ahl_live_…", workspaceId: "org_…", productId: "prd_…", release: "shop@2.4.1")
options.sampleRate = 0.5                                  // send half of all errors (default 1)
options.ignoreErrors = ["CancellationError", .regex("^Network.*timed out$")]
options.ignoreTransactions = [.regex("^health")]          // never sent, never profiled
options.denyUrls = ["VendorKit"]                          // errors whose top frame is in VendorKit
options.allowUrls = [.regex("^Shop")]                     // only errors whose top frame is in Shop…
options.debug = true                                      // the SDK's own diagnostics in the unified log
options.enabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
```

- Errors (exceptions, messages, `captureEvent` and crash reports) go through, in order:
  `enabled`, `ignoreErrors`, `denyUrls`, `allowUrls`, `sampleRate`, the scope (tags, contexts,
  breadcrumbs, user hash, trace), the scrubber, then `beforeSend`. A crash report dropped by
  `ignoreErrors` or `sampleRate` is deleted.
- `ignoreErrors` patterns match the message, the error's type or `Type: message`; a plain
  string matches as a substring, `.regex("…")` by search (an invalid regex matches nothing).
  They are matched on the device against the raw text. `ignoreTransactions` matches the
  transaction's name; a matching transaction still has a trace id (errors and propagation
  keep working) but is not sent or profiled.
- `denyUrls` and `allowUrls` take the same patterns and match the binary (image) the error's
  top stack frame is in: the innermost frame, the first line of the stack the event carries
  (`ShopKit`, or your app's executable name for code linked into it). An error is dropped when
  that matches any `denyUrls` pattern, or, with a non-empty `allowUrls`, when it matches none
  of them. They apply to `captureException`, whose stack starts at the code that called it
  (Swift errors carry no stack of their own), and to `captureEvent` with an `exception` whose
  `stacktrace` starts with a line in `Thread.callStackSymbols` form
  (`0   ShopKit   0x0000000100abc123 …`). An error without such a frame is always kept, and so
  are messages and crash reports (a crash's innermost frame is usually the system's:
  CoreFoundation for an `NSException`, `libsystem_kernel` for `abort`). Sentry's Cocoa SDK
  has no such options; they come from Sentry's JavaScript SDK and are AppHelm's own here.
- `sampleRate` (0–1) applies to errors only: transactions follow `tracesSampleRate`, and
  sessions, analytics, logs and feedback are never sampled.
- `debug: true` writes the SDK's own lines to the unified log (subsystem `dev.apphelm`,
  category `sdk`; Xcode's console shows them): why an error was dropped (`disabled`,
  `ignoreErrors`, `denyUrls`, `allowUrls`, `sampleRate`, `beforeSend`), failed sends and refused requests with their
  status. Never event contents.
- `enabled: false` makes the client send nothing at all (events, screens, sessions, errors,
  crash reports, transactions, profiles, replay, logs, feedback and check-ins); captures return
  `false` or nil, and `installCrashReporting` installs nothing. Flag reads and surveys keep
  working, and `withMonitor` still runs its job.

### Contexts, `captureEvent`, `lastEventId` and `configureScope`

```swift
apphelm.setTags(["plan": "pro", "beta": true])
apphelm.setContext("order", ["id": order.id, "items": 3, "express": true])  // nil removes it

// A hand-built error event, sent exactly as captureException / captureMessage would send it:
let id = try await apphelm.captureEvent(ApphelmEvent(
  exception: .init(type: "SyncError", value: "server rejected batch", stacktrace: Thread.callStackSymbols.joined(separator: "\n")),
  fingerprint: ["sync-rejected"], tags: ["queue": "uploads"], contexts: ["batch": ["size": 50]]))
apphelm.lastEventId   // the id of the last exception, message or event captured

apphelm.configureScope { scope in scope.setTag("region", "eu") }  // inside withScope: that scope
```

- `setContext(name, values)` sends the values with every later exception, message and crash
  as tags named `context.<name>.<key>` (tags are what an issue keeps of an event), as the Node
  and Python SDKs do. Names and keys are letters, digits, `_` and `-` (name up to 20, key up
  to 30). Only strings, finite numbers and booleans are kept (nested dictionaries and arrays
  are skipped); strings are scrubbed like breadcrumbs and cut to 200 characters; keys that look
  like secrets or contact details (`password`, `token`, `email`, `phone`, `card`…) are
  dropped. At most 10 contexts of 10 values; an event carries at most 10 context tags, in the
  room its own tags leave of 20, and only those whose whole name fits in 40 characters.
  `scope.setContext` inside `withScope` wins over the client's context of the same name.
- `captureEvent(ApphelmEvent(…))` needs a `message` or an `exception` (`type`, `value`,
  optional `stacktrace`, one frame per line) and takes `level`, `fingerprint`, `tags`,
  `contexts` (for this event only), `release`, `environment` and your own `eventId` (8–64 of
  letters, digits, `_`, `-`). It returns the event id, or nil when the event was dropped.
- Every exception and message now carries its event id (`$event_id`, a lower-case UUID), the
  id `lastEventId` returns and `captureFeedback(_:associatedEventId:)` links to.

### Flushing and closing

```swift
let sent = await apphelm.flush(timeout: 2)   // events, log lines and replay chunks; false on timeout
await apphelm.close(timeout: 2)              // flush, then send nothing more
```

`flush(timeout:)` and `close(timeout:)` never throw; a timeout lets the sends carry on in the
background. After `close`, captures return `false` or nil without a request, tracking does
nothing, and the flush timer stops; flag reads still work. `flush()` (no timeout) is unchanged.

## Logs

```swift
var options = ApphelmOptions(apiKey: "ahl_live_…", workspaceId: "org_…", productId: "prd_…", release: "shop@2.4.1", environment: "production")
options.logsService = "shop-ios"            // OpenTelemetry service.name (default unknown_service)
options.logsMinLevel = .info                // the default; .trace and .debug lines are not sent
options.beforeSendLog = { record in record.message.hasPrefix("heartbeat") ? nil : record }
let apphelm = ApphelmClient(options: options)

let log = apphelm.logger
log.info("Signed in", attributes: ["method": "passkey"])
log.error("Payment failed", attributes: ["order": order.id, "error": error])
let cart = log.child(["screen": "cart"])    // every line carries screen=cart
cart.warning("Slow cart load", attributes: ["ms": 1800])
```

- The same call shape as Apple's `os.Logger`: `trace`, `debug`, `info`, `notice` (sent as
  info), `warning` (also `warn`), `error`, `critical` and `fault` (sent as fatal), `fatal`,
  and `log(level, message, attributes:)`. An app can't read `os.Logger` lines back, so log
  the lines you want in AppHelm through this logger (to both, if you want them in Console too).
- Lines are batched (every `logsFlushIntervalSeconds`, default 2 s, or `logsMaxBatch`, 500
  lines) and sent as OpenTelemetry records to `POST /api/v1/logs`, exactly what an OTLP
  exporter sends (docs/LOGS.md). A line logged while a transaction is active carries its trace
  and span id, so it shows on the trace. An `Error` attribute becomes `exception.type` and
  `exception.message`.
- Privacy: the message and every string attribute (nested too) are scrubbed of secrets,
  emails and query-string tokens before `beforeSendLog` sees them; `trace_id`, `span_id`,
  `session_id` and `distinct_id` are kept as they are. The server redacts again.
- At most `logsMaxQueue` (10,000) lines wait; past it the oldest are dropped. A batch the
  server throttles or can't take (429, 5xx, network) is tried once more; any other refusal
  drops it. `logger.dropped` counts them. Sending never throws.
- The key needs `logs:write` (or `events:write`, which every server key has). `flush(timeout:)`
  and `close` include queued lines; `logger.flush(timeout:)` sends only them.

## User feedback

```swift
// After an error, ask the person what happened and link it to that error's issue:
try await apphelm.captureFeedback("The app froze when I tapped Pay", associatedEventId: apphelm.lastEventId)
```

- Stored as `human` feedback with `private_analysis` permission (`POST /api/v1/feedback`), on
  the issue of `associatedEventId` (from `lastEventId` or `captureEvent`). The message is
  scrubbed (emails, keys, tokens) and cut to 5,000 characters. The key needs `feedback:write`.
- `name` and `email` are accepted, so Sentry calls compile, and are **never sent**: AppHelm
  keeps no contact details with feedback.
- Returns AppHelm's answer (`id`, `profileId`, `replayed`), or nil when the client is disabled,
  closed or opted out. Throws `ApphelmError` for an empty message or when the server refuses it.

## Cron monitors

```swift
// A whole run: in_progress, then ok with its duration, or error (the job's error is rethrown).
try await apphelm.withMonitor("nightly-sync", monitorConfig: MonitorConfig(schedule: .crontab("0 3 * * *"), checkinMarginMinutes: 5, maxRuntimeMinutes: 30)) {
  try await syncEverything()
}

// Or by hand:
let id = newCheckInId()
try await apphelm.checkIn("nightly-sync", status: .inProgress, checkInId: id)
try await apphelm.checkIn("nightly-sync", status: .ok, checkInId: id, durationMs: 1200)
```

The same calls as the Kotlin client (`POST /api/v1/check-ins`; the key needs `events:write`).
A malformed slug (a lower-case letter or digit, then up to 63 of `a-z 0-9 _ -`), check-in id or
config throws `ApphelmError`; delivery never does (nil when it could not be sent).
`.interval(minutes:)` takes 1 to 10,080. A check-in that can't be delivered never fails the job.

## Release health

```swift
let apphelm = ApphelmClient(options: ApphelmOptions(/* … */, release: "shop@2.4.1")) // sessions are automatic

// Or by hand:
var options = ApphelmOptions(/* … */, release: "shop@2.4.1")
options.enableAutoSessionTracking = false
// When the app becomes active:
apphelm.startSession()
// When it goes to the background:
apphelm.endSession()
```

**Automatic sessions** (`enableAutoSessionTracking`, default true from 0.8.0; needs
`release`): a session starts when the app comes to the foreground. Going to the background
only notes the time; coming back after `sessionTrackingIntervalSeconds` (default 30, as
Sentry's) or more ends that session and starts a new one, and a shorter absence continues
it. Without UIKit (macOS) one session runs per launch. Each session is one `$session` event.
A crash sent on the next launch carries the crashed session's id, which marks it crashed.

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

Crashes: the crashed run's scope, written beside the crash file while it ran, names the
session that was running, with its release and environment, and `sendPendingCrashReports()`
sends the crash with them (never with this launch's session). For a report without that
file (written by a version before 0.8.0), each session's start and end are also noted next
to the crash reports (`sessions.json`, the last ten sessions), and the session running when
the report was written is found by the file's modification time. A crash written when no
session was running (before the first, or after `endSession()`) carries no session. Sessions
are noted in the directory given to `installCrashReporting`; with `startSession(directory:)`
pass the same one.

A watchdog termination in the foreground (out of memory, the watchdog; see "App hangs and
watchdog terminations") is sent on the next launch with the session it ended, which marks
that session crashed, as Sentry's does. A fatal app hang is sent with its session too and marks
it abnormal (`session_status: abnormal`), as Sentry does. A handled error (`captureException`, an
app hang the app came out of) marks its session errored on the server; a message doesn't.

Not covered: a process the system kills in the background is not a crashed session (as in
Sentry). Tracked events and screens don't carry the session id. There is no session-end
event and no session duration (the server has no use for them).

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

> Automatic tracing (transactions from installed middleware and integrations, automatic screen loads and app starts) is off until you set a trace sample rate (`traces_sample_rate`, `tracesSampleRate` or a `tracesSampler`); an incoming sampled `traceparent` is always honoured, and transactions you start yourself are kept at a rate of 1 when no rate is set.

`tracesSampleRate` is a `Double?`, not set (nil) by default. `startTransaction(name, op:
"task", traceparent: nil)` starts a transaction, which is kept with the probability
`tracesSampler` returns, else `tracesSampleRate`, else (no rate set) always. In this SDK
the automatic transactions are the UIKit screen loads (`enableUIViewControllerTracing`) and
app starts (`enableAppStartTracking`). They need both their flag and a rate or sampler:
the flags stay off by default because they swizzle UIKit methods, so swizzling is always
your choice, and with a flag on but no rate or sampler set they still swizzle nothing. If you pass a W3C `traceparent`, it
continues that trace: its trace id, parent span and sampling decision are kept. A malformed
or all-zero header starts a new trace. Spans come from `startSpan(op, description:)` and
`finish(.ok | .error)`, or from `span(op, description:) { }` (synchronous or `async`), which
finishes as an error if the closure throws and then rethrows. At most 50 are kept. Spans
take `data` (`startSpan("db.sql.query", description: sql, data: ["db.system": "sqlite"])`,
`span.setData("cache.hit", true)`): scalar attributes such as `http.response.status_code`,
`db.system`, `cache.hit`, `cache.key` and `messaging.destination.name`, which the server
indexes. `span.startChild(op)` nests a span under another; `transaction.setData` and
`transaction.setMeasurement(name, value:)` add attributes and whole-number measurements to
the transaction. A Sentry `sentry-trace` header value is accepted where a `traceparent` is,
so a call from a Sentry-instrumented client joins its trace. `tracesSampler` (a closure
given the name, op and parent decision, returning a rate or nil for `tracesSampleRate`)
decides new traces; setting it also turns automatic tracing on.
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
- Each HTTP span's `data` carries `http.request.method`, `http.response.status_code`,
  `server.address` (the host) and `url.full` (`scheme://host[:port]/path`, never the query),
  and each request leaves an `http` breadcrumb, with or without a transaction.
- No span is recorded without an unfinished transaction; nothing at all for a URL that is
  not http(s), or for the client's own requests to Apphelm. Use the wrapper or the delegate
  on a session, not both, or each request is recorded twice.

### Every URLSession request, automatically

With a trace sample rate set, every `URLSession` request is an `http.client` span of the
active transaction, with no wrapper, delegate or change at the call sites (Sentry's
`enableNetworkTracking`), and every request leaves an `http` breadcrumb, with or without a
rate (`enableNetworkBreadcrumbs`). Both are on by default, as Sentry's.

```swift
var options = ApphelmOptions(/* … */, tracesSampleRate: 0.2, tracePropagationHosts: ["api.example.com"])
options.enableNetworkTracking = false     // no automatic spans
options.enableNetworkBreadcrumbs = false  // no automatic http breadcrumbs
options.enableSwizzling = false           // no swizzling at all (URLSession, file I/O, Core Data, UIKit)
```

- `URLSessionTask`'s `resume` and `setState:` are swizzled, as Sentry's are: `resume` starts
  the span (`GET https://api.example.com/v1/cart`, the same description and `data` as
  `data(for:)`), and the task completing finishes it, an error for a failure or a response
  from 400 up. Data, upload and download tasks, from any session, delegate or completion
  handler; not stream or WebSocket tasks.
- `traceparent` naming the span is added to the task's request before it is sent, for hosts
  in `tracePropagationHosts` only (empty by default). Sentry's `tracePropagationTargets`
  defaults to every host; AppHelm's default sends the header nowhere until you list your own
  services, since it tells the receiver the trace id. No `baggage` header.
- Requests to Apphelm itself (any client's `baseURL`) are never recorded. Requests made
  through `data(for:)` are recorded by it, and a session with `httpSpanDelegate()` by the
  delegate, never twice.
- Spans need `tracesSampleRate` or `tracesSampler` (automatic tracing is off without one);
  breadcrumbs need `enableAutoBreadcrumbs`. With both options off, nothing is swizzled.
- **Behaviour change:** before this release nothing swizzled `URLSession`. Every app that
  upgrades now gets an `http` breadcrumb per request; set `enableNetworkBreadcrumbs = false`
  to keep the old behaviour.
- Not covered: Sentry's `enableCaptureFailedRequests` (an error event for each 5xx response)
  and GraphQL operation names.

### File I/O and Core Data spans

```swift
var options = ApphelmOptions(/* … */, tracesSampleRate: 0.2)
options.enableFileIOTracing = true     // default, as Sentry's
options.enableCoreDataTracing = true   // default, as Sentry's

// Swift's own Data no longer reads and writes through NSData on recent systems:
let cart = try Data(contentsOfWithApphelmTracing: cartURL)
try cart.writeWithApphelmTracing(to: backupURL)
try FileManager.default.removeItemWithApphelmTracing(at: oldURL)
```

- **File I/O** (`enableFileIOTracing`): `NSData`'s `initWithContentsOfFile:`,
  `initWithContentsOfFile:options:error:`, `initWithContentsOfURL:options:error:`,
  `writeToFile:atomically:` and `writeToFile:options:error:` (Sentry's list), plus
  `writeToURL:options:error:` (where `NSData.write(to:)` goes), and on iOS 18 / macOS 15 and
  later `FileManager`'s `createFileAtPath:contents:attributes:` (earlier it writes through
  `NSData`, as Sentry notes) are `file.read` / `file.write` spans of the active transaction,
  described as Sentry does (`cart.json (1.5 KB)`), with `file.path`, `file.size` and
  `blocked_main_thread`. A call inside a recorded one is part of it. Apphelm's own files are
  never recorded.
- Swift's `Data(contentsOf:)` and `Data.write(to:)` don't go through `NSData` on recent
  systems (checked on macOS 26; older ones did), so they are not seen; use
  `Data(contentsOfWithApphelmTracing:)`, `writeWithApphelmTracing(to:)` and `FileManager`'s
  `createFileWithApphelmTracing`, `removeItemWithApphelmTracing` (`file.delete`),
  `copyItemWithApphelmTracing` (`file.copy`) and `moveItemWithApphelmTracing`
  (`file.rename`), Sentry's `…WithSentryTracing` counterparts. They record for `client`, else
  the client created most recently, whatever `enableFileIOTracing` says.
- **Core Data** (`enableCoreDataTracing`): `NSManagedObjectContext`'s
  `executeFetchRequest:error:` (Swift's `fetch`) is a `db.sql.query` span, `SELECT 'Order'
  WHERE status == "open" SORT BY createdAt DESCENDING`, with `read_count`; `save:` with
  changes is a `db.sql.transaction` span, `INSERTED 2 'Order', UPDATED 3 items`, with
  `operations` (the counts per entity, as JSON). Both carry `db.system` (the stores' types:
  `SQLite`, `InMemory`) and `blocked_main_thread`. Only when the app has Core Data loaded:
  Apphelm doesn't link it.
- Both need `tracesSampleRate` or `tracesSampler`, and an unfinished transaction; without a
  rate nothing is swizzled. Not covered: Sentry also attaches the main thread's frames to a
  span that blocked it, and Core Data's `db.name` (the store's path).

### Mobile measurements: app start, screen loads and frames

```swift
var options = ApphelmOptions(/* … */, release: "shop@2.4.1", tracesSampleRate: 0.2) // a rate is required
options.enableAppStartTracking = true          // app.start.cold / app.start.warm, one event per launch
options.enableUIViewControllerTracing = true   // a ui.load transaction per UIKit screen, with ttid_ms
options.enableTimeToFullDisplayTracing = true  // keep it open for ttfd_ms
let apphelm = ApphelmClient(options: options)

// When the screen has its real content (after its data loaded):
apphelm.reportFullyDisplayed()
```

- **Frames** (`enableFramesTracking`, default true, UIKit): a `CADisplayLink` counts frames.
  A frame longer than the display's refresh interval (it missed its deadline: 16.7 ms at
  60 Hz, 8.3 ms at 120 Hz, with 5% tolerance for timestamp jitter) is slow; one over 700 ms
  is frozen (and not also slow). Every transaction sent while it runs carries
  `frames_total`, `frames_slow` and `frames_frozen` for its duration. It adds no events; the
  first frame after a return from the background is not counted.
- **Screen loads** (`enableUIViewControllerTracing`, default false, and only with
  `tracesSampleRate` or `tracesSampler` set: each screen shown is one event, sampled by
  that rate): `viewDidLoad` and `viewDidAppear` are swizzled. A
  `ui.load` transaction named as `captureScreenViews` names the screen starts before
  `viewDidLoad` runs, and the first frame drawn after `viewDidAppear` records `ttid_ms` and a
  `ui.load.initial_display` span. It then finishes, or with
  `enableTimeToFullDisplayTracing` waits for `reportFullyDisplayed()` (`ttfd_ms`, a
  `ui.load.full_display` span), at most 30 s, after which it finishes without `ttfd_ms`. A
  `reportFullyDisplayed()` before the first frame counts as full display at the first frame.
  HTTP calls made meanwhile are its spans. `startScreen(name)` (your own timing) takes
  `reportFullyDisplayed()` too (`ttfd_ms`) and finishes when you finish it.
- **SwiftUI screen loads** (Sentry's `.sentryTrace` and `SentryTracedView`, in SentrySwiftUI;
  here in the main `Apphelm` product, which already imports SwiftUI):
  `.apphelmTrace("Checkout", waitForFullDisplay:)` on a view, or
  `ApphelmTracedView("Checkout") { CheckoutView() }`, produces the same `ui.load` transaction
  the UIKit swizzle does. It starts the first time the view's body is built and records
  `ttid_ms` and a `ui.load.initial_display` span at the first frame after the view appears;
  `waitForFullDisplay` (default `enableTimeToFullDisplayTracing`) keeps it open for
  `reportFullyDisplayed()` (`ttfd_ms`), at most 30 s. One load per view, however often its
  body is rebuilt. Needs `tracesSampleRate` or `tracesSampler`, not
  `enableUIViewControllerTracing`. It sends no `$screen` (add `.apphelmScreen("Checkout")`).
  The client is `client:`, else the one in `\.apphelm`, else the client created most
  recently. While another transaction runs (an outer traced view's, a UIKit screen load, your
  own), a traced view is a `ui.load` span of it instead, ended at its first frame, as in
  Sentry. Unlike Sentry's, no `<name> - body` span per body build.
- **App start** (`enableAppStartTracking`, default false, and only with `tracesSampleRate`
  or `tracesSampler` set: one event per launch, sampled by that rate): a `$transaction` named `App Start Cold` / `App Start Warm`, op
  `app.start.cold` / `app.start.warm`, from process start (the kernel's `p_starttime`) to the
  first frame after the app first became active, with `app_start_cold_ms` or
  `app_start_warm_ms`. Following Sentry's rules: **cold** on the first launch after install,
  after an update (version or build changed) and after a reboot; **warm** otherwise. A
  process iOS prewarmed (`ActivePrewarm=1`) is measured from when Apphelm was first used
  instead (the process may have waited minutes) and reported as warm. Nothing is sent for a
  launch in the background (a push or background fetch), a start over 180 s, or a second
  start in the same process. The previous launch is remembered in `app-start.json` in the
  crash directory.

App hangs and watchdog terminations are in "Errors" above; profiling is below.

Verified with `swift test` on macOS and `xcodebuild test` on an iOS 26.5 simulator (the
UIKit screen-load swizzle and display link included, and a SwiftUI view traced in a
`UIHostingController`); not yet run on a device. The crash tests fork a child that really
crashes (a stack overflow on a new thread, `fatalError`), on macOS and on the simulator. App
hang detection is tested by stepping the tracker against a blocked queue and a synthetic frame
timeline, and by its own thread timing a real 1.2 s block of a test queue, not with a hang of
a running app's main thread; watchdog terminations by their rules and the
report they leave, not by a real out-of-memory kill.

### Profiling (opt-in)

`options.profilesSampleRate` (0–1, nil by default: off) profiles that share of *sampled* transactions:

```swift
var options = ApphelmOptions(apiKey: "ahl_live_…", workspaceId: "org_…", productId: "prd_…", tracesSampleRate: 0.2)
options.profilesSampleRate = 0.5
```

- A background thread samples the **main thread** every 10 ms while a profiled transaction
  runs, at most 30 s or 3,000 samples: it suspends the thread (`thread_suspend`), reads its
  registers (`thread_get_state`), walks the frame-pointer chain with `vm_read_overwrite` (a bad
  pointer is a failed read, never a crash) and resumes it. Nothing is allocated and no lock is
  taken while the thread is suspended. arm64 and x86_64.
- Frames are addresses (`instruction_addr`); the profile lists the loaded images they fall in
  (`debug_meta`, UUID, load address and `__TEXT` size, file name only), so the server names
  them with the dSYMs you upload (see "Symbolicating stripped builds").
- One profile at a time per process: a transaction starting while another is profiled is sent
  without one. Other threads are not sampled.
- The profile goes to `/api/v1/profiles` when the transaction finishes (at most 1 MB, else
  dropped); the transaction carries its id as `profile_id`. Not passed through `beforeSend`.
- Overhead: each sample stops the main thread for the register read and frame walk (tens of
  microseconds: about 30 µs per sample in the package tests on an Apple-silicon Mac), about
  0.3% of the main thread at 100 samples a second, and nothing when no profile runs.

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
- **Errors link their replay.** While a recording runs, every exception, message and
  `captureEvent` that `beforeSend` keeps carries its id (`replay_session_id`), so the issue opens
  the replay; a crash report carries the crashed run's (below).

### Sampling and replay on error

Sentry's two rates, with the same meaning (0.8.0):

```swift
options.replay = ReplayOptions(projectKey: "ahl_pub_…", origin: "https://app.example.com",
                               sessionSampleRate: 0.1, onErrorSampleRate: 1.0)
```

- `sessionSampleRate` (default 1, every recording, as before 0.8.0) is drawn when a recording
  starts: at the first screen after consent, after 30 minutes in the background and after
  `reset()`. A recording it picks is recorded and uploaded whole.
- `onErrorSampleRate` (default 0, off). A recording `sessionSampleRate` did not pick is then kept
  in memory only, nothing sent: the last `errorBufferSeconds` (default 30, as Sentry's mobile
  SDKs; 10 to 120) and never more than about 2 MB, the oldest dropped first. When an exception
  or `captureEvent` with an exception is reported and `beforeSend` keeps it, the buffer is
  uploaded with this probability, drawn for each error as Sentry's Cocoa SDK does; the replay
  starts with the screen shown at the start of the buffer, and recording carries on as a whole
  recording. A message (`captureMessage`) never uploads a buffer. Until an error uploads it, a
  buffer is no replay: `replaySessionId` is nil and nothing is counted against your plan.
- A buffer is cleared when the app stays in the background longer than
  `sessionTrackingIntervalSeconds` (30 s by default, Sentry's session timeout); the next screen
  starts a new buffer.
- **Crashes.** With `installCrashReporting`, the recording is also written beside the crash
  reports each time replay uploads (every `flushIntervalSeconds`, 5 s by default, and when the
  app goes to the background). After a crash, `sendPendingCrashReports()` on the next launch
  uploads that copy first (a buffer with the crashed run's `onErrorSampleRate`, as Sentry's crash
  recovery does) and links it to the crash report. The copy is not written from the signal
  handler, so the last seconds before a crash can be missing from it. `setReplayConsent(false)`
  deletes stored copies.
- Differences from Sentry: a whole recording ends after 30 minutes in the background (Sentry:
  the session timeout) and runs up to a day (Sentry: 60 minutes). There is no
  `beforeErrorSampling` and no `start()`/`stop()`/`flush()` for the buffer; the feedback API does
  not upload it. Tested with `swift test` on macOS, not yet on a device.
- **Not captured.** Keyboard, alerts and other windows than the key window, scroll offsets
  inside a view beyond its frame, and SwiftUI content that is not backed by UIKit views (it shows
  as the boxes of its hosting views, without its text).

## Symbolicating stripped builds

A release build is stripped, so a crash reports addresses (`0  Shop  0x0000000104935a98 Shop + 6808`).
Upload each dSYM itself, and the server reads its symbol table and its DWARF, so frames show
demangled Swift names, the file and line that ran, and calls the compiler inlined:

```bash
APPHELM_API_KEY=ahl_… npx apphelm debug-files upload "$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME" --product prd_…
# or, with Sentry's tools: sentry-cli debug-files upload … (docs/SENTRY-COMPAT.md)
```

When a build can't send the dSYM (it is too large, or must not leave the machine), a script
turns it into a small symbol table on your build machine and uploads that instead. Its tables
name functions (and, with `--lines`, where each is declared) but have no line table:

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

A dSYM upload's line table covers at most 96 MB of `__debug_info` and about 24 MB of stored
rows per architecture; past that, the upload's answer says which part was skipped and those
frames show the function only. Not covered: line numbers from the script's tables, images
loaded with `dlopen` after `installCrashReporting()`, and Apple's own frameworks, which show
whatever the device printed.


For Android and the JVM, use the Kotlin client (`com.sansavision:apphelm`).
