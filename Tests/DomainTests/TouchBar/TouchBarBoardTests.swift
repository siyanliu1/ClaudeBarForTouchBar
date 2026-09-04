import Testing
import Foundation
@testable import Domain

@Suite
struct TouchBarBoardTests {
    private let now = Date()

    // MARK: - Fixtures

    private func session(
        _ id: String,
        cwd: String = "/repo/claudebar",
        startedAt: TimeInterval = 0,
        phase: (inout ClaudeSession) -> Void = { _ in }
    ) -> ClaudeSession {
        var session = ClaudeSession(
            id: id,
            cwd: cwd,
            startedAt: now.addingTimeInterval(startedAt)
        )
        phase(&session)
        return session
    }

    private func snapshot(_ providerId: String, _ quotas: [(String, Double)]) -> UsageSnapshot {
        UsageSnapshot(
            providerId: providerId,
            quotas: quotas.map { key, percent in
                UsageQuota(
                    percentRemaining: percent,
                    quotaType: QuotaType(quotaKey: key)!,
                    providerId: providerId
                )
            },
            capturedAt: now
        )
    }

    private func build(
        sessions: [ClaudeSession] = [],
        snapshots: [String: UsageSnapshot] = [:],
        traySelection: (providerId: String, quotaKey: String) = ("claude", "session"),
        hooksEnabled: Bool = true,
        isRefreshing: Bool = false
    ) -> TouchBarBoard {
        TouchBarBoard.build(
            sessions: sessions,
            snapshot: { snapshots[$0] },
            traySelection: traySelection,
            hooksEnabled: hooksEnabled,
            isRefreshing: isRefreshing,
            now: now
        )
    }

    // MARK: - Order

    @Test
    func `the session that most wants the user comes first`() {
        let working = session("working", startedAt: -10)
        let blocked = session("blocked", startedAt: -600) { $0.awaitInput("permission") }
        let subagents = session("subagents", startedAt: -300) { $0.subagentStarted() }

        let board = build(sessions: [working, subagents, blocked])

        #expect(board.tiles.map(\.id) == ["blocked", "subagents", "working"])
    }

    @Test
    func `the newest session leads among equals`() {
        let older = session("older", startedAt: -600)
        let newer = session("newer", startedAt: -10)

        let board = build(sessions: [older, newer])

        #expect(board.tiles.map(\.id) == ["newer", "older"])
    }

    @Test
    func `the order does not depend on what a session is saying`() {
        var quiet = session("quiet", startedAt: -10)
        var chatty = session("chatty", startedAt: -600)
        chatty.resume(prompt: "a long and interesting prompt")

        let before = build(sessions: [quiet, chatty]).tiles.map(\.id)
        quiet.resume(prompt: "something else entirely")
        let after = build(sessions: [quiet, chatty]).tiles.map(\.id)

        #expect(before == after)
    }

    // MARK: - Expiry

    @Test
    func `a session that ended within the last ten minutes still has a tile`() {
        let recent = session("recent") { $0.end(at: now.addingTimeInterval(-60)) }

        #expect(build(sessions: [recent]).tiles.map(\.id) == ["recent"])
    }

    @Test
    func `a session that ended longer ago is gone`() {
        let old = session("old") { $0.end(at: now.addingTimeInterval(-601)) }

        #expect(build(sessions: [old]).tiles.isEmpty)
    }

    // MARK: - Tile Contents

    @Test
    func `a tile is named after the repository the session runs in`() {
        let board = build(sessions: [session("s", cwd: "/Users/me/code/claudebar")])

        #expect(board.tiles.first?.name == "claudebar")
    }

    @Test
    func `a tile always has a line to show`() {
        let board = build(sessions: [session("s")])

        #expect(board.tiles.first?.candidates == ["Active"])
        #expect(board.tiles.first?.text == "Active")
    }

    @Test
    func `a blocked tile asks for attention and keeps moving`() {
        let board = build(sessions: [session("s") { $0.awaitInput("permission") }])

        #expect(board.tiles.first?.isAttention == true)
        #expect(board.tiles.first?.isAnimated == true)
    }

    @Test
    func `a finished tile is still and asks for nothing`() {
        let board = build(sessions: [session("s") { $0.stop() }])

        #expect(board.tiles.first?.isAttention == false)
        #expect(board.tiles.first?.isAnimated == false)
    }

