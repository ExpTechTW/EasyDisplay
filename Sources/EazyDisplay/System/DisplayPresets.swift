import CoreGraphics
import Foundation

/// Display presets (reference modes) via the private MonitorPanel framework, as used by
/// System Settings › Displays › Preset.
@MainActor
enum DisplayPresets {
    struct Preset {
        let index: Int
        let name: String
        let maxSDRNits: Double
        let maxHDRNits: Double
        let isAppleDefault: Bool
    }

    private static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_NOW) != nil

    private static func panelDisplay(_ id: CGDirectDisplayID) -> NSObject? {
        guard loaded, let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type,
              let displays = managerClass.init().value(forKey: "displays") as? [NSObject]
        else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == id }
    }

    private static func preset(from object: NSObject) -> Preset? {
        guard object.value(forKey: "isValid") as? Bool == true,
              let index = (object.value(forKey: "presetIndex") as? NSNumber)?.intValue,
              let info = object.value(forKey: "presetDictionary") as? [String: Any]
        else { return nil }
        return Preset(
            index: index,
            name: object.value(forKey: "presetName") as? String ?? "Preset \(index)",
            maxSDRNits: (info["PresetMaxSDRLuminance"] as? NSNumber)?.doubleValue ?? 0,
            maxHDRNits: (info["PresetMaxHDRLuminance"] as? NSNumber)?.doubleValue ?? 0,
            isAppleDefault: (info["PresetOrigin"] as? NSNumber)?.intValue == 0
        )
    }

    static func presets(for display: CGDirectDisplayID) -> [Preset] {
        guard let objects = panelDisplay(display)?.value(forKey: "presets") as? [NSObject] else { return [] }
        return objects.compactMap(preset(from:))
    }

    static func active(for display: CGDirectDisplayID) -> Preset? {
        (panelDisplay(display)?.value(forKey: "activePreset") as? NSObject).flatMap(preset(from:))
    }

    /// Apple's "Apple Display (P3-600 nits)": SDR and HDR both capped at 600 nits, so the
    /// EDR headroom stays at 1.0 and corebrightnessd never rescales the backlight for HDR.
    static func sdr600(for display: CGDirectDisplayID) -> Preset? {
        presets(for: display).first { $0.isAppleDefault && $0.maxSDRNits == 600 && $0.maxHDRNits == 600 }
    }

    @discardableResult
    static func activate(index: Int, on display: CGDirectDisplayID) -> Bool {
        guard let panel = panelDisplay(display),
              let objects = panel.value(forKey: "presets") as? [NSObject],
              let target = objects.first(where: { ($0.value(forKey: "presetIndex") as? NSNumber)?.intValue == index })
        else { return false }
        let selector = NSSelectorFromString("setActivePreset:")
        guard panel.responds(to: selector) else { return false }
        typealias SetActive = @convention(c) (NSObject, Selector, NSObject) -> Bool
        return unsafeBitCast(panel.method(for: selector), to: SetActive.self)(panel, selector, target)
    }
}
