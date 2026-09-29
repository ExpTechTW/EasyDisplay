import AppKit
import Observation

/// What turning boost off puts back. Persisted, so a crash or force-quit while boosted is
/// undone at the next launch.
struct BoostRestoreState: Codable, Sendable {
    let presetIndex: Int
    let slider: Double
    let autoBrightness: Bool
    let caps: [String: Int]

    private static let defaultsKey = "BoostRestoreState"

    static func load() -> BoostRestoreState? {
        UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// The built-in XDR panel. Boost drives its backlight directly past the 600-nit SDR limit.
///
/// Boosting turns the system's auto-brightness off, because corebrightnessd would fight the direct writes. With
/// boosted auto-brightness on, EasyDisplay does its own from the ambient light sensor instead: an `AmbientFilter`
/// decides which light level to follow, and the `AutoBrightnessCurve` the slider and keys have taught gives the
/// brightness for it.
///
/// While boosted the system slider is pinned at its maximum. In the P3-600 preset that makes corebrightnessd's SDR
/// white 600 nits, the preset's HDR peak, so its EDR headroom stays at 1: an app asking for HDR headroom no longer
/// starts an EDR ramp, which rewrote the backlight every frame for about two seconds (and dimmed SDR pixels to make
/// room) while EasyDisplay kept writing it back, a visible flicker. Brightness keys reach EasyDisplay directly.
///
/// This decides where the backlight should be, once a second with the sensor sample and at once on the slider or a
/// key; the `BacklightDriver` holds it there.
@MainActor
@Observable
final class BuiltInDisplay: Identifiable {
    enum Boost {
        case off, enabling, on, disabling
    }

    /// Ceiling for boosted SDR white. Full-screen white on this panel is power-limited at about
    /// 1100 nits, so staying at 1000 keeps brightness independent of what is on screen.
    nonisolated static let maxBoostNits = 1000.0
    nonisolated static let minBoostNits = 2.0
    /// Direct backlight writes bypass corebrightnessd's thermal management, so EasyDisplay applies its own, well
    /// before the panel gets hot: the boost ceiling falls linearly between these points of the hottest display sensor
    /// (smoothed), from the full 1000 nits to 600, and stays there.
    ///
    /// 600 nits is the panel's own SDR maximum, which macOS shows under any load: a limit below it would only dim the
    /// display further than macOS itself does. It would, too, since the hottest sensors sit along the hinge, where the
    /// processor's exhaust warms the panel (measured: 2.6 °C in 90 s of 45 W, with the backlight unchanged), so they
    /// read 46 to 51 °C under heavy load at any brightness.
    static let thermalCurve: [(celsius: Double, nits: Double)] = [(42, maxBoostNits), (45, 600)]
    /// Where the system slider stays while boosted.
    nonisolated static let pinnedSlider = 1.0
    /// One press of a brightness key, as macOS steps its own slider.
    static let keyStep = 1.0 / 16
    /// A burst of key presses is one choice, as in Apple's patent on learning auto-brightness: the point is learned
    /// this long after the last adjustment.
    static let learnAfter: TimeInterval = 3
    /// The display's temperature sensors and the ambient light sensor stop updating while the backlight is off: they
    /// hold their last reading, or read 0 lux. Back on, they take a while to catch up (measured: about 7 seconds for
    /// the temperature, 11 for the light).
    static let sensorsCatchUp: TimeInterval = 15

    let id: CGDirectDisplayID
    let name: String
    @ObservationIgnored let settings: AppSettings

    /// Slider position, 0…1. Unboosted, the system slider. Boosted, the target as `boostNits(forSlider:)`.
    private(set) var slider = 0.0
    private(set) var autoBrightness = false
    private(set) var boost = Boost.off
    /// The most boost may drive now, from the display's temperature.
    private(set) var thermalCeiling = maxBoostNits
    private(set) var presetName = ""
    private(set) var error: String?
    /// SDR white while not boosted: the backlight level divided by the EDR headroom.
    private(set) var measuredNits = 0.0
    /// While boosted: the backlight level, as the driver last reported it.
    private(set) var drivenNits = 0.0
    /// The backlight is on. Off (display sleep, the lid closed), there's no brightness to record.
    private(set) var isLit = true
    @ObservationIgnored private var litSince = Date.distantPast
    /// The ambient light level followed, while boosted.
    private(set) var lux: Double?
    /// A brightness just chosen with the slider or keys, shown at once and learned once it has settled.
    private(set) var manualNits: Double?
    /// Smoothed hottest display temperature.
    private(set) var celsius: Double?

    /// Set while something shows the slider (the tray): only then is macOS's slider worth polling unboosted.
    @ObservationIgnored var observesSlider = false

    @ObservationIgnored private let framebuffer: BuiltInFramebuffer
    @ObservationIgnored private let sliderWriter: LatestValueWriter<Double>
    @ObservationIgnored private lazy var driver = BacklightDriver(framebuffer: framebuffer) { [weak self] level in
        self?.drivenNits = level
    } onEvent: { [weak self] event in
        self?.driverReported(event)
    }
    @ObservationIgnored private var ambient = AmbientFilter()
    /// The goal and pace last handed to the driver, so it's only told about changes.
    @ObservationIgnored private var steered: (nits: Double, pace: BacklightDriver.Pace)?
    /// The last slider or key change, which eases in quickly even while following the ambient light.
    @ObservationIgnored private var lastManualChange = Date.distantPast
    /// Waiting for macOS's slider to read back pinned; until then a lower reading is the old one, not a new key.
    @ObservationIgnored private var pinPending: Date?
    /// A hung corebrightnessd would otherwise pile up one blocked thread per poll.
    @ObservationIgnored private var sliderRead: Task<Void, Never>?
    @ObservationIgnored private var measuring: Task<Void, Never>?
    @ObservationIgnored private var wasLimited = false
    @ObservationIgnored private var targetLog: Task<Void, Never>?
    @ObservationIgnored private var loggedTarget: Int?
    @ObservationIgnored private var lastAutoMode: Bool?
    /// Set by layout snapshots; never touches the display.
    @ObservationIgnored private var isPreview = false

    init?(id: CGDirectDisplayID, name: String, settings: AppSettings) {
        guard let framebuffer = BuiltInFramebuffer.find() else { return nil }
        self.id = id
        self.name = name
        self.settings = settings
        self.framebuffer = framebuffer
        sliderWriter = LatestValueWriter { [id] value in
            _ = await withTimeout { DisplayServices.setBrightness(id, value) }
        }
    }

    // MARK: - Mappings

    /// Quadratic so the slider feels even; slider 0.775 is about 600 nits.
    static func boostNits(forSlider slider: Double) -> Double {
        max(minBoostNits, maxBoostNits * slider * slider)
    }

    static func slider(forBoostNits nits: Double) -> Double {
        min(1, max(0, nits / maxBoostNits).squareRoot())
    }

    static func thermalCeiling(forCelsius celsius: Double) -> Double {
        guard let first = thermalCurve.first, let last = thermalCurve.last else { return maxBoostNits }
        if celsius <= first.celsius { return first.nits }
        if celsius >= last.celsius { return last.nits }
        let upper = thermalCurve.firstIndex { $0.celsius >= celsius } ?? thermalCurve.count - 1
        let a = thermalCurve[upper - 1], b = thermalCurve[upper]
        return a.nits + (b.nits - a.nits) * (celsius - a.celsius) / (b.celsius - a.celsius)
    }

    // MARK: - State

    var followsAmbient: Bool {
        settings.boostAutoBrightness && lux != nil
    }

    /// Auto-brightness as it affects the display now: EasyDisplay's own while boosted, the system's otherwise.
    var autoBrightnessActive: Bool {
        boost == .on ? followsAmbient : autoBrightness
    }

    var headroom: Double {
        Double(NSScreen.screens.first { $0.displayID == id }?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
    }

    /// Where boost is headed before the thermal limit.
    private var desiredNits: Double {
        if followsAmbient, let lux { return manualNits ?? settings.autoCurve.nits(forLux: lux) }
        return Self.boostNits(forSlider: slider)
    }

    var targetNits: Double {
        min(desiredNits, thermalCeiling)
    }

    /// Boost is being held below where it would be because of the temperature.
    var thermalLimited: Bool {
        boost == .on && thermalCeiling < desiredNits - 0.5
    }

    var nits: Double {
        boost == .on ? drivenNits : measuredNits
    }

    var isTransitioning: Bool {
        boost == .enabling || boost == .disabling
    }

    /// The line under the display's name.
    var summary: String {
        switch boost {
        case .off: LF(autoBrightness ? "display.summary_auto" : "display.summary_manual", presetName)
        case .enabling: L("display.summary_enabling")
        case .on:
            if thermalLimited {
                LF("display.summary_thermal", Int(thermalCeiling.rounded()))
            } else if followsAmbient, let lux {
                LF("display.summary_boost_auto", Int(lux.rounded()))
            } else {
                L("display.summary_boost")
            }
        case .disabling: L("display.summary_disabling")
        }
    }

    // MARK: - Reading

    func refresh() async {
        guard !isPreview else { return }
        if boost == .off, let value = await readSlider() { slider = value }
        if boost == .off, let value = await readAutoBrightness() { autoBrightness = value }
        presetName = DisplayPresets.active(for: id)?.name ?? ""
        updateMeasuredNits()
    }

    private func readSlider() async -> Double? {
        await withTimeout { [id] in DisplayServices.brightness(id) } ?? nil
    }

    private func readAutoBrightness() async -> Bool? {
        await withTimeout { [id] in DisplayServices.autoBrightness(id) } ?? nil
    }

    private func updateMeasuredNits() {
        let level = framebuffer.nits(BuiltInFramebuffer.levelKey) ?? 0
        let nits = level / max(headroom, 1)
        if nits != measuredNits { measuredNits = nits }
        // The same threshold as the driver's: EasyDisplay's own lowest is 2 nits.
        setLit(level >= 0.5)
    }

    private func setLit(_ lit: Bool) {
        guard lit != isLit else { return }
        isLit = lit
        if lit { litSince = .now }
    }

    /// The display's temperature and the ambient light are being measured, rather than held from before it went off.
    var sensorsAreCurrent: Bool {
        isLit && Date.now.timeIntervalSince(litSince) >= Self.sensorsCatchUp
    }

    /// Follows macOS's own brightness ramp for a moment, ten times a second, so an indicator shows it settle.
    private func measureForAMoment() {
        measuring?.cancel()
        measuring = Task {
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                updateMeasuredNits()
            }
        }
    }

    /// Takes in a new second of sensor readings; the display's only regular work on the main thread.
    func update(_ sample: SensorSample) {
        guard !isPreview else { return }
        absorb(sample)
        guard boost == .on else {
            updateMeasuredNits()
            if observesSlider, sliderRead == nil, !sliderWriter.isBusy {
                sliderRead = Task {
                    if let value = await readSlider(), !sliderWriter.isBusy, boost == .off, value != slider { slider = value }
                    sliderRead = nil
                }
            }
            return
        }
        switchModeIfNeeded()
        learnIfSettled()
        // Following the light, the slider shows the brightness it's at, as Android's does since Pie.
        if followsAmbient, manualNits == nil {
            let position = Self.slider(forBoostNits: desiredNits)
            if abs(position - slider) > 0.0005 { slider = position }
        }
        steer()
    }

    private func absorb(_ sample: SensorSample) {
        if let reading = sample.displayCelsius {
            // Smoothed over about ten seconds, so sensor noise doesn't wobble the ceiling.
            let smoothed = celsius.map { $0 + (reading - $0) * 0.1 } ?? reading
            celsius = smoothed
            let ceiling = Self.thermalCeiling(forCelsius: smoothed).rounded()
            if ceiling != thermalCeiling { thermalCeiling = ceiling }
        }
        if thermalLimited != wasLimited {
            wasLimited = thermalLimited
            let shown = String(format: "%.1f", celsius ?? 0)
            Log.info("thermal", thermalLimited
                ? "螢幕 \(shown) °C，增亮上限降到 \(Int(thermalCeiling)) nit"
                : "螢幕 \(shown) °C，上限 \(Int(thermalCeiling)) nit，不再限制亮度")
        }
        guard boost == .on, let reading = sample.lux else { return }
        let first = lux == nil
        if ambient.add(reading, at: sample.time), let followed = ambient.ambient {
            lux = followed
            Log.info("auto", "環境光改為 \(String(format: "%.1f", followed)) lux")
        }
        // Nothing learned for this lighting yet: the brightness on screen when boost started is the first choice,
        // so turning boost on never dims the display towards a default the user never picked.
        if first, let lux, settings.boostAutoBrightness, !settings.autoCurve.hasPoint(near: lux) {
            let nits = max(drivenNits, Self.minBoostNits)
            settings.autoCurve.learn(lux: lux, nits: nits)
            Log.info("auto", "這種光線還沒有學過亮度，把開啟增亮時的 \(Int(nits.rounded())) nit 當成 \(String(format: "%.1f", lux)) lux 的起點")
        }
    }

    // MARK: - Control

    func setSlider(_ value: Double) {
        guard !isPreview else {
            slider = value
            return
        }
        guard boost == .on else {
            slider = value
            sliderWriter.submit(value)
            measureForAMoment()
            return
        }
        lastManualChange = .now
        adjust(toPosition: value)
    }

    /// A brightness key: `step` is a fraction of the slider, negative to dim. Boosted, it moves the boosted
    /// brightness and leaves the system slider pinned; otherwise it moves the system slider, as macOS would.
    func brightnessKey(step: Double) {
        guard !isTransitioning else { return }
        if boost == .on, !isPreview {
            lastManualChange = .now
            adjust(toPosition: Self.slider(forBoostNits: desiredNits) + step)
        } else {
            setSlider(min(1, max(0, slider + step)))
        }
    }

    /// Sets the boosted brightness to a slider position. Following the ambient light, it's shown at once and becomes
    /// a learned point for this lighting once the adjustments stop.
    private func adjust(toPosition position: Double) {
        let position = min(1, max(0, position))
        slider = position
        if followsAmbient { manualNits = Self.boostNits(forSlider: position) }
        steer()
    }

    /// Learns the brightness the user settled on, then lets the curve (which now passes through it) take over.
    private func learnIfSettled() {
        guard let manual = manualNits, Date.now.timeIntervalSince(lastManualChange) >= Self.learnAfter else { return }
        if followsAmbient, let lux {
            settings.autoCurve.learn(lux: lux, nits: manual)
            Log.info("auto", "記住 \(String(format: "%.1f", lux)) lux 時選的亮度 \(Int(manual.rounded())) nit")
        }
        manualNits = nil
    }

    func resetLearning() {
        Log.info("auto", "忘記所有學到的亮度（\(settings.autoCurve.points.count) 個）")
        settings.autoCurve.reset()
        manualNits = nil
        steer()
    }

    /// Hands the driver where to go, and how fast, when that changed.
    private func steer() {
        guard boost == .on, !isPreview else { return }
        let target = targetNits
        let manual = !followsAmbient || Date.now.timeIntervalSince(lastManualChange) < 1
        let pace: BacklightDriver.Pace = manual ? .quick : target > drivenNits ? .brighten : .dim
        if let steered, steered.nits == target, steered.pace == pace { return }
        steered = (target, pace)
        driver.steer(to: target, pace: pace)
        logTarget(target, manual: manual)
    }

    /// Where the brightness is headed and why, once a change has settled: a dragged slider or held key is one line,
    /// not one per step.
    private func logTarget(_ target: Double, manual: Bool) {
        let reason = thermalLimited ? "溫度限制"
            : manual ? (followsAmbient ? "手動調整（會學習）" : "手動調整")
            : "自動亮度（\(String(format: "%.1f", lux ?? 0)) lux）"
        targetLog?.cancel()
        targetLog = Task { [drivenNits] in
            try? await Task.sleep(for: .milliseconds(manual ? 600 : 0))
            guard !Task.isCancelled, Int(target.rounded()) != loggedTarget else { return }
            loggedTarget = Int(target.rounded())
            Log.info("brightness", "目標亮度 \(Int(drivenNits.rounded())) → \(Int(target.rounded())) nit：\(reason)")
        }
    }

    /// Keeps the brightness on screen when boosted auto-brightness is switched on or off.
    private func switchModeIfNeeded() {
        let auto = followsAmbient
        defer { lastAutoMode = auto }
        guard let last = lastAutoMode, last != auto else { return }
        manualNits = nil
        if !auto { slider = Self.slider(forBoostNits: drivenNits) }
    }

    private func driverReported(_ event: BacklightDriver.Event) {
        switch event {
        case .off:
            setLit(false)
            Log.info("backlight", "背光關閉（螢幕休眠、闔上或鎖定），等系統重新點亮")
        case .on:
            setLit(true)
            Log.info("backlight", "背光重新點亮，回到原本的亮度")
        case .dimming: Log.info("backlight", "系統在螢幕休眠前調暗，跟著變暗")
        case .undimmed: Log.info("backlight", "使用者回來了，從調暗的亮度調回")
        case .overwritten: overwritten()
        case .interference(let burst): logInterference(burst)
        }
    }

    /// One line per burst of writes elsewhere: a warning when any of it could be seen, which is what a flicker is.
    private func logInterference(_ burst: BacklightDriver.Interference) {
        let seconds = String(format: "%.1f", Double(burst.last - burst.first) / 1e9)
        guard let worst = burst.worst, burst.visible > 0 else {
            Log.info("backlight", "其他程式在 \(seconds) 秒內改寫背光 \(burst.writes) 次（\(burst.during)），都在畫面顯示前寫回")
            return
        }
        Log.warn("backlight", "可能閃爍：其他程式在 \(seconds) 秒內改寫背光 \(burst.writes) 次（\(burst.during)），"
            + "其中 \(burst.visible) 次會顯示；最大 \(Int(worst.level.rounded())) nit（當時維持 \(Int(worst.held.rounded())) nit），"
            + "最長顯示 \(String(format: "%.1f", burst.longestMilliseconds)) ms")
    }

    /// Something else wrote the backlight (the driver has written it back, and logs it): wake, a preset change, a True
    /// Tone adjustment, or macOS moving its slider (Control Center, or a brightness key EasyDisplay couldn't take). If
    /// the slider moved, that one step is applied and the slider pinned again.
    private func overwritten() {
        guard boost == .on, sliderRead == nil, !sliderWriter.isBusy else { return }
        sliderRead = Task {
            defer { sliderRead = nil }
            guard let value = await readSlider(), boost == .on else { return }
            if value >= Self.pinnedSlider - 0.001 {
                pinPending = nil
                return
            }
            // Until the pin lands, corebrightnessd's ramp keeps reporting the old, lower slider: counting it again
            // is how one key press once ran the brightness down to the minimum.
            if let pinned = pinPending, Date.now.timeIntervalSince(pinned) < 2 { return }
            Log.info("keys", "macOS 的亮度滑桿被移到 \(String(format: "%.3f", value))（控制中心，或沒接手到的亮度鍵），換算成一格調整後固定回最大")
            lastManualChange = .now
            adjust(toPosition: Self.slider(forBoostNits: desiredNits) + value - Self.pinnedSlider)
            pinPending = .now
            sliderWriter.submit(Self.pinnedSlider)
        }
    }

    // MARK: - Boost

    func setBoost(_ enabled: Bool) async {
        switch (enabled, boost) {
        case (true, .off): await enableBoost()
        case (false, .on):
            Log.info("boost", "關閉增亮")
            settings.boostWasOn = false
            await disableBoost()
        default: break
        }
    }

    private func enableBoost() async {
        boost = .enabling
        error = nil
        // Boost starts from the brightness on screen, so it waits for someone to be looking at it. Off, or dimmed before
        // display sleep, the display has nothing to start from: boost would start near the minimum, and learn that as
        // the choice for this light. Restored at launch, that's until the user is back.
        updateMeasuredNits()
        if !isLit || BacklightDriver.userIdleSeconds >= BacklightDriver.idleBeforeDimming {
            Log.info("boost", "螢幕沒亮或沒有人在用，等使用者回來再開啟增亮")
        }
        while !isLit || BacklightDriver.userIdleSeconds >= BacklightDriver.idleBeforeDimming {
            try? await Task.sleep(for: .seconds(1))
            updateMeasuredNits()
        }
        guard let sdr600 = DisplayPresets.sdr600(for: id), let current = DisplayPresets.active(for: id) else {
            return failEnabling(L("boost.error_preset"))
        }
        guard let startSlider = await readSlider(),
              let startAuto = await readAutoBrightness()
        else {
            return failEnabling(L("boost.error_unresponsive"))
        }
        var caps: [String: Int] = [:]
        for key in BuiltInFramebuffer.capKeys { caps[key] = framebuffer.raw(key) }
        // Held where it is from here on. Turning auto-brightness off, switching the preset and pinning the slider each
        // make corebrightnessd rewrite the backlight (pinned, towards 600 nits); every rewrite is put back before it
        // shows. The white on screen stays as it is while the preset changes the headroom.
        guard let level = driver.holdCurrent() else {
            // Off again in the meantime: back to waiting.
            boost = .off
            return await enableBoost()
        }
        let startNits = max(level / max(headroom, 1), Self.minBoostNits)
        BoostRestoreState(presetIndex: current.index, slider: startSlider, autoBrightness: startAuto, caps: caps).save()
        drivenNits = level
        let holding = holdWhite(startNits)
        _ = await withTimeout { [id] in DisplayServices.setAutoBrightness(id, false) }
        if current.index != sdr600.index {
            DisplayPresets.activate(index: sdr600.index, on: id)
            // Pinned at once, so the preset's own slider shows as briefly as it can, and again once the switch, which
            // resets the slider, is over.
            _ = await withTimeout { [id] in DisplayServices.setBrightness(id, Self.pinnedSlider) }
            try? await Task.sleep(for: .seconds(2))
        }
        _ = await withTimeout { [id] in DisplayServices.setBrightness(id, Self.pinnedSlider) }
        try? await Task.sleep(for: .milliseconds(800))
        holding.cancel()
        slider = Self.slider(forBoostNits: startNits)
        resetFollowing()
        autoBrightness = false
        presetName = sdr600.name
        boost = .on
        settings.boostWasOn = true
        // From the brightness on screen to where boost wants it (the learned curve, the thermal limit), eased as
        // auto-brightness would.
        let target = targetNits
        let pace: BacklightDriver.Pace = target > startNits ? .brighten : .dim
        steered = (target, pace)
        driver.steer(to: target, pace: pace)
        Log.info("boost", "開啟增亮：\(current.name) → \(sdr600.name)，從 \(Int(startNits.rounded())) nit 到 \(Int(target.rounded())) nit")
    }

    private func failEnabling(_ message: String) {
        Log.error("boost", "無法開啟增亮：\(message)")
        error = message
        boost = .off
    }

    private func disableBoost() async {
        boost = .disabling
        if let state = BoostRestoreState.load() { await restore(state) }
        boost = .off
        resetFollowing()
        await refresh()
    }

    private func resetFollowing() {
        lux = nil
        ambient = AmbientFilter()
        manualNits = nil
        lastAutoMode = nil
    }

    /// Keeps the white on screen at `white` nits while macOS changes the display's EDR headroom, until cancelled.
    /// Pixels are scaled by 1 / headroom, so the backlight follows it: switching from a preset with headroom 1.2 to
    /// one without would otherwise brighten the screen by as much at once.
    private func holdWhite(_ white: Double) -> Task<Void, Never> {
        Task {
            var last = 0.0
            while !Task.isCancelled {
                let headroom = max(headroom, 1)
                if abs(headroom - last) > 0.005 {
                    last = headroom
                    driver.steer(to: white * headroom, pace: .quick)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Undoes a boost, or one left behind by a crash or force-quit: at launch, when boost is turned off, and at quit.
    func restoreLeftoverBoost() async {
        guard boost != .disabling, let state = BoostRestoreState.load() else { return }
        boost = .disabling
        await restore(state)
        boost = .off
    }

    private func restore(_ state: BoostRestoreState) async {
        Log.info("boost", "還原：預設模式 #\(state.presetIndex)、亮度滑桿 \(String(format: "%.3f", state.slider))、自動亮度\(state.autoBrightness ? "開" : "關")")
        // Held where it is while macOS's own brightness is put back, then eased over to it, so nothing jumps. A boost
        // left behind by a crash is taken from where it is.
        let holding = driver.holdCurrent().map { holdWhite($0 / max(headroom, 1)) }
        defer { holding?.cancel() }
        DisplayPresets.activate(index: state.presetIndex, on: id)
        try? await Task.sleep(for: .seconds(2))
        // Switching presets resets the slider, so the slider is restored last.
        _ = await withTimeout { [id] in DisplayServices.setAutoBrightness(id, state.autoBrightness) }
        _ = await withTimeout { [id] in DisplayServices.setBrightness(id, state.slider) }
        try? await Task.sleep(for: .milliseconds(500))
        let handedOver = await driver.handOver()
        Log.info("boost", handedOver
            ? "背光已平順交還給 macOS（\(String(format: "%.1f", framebuffer.nits(BuiltInFramebuffer.levelKey) ?? 0)) nit）"
            : "macOS 沒有寫入背光，改用調動滑桿讓它重新設定")
        if !handedOver {
            // Nothing from corebrightnessd to ease to (the display is off, or it never wrote the backlight): its old
            // cap back, and a nudge of the slider makes it write the level again.
            if let raw = state.caps[BuiltInFramebuffer.backlightCapKey] { framebuffer.setRaw(BuiltInFramebuffer.backlightCapKey, raw) }
            _ = await withTimeout { [id] in DisplayServices.setBrightness(id, max(0, state.slider - 0.05)) }
            try? await Task.sleep(for: .milliseconds(300))
            _ = await withTimeout { [id] in DisplayServices.setBrightness(id, state.slider) }
        }
        for key in [BuiltInFramebuffer.physicalLimitKey, BuiltInFramebuffer.indicatorCapKey] {
            if let raw = state.caps[key], raw != framebuffer.raw(key) { framebuffer.setRaw(key, raw) }
        }
        BoostRestoreState.clear()
    }
}

#if DEBUG
extension BuiltInDisplay {
    /// Shows the boosted state in layout snapshots without touching the display.
    func previewBoost(nits: Double, lux: Double? = nil) {
        isPreview = true
        slider = Self.slider(forBoostNits: nits)
        drivenNits = nits
        self.lux = lux
        boost = .on
    }
}
#endif

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
