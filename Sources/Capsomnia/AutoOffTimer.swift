import Foundation

/// Preset auto-off durations offered in the UI, in minutes.
///
/// `0` is a distinct "no timer" state (awake mode stays on until Caps Lock is
/// turned off manually). It is offered separately as the "Off" chip rather than
/// living in `minuteOptions`.
enum AutoOffPreset {
    /// Finite quick-pick durations, in minutes.
    static let minuteOptions: [Int] = [15, 30, 60, 120, 240, 480]

    /// Lower/upper bounds for the custom picker.
    static let minCustomMinutes = 1
    static let maxCustomMinutes = 24 * 60
    static let customHourStep = 60
    static let customMinuteStep = 1

    /// Whether `minutes` maps to one of the fixed quick-pick chips.
    static func isQuickPick(_ minutes: Int) -> Bool {
        minuteOptions.contains(minutes)
    }

    /// Apply a custom-picker step while keeping the result within its bounds.
    static func adjustedCustomMinutes(_ minutes: Int, by delta: Int) -> Int {
        min(max(minutes + delta, minCustomMinutes), maxCustomMinutes)
    }

    static let minutesPerDay = 24 * 60
    static let defaultUntilMinutesFromMidnight = 23 * 60
    static let untilHourStep = 60
    static let untilMinuteStep = 1

    static func clampedUntilMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 0), minutesPerDay - 1)
    }

    /// Wrap a clock-time adjustment into `00:00...23:59`.
    static func adjustedUntilMinutes(_ minutes: Int, by delta: Int) -> Int {
        let day = minutesPerDay
        let total = clampedUntilMinutes(minutes) + delta
        return ((total % day) + day) % day
    }
}

/// Configured auto-off behavior. Duration and clock-time are mutually exclusive.
enum AutoOffSchedule: Equatable {
    case off
    case duration(minutes: Int)
    case until(minutesFromMidnight: Int)

    var isArmed: Bool {
        switch self {
        case .off:
            return false
        case .duration(let minutes):
            return minutes > 0
        case .until:
            return true
        }
    }

    static func clamped(_ schedule: AutoOffSchedule) -> AutoOffSchedule {
        switch schedule {
        case .off:
            return .off
        case .duration(let minutes):
            let clamped = min(max(minutes, 0), AutoOffPreset.maxCustomMinutes)
            return clamped == 0 ? .off : .duration(minutes: clamped)
        case .until(let minutes):
            return .until(minutesFromMidnight: AutoOffPreset.clampedUntilMinutes(minutes))
        }
    }
}

/// What the auto-off readout should show. Computed by the app delegate from the
/// live Caps Lock state and the pending timer state; rendered by the UI control.
enum AutoOffDisplayState: Equatable {
    /// Awake mode is off. Shows the configured duration, clock time, or infinity.
    case idle(AutoOffSchedule)
    /// Awake mode is on with no timer configured.
    case infinite
    /// Awake mode is on and a timer is running down.
    case counting(remaining: TimeInterval)
}

/// The timer bookkeeping the app delegate keeps between polls.
///
/// - `deadline` is set while awake mode is counting down.
struct AutoOffState: Equatable {
    var deadline: Date?

    init(deadline: Date? = nil) {
        self.deadline = deadline
    }
}

/// Carries an elapsed auto-off through the existing Caps Lock and helper
/// synchronization path, then requests immediate system sleep exactly once.
///
/// The app only calls `requestSleepIfReady` after `SleepDisabled` has been
/// confirmed to match the current Caps Lock state. Keeping the pending bit here
/// makes that ordering explicit and testable without sleeping the test Mac.
final class AutoOffSleepCoordinator {
    private(set) var isPending = false
    private let requestSleep: () -> CommandResult

    init(
        requestSleep: @escaping () -> CommandResult = {
            SystemSleepRequester.request()
        }
    ) {
        self.requestSleep = requestSleep
    }

    func recordCapsLockResult(_ result: CapsLockToggleResult) {
        isPending = result == .changed(to: false)
    }

    @discardableResult
    func cancelPending() -> Bool {
        let wasPending = isPending
        isPending = false
        return wasPending
    }

    /// Requests sleep once the confirmed state is OFF. A confirmed ON state
    /// means the user re-enabled awake mode before completion, so the pending
    /// sleep is cancelled rather than firing later against their intent.
    func requestSleepIfReady(capsLockOn: Bool) -> CommandResult? {
        guard isPending else { return nil }

        if capsLockOn {
            isPending = false
            return nil
        }

        isPending = false
        return requestSleep()
    }
}

