#if ENABLE_TOUCHBAR
import AppKit
import Domain
import Infrastructure

/// Owns the Touch Bar: the item in the Control Strip, the board that expands
/// from it, and the small state machine between them.
///
/// ```
///                tap tray                    tap toggle
///   ┌───────────┐ ────────► ┌──────────────┐ ◄────────► ┌──────────────┐
///   │ collapsed │           │ compact      │            │ wide         │
///   │ tray only │ ◄──────── │ placement 0  │            │ placement 1  │
///   └───────────┘  ✕ / tray └──────────────┘            └──────────────┘
///                                  ▲                            │
///                                  └────────── our own ✕ ───────┘
/// ```
///
/// Decides nothing about content: `TouchBarBoard` upstream has done that. This
/// puts pixels on the strip and reports what the user did with them.
@MainActor
final class TouchBarController {
    enum State: Equatable {
        case collapsed
        case presented(TouchBarLayout)
    }

    private(set) var state: State = .collapsed
    private(set) var isRunning = false

    /// The user toggled between compact and wide; the driver persists it.
    var onLayoutChange: ((TouchBarLayout) -> Void)?
    /// The user tapped the quota column.
    var onRefreshRequested: (() -> Void)?
    /// The board became visible or stopped being visible, however that
    /// happened. The driver starts and stops transcript polling on this.
    var onVisibilityChange: ((Bool) -> Void)?

    private static let trayIdentifier = NSTouchBarItem.Identifier(
        "com.tddworks.claudebar.touchbar.tray"
    )
    private static let boardIdentifier = NSTouchBarItem.Identifier(
        "com.tddworks.claudebar.touchbar.board"
    )

    private let trayItem = NSCustomTouchBarItem(identifier: TouchBarController.trayIdentifier)
    private let trayButton = NSButton()
    private var touchBar: NSTouchBar?
    private var boardView: TouchBarBoardView?
    private var visibilityTimer: Timer?
    private var wakeObserver: (any NSObjectProtocol)?

    private var content: TouchBarContent = .empty
    private var palette: TouchBarPalette

    private enum Timing {
        /// How often the board is asked whether it is still on screen.
        ///
        /// ponytail: a poll, not KVO. `NSTouchBar.isVisible` is not documented
        /// as observable and there is no hardware here to find out on, whereas
        /// a boolean read twice a second — only while the board is actually
        /// open — is certain and costs nothing. Swap it for KVO once someone
        /// has watched it fire.
        static let visibilityPoll: TimeInterval = 0.5
    }

    init(palette: TouchBarPalette) {
        self.palette = palette
        trayButton.bezelStyle = .rounded
        trayButton.imagePosition = .imageLeading
        trayButton.font = TouchBarFont.tray
        trayButton.target = self
        trayButton.action = #selector(trayTapped)
        trayItem.view = trayButton
    }

    // MARK: - Lifecycle

    /// Puts the tray item in the Control Strip. Idempotent.
    func start() {
        guard !isRunning else { return }
        guard TouchBarPrivateAPI.isAvailable else {
            AppLog.touchBar.warning("Touch Bar private interface unavailable; the board stays off")
            return
        }

        isRunning = true
        TouchBarPrivateAPI.addSystemTrayItem(trayItem)
        TouchBarPrivateAPI.setControlStripPresence(true, for: Self.trayIdentifier)
        observeWake()
        AppLog.touchBar.info("Touch Bar tray item registered")
    }

