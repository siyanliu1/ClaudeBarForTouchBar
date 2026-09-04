import Foundation

/// Represents a hook event received from Claude Code.
/// These events map directly to Claude Code's hook system events.
public struct SessionEvent: Sendable, Equatable, Codable {
    /// The session ID from Claude Code
    public let sessionId: String

    /// The type of hook event
    public let eventName: EventName

    /// The working directory where Claude Code is running
    public let cwd: String

    /// When this event was received
    public let receivedAt: Date

    /// Free-text payload carried by the event, when the hook provides one.
    /// `Notification` uses it for what Claude Code is blocked on
    /// (e.g. "Claude needs your permission to use Bash").
    public let message: String?

    /// The session's JSONL transcript, carried by every Claude Code hook payload.
    /// Reading it is how live token and tool information is recovered.
    public let transcriptPath: String?

    /// What the user asked for, from `UserPromptSubmit`.
    public let userPrompt: String?

    /// Claude Code's closing message for the turn, from `Stop`.
    public let lastAssistantMessage: String?

    /// Why `Notification` fired (e.g. `agent_needs_input`, `idle_prompt`).
    /// Only some of these mean the user is actually blocking progress; see
    /// `blocksOnUser`.
    public let notificationType: String?

    public init(
        sessionId: String,
        eventName: EventName,
        cwd: String,
        receivedAt: Date = Date(),
        message: String? = nil,
        transcriptPath: String? = nil,
        userPrompt: String? = nil,
        lastAssistantMessage: String? = nil,
        notificationType: String? = nil
    ) {
        self.sessionId = sessionId
        self.eventName = eventName
        self.cwd = cwd
        self.receivedAt = receivedAt
        self.message = message
        self.transcriptPath = transcriptPath
        self.userPrompt = userPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.notificationType = notificationType
    }

    /// Whether this notification means Claude Code has stopped and is waiting on
    /// the user, rather than just telling them something.
    ///
    /// Claude Code sends `Notification` for plenty of things that need no answer
    /// — going idle, finishing a login, an MCP elicitation echo. Treating those
    /// as "Needs you" would leave the indicator permanently stuck, so only the
    /// types that block a turn count. A payload with no type at all is treated as
    /// blocking: older Claude Code versions omit the field, and the permission
    /// prompt is what that hook was added for.
    public var blocksOnUser: Bool {
        guard eventName == .notification else { return false }
        guard let notificationType else { return true }
        return Self.blockingNotificationTypes.contains(notificationType)
    }

    /// Notification types that stop a turn until the user answers. Taken from the
    /// Claude Code 2.1.223 binary; unknown types are ignored rather than guessed at.
    static let blockingNotificationTypes: Set<String> = [
        "permission_prompt",
        "worker_permission_prompt",
        "agent_needs_input",
        // An MCP server's elicitation blocks the turn exactly as a permission
        // prompt does; in the binary all three come from the same helper.
        "elicitation_dialog",
        "elicitation_url_dialog",
    ]

    /// Whether this event originates from ClaudeBar's own background quota probe.
    ///
    /// ClaudeBar refreshes quotas by spawning `claude /usage` in
    /// `<AppSupport>/ClaudeBar/Probe`. Claude Code fires SessionStart/SessionEnd
    /// hooks for that run, which loop back into ClaudeBar's own hook server. These
    /// events must be ignored so routine background polling doesn't pollute the
    /// recent-sessions list or fire "Claude Code Finished: Probe" notifications.
    /// (issue #172)
    public var isClaudeBarProbe: Bool {
        let components = ((cwd as NSString).standardizingPath as NSString).pathComponents
        return Array(components.suffix(2)) == ["ClaudeBar", "Probe"]
    }

    /// The types of hook events from Claude Code
    public enum EventName: String, Sendable, Equatable, Codable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case taskCompleted = "TaskCompleted"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case stop = "Stop"
        /// Fires at the start of every turn (before Claude processes the prompt).
        /// Used to revive a session out of `.stopped` so the indicator tracks
        /// real activity instead of sticking on the end-of-turn `Stop`.
        case userPromptSubmit = "UserPromptSubmit"
        /// Fires when Claude Code needs the user — most importantly a
        /// permission prompt. The session is blocked until it is answered.
        case notification = "Notification"
    }
}
