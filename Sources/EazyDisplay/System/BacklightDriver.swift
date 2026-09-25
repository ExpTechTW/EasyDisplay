import Foundation

/// Holds the built-in backlight at a level while boosted, on a queue of its own, so neither a busy main thread nor
/// SwiftUI can delay it. 30 times a second it reads the level once: written elsewhere (corebrightnessd, a True Tone
/// adjustment, wake) it's written back within a tick; off (display sleep, lid, lock) it's left off until the system
/// turns it back on; and on the way to a new goal it moves one eased step.
///
/// The main thread only sets the goal, and hears back when the level has visibly changed (at most 10 times a second)
/// or something else wrote it.
final class BacklightDriver: @unchecked Sendable {
    /// How fast the level eases to its goal, as a time constant (63% of the way, on a log scale so it looks even at
    /// any brightness). The slider and keys are quick; ambient light changes are slow, brightening faster than
    /// dimming, as macOS's own auto-brightness.
    enum Pace: Sendable {
        case quick, brighten, dim

        var seconds: Double {
            switch self {
            case .quick: 0.08
            case .brighten: 1
            case .dim: 3
            }
        }

        /// The share of the remaining distance covered each tick.
        var fraction: Double {
            switch self {
            case .quick: Self.quickFraction
            case .brighten: Self.brightenFraction
            case .dim: Self.dimFraction
            }
        }

        private static let quickFraction = share(Pace.quick.seconds)
        private static let brightenFraction = share(Pace.brighten.seconds)
        private static let dimFraction = share(Pace.dim.seconds)

        private static func share(_ seconds: Double) -> Double {
            1 - exp(-1 / (BacklightDriver.ticksPerSecond * seconds))
        }
    }

    enum Event: Sendable {
        /// Something else wrote the level; it has been written back.
        case overwritten(Double)
        case off, on
    }

    static let ticksPerSecond = 30.0
    /// The UI shows whole nits; it hears about the ramp this often at most.
    private static let reportInterval: UInt64 = 100_000_000

    private let framebuffer: BuiltInFramebuffer
    private let queue = DispatchQueue(label: "EazyDisplay.backlight", qos: .userInteractive)
    private let onLevel: @MainActor @Sendable (Double) -> Void
    private let onEvent: @MainActor @Sendable (Event) -> Void

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var current = 0.0
    private var goal = 0.0
    private var pace = Pace.quick
    private var off = false
    private var reportedAt: UInt64 = 0

    init(
        framebuffer: BuiltInFramebuffer,
        onLevel: @escaping @MainActor @Sendable (Double) -> Void,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        self.framebuffer = framebuffer
        self.onLevel = onLevel
        self.onEvent = onEvent
    }

    /// Starts holding `nits`, at once unless the display is off: then it's left dark until the system turns it on.
    func start(at nits: Double) {
        queue.async { [self] in
            current = nits
            goal = nits
            framebuffer.raiseOuterCaps(to: BuiltInDisplay.maxBoostNits)
            off = (framebuffer.nits(BuiltInFramebuffer.levelKey) ?? 0) < 0.5
            if !off { framebuffer.drive(nits: nits) }
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1 / Self.ticksPerSecond, repeating: 1 / Self.ticksPerSecond, leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func steer(to nits: Double, pace: Pace) {
        queue.async { [self] in
            goal = nits
            self.pace = pace
        }
    }

    /// One step from `nits` toward `goal`: `nits × (goal / nits)^fraction`, the same as easing log(nits) linearly,
    /// in one pow. The last 0.2% is invisible; it arrives instead of creeping.
    static func step(from nits: Double, toward goal: Double, fraction: Double) -> Double {
        let next = nits * pow(goal / nits, fraction)
        return abs(next - goal) < max(0.2, goal * 0.002) ? goal : next
    }

    private func tick() {
        guard let level = framebuffer.nits(BuiltInFramebuffer.levelKey) else { return }
        // Off is the system's call; EazyDisplay's own lowest is 2 nits.
        if level < 0.5 {
            if !off {
                off = true
                send(.off)
            }
            return
        }
        if off {
            off = false
            retake()
            send(.on)
            return
        }
        if abs(level - current) > 1 {
            retake()
            send(.overwritten(level))
        }
        guard current != goal else { return }
        current = Self.step(from: current, toward: goal, fraction: pace.fraction)
        framebuffer.drive(nits: current)
        let now = DispatchTime.now().uptimeNanoseconds
        if current == goal || now - reportedAt >= Self.reportInterval {
            reportedAt = now
            let level = current
            DispatchQueue.main.async { [onLevel] in MainActor.assumeIsolated { onLevel(level) } }
        }
    }

    /// Writes the level back after something else set it, which may have lowered the outer caps too.
    private func retake() {
        framebuffer.raiseOuterCaps(to: BuiltInDisplay.maxBoostNits)
        framebuffer.drive(nits: current)
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [onEvent] in MainActor.assumeIsolated { onEvent(event) } }
    }
}
