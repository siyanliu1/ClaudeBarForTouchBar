import Foundation

/// The two shapes the Touch Bar board takes.
///
/// Both draw the same tiles at the same size; the only difference is how much
/// of the bar the board is allowed to occupy, and therefore how many tiles are
/// visible at once.
///
/// - `.compact`: the board sits in the app region and the Control Strip — with
///   its brightness and volume keys, and our own tray item — stays put.
/// - `.wide`: the board takes the whole bar. Nothing else is reachable, which
///   makes it a glance-and-close mode.
///
/// The pt figures are measurements taken on a MacBookPro16,2 running macOS
/// 26.6.2, not guesses, and they have to add up exactly or the board clips or
/// leaves a gap. They live here rather than beside the views — the usual home
/// for rendering constants — because arithmetic that must balance deserves a
/// test, and the App target has none.
public enum TouchBarLayout: String, Sendable, Equatable, CaseIterable {
    case compact
    case wide

    /// The layout used before the user has chosen one, and the fallback for raw
    /// values this build does not recognize.
    public static let `default`: TouchBarLayout = .compact

    /// Decodes a persisted raw value, falling back to `.default`, so a settings
    /// file written by a newer build never breaks an older one.
    public init(storedRawValue: String) {
        self = TouchBarLayout(rawValue: storedRawValue) ?? .default
    }

    /// Short label for the settings picker.
    public var displayLabel: String {
        switch self {
        case .compact: "Compact"
        case .wide: "Wide"
        }
    }

    /// The other layout — what the toggle button switches to.
    public var toggled: TouchBarLayout {
        self == .compact ? .wide : .compact
    }

    /// How much width the board owns.
    ///
    /// Compact is not the full panel: the system draws its own close box in the
    /// 64 pt to the left, outside anything we lay out. Wide is the whole bar,
    /// which is why it has to draw its own close button.
    public var boardWidth: Double {
        switch self {
        case .compact: 621
        case .wide: 1004
        }
    }

    /// Width left for the scrolling session area once the buttons and the quota
    /// column have taken theirs.
    public var sessionAreaWidth: Double {
        switch self {
        case .compact: 440
        case .wide: 777
        }
    }

    /// Whether the board has to supply its own close button. Compact keeps the
    /// system's; wide hides the Control Strip, so without one the only way out
    /// would be to toggle back to compact first.
    public var drawsOwnCloseButton: Bool {
        self == .wide
    }

    /// How many whole tiles fit the session area. The rest scroll in from the
    /// right; there is no room in either layout to let the next one peek.
    public var visibleTileCount: Int {
        TouchBarMetrics.tileCount(fitting: sessionAreaWidth)
    }

    /// Width the board's own subviews consume, which must equal `boardWidth`.
    var laidOutWidth: Double {
        let closeButton = drawsOwnCloseButton
            ? TouchBarMetrics.closeButtonWidth + TouchBarMetrics.spacing
            : 0
        return TouchBarMetrics.edgeInset
            + closeButton
            + TouchBarMetrics.toggleButtonWidth + TouchBarMetrics.spacing
            + sessionAreaWidth + TouchBarMetrics.spacing
            + TouchBarMetrics.quotaColumnWidth
            + TouchBarMetrics.edgeInset
    }
}

/// Fixed sizes shared by both layouts, in points.
public enum TouchBarMetrics {
    /// The bar is 30 pt tall and that is not negotiable.
    public static let height: Double = 30

    public static let tileWidth: Double = 104
    public static let tileHeight: Double = 26
    public static let tileGap: Double = 6

    public static let quotaColumnWidth: Double = 125
    public static let toggleButtonWidth: Double = 32
    public static let closeButtonWidth: Double = 40

    /// Gap between the board's top-level pieces, and its left and right margin.
    public static let spacing: Double = 6
    public static let edgeInset: Double = 6

    /// The largest tray item we will draw. Measured against a real Control
    /// Strip in Phase 1; if the real ceiling is lower, the number goes and only
    /// the dot stays.
    public static let maxTrayItemWidth: Double = 50

    /// How many whole tiles, separated by gaps, fit `width`.
    public static func tileCount(fitting width: Double) -> Int {
        guard width >= tileWidth else { return 0 }
        return Int((width - tileWidth) / (tileWidth + tileGap)) + 1
    }
}
