#if ENABLE_TOUCHBAR
import AppKit
import Domain
import Infrastructure

/// Turns monitor state into a Touch Bar board, and the board's taps back into
/// monitor calls.
///
/// The same shape as `NotchWindowDriver`: an outer sync on the enable setting
/// that brings the controller up and down, and an inner sync that reads
/// everything the board depends on and pushes one Equatable value at it. The
/// Touch Bar is a view onto `QuotaMonitor` and `SessionMonitor`, never a second
/// source of truth.
@MainActor
final class TouchBarDriver {
    private let monitor: QuotaMonitor
    private let sessionMonitor: SessionMonitor
    private let settings: AppSettings
    private let usageSync: SessionUsageSync
    private let controller: TouchBarController

    private var enabledSync: ObservationRenderSync<Bool>?
    private var contentSync: ObservationRenderSync<TouchBarContent>?
    private var expiryTimer: Timer?

    private enum Timing {
        /// Sessions expire by the clock, not by anything observable, so
        /// something has to tick. A minute is well inside the ten the board
        /// keeps a finished session for.
        static let expiryInterval: TimeInterval = 60
    }

    /// The providers the board reads. Also the pair a tap on the quota column
    /// refreshes.
    private static let boardProviderIds = ["claude", "codex"]

    init(
        monitor: QuotaMonitor,
        sessionMonitor: SessionMonitor,
        settings: AppSettings,
        usageSync: SessionUsageSync
    ) {
        self.monitor = monitor
        self.sessionMonitor = sessionMonitor
        self.settings = settings
        self.usageSync = usageSync
        self.controller = TouchBarController(
            palette: TouchBarPalette.resolve(themeModeId: settings.themeMode)
        )
    }

    /// Defers every AppKit object past `didFinishLaunching`, for the same
    /// reason the notch does: building them during `App.init` upsets the
    /// MenuBarExtra hosting.
    func startWhenLaunched() {
        if NSApp?.isRunning == true {
            start()
            return
        }

        var observer: (any NSObjectProtocol)?
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            Task { @MainActor in self?.start() }
        }
    }

    // MARK: - Private

    private func start() {
        wireController()

        let sync = ObservationRenderSync<Bool>(
            read: { [settings] in settings.touchBarEnabled },
            render: { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    controller.start()
                    startContentSync()
                } else {
                    stopContentSync()
                    controller.stop()
                }
            }
        )
        enabledSync = sync
        sync.start()
    }

    private func wireController() {
        controller.onLayoutChange = { [weak self] layout in
            self?.settings.touchBarLayout = layout
        }

        controller.onRefreshRequested = { [weak self] in
            guard let self else { return }
            // Just the two the board shows. refreshAll would probe nineteen
            // providers to update five numbers.
            Task { await self.monitor.refresh(providerIds: Self.boardProviderIds) }
        }

        controller.onVisibilityChange = { [weak self] isVisible in
            // Transcripts are only worth following while someone can see the
            // result. Collapsed, the board costs nothing but hook events.
            self?.usageSync.setPolling(isVisible)
        }
    }

    private func startContentSync() {
        guard contentSync == nil else { return }

        let sync = ObservationRenderSync<TouchBarContent>(
            read: { [weak self] in self?.currentContent() ?? .empty },
            render: { [weak self] content in self?.controller.update(content) }
        )
        contentSync = sync
        sync.start()

        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: Timing.expiryInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.expireStaleSessions() }
        }
    }

    private func stopContentSync() {
        contentSync?.stop()
        contentSync = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        usageSync.setPolling(false)
    }

    /// Reads everything the board depends on. Every `@Observable` property
    /// touched here is what makes the next change re-render.
    private func currentContent() -> TouchBarContent {
        TouchBarContent(
            board: TouchBarBoard.build(
                sessions: sessionMonitor.sessions,
                // provider(for:) rather than quota(providerId:) — the latter
                // filters to enabled providers, and mixing the two would show a
                // number in the column and a dash in the tray for the same
                // provider.
                snapshot: { [monitor] in monitor.provider(for: $0)?.snapshot },
                traySelection: (
                    settings.menuBarPercentageProviderId,
                    settings.menuBarPercentageQuotaKey
                ),
                hooksEnabled: settings.hook.isHookEnabled(),
                // monitor.isRefreshing is true while ANY provider syncs, which
                // would dim these numbers because Bedrock is busy.
                isRefreshing: Self.boardProviderIds.contains { monitor.provider(for: $0)?.isSyncing == true },
                now: Date()
            ),
            themeModeId: settings.themeMode,
            layout: settings.touchBarLayout
        )
    }

    /// A finished session leaves the board on a clock, and a killed one is only
    /// noticed by having gone quiet — neither is an observable change, so this
    /// prunes and then re-reads.
    private func expireStaleSessions() {
        sessionMonitor.pruneStale(now: Date())
        contentSync?.refreshNow()
    }
}
#endif
