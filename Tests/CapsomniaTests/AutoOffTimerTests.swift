import XCTest
@testable import Capsomnia

final class AutoOffPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Disabled

    func testDisabledTimerClearsStateAndNeverFires() {
        let onResult = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .off,
            now: now,
            state: AutoOffState(deadline: now.addingTimeInterval(-1))
        )
        XCTAssertEqual(onResult.state, AutoOffState())
        XCTAssertFalse(onResult.shouldFire)
    }

    // MARK: Arming / counting (awake on)

    func testArmsFullDurationOnFirstStart() {
        let result = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .duration(minutes: 30),
            now: now,
            state: AutoOffState()
        )
        XCTAssertEqual(result.state.deadline, now.addingTimeInterval(30 * 60))
        XCTAssertFalse(result.shouldFire)
    }

    func testKeepsExistingDeadlineWhileCountingDown() {
        let deadline = now.addingTimeInterval(5 * 60)
        let result = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .duration(minutes: 30),
            now: now,
            state: AutoOffState(deadline: deadline)
        )
        XCTAssertEqual(result.state.deadline, deadline)
        XCTAssertFalse(result.shouldFire)
    }

    func testFiresWhenDeadlineReached() {
        let result = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .duration(minutes: 30),
            now: now,
            state: AutoOffState(deadline: now)
        )
        XCTAssertEqual(result.state, AutoOffState())
        XCTAssertTrue(result.shouldFire)
    }

    // MARK: Re-enable behavior

    func testTurningOffClearsTheCurrentCountdown() {
        let result = AutoOffPolicy.evaluate(
            capsLockOn: false,
            schedule: .duration(minutes: 60),
            now: now,
            state: AutoOffState(deadline: now.addingTimeInterval(40 * 60))
        )
        XCTAssertEqual(result.state, AutoOffState())
        XCTAssertFalse(result.shouldFire)
    }

    func testReenableAlwaysStartsTheFullDuration() {
        let result = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .duration(minutes: 60),
            now: now,
            state: AutoOffState()
        )
        XCTAssertEqual(result.state.deadline, now.addingTimeInterval(60 * 60))
        XCTAssertFalse(result.shouldFire)
    }

    // MARK: Explicit restart

    func testRestartedArmsFullDurationWhenAwake() {
        let state = AutoOffPolicy.restarted(
            capsLockOn: true,
            schedule: .duration(minutes: 120),
            now: now
        )
        XCTAssertEqual(state.deadline, now.addingTimeInterval(120 * 60))
    }

    func testRestartedWhileOffLeavesTheNextEnableFresh() {
        let state = AutoOffPolicy.restarted(
            capsLockOn: false,
            schedule: .duration(minutes: 120),
            now: now
        )
        XCTAssertEqual(state, AutoOffState())
    }

    func testRestartedIsEmptyWhenTimerDisabled() {
        XCTAssertEqual(
            AutoOffPolicy.restarted(capsLockOn: true, schedule: .off, now: now),
            AutoOffState()
        )
    }

    // MARK: Until clock time

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0) -> Date {
        utcCalendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )!
    }

    func testUntilArmsSameDayWhenClockTimeIsStillAhead() {
        let now = utcDate(year: 2026, month: 8, day: 18, hour: 10, minute: 0)
        let result = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .until(minutesFromMidnight: 23 * 60),
            now: now,
            calendar: utcCalendar,
            state: AutoOffState()
        )
        XCTAssertEqual(
            result.state.deadline,
            utcDate(year: 2026, month: 8, day: 18, hour: 23, minute: 0)
        )
        XCTAssertFalse(result.shouldFire)
    }

    func testUntilRollsToNextDayWhenClockTimeHasPassed() {
        let now = utcDate(year: 2026, month: 8, day: 18, hour: 23, minute: 30)
        let result = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .until(minutesFromMidnight: 23 * 60),
            now: now,
            calendar: utcCalendar,
            state: AutoOffState()
        )
        XCTAssertEqual(
            result.state.deadline,
            utcDate(year: 2026, month: 8, day: 19, hour: 23, minute: 0)
        )
        XCTAssertFalse(result.shouldFire)
    }

    func testUntilRollsToNextDayWhenClockTimeIsExactlyNow() {
        let now = utcDate(year: 2026, month: 8, day: 18, hour: 23, minute: 0)
        let next = AutoOffPolicy.nextClockTime(
            minutesFromMidnight: 23 * 60,
            after: now,
            calendar: utcCalendar
        )
        XCTAssertEqual(next, utcDate(year: 2026, month: 8, day: 19, hour: 23, minute: 0))
    }

    func testUntilFiresWhenDeadlineReached() {
        let now = utcDate(year: 2026, month: 8, day: 18, hour: 23, minute: 0)
        let result = AutoOffPolicy.evaluate(
            capsLockOn: true,
            schedule: .until(minutesFromMidnight: 23 * 60),
            now: now,
            calendar: utcCalendar,
            state: AutoOffState(deadline: now)
        )
        XCTAssertEqual(result.state, AutoOffState())
        XCTAssertTrue(result.shouldFire)
    }

    func testUntilRestartRecomputesTheNextOccurrence() {
        let now = utcDate(year: 2026, month: 8, day: 18, hour: 22, minute: 0)
        let state = AutoOffPolicy.restarted(
            capsLockOn: true,
            schedule: .until(minutesFromMidnight: 23 * 60),
            now: now,
            calendar: utcCalendar
        )
        XCTAssertEqual(
            state.deadline,
            utcDate(year: 2026, month: 8, day: 18, hour: 23, minute: 0)
        )
    }

    func testMidnightUntilIsAValidArmedSchedule() {
        XCTAssertTrue(AutoOffSchedule.until(minutesFromMidnight: 0).isArmed)
        XCTAssertEqual(AutoOffFormatter.clockLabel(minutesFromMidnight: 0), "00:00")
    }
}

