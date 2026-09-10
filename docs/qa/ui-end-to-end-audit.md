# End-to-end UI audit

Two independent rounds, deliberately decomposed differently so they would not
share blind spots.

- **Round 1 — by file area.** 17 areas across `Sources/App`, `Sources/Domain`
  and `Sources/Infrastructure`.
- **Round 2 — by user journey.** 12 journeys and cross-cutting axes (first run,
  toggle symmetry, change-while-open, text input, system events, lifecycle,
  concurrency, error/empty states, keyboard and accessibility, formatting,
  multiplicity, migration), plus a cross-round critic aimed at everything that
  is *not* Swift source: build configuration, entitlements, the asset catalog,
  the release scripts, and the shell script the hook installer writes.

Round 2 also re-adjudicated every round-1 finding that had not been verified,
with two independent reviewers each — one told to refute it, one told to build
a reproduction. **28 of 33 were upheld, 3 were corrected, 2 were overturned.**

**No build or run was possible.** Linux container, no Swift toolchain, no
Xcode, no macOS. Nothing here was observed in a running app; everything was
established by reading the code that proves or disproves it. Where that is not
enough to settle a question, it says so.

---

## The eight that matter most

### 1. Quota notifications never fire on a default install
`MenuContentView.swift:916,935` · `QuotaMonitor.swift:99-113`

`alerter.alert` is reachable only from `QuotaMonitor.handleSnapshotUpdate`, which
only `refreshProvider` calls. The popover refreshes providers directly —
`try await provider.refresh()` — bypassing the monitor. The only other way in is
the background loop, and `app.backgroundSyncEnabled` defaults to `false`
(`JSONSettingsRepository.swift:174`), so `restartMonitoring` calls
`stopMonitoring()` (`StatusItemLabelDriver.swift:534`).

The app asks for notification permission on first open and can then never post a
quota alert. `NotificationsSpec` is green because it drives `monitor.refresh` —
the one path the UI does not use.

**Fix:** route the popover's refresh through `monitor.refreshAll()` /
`monitor.refresh(providerId:)`.

### 2. The App Store build cannot work at all
`Sources/App/entitlements.mas.plist` · `.github/workflows/appstore-release.yml:169`

The MAS configuration enables `com.apple.security.app-sandbox` and grants only
`network.client` and `automation.apple-events`. Nothing else. The app spawns CLI
binaries, reads `~/.claude` and `~/.touchquota`, writes
`~/.touchquota/settings.json`, and runs a loopback HTTP server for hooks — that
needs file access it does not have, and `network.server`, which is absent. In a
sandbox `homeDirectoryForCurrentUser` returns the container, so even settings go
to the wrong place.

The same workflow blanks `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, which drops
`ENABLE_SPARKLE`, so `UpdatesPane` takes its `#else` branch and tells App Store
users "Updates unavailable in debug builds" — in a shipping release.

**Fix:** either add the entitlements the features need (and accept App Review
2.5.1 risk on the CLI spawning), or don't ship the MAS target.

### 3. Every beta release rolls the stable channel back to 0.2.2
`scripts/update-appcast.sh:126-133,182-183` · `.github/workflows/release.yml:414,468,474`

The script's design is "carry the other channel's latest item forward". It reads
that item from `docs/appcast.xml` **in the git checkout** — which the release
workflow never commits back. It generates the appcast and uploads it to Pages,
committing only `CHANGELOG.md`. The checked-in file is frozen at a single stable
item: **0.2.2**.

So the feature fails in both directions:
- Releasing a **beta** writes `new beta + stable 0.2.2`. Stable-channel users are
  offered 0.2.2 — a downgrade — however many stable releases have shipped since.
- Releasing a **stable** finds no beta item in the frozen file, so it writes the
  new stable alone and drops any live beta entry.

**Fix:** fetch the published appcast from Pages as the seed, or commit
`docs/appcast.xml` back after each release.

### 4. The Touch Bar's "Needs you" state is cancelled a moment after it appears
`SessionMonitor.swift:85-88` · `TouchQuotaApp.swift:239-243`

