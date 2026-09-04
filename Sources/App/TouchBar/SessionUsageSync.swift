import Foundation
import Domain
import Infrastructure

/// Keeps each running session's context percentage and current tool up to date
/// by following its transcript.
///
/// Hook events say what a session is doing but never how many tokens it has
/// spent — that is only in the JSONL transcript Claude Code writes. This reads
/// the appended bytes of each live session's transcript and hands the result to
/// `SessionMonitor`.
///
/// It is deliberately not Touch Bar-specific: the notch and the popover can
/// show a context percentage later without moving any of this.
@MainActor
final class SessionUsageSync {
    private let sessionMonitor: SessionMonitor
    private let reader = TranscriptUsageReader()

    /// Where the last read of each session's transcript stopped, and what it
    /// found. The reader is stateless; this is the state.
    private var progress: [String: (offset: Int, usage: SessionUsage?)] = [:]
    /// Sessions with a read in flight. Without this, a slow read and the tick
    /// that follows it would both start from the same offset and the later
    /// answer could be the older one.
    private var reading: Set<String> = []

    private var timer: Timer?

    private enum Timing {
        /// How often a visible board re-reads the transcripts of the sessions
        /// that are actually working.
        static let pollInterval: TimeInterval = 3
    }

    init(sessionMonitor: SessionMonitor) {
        self.sessionMonitor = sessionMonitor
    }

    /// Reads one session now. Called when a hook event says something happened,
    /// which is the cheapest possible trigger — no polling, no guessing.
    func sessionDidChange(_ sessionId: String) {
        // Pruning belongs here rather than only in the tick: events arrive
        // whatever the board is doing, and the tick only runs while it is on
        // screen — so with the board closed, which is most of the time, nothing
        // would ever release a finished session's read position.
        forgetSessionsNotIn(Set(sessionMonitor.sessions.map(\.id)))
        guard let session = sessionMonitor.sessions.first(where: { $0.id == sessionId }) else { return }
        read(session)
    }

    /// Starts or stops the 3-second tick.
    ///
    /// Only worth running while the board is actually on screen: a context
    /// percentage nobody is looking at is a file read for nothing, and this can
    /// run for as long as the Mac is awake.
    func setPolling(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }

        timer = Timer.scheduledTimer(withTimeInterval: Timing.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Forgets a session's read position. Sessions that have gone are dropped
    /// so the map does not grow for the life of the app.
    func forgetSessionsNotIn(_ ids: Set<String>) {
        progress = progress.filter { ids.contains($0.key) }
    }

    // MARK: - Private

    private func tick() {
        for session in sessionMonitor.activeSessions where session.isBusy {
            read(session)
        }
        forgetSessionsNotIn(Set(sessionMonitor.sessions.map(\.id)))
    }

    private func read(_ session: ClaudeSession) {
        guard let path = session.transcriptPath, !reading.contains(session.id) else { return }

        let sessionId = session.id
        let previous = progress[sessionId]
        let reader = reader
        reading.insert(sessionId)

        Task.detached(priority: .utility) {
            // A transcript that has not grown has nothing new to say, and
            // stat is far cheaper than opening and decoding it.
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
            let result: (offset: Int, usage: SessionUsage?)?
            if let size, let previous, size <= previous.offset {
                result = nil
            } else {
                result = try? reader.read(path: path, from: previous?.offset ?? 0, previous: previous?.usage)
            }

            await MainActor.run { [weak self] in
                self?.finish(sessionId: sessionId, result: result)
            }
        }
    }

    private func finish(sessionId: String, result: (offset: Int, usage: SessionUsage?)?) {
        reading.remove(sessionId)
        guard let result else { return }
        progress[sessionId] = result
        guard let usage = result.usage else { return }
        sessionMonitor.updateUsage(sessionId: sessionId, usage: usage)
    }
}
