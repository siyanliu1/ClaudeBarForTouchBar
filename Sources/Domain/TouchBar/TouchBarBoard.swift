import Foundation

/// Everything the Touch Bar draws, worked out in one place.
///
/// The bar itself is a view: it lays out what this says and nothing more. Which
/// sessions appear, in what order, which quota goes in which cell and what the
/// tray item shows are all decisions, and decisions belong here where they can
/// be checked without a Touch Bar to look at.
public struct TouchBarBoard: Sendable, Equatable {
    /// One session's tile.
    public struct Tile: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let phase: ClaudeSession.Phase
        public let contextPercent: Double?

        /// What the second line can say, most interesting first. Never empty —
        /// a session with nothing of its own to say falls back to its phase.
        public let candidates: [String]

        /// Whether this session is blocked on the user.
        public let isAttention: Bool

        /// Whether the tile's text should move. A finished session's text is
        /// history; scrolling it implies something is still happening.
        public let isAnimated: Bool

        /// The line to show when only one line fits.
        public var text: String { candidates.first ?? "" }

        public init(
            id: String,
            name: String,
            phase: ClaudeSession.Phase,
            contextPercent: Double?,
            candidates: [String],
            isAttention: Bool,
            isAnimated: Bool
        ) {
            self.id = id
            self.name = name
            self.phase = phase
            self.contextPercent = contextPercent
            self.candidates = candidates
            self.isAttention = isAttention
            self.isAnimated = isAnimated
        }
    }

    /// One quota number. A window the provider did not report is not an error —
    /// it renders as a dash — so both parts are absent together.
    public struct QuotaCell: Sendable, Equatable {
        public let percent: Double?

        public var status: QuotaStatus? {
            percent.map(QuotaStatus.from(percentRemaining:))
        }

        public static let missing = QuotaCell(percent: nil)

        public init(percent: Double?) {
            self.percent = percent
        }
    }

    /// The item in the Control Strip, all the board is when it is collapsed.
    public struct Tray: Sendable, Equatable {
        /// Colours the dot. `nil` with no sessions, when the dot follows the
        /// number's own status instead.
        public let phase: ClaudeSession.Phase?
        public let quota: QuotaCell

        public init(phase: ClaudeSession.Phase?, quota: QuotaCell) {
            self.phase = phase
            self.quota = quota
        }
    }

    public let tiles: [Tile]
    /// Claude's 5h, 7d and Fable windows, in that order.
    public let claude: [QuotaCell]
    /// Codex's 5h and 7d windows, in that order.
    public let codex: [QuotaCell]
    public let tray: Tray
    public let isRefreshing: Bool
    /// What to say instead of tiles when there are none.
    public let emptyMessage: String?

    /// How long a finished session stays on the board.
    public static let endedRetention: TimeInterval = 600

    static let claudeQuotaKeys = ["session", "weekly", "model:fable"]
    static let codexQuotaKeys = ["session", "weekly"]

    public init(
        tiles: [Tile],
        claude: [QuotaCell],
        codex: [QuotaCell],
        tray: Tray,
        isRefreshing: Bool,
        emptyMessage: String?
    ) {
        self.tiles = tiles
        self.claude = claude
        self.codex = codex
        self.tray = tray
        self.isRefreshing = isRefreshing
        self.emptyMessage = emptyMessage
    }

    /// Builds the board from monitor state.
    ///
    /// - Parameters:
    ///   - sessions: Every tracked session, in any order.
    ///   - snapshot: Looks up a provider's latest snapshot by id.
    ///   - traySelection: The provider and quota the tray item's number follows —
    ///     the same choice the menu bar label already uses.
    ///   - hooksEnabled: Whether session tracking is switched on at all, which
    ///     decides which of the two empty states applies.
    ///   - isRefreshing: Whether a quota refresh is in flight, so the numbers can
    ///     dim rather than jump.
    ///   - now: Reference time, so a finished session expires deterministically.
    public static func build(
        sessions: [ClaudeSession],
        snapshot: (String) -> UsageSnapshot?,
        traySelection: (providerId: String, quotaKey: String),
        hooksEnabled: Bool,
        isRefreshing: Bool,
        now: Date
    ) -> TouchBarBoard {
        let tiles = sessions
            .filter { isWorthShowing($0, now: now) }
            // Loudest first, and newest among equals. The key is the phase and
            // the start time, never the text, so a tile does not jump around
            // while its own second line changes.
            .sorted { lhs, rhs in
                lhs.attentionRank != rhs.attentionRank
                    ? lhs.attentionRank > rhs.attentionRank
                    : lhs.startedAt > rhs.startedAt
            }
            .map(Tile.init(session:))

        let claudeSnapshot = snapshot("claude")
        let codexSnapshot = snapshot("codex")

        return TouchBarBoard(
            tiles: tiles,
            claude: claudeQuotaKeys.map { cell(in: claudeSnapshot, forKey: $0) },
            codex: codexQuotaKeys.map { cell(in: codexSnapshot, forKey: $0) },
            tray: Tray(
                // The dot follows the tile the user would see first, so the
                // collapsed bar and the open one never disagree.
                phase: tiles.first?.phase,
                quota: cell(in: snapshot(traySelection.providerId), forKey: traySelection.quotaKey)
            ),
            isRefreshing: isRefreshing,
            emptyMessage: tiles.isEmpty ? emptyMessage(hooksEnabled: hooksEnabled) : nil
        )
    }

    // MARK: - Private

    private static func isWorthShowing(_ session: ClaudeSession, now: Date) -> Bool {
        guard let endedAt = session.endedAt else { return true }
        return now.timeIntervalSince(endedAt) < endedRetention
    }

    private static func cell(in snapshot: UsageSnapshot?, forKey key: String) -> QuotaCell {
        guard let quota = snapshot?.quota(forKey: key) else { return .missing }
        return QuotaCell(percent: quota.percentRemaining)
    }

    private static func emptyMessage(hooksEnabled: Bool) -> String {
        hooksEnabled
            ? "No sessions · appears when Claude Code starts"
            : "Enable Hooks in Settings"
    }
}

private extension TouchBarBoard.Tile {
    init(session: ClaudeSession) {
        let candidates = session.tickerCandidates.isEmpty
            ? [session.tickerText]
            : session.tickerCandidates
        self.init(
            id: session.id,
            name: session.repoName,
            phase: session.phase,
            contextPercent: session.contextPercent,
            candidates: candidates,
            isAttention: session.phase == .awaitingInput,
            isAnimated: session.phase == .active
                || session.phase == .subagentsWorking
                || session.phase == .awaitingInput
        )
    }
}