`updateUsage` treats a grown transcript as proof the session resumed:

```swift
if sessions[index].phase == .awaitingInput,
   usage.contextTokens > (sessions[index].usage?.contextTokens ?? 0) {
    sessions[index].resume()
}
```

The hook loop calls `processEvent` (which sets `.awaitingInput`) and then
`sessionUsageSync.sessionDidChange` (which reads the transcript) for every event,
in that order. Claude Code appends the `tool_use` record *before* it asks for
permission, so the first read after blocking always sees more context and
resumes. The tile loses its amber fill, its "Needs you" line, its attention sort
order and the tray dot colour — the one thing the board exists for.

**Fix:** snapshot `contextTokens` when `awaitInput` is set and require growth
beyond *that*.

### 5. Hook events larger than ~1KB are dropped every time
`HookHTTPServer.swift:100,126-152` · `HookInstaller.swift:18`

The installer writes this into `~/.claude/settings.json`:

```sh
__touchquota_hook() { PORT=$(cat "$HOME/.claude/touchquota-hook-port" ...); cat | curl -s -X POST "http://localhost:${PORT}/hook" -d @- ... & }
```

curl adds `Expect: 100-continue` for `-d` bodies over ~1KB and withholds the body
until the server answers. `HookHTTPServer` never answers. Its single
`receive(minimumIncompleteLength: 1, ...)` returns the headers alone — which
still contain `\r\n\r\n`, so they pass the separator guard at `:129` and the
`POST /hook` prefix check at `:137`. The body slice is empty, the parse fails
("Failed to parse hook event payload"), and the `defer` has already sent 200 and
cancelled the connection before curl's body arrives.

This is not the intermittent segmentation problem round 1 guessed. For any
payload over the threshold it fails deterministically. `Stop` events carry
`last_assistant_message`, which routinely exceeds it — so turns silently never
end, and combined with #7 the session sits "Active" indefinitely.

**Fix:** loop on `receive` until `isComplete`, or honour `Content-Length`; and
send `100 Continue` when the request asks for it.

### 6. Hook server bind failure is silent and permanent
`HookHTTPServer.swift:39-63`

The documented auto-assign fallback is dead code — `port = .any` is reached only
when `defaultPort == 0`. On failure the state handler logs and finishes the
stream; nothing retries and nothing reaches the UI. `start()` returns the stream
before the listener is up, so the caller logs "Hook server started" either way.
The toggle stays ON, the pane still says "installed", and no session ever
appears. Also reachable by toggling OFF then straight back ON: `stop()` only
enqueues `listener.cancel()` while `start()` binds immediately.

**Fix:** rebind with `NWEndpoint.Port.any` on `EADDRINUSE` (the hook script
already reads the real port from the port file), and surface a failed listener.

### 7. A session killed without `SessionEnd` stays "Active" forever
`SessionMonitor.swift:98`

`pruneStale` is documented "Call it on a timer" and nothing does. Its only
callers are `processEvent` — which needs a new event, exactly what a dead session
cannot send — and `TouchBarDriver.expireStaleSessions`, behind `#if ENABLE_TOUCHBAR`
and only while the board is open. Touch Bar and notch both default to off.

**Fix:** tick `pruneStale` from the app-lifetime loop, not from a feature that
defaults off.

### 8. A corrupt `settings.json` is silently treated as empty, then overwritten
`JSONSettingsStore.swift:37,63-70`

`readFileUnsafe` returns `[:]` for any file it cannot parse. Every subsequent
read therefore falls back to defaults, the UI renders as if the user had
configured nothing, and the next write — from any pane, any toggle — serializes
that empty dictionary plus the one changed key and writes it atomically over the
file. One stray character in the file, and every setting is gone with no warning
and no backup.

**Fix:** distinguish "missing" from "unparseable"; on a parse failure, refuse to
write and tell the user which file to fix.

---

## Confirmed — settings that do not take effect

