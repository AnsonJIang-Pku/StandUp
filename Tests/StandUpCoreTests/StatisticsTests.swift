import Foundation
import XCTest
@testable import StandUpCore

final class StatisticsTests: XCTestCase {
    func testCountsAllMetricsAndDeduplicatesAcrossLocalDays() {
        var stats = StatisticsService()
        let date = instant("2026-11-02T23:59:59+08:00")
        let tomorrow = date.addingTimeInterval(1)
        let activity = UUID()
        stats.record(.activity(seconds: 180), id: activity, at: date, schedule: testSchedule)
        stats.record(.activity(seconds: 180), id: activity, at: tomorrow, schedule: testSchedule)
        stats.record(.skip, id: UUID(), at: date, schedule: testSchedule)
        stats.record(.snooze, id: UUID(), at: date, schedule: testSchedule)
        stats.record(.work, id: UUID(), at: date, schedule: testSchedule)
        let total = stats.totals(at: date, schedule: testSchedule)
        XCTAssertEqual(total.completedActivities, 1)
        XCTAssertEqual(total.activitySeconds, 180)
        XCTAssertEqual(total.skips, 1)
        XCTAssertEqual(total.snoozes, 1)
        XCTAssertEqual(total.completedWork, 1)
        XCTAssertEqual(stats.totals(at: tomorrow, schedule: testSchedule), DailyStatistics())
    }

    func testPruningKeepsTodayAndPrevious29LocalDates() {
        let now = instant("2026-11-02T09:00:00+08:00")
        let lastKept = instant("2026-10-04T09:00:00+08:00")
        let expired = instant("2026-10-03T09:00:00+08:00")
        var stats = StatisticsService()
        for date in [now, lastKept, expired] {
            stats.record(.work, id: UUID(), at: date, schedule: testSchedule)
        }
        stats.prune(at: now, schedule: testSchedule)
        XCTAssertEqual(stats.totals(at: now, schedule: testSchedule).completedWork, 1)
        XCTAssertEqual(stats.totals(at: lastKept, schedule: testSchedule).completedWork, 1)
        XCTAssertEqual(stats.totals(at: expired, schedule: testSchedule).completedWork, 0)
    }

    func testDisablingStatisticsDoesNotStopTimerOrCountEvents() {
        let clock = TestClock(instant("2026-11-02T09:00:00+08:00"))
        let session = TimerSession(schedule: testSchedule, now: { clock.now })
        session.setStatisticsEnabled(false)
        session.handle(.startWork)
        clock.advance(1800)
        session.handle(.refresh)
        session.handle(.skip(session.engine.snapshot.stage!.id))
        XCTAssertEqual(session.engine.state, .working)
        XCTAssertEqual(session.data.statistics.totals(at: clock.now, schedule: testSchedule), DailyStatistics())
        session.setStatisticsEnabled(true)
        clock.advance(1800)
        session.handle(.refresh)
        XCTAssertEqual(session.data.statistics.totals(at: clock.now, schedule: testSchedule).completedWork, 1)
    }
}
