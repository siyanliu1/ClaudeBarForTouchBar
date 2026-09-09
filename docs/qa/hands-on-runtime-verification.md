# Hands-on runtime verification

The companion to [ui-end-to-end-audit.md](ui-end-to-end-audit.md), which said of
itself: *"No build or run was possible… everything here is a claim about the
code, not an observation of the app."*

This one is the opposite. Everything below was observed on the target hardware:
a MacBookPro16,2 (13-inch 2020, physical Touch Bar) running macOS 26.6.2
(25G83), with Xcode 26.5 (17F42) and tuist 4.207.0.

`xcode-select` still points at `/Library/Developer/CommandLineTools`, so every
build and test command needs `DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer`
exported first. Switching it properly needs `sudo xcode-select -s`.

---

## Build and test baseline

**First successful compile of the Touch Bar stack.** `ClaudeBarApp.swift`,
`GeneralPane.swift` and `StatusItemLabelDriver.swift` — the three files the
implementation session listed as "nothing has compiled" — build clean.
`ENABLE_TOUCHBAR` and `ENABLE_SPARKLE` are both set for Debug and Release.

**Full suite green: 2200 tests, 0 failures, 0 skips.**

| Bundle | Tests | Suites |
|---|---:|---:|
| AcceptanceTests | 71 | 52 |
| DomainTests | 854 | 55 |
| InfrastructureTests | 1275 | 101 |

One test failed on the first run and was fixed. See below.

**Confirmed — `Sources/App` is untestable by construction.** `Project.swift:165-181`
gives `AcceptanceTests` dependencies on `Domain`, `Infrastructure` and `Mockable`
only, and all three test targets are `product: .unitTests` with no host
application. The audit's claim holds exactly as written.

### The one failing test — and why it was the test, not the app

`JSONSettingsStoreTests.swift:298` · `write refuses to replace a settings file that is not valid JSON`

The fixture was a JSON object with a trailing comma, on the premise that this
"is enough to fail parsing". **It is not, on this OS.** Verified directly:

```
JSONSerialization.jsonObject(with: "{\n \"app\": { … },\n}")  →  PARSED OK
JSONSerialization.jsonObject(with: "{ not json")              →  FAILED
```

So the file was never corrupt, the store parsed it, and the write correctly went
through — the assertion that the file must be unchanged then failed. The
behaviour the test means to pin down is real and is covered by its two siblings
(`write leaves a malformed file alone rather than replacing it`,
`isUnreadable distinguishes a corrupt file from a missing one`), both of which
pass and both of which use genuinely unparseable input.

Fixed by making the fixture genuinely invalid (an unbalanced brace) and
correcting `JSONSettingsStore.swift`'s doc comment, which repeated the same
wrong claim about trailing commas.

---

## The Touch Bar — the part that had never run

Every item here is new information. The Touch Bar panel sleeps after ~75 s of
HID inactivity and reads as an all-black capture; `screencapture -b -x out.png`
grabs it at 2008 × 60 px (= 1004 × 30 pt) once awake, and needs no permission.

### The Control Strip tray item works from a real bundle

The open question from the design spike — `DFRElementSetControlStripPresenceForIdentifier`
returned false from an unbundled executable, and community notes said tray items
need a real `.app` — **is settled: it appears.** Captured in the Control Strip
between the `‹` chevron and the play button: a rounded ClaudeBar button with a
status dot and the Claude number (a `–` here, because the Claude probe fails on
this machine — see below).

`[INFO] [touchBar] Touch Bar tray item registered` on every launch, and the
button is really there.

### Both layouts present, and the geometry is exact

Measured from the captures by finding lit pixel runs at the mid-row:

| | measured | `TouchBarMetrics` |
|---|---|---|
| Compact — board origin | 64.0 pt | 64 pt system close box |
| Compact — toggle | 32.0 pt | `toggleButtonWidth = 32` |
| Compact — tiles | 4 × 104.0 pt | `tileWidth = 104`, `visibleTileCount = 4` |
| Compact — tile pitch | 110.0 pt | 104 + `tileGap = 6` |
| Wide — own close button | 40.0 pt at inset 6.0 pt | `closeButtonWidth = 40`, `edgeInset = 6` |
| Wide — toggle | 32.0 pt at 52.0 pt | 6 + 40 + 6 |
| Wide — tiles | 6 × 104.0 pt from 90.0 pt | 52 + 32 + 6 |

