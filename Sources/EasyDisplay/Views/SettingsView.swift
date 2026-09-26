import ServiceManagement
import SwiftUI

struct GeneralPage: View {
    @Environment(LanguageSettings.self) private var language
    @Environment(DisplayManager.self) private var manager
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = false
    @State private var loginMessage: String?

    var body: some View {
        @Bindable var language = language
        @Bindable var settings = settings
        Form {
            PageHeader(page: .general)

            Section(L("settings.startup")) {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    Text(L("settings.launch_at_login"))
                    Text(loginMessage ?? L("settings.launch_at_login_hint"))
                        .foregroundStyle(loginMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }

            Section(L("settings.keys")) {
                Toggle(isOn: $settings.handlesBrightnessKeys) {
                    Text(L("settings.keys_handle"))
                    Text(L("settings.keys_hint"))
                }
                if settings.handlesBrightnessKeys {
                    LabeledContent {
                        if manager.keysAvailable {
                            Label(L("settings.keys_ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Button(L("settings.keys_allow")) {
                                BrightnessKeys.requestAccess()
                                BrightnessKeys.openAccessibilitySettings()
                            }
                        }
                    } label: {
                        Text(L("settings.keys_access"))
                        Text(L(manager.keysAvailable ? "settings.keys_access_ready" : "settings.keys_needed"))
                    }
                }
            }

            Section {
                Picker(L("language.title"), selection: $language.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
        .onAppear(perform: refreshLoginState)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = error.localizedDescription
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval { loginMessage = L("settings.login_needs_approval") }
    }
}

struct BoostPage: View {
    @Environment(DisplayManager.self) private var manager
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var settings = settings
        let curve = BuiltInDisplay.thermalCurve
        Form {
            PageHeader(page: .boost)

            if let display = manager.builtIn, manager.builtInOnline {
                let boosted = display.boost == .on || display.boost == .enabling
                Section {
                    Toggle(isOn: Binding(get: { boosted }, set: { enabled in Task { await display.setBoost(enabled) } })) {
                        Text(L("tray.boost"))
                        Text(LF("boost.hint_off", Int(BuiltInDisplay.maxBoostNits)))
                    }
                    .disabled(display.isTransitioning)
                    // Only means something while boost is on: whether it comes back after a relaunch.
                    if boosted {
                        Toggle(isOn: $settings.restoreBoostAtLaunch) {
                            Text(L("settings.boost_at_launch"))
                            Text(L("settings.boost_at_launch_hint"))
                        }
                    }
                    if let error = display.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }

                Section(L("settings.boost_now")) {
                    LabeledContent(L("settings.current_brightness")) {
                        Text("\(Int(display.nits.rounded())) nit").monospacedDigit()
                    }
                    LabeledContent(L("settings.current_preset"), value: display.presetName)
                    if display.boost == .on, let lux = display.lux {
                        LabeledContent(L("settings.ambient_light")) {
                            Text(Metric.ambient.format(lux) + " lux").monospacedDigit()
                        }
                    }
                    if let celsius = display.celsius {
                        LabeledContent(L("settings.thermal_now")) {
                            Text(LF("settings.thermal_now_value", String(format: "%.1f", celsius), Int(display.thermalCeiling)))
                                .monospacedDigit()
                                .foregroundStyle(display.thermalLimited ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        }
                    }
                }
            } else {
                Section {
                    Text(L("settings.no_builtin")).foregroundStyle(.secondary)
                }
            }

            Section(L("settings.boost_behavior")) {
                Toggle(isOn: $settings.boostAutoBrightness) {
                    Text(L("boost.auto"))
                    Text(LF("settings.boost_auto_hint", Int(BuiltInDisplay.maxBoostNits)))
                }
            }

            if settings.boostAutoBrightness {
                Section {
                    let display = manager.builtInOnline ? manager.builtIn : nil
                    let now = display.flatMap { display in
                        display.boost == .on && display.followsAmbient ? display.lux.map { (lux: $0, nits: display.nits) } : nil
                    }
                    AutoCurveChart(curve: settings.autoCurve, now: now)
                        .padding(.vertical, 6)
                    LabeledContent {
                        Button(L("curve.reset")) { manager.builtIn?.resetLearning() ?? settings.autoCurve.reset() }
                            .disabled(settings.autoCurve.points.isEmpty)
                    } label: {
                        Text(LF("curve.points", settings.autoCurve.points.count))
                        Text(L("curve.points_hint"))
                    }
                } header: {
                    Text(L("curve.title"))
                } footer: {
                    Text(L("curve.footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent {
                    Text(LF("settings.thermal_value", Int(curve[0].celsius), Int(curve[1].celsius), Int(curve[1].nits)))
                } label: {
                    Text(L("settings.thermal"))
                    Text(LF("settings.thermal_hint", Int(curve[2].celsius), Int(curve[2].nits)))
                }
            } footer: {
                Text(L("settings.boost_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MonitorPage: View {
    @Environment(DisplayManager.self) private var manager
    @Environment(AppSettings.self) private var settings
    @State private var chart: MonitorChartModel?
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var settings = settings
        let monitor = manager.sensors
        Form {
            PageHeader(page: .monitor)

            Section {
                if let chart {
                    MonitorCharts(monitor: monitor, model: chart, plotHeight: 90)
                        .padding(.vertical, 6)
                }
            }

            MonitorAnalysisSection(monitor: monitor)

            Section {
                Picker(selection: $settings.monitorRetentionDays) {
                    ForEach(AppSettings.retentionChoices, id: \.self) { Text(LF("monitor.retention_days", $0)).tag($0) }
                } label: {
                    Text(L("monitor.retention"))
                    Text(L("monitor.retention_hint"))
                }
                Button(L("monitor.clear"), role: .destructive) { confirmingClear = true }
                    .disabled(monitor.database == nil)
            } header: {
                Text(L("monitor.data"))
            } footer: {
                Text(L("monitor.data_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(L("monitor.clear_confirm"), isPresented: $confirmingClear) {
            Button(L("monitor.clear_action"), role: .destructive) {
                Task { await monitor.clearHistory() }
            }
        }
        .onAppear {
            if chart == nil { chart = MonitorChartModel(monitor: monitor, place: "settings") }
        }
        .onChange(of: settings.monitorRetentionDays) {
            Task { await monitor.prune() }
        }
    }
}

struct UpdatesPage: View {
    @Environment(Updater.self) private var updater
    @Environment(LanguageSettings.self) private var language

    var body: some View {
        Form {
            PageHeader(page: .updates)

            Section {
                LabeledContent(L("update.current")) {
                    HStack(spacing: 8) {
                        Text(updater.build.label).monospacedDigit().textSelection(.enabled)
                        ReleaseBadge(prerelease: updater.build.isPrerelease)
                    }
                }
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 8)
                    if updater.available != nil, !updater.isBusy {
                        Button(L("update.view_changes")) { updater.openReleasePage() }
                        Button(L("update.install")) { updater.install() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(L("update.check_now")) { updater.check() }
                            .disabled(updater.isBusy || updater.unavailableReason != nil)
                    }
                }
            } footer: {
                if let last = updater.preferences.lastCheck, updater.unavailableReason == nil {
                    Text(LF("update.last_checked", last.formatted(.dateTime.month().day().hour().minute().locale(language.language.locale))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if updater.unavailableReason == nil {
                Section {
                    Toggle(isOn: Binding(get: { updater.preferences.checksAutomatically }, set: { updater.setChecksAutomatically($0) })) {
                        Text(L("update.automatic"))
                        Text(L("update.automatic_hint"))
                    }
                    Toggle(isOn: Binding(get: { updater.channel == .prerelease }, set: { updater.setReceivesPrereleases($0) })) {
                        Text(L("update.prerelease"))
                        Text(L("update.prerelease_hint"))
                    }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let reason = updater.unavailableReason {
            Text(reason).foregroundStyle(.secondary)
        } else {
            switch updater.phase {
            case .idle:
                if let release = updater.available { Text(LF("update.available", release.label)) }
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("update.checking")).foregroundStyle(.secondary)
                }
            case .upToDate:
                Label(L("update.up_to_date"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .downloading(let percent):
                VStack(alignment: .leading, spacing: 4) {
                    Text(LF("update.downloading", "\(percent)%")).foregroundStyle(.secondary)
                    ProgressView(value: Double(percent), total: 100)
                }
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("update.installing")).foregroundStyle(.secondary)
                }
            case .failed(let failure):
                Text(failure.message)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AboutPage: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EasyDisplay").font(.title.bold())
                        Text(L("app.tagline")).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(LF("settings.version", updater.build.label)).monospacedDigit().textSelection(.enabled)
                            ReleaseBadge(prerelease: updater.build.isPrerelease)
                        }
                        .font(.callout)
                    }
                }
                .padding(.vertical, 6)
            }

            Section(L("about.links")) {
                link(L("about.github"), symbol: "chevron.left.forwardslash.chevron.right", path: "")
                link(L("about.changelog"), symbol: "doc.text", path: "/releases")
                link(L("about.issues"), symbol: "exclamationmark.bubble", path: "/issues")
            }
        }
    }

    private func link(_ title: String, symbol: String, path: String) -> some View {
        let repository = updater.build.repository ?? "ExpTechTW/EasyDisplay"
        return Link(destination: URL(string: "https://github.com/\(repository)\(path)")!) {
            LabeledContent {
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
            } label: {
                Label(title, systemImage: symbol)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
