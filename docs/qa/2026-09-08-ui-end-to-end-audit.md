# End-to-end UI audit — 2026-09-08

## What this is, and what it is not

Every user-facing interaction in `Sources/App` was traced from the control the
user touches through to its effect and back to the view: 17 areas, covering the
menu-bar label, the popover, the Settings window and all its panes, all 13
provider config cards, settings persistence, themes, the Touch Bar board, the
notch, the refresh engine, sessions/hooks, the cards and share flow, and
notifications/updates.

**No build or run was possible.** The audit ran on Linux with no Swift
toolchain, no Xcode and no macOS, so nothing here was observed in a running app.
Every finding in section A was confirmed by reading the code that would prove or
disprove it. Section C lists the two findings that genuinely need a device.

Findings are graded by how firmly the code settles them:

- **A — Confirmed.** The code path was read end to end and no guard, default or
  alternate call site refutes it.
- **B — Consistent with the code, not independently re-verified.** Reported by
  the trace, the quoted code matches, but a second adversarial pass did not run.
- **C — Needs a device.** The mechanism is visible in the code but the outcome
  depends on runtime behaviour (Auto Layout, sandbox APIs).
- **D — Rejected or downgraded.**

---

## A. Confirmed

### A1. Quota notifications never fire on a default install
`Sources/App/Views/MenuContentView.swift:916,935` · `Sources/Domain/Monitor/QuotaMonitor.swift:99-113`

`alerter.alert` is reachable only from `QuotaMonitor.handleSnapshotUpdate`,
which only `refreshProvider` calls. But the popover refreshes providers
directly:

```swift
for provider in monitor.enabledProviders where !provider.isSyncing {
    group.addTask { try await provider.refresh() }   // bypasses QuotaMonitor
}
```

The only other path into `refreshProvider` is the background monitoring loop,
and `app.backgroundSyncEnabled` defaults to `false`
(`JSONSettingsRepository.swift:174`) → `RefreshInterval.off` → `restartMonitoring`
calls `monitor.stopMonitoring()` (`StatusItemLabelDriver.swift:531-537`).

So on a fresh install the app asks for notification permission on first open and
then can never post a quota alert. `NotificationsSpec` is green because it drives
`monitor.refresh` — the one path the UI does not use.

The popover path also never writes `previousStatuses`, so the change-detection
baseline drifts even once background sync is switched on.

**Fix:** route the popover's refresh through `monitor.refreshAll()` /
`monitor.refresh(providerId:)` instead of `provider.refresh()`.

### A2. The Touch Bar's "Needs you" state is cancelled a moment after it appears
`Sources/Domain/Session/SessionMonitor.swift:85` · `Sources/App/ClaudeBarApp.swift:240-243`

`updateUsage` treats a grown transcript as proof the session resumed:

```swift
if sessions[index].phase == .awaitingInput,
   usage.contextTokens > (sessions[index].usage?.contextTokens ?? 0) {
    sessions[index].resume()
}
```

The hook loop calls both, in this order, for every event:

```swift
await sessionMonitor.processEvent(event)          // sets .awaitingInput
await sessionUsageSync.sessionDidChange(event.sessionId)   // reads transcript → resume()
```

Claude Code appends the `tool_use` assistant record *before* it asks for
permission, so the very first read after blocking sees more context than the
last stored reading and immediately resumes. The tile loses its amber fill, its
"Needs you" line, its attention sort order and the tray dot colour — the one
thing the board exists for.

**Fix:** the baseline is wrong. Snapshot `contextTokens` at the moment
`awaitInput` is set and require growth beyond *that*, or require a token delta
larger than a single tool-use record.

### A3. Hook server bind failure is silent and permanent
`Sources/Infrastructure/Hooks/HookHTTPServer.swift:39-63`

The documented auto-assign fallback is dead code — `port = .any` is only reached
when `defaultPort == 0`, and the default is `HookConstants.defaultPort`. On
failure the handler logs and finishes the stream:

```swift
case .failed(let error):
    AppLog.hooks.error("Hook HTTP server failed: \(error.localizedDescription)")
    self.continuation?.finish()
```

Nothing retries and nothing reaches the UI. `start()` returns the stream before
the listener is up, so `startHookServer()` logs "Hook server started" either way.
The toggle stays ON, the dot stays green, `hook.enabled` is persisted — and no
session ever appears anywhere, forever. Also reachable by toggling OFF then
immediately ON: `stop()` only enqueues `listener.cancel()` while `start()` binds
straight away, so the rebind races the port release.

