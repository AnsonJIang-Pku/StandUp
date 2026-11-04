import XCTest
@testable import StandUpCore

final class SchedulePolicyTests: XCTestCase {
    func testOpeningAndClosingBoundaries() {
        XCTAssertNil(testSchedule.window(at: instant("2026-11-02T08:59:00+08:00")))
        XCTAssertNotNil(testSchedule.window(at: instant("2026-11-02T09:00:00+08:00")))
        XCTAssertNotNil(testSchedule.window(at: instant("2026-11-06T21:59:00+08:00")))
        XCTAssertNil(testSchedule.window(at: instant("2026-11-06T22:00:00+08:00")))
    }

    func testWeekendAndMidnight() {
        XCTAssertNil(testSchedule.window(at: instant("2026-11-07T12:00:00+08:00")))
        XCTAssertNil(testSchedule.window(at: instant("2026-11-08T12:00:00+08:00")))
        let before = instant("2026-11-01T23:59:59+08:00")
        let after = instant("2026-11-02T00:00:00+08:00")
        XCTAssertNotEqual(testSchedule.dayKey(at: before), testSchedule.dayKey(at: after))
        XCTAssertNil(testSchedule.window(at: after))
        XCTAssertEqual(testSchedule.nextOpening(after: before), instant("2026-11-02T09:00:00+08:00"))
    }
}

extension SchedulePolicyTests {
    private func emptyWeek() -> ScheduleConfiguration {
        var configuration = ScheduleConfiguration()
        for day in Weekday.allCases { configuration[day].enabled = false }
        return configuration
    }

    func testIndependentDaysAndWeekendAllDay() {
        var configuration = emptyWeek()
        configuration[.monday] = DaySchedule(startMinute: 9 * 60 + 30, endMinute: 11 * 60)
        configuration[.wednesday] = DaySchedule(startMinute: 14 * 60, endMinute: 18 * 60)
        configuration[.saturday] = DaySchedule(allDay: true)
        let policy = testSchedule.withConfiguration(configuration)
        XCTAssertNil(policy.window(at: instant("2026-11-02T09:29:59+08:00")))
        XCTAssertNotNil(policy.window(at: instant("2026-11-02T09:30:00+08:00")))
        XCTAssertNil(policy.window(at: instant("2026-11-03T10:00:00+08:00")))
        XCTAssertNil(policy.window(at: instant("2026-11-04T10:00:00+08:00")))
        XCTAssertNotNil(policy.window(at: instant("2026-11-04T14:00:00+08:00")))
        XCTAssertNotNil(policy.window(at: instant("2026-11-07T00:00:00+08:00")))
        XCTAssertNotNil(policy.window(at: instant("2026-11-07T23:59:59+08:00")))
        XCTAssertNil(policy.window(at: instant("2026-11-08T00:00:00+08:00")))
    }

    func testFridayAndSundayOvernightBelongToStartingDay() {
        var configuration = emptyWeek()
        for day in [Weekday.friday, .sunday] {
            configuration[day] = DaySchedule(startMinute: 22 * 60, endMinute: 2 * 60, allowsOvernight: true)
        }
        let policy = testSchedule.withConfiguration(configuration)
        for (day, next) in [("06", "07"), ("08", "09")] {
            let open = instant("2026-11-\(day)T22:00:00+08:00")
            let close = instant("2026-11-\(next)T02:00:00+08:00")
            XCTAssertNil(policy.window(at: open.addingTimeInterval(-1)))
            XCTAssertEqual(policy.window(at: close.addingTimeInterval(-1))?.start, open)
            XCTAssertEqual(policy.window(at: open)?.end, close)
            XCTAssertNil(policy.window(at: close))
        }
    }

