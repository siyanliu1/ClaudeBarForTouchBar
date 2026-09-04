import Testing
import Foundation
@testable import Domain

@Suite
struct SessionUsageTests {
    private func usage(contextTokens: Int, contextWindow: Int = 200_000) -> SessionUsage {
        SessionUsage(
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            model: "claude-opus-4-6",
            currentTool: nil
        )
    }

    @Test
    func `context percent is the share of the window in use`() {
        #expect(usage(contextTokens: 50_000).contextPercent == 25)
    }

    @Test
    func `a long context model is measured against its own window`() {
        let long = usage(contextTokens: 200_000, contextWindow: 1_000_000)

        #expect(long.contextPercent == 20)
    }

    @Test
    func `a window of zero reads as empty rather than dividing by zero`() {
        #expect(usage(contextTokens: 1000, contextWindow: 0).contextPercent == 0)
    }

    @Test
    func `a context larger than the window is not reported past full`() {
        #expect(usage(contextTokens: 250_000).contextPercent == 100)
    }
}