**Fix:** on `.posix(.EADDRINUSE)`, rebind with `NWEndpoint.Port.any` (the hook
script already reads the real port from the port file), and surface a failed
listener in the Hooks pane.

### A4. "Save & Test Connection" reports success without testing anything
`CopilotConfigCard.swift:595` · `MiniMaxConfigCard.swift:301` · `AlibabaConfigCard.swift:315`

All three do the same thing:

```swift
await monitor.refresh(providerId: "copilot")
if let error = monitor.provider(for: "copilot")?.lastError { ...Failed... }
else { copilotTestResult = "Success: Connection verified" }
```

`QuotaMonitor.refreshProvider` opens with `guard await provider.isAvailable() else { return }`.
With no credentials configured the probe never runs, `lastError` is never
written, and the card prints **"Success: Connection verified"**.

**Fix:** check availability explicitly, or have the test path call the probe
directly and report the availability failure.

### A5. The theme grid never refreshes after an import or delete
`Sources/App/Theme/ThemeRegistry.swift:21` · `AppearancePane.swift:24` · `SettingsControls.swift:52`

`ThemeRegistry` is a plain `final class`, not `@Observable`, and `AppearancePane`
iterates `ThemeRegistry.shared.allThemes`. The delete `x` calls
`removeImportedTheme(id:)` with no state change anywhere in the pane, so the tile
stays on screen. Import updates only `ThemeImportButton`'s own `@State`
(`importedThemeName`), which does not invalidate its sibling grid — the user
sees "Imported: Dracula" and no new tile.

**Fix:** make `ThemeRegistry` `@Observable`.

### A6. Deleting the selected imported theme strands `themeMode`
`Sources/App/Theme/ThemeRegistry.swift:121-127`

`removeImportedTheme` never touches `AppSettings.themeMode`, so it keeps
pointing at an id that no longer resolves.

**Fix:** reset `themeMode` to `"system"` when the removed id is the active one.

### A7. Turning the menu-bar readout off does not clear it
`Sources/App/StatusItemLabelDriver.swift:174,194-200`

```swift
let label = freshLabel ?? lastKnownLabel(whenFreshIsMissing: freshLabel)
```

`lastKnownLabel` exists to bridge a momentary data gap, and cannot tell that gap
apart from "the user switched the readout off". With both `menuBarPercentageEnabled`
and `menuBarDurationEnabled` off, `menuBarLabel` returns nil and the *previous*
number is redrawn — frozen in the menu bar until relaunch.

**Fix:** only fall back when a readout is actually configured.

### A8. Bedrock's AWS profile does not take effect until relaunch
`Sources/Infrastructure/Bedrock/BedrockUsageProbe.swift:19-21`

```swift
let profileName = settingsRepository.awsProfileName()
self.cloudWatchClient = AWSBedrockCloudWatchClient(profileName: profileName.isEmpty ? nil : profileName)
```

Read once, at construction, in `ClaudeBarApp.init()`. Editing the profile in
Settings persists it but the live client keeps the old one.

**Fix:** resolve the profile per probe call rather than in `init`.

### A9. Background refresh deletes the daily usage cards from the open popover
`Sources/Domain/Provider/Claude/ClaudeProvider.swift:242`

```swift
case .interactive: return await attachDailyReport(to: snapshot)
case .background:  return snapshot        // dailyUsageReport == nil
```

and the result is assigned straight over `snapshot`. A background tick therefore
replaces the snapshot that carried the report with one that does not, and the
Cost / Tokens / Working Time cards vanish while the user is looking at them. The
notch's "today" row goes blank permanently. The Refresh button cannot recover it
while `isSyncing` is true (see B4).

**Fix:** carry the previous `dailyUsageReport` forward on the background path.

### A10. `ObservationRenderSync.renderNow()` leaks an observation registration every call
`Sources/Domain/Monitor/ObservationRenderSync.swift:49-53,77-92`

`renderNow()` clears `lastRendered` and calls `sync()`, and `sync()` arms a fresh
`withObservationTracking` registration without tearing down the previous one.
`renderNow()` runs on every background refresh tick and on every dropdown
open/close. Registrations accumulate for the life of the process, so the
menu-bar label is recomputed once per accumulated registration per state change.
A long-running login-item app gets progressively slower until relaunch.

*(Confirmed by both adversarial lenses.)*

