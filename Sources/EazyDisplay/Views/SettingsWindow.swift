import AppKit
import Observation
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, boost, monitor, updates, about

    /// The sidebar's groups: how EazyDisplay behaves, what it has measured, and EazyDisplay itself.
    static let groups: [[SettingsPage]] = [[.general, .boost], [.monitor], [.updates, .about]]

    var id: Self { self }
    var title: String { L("settings.page.\(rawValue)") }
    var subtitle: String { L("settings.page.\(rawValue)_subtitle") }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .boost: "sun.max.fill"
        case .monitor: "chart.xyaxis.line"
        case .updates: "arrow.down.circle.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general, .about: .gray
        case .boost: .orange
        case .monitor: .blue
        case .updates: .indigo
        }
    }
}

/// Which page the Settings window shows; also set from outside, e.g. by the tray's boost options.
@MainActor
@Observable
final class SettingsNavigation {
    var page: SettingsPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "settings.page") }
    }

    init() {
        page = UserDefaults.standard.string(forKey: "settings.page").flatMap(SettingsPage.init(rawValue:)) ?? .general
    }
}

/// The Settings window, managed directly: SwiftUI's Settings scene doesn't reliably open, or come to the front,
/// from a menu bar app.
@MainActor
final class SettingsWindow {
    struct Models {
        let manager: DisplayManager
        let settings: AppSettings
        let language: LanguageSettings
        let updater: Updater
    }

    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var closing: NSObjectProtocol?
    private var models: Models?
    private let navigation = SettingsNavigation()

    /// Hands over what the window shows; done once at launch.
    func configure(_ models: Models) {
        self.models = models
    }

    func show(page: SettingsPage? = nil) {
        guard let models else { return }
        if let page { navigation.page = page }
        let window = self.window ?? makeWindow(models)
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Visible even when macOS doesn't hand EazyDisplay the focus.
        window.orderFrontRegardless()
    }

    private func makeWindow(_ models: Models) -> NSWindow {
        let root = SettingsRoot(navigation: navigation, language: models.language) { [weak self] title in
            self?.window?.title = title
        }
        .environment(models.manager)
        .environment(models.settings)
        .environment(models.language)
        .environment(models.updater)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.title = navigation.page.title
        window.setContentSize(NSSize(width: 800, height: 640))
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("EazyDisplay.settings")
        // A closed window is let go, so its live charts don't keep redrawing behind the scenes.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window = nil
                if let closing = self?.closing { NotificationCenter.default.removeObserver(closing) }
                self?.closing = nil
            }
        }
        return window
    }
}

private struct SettingsRoot: View {
    @Bindable var navigation: SettingsNavigation
    let language: LanguageSettings
    /// The window's title isn't SwiftUI's: NSHostingController doesn't pass `navigationTitle` on.
    let setTitle: (String) -> Void
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })) {
                ForEach(SettingsPage.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { page in
                            Label {
                                Text(page.title)
                            } icon: {
                                PageIcon(page: page, size: 20)
                            }
                            .tag(page)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .focused($sidebarFocused)
        } detail: {
            Group {
                switch navigation.page {
                case .general: GeneralPage()
                case .boost: BoostPage()
                case .monitor: MonitorPage()
                case .updates: UpdatesPage()
                case .about: AboutPage()
                }
            }
            .formStyle(.grouped)
        }
        // The sidebar has the keyboard, as in System Settings, rather than whatever control comes first.
        .defaultFocus($sidebarFocused, true)
        .environment(\.locale, language.language.locale)
        // Rebuilds every string when the language changes.
        .id(language.language)
        .onAppear { setTitle(navigation.page.title) }
        .onChange(of: navigation.page) { setTitle(navigation.page.title) }
        .onChange(of: language.language) { setTitle(navigation.page.title) }
    }
}

/// A page's symbol on a colored rounded square, as System Settings draws them.
struct PageIcon: View {
    let page: SettingsPage
    let size: CGFloat

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(page.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The large icon, title and description at the top of a page.
struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        Section {
            HStack(spacing: 14) {
                PageIcon(page: page, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).font(.title2.bold())
                    Text(page.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
