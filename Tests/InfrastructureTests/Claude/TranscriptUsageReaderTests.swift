import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

@Suite
struct TranscriptUsageReaderTests {
    private let reader = TranscriptUsageReader()

    // MARK: - Fixtures

    private func transcript(_ lines: String...) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    private func assistant(
        model: String = "claude-opus-4-6",
        input: Int = 100,
        cacheRead: Int = 50_000,
        cacheCreation: Int = 2_000,
        content: String = "[]"
    ) -> String {
        """
        {"type":"assistant","message":{"id":"msg_1","model":"\(model)","content":\(content),\
        "usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":\(cacheCreation),"output_tokens":30}},"requestId":"req_1"}
        """
    }

    private func toolUse(_ name: String, _ input: String) -> String {
        """
        [{"type":"text","text":"working"},{"type":"tool_use","name":"\(name)","input":\(input)}]
        """
    }

    private func withTranscript(_ contents: String, _ body: (String) throws -> Void) rethrows {
        let path = NSTemporaryDirectory() + "transcript-\(UUID().uuidString).jsonl"
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Reading

    @Test
    func `context is the newest assistant record's input plus everything cached`() throws {
        try withTranscript(transcript(assistant())) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.contextTokens == 52_100)
            #expect(result.usage?.model == "claude-opus-4-6")
            #expect(result.usage?.contextWindow == 200_000)
        }
    }

    @Test
    func `a long context model is measured against the million token window`() throws {
        try withTranscript(transcript(assistant(model: "claude-sonnet-4-6[1m]"))) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.contextWindow == 1_000_000)
        }
    }

    @Test
    func `the newest record wins when several are appended at once`() throws {
        let contents = transcript(
            assistant(input: 1, cacheRead: 0, cacheCreation: 0),
            assistant(input: 7, cacheRead: 3, cacheCreation: 0)
        )
        try withTranscript(contents) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.contextTokens == 10)
        }
    }

    @Test
    func `a second read starts where the first stopped`() throws {
        try withTranscript(transcript(assistant(input: 1, cacheRead: 0, cacheCreation: 0))) { path in
            let first = try reader.read(path: path, from: 0, previous: nil)
            try append(transcript(assistant(input: 9, cacheRead: 0, cacheCreation: 0)), to: path)

            let second = try reader.read(path: path, from: first.offset, previous: first.usage)

            #expect(second.usage?.contextTokens == 9)
            #expect(second.offset > first.offset)
        }
    }

    @Test
    func `a half written line is left for the next read`() throws {
        let complete = transcript(assistant(input: 1, cacheRead: 0, cacheCreation: 0))
        try withTranscript(complete) { path in
            let partial = String(assistant(input: 9, cacheRead: 0, cacheCreation: 0).prefix(60))
            try append(partial, to: path)

            let first = try reader.read(path: path, from: 0, previous: nil)

            #expect(first.offset == complete.utf8.count)
            #expect(first.usage?.contextTokens == 1)

            // The rest of that line arrives, and now it counts.
            let rest = String(assistant(input: 9, cacheRead: 0, cacheCreation: 0).dropFirst(60))
            try append(rest + "\n", to: path)
            let second = try reader.read(path: path, from: first.offset, previous: first.usage)

            #expect(second.usage?.contextTokens == 9)
        }
    }

    @Test
    func `nothing new means the previous reading still stands`() throws {
        try withTranscript(transcript(assistant())) { path in
            let first = try reader.read(path: path, from: 0, previous: nil)
            let second = try reader.read(path: path, from: first.offset, previous: first.usage)

            #expect(second.usage == first.usage)
            #expect(second.offset == first.offset)
        }
    }

    @Test
    func `lines that are not assistant records are ignored`() throws {
        let contents = transcript(
            #"{"type":"user","message":{"content":"hello"}}"#,
            assistant(input: 5, cacheRead: 0, cacheCreation: 0),
            #"{"type":"user","message":{"content":"more"}}"#
        )
        try withTranscript(contents) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.contextTokens == 5)
        }
    }

    @Test
    func `a line that is not JSON does not stop the read`() throws {
        let contents = transcript("{not json", assistant(input: 5, cacheRead: 0, cacheCreation: 0))
        try withTranscript(contents) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.contextTokens == 5)
        }
    }

    @Test
    func `a transcript replaced by a shorter one is read from the top`() throws {
        try withTranscript(transcript(assistant(input: 1, cacheRead: 0, cacheCreation: 0))) { path in
            let first = try reader.read(path: path, from: 0, previous: nil)

            let shorter = transcript(assistant(input: 2, cacheRead: 0, cacheCreation: 0))
            try Data(shorter.utf8).write(to: URL(fileURLWithPath: path))

            let second = try reader.read(path: path, from: first.offset + 10_000, previous: first.usage)

            #expect(second.usage?.contextTokens == 2)
        }
    }

    @Test
    func `reading a transcript that is not there throws`() {
        #expect(throws: (any Error).self) {
            try reader.read(path: "/nonexistent/transcript.jsonl", from: 0, previous: nil)
        }
    }

    // MARK: - Current Tool

    @Test
    func `a shell command is summarised on one line and cut short`() throws {
        let command = "tuist test DomainTests\\nand a very long second line that runs on"
        let content = toolUse("Bash", #"{"command":"\#(command)"}"#)
        try withTranscript(transcript(assistant(content: content))) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.currentTool == "Bash · tuist test DomainTests and a very long s")
        }
    }

    @Test
    func `a file tool is summarised by the file it touches`() throws {
        let content = toolUse("Edit", #"{"file_path":"/repo/Sources/Domain/Ledger.swift"}"#)
        try withTranscript(transcript(assistant(content: content))) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.currentTool == "Edit · Ledger.swift")
        }
    }

    @Test
    func `a subagent is summarised by what it was asked to do`() throws {
        let content = toolUse("Agent", #"{"description":"Explore repo layout"}"#)
        try withTranscript(transcript(assistant(content: content))) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.currentTool == "Agent · Explore repo layout")
        }
    }

    @Test
    func `an unfamiliar tool is named and nothing more`() throws {
        let content = toolUse("WebFetch", #"{"url":"https://example.com"}"#)
        try withTranscript(transcript(assistant(content: content))) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.currentTool == "WebFetch")
        }
    }

    @Test
    func `the last tool in a record is the one being run`() throws {
        let content = """
        [{"type":"tool_use","name":"Read","input":{"file_path":"/a/First.swift"}},\
        {"type":"tool_use","name":"Read","input":{"file_path":"/a/Second.swift"}}]
        """
        try withTranscript(transcript(assistant(content: content))) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.currentTool == "Read · Second.swift")
        }
    }

    @Test
    func `a reply with no tool keeps showing the last tool that ran`() throws {
        let withTool = assistant(content: toolUse("Bash", #"{"command":"ls"}"#))
        try withTranscript(transcript(withTool)) { path in
            let first = try reader.read(path: path, from: 0, previous: nil)
            try append(transcript(assistant(content: #"[{"type":"text","text":"done"}]"#)), to: path)

            let second = try reader.read(path: path, from: first.offset, previous: first.usage)

            #expect(second.usage?.currentTool == "Bash · ls")
        }
    }
    @Test
    func `a model holding more than the standard window is not reported as full`() throws {
        // claude-opus-5 runs past 200k with no [1m] marker in its name.
        let big = assistant(model: "claude-opus-5", input: 2, cacheRead: 208_480, cacheCreation: 1_281)
        try withTranscript(transcript(big)) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            // 209,763 fits the next size up, so it is measured against 500k
            // rather than being called a fifth of a million.
            #expect(result.usage?.contextWindow == 500_000)
            #expect(abs((result.usage?.contextPercent ?? 0) - 41.9526) < 0.0001)
        }
    }
    // MARK: - Records That Are Not Turns

    @Test
    func `a synthetic notice does not report a full session as empty`() throws {
        // Claude Code writes its own notices as real assistant records with a
        // usage block of all zeros.
        let synthetic = """
        {"type":"assistant","message":{"id":"msg_2","model":"<synthetic>",\
        "content":[{"type":"text","text":"You've hit your session limit"}],\
        "usage":{"input_tokens":0,"cache_read_input_tokens":0,\
        "cache_creation_input_tokens":0,"output_tokens":0}},"requestId":"req_2"}
        """
        let contents = transcript(assistant(input: 2, cacheRead: 124_000, cacheCreation: 0), synthetic)

        try withTranscript(contents) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.contextTokens == 124_002)
            #expect(result.usage?.model == "claude-opus-4-6")
        }
    }

    @Test
    func `a synthetic notice arriving alone leaves the previous reading standing`() throws {
        try withTranscript(transcript(assistant(input: 2, cacheRead: 124_000, cacheCreation: 0))) { path in
            let first = try reader.read(path: path, from: 0, previous: nil)

            let synthetic = """
            {"type":"assistant","message":{"id":"msg_2","model":"<synthetic>",\
            "content":[{"type":"text","text":"No response requested."}],\
            "usage":{"input_tokens":0,"cache_read_input_tokens":0,\
            "cache_creation_input_tokens":0,"output_tokens":0}},"requestId":"req_2"}
            """
            try append(transcript(synthetic), to: path)
            let second = try reader.read(path: path, from: first.offset, previous: first.usage)

            #expect(second.usage?.contextTokens == 124_002)
        }
    }

    // MARK: - Window Inference

    @Test
    func `the inferred window only ever grows as a session fills`() {
        // Crossing a size still drops the percentage — 499k of an assumed 500k
        // reads 99.8%, and one token later 60% of a million. That is the price
        // of inferring a window nothing states, and it is paid at most twice in
        // a session, each time replacing a near-full reading that was wrong.
        // What must not happen is the window shrinking, which would make the
        // percentage climb while the session emptied.
        var window = 0

        for tokens in [150_000, 199_999, 200_001, 260_000, 499_000, 600_000] {
            let next = ModelContextWindow.window(
                for: "claude-opus-5",
                holding: tokens,
                previously: window
            )
            #expect(next >= window, "window shrank at \(tokens) tokens")
            window = next
        }
    }

    @Test
    func `a reading is never past full`() {
        var window = 0

        for tokens in [150_000, 199_999, 200_001, 600_000, 1_400_000] {
            window = ModelContextWindow.window(for: "claude-opus-5", holding: tokens, previously: window)
            let usage = SessionUsage(
                contextTokens: tokens,
                contextWindow: window,
                model: "claude-opus-5",
                currentTool: nil
            )
            #expect(usage.contextPercent <= 100)
        }
    }

    @Test
    func `a session just past the standard window is measured against the next size up`() {
        // Not a million: reporting a nearly-full window as a fifth full is the
        // opposite of what the reading is for.
        #expect(ModelContextWindow.window(for: "claude-opus-5", holding: 200_001) == 500_000)
        #expect(ModelContextWindow.window(for: "claude-opus-5", holding: 600_000) == 1_000_000)
    }

    @Test
    func `an inferred window is never given back`() {
        #expect(
            ModelContextWindow.window(for: "claude-opus-5", holding: 10_000, previously: 500_000)
                == 500_000
        )
    }

    @Test
    func `a long context model starts at its own window`() {
        #expect(ModelContextWindow.window(for: "claude-sonnet-4-6[1m]", holding: 10) == 1_000_000)
    }

    @Test
    func `a notebook is summarised by its own path argument`() throws {
        let content = toolUse("NotebookEdit", #"{"notebook_path":"/repo/analysis/model.ipynb"}"#)
        try withTranscript(transcript(assistant(content: content))) { path in
            let result = try reader.read(path: path, from: 0, previous: nil)

            #expect(result.usage?.currentTool == "NotebookEdit · model.ipynb")
        }
    }
}
