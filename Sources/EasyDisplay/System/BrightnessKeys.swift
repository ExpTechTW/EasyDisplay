import AppKit
@preconcurrency import ApplicationServices

/// The keyboard's brightness keys, taken before macOS sees them. EasyDisplay then changes the display in use and
/// shows its own indicator in place of the system's. Taking the keys needs Accessibility access.
@MainActor
final class BrightnessKeys {
    /// Asked for every brightness key press, auto-repeat and release; true takes it from macOS. `fine` is ⌥⇧, which
    /// steps a quarter as far, as in macOS. Only presses should change anything.
    var onKey: (_ up: Bool, _ fine: Bool, _ pressed: Bool) -> Bool = { _, _, _ in false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Brightness keys arrive as NX_SYSDEFINED events of subtype 8, their key and state in `data1`.
    private static let systemDefined = CGEventType(rawValue: 14)!
    private static let brightnessUp = 2
    private static let brightnessDown = 3

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks for Accessibility access; macOS shows its prompt once, then Settings has to be used.
    static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read as a global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    var isRunning: Bool { tap != nil }

    /// Starts listening when access has been given; safe to call again.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard Self.isTrusted else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventMask(Self.systemDefined.rawValue),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let keys = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
                let data = NSEvent(cgEvent: event).flatMap { $0.type == .systemDefined && $0.subtype.rawValue == 8 ? $0.data1 : nil }
                let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
                // The tap's run loop source is on the main run loop, so this runs on the main thread.
                let take = MainActor.assumeIsolated { keys.handle(type, data, fine: fine) }
                return take ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        log.info("brightness keys: listening")
        return true
    }

    /// Whether to take the event. `data1` is a media key's, nil for anything else.
    private func handle(_ type: CGEventType, _ data1: Int?, fine: Bool) -> Bool {
        // macOS turns a tap off that it thinks is too slow; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == Self.systemDefined, let data1 else { return false }
        let code = (data1 & 0xFFFF_0000) >> 16
        guard code == Self.brightnessUp || code == Self.brightnessDown else { return false }
        let pressed = (data1 & 0xFF00) >> 8 == 0x0A
        return onKey(code == Self.brightnessUp, fine, pressed)
    }
}

/// The display the user is working on: the one holding most of the frontmost app's frontmost window, or else the one
/// under the pointer.
enum FocusedDisplay {
    static func current() -> CGDirectDisplayID? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
           let display = display(containing: CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)) {
            return display
        }
        // Global display coordinates have their origin at the top left of the main display; AppKit's at the bottom.
        let mouse = NSEvent.mouseLocation
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return display(containing: CGRect(x: mouse.x, y: height - mouse.y, width: 1, height: 1))
    }

    /// The display showing the largest part of `rect`, in global display coordinates.
    private static func display(containing rect: CGRect) -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, UInt32(ids.count), &ids, &count) == .success, count > 0 else { return nil }
        return ids.prefix(Int(count)).max { area(rect, $0) < area(rect, $1) }
    }

    private static func area(_ rect: CGRect, _ display: CGDirectDisplayID) -> CGFloat {
        let overlap = rect.intersection(CGDisplayBounds(display))
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
