import Foundation

/// How many tokens a Claude model can hold.
///
/// Neither the transcript nor the CLI states this — Claude Code reads it from
/// the model metadata the API returns — so it has to be inferred from two
/// things: the `[1m]` marker Claude Code puts in the model name for the
/// long-context variants, and the transcript itself, which cannot hold more
/// context than the window allows.
///
/// ponytail: inference, not a table. A real per-model table would need a source
/// to keep it honest; the day one exists (a model-metadata endpoint, or the CLI
/// writing the window into the transcript) it replaces this outright.
enum ModelContextWindow {
    static let standard = 200_000

    /// The window sizes worth guessing between, smallest first. A session is
    /// measured against the smallest one it still fits in — jumping straight to
    /// a million for a session just past 200k would report a nearly-full window
    /// as a fifth full, which is the opposite of what the reading is for.
    static let sizes = [standard, 500_000, 1_000_000]

    /// The window for `model`, given a transcript observed to hold
    /// `contextTokens` and whatever was inferred last time.
    ///
    /// A session already holding more than the standard window is proof the
    /// standard window is wrong for that model — `claude-opus-5` runs past 200k
    /// with no `[1m]` in its name. `previously` makes the guess a ratchet: once
    /// a session has been seen at 300k the window never shrinks back.
    ///
    /// Crossing a size does still drop the percentage — 499k of an assumed 500k
    /// reads 99.8%, and one token later 60% of a million. That is unavoidable
    /// while the window is inferred rather than known; it happens at most twice
    /// in a session, and each time it replaces a near-full reading that was the
    /// wrong one.
    static func window(for model: String, holding contextTokens: Int, previously: Int? = nil) -> Int {
        let assumed = max(
            model.contains("[1m]") ? sizes.last ?? standard : standard,
            previously ?? 0
        )
        guard contextTokens > assumed else { return assumed }
        return sizes.first { $0 >= contextTokens } ?? sizes.last ?? standard
    }
}