Not one constant is off. The compact board keeps the system close box and the
Control Strip; the wide board draws its own ✕ and the Control Strip is gone,
exactly as `drawsOwnCloseButton` and `placement` intend.

### What else was seen working

- **The compact/wide toggle**, and `app.touchBarLayout` persisting to
  `settings.json` the instant it is tapped — with the Settings window's own
  Board Width control showing the new value.
- **The quota column is tappable.** A tap fired a refresh of exactly
  `claude` + `codex` (`onRefreshRequested` → `monitor.refresh(providerIds:)`),
  and the column dimmed while syncing.
- **Tiles render correctly**: the `awaitingInput` session sorted first with an
  amber bar and "Needs you · Claud…", the stopped session showing its last
  assistant message ("Done. Tests pass."), context percentages correct against a
  200 k window (20 k → 10 %, 120 k → 60 %).
- **The empty state**: "No sessions · appears when Claude Code starts".
- **Finding #4's fix, end to end.** A session was given a
  `Notification`/`permission_prompt` *and* a transcript that grew afterwards —
  the exact sequence that used to cancel the state — and it still reads
  "Needs you", still sorted first.

### Correction — "The Touch Bar session strip is unscrollable" is wrong

The audit settled this one by documentation, concluding that `sessionArea` is a
bare `NSView` whose height "resolves to 0" because its children are pinned with
`centerY`, so every touch on a tile is rejected by `hitTest`.

Reproduced with the identical constraint set (horizontal `NSStackView`,
`alignment: .centerY`, bare `NSView` with leading/trailing/centerY children, one
26 pt height constraint on the scrubber) on this OS:

```
sessionArea.frame             = (44.0, 0.0, 440.0, 30.0)
sessionArea.hasAmbiguousLayout = false
hitTest at the tile strip     -> NSClipView
scrubber reachable by hit-test: true
  hitTest y=8.0  -> NSClipView
  hitTest y=15.0 -> NSClipView
  hitTest y=22.0 -> NSClipView
```

`sessionArea` gets the **full 30 pt**, the layout is unambiguous, and hit-testing
reaches the scrubber across the whole tile band. The recommended fix —
`sessionArea.heightAnchor.constraint(equalToConstant: tileHeight)` — would have
*shrunk* the touch target from 30 pt to 26 pt.

**Still open:** whether a swipe actually scrolls the strip to tiles 5+ in compact
mode. It was not observed scrolling during the hardware session, but it is not
established that a swipe was attempted. Wide mode shows 6 tiles at once, so the
question only bites in compact.

---

## Hooks — the branch's fixes, against the running server

### Oversized bodies (#5) — fixed, but the stated mechanism was wrong

All three paths were driven at the live server and all three parsed:

| Path | Result |
|---|---|
| Forced `Expect: 100-continue`, 4 KB body | server answers `HTTP/1.1 100 Continue`, then `200`; event parsed |
| Headers, then body 300 ms later (raw socket) | `200`; event parsed |
| Body dribbled 500 B at a time | `200`; event parsed |

**Correction:** curl 8.7.1 on macOS does **not** send `Expect: 100-continue` for
the `-d @-` form the installed hook uses — it buffers stdin and sends
`Content-Length`. A trace shows it writing the 137-byte header block and the
body as *separate* writes, which is what broke the old single `receive()`. The
bug was real and the fix is right; it was TCP segmentation, not 100-continue.

### Port fallback (#6) — fixed

With port 19847 held by another process:

```
[ERROR]   Hook HTTP server failed: … (Network.NWError error 48 - Address already in use)
[WARNING] Port 19847 unavailable; retrying on an OS-assigned port
[INFO]    Hook HTTP server listening on port 62995
```

62995 was written to `~/.claude/claudebar-hook-port` and a POST to it was
accepted — so the installed hook script, which reads that file, follows.

### The installer, exercised through the Settings toggle

