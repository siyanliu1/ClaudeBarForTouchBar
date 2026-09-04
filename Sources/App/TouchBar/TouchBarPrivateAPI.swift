#if ENABLE_TOUCHBAR
import AppKit
import Infrastructure

/// The only file in ClaudeBar that touches private Apple interfaces.
///
/// A background `LSUIElement` app cannot reach the Touch Bar through public
/// AppKit: `NSTouchBar` only shows for the frontmost application, and ClaudeBar
/// is never frontmost. Every tool that puts its own content on the bar — Pock,
/// MTMR, BetterTouchTool — goes through DFRFoundation and a handful of private
/// `NSTouchBar` class methods instead, and so does this.
///
/// Everything is resolved at runtime, by `dlsym` for the C functions and by
/// `responds(to:)` for the Objective-C class methods. Nothing is linked, so a
/// macOS that has dropped a symbol leaves the feature switched off rather than
/// refusing to launch. `isAvailable` is the one question callers need to ask.
///
/// This is why the whole Touch Bar feature sits behind `ENABLE_TOUCHBAR`:
/// App Review rejects private API under guideline 2.5.1, and the Mac App Store
/// workflow blanks the compilation conditions, so those builds drop it.
@MainActor
enum TouchBarPrivateAPI {
    /// Whether the private interface is complete enough to use. False leaves
    /// every call below a no-op, so callers can ask once and then stop
    /// worrying.
    static var isAvailable: Bool {
        setPresence != nil
            && showsCloseBox != nil
            && Selectors.all.allSatisfy(responds(to:))
    }

    // MARK: - Control Strip tray item

    /// Registers a tray item with the Touch Bar service. It does not appear
    /// until `setControlStripPresence(true, …)` follows.
    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        perform(Selectors.addSystemTrayItem, on: NSTouchBarItem.self, with: item)
    }

    static func removeSystemTrayItem(_ item: NSTouchBarItem) {
        perform(Selectors.removeSystemTrayItem, on: NSTouchBarItem.self, with: item)
    }

    /// Shows or hides the tray item in the Control Strip.
    ///
    /// Community reports — and the spike this was built from — agree that a
    /// tray item is ignored unless the process runs from a real `.app` bundle.
    /// Nothing here can detect that; it simply will not appear.
    static func setControlStripPresence(_ present: Bool, for identifier: NSTouchBarItem.Identifier) {
        setPresence?(identifier.rawValue as NSString, present)
    }

    // MARK: - System modal bar

    /// Presents `bar` over whatever the frontmost app is showing.
    ///
    /// `placement` is the difference between the board's two shapes: 0 leaves
    /// the bar inside the app region with the Control Strip still visible, 1
    /// takes the full width and hides the Control Strip — and with it our own
    /// tray item, which is why the wide layout has to draw its own way out.
    static func presentSystemModal(
        _ bar: NSTouchBar,
        placement: Int,
        trayItemIdentifier: NSTouchBarItem.Identifier
    ) {
        guard let objcMsgSend, responds(to: Selectors.presentSystemModal) else { return }
        let present = unsafeBitCast(objcMsgSend, to: PresentWithPlacement.self)
        present(
            NSTouchBar.self,
            Selectors.presentSystemModal,
            bar,
            placement,
            trayItemIdentifier.rawValue as NSString
        )
    }

    /// Takes the bar away entirely. The tray item stays.
    static func dismissSystemModal(_ bar: NSTouchBar) {
        perform(Selectors.dismissSystemModal, on: NSTouchBar.self, with: bar)
    }

    /// Collapses the bar back into its tray item.
    static func minimizeSystemModal(_ bar: NSTouchBar) {
        perform(Selectors.minimizeSystemModal, on: NSTouchBar.self, with: bar)
    }

    /// Whether the system draws its own close box at the left of a modal bar.
    static func setShowsCloseBoxWhenFrontMost(_ shows: Bool) {
        showsCloseBox?(shows)
    }

    // MARK: - Selectors

    private enum Selectors {
        // The 10.13-era `…FunctionBar…` spellings are gone on macOS 26; only
        // these remain, so there is no legacy fallback to keep.
        static let addSystemTrayItem = NSSelectorFromString("addSystemTrayItem:")
        static let removeSystemTrayItem = NSSelectorFromString("removeSystemTrayItem:")
        static let presentSystemModal = NSSelectorFromString(
            "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
        )
        static let dismissSystemModal = NSSelectorFromString("dismissSystemModalTouchBar:")
        static let minimizeSystemModal = NSSelectorFromString("minimizeSystemModalTouchBar:")

        static let all = [
            addSystemTrayItem,
            removeSystemTrayItem,
            presentSystemModal,
            dismissSystemModal,
            minimizeSystemModal,
        ]
    }

    // MARK: - Runtime lookup

    private typealias SetPresenceFunction = @convention(c) (NSString, Bool) -> Void
    private typealias ShowsCloseBoxFunction = @convention(c) (Bool) -> Void

    /// `objc_msgSend` cast to the one signature that needs three arguments;
    /// `perform(_:with:with:)` tops out at two.
    private typealias PresentWithPlacement =
        @convention(c) (AnyObject, Selector, AnyObject, Int, AnyObject) -> Void

    private static let framework: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
        let handle = dlopen(path, RTLD_NOW)
        if handle == nil {
            AppLog.touchBar.warning("DFRFoundation is not loadable; the Touch Bar board is unavailable")
        }
        return handle
    }()

    private static let setPresence: SetPresenceFunction? =
        function("DFRElementSetControlStripPresenceForIdentifier")

    private static let showsCloseBox: ShowsCloseBoxFunction? =
        function("DFRSystemModalShowsCloseBoxWhenFrontMost")

    private static func function<T>(_ name: String) -> T? {
        guard let framework, let symbol = dlsym(framework, name) else {
            AppLog.touchBar.warning("DFRFoundation has no \(name); the Touch Bar board is unavailable")
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// The default search order, for `objc_msgSend` — which Swift will not name
    /// directly.
    private static let objcMsgSend: UnsafeMutableRawPointer? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")

    private static func responds(to selector: Selector) -> Bool {
        (NSTouchBar.self as AnyObject).responds(to: selector)
            || (NSTouchBarItem.self as AnyObject).responds(to: selector)
    }

    private static func perform(_ selector: Selector, on target: AnyObject, with argument: AnyObject) {
        guard target.responds(to: selector) else {
            AppLog.touchBar.warning("\(NSStringFromSelector(selector)) is gone; the Touch Bar board is unavailable")
            return
        }
        _ = target.perform(selector, with: argument)
    }
}
#endif
