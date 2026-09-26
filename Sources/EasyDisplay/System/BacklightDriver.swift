import CoreGraphics
import Foundation
import IOKit

/// Holds the built-in backlight while boosted, on a queue of its own, so neither a busy main thread nor SwiftUI can
/// delay it, and makes every change to it an eased one.
///
/// The framebuffer sends a message whenever its brightness properties change, so a level written elsewhere
/// (corebrightnessd reacting to the pinned slider, a preset switch, wake) is written back as soon as it lands, within
/// about a millisecond, before the panel shows it. The system still decides when the display is off (sleep, the lid,
/// lock): it's left off until the system turns it on, then back where it was. The dimming before display sleep is
/// followed down, eased, and eased back up when the user returns.
///
/// Moving, the level takes one eased step 30 times a second; holding still, it's only checked twice a second, in case
/// a change came without a message.
///
/// The main thread only sets the goal, and hears back when the level has visibly changed (at most 10 times a second)
/// or something else wrote it.
final class BacklightDriver: @unchecked Sendable {
    /// How fast the level eases to its goal, as a time constant (63% of the way, on a log scale so it looks even at
    /// any brightness). The slider and keys are quick; ambient light changes are slow, brightening faster than
    /// dimming, as macOS's own auto-brightness.
    enum Pace: Sendable {
        /// The slider and keys, and the dimming before display sleep.
        case quick
        /// Handing the backlight back to macOS: a short fade, as macOS changes brightness itself.
        case handOver
        case brighten, dim

        var seconds: Double {
            switch self {
            case .quick: 0.08
            case .handOver: 0.15
            case .brighten: 1
            case .dim: 3
            }
        }

        /// The share of the remaining distance covered each tick.
        var fraction: Double {
            switch self {
            case .quick: Self.quickFraction
            case .handOver: Self.handOverFraction
            case .brighten: Self.brightenFraction
            case .dim: Self.dimFraction
            }
        }

        private static let quickFraction = share(Pace.quick.seconds)
        private static let handOverFraction = share(Pace.handOver.seconds)
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
        /// The system started dimming the display before it sleeps, or stopped because the user is back.
        case dimming, undimmed
    }

    private enum State {
        case stopped, holding, off
    }

    static let ticksPerSecond = 30.0
    /// Holding still, a write that came without a message is still caught this often.
    private static let idleCheck = 0.5
    /// The UI shows whole nits; it hears about the ramp this often at most.
    private static let reportInterval: UInt64 = 100_000_000
    /// The main thread hears about writes elsewhere this often at most; corebrightnessd ramps write 120 times a second.
    private static let overwriteReportInterval: UInt64 = 250_000_000
    /// No keyboard or pointer input for this long, a falling level from elsewhere is the dimming before display sleep.
    static let idleBeforeDimming: TimeInterval = 10
    /// Handing over, corebrightnessd is done ramping once it hasn't written for this long (its ramps write every 8 to
    /// 50 ms).
    private static let settled: UInt64 = 400_000_000
    /// Handing over waits at most this long for corebrightnessd to settle, and for it to write at all.
    private static let settleLimit: UInt64 = 6_000_000_000
    private static let firstWriteLimit: UInt64 = 1_500_000_000
    /// And eases for at most this long once it has.
    private static let easeLimit: UInt64 = 1_500_000_000

    private let framebuffer: BuiltInFramebuffer
    private let queue = DispatchQueue(label: "EasyDisplay.backlight", qos: .userInteractive)
    private let onLevel: @MainActor @Sendable (Double) -> Void
    private let onEvent: @MainActor @Sendable (Event) -> Void

    // Only touched on `queue`.
    private var state = State.stopped
    private var timer: DispatchSourceTimer?
    private var timerIsFast = false
    private var notificationPort: IONotificationPortRef?
    private var notification: io_object_t = 0
    /// The level written now, and where it's easing to.
    private var current = 0.0
    private var goal = 0.0
    private var pace = Pace.quick
    /// While the system dims the display before it sleeps: the level it has dimmed to, which the level follows down.
    private var dimmedTo: Double?
    /// The last level and cap written elsewhere, which is where corebrightnessd wants the backlight.
    private var foreign: (level: Double, cap: Double, at: UInt64)?
    /// Set while handing the backlight back: when it began, when corebrightnessd was found settled, and what to call
    /// once it's done.
    private var handingOver: (began: UInt64, settledAt: UInt64?, done: (Bool) -> Void)?
    private var reportedAt: UInt64 = 0
    private var overwriteReportedAt: UInt64 = 0