| Finding | Location |
|---|---|
| Turning the menu-bar readout OFF leaves the last number frozen forever: `freshLabel ?? lastKnownLabel(...)` cannot tell "user switched it off" from "momentary data gap" | `StatusItemLabelDriver.swift:174,194` |
| Disabling the menu-bar provider permanently blanks the readout, with no self-heal | `ProvidersPane.swift:109` |
| Bedrock AWS profile is read once in `init` and baked into the CloudWatch client — editing it does nothing until relaunch | `BedrockUsageProbe.swift:19` |
| Switching Claude to API mode silently overwrites the user's Background Sync interval and never restores it | `ClaudeConfigCard.swift:130` |
| Clearing the Claude API budget is a no-op: `if let value = Decimal(string: newValue)` skips the empty string, so the old threshold stays active | `ClaudeConfigCard.swift:331` |
| The Alibaba manual cookie can never be cleared — emptying the field keeps the old value | `AlibabaConfigCard.swift:164` |
| Z.ai config path is never `~`-expanded, so the path its own placeholder suggests breaks the probe | `ZaiUsageProbe.swift:142` |
| Provider chosen in the popup is not persisted; every relaunch snaps back to Claude | `QuotaMonitor.swift:48` |
| Re-enabling a provider does not re-validate the selection, so the popover stays stuck on a disabled one | `QuotaMonitor.swift:369` |
| "Launch at Login" shows a stale value — `SMAppService` status is sampled once per process | `AppSettings.swift:289` |
| Christmas theme auto-enable is evaluated once in `AppSettings.init`, so a resident login-item app never sees the date change | `AppSettings.swift:291` |

## Confirmed — the UI says something untrue

| Finding | Location |
|---|---|
| "Save & Test Connection" reports green Success when the probe never ran — `refreshProvider` returns early on `guard await provider.isAvailable()`, leaving `lastError` untouched (Copilot, MiniMax, Alibaba) | `CopilotConfigCard.swift:595`, `MiniMaxConfigCard.swift:301`, `AlibabaConfigCard.swift:315` |
| Worse: the success check reads shared `provider.lastError`, not the refresh's own result, so an unrelated concurrent failure can flip it | `CopilotConfigCard.swift:597` |
| Overview mode paints a green HEALTHY badge on providers that have no data, directly above their error row | `MenuContentView.swift:488` |
| Sidebar asserts "up to date" with a green dot before any update check has ever run | `SettingsSidebarView.swift:22` |
| Sync & Alerts shows the cadence the user picked while the loop polls up to 30× slower (API floor × battery multiplier) | `QuotaMonitor.swift:486` |
| "Claude Code Finished" reports whichever session ended most recently, not the one that ended | `TouchQuotaApp.swift:271` |
| `HookInstaller.InstallerError` is not `LocalizedError`, so the message naming the corrupt file is replaced by an opaque Cocoa error | `HookInstaller.swift:127` |
| App Store users are told "Updates unavailable in debug builds" in a shipping release | `UpdatesPane.swift:41` |

## Confirmed — state that goes stale or wrong

| Finding | Location |
|---|---|
| `ThemeRegistry` is a plain class, not `@Observable`, so the Appearance grid never refreshes after an import or delete | `ThemeRegistry.swift:21`, `AppearancePane.swift:24` |
| Deleting the active imported theme leaves `themeMode` pointing at a removed id | `ThemeRegistry.swift:121` |
| Background refresh replaces the snapshot that carried the daily report with one that has none, so the Cost/Tokens/Working-Time cards vanish while the user watches | `ClaudeProvider.swift:242` |
| `ObservationRenderSync.renderNow()` arms a fresh observation registration without tearing down the previous one, on every refresh tick and every dropdown open/close — the app slows progressively until relaunch | `ObservationRenderSync.swift:49,77` |
| Menu-bar image never repaints when macOS switches Light/Dark: the resolved scheme is not part of `LabelContent`, so the `content == lastContent` early-out suppresses it | `StatusItemLabelDriver.swift:224` |
| Restarting the background loop stacks concurrent probes of the same provider; the superseded probe still wins | `QuotaMonitor.swift:86` |
| A failed Share-pass overlay is bound to long-lived provider state, so it re-blocks the whole popup on every reopen until dismissed | `MenuContentView.swift:116` |
| Notch `hide()` leaves a stale panel-sized interactive rect, so it can reappear already expanded and swallow menu-bar clicks | `NotchWindowController.swift:111` |
| Notch hover is driven only by a *global* mouse monitor, so hover is dead whenever TouchQuota is frontmost | `NotchWindowController.swift:175` |
| Custom web card reloads its page on every SwiftUI update | `CustomWebCardView.swift:78` |
| Extension sections are merged in probe-completion order, so rows reshuffle on every refresh | `ExtensionProvider.swift:83` |
| Turning hooks OFF never clears the session state hooks created | `TouchQuotaApp.swift:252` |