/// Pure scheduling policy for the auto-off timer. No side effects, so the whole
/// behavior can be unit-tested without hardware, timers, or a run loop.
enum AutoOffPolicy {
    /// Advance the timer state and decide whether awake mode should turn off now.
    ///
    /// - Parameters:
    ///   - capsLockOn: whether awake mode (Caps Lock) is currently on.
    ///   - schedule: the configured duration, clock time, or off.
    ///   - now: the current instant.
    ///   - calendar: used only for clock-time schedules.
    ///   - state: the current timer state.
    /// - Returns: the next `state` to persist and `shouldFire`, which is `true`
    ///   exactly once when the countdown reaches zero.
    static func evaluate(
        capsLockOn: Bool,
        schedule: AutoOffSchedule,
        now: Date,
        calendar: Calendar = .current,
        state: AutoOffState
    ) -> (state: AutoOffState, shouldFire: Bool) {
        // Timer disabled: no deadline, no memory.
        guard schedule.isArmed else {
            return (AutoOffState(), false)
        }

        guard capsLockOn else {
            // Turning awake mode off ends the current timer session. The next
            // re-enable always starts a fresh countdown.
            return (AutoOffState(), false)
        }

        // Awake mode is on.
        if let deadline = state.deadline {
            if now >= deadline {
                return (AutoOffState(), true)
            }
            return (AutoOffState(deadline: deadline), false)
        }

        // Just turned on (or the timer was just re-armed): begin a fresh countdown.
        guard let deadline = deadline(for: schedule, now: now, calendar: calendar) else {
            return (AutoOffState(), false)
        }
        return (AutoOffState(deadline: deadline), false)
    }

    /// A fresh countdown for the explicit Restart action.
    static func restarted(
        capsLockOn: Bool,
        schedule: AutoOffSchedule,
        now: Date,
        calendar: Calendar = .current
    ) -> AutoOffState {
        guard schedule.isArmed else { return AutoOffState() }
        guard capsLockOn else { return AutoOffState() }
        return AutoOffState(deadline: deadline(for: schedule, now: now, calendar: calendar))
    }

    /// Next fire instant for `schedule`. Clock-time values that are already
    /// past (or exactly now) roll to the following day.
    static func deadline(
        for schedule: AutoOffSchedule,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        switch AutoOffSchedule.clamped(schedule) {
        case .off:
            return nil
        case .duration(let minutes):
            return now.addingTimeInterval(TimeInterval(minutes) * 60)
        case .until(let minutesFromMidnight):
            return nextClockTime(
                minutesFromMidnight: minutesFromMidnight,
                after: now,
                calendar: calendar
            )
        }
    }

    static func nextClockTime(
        minutesFromMidnight: Int,
        after now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let clamped = AutoOffPreset.clampedUntilMinutes(minutesFromMidnight)
        var components = DateComponents()
        components.hour = clamped / 60
        components.minute = clamped % 60
        components.second = 0
        if let next = calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime
        ) {
            return next
        }
        return now.addingTimeInterval(TimeInterval(AutoOffPreset.minutesPerDay * 60))
    }
}

/// Formatting helpers for the auto-off readout and chips.
enum AutoOffFormatter {
    /// `HH:MM:SS` countdown, clamped at zero and never negative.
    static func countdown(_ remaining: TimeInterval) -> String {
        let (hours, minutes, seconds) = components(remaining)
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Compact, language-neutral duration label: "∞", "15m", "1h", "1h 30m".
    static func durationLabel(minutes: Int) -> String {
        guard minutes > 0 else { return "∞" }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return "\(mins)m" }
        if mins == 0 { return "\(hours)h" }
        return "\(hours)h \(mins)m"
    }

    /// Language-neutral clock label: "00:00", "09:05", "23:00".
    static func clockLabel(minutesFromMidnight: Int) -> String {
        let clamped = AutoOffPreset.clampedUntilMinutes(minutesFromMidnight)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func idleLabel(for schedule: AutoOffSchedule) -> String {
        switch AutoOffSchedule.clamped(schedule) {
        case .off:
            return durationLabel(minutes: 0)
        case .duration(let minutes):
            return durationLabel(minutes: minutes)
        case .until(let minutes):
            return clockLabel(minutesFromMidnight: minutes)
        }
    }

    private static func components(_ remaining: TimeInterval) -> (Int, Int, Int) {
        let total = max(0, Int(remaining.rounded(.down)))
        return (total / 3600, (total % 3600) / 60, total % 60)
    }
}
