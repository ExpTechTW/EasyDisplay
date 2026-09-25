import AppKit
import Observation

/// Tracks the connected displays, hands them the sensor monitor's samples and routes the brightness keys.
@MainActor
@Observable
final class DisplayManager {
    /// Kept while the lid is closed, so a boost can still be restored.
    private(set) var builtIn: BuiltInDisplay?
    private(set) var builtInOnline = false
    private(set) var externals: [ExternalDisplay] = []
    let sensors: SensorMonitor
    let settings: AppSettings
    @ObservationIgnored let brightnessKeys = BrightnessKeys()
    /// Whether EazyDisplay may take the brightness keys (Accessibility access).
    private(set) var keysAvailable = BrightnessKeys.isTrusted
    /// The tray is open: only then does the built-in display poll macOS's slider for changes made elsewhere.
    var trayVisible = false {
        didSet { builtIn?.observesSlider = trayVisible }
    }

    init(settings: AppSettings, database: MonitorDatabase?) {
        self.settings = settings
        sensors = SensorMonitor(database: database) { (settings.monitorRetention, settings.monitorRetention) }
        reloadDisplays()
        sensors.reading = { [weak self] in
            guard let self, let display = self.builtIn, self.builtInOnline else { return DisplayReading() }
            return DisplayReading(
                nits: display.nits,
                headroom: display.headroom,
                boosted: display.boost == .on,
                thermalLimited: display.thermalLimited,
                autoBrightness: display.autoBrightnessActive
            )
        }
        sensors.onSample = { [weak self] in self?.sampled($0) }
        sensors.start()
        brightnessKeys.onKey = { [weak self] up, fine, pressed in
            self?.brightnessKey(up: up, fine: fine, pressed: pressed) ?? false
        }
        brightnessKeys.start()
        log.info("accessibility: \(BrightnessKeys.isTrusted ? "allowed" : "not allowed", privacy: .public)")
        // Without it macOS keeps the keys, shows its own indicator, and moves the slider boost has pinned: ask once
        // per launch, which shows macOS's prompt until EazyDisplay is in the Accessibility list.
        if settings.handlesBrightnessKeys, !BrightnessKeys.isTrusted { BrightnessKeys.requestAccess() }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadDisplays()
                Task { await self.refreshAll() }
            }
        }

        Task {
            await builtIn?.restoreLeftoverBoost()
            await refreshAll()
            if settings.restoreBoostAtLaunch, settings.boostWasOn { await builtIn?.setBoost(true) }
        }
    }

    private func sampled(_ sample: SensorSample) {
        if builtInOnline { builtIn?.update(sample) }
        // Access given in System Settings shows up without a relaunch.
        if !keysAvailable, BrightnessKeys.isTrusted {
            keysAvailable = brightnessKeys.start()
        }
    }

    /// Undoes a boost and writes the last seconds of samples, before the app quits.
    func prepareToQuit() async {
        await builtIn?.restoreLeftoverBoost()
        sensors.flush()
    }

    /// Takes a brightness key for the display in use, when EazyDisplay can change it.
    private func brightnessKey(up: Bool, fine: Bool, pressed: Bool) -> Bool {
        guard settings.handlesBrightnessKeys, let id = FocusedDisplay.current() else { return false }
        // A sixteenth of the range per press, a quarter of that with ⌥⇧, as macOS steps.
        let step = (fine ? 0.25 : 1) * BuiltInDisplay.keyStep * (up ? 1 : -1)
        if let builtIn, builtInOnline, builtIn.id == id {
            if pressed {
                log.debug("brightness key \(up ? "up" : "down", privacy: .public) on the built-in display")
                builtIn.brightnessKey(step: step)
                BrightnessOSD.shared.show(.builtIn(builtIn))
            }
            return true
        }
        if let external = externals.first(where: { $0.id == id }), external.isControllable {
            if pressed {
                external.brightnessKey(step: step)
                BrightnessOSD.shared.show(.external(external))
            }
            return true
        }
        // A display EazyDisplay can't dim: macOS gets the key, and does what it can.
        return false
    }

    func refreshAll() async {
        await builtIn?.refresh()
        for display in externals { await display.refresh() }
    }

    private func reloadDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let online = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        let builtInID = online.first { CGDisplayIsBuiltin($0) != 0 }
        builtInOnline = builtInID != nil
        if let builtInID, builtIn?.id != builtInID {
            builtIn = BuiltInDisplay(id: builtInID, name: screenName(builtInID) ?? L("display.builtin"), settings: settings)
            builtIn?.observesSlider = trayVisible
        }
        externals = online.filter { CGDisplayIsBuiltin($0) == 0 }.map { id in
            externals.first { $0.id == id } ?? ExternalDisplay(id: id, name: screenName(id) ?? LF("display.external", Int(id)))
        }
    }

    private func screenName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { $0.displayID == id }?.localizedName
    }
}
