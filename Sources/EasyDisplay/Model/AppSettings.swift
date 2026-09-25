import Foundation
import Observation

/// Preferences, kept in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let boostAutoBrightness = "boost.autoBrightness"
        static let restoreBoostAtLaunch = "boost.restoreAtLaunch"
        static let boostWasOn = "boost.wasOn"
        static let learnedPoints = "boost.learnedPoints"
        static let monitorRetentionDays = "monitor.retentionDays"
        static let handlesBrightnessKeys = "keys.brightness"
    }

    /// Days of history kept, at least the longest chart and analysis period.
    static let retentionChoices = [30, 90, 365]

    @ObservationIgnored private let defaults: UserDefaults

    /// While boosted, follow the ambient light instead of holding the slider's level.
    var boostAutoBrightness: Bool {
        didSet { defaults.set(boostAutoBrightness, forKey: Key.boostAutoBrightness) }
    }

    /// Turn boost back on at launch when it was on at quit. On unless turned off.
    var restoreBoostAtLaunch: Bool {
        didSet { defaults.set(restoreBoostAtLaunch, forKey: Key.restoreBoostAtLaunch) }
    }

    /// Whether boost was on when EasyDisplay last quit. Only turning it off by hand clears it.
    @ObservationIgnored var boostWasOn: Bool {
        didSet { defaults.set(boostWasOn, forKey: Key.boostWasOn) }
    }

    /// The brightnesses the user chose for boosted auto-brightness, each at the light level it was chosen at.
    var autoCurve: AutoBrightnessCurve {
        didSet { defaults.set(try? JSONEncoder().encode(autoCurve.points), forKey: Key.learnedPoints) }
    }

    /// How many days the monitor keeps, every second of it and its summaries alike.
    var monitorRetentionDays: Int {
        didSet { defaults.set(monitorRetentionDays, forKey: Key.monitorRetentionDays) }
    }

    var monitorRetention: TimeInterval { TimeInterval(monitorRetentionDays) * 24 * 60 * 60 }

    /// EasyDisplay takes the brightness keys and changes the display in use, with its own indicator. On unless turned
    /// off; needs Accessibility access.
    var handlesBrightnessKeys: Bool {
        didSet { defaults.set(handlesBrightnessKeys, forKey: Key.handlesBrightnessKeys) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        boostAutoBrightness = defaults.object(forKey: Key.boostAutoBrightness) as? Bool ?? true
        restoreBoostAtLaunch = defaults.object(forKey: Key.restoreBoostAtLaunch) as? Bool ?? true
        boostWasOn = defaults.bool(forKey: Key.boostWasOn)
        let points = defaults.data(forKey: Key.learnedPoints).flatMap { try? JSONDecoder().decode([LearnedPoint].self, from: $0) }
        autoCurve = AutoBrightnessCurve(points: points ?? [])
        // One global multiplier, from before auto-brightness learned per light level.
        defaults.removeObject(forKey: "boost.autoPreference")
        let days = defaults.integer(forKey: Key.monitorRetentionDays)
        monitorRetentionDays = Self.retentionChoices.contains(days) ? days : 30
        handlesBrightnessKeys = defaults.object(forKey: Key.handlesBrightnessKeys) as? Bool ?? true
    }
}