    init(
        framebuffer: BuiltInFramebuffer,
        onLevel: @escaping @MainActor @Sendable (Double) -> Void,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        self.framebuffer = framebuffer
        self.onLevel = onLevel
        self.onEvent = onEvent
    }

    /// Seconds since the last keyboard, pointer or trackpad input.
    static var userIdleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    private static let anyInput = CGEventType(rawValue: ~0)!

    /// Takes the backlight where it is now and holds it there, before anything else can write it; returns the level
    /// held. Nil when the display is off: there's nothing to hold, and the backlight isn't taken.
    func holdCurrent() -> Double? {
        queue.sync {
            guard let level = framebuffer.nits(BuiltInFramebuffer.levelKey), level >= 0.5 else { return nil }
            current = level
            goal = level
            dimmedTo = nil
            // Only what corebrightnessd writes from now on says where it wants the backlight.
            foreign = nil
            handingOver = nil
            state = .holding
            framebuffer.raiseOuterCaps(to: BuiltInDisplay.maxBoostNits)
            framebuffer.drive(nits: level)
            listen()
            schedule()
            return level
        }
    }

    /// Handing over, it still moves where the level is held until corebrightnessd has settled.
    func steer(to nits: Double, pace: Pace) {
        queue.async { [self] in
            guard handingOver?.settledAt == nil else { return }
            goal = nits
            self.pace = pace
            schedule()
        }
    }

