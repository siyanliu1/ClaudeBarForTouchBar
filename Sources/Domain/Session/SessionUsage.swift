import Foundation

/// What a Claude Code session's transcript says about its current turn.
///
/// Only what a display actually shows is kept. Cumulative token totals are
/// deliberately absent: they cannot be accumulated exactly from incremental
/// reads without also carrying the set of message ids already counted, and
/// nothing renders them. `contextTokens` needs none of that — it is read
/// straight off the newest assistant record.
public struct SessionUsage: Sendable, Equatable {
    /// Tokens the next request will carry: the newest assistant record's input,
    /// cache reads and cache writes.
    public let contextTokens: Int

    /// How many tokens this model can hold.
    public let contextWindow: Int

    /// The model that wrote the newest assistant record.
    public let model: String

    /// The most recent tool call, already summarised for display
    /// (e.g. `Bash · tuist test DomainTests`). `nil` when the transcript has
    /// shown no tool use.
    public let currentTool: String?

    public init(contextTokens: Int, contextWindow: Int, model: String, currentTool: String?) {
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.model = model
        self.currentTool = currentTool
    }

    /// How full the context window is, 0–100.
    ///
    /// Clamped at 100: the window figures are a lookup table, not something the
    /// transcript states, so a model whose real window is larger than the table
    /// says must not produce "137%".
    public var contextPercent: Double {
        guard contextWindow > 0 else { return 0 }
        return min(100, Double(contextTokens) / Double(contextWindow) * 100)
    }
}
