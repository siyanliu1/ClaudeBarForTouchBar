import Foundation

/// Represents an active or recent Claude Code session.
/// Tracks session lifecycle, subagent activity, and task completion.
public struct ClaudeSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let cwd: String
    public let startedAt: Date
    public private(set) var phase: Phase
    public private(set) var activeSubagentCount: Int
    public private(set) var completedTaskCount: Int
    public private(set) var endedAt: Date?

    /// When the current turn stopped, if it has. Cleared when work resumes.
    /// Distinct from `endedAt`: a stopped session is still alive and will
    /// revive on the next `UserPromptSubmit`.
    public private(set) var stoppedAt: Date?

    /// What Claude Code is blocked on, when the session is `.awaitingInput`
    /// (e.g. "Claude needs your permission to use Bash"). Cleared when work resumes.
    public private(set) var pendingPrompt: String?

    /// The session's JSONL transcript, from the hook payload. Reading it is how
    /// token counts and the running tool are recovered.
    public let transcriptPath: String?

    /// When this session last produced any hook event. A session killed without
    /// a `SessionEnd` goes quiet here and nowhere else, so this is what says it
    /// is gone.
    public private(set) var lastEventAt: Date

    /// The last thing the user asked for, from `UserPromptSubmit`.
    public private(set) var lastPrompt: String?

    /// How Claude Code closed the last turn, from `Stop`.
    public private(set) var lastReply: String?

    /// What the transcript says about the current turn, once it has been read.
    public private(set) var usage: SessionUsage?

    public init(
        id: String,
        cwd: String,
        startedAt: Date = Date(),
        transcriptPath: String? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.startedAt = startedAt
        self.transcriptPath = transcriptPath
        self.lastEventAt = startedAt
        self.phase = .active
        self.activeSubagentCount = 0
        self.completedTaskCount = 0
    }

    /// The current phase of the session
    public enum Phase: String, Sendable, Equatable {
        case active
        case subagentsWorking
        /// Claude Code is blocked waiting on the user — typically a permission prompt.
        case awaitingInput
        case stopped
        case ended

        /// Human-readable label for this phase
        public var label: String {
            switch self {
            case .active: return "Active"
            case .subagentsWorking: return "Agents Working"
            case .awaitingInput: return "Needs You"
            case .stopped: return "Stopped"
            case .ended: return "Ended"
            }
        }
    }

    // MARK: - Mutations

    /// Records a subagent starting work. Subagent activity also revives a
    /// `.stopped` session: a new turn is clearly underway, so the indicator
    /// should reflect work rather than staying stuck on the previous turn's stop.
    public mutating func subagentStarted() {
        guard phase != .ended else { return }
        activeSubagentCount += 1
        updatePhase()
    }

    /// Records a subagent stopping work
    public mutating func subagentStopped() {
        guard phase != .ended else { return }
        activeSubagentCount = max(0, activeSubagentCount - 1)
        // Only a session that was showing its subagents re-derives its phase
        // here. A session blocked on the user still is when a subagent reports
        // back — recomputing would call it active and throw away the prompt
        // nobody has answered yet.
        guard phase == .subagentsWorking else { return }
        updatePhase()
    }

    /// Revives a stopped/idle session when a new turn begins (UserPromptSubmit).
    /// `Stop` fires at the end of every turn, so without this a session would be
    /// stuck `.stopped` for the rest of its life. No-op once ended.
    public mutating func resume(prompt: String? = nil) {
        guard phase != .ended else { return }
        if let prompt { lastPrompt = prompt }
        updatePhase()
    }

    /// Brings an ended session back, keeping the history it accumulated.
    ///
    /// `claude --resume` reports the same session id, so this is the same
    /// session continuing rather than a new one: its start time and task count
    /// are still true. `resume()` cannot do this — it refuses to touch an ended
    /// session, which is what makes it safe to call on every prompt.
    public mutating func revive(at date: Date = Date()) {
        endedAt = nil
        stoppedAt = nil
        pendingPrompt = nil
        activeSubagentCount = 0
        phase = .active
        lastEventAt = date
    }

    /// Records that Claude Code is blocked waiting on the user, carrying the
    /// prompt it is blocked on. No-op once ended.
    public mutating func awaitInput(_ prompt: String? = nil, at date: Date = Date()) {
        guard phase != .ended else { return }
        phase = .awaitingInput
        pendingPrompt = prompt
        stoppedAt = nil
    }

    /// Records a task completion
    public mutating func taskCompleted() {
        guard phase != .ended else { return }
        completedTaskCount += 1
    }

    /// Marks the session as stopped (Claude Code stopped responding)
    public mutating func stop(at date: Date = Date(), reply: String? = nil) {
        guard phase != .ended else { return }
        if let reply { lastReply = reply }
        phase = .stopped
        activeSubagentCount = 0
        stoppedAt = date
        pendingPrompt = nil
    }

    /// Marks the session as ended
    public mutating func end(at date: Date = Date()) {
        phase = .ended
        activeSubagentCount = 0
        endedAt = date
    }

    /// Records what the transcript reader found. Says nothing about the phase:
    /// reading a file is not activity, and a session that stopped mid-read must
    /// not be dragged back to working by its own token count arriving late.
    public mutating func updateUsage(_ usage: SessionUsage) {
        self.usage = usage
    }

    /// Records that the session is still alive, whatever the event was.
    public mutating func touch(at date: Date) {
        lastEventAt = date
    }

    /// When this session last finished doing something — the end of the session
    /// if it has ended, otherwise the end of the last turn. nil while working.
    ///
    /// The notch uses this to time the "done" flash; `endedAt` wins because a
    /// session that ended is finished for good, whereas a stop is provisional.
    public var finishedAt: Date? {
        endedAt ?? stoppedAt
    }

    /// The repository the session is running in — the last path component of
    /// `cwd`. This is how users refer to a session ("the claudebar one"), so it
    /// belongs here rather than being re-derived by each view.
    public var repoName: String {
        ((cwd as NSString).standardizingPath as NSString).lastPathComponent
    }

    /// Whether this session is still active (not ended)
    public var isActive: Bool {
        phase != .ended
    }

    /// Whether this session's transcript is worth re-reading: Claude Code is
    /// working, or is blocked on the user and about to be.
    ///
    /// A blocked session counts because nothing in the hook stream fires when a
    /// permission is granted — `PreToolUse` is deliberately not registered — so
    /// the transcript growing again is the only signal that the user answered.
    /// Stop reading it and the session would sit on "Needs you" at a frozen
    /// percentage for the rest of the turn.
    public var isBusy: Bool {
        phase == .active || phase == .subagentsWorking || phase == .awaitingInput
    }

    /// Duration of the session so far
    public var duration: TimeInterval {
        let end = endedAt ?? Date()
        return end.timeIntervalSince(startedAt)
    }

    /// Human-readable duration string
    public var durationDescription: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// How loudly this session is asking for the user, highest first. Used to
    /// pick the one session the menu bar can show, and to sort the Touch Bar.
    public var attentionRank: Int {
        switch phase {
        case .awaitingInput: return 4
        case .subagentsWorking: return 3
        case .active: return 2
        case .stopped: return 1
        case .ended: return 0
        }
    }

    /// What this session has to say, most interesting first. A display that can
    /// only show one line takes the first; one that rotates takes them in order.
    /// Empty when the session has produced no text of its own yet.
    public var tickerCandidates: [String] {
        var candidates: [String] = []
        if phase == .awaitingInput, let pendingPrompt {
            candidates.append("Needs you · \(pendingPrompt)")
        }
        if isWorking, let currentTool = usage?.currentTool {
            candidates.append(currentTool)
        }
        if let lastPrompt { candidates.append(lastPrompt) }
        if let lastReply { candidates.append(lastReply) }
        return candidates.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// How full the context window is, once a transcript has been read.
    public var contextPercent: Double? {
        usage?.contextPercent
    }

    /// One line describing the session. Falls back to the phase when the session
    /// has said nothing yet — a brand new session has no prompt and no reply.
    public var tickerText: String {
        tickerCandidates.first ?? phaseText
    }

    // MARK: - Private

    /// Whether a tool named in the transcript is plausibly still running. A
    /// stopped session's last tool finished with the turn.
    private var isWorking: Bool {
        phase == .active || phase == .subagentsWorking
    }

    private var phaseText: String {
        switch phase {
        case .stopped where completedTaskCount > 0:
            return "Turn finished · \(completedTaskCount) task\(completedTaskCount == 1 ? "" : "s")"
        case .stopped:
            return "Turn finished"
        case .ended:
            return "Ended · \(durationDescription)"
        default:
            return phase.label
        }
    }

    private mutating func updatePhase() {
        pendingPrompt = nil
        stoppedAt = nil
        if activeSubagentCount > 0 {
            phase = .subagentsWorking
        } else {
            phase = .active
        }
    }
}