    /// Gives the backlight back to corebrightnessd without a jump. Held where it is until corebrightnessd has finished
    /// its own ramp to where it wants the backlight (at most 6 seconds), eased there in one fade, then left with exactly
    /// what corebrightnessd wrote. False when corebrightnessd wrote nothing (the display is off, or nothing changed for
    /// it): the driver just stopped, and corebrightnessd has to be made to write the backlight again.
    @discardableResult
    func handOver() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                guard state == .holding else {
                    finish()
                    continuation.resume(returning: false)
                    return
                }
                dimmedTo = nil
                handingOver = (DispatchTime.now().uptimeNanoseconds, nil, { continuation.resume(returning: $0) })
                schedule()
            }
        }
    }

    /// One step from `nits` toward `goal`: `nits × (goal / nits)^fraction`, the same as easing log(nits) linearly,
    /// in one pow. The last 0.2% is invisible; it arrives instead of creeping.
    static func step(from nits: Double, toward goal: Double, fraction: Double) -> Double {
        let next = nits * pow(goal / nits, fraction)
        return abs(next - goal) < max(0.2, goal * 0.002) ? goal : next
    }

    // MARK: - On the queue

    /// Where the level is going: the goal, or corebrightnessd's level once it has settled while handing over, and never
    /// above the system's dimming.
    private var target: Double {
        if handingOver?.settledAt != nil, let foreign { return foreign.level }
        return min(goal, dimmedTo ?? .infinity)
    }

    /// Reads the backlight; anything written elsewhere is written back, and the system's own changes followed.
    private func check() {
        guard state != .stopped, let level = framebuffer.nits(BuiltInFramebuffer.levelKey) else { return }
        // Off is the system's call; EasyDisplay's own lowest is 2 nits.
        if level < 0.5 {
            if state != .off {
                state = .off
                dimmedTo = nil
                send(.off)
            }
            return
        }
        if state == .off {
            // Back on, where it was before the display dimmed and slept, as macOS itself wakes a display.
            state = .holding
            current = goal
            retake()
            report()
            send(.on)
            schedule()
            return
        }
        let cap = framebuffer.nits(BuiltInFramebuffer.backlightCapKey) ?? level
        guard abs(level - current) > 0.5 || abs(cap - current) > 0.5 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let previous = foreign
        foreign = (level, cap, now)
        followDimming(level, previous: previous, now: now)
        retake()
        if dimmedTo == nil, now - overwriteReportedAt >= Self.overwriteReportInterval {
            overwriteReportedAt = now
            send(.overwritten(level))
        }
        schedule()
    }

    /// The dimming before display sleep is corebrightnessd ramping the level down, many steps a second, with nobody at
    /// the Mac. Followed, it dims as macOS would; the user coming back undims it.
    private func followDimming(_ level: Double, previous: (level: Double, cap: Double, at: UInt64)?, now: UInt64) {
        guard handingOver == nil else { return }
        let idle = Self.userIdleSeconds >= Self.idleBeforeDimming
        if let dimmed = dimmedTo {
            if idle, level <= dimmed + 0.5 {
                dimmedTo = level
            } else {
                undim()
            }
            return
        }
        guard idle, let previous, now - previous.at < 250_000_000, level < previous.level * 0.99, level < current else { return }
        dimmedTo = level
        send(.dimming)
    }

    private func undim() {
        dimmedTo = nil
        pace = .quick
        send(.undimmed)
    }

    private func tick() {
        check()
        guard state == .holding else {
            schedule()
            return
        }
        if dimmedTo != nil, Self.userIdleSeconds < Self.idleBeforeDimming { undim() }
        if advanceHandOver() { return }
        let target = target
        if current != target {
            let fraction = handingOver != nil ? Pace.handOver.fraction : dimmedTo != nil ? Pace.quick.fraction : pace.fraction
            current = Self.step(from: current, toward: target, fraction: fraction)
            framebuffer.drive(nits: current)
            if current == target || DispatchTime.now().uptimeNanoseconds - reportedAt >= Self.reportInterval { report() }
        }
        schedule()
    }

    /// Tells the main thread the level now.
    private func report() {
        reportedAt = DispatchTime.now().uptimeNanoseconds
        let level = current
        DispatchQueue.main.async { [onLevel] in MainActor.assumeIsolated { onLevel(level) } }
    }

    /// Moves a hand-over along; true once it's over.
    private func advanceHandOver() -> Bool {
        guard var handing = handingOver else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let foreign else {
            guard now - handing.began >= Self.firstWriteLimit else { return false }
            finish()
            handing.done(false)
            return true
        }
        if handing.settledAt == nil, now - foreign.at >= Self.settled || now - handing.began >= Self.settleLimit {
            handing.settledAt = now
            handingOver = handing
        }
        guard let settledAt = handing.settledAt, current == foreign.level || now - settledAt >= Self.easeLimit else {
            return false
        }
        // Exactly what corebrightnessd asked for, so its own next step carries on from there.
        framebuffer.setNits(BuiltInFramebuffer.backlightCapKey, foreign.cap)
        framebuffer.setNits(BuiltInFramebuffer.levelKey, foreign.level)
        finish()
        handing.done(true)
        return true
    }

    /// Writes the level back, with the outer caps, which a preset switch or wake may have lowered.
    private func retake() {
        framebuffer.raiseOuterCaps(to: BuiltInDisplay.maxBoostNits)
        framebuffer.drive(nits: current)
    }

    /// 30 times a second while moving or handing over, or without the framebuffer's messages; otherwise twice a
    /// second.
    private func schedule() {
        guard state != .stopped else { return }
        let moving = notificationPort == nil || state == .holding && (current != target || handingOver != nil)
        if timer != nil, moving == timerIsFast { return }
        timerIsFast = moving
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        let interval = moving ? 1 / Self.ticksPerSecond : Self.idleCheck
        timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: moving ? .milliseconds(4) : .milliseconds(100))
    }

    /// Hears the framebuffer's messages, one for each change to its brightness properties.
    private func listen() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, framebuffer.service, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<BacklightDriver>.fromOpaque(context).takeUnretainedValue().check()
        }, context, &notification)
        if result == KERN_SUCCESS {
            notificationPort = port
        } else {
            IONotificationPortDestroy(port)
            log.error("no brightness messages from the framebuffer (\(result)); checking 30 times a second instead")
        }
    }

    private func finish() {
        state = .stopped
        handingOver = nil
        dimmedTo = nil
        foreign = nil
        timer?.cancel()
        timer = nil
        timerIsFast = false
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [onEvent] in MainActor.assumeIsolated { onEvent(event) } }
    }
}