Against a real `~/.claude/settings.json` with 10 pre-existing top-level keys
(including the user's `statusLine`):

- **Install** — all 10 keys preserved byte-identical; all 8 events registered
  (`SessionStart`, `SessionEnd`, `TaskCompleted`, `SubagentStart`,
  `SubagentStop`, `Stop`, `UserPromptSubmit`, `Notification`); matcher-based
  format correct.
- **Uninstall** — the file comes back **byte-identical to the pre-test backup**.
- Toggling off stops the server and removes the port file.

### A real Claude Code session

With the hooks installed by the app, a genuine `claude -p` run drove
`SessionStart` → `UserPromptSubmit` → `SessionEnd` into the app under its real
session UUID. The whole chain — Claude Code → installed shell function → curl →
`HookHTTPServer` → `SessionMonitor` — works on this machine.

---

## Settings store

**Corrupt file (#8) — the no-clobber half works.** With a genuinely unparseable
`settings.json`, a full app lifecycle left the file byte-for-byte identical.

**What that costs the user, though, is worth naming.** In that state every read
falls back to defaults, so the app launches with no hook server, no Touch Bar
board and no background sync — silently. Nothing warns at startup; the
`Refusing to write settings…` error is only emitted when something *attempts a
write*, which on a defaults-only launch may never happen. The user sees an app
that has forgotten everything and says nothing.

---

## Probes

**Codex works.** `plan type: plus`, Session 100 %, Weekly 100 %, in ~2 s.

**Claude fails on this machine — and ClaudeBar's diagnosis is correct.** The
CLI's OAuth session has expired (`claude -p` reports "OAuth session expired and
could not be refreshed"). `/usage` therefore renders with a header of
`Opus 5 (1M context) · API Usage Billing` and shows the Session cost panel
instead of quota bars, while `~/.claude.json` still records
`billingType: stripe_subscription` and `organizationType: claude_max`. The #271
guard sees exactly that mismatch and refuses the `/cost` fallback:

```
[ERROR] Claude /usage rendered the API billing cost panel for a
        stripe_subscription account — not falling back to /cost
```

That is the guard doing its job. The remedy is `claude login`, which is what the
app's own message says. The Touch Bar's `Claude –/–/–` is the honest rendering
of it.

Two genuine defects were found alongside it:

**The folder-trust self-heal is unreachable on a timeout.** On a fresh install
the probe directory is untrusted, so `claude` sits on the trust prompt. The
recovery — `catch ProbeError.folderTrustRequired` → `writeClaudeTrust` → retry —
is reachable only when the run *returns output that parses*. Two of the observed
runs instead ended in `RunError.timedOut` after the full 20 s, where the recovery
never runs and nothing is written; a later run happened to return the screen and
recovered. `InteractiveRunner.run` throws `.timedOut` when the captured buffer is
empty or not valid UTF-8, so the failure mode is a first-launch race, not a
permanent block — but it costs 20 s per probe until it wins.

**The raw TUI dump goes into the user-facing log at INFO.**
`ClaudeUsageProbe.swift:95` writes the entire ANSI screen —
`\[2G\[1mAccessing\[12Gworkspace:` and several thousand more bytes — to
`~/Library/Logs/ClaudeBar/ClaudeBar.log` on **every** probe. Measured at ~7 KB
per probe, which rotates the 5 MB log in roughly five days at the default 10-minute
interval, and makes the log unreadable in the meantime. The same content is
already logged two lines later at `.debug`, which is OSLog-only. The `.info` call
should be `.debug`.

---

## Diagnostics and logging

**The documented OSLog predicate matches nothing.** `AppLogger.swift:99` uses
`Bundle.main.bundleIdentifier`, which is `com.tddworks.claudebar` — lowercase.
`CLAUDE.md` and `AppLogger`'s own doc comment both tell you to filter on
`subsystem == "com.tddworks.ClaudeBar"`, and the fallback string in the code is
the same wrong spelling. Every documented `log show` / `log stream` / Console.app
filter in the repo returns nothing.

```bash
# what the docs say (returns nothing)
log show --predicate 'subsystem == "com.tddworks.ClaudeBar"' --info --debug --last 1h
# what actually works
log show --predicate 'subsystem == "com.tddworks.claudebar"' --info --debug --last 1h
```

**Unit tests write into the user's real log file.** Running the suite fills
`~/Library/Logs/ClaudeBar/ClaudeBar.log` with fixture output — "Claude Code
v1.0.27", "Organization: Acme Corp", "Failed to send alert: … (test error 1.)".
The file is a user-facing artefact reachable from Settings → Open Logs Folder.

**Cosmetic:** `Background refresh starting (interval: 600s, providers:
claude,claude,claude,codex)`. `backgroundRefreshProviderIds`
(`StatusItemLabelDriver.swift:540`) appends without de-duplicating. Harmless —
`QuotaMonitor.refresh(providerIds:)` de-dupes at `:167` and only one probe of
each runs — but the log line is alarming and wrong.

**Cosmetic:** `Hook HTTP server stopped` is logged twice on a single toggle-off.

---

## Accessibility, confirmed live

Read straight out of the accessibility tree of the running Settings window:
every switch is an `AXCheckBox/AXToggle` **with no title**. The audit found this
by reading `SettingsPaneChrome.swift:111`; it is exactly as described, and
VoiceOver has nothing to announce but "switch".

---

## Popover, notch and theme import

A second pass, driven through the app's own UI.

### Finding the menu bar item is harder than it should be

`MenuBarExtra`'s label is deliberately `Color.clear.frame(width: 1, height: 1)`
(`ClaudeBarApp.swift:314`) — every menu-bar pixel is drawn by
`StatusItemLabelDriver` into `statusItem.button.image`. The item does work: it
renders the configured provider's number (a green `100%` for Codex).

But on this 13-inch display it is **collapsed into macOS 26's menu-bar overflow**,
behind the `‹` chevron, and is invisible until that is expanded. It took a
quit/relaunch pixel diff and an expanded-overflow capture to establish that it
existed at all — `attach` succeeded, so none of the driver's three diagnostics
(`Status item has no button`, `Attached … via the watchdog`, `No drawable status
item found`) ever fired. A first-time user on a crowded menu bar could
reasonably conclude the app had not launched.

### The popover

**Confirmed — the first open has no chrome.** The audit's narrowed finding
reproduces exactly. First open after launch: the gradient plus a floating
"Claude Unavailable" card, with no header, no provider pills and no action bar.
Every subsequent open renders the lot — header with an amber `UNAVAILABLE`
badge, the pill row (Claude / Codex / Gemini / Antigravity / +), the body, and
the action bar (Dashboard, Refresh, gear, ✕).

**Opening the dropdown does drive a refresh** — the button reads "Syncing…" and
the providers repopulate, which is the path fix `43d3a39` re-routed through the
monitor.

**Confirmed — and broader than reported: overview mode paints green HEALTHY over
errors.** With Overview Mode on, five providers each show a green `HEALTHY` pill
immediately above their own error row:

| Provider | Badge | Row directly beneath it |
|---|---|---|
| Claude | HEALTHY | ⚠ The Claude CLI did not see this account's subscription — its… |
| Gemini | HEALTHY | ⚠ Authentication required. Please log in. |
| Antigravity | HEALTHY | ⚠ Command did not complete within the timeout. |
| Z.ai | HEALTHY | ⚠ Authentication required. Please log in. |
| Amp | HEALTHY | ⚠ CLI not found: AmpCode |

Only Codex is genuinely healthy, and it is the only one of the six that renders
actual quota cards (Session 100 % / Weekly 100 %, with reset countdowns). The
audit called this one row; it is in fact every provider that fails.

**New — the actionable instruction is truncated.** The Claude error is surfaced
to the user, which is right, but the card clips it mid-command:
`…its usage screen showed API billing only. Run \`claude lo…`. The one thing the
message exists to tell the user is the part that gets cut.

### The notch

It renders on a Mac with no physical cutout, as a virtual pill drawn over the
menu bar, and both of its states work:

- **Session state** — amber ⚠ `Needs you` in the leading lane and the hook's
  message in the trailing lane (`Claude needs your…mission to use Bash`,
  middle-truncated).
- **Quota state** — collapsed as `5h 100%` with a green bar; a click expands it
  to a `Usage` panel with `5h` and `7d` rows and two buttons.
- **`Snooze 30m` works** — the panel dismisses on click. (The audit's complaint
  was about the session state specifically, which was not re-tested here.)

**Observed once: the notch window swallowed a menu-bar click.** A click aimed at
ClaudeBar's own status item landed on the notch panel instead and expanded it.
The notch window is 900 × 420 pt pinned at `y = 0`, so it covers the middle of
the menu bar; this is the concrete instance of the interactive-rect concern the
audit raised at `NotchWindowController.swift:111`.

### Theme import — the audit's other device question, also wrong

The audit concluded, from documentation, that
`startAccessingSecurityScopedResource()` must return false in a non-sandboxed
app and that import therefore **"fails on every file, every time"** with
"Cannot access file".

It does not. Driven through the real `.fileImporter` panel with a complete
`.itermcolors` file:

- the guard passed, the theme imported, and `QAFull` appeared as a sixth theme
  card **immediately**;
- it persisted to `~/.claudebar/themes/qafull.json`;
- selecting it applied the palette live across the Settings window and wrote
  `themeMode = imported-qafull`.

Two further claims fall with it:

- **"The Appearance grid never refreshes after an import or delete"** — it
  refreshed on both.
- **"Deleting the active imported theme leaves `themeMode` pointing at a removed
  id"** — deleting it while active repointed `themeMode` to `system`, removed
  the file, and re-rendered the window. Clean fallback.

**Real defect found instead: parser errors are unreadable.** An `.itermcolors`
file missing `Ansi 8`–`Ansi 15` surfaced as:

```
Import failed: The operation couldn't be completed.
(Infrastructure.ITermColorsParserError error 0.)
```

`ITermColorsParserError` is not `LocalizedError`, so
`missingColor("Ansi 8 Color")` — which names the exact key at fault — is thrown
away and replaced with a case index. (The index is not even the right one for
the case that threw, which shows how little it means.) Same defect class as the
audit's `HookInstaller.InstallerError` finding.

### Retracted — the Keychain error was a test artefact

An earlier draft of this report listed:

```
[ERROR] [credentials] Keychain read of 'Claude Code-credentials' failed:
        security exited 44 — SecKeychainSearchCreateFromAttributes …
```

It only occurs when the app is launched with `nohup` from a shell, which gives it
no proper security session and therefore no login keychain in its search list.
Relaunched through LaunchServices (`open -a`), the error does not appear at all.
The exact command the app runs — `security find-generic-password -s "Claude
Code-credentials" -w` — succeeds from a normal session. **Not a defect.**

---

## Method, and two deviations worth disclosing

Observation channels: `screencapture -b` for the Touch Bar (no permission
needed), the file log, OSLog at the *correct* subsystem, `~/.claudebar/settings.json`,
`lsof`, curl against the live hook server, synthetic transcript JSONL, and the
accessibility tree of the Settings window.

1. **The app was first launched from inside a Claude Code shell**, which leaked
   `ANTHROPIC_BASE_URL` and `CLAUDE_CODE_CHILD_SESSION` into it and made the
   `/usage` reading suspect. Every probe result reported above was re-taken with
   a scrubbed environment (verified: zero `CLAUDE*`/`ANTHROPIC*` variables in the
   process environment). The conclusion did not change.
2. **`LSUIElement` was temporarily flipped to `false`** in the `/Applications`
   copy so that macOS would expose the app for UI automation — an `LSUIElement`
   app is not enumerable as a controllable application. It was restored to `true`
   and the bundle re-signed afterwards. Only the Settings-window checks used that
   build; every Touch Bar, hook and probe result above was taken with
   `LSUIElement` true.

Left unverified: Sparkle updates, the multi-account subsystem, Bedrock, and the
remaining cosmetic findings in the audit's tables. The Touch Bar swipe-to-scroll
question is still open.

Of the audit's **two** device-dependent questions — the ones it said it had
settled from documentation — **both turned out to be wrong** when run: the Touch
Bar session strip is hit-testable, and theme import works. Three further claims
in its tables (grid never refreshes, dangling `themeMode`, and the stated
mechanism of the >1 KB hook bug) were also wrong. Its claims that *were*
confirmed on hardware were confirmed exactly.
