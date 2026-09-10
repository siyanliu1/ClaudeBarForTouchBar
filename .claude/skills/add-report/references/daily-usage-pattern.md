# Daily Usage Pattern — Reference Implementation

This documents the complete DailyUsage feature as a reference for new report cards.

## File Map

```
Sources/Domain/DailyUsage/
├── DailyUsageStat.swift          # Single day's data with formatting
├── DailyUsageReport.swift        # Today vs yesterday with deltas
└── DailyUsageAnalyzing.swift     # @Mockable protocol

Sources/Infrastructure/Claude/
├── SessionJSONLParser.swift      # Parses JSONL → TokenUsageRecord[]
├── ModelPricing.swift            # Token → cost calculation
└── ClaudeDailyUsageAnalyzer.swift # Implements DailyUsageAnalyzing

Sources/App/Views/
└── DailyUsageCardView.swift      # Card + DailyUsageMetric enum

Sources/Domain/Provider/
├── UsageSnapshot.swift           # Has dailyUsageReport: DailyUsageReport?
└── Claude/ClaudeProvider.swift   # Injects analyzer, calls attachDailyReport()

Sources/App/
├── Views/MenuContentView.swift   # Renders in statsGrid()
└── TouchQuotaApp.swift            # Wires ClaudeDailyUsageAnalyzer()

Tests/DomainTests/DailyUsage/
├── DailyUsageStatTests.swift     # 8 tests: formatting, isEmpty
└── DailyUsageReportTests.swift   # 15 tests: deltas, percentages, progress

Tests/InfrastructureTests/Claude/
├── SessionJSONLParserTests.swift        # 6 tests: parsing, edge cases
├── ModelPricingTests.swift              # 6 tests: rates, cost calc
└── ClaudeDailyUsageAnalyzerTests.swift  # 4 tests: date partitioning
```

## Data Flow

```
~/.claude/projects/*/*.jsonl
    ↓ (only files modified in last 2 days)
SessionJSONLParser.parse(fileURL:)
    ↓
[TokenUsageRecord] (model, inputTokens, outputTokens, cache*, timestamp)
    ↓
ClaudeDailyUsageAnalyzer.analyzeToday()
    ↓ partition by date, aggregate with ModelPricing.cost()
DailyUsageReport { today: DailyUsageStat, previous: DailyUsageStat }
    ↓
ClaudeProvider.attachDailyReport(to: snapshot)
    ↓
UsageSnapshot.dailyUsageReport
    ↓
MenuContentView.statsGrid() → DailyUsageCardView × 3
```

## Key Design Decisions

1. **Report on UsageSnapshot, not QuotaMonitor** — Reports are per-provider data,
   not global state. Each provider owns its report via its snapshot.

2. **Analyzer injected into Provider** — Protocol-based DI allows testing without
   real file I/O. The provider calls the analyzer in refresh() and attaches results.

3. **Performance: file modification date filter** — With 2000+ JSONL files, scanning
   all is too slow. Only files modified since the comparison period start are checked.

4. **Formatting in domain models** — Views read `formattedCost`, `formattedTokens` etc.
   directly. No formatting logic in views.

5. **Cards match existing style** — Uses `theme.cardGradient`, `theme.glassBorder`,
   `theme.cardCornerRadius`, animated progress bars with delay parameter.

6. **Three cards in 2+1 layout** — Cost and Tokens in a 2-column grid, Working Time
   full-width below. Each card shows: label, value, progress bar, delta comparison.
