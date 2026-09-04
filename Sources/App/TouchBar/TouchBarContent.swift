#if ENABLE_TOUCHBAR
import Foundation
import Domain

/// Everything the Touch Bar needs for one repaint, in one value.
///
/// Equatable so the driver can push it unconditionally and the controller can
/// drop the ones that changed nothing — the same contract `NotchContent` has.
struct TouchBarContent: Equatable {
    let board: TouchBarBoard
    /// The theme id, carried rather than resolved upstream so the controller
    /// can turn it into colours on the main actor where AppKit wants them.
    let themeModeId: String
    let layout: TouchBarLayout

    static let empty = TouchBarContent(
        board: .empty,
        themeModeId: "dark",
        layout: .default
    )
}
#endif
