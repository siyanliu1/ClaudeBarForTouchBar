#if ENABLE_TOUCHBAR
import AppKit
import Domain

/// One session, 104 × 26 pt.
///
/// ```
///  ┌─┬────────────────────────────┐
///  │▌│ claudebar            34%   │
///  │▌│ Bash · tuist test Domai…   │
///  └─┴────────────────────────────┘
/// ```
///
/// Decides nothing: `TouchBarBoard.Tile` has already worked out which line to
/// show and whether this session is asking for the user. This only draws it.
final class SessionTileView: NSScrubberItemView {
    static let identifier = NSUserInterfaceItemIdentifier("com.tddworks.claudebar.touchbar.tile")

    private let phaseBar = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    private enum Metrics {
        static let cornerRadius: CGFloat = 4
        static let phaseBarWidth: CGFloat = 3
        static let padding: CGFloat = 5
        /// Enough for about nine characters, which is where repository names
        /// start to collide with the percentage pinned to the right.
        static let nameWidth: CGFloat = 60
        static let lineSpacing: CGFloat = 1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionTileView is never loaded from a nib")
    }

    func configure(with tile: TouchBarBoard.Tile, palette: TouchBarPalette) {
        let isEnded = tile.phase == .ended

        layer?.backgroundColor = (tile.isAttention ? palette.attentionTileFill : palette.tileFill).cgColor
        phaseBar.layer?.backgroundColor = palette.color(for: tile.phase).cgColor

        nameLabel.stringValue = tile.name
        nameLabel.textColor = tile.isAttention
            ? palette.color(for: .awaitingInput)
            : (isEnded ? palette.endedPrimaryText : palette.primaryText)

        if let percent = tile.contextPercent {
            contextLabel.stringValue = "\(Int(percent.rounded()))%"
            contextLabel.textColor = isEnded
                ? palette.endedPrimaryText
                : palette.contextColor(forPercent: percent)
        } else {
            // A session whose transcript has not been read yet has no number to
            // show, and a zero would be a lie.
            contextLabel.stringValue = "–"
            contextLabel.textColor = palette.endedSecondaryText
        }

        detailLabel.stringValue = tile.text
        detailLabel.textColor = isEnded ? palette.endedSecondaryText : palette.secondaryText
        detailLabel.toolTip = tile.text
    }

    // MARK: - Private

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true

        phaseBar.wantsLayer = true
        nameLabel.font = TouchBarFont.tileName
        nameLabel.lineBreakMode = .byTruncatingTail
        contextLabel.font = TouchBarFont.tileContext
        contextLabel.alignment = .right
        detailLabel.font = TouchBarFont.tileDetail
        detailLabel.lineBreakMode = .byTruncatingTail

        for view in [phaseBar, nameLabel, contextLabel, detailLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        // The name gives way before the percentage does: a truncated repository
        // name is still recognisable, a truncated number is a wrong number.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contextLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            phaseBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            phaseBar.topAnchor.constraint(equalTo: topAnchor),
            phaseBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            phaseBar.widthAnchor.constraint(equalToConstant: Metrics.phaseBarWidth),

            nameLabel.leadingAnchor.constraint(
                equalTo: phaseBar.trailingAnchor,
                constant: Metrics.padding
            ),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding / 2),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.nameWidth),

            contextLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor,
                constant: 2
            ),
            contextLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Metrics.padding
            ),
            contextLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Metrics.padding
            ),
            detailLabel.topAnchor.constraint(
                equalTo: nameLabel.bottomAnchor,
                constant: Metrics.lineSpacing
            ),
        ])
    }
}

/// The board's stand-in when there are no sessions at all. Not a tile: it says
/// why the area is empty, which a tile shape would only confuse.
final class TouchBarEmptyStateView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(message: String, palette: TouchBarPalette) {
        super.init(frame: .zero)
        label.font = TouchBarFont.emptyState
        label.textColor = palette.endedSecondaryText
        label.stringValue = message
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TouchBarEmptyStateView is never loaded from a nib")
    }

    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}
#endif
