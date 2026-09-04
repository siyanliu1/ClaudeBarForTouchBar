import Testing
@testable import Domain

@Suite
struct TouchBarLayoutTests {

    // MARK: - Persistence

    @Test
    func `layouts persist under their own names`() {
        #expect(TouchBarLayout.compact.rawValue == "compact")
        #expect(TouchBarLayout.wide.rawValue == "wide")
    }

    @Test
    func `compact is what an unconfigured install gets`() {
        #expect(TouchBarLayout.default == .compact)
    }

    @Test
    func `a layout this build does not know falls back to compact`() {
        // A settings file from a newer build must never break this one.
        #expect(TouchBarLayout(storedRawValue: "tall") == .compact)
        #expect(TouchBarLayout(storedRawValue: "") == .compact)
    }

    @Test
    func `each layout toggles to the other`() {
        #expect(TouchBarLayout.compact.toggled == .wide)
        #expect(TouchBarLayout.wide.toggled == .compact)
    }

    // MARK: - Geometry

    @Test
    func `every piece of the board adds up to the width the board owns`() {
        // If these disagree the bar either clips its last item or leaves a gap,
        // and neither shows up anywhere but on real hardware.
        for layout in TouchBarLayout.allCases {
            #expect(layout.laidOutWidth == layout.boardWidth)
        }
    }

    @Test
    func `the measured widths are the ones taken off the hardware`() {
        #expect(TouchBarLayout.compact.boardWidth == 621)
        #expect(TouchBarLayout.wide.boardWidth == 1004)
    }

    @Test
    func `only the wide layout has to draw its own way out`() {
        // Compact keeps the system close box; wide hides the Control Strip.
        #expect(TouchBarLayout.compact.drawsOwnCloseButton == false)
        #expect(TouchBarLayout.wide.drawsOwnCloseButton)
    }

    @Test
    func `the session area shows four tiles compact and seven wide`() {
        #expect(TouchBarLayout.compact.visibleTileCount == 4)
        #expect(TouchBarLayout.wide.visibleTileCount == 7)
    }

    @Test
    func `the visible tiles and their gaps fit inside the session area`() {
        for layout in TouchBarLayout.allCases {
            let count = Double(layout.visibleTileCount)
            let used = count * TouchBarMetrics.tileWidth
                + (count - 1) * TouchBarMetrics.tileGap
            #expect(used <= layout.sessionAreaWidth)
        }
    }

    @Test
    func `one more tile would not fit either layout`() {
        for layout in TouchBarLayout.allCases {
            let count = Double(layout.visibleTileCount + 1)
            let used = count * TouchBarMetrics.tileWidth
                + (count - 1) * TouchBarMetrics.tileGap
            #expect(used > layout.sessionAreaWidth)
        }
    }

    @Test
    func `an area too small for a single tile shows none`() {
        #expect(TouchBarMetrics.tileCount(fitting: 0) == 0)
        #expect(TouchBarMetrics.tileCount(fitting: 103) == 0)
        #expect(TouchBarMetrics.tileCount(fitting: 104) == 1)
    }
}
