import AppKit
import SwiftUI

/// EazyDisplay's brightness indicator, in place of the system's: at the top right of the display that changed, with
/// its brightness in nits (or percent, for a monitor that doesn't report nits). It doesn't take focus, shows over
/// full-screen apps, and fades away by itself.
@MainActor
final class BrightnessOSD {
    enum Target {
        case builtIn(BuiltInDisplay)
        case external(ExternalDisplay)

        var id: CGDirectDisplayID {
            switch self {
            case .builtIn(let display): display.id
            case .external(let display): display.id
            }
        }
    }

    static let shared = BrightnessOSD()

    private var panel: NSPanel?
    private var shownFor: CGDirectDisplayID?
    private var hideTask: Task<Void, Never>?
    /// Counts showings, so fading out one doesn't hide the next.
    private var generation = 0

    func show(_ target: Target) {
        generation += 1
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        if shownFor != target.id || panel.contentView == nil {
            // The view reads the display itself, so it follows the brightness as it settles.
            panel.contentView = NSHostingView(rootView: BrightnessOSDView(target: target))
            shownFor = target.id
        }
        let size = panel.contentView?.fittingSize ?? .zero
        if let screen = NSScreen.screens.first(where: { $0.displayID == target.id }) {
            // Below the menu bar, at the right, where the system's Control Center indicators appear.
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard let panel else { return }
        let shown = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { [weak self] in
                if self?.generation == shown { panel.orderOut(nil) }
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct BrightnessOSDView: View {
    let target: BrightnessOSD.Target

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: boosted ? "sun.max.fill" : "sun.max")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(boosted ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .frame(width: 26)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: value)
                }
                Level(fraction: fraction, tick: tick, tint: boosted ? .orange : .primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(4)
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        switch target {
        case .builtIn(let display): display.name
        case .external(let display): display.name
        }
    }

    private var boosted: Bool {
        if case .builtIn(let display) = target { return display.boost == .on }
        return false
    }

    private var value: String {
        switch target {
        case .builtIn(let display): "\(Int(display.nits.rounded())) nit"
        case .external(let display): display.brightness.map(percent) ?? "—"
        }
    }

    private var fraction: Double {
        switch target {
        case .builtIn(let display): display.slider
        case .external(let display): display.brightness ?? 0
        }
    }

    /// Where boost goes past the panel's normal 600 nits.
    private var tick: Double? {
        boosted ? BuiltInDisplay.slider(forBoostNits: 600) : nil
    }
}

/// A rounded level bar, filled up to `fraction`.
private struct Level: View {
    let fraction: Double
    let tick: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule()
                    .fill(tint)
                    .frame(width: max(geometry.size.height, geometry.size.width * min(max(fraction, 0), 1)))
                    .animation(.snappy(duration: 0.18), value: fraction)
                if let tick {
                    Rectangle()
                        .fill(.background.opacity(0.8))
                        .frame(width: 2)
                        .offset(x: geometry.size.width * tick - 1)
                }
            }
        }
        .frame(height: 6)
    }
}

#if DEBUG
/// Lets layout snapshots show the indicator without putting it on screen.
struct BrightnessOSDPreview: View {
    let target: BrightnessOSD.Target

    var body: some View {
        BrightnessOSDView(target: target)
    }
}
#endif
