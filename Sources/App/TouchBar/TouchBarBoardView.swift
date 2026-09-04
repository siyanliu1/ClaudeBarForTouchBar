#if ENABLE_TOUCHBAR
import AppKit
import Domain

/// The whole board, as one view.
///
/// ```
///  compact │ 6 │⟷ 32│ 6 │  sessions 440  │ 6 │ quota 125 │ 6 │        = 621
///  wide    │ 6 │ ✕ 40 │ 6 │⟷ 32│ 6 │ sessions 777 │ 6 │ quota 125 │ 6 │ = 1004
/// ```
///
/// One `NSCustomTouchBarItem` holds this rather than several system items,
/// because the spacing between system items is not controllable and compact
/// mode has only 6 pt of slack to give away.
@MainActor
final class TouchBarBoardView: NSView {
    private let scrubberController: SessionScrubberController
    private let quotaColumn = QuotaColumnView()
    private let emptyState: TouchBarEmptyStateView
    private let stack = NSStackView()
    private let closeButton = NSButton()
    private let toggleButton = NSButton()

    private var layout: TouchBarLayout
    private var palette: TouchBarPalette
    private var boardWidthConstraint: NSLayoutConstraint?
    private var sessionAreaWidthConstraint: NSLayoutConstraint?

    var onClose: (() -> Void)?
    var onToggle: (() -> Void)?
    var onRefresh: (() -> Void)? {
        get { quotaColumn.onTap }
        set { quotaColumn.onTap = newValue }
    }

    init(layout: TouchBarLayout, palette: TouchBarPalette) {
        self.layout = layout
        self.palette = palette
        self.scrubberController = SessionScrubberController(palette: palette)
        self.emptyState = TouchBarEmptyStateView(message: "", palette: palette)
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TouchBarBoardView is never loaded from a nib")
    }

    func update(board: TouchBarBoard, layout newLayout: TouchBarLayout, palette newPalette: TouchBarPalette, now: Date) {
        palette = newPalette
        apply(layout: newLayout)

        scrubberController.update(tiles: board.tiles, palette: newPalette, now: now)
        quotaColumn.configure(with: board, palette: newPalette)

        // The empty state replaces the strip rather than sitting inside it: an
        // explanation shaped like a tile reads as a session that went wrong.
        let isEmpty = board.emptyMessage != nil
        emptyState.message = board.emptyMessage ?? ""
        emptyState.isHidden = !isEmpty
        scrubberController.scrubber.isHidden = isEmpty
    }

    // MARK: - Private

    private func build() {
        wantsLayer = true
        // Every colour in here is either fixed or semantic, and a semantic
        // NSColor resolves against the appearance current at draw time. The bar
        // is black whatever the rest of the Mac is doing, so pin it.
        appearance = NSAppearance(named: .darkAqua)

        configure(button: closeButton, symbol: "xmark", description: "Close the Touch Bar board")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        toggleButton.target = self
        toggleButton.action = #selector(toggleTapped)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = TouchBarMetrics.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: TouchBarMetrics.edgeInset,
            bottom: 0,
            right: TouchBarMetrics.edgeInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        let sessionArea = NSView()
        sessionArea.translatesAutoresizingMaskIntoConstraints = false
        for view in [scrubberController.scrubber, emptyState] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sessionArea.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: sessionArea.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: sessionArea.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: sessionArea.centerYAnchor),
            ])
        }
        scrubberController.scrubber.heightAnchor
            .constraint(equalToConstant: TouchBarMetrics.tileHeight).isActive = true

        stack.addArrangedSubview(closeButton)
        stack.addArrangedSubview(toggleButton)
        stack.addArrangedSubview(sessionArea)
        stack.addArrangedSubview(quotaColumn)
        addSubview(stack)

        quotaColumn.translatesAutoresizingMaskIntoConstraints = false

        let boardWidth = widthAnchor.constraint(equalToConstant: layout.boardWidth)
        let sessionWidth = sessionArea.widthAnchor.constraint(equalToConstant: layout.sessionAreaWidth)
        boardWidthConstraint = boardWidth
        sessionAreaWidthConstraint = sessionWidth

        NSLayoutConstraint.activate([
            boardWidth,
            sessionWidth,
            heightAnchor.constraint(equalToConstant: TouchBarMetrics.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: TouchBarMetrics.closeButtonWidth),
            toggleButton.widthAnchor.constraint(equalToConstant: TouchBarMetrics.toggleButtonWidth),
            quotaColumn.widthAnchor.constraint(equalToConstant: TouchBarMetrics.quotaColumnWidth),
        ])

        apply(layout: layout)
    }

    private func apply(layout newLayout: TouchBarLayout) {
        layout = newLayout
        boardWidthConstraint?.constant = newLayout.boardWidth
        sessionAreaWidthConstraint?.constant = newLayout.sessionAreaWidth

        // Compact keeps the system's close box, off to the left of anything we
        // lay out, so drawing a second one would be two ways to do the same
        // thing 6 pt apart.
        closeButton.isHidden = !newLayout.drawsOwnCloseButton

        configure(
            button: toggleButton,
            symbol: newLayout.toggleSymbolName,
            description: newLayout.toggleDescription
        )
    }

    private func configure(button: NSButton, symbol: String, description: String) {
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = description
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func toggleTapped() {
        onToggle?()
    }
}

/// The AppKit half of the layout: the private `placement` argument and the
/// symbols for the toggle. Kept out of Domain, where the measurements live,
/// because these mean nothing without AppKit.
extension TouchBarLayout {
    /// What `presentSystemModalTouchBar:placement:…` is given. 0 leaves the
    /// Control Strip alone; 1 takes the whole bar.
    var placement: Int {
        switch self {
        case .compact: 0
        case .wide: 1
        }
    }

    /// The toggle shows where it would go, not where it is.
    var toggleSymbolName: String {
        switch self {
        case .compact: "arrow.left.and.right"
        case .wide: "arrow.right.and.line.vertical.and.arrow.left"
        }
    }

    var toggleDescription: String {
        switch self {
        case .compact: "Widen the board to the whole Touch Bar"
        case .wide: "Shrink the board and bring the Control Strip back"
        }
    }
}
#endif