**Fix:** make `renderNow()` force a re-render without re-arming — the live
registration from the last change-driven `sync()` still catches real changes.

### A11. A Claude Code session killed without `SessionEnd` stays "Active" forever
`Sources/Domain/Session/SessionMonitor.swift:98`

`pruneStale` is documented "Call it on a timer" and nothing does. Its only
callers are `processEvent` (which needs a new event — exactly what a dead
session cannot send) and `TouchBarDriver.expireStaleSessions`, which is behind
`#if ENABLE_TOUCHBAR` and only runs while the board is open. Touch Bar and notch
both default to off, so on a default install the menu-bar glyph and the popover
card keep showing a session that no longer exists, with no control that clears it.

**Fix:** tick `pruneStale` from the app-lifetime loop, not from a feature that
defaults off.

### A12. The Claude API budget cannot be cleared
`Sources/App/Views/Settings/ClaudeConfigCard.swift:331`

```swift
.onChange(of: budgetInput) { _, newValue in
    if let value = Decimal(string: newValue) { settings.claudeApiBudget = value }
}
```

Emptying the field parses to nil, so nothing is written and the old threshold
stays in force behind an empty-looking field. Same for any invalid input.

**Fix:** treat empty as "clear the budget", and reject invalid input visibly.

### A13. The menu-bar image never repaints when macOS switches Light/Dark
`Sources/App/StatusItemLabelDriver.swift:236`

`resolvedTheme(for:)` samples `NSApp.effectiveAppearance` at draw time, but
nothing triggers a draw on an appearance change, and `LabelContent` does not
carry the appearance, so `render`'s `content == lastContent` early-out suppresses
the repaint even if one were requested. Under the default "System" theme the
label keeps the old palette. *(Confirmed by both lenses.)*

**Fix:** include the resolved scheme in `LabelContent` and observe
`AppleInterfaceThemeChangedNotification`.

### A14. "Claude Code Finished" quotes a different session's numbers
`Sources/App/ClaudeBarApp.swift:271`

```swift
let taskCount = sessionMonitor.recentSessions.first?.completedTaskCount ?? 0
let duration  = sessionMonitor.recentSessions.first?.durationDescription ?? ""
```

`recentSessions.first` is only the right session when this event actually
updated a tracked one. If ClaudeBar restarted while a session was running,
`processEvent` drops the unknown id and the notification reports an older
session's stats, or an empty duration ("Session ended after "). *(Confirmed by
both lenses.)*

**Fix:** look up `event.sessionId` and return if it is unknown.

### A15. The Alibaba provider has no visual identity
`Sources/App/Views/ProviderVisualIdentity.swift:538+`

`AlibabaProvider` is registered (`ClaudeBarApp.swift:122`) and has a config card
(`ProvidersPane.swift:239`), but `"alibaba"` appears in none of the five
`ProviderVisualIdentityLookup` switches. It hits every `default:` — purple
accent, `questionmark.circle.fill`, and asset name `"QuestionIcon"`, which is not
in the catalog. It renders as an unbranded question mark in the provider list,
the popover pill and the popover header.

Two further asset names are returned but missing from `Assets.xcassets`:
`KiroIcon` and `DeepSeekIcon`. Those degrade gracefully to SF Symbols.

**Fix:** add the `"alibaba"` cases and ship the three missing imagesets.

---

## B. Consistent with the code, not independently re-verified