    /// Takes everything back down. Idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        dismiss()
        TouchBarPrivateAPI.setControlStripPresence(false, for: Self.trayIdentifier)
        TouchBarPrivateAPI.removeSystemTrayItem(trayItem)

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        AppLog.touchBar.info("Touch Bar tray item removed")
    }

    // MARK: - Presentation

    func present(_ layout: TouchBarLayout) {
        guard isRunning else { return }

        let bar = touchBar ?? makeTouchBar()
        touchBar = bar
        boardView?.update(
            board: content.board,
            layout: layout,
            palette: palette,
            now: Date()
        )

        // Compact sits inside the app region, where the system supplies the
        // close box; wide covers the whole bar and has to draw its own.
        TouchBarPrivateAPI.setShowsCloseBoxWhenFrontMost(!layout.drawsOwnCloseButton)
        TouchBarPrivateAPI.presentSystemModal(
            bar,
            placement: layout.placement,
            trayItemIdentifier: Self.trayIdentifier
        )

        state = .presented(layout)
        startWatchingVisibility()
        onVisibilityChange?(true)
        AppLog.touchBar.info("Touch Bar board presented (\(layout.rawValue))")
    }

    func dismiss() {
        guard case .presented = state, let touchBar else { return }
        TouchBarPrivateAPI.dismissSystemModal(touchBar)
        finishDismissal()
    }

    /// Swaps compact for wide, or back. The bar has to go away and come back:
    /// `placement` is fixed at presentation time.
    func toggle() {
        guard case .presented(let layout) = state else { return }
        let next = layout.toggled
        if let touchBar {
            TouchBarPrivateAPI.dismissSystemModal(touchBar)
        }
        state = .collapsed
        present(next)
        onLayoutChange?(next)
    }

    // MARK: - Content

    func update(_ newContent: TouchBarContent) {
        guard newContent != content else { return }
        let layoutChanged = newContent.layout != content.layout
        content = newContent
        palette = TouchBarPalette.resolve(themeModeId: newContent.themeModeId)

        updateTrayItem()

        // While collapsed there is no board to draw into; it is rebuilt from
        // `content` the moment it is presented.
        guard case .presented(let presentedLayout) = state else { return }
        boardView?.update(
            board: newContent.board,
            layout: layoutChanged ? newContent.layout : presentedLayout,
            palette: palette,
            now: Date()
        )
    }

    // MARK: - Private

    private func makeTouchBar() -> NSTouchBar {
        let view = TouchBarBoardView(layout: content.layout, palette: palette)
        view.onClose = { [weak self] in self?.dismiss() }
        view.onToggle = { [weak self] in self?.toggle() }
        view.onRefresh = { [weak self] in self?.onRefreshRequested?() }
        boardView = view

        let item = NSCustomTouchBarItem(identifier: Self.boardIdentifier)
        item.view = view

        let bar = NSTouchBar()
        bar.defaultItemIdentifiers = [Self.boardIdentifier]
        bar.templateItems = [item]
        return bar
    }

    private func updateTrayItem() {
        let tray = content.board.tray
        trayButton.attributedTitle = NSAttributedString(
            string: trayTitle(for: tray.quota),
            attributes: [
                .font: TouchBarFont.tray,
                .foregroundColor: trayTitleColor(for: tray.quota),
            ]
        )
        trayButton.image = dotImage(for: tray)
        trayButton.toolTip = "ClaudeBar — tap to open the Touch Bar board"
    }

    private func trayTitle(for quota: TouchBarBoard.QuotaCell) -> String {
        guard let percent = quota.percent else { return "–" }
        return "\(Int(percent.rounded()))%"
    }

    private func trayTitleColor(for quota: TouchBarBoard.QuotaCell) -> NSColor {
        guard let status = quota.status else { return palette.endedSecondaryText }
        return palette.color(for: status)
    }

    /// The dot takes the leading session's phase, and falls back to the
    /// number's own status when nothing is running — so the Control Strip
    /// always says something rather than showing a grey blob.
    private func dotImage(for tray: TouchBarBoard.Tray) -> NSImage {
        let color: NSColor = if let phase = tray.phase {
            palette.color(for: phase)
        } else if let status = tray.quota.status {
            palette.color(for: status)
        } else {
            palette.endedSecondaryText
        }

        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        // Template images are recoloured by the system, which would erase the
        // one thing this image carries.
        image.isTemplate = false
        return image
    }

    private func startWatchingVisibility() {
        visibilityTimer?.invalidate()
        visibilityTimer = Timer.scheduledTimer(
            withTimeInterval: Timing.visibilityPoll,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkVisibility() }
        }
    }

    /// The board can go away without us: the system close box, another app
    /// presenting its own modal bar, the display sleeping. Noticing matters
    /// because polling and animation should stop with it.
    private func checkVisibility() {
        guard case .presented = state, let touchBar else { return }
        guard !touchBar.isVisible else { return }
        AppLog.touchBar.info("Touch Bar board was dismissed from outside")
        finishDismissal()
    }

    private func finishDismissal() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        state = .collapsed
        onVisibilityChange?(false)
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertTrayPresence() }
        }
    }

    /// Sleep can evict the tray item, and nothing tells us when it does. The
    /// call is idempotent, so re-asserting costs nothing when it survived.
    private func reassertTrayPresence() {
        guard isRunning else { return }
        TouchBarPrivateAPI.setControlStripPresence(true, for: Self.trayIdentifier)
    }

    @objc private func trayTapped() {
        switch state {
        case .collapsed:
            present(content.layout)
        case .presented:
            dismiss()
        }
    }
}
#endif