final class AutoOffSleepCoordinatorTests: XCTestCase {
    func testCompatibilityModeCanCancelPendingSystemSleep() {
        var sleepRequestCount = 0
        let coordinator = AutoOffSleepCoordinator {
            sleepRequestCount += 1
            return (0, "", "")
        }

        coordinator.recordCapsLockResult(.changed(to: false))

        XCTAssertTrue(coordinator.cancelPending())
        XCTAssertFalse(coordinator.isPending)
        XCTAssertNil(coordinator.requestSleepIfReady(capsLockOn: false))
        XCTAssertEqual(sleepRequestCount, 0)
        XCTAssertFalse(coordinator.cancelPending())
    }

    func testSuccessfulAutoOffSleepsOnceAfterConfirmedOff() {
        var sleepRequestCount = 0
        let coordinator = AutoOffSleepCoordinator {
            sleepRequestCount += 1
            return (0, "", "")
        }

        coordinator.recordCapsLockResult(.changed(to: false))

        XCTAssertTrue(coordinator.isPending)
        XCTAssertEqual(
            coordinator.requestSleepIfReady(capsLockOn: false)?.status,
            0
        )
        XCTAssertFalse(coordinator.isPending)
        XCTAssertEqual(sleepRequestCount, 1)
        XCTAssertNil(coordinator.requestSleepIfReady(capsLockOn: false))
        XCTAssertEqual(sleepRequestCount, 1)
    }

    func testFailedCapsLockOffNeverSleeps() {
        var sleepRequestCount = 0
        let coordinator = AutoOffSleepCoordinator {
            sleepRequestCount += 1
            return (0, "", "")
        }

        coordinator.recordCapsLockResult(.writeFailed(target: false))

        XCTAssertFalse(coordinator.isPending)
        XCTAssertNil(coordinator.requestSleepIfReady(capsLockOn: false))
        XCTAssertEqual(sleepRequestCount, 0)
    }

    func testConfirmedOnCancelsPendingSleep() {
        var sleepRequestCount = 0
        let coordinator = AutoOffSleepCoordinator {
            sleepRequestCount += 1
            return (0, "", "")
        }

        coordinator.recordCapsLockResult(.changed(to: false))

        XCTAssertNil(coordinator.requestSleepIfReady(capsLockOn: true))
        XCTAssertFalse(coordinator.isPending)
        XCTAssertNil(coordinator.requestSleepIfReady(capsLockOn: false))
        XCTAssertEqual(sleepRequestCount, 0)
    }
}

