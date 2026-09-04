import Foundation
import Observation

/// Monitors Claude Code sessions by processing hook events.
/// Single source of truth for session state, similar to QuotaMonitor for providers.
/// Isolated to @MainActor since it's consumed by SwiftUI views.
@MainActor
@Observable
public final class SessionMonitor {
    /// Every session being tracked, in the order they were first seen. Ended
    /// sessions stay until they are pruned, so this is the whole board.
    ///
    /// Several Claude Code sessions run at once — two terminals in the same
    /// directory is normal — and each is tracked separately. Views that can only
    /// show one read `activeSession`.
    public private(set) var sessions: [ClaudeSession] = []

    /// Maximum number of ended sessions to keep
    private let maxRecentSessions: Int

    public init(maxRecentSessions: Int = 10) {
        self.maxRecentSessions = maxRecentSessions
    }

    // MARK: - Event Processing

    /// Processes a session event and updates state accordingly.
    ///
    /// Events are routed by session id. An event naming a session that was never
    /// started is dropped: ClaudeBar may well have launched mid-session, and
    /// inventing a session from a `Stop` would show one with no start time.
    public func processEvent(_ event: SessionEvent) {
        // Liveness is recorded before staleness is judged. An event is proof its
        // session is alive, and pruning first would let a session that had been
        // quiet overnight be retired by the very event breaking the silence —
        // and then dropped, because the routing below would no longer find it.
        if let index = sessions.firstIndex(where: { $0.id == event.sessionId }) {
            sessions[index].touch(at: event.receivedAt)
        }

        // Sessions used to be cleaned up by the next SessionStart ending the
        // previous one. Now that they coexist, something has to retire the ones
        // that died without a SessionEnd, and an arriving event is the only tick
        // this type has of its own.
        pruneStale()

        if event.eventName == .sessionStart {
            handleSessionStart(event)
            return
        }

        guard let index = sessions.firstIndex(where: { $0.id == event.sessionId }) else { return }

        switch event.eventName {
        case .sessionStart:
            break
        case .sessionEnd:
            sessions[index].end(at: event.receivedAt)
            trimEndedSessions()
        case .taskCompleted:
            sessions[index].taskCompleted()
        case .subagentStart:
            sessions[index].subagentStarted()
        case .subagentStop:
            sessions[index].subagentStopped()
        case .stop:
            sessions[index].stop(at: event.receivedAt, reply: event.lastAssistantMessage)
        case .userPromptSubmit:
            sessions[index].resume(prompt: event.userPrompt)
        case .notification:
            guard event.blocksOnUser else { return }
            sessions[index].awaitInput(event.message, at: event.receivedAt)
        }
    }

    /// Records what the transcript reader found for one session. Unknown ids are
    /// dropped: a session that ended while its transcript was being read is gone.
    public func updateUsage(sessionId: String, usage: SessionUsage) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        // Granting a permission fires no hook — PreToolUse is deliberately not
        // registered — so a session that was blocked would stay blocked in the
        // UI until the turn ended. The transcript growing is the answer: more
        // context than last time means Claude is working again.
        if sessions[index].phase == .awaitingInput,
           usage.contextTokens > (sessions[index].usage?.contextTokens ?? 0) {
            sessions[index].resume()
        }

        sessions[index].updateUsage(usage)
    }

    /// Drops sessions that are no longer worth showing, and ends the ones that
    /// went quiet without saying goodbye.
    ///
    /// A Claude Code killed with the window sends no `SessionEnd`, so without
    /// this its session would sit "active" forever. Call it on a timer.
    public func pruneStale(
        now: Date = Date(),
        endedRetention: TimeInterval = 600,
        idleTimeout: TimeInterval = 43_200
    ) {
        for index in sessions.indices where sessions[index].isActive {
            guard now.timeIntervalSince(sessions[index].lastEventAt) >= idleTimeout else { continue }
            // Ended now, not when it last spoke. Backdating would put the
            // session past its retention the instant it was retired, so it
            // would vanish rather than spend its ten minutes on the board like
            // any other session that just finished.
            sessions[index].end(at: now)
        }

        sessions.removeAll { session in
            guard let endedAt = session.endedAt else { return false }
            return now.timeIntervalSince(endedAt) >= endedRetention
        }
    }

    // MARK: - Queries

    /// Sessions that are still running
    public var activeSessions: [ClaudeSession] {
        sessions.filter(\.isActive)
    }

    /// The one running session a single-slot view should show: the one asking
    /// hardest for the user, and the newest of those if several ask equally.
    public var activeSession: ClaudeSession? {
        activeSessions.max { lhs, rhs in
            (lhs.attentionRank, lhs.startedAt) < (rhs.attentionRank, rhs.startedAt)
        }
    }

    /// Sessions that have ended, most recently ended first
    public var recentSessions: [ClaudeSession] {
        sessions
            .filter { !$0.isActive }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    /// Whether there's an active Claude Code session
    public var hasActiveSession: Bool {
        !activeSessions.isEmpty
    }

    // MARK: - Private

    private func handleSessionStart(_ event: SessionEvent) {
        // A resumed session reports the same id. Reviving the one already tracked
        // keeps its task count and start time instead of showing it twice.
        if let index = sessions.firstIndex(where: { $0.id == event.sessionId }) {
            sessions[index].touch(at: event.receivedAt)
            // `resume` is a no-op once a session has ended, so an ended one has
            // to be revived explicitly — otherwise `claude --resume` would
            // reach a record that ignores every event for the rest of its life,
            // since the id already exists and no new session is appended.
            sessions[index].revive(at: event.receivedAt)
            return
        }

        sessions.append(ClaudeSession(
            id: event.sessionId,
            cwd: event.cwd,
            startedAt: event.receivedAt,
            transcriptPath: event.transcriptPath
        ))
    }

    private func trimEndedSessions() {
        let keep = Set(recentSessions.prefix(maxRecentSessions).map(\.id))
        sessions.removeAll { !$0.isActive && !keep.contains($0.id) }
    }
}