## Confirmed — numbers that disagree with each other

| Finding | Location |
|---|---|
| Token card headline includes cache tokens; its delta and progress bar do not, so the percentage is against a base ~100× smaller and can point the opposite way | `DailyUsageCardView.swift:108,139` |
| Menu bar prints a frozen, meaningless "100%" for dollar-balance quotas that the popover renders as a dollar amount | `MenuBarPercentageDisplay.swift:16` |
| Notch and Touch Bar ignore the Used/Remaining display mode and contradict the menu bar for the same quota | `NotchRootView.swift:182`, `TouchBarBoard.swift:182` |
| Menu bar truncates the quota percentage while the Touch Bar rounds it, so the two read one point apart | `QuotaColumnView.swift:114` |
| "1 tasks" / "1 agents" — popover and notch never singularise counts the rest of the app does | `SessionIndicatorView.swift:42` |

## Confirmed — accessibility

Every one of these was found only by the journey sweep; the file-area sweep never
looked for them.

| Finding | Location |
|---|---|
| Every Settings switch is an unlabeled `Toggle` — VoiceOver announces "switch" with no name | `SettingsPaneChrome.swift:111` |
| The menu bar status item has no accessibility label, so VoiceOver cannot identify it | `StatusItemLabelDriver.swift:230` |
| Config text fields have no accessibility label; the visible caption is a detached `Text` | `BedrockConfigCard.swift:31` |
| The delete button for an imported theme is nested inside another Button's label — unreachable by keyboard and VoiceOver | `SettingsControls.swift:51` |
| The popover's scroll-wheel monitor is app-wide and rewrites scroll events belonging to the Settings window | `MenuContentView.swift:1465` |

## Confirmed — multiplicity, empty states, and dead code

| Finding | Location |
|---|---|
| The entire multi-account subsystem is unreachable: no provider conforms to `MultiAccountProvider`, and neither `AccountManagementCard` nor `AccountPickerView` is ever instantiated — a complete UI and a full repository implementation that nothing can reach | `AccountManagementCard.swift:9` |
| Bedrock with two regions lists each model twice and hands SwiftUI duplicate `ForEach` ids | `BedrockUsageProbe.swift:67` |
| The Menu Bar quota picker keys rows on `quotaKey`, which providers can emit twice | `MenuBarPane.swift:143` |
| The notch panel lists the three *oldest* sessions, so the session it is announcing can be missing from the list | `NotchWindowDriver.swift:155` |
| A provider whose snapshot carries no quotas renders a completely blank popover body | `MenuContentView.swift:431` |
| Settings search is a hand-written keyword index that has drifted from the panes ("Notch Live Activity" and "Touch Bar Board" are not indexed; 8 of 20 providers are named), and returns a blank sidebar with no "no results" | `SettingsSection.swift:36` |
| Extensions in a folder whose path contains a space or non-ASCII character are silently skipped — discovery compares a percent-encoded path against the filesystem | `ExtensionDirectoryScanner.swift:37` |
| Kiro ships enabled but `KiroIcon` is not in the asset catalog (only a loose `.svg` in the bundle root); DeepSeek has no icon asset at all; `"alibaba"` is in none of the five `ProviderVisualIdentityLookup` switches, so it renders as a purple question mark in three places | `ProviderVisualIdentity.swift:726,728,538+` |
| The Dashboard button does nothing for Antigravity and whenever no provider is selected | `MenuContentView.swift:795` |
| The collapsed notch's lanes are not symmetric around the reserved cutout, so part of the trailing lane is drawn behind the camera housing | `NotchRootView.swift:81` |
| Changing the theme never recolours Touch Bar session tiles — the diff compares tile values only | `SessionScrubberController.swift:63` |
| Claude card runs a blocking `/usr/bin/security` subprocess inside `body` on every render in API mode | `ClaudeConfigCard.swift:176` |
| "Snooze 30m" does nothing visible on the state users most want to dismiss, and silently arms a hidden snooze | `NotchWindowDriver.swift:173` |
| An imported theme whose name sanitizes to an empty string is stored as a hidden `.json` and lost on next launch | `ImportedThemeStore.swift:58` |
| Three popover cards paint from the legacy colour-scheme palette instead of the active theme | `Theme.swift:414` |
| Custom card URL is saved unvalidated; a schemeless URL yields a blank 200pt box and a dead "open in browser" button | `CustomCardURLField.swift:67` |

