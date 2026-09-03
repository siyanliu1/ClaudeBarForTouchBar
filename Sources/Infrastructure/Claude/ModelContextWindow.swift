import Foundation

/// How many tokens a Claude model can hold.
///
/// Neither the transcript nor the CLI states this — Claude Code reads it from
/// the model metadata the API returns — so it has to be inferred. Two things
/// give it away: the `[1m]` marker Claude Code puts in the model name for the
/// long-context variants, and the transcript itself, which cannot hold more
/// context than the window allows.
///
/// ponytail: inference, not a table. A real per-model table would need a source
/// to keep it honest; the day one exists (a model-metadata endpoint, or the CLI
/// writing the window into the transcript) it replaces this outright.
enum ModelContextWindow {
    static let standard = 200_000
    static let long = 1_000_000

    /// The window for `model`, given a transcript observed to hold
    /// `contextTokens`.
    ///
    /// A session already holding more than the standard window is proof the
    /// standard window is wrong for that model — `claude-opus-5` runs past 200k
    /// with no `[1m]` in its name — and reporting "100% full" at that point
    /// would be a false alarm about a session with room to spare.
    static func window(for model: String, holding contextTokens: Int) -> Int {
        let assumed = model.contains("[1m]") ? long : standard
        return contextTokens > assumed ? long : assumed
    }
}
