import AppKit
import SwiftUI

enum Metrics {
    static let panelWidth: CGFloat = 360
    static let icon: CGFloat = 26
}

/// A card's title, in the style of Control Center module headers.
struct CardTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Controls that belong together, on a rounded background like a module in Control Center.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { CardTitle(title) }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Round display icon, filled with the accent color (or `tint`), as in the system menus.
struct DisplayIcon: View {
    let symbol: String
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.callout)
            .foregroundStyle(.white)
            .frame(width: Metrics.icon, height: Metrics.icon)
            .background(Circle().fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)))
            .accessibilityHidden(true)
    }
}

/// A name, with what's going on with it in small print underneath.
struct NameAndSummary: View {
    let name: String
    let summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).lineLimit(1).truncationMode(.middle)
            if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// Release or pre-release, like the label GitHub puts on a release: green for a release, orange for a pre-release.
struct ReleaseBadge: View {
    let prerelease: Bool

    var body: some View {
        let color: Color = prerelease ? .orange : .green
        Text(L(prerelease ? "update.kind_prerelease" : "update.kind_release"))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Something that needs attention, tinted by how much, with what to do about it.
struct Notice<Actions: View>: View {
    let symbol: String
    let tint: Color
    var title: String?
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                actions.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The label of a menu item: full width, highlighted under the pointer, and clickable across the whole
/// highlighted area rather than only on its text.
private struct MenuItemLabel: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // The panel hides without an exit event; don't come back highlighted.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in hovering = false }
    }
}

/// A full-width menu-style row, like items in system menus.
struct MenuRow<Label: View>: View {
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label.modifier(MenuItemLabel())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .padding(.horizontal, -6)
    }
}

/// A menu item's title with its keyboard shortcut on the right, as menus show them.
struct ShortcutLabel: View {
    let title: String
    let keys: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }
}

extension Text {
    /// A reading at the end of a row, such as a brightness.
    func valueStyle(width: CGFloat = 40) -> some View {
        font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: width, alignment: .trailing)
    }
}

func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