final class AutoOffFormatterTests: XCTestCase {
    func testCountdownFormatsHoursMinutesSeconds() {
        XCTAssertEqual(AutoOffFormatter.countdown(0), "00:00:00")
        XCTAssertEqual(AutoOffFormatter.countdown(59), "00:00:59")
        XCTAssertEqual(AutoOffFormatter.countdown(3661), "01:01:01")
        XCTAssertEqual(AutoOffFormatter.countdown(7200), "02:00:00")
    }

    func testCountdownClampsNegativeToZero() {
        XCTAssertEqual(AutoOffFormatter.countdown(-42), "00:00:00")
    }

    func testDurationLabelIsCompactAndLanguageNeutral() {
        XCTAssertEqual(AutoOffFormatter.durationLabel(minutes: 0), "∞")
        XCTAssertEqual(AutoOffFormatter.durationLabel(minutes: 15), "15m")
        XCTAssertEqual(AutoOffFormatter.durationLabel(minutes: 60), "1h")
        XCTAssertEqual(AutoOffFormatter.durationLabel(minutes: 90), "1h 30m")
        XCTAssertEqual(AutoOffFormatter.durationLabel(minutes: 120), "2h")
        XCTAssertEqual(AutoOffFormatter.durationLabel(minutes: 480), "8h")
    }

    func testClockLabelIsZeroPadded() {
        XCTAssertEqual(AutoOffFormatter.clockLabel(minutesFromMidnight: 0), "00:00")
        XCTAssertEqual(AutoOffFormatter.clockLabel(minutesFromMidnight: 9 * 60 + 5), "09:05")
        XCTAssertEqual(AutoOffFormatter.clockLabel(minutesFromMidnight: 23 * 60), "23:00")
    }

    func testIdleLabelUsesDurationOrClock() {
        XCTAssertEqual(AutoOffFormatter.idleLabel(for: .off), "∞")
        XCTAssertEqual(AutoOffFormatter.idleLabel(for: .duration(minutes: 90)), "1h 30m")
        XCTAssertEqual(AutoOffFormatter.idleLabel(for: .until(minutesFromMidnight: 23 * 60)), "23:00")
    }
}

final class AutoOffPresetTests: XCTestCase {
    func testQuickPickRecognizesPresetsOnly() {
        XCTAssertTrue(AutoOffPreset.isQuickPick(60))
        XCTAssertTrue(AutoOffPreset.isQuickPick(480))
        XCTAssertFalse(AutoOffPreset.isQuickPick(45))
        XCTAssertFalse(AutoOffPreset.isQuickPick(0))
    }

    func testCustomBoundsAreSane() {
        XCTAssertEqual(AutoOffPreset.minCustomMinutes, 1)
        XCTAssertEqual(AutoOffPreset.maxCustomMinutes, 24 * 60)
        XCTAssertEqual(AutoOffPreset.customHourStep, 60)
        XCTAssertEqual(AutoOffPreset.customMinuteStep, 1)
        XCTAssertEqual(AutoOffPreset.minuteOptions, [15, 30, 60, 120, 240, 480])
    }

    func testCustomMinuteAdjustmentUsesOneMinuteStepsAndClamps() {
        XCTAssertEqual(AutoOffPreset.adjustedCustomMinutes(45, by: 1), 46)
        XCTAssertEqual(AutoOffPreset.adjustedCustomMinutes(45, by: -1), 44)
        XCTAssertEqual(AutoOffPreset.adjustedCustomMinutes(1, by: -1), 1)
        XCTAssertEqual(AutoOffPreset.adjustedCustomMinutes(24 * 60, by: 1), 24 * 60)
    }

    func testUntilMinutesWrapAroundTheDay() {
        XCTAssertEqual(AutoOffPreset.defaultUntilMinutesFromMidnight, 23 * 60)
        XCTAssertEqual(AutoOffPreset.clampedUntilMinutes(-1), 0)
        XCTAssertEqual(AutoOffPreset.clampedUntilMinutes(24 * 60), 24 * 60 - 1)
        XCTAssertEqual(AutoOffPreset.adjustedUntilMinutes(23 * 60, by: 60), 0)
        XCTAssertEqual(AutoOffPreset.adjustedUntilMinutes(0, by: -1), 24 * 60 - 1)
        XCTAssertEqual(AutoOffPreset.adjustedUntilMinutes(23 * 60 + 59, by: 1), 0)
    }
}