    func testAmbiguousAndReversedRangesRequireExplicitSelection() {
        XCTAssertFalse(DaySchedule(startMinute: 540, endMinute: 540).isValid)
        XCTAssertFalse(DaySchedule(startMinute: 540, endMinute: 540, allowsOvernight: true).isValid)
        XCTAssertTrue(DaySchedule(startMinute: 540, endMinute: 540, allDay: true).isValid)
        XCTAssertFalse(DaySchedule(startMinute: 1320, endMinute: 120).isValid)
        XCTAssertTrue(DaySchedule(startMinute: 1320, endMinute: 120, allowsOvernight: true).isValid)
        var settings = AppSettings()
        var invalid = ScheduleConfiguration()
        invalid[.monday].endMinute = invalid[.monday].startMinute
        XCTAssertFalse(settings.applySchedule(invalid))
        XCTAssertEqual(settings.schedule, .defaults)
    }

    func testUnrestrictedAndContiguousAllDayHaveNoClosingTime() {
        let date = instant("2026-11-08T04:00:00+08:00")
        var configuration = emptyWeek()
        configuration.enabled = false
        var policy = testSchedule.withConfiguration(configuration)
        XCTAssertEqual(policy.window(at: date)?.end, .distantFuture)
        XCTAssertNil(policy.nextOpening(after: date))

        configuration.enabled = true
        for day in Weekday.allCases { configuration[day] = DaySchedule(allDay: true) }
        policy = testSchedule.withConfiguration(configuration)
        XCTAssertEqual(policy.window(at: date)?.end, .distantFuture)

        configuration[.sunday].enabled = false
        policy = testSchedule.withConfiguration(configuration)
        XCTAssertNil(policy.window(at: date))
        XCTAssertEqual(policy.window(at: instant("2026-11-02T12:00:00+08:00"))?.end,
                       instant("2026-11-08T00:00:00+08:00"))
    }

    func testOverlapAndAdjacentWindowsDoNotInterruptSession() {
        var configuration = emptyWeek()
        configuration[.friday] = DaySchedule(startMinute: 1320, endMinute: 120, allowsOvernight: true)
        configuration[.saturday] = DaySchedule(startMinute: 120, endMinute: 240)
        let policy = testSchedule.withConfiguration(configuration)
        let close = instant("2026-11-07T04:00:00+08:00")
        XCTAssertEqual(policy.window(at: instant("2026-11-06T23:30:00+08:00"))?.end, close)
        XCTAssertEqual(policy.window(at: instant("2026-11-07T02:00:00+08:00"))?.end, close)
    }

    func testUsesUpdatedSystemTimeZone() {
        var zone = TimeZone(secondsFromGMT: 8 * 3600)!
        let policy = SchedulePolicy(timeZone: { zone })
        let date = instant("2026-11-02T09:30:00+08:00")
        XCTAssertNotNil(policy.window(at: date))
        zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNil(policy.window(at: date))
        XCTAssertEqual(policy.nextOpening(after: date), instant("2026-11-02T09:00:00Z"))
    }

    func testDaylightSavingGapFoldAndAllDay() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        var configuration = emptyWeek()
        configuration[.sunday] = DaySchedule(startMinute: 150, endMinute: 240)
        var policy = SchedulePolicy(configuration: configuration, timeZone: { zone })
        let spring = instant("2026-03-08T03:00:00-07:00")
        XCTAssertNil(policy.window(at: spring.addingTimeInterval(-1)))
        XCTAssertEqual(policy.window(at: spring)?.start, spring)
        XCTAssertEqual(policy.window(at: spring)?.duration, 3600)

        configuration[.sunday] = DaySchedule(startMinute: 60, endMinute: 90)
        policy = SchedulePolicy(configuration: configuration, timeZone: { zone })
        let first = instant("2026-11-01T01:00:00-07:00")
        let last = instant("2026-11-01T01:30:00-08:00")
        XCTAssertEqual(policy.window(at: first)?.end, last)
        XCTAssertNotNil(policy.window(at: last.addingTimeInterval(-1)))
        XCTAssertNil(policy.window(at: last))

        configuration[.sunday] = DaySchedule(allDay: true)
        policy = SchedulePolicy(configuration: configuration, timeZone: { zone })
        XCTAssertEqual(policy.window(at: spring)?.duration, 23 * 3600)
        XCTAssertEqual(policy.window(at: first)?.duration, 25 * 3600)
    }
}
