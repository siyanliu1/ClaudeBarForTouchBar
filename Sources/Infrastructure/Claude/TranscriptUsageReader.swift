import Foundation
import Domain

/// Reads a Claude Code session transcript to find how full its context window is
/// and what tool it is running.
///
/// Transcripts are append-only JSONL and grow to megabytes over a long session,
/// so each read picks up only the bytes added since the last one. The caller
/// keeps the offset; this type holds no state.
public struct TranscriptUsageReader: Sendable {
    public init() {}

    /// Reads whatever was appended to `path` since `offset`.
    ///
    /// Returns the offset to resume from — always just past the last complete
    /// line, so a half-written line is read again next time rather than parsed
    /// in two halves — and the usage, which falls back to `previous` when the
    /// new bytes said nothing about it.
    public func read(
        path: String,
        from offset: Int,
        previous: SessionUsage?
    ) throws -> (offset: Int, usage: SessionUsage?) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        let end = try handle.seekToEnd()
        // A transcript shorter than the offset was replaced, not appended to —
        // a resumed session rewriting its file. Start again from the top.
        var start = UInt64(max(0, offset))
        if start > end { start = 0 }
        guard start < end else { return (Int(start), previous) }

        try handle.seek(toOffset: start)
        let appended = try handle.readToEnd() ?? Data()
        guard let lastNewline = appended.lastIndex(of: UInt8(ascii: "\n")) else {
            return (Int(start), previous)
        }

        let complete = appended[...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        return (Int(start) + complete.count, usage(from: text, previous: previous))
    }

    // MARK: - Private

    /// The newest assistant record wins, so lines are read newest first and the
    /// scan stops as soon as both answers are in hand.
    private func usage(from text: String, previous: SessionUsage?) -> SessionUsage? {
        var contextTokens: Int?
        var model: String?
        var tool: String?

        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any]
            else { continue }

            if tool == nil { tool = toolSummary(in: message) }

            if contextTokens == nil, let usage = message["usage"] as? [String: Any] {
                // What the next request will carry, which is what "context used"
                // means: fresh input plus everything replayed from the cache.
                let tokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                // Claude Code writes its own notices — "You've hit your session
                // limit", "API Error: 503" — as real assistant records carrying
                // a usage block of all zeros, usually under the model name
                // "<synthetic>". A turn that carried no context at all did not
                // happen, so keep walking back rather than reporting a full
                // session as empty.
                if tokens > 0 {
                    contextTokens = tokens
                    model = message["model"] as? String
                }
            }

            if contextTokens != nil, tool != nil { break }
        }

        guard let contextTokens, let model else { return previous }

        return SessionUsage(
            contextTokens: contextTokens,
            contextWindow: ModelContextWindow.window(
                for: model,
                holding: contextTokens,
                previously: previous?.contextWindow
            ),
            model: model,
            currentTool: tool ?? previous?.currentTool
        )
    }

    private func toolSummary(in message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]],
              let block = content.last(where: { $0["type"] as? String == "tool_use" }),
              let name = block["name"] as? String
        else { return nil }

        let input = block["input"] as? [String: Any] ?? [:]
        guard let detail = detail(forTool: name, input: input), !detail.isEmpty else { return name }
        return "\(name) · \(detail)"
    }

    private static let maxDetailLength = 40

    private func detail(forTool name: String, input: [String: Any]) -> String? {
        switch name {
        case "Bash":
            // Commands are routinely multi-line; a tile is one line.
            guard let command = input["command"] as? String else { return nil }
            let flattened = command.split(whereSeparator: \.isNewline).joined(separator: " ")
            return String(flattened.prefix(Self.maxDetailLength))
        case "Edit", "Write", "Read":
            guard let path = input["file_path"] as? String else { return nil }
            return (path as NSString).lastPathComponent
        case "NotebookEdit":
            // The only file tool that does not call its argument file_path.
            guard let path = input["notebook_path"] as? String else { return nil }
            return (path as NSString).lastPathComponent
        case "Agent", "Task":
            guard let description = input["description"] as? String else { return nil }
            return String(description.prefix(Self.maxDetailLength))
        default:
            return nil
        }
    }
}
