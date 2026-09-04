#if ENABLE_TOUCHBAR
import AppKit
import SwiftUI
import Domain

/// The colours the Touch Bar draws with, resolved once per repaint.
///
/// Two reasons this exists rather than each view reaching for `ThemeRegistry`.
/// First, everything in this codebase vends a SwiftUI `Color` and AppKit needs
/// an `NSColor`, so the conversion should happen once, not at every draw call.
///
/// Second, and less obvious: `resolveTheme(for:systemColorScheme:)` only
/// consults the colour scheme for the `"system"` theme id. A user on the light
/// theme gets `LightTheme`, whose text colours are near-black — invisible on a
/// bar that is always black whatever the rest of the Mac is doing. So the text
/// greys here are fixed, and the theme is consulted only for the status
/// colours, which are saturated enough to read on black in every theme.
@MainActor
struct TouchBarPalette {
    /// Tile background, and the warmer one used while a session is blocked.
    let tileFill: NSColor
    let attentionTileFill: NSColor

    let primaryText: NSColor
    let secondaryText: NSColor
    let endedPrimaryText: NSColor
    let endedSecondaryText: NSColor
    /// Numbers dim to this while a refresh is in flight.
    let dimmedText: NSColor

    let claudeLabel: NSColor
    let codexLabel: NSColor

    private let statusColors: [QuotaStatus: NSColor]
    private let phaseColors: [ClaudeSession.Phase: NSColor]

    func color(for status: QuotaStatus) -> NSColor {
        statusColors[status] ?? primaryText
    }

    func color(for phase: ClaudeSession.Phase) -> NSColor {
        phaseColors[phase] ?? secondaryText
    }

    /// How a context percentage is coloured. White until the window is filling
    /// up, then the same warning and critical colours a quota uses — the two
    /// mean the same thing to the reader, so they should look the same.
    func contextColor(forPercent percent: Double) -> NSColor {
        switch percent {
        case 90...: color(for: .critical)
        case 80...: color(for: .warning)
        default: primaryText
        }
    }

    static func resolve(themeModeId: String) -> TouchBarPalette {
        let theme = ThemeRegistry.shared.resolveTheme(for: themeModeId, systemColorScheme: .dark)

        var statusColors: [QuotaStatus: NSColor] = [:]
        for status in [QuotaStatus.healthy, .warning, .critical, .depleted] {
            statusColors[status] = NSColor(theme.statusColor(for: status))
        }

        var phaseColors: [ClaudeSession.Phase: NSColor] = [:]
        for phase in [ClaudeSession.Phase.active, .subagentsWorking, .awaitingInput, .stopped, .ended] {
            // phase.color is a semantic system colour, so the NSColor it becomes
            // resolves against whatever appearance is current at draw time. The
            // board forces .darkAqua on itself for exactly this reason.
            phaseColors[phase] = NSColor(phase.color)
        }

        return TouchBarPalette(
            tileFill: NSColor(red: 0.086, green: 0.086, blue: 0.094, alpha: 1),
            attentionTileFill: NSColor(red: 0.165, green: 0.141, blue: 0.031, alpha: 1),
            primaryText: .white,
            secondaryText: NSColor(white: 1, alpha: 0.62),
            endedPrimaryText: NSColor(white: 1, alpha: 0.55),
            endedSecondaryText: NSColor(white: 1, alpha: 0.50),
            dimmedText: NSColor(white: 1, alpha: 0.50),
            claudeLabel: NSColor(ProviderVisualIdentityLookup.color(for: "claude", scheme: .dark)),
            codexLabel: NSColor(ProviderVisualIdentityLookup.color(for: "codex", scheme: .dark)),
            statusColors: statusColors,
            phaseColors: phaseColors
        )
    }
}

/// Type sizes, all of them. Collected here because the bar is 30 pt tall and
/// every one of these was chosen against that ceiling.
@MainActor
enum TouchBarFont {
    static let tileName = NSFont.systemFont(ofSize: 11, weight: .bold)
    static let tileContext = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    static let tileDetail = NSFont.systemFont(ofSize: 9.5, weight: .regular)
    static let quota = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    static let tray = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static let emptyState = NSFont.systemFont(ofSize: 10, weight: .regular)
}
#endif
