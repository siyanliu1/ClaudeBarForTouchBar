import Testing
import Foundation
@testable import Domain

@Suite
@MainActor
struct SessionMonitorTests {
    private func makeEvent(
        sessionId: String = "test-session",
        eventName: SessionEvent.EventName,
        cwd: String = "/tmp/project",
        receivedAt: Date = Date(),
        message: String? = nil
    ) -> SessionEvent {
        SessionEvent(
            sessionId: sessionId,
            eventName: eventName,
            cwd: cwd,
            receivedAt: receivedAt,
            message: message
        )
    }

    // MARK: - Session Lifecycle

    @Test
    func `starts with no active session`() {
        let monitor = SessionMonitor()

        #expect(monitor.activeSession == nil)
        #expect(monitor.hasActiveSession == false)
        #expect(monitor.recentSessions.isEmpty)
    }

    @Test
    func `SessionStart creates active session`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .sessionStart))

        #expect(monitor.activeSession != nil)
        #expect(monitor.activeSession?.id == "test-session")
        #expect(monitor.activeSession?.cwd == "/tmp/project")
        #expect(monitor.activeSession?.phase == .active)
        #expect(monitor.hasActiveSession == true)
    }

    @Test
    func `SessionEnd moves session to recent and clears active`() {
        let monitor = SessionMonitor()
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(60)

        monitor.processEvent(makeEvent(eventName: .sessionStart, receivedAt: startDate))
        monitor.processEvent(makeEvent(eventName: .sessionEnd, receivedAt: endDate))

        #expect(monitor.activeSession == nil)
        #expect(monitor.hasActiveSession == false)
        #expect(monitor.recentSessions.count == 1)
        #expect(monitor.recentSessions.first?.id == "test-session")
        #expect(monitor.recentSessions.first?.phase == .ended)
    }

    @Test
    func `SessionEnd for different session ID is ignored`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(sessionId: "session-1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "session-2", eventName: .sessionEnd))

        #expect(monitor.activeSession?.id == "session-1")
        #expect(monitor.recentSessions.isEmpty)
    }

    @Test
    func `a second SessionStart runs alongside the first`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(sessionId: "session-1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "session-2", eventName: .sessionStart))

        #expect(monitor.activeSessions.count == 2)
        #expect(monitor.recentSessions.isEmpty)
    }

    // MARK: - Task Tracking

    @Test
    func `TaskCompleted increments task count`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .sessionStart))
        monitor.processEvent(makeEvent(eventName: .taskCompleted))
        monitor.processEvent(makeEvent(eventName: .taskCompleted))

        #expect(monitor.activeSession?.completedTaskCount == 2)
    }

    @Test
    func `TaskCompleted for wrong session ID is ignored`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(sessionId: "session-1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "other", eventName: .taskCompleted))

        #expect(monitor.activeSession?.completedTaskCount == 0)
    }

    @Test
    func `TaskCompleted without active session is ignored`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .taskCompleted))

        #expect(monitor.activeSession == nil)
    }

    // MARK: - Subagent Tracking

    @Test
    func `SubagentStart changes phase to subagentsWorking`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .sessionStart))
        monitor.processEvent(makeEvent(eventName: .subagentStart))

        #expect(monitor.activeSession?.phase == .subagentsWorking)
        #expect(monitor.activeSession?.activeSubagentCount == 1)
    }

    @Test
    func `SubagentStop returns to active when no subagents remain`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .sessionStart))
        monitor.processEvent(makeEvent(eventName: .subagentStart))
        monitor.processEvent(makeEvent(eventName: .subagentStop))

        #expect(monitor.activeSession?.phase == .active)
        #expect(monitor.activeSession?.activeSubagentCount == 0)
    }

    @Test
    func `multiple subagents tracked correctly`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .sessionStart))
        monitor.processEvent(makeEvent(eventName: .subagentStart))
        monitor.processEvent(makeEvent(eventName: .subagentStart))
        monitor.processEvent(makeEvent(eventName: .subagentStart))
        monitor.processEvent(makeEvent(eventName: .subagentStop))

        #expect(monitor.activeSession?.activeSubagentCount == 2)
        #expect(monitor.activeSession?.phase == .subagentsWorking)
    }

    // MARK: - Stop

    @Test
    func `Stop sets phase to stopped`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .sessionStart))
        monitor.processEvent(makeEvent(eventName: .subagentStart))
        monitor.processEvent(makeEvent(eventName: .stop))

        #expect(monitor.activeSession?.phase == .stopped)
        #expect(monitor.activeSession?.activeSubagentCount == 0)
    }

    @Test
    func `Stop for wrong session is ignored`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(sessionId: "session-1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "other", eventName: .stop))

        #expect(monitor.activeSession?.phase == .active)
    }

    @Test
    func `UserPromptSubmit revives a stopped session to active`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(eventName: .sessionStart))
        monitor.processEvent(makeEvent(eventName: .stop))
        monitor.processEvent(makeEvent(eventName: .userPromptSubmit))

        #expect(monitor.activeSession?.phase == .active)
    }

    @Test
    func `UserPromptSubmit for wrong session is ignored`() {
        let monitor = SessionMonitor()

        monitor.processEvent(makeEvent(sessionId: "session-1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "session-1", eventName: .stop))
        monitor.processEvent(makeEvent(sessionId: "other", eventName: .userPromptSubmit))

        #expect(monitor.activeSession?.phase == .stopped)
    }

    // MARK: - Recent Sessions

    @Test
    func `recent sessions are ordered most recent first`() {
        let monitor = SessionMonitor()
        let now = Date()

        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart, receivedAt: now))
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionEnd, receivedAt: now.addingTimeInterval(10)))

        monitor.processEvent(makeEvent(sessionId: "s2", eventName: .sessionStart, receivedAt: now.addingTimeInterval(20)))
        monitor.processEvent(makeEvent(sessionId: "s2", eventName: .sessionEnd, receivedAt: now.addingTimeInterval(30)))

        #expect(monitor.recentSessions.count == 2)
        #expect(monitor.recentSessions[0].id == "s2")
        #expect(monitor.recentSessions[1].id == "s1")
    }

    @Test
    func `recent sessions are capped at max`() {
        let monitor = SessionMonitor(maxRecentSessions: 3)
        let now = Date()

        for i in 1...5 {
            let time = now.addingTimeInterval(Double(i * 10))
            monitor.processEvent(makeEvent(sessionId: "s\(i)", eventName: .sessionStart, receivedAt: time))
            monitor.processEvent(makeEvent(sessionId: "s\(i)", eventName: .sessionEnd, receivedAt: time.addingTimeInterval(5)))
        }

        #expect(monitor.recentSessions.count == 3)
        #expect(monitor.recentSessions[0].id == "s5")
        #expect(monitor.recentSessions[1].id == "s4")
        #expect(monitor.recentSessions[2].id == "s3")
    }

    // MARK: - Complex Scenarios

    @Test
    func `full session lifecycle with tasks and subagents`() {
        let monitor = SessionMonitor()

        // Start session
        monitor.processEvent(makeEvent(eventName: .sessionStart))
        #expect(monitor.activeSession?.phase == .active)

        // Work with subagents
        monitor.processEvent(makeEvent(eventName: .subagentStart))
        #expect(monitor.activeSession?.phase == .subagentsWorking)

        // Task completed while subagent running
        monitor.processEvent(makeEvent(eventName: .taskCompleted))
        #expect(monitor.activeSession?.completedTaskCount == 1)

        // Subagent finishes
        monitor.processEvent(makeEvent(eventName: .subagentStop))
        #expect(monitor.activeSession?.phase == .active)

        // More tasks
        monitor.processEvent(makeEvent(eventName: .taskCompleted))
        #expect(monitor.activeSession?.completedTaskCount == 2)

        // Session ends
        monitor.processEvent(makeEvent(eventName: .sessionEnd))
        #expect(monitor.activeSession == nil)
        #expect(monitor.recentSessions.count == 1)
        #expect(monitor.recentSessions.first?.completedTaskCount == 2)
    }

    // MARK: - Permission Prompts

    @Test
    func `Notification moves the active session to awaitingInput`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(eventName: .sessionStart))

        monitor.processEvent(makeEvent(eventName: .notification, message: "Claude needs your permission to use Bash"))

        #expect(monitor.activeSession?.phase == .awaitingInput)
        #expect(monitor.activeSession?.pendingPrompt == "Claude needs your permission to use Bash")
    }

    @Test
    func `Notification is ignored when it belongs to another session`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(eventName: .sessionStart))

        monitor.processEvent(makeEvent(sessionId: "other", eventName: .notification, message: "blocked"))

        #expect(monitor.activeSession?.phase == .active)
        #expect(monitor.activeSession?.pendingPrompt == nil)
    }

    @Test
    func `UserPromptSubmit releases a session waiting on input`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(eventName: .sessionStart))
        monitor.processEvent(makeEvent(eventName: .notification, message: "blocked"))

        monitor.processEvent(makeEvent(eventName: .userPromptSubmit))

        #expect(monitor.activeSession?.phase == .active)
        #expect(monitor.activeSession?.pendingPrompt == nil)
    }
    @Test
    func `a notification Claude Code raises for itself leaves the session working`() {
        let monitor = SessionMonitor()
        monitor.processEvent(SessionEvent(sessionId: "s1", eventName: .sessionStart, cwd: "/tmp"))

        monitor.processEvent(SessionEvent(
            sessionId: "s1",
            eventName: .notification,
            cwd: "/tmp",
            message: "Claude is waiting for your input",
            notificationType: "idle_prompt"
        ))

        #expect(monitor.activeSession?.phase == .active)
        #expect(monitor.activeSession?.pendingPrompt == nil)
    }

    @Test
    func `a permission notification moves the session to awaitingInput`() {
        let monitor = SessionMonitor()
        monitor.processEvent(SessionEvent(sessionId: "s1", eventName: .sessionStart, cwd: "/tmp"))

        monitor.processEvent(SessionEvent(
            sessionId: "s1",
            eventName: .notification,
            cwd: "/tmp",
            message: "Claude needs your permission to use Bash",
            notificationType: "agent_needs_input"
        ))

        #expect(monitor.activeSession?.phase == .awaitingInput)
        #expect(monitor.activeSession?.pendingPrompt == "Claude needs your permission to use Bash")
    }
    // MARK: - Several Sessions At Once

    @Test
    func `events reach the session they name and no other`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "s2", eventName: .sessionStart))

        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .taskCompleted))
        monitor.processEvent(makeEvent(sessionId: "s2", eventName: .subagentStart))

        let first = monitor.sessions.first { $0.id == "s1" }
        let second = monitor.sessions.first { $0.id == "s2" }
        #expect(first?.completedTaskCount == 1)
        #expect(first?.phase == .active)
        #expect(second?.completedTaskCount == 0)
        #expect(second?.phase == .subagentsWorking)
    }

    @Test
    func `activeSession is whichever session most wants the user`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "working", eventName: .sessionStart, receivedAt: now))
        monitor.processEvent(makeEvent(sessionId: "blocked", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-60)))

        monitor.processEvent(SessionEvent(
            sessionId: "blocked",
            eventName: .notification,
            cwd: "/tmp",
            message: "Claude needs your permission to use Bash"
        ))

        #expect(monitor.activeSession?.id == "blocked")
    }

    @Test
    func `the newest session wins when none is more urgent than another`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "older", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-60)))
        monitor.processEvent(makeEvent(sessionId: "newer", eventName: .sessionStart, receivedAt: now))

        #expect(monitor.activeSession?.id == "newer")
    }

    @Test
    func `SessionStart for a session already known resumes it instead of duplicating it`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .stop))

        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))

        #expect(monitor.sessions.count == 1)
        #expect(monitor.activeSession?.phase == .active)
    }

    // MARK: - Payload Carried Onto The Session

    @Test
    func `a session keeps the transcript path its start event carried`() {
        let monitor = SessionMonitor()

        monitor.processEvent(SessionEvent(
            sessionId: "s1",
            eventName: .sessionStart,
            cwd: "/tmp",
            transcriptPath: "/tmp/s1.jsonl"
        ))

        #expect(monitor.activeSession?.transcriptPath == "/tmp/s1.jsonl")
    }

    @Test
    func `the prompt and the reply are recorded as they arrive`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))

        monitor.processEvent(SessionEvent(
            sessionId: "s1",
            eventName: .userPromptSubmit,
            cwd: "/tmp",
            userPrompt: "run the tests"
        ))
        monitor.processEvent(SessionEvent(
            sessionId: "s1",
            eventName: .stop,
            cwd: "/tmp",
            lastAssistantMessage: "All green."
        ))

        #expect(monitor.activeSession?.lastPrompt == "run the tests")
        #expect(monitor.activeSession?.lastReply == "All green.")
    }

    // MARK: - Pruning

    @Test
    func `pruneStale drops sessions that ended longer ago than the retention`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-1200)))
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionEnd, receivedAt: now.addingTimeInterval(-900)))
        monitor.processEvent(makeEvent(sessionId: "s2", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-600)))
        monitor.processEvent(makeEvent(sessionId: "s2", eventName: .sessionEnd, receivedAt: now.addingTimeInterval(-60)))

        monitor.pruneStale(now: now)

        #expect(monitor.sessions.map(\.id) == ["s2"])
    }

    @Test
    func `pruneStale ends a session that was killed without a SessionEnd`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "zombie", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-50_000)))

        monitor.pruneStale(now: now, endedRetention: 86_400)

        #expect(monitor.activeSessions.isEmpty)
        #expect(monitor.recentSessions.first?.id == "zombie")
    }

    @Test
    func `pruneStale leaves a session that is merely quiet alone`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-3600)))

        monitor.pruneStale(now: now)

        #expect(monitor.activeSessions.map(\.id) == ["s1"])
    }
    @Test
    func `a zombie session is retired by the next event to arrive`() {
        let monitor = SessionMonitor()
        let longAgo = Date().addingTimeInterval(-50_000)
        monitor.processEvent(makeEvent(sessionId: "zombie", eventName: .sessionStart, receivedAt: longAgo))

        monitor.processEvent(makeEvent(sessionId: "fresh", eventName: .sessionStart))

        #expect(monitor.activeSessions.map(\.id) == ["fresh"])
    }
    // MARK: - Liveness

    @Test
    func `an event from a session quiet for a day proves it is alive, not dead`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-50_000)))

        // The user comes back to a terminal left open overnight.
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .userPromptSubmit, receivedAt: now))

        #expect(monitor.activeSessions.map(\.id) == ["s1"])
        #expect(monitor.activeSession?.phase == .active)
    }

    @Test
    func `a session retired for going quiet stays on the board for its retention`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "zombie", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-50_000)))

        monitor.pruneStale(now: now)

        // Retired, but not vanished: it gets the same ten minutes any finished
        // session gets, rather than being deleted by the sweep that ended it.
        #expect(monitor.activeSessions.isEmpty)
        #expect(monitor.recentSessions.map(\.id) == ["zombie"])
    }

    @Test
    func `a resumed session comes back with the history it had`() {
        let monitor = SessionMonitor()
        let now = Date()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart, receivedAt: now.addingTimeInterval(-300)))
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .taskCompleted, receivedAt: now.addingTimeInterval(-200)))
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionEnd, receivedAt: now.addingTimeInterval(-100)))

        // claude --resume reports the same session id.
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart, receivedAt: now))

        #expect(monitor.sessions.count == 1)
        #expect(monitor.activeSession?.id == "s1")
        #expect(monitor.activeSession?.phase == .active)
        #expect(monitor.activeSession?.completedTaskCount == 1)
        #expect(monitor.activeSession?.startedAt == now.addingTimeInterval(-300))
    }

    @Test
    func `events reach a resumed session instead of being dropped`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionEnd))
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))

        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .subagentStart))

        #expect(monitor.activeSession?.phase == .subagentsWorking)
    }

    // MARK: - Usage

    @Test
    func `usage is written to the session it names`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))
        monitor.processEvent(makeEvent(sessionId: "s2", eventName: .sessionStart))

        monitor.updateUsage(sessionId: "s2", usage: SessionUsage(
            contextTokens: 100_000,
            contextWindow: 200_000,
            model: "claude-opus-4-6",
            currentTool: nil
        ))

        #expect(monitor.sessions.first { $0.id == "s1" }?.contextPercent == nil)
        #expect(monitor.sessions.first { $0.id == "s2" }?.contextPercent == 50)
    }

    @Test
    func `usage for a session that is gone is dropped`() {
        let monitor = SessionMonitor()

        monitor.updateUsage(sessionId: "ghost", usage: SessionUsage(
            contextTokens: 1,
            contextWindow: 200_000,
            model: "claude-opus-4-6",
            currentTool: nil
        ))

        #expect(monitor.sessions.isEmpty)
    }
    @Test
    func `a blocked session goes back to work when its transcript grows`() {
        // Granting a permission fires no hook, so the transcript is the only
        // evidence the user answered.
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))
        monitor.updateUsage(sessionId: "s1", usage: usage(contextTokens: 40_000))
        monitor.processEvent(SessionEvent(
            sessionId: "s1",
            eventName: .notification,
            cwd: "/tmp",
            message: "Claude needs your permission to use Bash",
            notificationType: "permission_prompt"
        ))
        #expect(monitor.activeSession?.phase == .awaitingInput)

        monitor.updateUsage(sessionId: "s1", usage: usage(contextTokens: 41_000))

        #expect(monitor.activeSession?.phase == .active)
        #expect(monitor.activeSession?.pendingPrompt == nil)
    }

    @Test
    func `a blocked session stays blocked while its transcript does not grow`() {
        let monitor = SessionMonitor()
        monitor.processEvent(makeEvent(sessionId: "s1", eventName: .sessionStart))
        monitor.updateUsage(sessionId: "s1", usage: usage(contextTokens: 40_000))
        monitor.processEvent(SessionEvent(
            sessionId: "s1",
            eventName: .notification,
            cwd: "/tmp",
            message: "Claude needs your permission to use Bash",
            notificationType: "permission_prompt"
        ))

        // The same reading arriving again is not evidence of anything.
        monitor.updateUsage(sessionId: "s1", usage: usage(contextTokens: 40_000))

        #expect(monitor.activeSession?.phase == .awaitingInput)
    }

    private func usage(contextTokens: Int) -> SessionUsage {
        SessionUsage(
            contextTokens: contextTokens,
            contextWindow: 200_000,
            model: "claude-opus-4-6",
            currentTool: nil
        )
    }
}
