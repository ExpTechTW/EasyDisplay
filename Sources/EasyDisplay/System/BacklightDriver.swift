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
        /// Down to what macOS can show, before handing it the backlight: a short fade, as macOS changes brightness itself.
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
        /// Writes elsewhere over the last stretch, and how visible they were.
        case interference(Interference)
    }

    /// Writes from elsewhere, gathered over a stretch of time so a ramp of a hundred writes a second is one line in the
    /// log. Something else's level only shows for as long as it takes to write ours back, and not at all when our cap
    /// (BLNitsCap) stayed below it: the panel shows the lower of the two.
    struct Interference: Sendable {
        var writes = 0
        /// Writes the panel could show: the lower of level and cap more than 2% away from ours. A higher level under our
        /// own cap doesn't show; corebrightnessd writes the level alone after wake and while the slider is pinned.
        var visible = 0
        /// The level furthest from ours that showed, and ours at the time.
        var worst: (level: Double, held: Double)?
        /// The longest a foreign level stayed on screen before it was written back, in milliseconds.
        var longestMilliseconds = 0.0
        var first: UInt64 = 0
        var last: UInt64 = 0
        /// What the driver was doing: holding, easing to a goal, following the dimming, handing over.
        var during: String = ""
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
    /// Called once the level has reached its goal, for `ease(to:)`.
    private var arrived: (() -> Void)?
    private var easing: (token: UUID, continuation: CheckedContinuation<Void, Never>)?
    private var reportedAt: UInt64 = 0
    private var overwriteReportedAt: UInt64 = 0
    private var interference: Interference?
    /// A burst of writes elsewhere ends once none has come for this long.
    private static let interferenceGap: UInt64 = 1_000_000_000
    /// Until then, the backlight is read every `closeCheck` instead of waiting for the framebuffer's messages.
    private var closeWatchUntil: UInt64 = 0
    private var closeWatching = false
    /// When the backlight was last seen as ours, while watching closely: a write elsewhere found now showed since then.
    private var lastSeenOurs: UInt64 = 0
    /// Between two reads while watching closely. A read takes about 10 µs, a write about 280.
    private static let closeCheck: useconds_t = 100

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
            state = .holding
            framebuffer.raiseOuterCaps(to: BuiltInDisplay.maxBoostNits)
            framebuffer.drive(nits: level)
            listen()
            schedule()
            return level
        }
    }

    /// Watches the backlight closely for `seconds`: while boost starts, turning the system's auto-brightness off and
    /// switching the preset make corebrightnessd write the backlight about a hundred times a second, and the
    /// framebuffer's messages about it can come many milliseconds late. Read every 0.1 ms instead, a write elsewhere is undone before its paired cap or level write
    /// lands, so it doesn't show, or shows for a fraction of a millisecond. It costs a fifth of a core while it lasts.
    func watchClosely(for seconds: Double) {
        queue.async { [self] in
            closeWatchUntil = max(closeWatchUntil, DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9))
            watchCloselyNow()
        }
    }

    func steer(to nits: Double, pace: Pace) {
        queue.async { [self] in
            goal = nits
            self.pace = pace
            schedule()
        }
    }

    /// Fades to `nits` with the hand-over pace; returns once it's there, or after a second and a half at most.
    func ease(to nits: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard state == .holding, current != nits else {
                    continuation.resume()
                    return
                }
                goal = nits
                pace = .handOver
                // Whichever comes first, arriving or the time limit, resumes; both run on the queue.
                let token = UUID()
                easing = (token, continuation)
                arrived = { [self] in finishEasing(token) }
                queue.asyncAfter(deadline: .now() + 1.5) { [self] in finishEasing(token) }
                schedule()
            }
        }
    }

    /// Only called on the queue.
    private func finishEasing(_ token: UUID) {
        guard let easing, easing.token == token else { return }
        self.easing = nil
        arrived = nil
        easing.continuation.resume()
    }

    /// Lets go of the backlight, leaving the level as it is: macOS has been made to want this level already, so there's
    /// nothing left to hold. Puts back the cap macOS last wrote (ours would clamp its next ramps), or `fallbackCap`.
    /// Returns the level macOS last wrote, if it wrote one.
    @discardableResult
    func release(fallbackCap: Double) async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            queue.async { [self] in
                let written = foreign
                if state != .stopped {
                    framebuffer.setNits(BuiltInFramebuffer.backlightCapKey, max(written?.cap ?? fallbackCap, current))
                }
                finish()
                continuation.resume(returning: written?.level)
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

    /// Reads the backlight every 0.1 ms until `closeWatchUntil`, from a thread of its own: each read is a moment on the
    /// queue, which stays free for everything else in between (the timer's easing, the main thread's calls).
    private func watchCloselyNow() {
        guard !closeWatching, state != .stopped else { return }
        closeWatching = true
        lastSeenOurs = DispatchTime.now().uptimeNanoseconds
        let thread = Thread { [self] in
            while queue.sync(execute: { () -> Bool in
                guard state != .stopped, DispatchTime.now().uptimeNanoseconds < closeWatchUntil else {
                    closeWatching = false
                    return false
                }
                check()
                return true
            }) {
                usleep(Self.closeCheck)
            }
        }
        thread.name = "EasyDisplay.backlight.watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Where the level is going: the goal, never above the system's dimming.
    private var target: Double {
        min(goal, dimmedTo ?? .infinity)
    }

    /// Reads the backlight; anything written elsewhere is written back, and the system's own changes followed.
    private func check() {
        guard state != .stopped, let level = framebuffer.nits(BuiltInFramebuffer.levelKey) else { return }
        // Off is the system's call; EasyDisplay's own lowest is 2 nits.
        if level < 0.5 {
            if state != .off {
                closeInterference()
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
            closeWatchUntil = max(closeWatchUntil, DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
            watchCloselyNow()
            return
        }
        let cap = framebuffer.nits(BuiltInFramebuffer.backlightCapKey) ?? level
        guard abs(level - current) > 0.5 || abs(cap - current) > 0.5 else {
            lastSeenOurs = DispatchTime.now().uptimeNanoseconds
            return
        }
        // The message arrives after the write; the cap read with the level says whether it showed.
        let now = DispatchTime.now().uptimeNanoseconds
        let previous = foreign
        foreign = (level, cap, now)
        followDimming(level, previous: previous, now: now)
        let held = current
        retake()
        // Watching closely, it showed at most since the last read that found it ours; otherwise, from when it was seen.
        record(level: level, cap: cap, held: held, landed: closeWatching ? lastSeenOurs : now)
        lastSeenOurs = DispatchTime.now().uptimeNanoseconds
        if dimmedTo == nil, now - overwriteReportedAt >= Self.overwriteReportInterval {
            overwriteReportedAt = now
            send(.overwritten(level))
        }
        schedule()
    }

    /// Adds a write from elsewhere to the current burst. `landed` is when the write was seen; the time until ours was
    /// back is how long it could have shown.
    private func record(level: Double, cap: Double, held: Double, landed: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        if let burst = interference, now - burst.last > Self.interferenceGap { closeInterference() }
        var burst = interference ?? Interference(first: now, during: activity)
        burst.writes += 1
        burst.last = now
        // What the panel showed: the lower of level and cap.
        let shown = min(level, cap)
        if dimmedTo == nil, abs(shown - held) > max(1, held * 0.02) {
            burst.visible += 1
            if abs(shown - held) > abs((burst.worst?.level ?? held) - (burst.worst?.held ?? held)) { burst.worst = (shown, held) }
            burst.longestMilliseconds = max(burst.longestMilliseconds, Double(now - landed) / 1e6)
        }
        interference = burst
    }

    /// Sends the burst of writes elsewhere to the main thread, which logs it.
    private func closeInterference() {
        guard let burst = interference else { return }
        interference = nil
        send(.interference(burst))
    }

    private var activity: String {
        if dimmedTo != nil { return "跟著系統調暗" }
        if current != goal { return "漸變中" }
        return "維持亮度"
    }

    /// The dimming before display sleep is corebrightnessd ramping the level down, many steps a second, with nobody at
    /// the Mac. Followed, it dims as macOS would; the user coming back undims it.
    private func followDimming(_ level: Double, previous: (level: Double, cap: Double, at: UInt64)?, now: UInt64) {
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
        if let burst = interference, DispatchTime.now().uptimeNanoseconds - burst.last > Self.interferenceGap { closeInterference() }
        guard state == .holding else {
            schedule()
            return
        }
        if dimmedTo != nil, Self.userIdleSeconds < Self.idleBeforeDimming { undim() }
        let target = target
        if current != target {
            let fraction = dimmedTo != nil ? Pace.quick.fraction : pace.fraction
            current = Self.step(from: current, toward: target, fraction: fraction)
            framebuffer.drive(nits: current)
            if current == target || DispatchTime.now().uptimeNanoseconds - reportedAt >= Self.reportInterval { report() }
        }
        if current == goal, let arrived {
            self.arrived = nil
            arrived()
        }
        schedule()
    }

    /// Tells the main thread the level now.
    private func report() {
        reportedAt = DispatchTime.now().uptimeNanoseconds
        let level = current
        DispatchQueue.main.async { [onLevel] in MainActor.assumeIsolated { onLevel(level) } }
    }

    /// Writes the level back, the backlight cap first: with our cap back, a higher level written elsewhere no longer
    /// shows. Then the outer caps, which a preset switch or wake may have lowered.
    private func retake() {
        framebuffer.drive(nits: current)
        framebuffer.raiseOuterCaps(to: BuiltInDisplay.maxBoostNits)
    }

    /// 30 times a second while moving or handing over, or without the framebuffer's messages; otherwise twice a
    /// second.
    private func schedule() {
        guard state != .stopped else { return }
        let moving = notificationPort == nil || state == .holding && current != target
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
            Log.warn("backlight", "收不到 framebuffer 的亮度通知（\(result)），改成每秒檢查 30 次")
        }
    }

    private func finish() {
        closeInterference()
        state = .stopped
        if let easing { finishEasing(easing.token) }
        arrived = nil
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
