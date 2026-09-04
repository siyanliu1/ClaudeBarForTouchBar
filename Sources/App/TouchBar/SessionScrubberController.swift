#if ENABLE_TOUCHBAR
import AppKit
import Domain

/// Drives the horizontally scrolling strip of session tiles.
///
/// `NSScrubber` is the Touch Bar's own scroller, so it gets finger inertia and
/// the right feel for free — which a hand-rolled scroll view on a 30 pt strip
/// would not.
@MainActor
final class SessionScrubberController: NSObject, NSScrubberDataSource, NSScrubberDelegate {
    let scrubber = NSScrubber()

    private var tiles: [TouchBarBoard.Tile] = []
    private var palette: TouchBarPalette
    /// When the user last touched the strip. Yanking the view somewhere else
    /// mid-scroll is the rudest thing this could do, so auto-scroll waits.
    private var lastInteractionAt: Date?
    /// The session the strip was last pulled to the front for. A session stays
    /// blocked for as long as the user ignores it, and content updates keep
    /// arriving — without this, every context percentage tick would drag the
    /// strip back to the front while they were reading another tile.
    private var scrolledToAttentionFor: String?

    private enum Timing {
        /// How long after a scroll the board leaves the user's position alone.
        static let interactionGrace: TimeInterval = 2
    }

    init(palette: TouchBarPalette) {
        self.palette = palette
        super.init()

        let layout = NSScrubberFlowLayout()
        layout.itemSize = NSSize(
            width: TouchBarMetrics.tileWidth,
            height: TouchBarMetrics.tileHeight
        )
        layout.itemSpacing = TouchBarMetrics.tileGap

        scrubber.scrubberLayout = layout
        // Free, not item-by-item: this is a ticker to read, not a control to
        // pick from.
        scrubber.mode = .free
        scrubber.isContinuous = false
        // Arrow buttons would cost 32 pt of the session area, which is a third
        // of a tile.
        scrubber.showsArrowButtons = false
        scrubber.selectionBackgroundStyle = .none
        scrubber.selectionOverlayStyle = .none
        scrubber.floatsSelectionViews = false
        scrubber.backgroundColor = .clear
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.register(SessionTileView.self, forItemIdentifier: SessionTileView.identifier)
    }

    func update(tiles newTiles: [TouchBarBoard.Tile], palette newPalette: TouchBarPalette, now: Date) {
        let previous = tiles
        tiles = newTiles
        palette = newPalette

        if previous.map(\.id) == newTiles.map(\.id) {
            reloadChangedItems(from: previous, to: newTiles)
        } else {
            // ponytail: reloadData on any change to the set or the order of
            // sessions. NSScrubber can animate inserts and removals, but a
            // batch update whose index sets disagree with the data source is a
            // crash, and tiles reorder whenever a session changes phase — which
            // insert/remove cannot express at all. Worth revisiting with
            // performSequentialBatchUpdates plus moveItem once there is
            // hardware to watch it on.
            scrubber.reloadData()
        }

        scrollToAttentionIfWanted(now: now)
    }

    // MARK: - NSScrubberDataSource

    func numberOfItems(for scrubber: NSScrubber) -> Int {
        tiles.count
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: SessionTileView.identifier, owner: nil)
        guard let tile = view as? SessionTileView, tiles.indices.contains(index) else {
            return view ?? NSScrubberItemView()
        }
        tile.configure(with: tiles[index], palette: palette)
        return tile
    }

    // MARK: - NSScrubberDelegate

    func didBeginInteracting(with scrubber: NSScrubber) {
        lastInteractionAt = Date()
    }

    func didFinishInteracting(with scrubber: NSScrubber) {
        lastInteractionAt = Date()
    }

    // MARK: - Private

    private func reloadChangedItems(from previous: [TouchBarBoard.Tile], to current: [TouchBarBoard.Tile]) {
        let changed = zip(previous, current)
            .enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map(\.offset)
        guard !changed.isEmpty else { return }
        scrubber.reloadItems(at: IndexSet(changed))
    }

    /// Pulls a session that needs the user to the left edge, where the eye
    /// lands first. Once, when it takes the lead — not on every repaint for as
    /// long as it stays there — and never while the user is scrolling.
    private func scrollToAttentionIfWanted(now: Date) {
        guard let lead = tiles.first, lead.isAttention else {
            scrolledToAttentionFor = nil
            return
        }
        guard lead.id != scrolledToAttentionFor else { return }
        if let lastInteractionAt, now.timeIntervalSince(lastInteractionAt) < Timing.interactionGrace {
            return
        }
        scrolledToAttentionFor = lead.id
        scrubber.scrollItem(at: 0, to: .leading)
    }
}
#endif
