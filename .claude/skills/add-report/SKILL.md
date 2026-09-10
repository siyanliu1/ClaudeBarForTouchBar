---
name: add-report
description: >
  Guide for adding new report cards to TouchQuota that analyze local data sources and display
  metrics with comparison deltas. Use this skill when:
  (1) Adding a new report/analytics card (e.g., weekly summary, model breakdown, session stats)
  (2) Creating data analysis features that read local files and display aggregated metrics
  (3) Adding comparison cards that show "today vs previous" style deltas
  (4) Building any feature that follows the DailyUsage pattern (parse → aggregate → report → card)
---

# Add Report Card to TouchQuota

Add new report cards that analyze local data sources, compute metrics with comparison deltas,
and display them in the existing card UI style using TDD.

## When to Use

This skill covers adding **report-style features** — cards that:
- Read and parse local data files (JSONL, JSON, CSV, etc.)
- Aggregate metrics (cost, tokens, time, counts)
- Compare periods (today vs yesterday, this week vs last week)
- Display results in glassmorphism cards matching the existing UI

## Architecture Pattern

Every report feature follows this data flow:

```
Data Source → Parser → Analyzer → Report Model → UsageSnapshot → Card View
```

Mapped to the codebase layers:

| Layer | Location | What to Create |
|-------|----------|----------------|
| **Domain** | `Sources/Domain/{Feature}/` | Rich models + `@Mockable` protocol |
| **Infrastructure** | `Sources/Infrastructure/{Provider}/` | Parser + Analyzer implementation |
| **App** | `Sources/App/Views/` | Card view(s) |
| **Integration** | Provider class + `statsGrid` | Wire analyzer → snapshot → UI |

> **Reference implementation:** See `references/daily-usage-pattern.md` for the complete
> DailyUsage feature as a working example of this pattern.

## Workflow

```
Phase 0: Architecture Design (get user approval)
    ↓
Phase 1: Domain Models + Tests (TDD Red→Green)
    ↓
Phase 2: Infrastructure Parser + Analyzer + Tests
    ↓
Phase 3: Card View + Integration
    ↓
Phase 4: Verify all tests pass
```

---

## Phase 0: Architecture Design (MANDATORY)

Before writing code, design the feature and get user approval.

### Step 1: Define the Report

Answer these questions:
- **What data source?** (JSONL sessions, API response, local DB, etc.)
- **What metrics?** (cost, tokens, time, counts, etc.)
- **What comparison period?** (today vs yesterday, this week vs last, etc.)
- **Which provider?** (Claude, Codex, or generic across all?)
- **How many cards?** (one per metric, or a single combined card?)

### Step 2: Create Architecture Diagram

```
Example: Adding a weekly cost breakdown report

┌─────────────────────────────────────────────────────────┐
│  Data Source        Infrastructure          Domain       │
│                                                          │
│  ~/.claude/    →  WeeklyParser        →  WeeklyStat     │
│  projects/        (reads JSONL)          (per-day cost) │
│  *.jsonl                                                 │
│                    WeeklyAnalyzer     →  WeeklyReport   │
│                    (aggregates by        (this week vs  │
│                     week, implements      last week)    │
│                     protocol)                            │
│                          ↓                    ↓          │
│                    Provider.refresh()  → UsageSnapshot   │
│                                          .weeklyReport   │
│                          ↓                               │
│                    statsGrid() → WeeklyCardView          │
└─────────────────────────────────────────────────────────┘
```

### Step 3: Document Components

| Component | Purpose | Inputs | Outputs |
|-----------|---------|--------|---------|
| `{Name}Stat` | Single period's data | Raw aggregated values | Formatted strings, isEmpty |
| `{Name}Report` | Period comparison | Two Stats | Deltas, percentages, progress |
| `{Name}Analyzing` | Protocol | Date/config | Report |
| `{Name}Analyzer` | Implementation | File paths | Report |
| `{Name}CardView` | UI card | Report + metric | Glassmorphism card |

### Step 4: Get User Approval

Use `AskUserQuestion` to confirm the design before proceeding.

---

## Phase 1: Domain Models (TDD)

### 1a. Create the Stat Model

The stat model represents **one period's aggregated data** with rich formatting behavior.

**Location:** `Sources/Domain/{Feature}/{Name}Stat.swift`

