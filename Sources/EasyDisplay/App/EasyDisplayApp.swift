import SwiftUI

@main
struct EasyDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            TrayView(manager: appDelegate.manager, language: appDelegate.language, updater: appDelegate.updater) { page in
                SettingsWindow.shared.show(page: page)
            }
        } label: {
            MenuBarLabel(manager: appDelegate.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

/// A sun, filled while the built-in display is boosted, and its brightness beside it.
private struct MenuBarLabel: View {
    let manager: DisplayManager

    var body: some View {
        let display = manager.builtInOnline ? manager.builtIn : nil
        HStack(spacing: 3) {
            Image(systemName: display?.boost == .on ? "sun.max.fill" : "sun.max")
            if let display {
                Text("\(Int(display.nits.rounded())) nit").monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("EasyDisplay")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let language = LanguageSettings()
    let settings = AppSettings()
    let updater = Updater()
    private(set) lazy var manager = DisplayManager(settings: settings, database: Self.openDatabase())
    private var terminationSignal: DispatchSourceSignal?
    private var quitting = false

    /// Without the database the monitor still shows live readings, just no history.
    private static func openDatabase() -> MonitorDatabase? {
        do {
            return try MonitorDatabase()
        } catch {
            log.error("monitor database unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, also when started without the app bundle (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
        SettingsWindow.shared.configure(.init(manager: manager, settings: settings, language: language, updater: updater))
        updater.start()

        // `kill` sends SIGTERM, which would otherwise end the app without restoring a boosted display.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    /// Undoing a boost takes a few seconds of preset and slider changes; quitting waits for it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            await manager.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opening EasyDisplay again (Finder, Spotlight) shows Settings; that also helps when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }
}