    @Test
    func `a tile carries the context percentage once one is known`() {
        let board = build(sessions: [session("s") { session in
            session.updateUsage(SessionUsage(
                contextTokens: 60_000,
                contextWindow: 200_000,
                model: "claude-opus-4-6",
                currentTool: nil
            ))
        }])

        #expect(board.tiles.first?.contextPercent == 30)
    }

    // MARK: - Quota Columns

    @Test
    func `the claude line reads the five hour, seven day and fable windows in order`() {
        let board = build(snapshots: [
            "claude": snapshot("claude", [("session", 90), ("weekly", 15), ("model:fable", 30)]),
        ])

        #expect(board.claude.map(\.percent) == [90, 15, 30])
    }

    @Test
    func `the codex line reads its two windows`() {
        let board = build(snapshots: [
            "codex": snapshot("codex", [("session", 80), ("weekly", 45)]),
        ])

        #expect(board.codex.map(\.percent) == [80, 45])
    }

    @Test
    func `a window the provider did not report is missing, not zero`() {
        let board = build(snapshots: [
            "claude": snapshot("claude", [("session", 90)]),
        ])

        #expect(board.claude.map(\.percent) == [90, nil, nil])
        #expect(board.claude[1].status == nil)
    }

    @Test
    func `a provider that has never reported leaves its whole line missing`() {
        let board = build()

        #expect(board.claude.allSatisfy { $0.percent == nil })
        #expect(board.codex.allSatisfy { $0.percent == nil })
    }

    @Test
    func `each number carries its own status`() {
        let board = build(snapshots: [
            "claude": snapshot("claude", [("session", 90), ("weekly", 30), ("model:fable", 5)]),
        ])

        #expect(board.claude.map(\.status) == [.healthy, .warning, .critical])
    }

    // MARK: - Tray

    @Test
    func `the tray number follows the provider and window the menu bar uses`() {
        let board = build(
            snapshots: [
                "claude": snapshot("claude", [("session", 90)]),
                "codex": snapshot("codex", [("weekly", 45)]),
            ],
            traySelection: ("codex", "weekly")
        )

        #expect(board.tray.quota.percent == 45)
    }

    @Test
    func `the tray dot shows the phase of the tile that leads the board`() {
        let working = session("working", startedAt: -10)
        let blocked = session("blocked", startedAt: -600) { $0.awaitInput("permission") }

        let board = build(sessions: [working, blocked])

        #expect(board.tray.phase == .awaitingInput)
    }

    @Test
    func `the tray dot has no phase to show when nothing is running`() {
        #expect(build().tray.phase == nil)
    }

    // MARK: - Empty States

    @Test
    func `an empty board says when sessions will appear`() {
        #expect(build().emptyMessage == "No sessions · appears when Claude Code starts")
    }

    @Test
    func `an empty board says so differently when hooks are off`() {
        #expect(build(hooksEnabled: false).emptyMessage == "Enable Hooks in Settings")
    }

    @Test
    func `a board with tiles has nothing to say instead of them`() {
        #expect(build(sessions: [session("s")]).emptyMessage == nil)
    }

    // MARK: - Refresh

    @Test
    func `the board reports a refresh in flight`() {
        #expect(build(isRefreshing: true).isRefreshing)
        #expect(build().isRefreshing == false)
    }

    @Test
    func `the same state twice builds an equal board`() {
        let sessions = [session("a", startedAt: -10), session("b", startedAt: -20)]
        let snapshots = ["claude": snapshot("claude", [("session", 90)])]

        #expect(build(sessions: sessions, snapshots: snapshots)
            == build(sessions: sessions, snapshots: snapshots))
    }
    // MARK: - Empty Value

    @Test
    func `the empty board has a cell for every number it will ever show`() {
        #expect(TouchBarBoard.empty.claude.count == 3)
        #expect(TouchBarBoard.empty.codex.count == 2)
        #expect(TouchBarBoard.empty.claude.allSatisfy { $0.percent == nil })
    }

    @Test
    func `the empty board makes no claim about sessions`() {
        // "No sessions" would be a statement; before the first read there is
        // simply nothing known.
        #expect(TouchBarBoard.empty.tiles.isEmpty)
        #expect(TouchBarBoard.empty.emptyMessage == nil)
        #expect(TouchBarBoard.empty.tray.phase == nil)
    }
}