**Pattern to follow:**
```swift
import Foundation

public struct {Name}Stat: Sendable, Equatable {
    public let date: Date
    // Add your metrics here
    public let metricA: Decimal
    public let metricB: Int

    // Formatting — encapsulate in the model, not the view
    public var formattedMetricA: String { /* currency, compact number, duration, etc. */ }
    public var formattedMetricB: String { /* ... */ }

    public var isEmpty: Bool { /* all zeros check */ }
    public static func empty(for date: Date) -> Self { /* zero-valued instance */ }
}
```

**Key rules:**
- Use `Decimal` for monetary values (not Double — floating point errors)
- Use `TimeInterval` for durations
- Use `Locale(identifier: "en_US")` for currency formatting (not `en_US_POSIX` which adds a space)
- All formatting lives in the model — views just read formatted strings
- `isEmpty` uses `&&` (all zeros = empty), not `||`

### 1b. Create the Report Model

The report model **compares two periods** and computes deltas.

**Location:** `Sources/Domain/{Feature}/{Name}Report.swift`

**Pattern to follow:**
```swift
public struct {Name}Report: Sendable, Equatable {
    public let current: {Name}Stat   // e.g., today, this week
    public let previous: {Name}Stat  // e.g., yesterday, last week

    // Delta calculations
    public var metricADelta: Decimal { current.metricA - previous.metricA }
    public var metricAChangePercent: Double? {
        guard previous.metricA > 0 else { return nil }  // nil when previous is zero
        // ...
    }

    // Formatted deltas with sign: "+$5.00", "-1.2M"
    public var formattedMetricADelta: String { /* ... */ }

    // Progress for bar display (0-1 ratio of current vs total)
    public var metricAProgress: Double {
        let total = /* current + previous */
        guard total > 0 else { return 0 }
        return current / total
    }
}
```

**Key rules:**
- Change percent returns `nil` when previous is zero (avoid division by zero)
- Formatted deltas always include sign (`+` or `-`)
- Progress is `current / (current + previous)`, clamped to 0-1
- Use `abs()` for formatted values, prepend sign separately

### 1c. Create the Protocol

**Location:** `Sources/Domain/{Feature}/{Name}Analyzing.swift`

```swift
import Mockable

@Mockable
public protocol {Name}Analyzing: Sendable {
    func analyze() async throws -> {Name}Report
}
```

### 1d. Write Tests First

**Location:** `Tests/DomainTests/{Feature}/`

Create two test files following Chicago School TDD (test state, not interactions):

- `{Name}StatTests.swift` — Test formatting, isEmpty, edge cases
- `{Name}ReportTests.swift` — Test deltas, percentages, nil cases, progress

```swift
import Foundation
import Testing
@testable import Domain

@Suite
struct {Name}StatTests {
    @Test func `formats metric as expected`() {
        let stat = {Name}Stat(date: Date(), metricA: 14.26, ...)
        #expect(stat.formattedMetricA == "$14.26")
    }
    // ...
}
```

After writing tests → implement the models → run tests → all green.

---

## Phase 2: Infrastructure (TDD)

### 2a. Create the Parser (if reading files)

If the report reads local files (JSONL, JSON, CSV), create a parser.

**Location:** `Sources/Infrastructure/{Provider}/{Name}Parser.swift`

**Pattern:** Parser is a struct (not protocol) since it's a pure data transformation.

```swift
struct {Name}Parser {
    func parse(fileURL: URL) throws -> [{Name}Record] { /* ... */ }
    func parse(content: String) -> [{Name}Record] { /* for testing */ }
}
```

### 2b. Create the Analyzer

**Location:** `Sources/Infrastructure/{Provider}/{Provider}{Name}Analyzer.swift`

The analyzer implements the domain protocol and orchestrates:
1. Find relevant files (filter by modification date for performance)
2. Parse files into records
3. Partition records by time period
4. Aggregate into stat models
5. Return report

**Performance rule:** Only scan files modified within the relevant time window.
With 2000+ JSONL files, scanning all of them is too slow.

```swift
public struct {Provider}{Name}Analyzer: {Name}Analyzing, Sendable {
    public func analyze() async throws -> {Name}Report {
        let files = findRecentFiles(since: periodStart)  // Performance!
        // parse → partition → aggregate → return
    }
}
```

### 2c. Write Infrastructure Tests

**Location:** `Tests/InfrastructureTests/{Provider}/`

- Parser tests: valid input, missing fields, malformed data, timestamps
- Analyzer tests: use temp directories with JSONL content, test date partitioning

