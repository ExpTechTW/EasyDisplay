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
    /// Whether EasyDisplay may take the brightness keys (Accessibility access).
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
                nits: display.isLit ? display.nits : nil,
                sensorsAreCurrent: display.sensorsAreCurrent,
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
        Log.info("keys", "輔助使用權限：\(BrightnessKeys.isTrusted ? "已允許" : "未允許")")
        Log.info("app", "設定：增亮時自動亮度\(on(settings.boostAutoBrightness))、啟動時恢復增亮\(on(settings.restoreBoostAtLaunch))"
            + "（上次結束時\(settings.boostWasOn ? "增亮中" : "沒有增亮")）、處理亮度鍵\(on(settings.handlesBrightnessKeys))、"
            + "紀錄保留 \(settings.monitorRetentionDays) 天、已學習 \(settings.autoCurve.points.count) 個亮度")
        // Without it macOS keeps the keys, shows its own indicator, and moves the slider boost has pinned: ask once
        // per launch, which shows macOS's prompt until EasyDisplay is in the Accessibility list.
        if settings.handlesBrightnessKeys, !BrightnessKeys.isTrusted { BrightnessKeys.requestAccess() }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadDisplays()
                Task { await self.refreshAll() }
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Log.info("app", "系統睡眠")
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Log.info("app", "從睡眠喚醒")
        }

        Task {
            if BoostRestoreState.load() != nil { Log.warn("boost", "上次沒有正常結束，先還原留下的增亮") }
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
        Log.info("app", "結束")
        await builtIn?.restoreLeftoverBoost()
        sensors.flush()
        Log.flush()
    }

    /// Takes a brightness key for the display in use, when EasyDisplay can change it.
    private func brightnessKey(up: Bool, fine: Bool, pressed: Bool) -> Bool {
        guard settings.handlesBrightnessKeys, let id = FocusedDisplay.current() else { return false }
        // A sixteenth of the range per press, a quarter of that with ⌥⇧, as macOS steps.
        let step = (fine ? 0.25 : 1) * BuiltInDisplay.keyStep * (up ? 1 : -1)
        if let builtIn, builtInOnline, builtIn.id == id {
            if pressed {
                Log.info("keys", "亮度鍵\(up ? "調亮" : "調暗")\(fine ? "（微調）" : "")：\(builtIn.name)")
                builtIn.brightnessKey(step: step)
                BrightnessOSD.shared.show(.builtIn(builtIn))
            }
            return true
        }
        if let external = externals.first(where: { $0.id == id }), external.isControllable {
            if pressed {
                Log.info("keys", "亮度鍵\(up ? "調亮" : "調暗")\(fine ? "（微調）" : "")：\(external.name)")
                external.brightnessKey(step: step)
                BrightnessOSD.shared.show(.external(external))
            }
            return true
        }
        // A display EasyDisplay can't dim: macOS gets the key, and does what it can.
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
        let launching = builtIn == nil && externals.isEmpty && !builtInOnline
        if !launching, (builtInID != nil) != builtInOnline {
            Log.info("display", builtInID != nil ? "內建螢幕開啟" : "內建螢幕關閉（闔上或只用外接螢幕）")
        }
        builtInOnline = builtInID != nil
        if let builtInID, builtIn?.id != builtInID {
            builtIn = BuiltInDisplay(id: builtInID, name: screenName(builtInID) ?? L("display.builtin"), settings: settings)
            builtIn?.observesSlider = trayVisible
        }
        let before = externals
        externals = online.filter { CGDisplayIsBuiltin($0) == 0 }.map { id in
            externals.first { $0.id == id } ?? ExternalDisplay(id: id, name: screenName(id) ?? LF("display.external", Int(id)))
        }
        if launching {
            let names = (builtInOnline ? [builtIn?.name ?? L("display.builtin")] : []) + externals.map(\.name)
            Log.info("display", "螢幕：\(names.isEmpty ? "無" : names.joined(separator: "、"))")
            return
        }
        for display in externals where !before.contains(where: { $0.id == display.id }) { Log.info("display", "連接外接螢幕 \(display.name)") }
        for display in before where !externals.contains(where: { $0.id == display.id }) { Log.info("display", "中斷外接螢幕 \(display.name)") }
    }

    private func on(_ value: Bool) -> String { value ? "開" : "關" }

    private func screenName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { $0.displayID == id }?.localizedName
    }
}
