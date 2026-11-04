import Foundation
import XCTest
@testable import StandUpCore

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: PersistenceService!
    private var clock: TestClock!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PersistenceService(url: directory.appendingPathComponent("state.json"))
        clock = TestClock(instant("2026-11-02T09:00:00+08:00"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(_ data: LocalData = LocalData()) -> TimerSession {
        TimerSession(data: data, schedule: testSchedule, now: { [clock] in clock!.now })
    }

    func testRoundTripPreservesDeadlineAndSettings() throws {
        let first = session()
        first.handle(.startWork)
        first.setStatisticsEnabled(false)
        let original = first.engine.snapshot
        try store.save(first.data)
        clock.advance(600)
        let restored = session(try store.load())
        XCTAssertEqual(restored.handle(.applicationLaunched), [])
        XCTAssertEqual(restored.engine.snapshot, original)
        XCTAssertEqual(restored.engine.remaining(at: clock.now), 1200)
        XCTAssertFalse(restored.data.settings.statisticsEnabled)
    }

    func testExpiredWorkReminderOnlyOnceAcrossRelaunches() throws {
        let first = session()
        first.handle(.startWork)
        try store.save(first.data)
        clock.advance(1815)
        let second = session(try store.load())
        let effects = second.handle(.applicationLaunched)
        XCTAssertTrue(effects.contains(.remind(second.engine.snapshot.stage!.id)))
        XCTAssertEqual(second.data.statistics.totals(at: clock.now, schedule: testSchedule).completedWork, 1)
        try store.save(second.data)
        let third = session(try store.load())
        XCTAssertEqual(third.handle(.applicationLaunched), [])
        XCTAssertEqual(third.engine.state, .breakDue)
        XCTAssertEqual(third.data.statistics.totals(at: clock.now, schedule: testSchedule).completedWork, 1)
    }

    func testExpiredActivityIsRecordedOnceAndNoCatchupCyclesAreCreated() throws {
        let first = session()
        first.handle(.startWork)
        clock.advance(1800)
        first.handle(.refresh)
        first.handle(.startBreak(first.engine.snapshot.stage!.id))
        try store.save(first.data)
        clock.advance(7200)
        let second = session(try store.load())
        second.handle(.applicationLaunched)
        XCTAssertEqual(second.engine.state, .working)
        XCTAssertEqual(second.engine.remaining(at: clock.now), 1800)
        try store.save(second.data)
        let third = session(try store.load())
        XCTAssertEqual(third.handle(.applicationLaunched), [])
        let totals = third.data.statistics.totals(at: clock.now, schedule: testSchedule)
        XCTAssertEqual(totals.completedActivities, 1)
        XCTAssertEqual(totals.activitySeconds, 180)
    }

    func testSleepSnapshotRecoversRemainingTimeOnLaunch() throws {
        let first = session()
        first.handle(.startWork)
        clock.advance(600)
        first.handle(.systemWillSleep)
        try store.save(first.data)
        clock.advance(3600)
        let restored = session(try store.load())
        XCTAssertEqual(restored.handle(.applicationLaunched), [])
        XCTAssertEqual(restored.engine.state, .working)
        XCTAssertEqual(restored.engine.remaining(at: clock.now), 1200)
    }

    func testMissingOrDamagedDataUsesDefaults() throws {
        XCTAssertEqual(try store.load(), LocalData())
        try store.save(LocalData())
        try Data("{truncated".utf8).write(to: store.url)
        XCTAssertEqual(try store.load(), LocalData())
    }

    func testSemanticallyInvalidSnapshotUsesDefaults() throws {
        var data = LocalData()
        data.timer.sessionStartedAt = clock.now
        try store.save(data)
        XCTAssertEqual(try store.load(), LocalData())
    }
}