---

## The two questions that needed a device — both settled

### The Touch Bar session strip is unscrollable
`TouchBarBoardView.swift:92-130`

`sessionArea` is a bare `NSView`. Auto Layout can size a view only from a
constraint on that attribute, an intrinsic content size, or autoresizing
translation — and none applies here. Its children are pinned
leading/trailing/**centerY**; `centerY` is a position attribute, so a child's
height cannot propagate upward through it. (Compare `QuotaColumnView.swift:60-69`,
which pins top and bottom and therefore *does* enclose its content.) A bare
`NSView` returns `noIntrinsicMetric` on both axes. So the height resolves to 0.

`NSView.hitTest(_:)` returns nil "if that point lies completely outside the
view", independent of `clipsToBounds` — so the tiles draw correctly (macOS 14+
does not clip by default) while every touch on them is rejected at `sessionArea`.
Tiles past the 4th (compact) / 7th (wide) are unreachable.

**Fix:** `sessionArea.heightAnchor.constraint(equalToConstant: TouchBarMetrics.tileHeight)`.

### Theme import fails on every file
`ThemeImportView.swift:69` · `entitlements.plist`

The shipped Developer-ID build is not sandboxed —
`com.apple.security.app-sandbox` is absent from `entitlements.plist`, which is
what `Project.swift:82` and `scripts/sign-app.sh` use, and Homebrew is the
primary channel.

`startAccessingSecurityScopedResource()` consumes a sandbox extension token
carried on the URL. A non-sandboxed app has no sandbox to extend, so there is no
token and the call answers false. AppKit's own file panels historically
"auto-start" their URLs so callers never needed this, but SwiftUI's
cross-platform `.fileImporter` deliberately did not adopt that behaviour. The
guard therefore fails and `handleImport` shows "Cannot access file" — for every
file, every time.

The MAS build is worse: it is sandboxed but has no
`com.apple.security.files.user-selected.*` entitlement anywhere in the repo, so
the picker itself cannot return a usable URL.

**Fix:** don't gate on the result when the app is not sandboxed — call it, ignore
the return, and pair it with `stopAccessing` only if it succeeded.

---

## Corrections to the first round

Round 2's adjudication overturned two findings and narrowed three. They are
recorded here rather than deleted, because "we checked and it's fine" is worth as
much as a finding.

- **Overturned — Refresh/⌘R silently no-ops during a background probe.** It
  cannot: `WrappedActionButton` applies `.disabled(isLoading)`
  (`MenuContentView.swift:1401`) from the same `isSyncing` the guard tests, so
  the button is visibly a "Syncing" spinner and the shortcut is inert. The guard
  at `:932` is unreachable defensive code. *(A real issue was found next door:
  in overview mode `:802` disables Refresh whenever **any** enabled provider is
  syncing, so one slow provider blocks refreshing all the others.)*
- **Overturned — untrimmed MiniMax/Alibaba API keys always fail.** The keys are
  stored untrimmed, inconsistently with DeepSeek and Vercel which trim. But a
  single-line `SecureField` strips pasted newlines, trailing whitespace in an
  HTTP header value is stripped as OWS by conforming servers, and the same click
  surfaces "Failed: …" in the card — so the "Configured" badge never silently
  misleads. Worth a defensive one-liner, not a user-facing bug.
- **Narrowed — duplicate quota alert on every launch.** `previousStatuses` is
  in-memory and defaults to `.healthy`, so the first monitor-mediated refresh of
  an already-degraded provider does alert. But it is not "every launch": the
  alerting path is unreachable from the popover at all (see #1), so it needs
  background sync switched on or a provider config card touched. Low.
- **Narrowed — clearing Bedrock REGIONS permanently breaks the probe.** It
  persists `[]` and shadows the `?? ["us-east-1"]` default, but
  `BedrockUsageProbe.swift:48` guards the empty list and says "No AWS regions
  configured"; typing a region back into the same field fixes it immediately.
  Low.
- **Narrowed — the first-open popup is blank.** It is not blank: the gradient,
  the orbs and the ungated empty-state card render. What is missing is the
  header, the provider pills and the whole action bar, so the user's first-ever
  view is an "Unavailable" card floating with no chrome. It happens only when
  notification authorization is `.notDetermined` — the first open after install.
  The awaited permission prompt also gates the first probe, which is *why* the
  card says Unavailable. Low, and a one-line fix: move
  `withAnimation { animateIn = true }` above the permission request.

---

## Why the test suite could not catch any of this

`Project.swift:165-181` — the `AcceptanceTests` target depends on `Domain`,
`Infrastructure` and `Mockable`. It has **no dependency on the `TouchQuota` app
target**. All ~14,600 lines of `Sources/App` are unreachable from the acceptance
suite by construction, and that is where nearly every finding above lives.

Two consequences visible in the suite today:

1. **Two specs assert nothing.** `ThemesSpec.swift:37-50` asserts
   `claude.id == "claude"`; `UpdatesSpec.swift:29-43` asserts URL constants. Both
   explain why in their own doc comments: the types they mean to test are in the
   App layer.
2. **Six config specs prove persistence through a class the app never
   instantiates.** They drive `UserDefaultsProviderSettingsRepository`;
   production wires `JSONSettingsRepository.shared` (`TouchQuotaApp.swift:69`).
   So `copilot.manualUsageValue` / `manualUsageIsPercent` /
   `manualOverrideEnabled` have no round-trip coverage anywhere, while
   `CopilotConfigSpec` reads as though they do.

`NotificationsSpec` passing while notifications are entirely broken (#1) is the
sharpest illustration: it drives `monitor.refresh`, the one refresh path the UI
never takes.

**The fix that unlocks the rest:** add `.target(name: "TouchQuota")` to the
`AcceptanceTests` dependencies, or add an `AppTests` target. The drivers are
already written for it — they take injected `monitor` / `settings` /
`sessionMonitor` and expose imperative start/stop, so they can be driven
headlessly.

---

## Method and its limits

Round 1: 17 file-area traces, each finding put to two adversarial reviewers.
Round 2: 33 re-adjudications (66 reviewers), 12 journey sweeps with two
reviewers per finding, two documentation-backed investigations of the
device-dependent questions, and one cross-round critic over the non-Swift
surfaces. Round 2 ran 171 agents to completion with no failures.

A finding is listed as confirmed only where both reviewers independently agreed
it was real after reading the code themselves, or where it was verified by hand
against the source. The severe items in "The eight that matter most" were each
re-checked by hand on top of that.

What this method cannot do: prove that anything actually renders, that a gesture
lands, or that a timing-dependent sequence resolves the way the code reads. Every
finding here is a claim about the code, not an observation of the app.