---

## Phase 3: Card View + Integration

### 3a. Create the Card View

**Location:** `Sources/App/Views/{Name}CardView.swift`

The card must match the existing glassmorphism style. Use `WrappedStatCard` as the reference:

```swift
struct {Name}CardView: View {
    let metric: {Name}Metric  // enum for each displayable metric
    let report: {Name}Report
    let delay: Double          // for cascading entrance animation

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 1. Header: icon + LABEL (uppercased)
            // 2. Large value (e.g., "$14.26" or "19.5M")
            // 3. Progress bar (animated)
            // 4. Delta comparison line (e.g., "Vs Mar 10 -$27.47 (4.9%)")
        }
        .padding(12)
        .background(/* theme.cardGradient + theme.glassBorder stroke */)
        .scaleEffect(isHovering ? 1.015 : 1.0)
        .onHover { isHovering = $0 }
    }
}
```

**Card styling checklist:**
- `.padding(12)` on the VStack
- `theme.cardGradient` fill + `theme.glassBorder` stroke (1pt)
- `theme.cardCornerRadius` for corners
- `theme.fontDesign` on all text
- `theme.textPrimary` / `theme.textSecondary` / `theme.textTertiary` for text hierarchy
- `theme.progressTrack` for bar background
- Hover scale effect (1.015)
- Animated progress bar with `delay` parameter

### 3b. Add to UsageSnapshot

Add an optional field for the report:

```swift
// In Sources/Domain/Provider/UsageSnapshot.swift
public let {name}Report: {Name}Report?
// Add to init with default nil
```

### 3c. Wire into Provider

Inject the analyzer into the provider that owns this data:

```swift
// In the provider's init:
private let {name}Analyzer: (any {Name}Analyzing)?

// In refresh():
snapshot = await attach{Name}Report(to: newSnapshot)

// Helper method:
private func attach{Name}Report(to snapshot: UsageSnapshot) async -> UsageSnapshot {
    guard let analyzer = {name}Analyzer,
          let report = try? await analyzer.analyze(),
          !report.current.isEmpty else { return snapshot }
    return UsageSnapshot(/* copy all fields, add report */)
}
```

### 3d. Render in statsGrid

Add to `MenuContentView.statsGrid(snapshot:)`:

```swift
if let report = snapshot.{name}Report {
    let baseDelay = Double(snapshot.quotas.count + 1) * 0.08
    // Render card(s) in LazyVGrid or standalone
}
```

### 3e. Register in TouchQuotaApp

Pass the analyzer when creating the provider:

```swift
{Provider}Provider(
    probe: ...,
    settingsRepository: settingsRepository,
    {name}Analyzer: {Provider}{Name}Analyzer()
)
```

---

## Phase 4: Verify

1. `tuist generate`
2. Run all tests: `xcodebuild test -scheme TouchQuota-Workspace ...`
3. Build the app and verify the cards appear
4. Check logs for analyzer output

---

## Checklist

### Phase 0: Architecture
- [ ] Define data source, metrics, comparison period, provider
- [ ] Create architecture diagram
- [ ] Get user approval

### Phase 1: Domain (TDD)
- [ ] Write `{Name}StatTests` (formatting, isEmpty, edge cases)
- [ ] Implement `{Name}Stat` — make tests green
- [ ] Write `{Name}ReportTests` (deltas, percentages, progress)
- [ ] Implement `{Name}Report` — make tests green
- [ ] Create `{Name}Analyzing` protocol with `@Mockable`

### Phase 2: Infrastructure (TDD)
- [ ] Write parser tests (valid input, missing fields, malformed data)
- [ ] Implement parser — make tests green
- [ ] Write analyzer tests (temp dirs, date partitioning)
- [ ] Implement analyzer with file modification date filtering
- [ ] Run all infrastructure tests green

### Phase 3: Integration
- [ ] Create `{Name}CardView` matching glassmorphism style
- [ ] Add `{name}Report` field to `UsageSnapshot`
- [ ] Wire analyzer into provider's `refresh()` via `attach{Name}Report`
- [ ] Render cards in `statsGrid`
- [ ] Register analyzer in `TouchQuotaApp`

### Phase 4: Verify
- [ ] `tuist generate` succeeds
- [ ] All tests pass
- [ ] App builds and cards render correctly
- [ ] Logs show analyzer activity
