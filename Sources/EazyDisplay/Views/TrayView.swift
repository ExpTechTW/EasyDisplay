import SwiftUI

struct TrayView: View {
    let manager: DisplayManager
    let language: LanguageSettings
    let updater: Updater
    let openSettings: (SettingsPage?) -> Void
    @State private var chart: MonitorChartModel

    init(manager: DisplayManager, language: LanguageSettings, updater: Updater, openSettings: @escaping (SettingsPage?) -> Void) {
        self.manager = manager
        self.language = language
        self.updater = updater
        self.openSettings = openSettings
        _chart = State(initialValue: MonitorChartModel(monitor: manager.sensors, place: "tray", ranges: [.fiveMinutes, .hour, .day]))
    }

    var body: some View {
        VStack(spacing: 10) {
            if manager.settings.handlesBrightnessKeys, !manager.keysAvailable {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange, title: L("tray.keys_title"), text: L("tray.keys_text")) {
                    Button(L("settings.keys_allow")) {
                        BrightnessKeys.requestAccess()
                        BrightnessKeys.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            BrightnessCard(manager: manager)
            Card(title: L("tray.monitor")) {
                MonitorCharts(monitor: manager.sensors, model: chart, metrics: [.brightness, .power, .temperature])
            }
            Footer(updater: updater) { openSettings(nil) }
        }
        .padding(12)
        .frame(width: Metrics.panelWidth)
        .environment(\.locale, language.language.locale)
        // Rebuilds every string when the language changes.
        .id(language.language)
        .task { await manager.refreshAll() }
        .onAppear { manager.trayVisible = true }
        .onDisappear { manager.trayVisible = false }
    }
}

// MARK: - Brightness

private struct BrightnessCard: View {
    let manager: DisplayManager

    var body: some View {
        Card(title: L("tray.brightness")) {
            if let builtIn = manager.builtIn, manager.builtInOnline {
                BuiltInRow(display: builtIn)
            }
            ForEach(manager.externals) { display in
                ExternalRow(display: display)
            }
            if !manager.builtInOnline, manager.externals.isEmpty {
                Text(L("tray.no_displays")).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BuiltInRow: View {
    let display: BuiltInDisplay

    var body: some View {
        let boosted = display.boost == .on
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                DisplayIcon(symbol: "laptopcomputer", tint: display.thermalLimited ? .red : boosted ? .orange : nil)
                NameAndSummary(name: display.name, summary: display.summary)
                Spacer(minLength: 0)
                Text("\(Int(display.nits.rounded())) nit")
                    .valueStyle(width: 64)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(display.nits.rounded()))
            }
            .help(display.name)
            slider
                .labelsHidden()
                .disabled(display.isTransitioning)
                .padding(.leading, Metrics.icon + 8)
        }
    }

    private var value: Binding<Double> {
        Binding(get: { display.slider }, set: { display.setSlider($0) })
    }

    @ViewBuilder private var slider: some View {
        if display.boost == .on {
            // The tick marks 600 nits, where the panel's normal SDR range ends.
            Slider(value: value, in: 0...1) {
                Text(LF("a11y.brightness", display.name))
            } ticks: {
                SliderTick(BuiltInDisplay.slider(forBoostNits: 600))
            }
            .tint(.orange)
            .help(L("boost.tick_help"))
        } else {
            Slider(value: value, in: 0...1) { Text(LF("a11y.brightness", display.name)) }
        }
    }
}

private struct ExternalRow: View {
    let display: ExternalDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                DisplayIcon(symbol: "display", tint: display.isControllable ? nil : .gray)
                NameAndSummary(name: display.name, summary: display.control.label)
                Spacer(minLength: 0)
                if let brightness = display.brightness {
                    Text(percent(brightness)).valueStyle()
                }
            }
            .help(display.name)
            if display.isControllable {
                Slider(value: Binding(get: { display.brightness ?? 0 }, set: { display.setBrightness($0) }), in: 0...1) {
                    Text(LF("a11y.brightness", display.name))
                }
                .labelsHidden()
                .disabled(display.brightness == nil)
                .padding(.leading, Metrics.icon + 8)
            }
        }
    }
}

// MARK: - Footer

private struct Footer: View {
    let updater: Updater
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(LF("settings.version", updater.build.label))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                ReleaseBadge(prerelease: updater.build.isPrerelease)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            // Only when a newer build is out.
            if let release = updater.available {
                MenuRow {
                    updater.showAvailable()
                } label: {
                    HStack {
                        Text(updateTitle(release))
                        Spacer()
                        updateProgress
                    }
                }
                .disabled(updater.isBusy)
            }
            MenuRow(shortcut: KeyboardShortcut(",")) {
                openSettings()
            } label: {
                ShortcutLabel(title: L("action.settings"), keys: "⌘,")
            }
            MenuRow(shortcut: KeyboardShortcut("q")) {
                NSApp.terminate(nil)
            } label: {
                ShortcutLabel(title: L("action.quit"), keys: "⌘Q")
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var updateProgress: some View {
        switch updater.phase {
        case .downloading(let percent):
            ProgressView(value: Double(percent), total: 100).progressViewStyle(.circular).controlSize(.small)
        case .installing:
            ProgressView().controlSize(.small)
        default:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        }
    }

    private func updateTitle(_ release: Release) -> String {
        switch updater.phase {
        case .downloading(let percent): LF("update.downloading", "\(percent)%")
        case .installing: L("update.installing")
        default: LF("update.tray", release.label)
        }
    }
}