| # | Finding | Location |
|---|---|---|
| B1 | First open shows a blank popup: `.task` awaits the notification-permission prompt before setting `animateIn`, and all content is `.opacity(animateIn ? 1 : 0)` | `MenuContentView.swift:132-142,275` |
| B2 | `previousStatuses` is in-memory and defaults to `.healthy`, so an already-critical provider fires a fresh alert on every launch | `QuotaMonitor.swift:100` |
| B3 | Picking a menu-bar provider whose data has not loaded blanks the readout permanently (stale quota key never re-normalized) | `MenuBarPane.swift:249` |
| B4 | Refresh / ⌘R silently no-ops while a background probe of the same provider is in flight — after it has already dropped the CLI lookup cache | `MenuContentView.swift:932` |
| B5 | A failed Share-pass leaves a modal overlay bound to long-lived provider state; it re-blocks the whole popup on every reopen until dismissed | `MenuContentView.swift:116` |
| B6 | Overview mode paints a green HEALTHY badge on providers that failed to probe | `MenuContentView.swift:488` |
| B7 | Dashboard button (⌘D) opens the wrong provider in overview mode, or nothing for providers with no dashboard URL | `MenuContentView.swift:795` |
| B8 | Clearing the Bedrock REGIONS field persists an empty array and permanently breaks the probe | `BedrockConfigCard.swift:69` |
| B9 | The Alibaba manual cookie can never be cleared — deleting the text leaves the old cookie stored | `AlibabaConfigCard.swift:163` |
| B10 | Custom card URL is saved with no validation; a schemeless URL yields a blank 200pt box and a dead "open in browser" button | `CustomCardURLField.swift:67`, `CustomWebCardView.swift:30` |
| B11 | Token card headline includes cache tokens; its delta and progress bar do not, so the percentage is against a base ~100× smaller | `DailyUsageCardView.swift:108,139` |
| B12 | Touch Bar quota numbers ignore the Used/Remaining display mode and always show percent-remaining, contradicting the menu bar | `TouchBarBoard.swift:182` |
| B13 | Notch `hide()` leaves a stale panel-sized interactive rect, so it can reappear already expanded and swallow menu-bar clicks | `NotchWindowController.swift:111` |
| B14 | Notch panel's session list is unsorted, so `prefix(3)` can drop the very session the notch is reporting | `NotchWindowDriver.swift:155` |
| B15 | Sync & Alerts displays the cadence the user picked while the loop polls up to 30× slower (API floor × battery multiplier) | `QuotaMonitor.swift:486` |
| B16 | `HookInstaller.InstallerError` does not conform to `LocalizedError`, so the actionable message is replaced by an opaque Cocoa error | `HookInstaller.swift:127`, `HooksPane.swift:80` |
| B17 | Hook requests are read with a single `receive()`; `isComplete` is ignored and the connection is cancelled immediately, so any payload not in the first segment is dropped (curl adds `Expect: 100-continue` above ~1KB) | `HookHTTPServer.swift:100` |
| B18 | "Hooks enabled but not installed" never self-heals — the reconcile is skipped by `if HookInstaller.isInstalled()`, the exact state that needs it, and the toggle is already ON | `ClaudeBarApp.swift:205` |
| B19 | `SparkleUpdater`'s computed passthroughs to Sparkle's KVO properties carry no Observation dependency, so "Check Now" can stay disabled and "Last checked" never updates | `SparkleUpdater.swift:76` |
| B20 | Imported theme whose name sanitizes to an empty string is stored as a hidden `.json` and lost on next launch | `ImportedThemeStore.swift:58` |
| B21 | Pill scroll-wheel monitor is app-wide and does not check the event's window, so it can hijack scrolling in the Settings window | `MenuContentView.swift:1465` |
| B22 | Settings search returns an empty, unexplained sidebar for settings that do exist | `SettingsSection.swift:36` |
| B23 | "Launch at Login" silently snaps back when `SMAppService` registration fails | `AppSettings.swift:239` |
| B24 | Collapsed notch lanes are not symmetric around the reserved cutout, so part of the trailing lane is drawn behind the camera housing | `NotchRootView.swift:81` |
| B25 | Changing the theme never recolours Touch Bar session tiles — the diff compares tile values only, so a palette-only change never reaches `configure` | `SessionScrubberController.swift:63` |
| B26 | Z.ai custom config path is used verbatim; a `~` path (the field's own placeholder) silently disables the provider | `ZaiConfigCard.swift:57` |
| B27 | Claude card runs a blocking `/usr/bin/security` subprocess inside `body` on every render in API mode | `ClaudeConfigCard.swift:176` |
| B28 | MiniMax/Alibaba API keys are stored untrimmed, so a pasted key with trailing whitespace reads as Configured but always fails | `MiniMaxConfigCard.swift:294` |
| B29 | Custom web card reloads the page on every SwiftUI update because `updateNSView` compares the configured URL against the committed URL | `CustomWebCardView.swift:77` |
| B30 | Three popover cards paint from the legacy colour-scheme palette instead of the active theme | `Theme.swift:414` |
| B31 | Provider chosen in the popup is not persisted; every relaunch snaps back to Claude | `QuotaMonitor.swift:48` |
| B32 | Notch hover is driven only by a *global* mouse monitor, so hover is dead whenever ClaudeBar is frontmost | `NotchWindowController.swift:175` |
| B33 | "Snooze 30m" does nothing visible on the state users most want to dismiss, and silently arms a hidden snooze | `NotchWindowDriver.swift:173` |

---

## C. Needs a device to settle

### C1. Touch Bar session strip may be untappable
`Sources/App/TouchBar/TouchBarBoardView.swift:92`

`sessionArea` is a bare `NSView` whose children are pinned leading/trailing/**centerY
only** — no top or bottom. The stack's `alignment = .centerY` supplies a centre,
not a height, and a bare `NSView` has no intrinsic content size, so nothing
determines `sessionArea`'s height and Auto Layout should resolve it to 0. Tiles
would still *draw* correctly (they are centred and macOS 14+ does not clip by
default) while `hitTest` rejects every touch outside the zero-height bounds,
making the scrubber unscrollable and every session past the 4th (compact) / 7th
(wide) unreachable.

This is the reasoning from the code; whether Auto Layout actually resolves it to
0 here needs one run on a Touch Bar Mac. **Cheap check:** add
`sessionArea.heightAnchor.constraint(equalToConstant: TouchBarMetrics.tileHeight)`
and see whether scrubbing starts working.

### C2. Theme import may fail on every file
`Sources/App/Settings/ThemeImportView.swift:69`

```swift
guard url.startAccessingSecurityScopedResource() else {
    importError = "Cannot access file"
    return
}
```

`entitlements.plist` has no `com.apple.security.app-sandbox`, so the app is not
sandboxed and the URL `fileImporter` vends is not security-scoped. Apple
documents this call as returning `false` for a non-security-scoped URL, which
would make theme import fail with "Cannot access file" every time. Reports of
actual behaviour on recent macOS vary, so this needs one run to settle.

---

## D. Rejected or downgraded

- **`ProvidersPane` negative progress-bar width** (`ProvidersPane.swift:98`) —
  reported as a crash. It is not: `geo.size.width * quota.percentRemaining / 100`
  does go negative for an over-quota provider, but SwiftUI clamps and logs. The
  real symptom is a "-12%" label and an unclamped bar above 100%. Downgraded to
  low.
- **`SparkleUpdater.isCheckingForUpdates` is dead** (`SparkleUpdater.swift:62`) —
  literally true (nothing ever writes it, all three consumers can only read
  `false`), but the adversarial pass judged the user-visible consequence to be
  cosmetic: the button simply never shows a spinner. Folded into B19, which is
  the finding that actually bites.

---

## The structural reason none of this was caught

`Project.swift:165-181` — the `AcceptanceTests` target depends on `Domain`,
`Infrastructure` and `Mockable`. It has **no dependency on the `ClaudeBar` app
target**. All ~14,600 lines of `Sources/App` — `AppSettings`, `ThemeRegistry`,
`StatusItemLabelDriver`, `TouchBarDriver`, `NotchWindowDriver`, `MenuContentView`,
every Settings pane and config card — are unreachable from the acceptance suite
by construction. Every finding above lives in that blind spot.

Two consequences visible in the suite today:

1. **Two specs assert nothing.** `ThemesSpec.swift:37-50` asserts
   `claude.id == "claude"`; `UpdatesSpec.swift:29-43` asserts URL constants. Both
   say why in their own doc comments: the types they mean to test are in the App
   layer.
2. **Six config specs prove persistence through a class the app never
   instantiates.** They drive `UserDefaultsProviderSettingsRepository`; production
   wires `JSONSettingsRepository.shared` (`ClaudeBarApp.swift:69`). So
   `copilot.manualUsageValue` / `manualUsageIsPercent` / `manualOverrideEnabled`
   have no round-trip coverage anywhere, while `CopilotConfigSpec` reads as
   though they do.

Several headline defects follow directly: `NotificationsSpec` passes because it
drives `monitor.refresh`, the one refresh path the UI never takes (A1).

**The fix that unlocks the rest:** add `.target(name: "ClaudeBar")` to the
`AcceptanceTests` dependencies (or add an `AppTests` target). The drivers are
already written for it — they take injected `monitor` / `settings` /
`sessionMonitor` and expose imperative start/stop, so they can be driven
headlessly.

---

## Method

17 areas traced in parallel, each finding then put to two adversarial reviewers —
one told to refute it, one told to build a concrete reproduction. The verify pass
was largely lost to capacity limits (14 of ~120 verdicts landed), so section A was
verified by hand instead: each claim's code path read end to end, looking for the
guard, default or call site that would refute it. Section B is what the traces
reported with matching code but no second pass.
