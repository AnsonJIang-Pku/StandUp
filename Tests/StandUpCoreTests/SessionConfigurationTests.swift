import Foundation
import XCTest
@testable import StandUpCore

final class SessionConfigurationTests: XCTestCase {
    private let monday = instant("2026-11-02T10:00:00+08:00")
    private let original = TimerConfiguration(workMinutes: 17, activityMinutes: 7, snoozeMinutes: 11,
                                              maxSnoozeCount: 1)
    private let replacement = TimerConfiguration(workMinutes: 43, activityMinutes: 13, snoozeMinutes: 19,
                                                 maxSnoozeCount: 3, autoStartNextWork: false)

    private func session(_ clock: TestClock, data: LocalData = LocalData()) -> TimerSession {
        TimerSession(data: data, schedule: testSchedule, now: { clock.now })
    }

    private func configure(_ configuration: TimerConfiguration, in session: TimerSession) {
        var settings = session.data.settings
        XCTAssertTrue(settings.applyTimer(configuration))
        XCTAssertTrue(session.applySettings(settings).isEmpty)
    }

    private func advance(_ minutes: Int, clock: TestClock, session: TimerSession) {
        clock.advance(TimeInterval(minutes * 60))
        session.handle(.refresh)
    }

    private func stageID(_ session: TimerSession) throws -> UUID {
        try XCTUnwrap(session.engine.snapshot.stage?.id)
    }

    func testWorkSnoozeAndActivityUseCycleSnapshotAndNextWorkUsesLatest() throws {
        let clock = TestClock(monday)
        let session = session(clock)
        configure(original, in: session)
        session.handle(.startWork)
        let work = session.engine.snapshot.stage
        clock.advance(60)

        configure(replacement, in: session)
        XCTAssertEqual(session.engine.snapshot.stage, work)
        XCTAssertEqual(session.engine.activeConfiguration, original)
        XCTAssertEqual(session.engine.remaining(at: clock.now), 16 * 60)
        advance(16, clock: clock, session: session)
        session.handle(.snooze(try stageID(session)))
        XCTAssertEqual(session.engine.remaining(at: clock.now), 11 * 60)
        advance(11, clock: clock, session: session)
        session.handle(.startBreak(try stageID(session)))
        XCTAssertEqual(session.engine.remaining(at: clock.now), 7 * 60)
        var final = replacement
        final.workMinutes = 51
        configure(final, in: session)
        XCTAssertEqual(session.engine.remaining(at: clock.now), 7 * 60)
        advance(7, clock: clock, session: session)
        XCTAssertEqual(session.engine.state, .working)
        XCTAssertEqual(session.engine.activeConfiguration, final)
        XCTAssertEqual(session.engine.remaining(at: clock.now), 51 * 60)
        XCTAssertEqual(session.data.statistics.totals(at: clock.now, schedule: testSchedule).activitySeconds, 7 * 60)
    }

    func testSnoozeLimitPersistsAcrossSleepAndResetsOnNextWork() throws {
        let clock = TestClock(monday)
        let session = session(clock)
        configure(original, in: session)
        session.handle(.startWork)
        advance(17, clock: clock, session: session)
        XCTAssertTrue(session.engine.canSnooze)
        session.handle(.snooze(try stageID(session)))
        session.handle(.systemWillSleep)
        clock.advance(3600)
        session.handle(.systemDidWake)
        XCTAssertEqual(session.engine.remaining(at: clock.now), 11 * 60)
        XCTAssertEqual(session.engine.snapshot.snoozeCount, 1)
        advance(11, clock: clock, session: session)
        XCTAssertFalse(session.engine.canSnooze)
        let due = try stageID(session)
        XCTAssertTrue(session.handle(.snooze(due)).isEmpty)
        XCTAssertEqual(session.engine.state, .breakDue)
        XCTAssertTrue(session.engine.isCurrentReminder(due, at: clock.now))
        session.handle(.skip(due))
        XCTAssertEqual(session.engine.snapshot.snoozeCount, 0)
        advance(17, clock: clock, session: session)
        XCTAssertTrue(session.engine.canSnooze)
        XCTAssertEqual(session.data.statistics.totals(at: clock.now, schedule: testSchedule).snoozes, 1)
    }

    func testRestartCapturesLatestAndDisabledAutoStartReturnsToIdle() throws {
        let clock = TestClock(monday)
        let session = session(clock)
        configure(original, in: session)
        session.handle(.startWork)
        configure(replacement, in: session)
        session.handle(.restart)
        XCTAssertEqual(session.engine.activeConfiguration, replacement)
        XCTAssertEqual(session.engine.remaining(at: clock.now), 43 * 60)
        advance(43, clock: clock, session: session)
        session.handle(.startBreak(try stageID(session)))
        advance(13, clock: clock, session: session)
        XCTAssertEqual(session.engine.state, .idle)
        XCTAssertNil(session.engine.snapshot.stage)
        XCTAssertEqual(session.data.statistics.totals(at: clock.now, schedule: testSchedule).activitySeconds, 13 * 60)
    }

    func testSavedSnapshotRestoresWorkAfterSleepAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceService(url: directory.appendingPathComponent("state.json"))
        let clock = TestClock(monday)
        let first = session(clock)
        configure(original, in: first)
        first.handle(.startWork)
        clock.advance(120)
        configure(replacement, in: first)
        first.handle(.systemWillSleep)
        try store.save(first.data)
        clock.advance(600)
        let restored = session(clock, data: try store.load())
        restored.handle(.applicationLaunched)
        XCTAssertEqual(restored.data.settings.timer, replacement)
        XCTAssertEqual(restored.engine.activeConfiguration, original)
        XCTAssertEqual(restored.engine.remaining(at: clock.now), 15 * 60)
        XCTAssertEqual(restored.engine.snapshot.stage?.id, first.engine.snapshot.stage?.id)
    }

    func testOvernightSessionAndItsReminderSurviveMidnight() throws {
        let clock = TestClock(instant("2026-11-06T23:40:00+08:00"))
        let session = session(clock)
        var settings = session.data.settings
        var schedule = settings.schedule
        schedule[.friday] = DaySchedule(startMinute: 1320, endMinute: 120, allowsOvernight: true)
        settings.applySchedule(schedule)
        XCTAssertTrue(session.applySettings(settings).isEmpty)
        session.handle(.startWork)
        advance(30, clock: clock, session: session)
        XCTAssertEqual(session.engine.state, .breakDue)
        let due = try stageID(session)
        XCTAssertTrue(session.engine.isCurrentReminder(due, at: clock.now))
        XCTAssertEqual(session.engine.snapshot.sessionEndsAt, instant("2026-11-07T02:00:00+08:00"))
        clock.now = instant("2026-11-07T02:00:00+08:00")
        XCTAssertEqual(session.handle(.refresh), [.clearReminder])
        XCTAssertEqual(session.engine.state, .outsideSchedule)
    }

    func testScheduleSaveRecomputesCutoffAndImmediatelyClearsIfOutside() throws {
        let clock = TestClock(monday)
        let session = session(clock)
        session.handle(.startWork)
        let stage = session.engine.snapshot.stage
        var settings = session.data.settings
        var schedule = settings.schedule
        schedule[.monday].endMinute = 23 * 60
        settings.applySchedule(schedule)
        XCTAssertTrue(session.applySettings(settings).isEmpty)
        XCTAssertEqual(session.engine.snapshot.stage, stage)
        XCTAssertEqual(session.engine.snapshot.sessionEndsAt, instant("2026-11-02T23:00:00+08:00"))
        advance(30, clock: clock, session: session)
        XCTAssertEqual(session.engine.state, .breakDue)
        schedule[.monday].startMinute = 11 * 60
        settings.applySchedule(schedule)
        XCTAssertEqual(session.applySettings(settings), [.clearReminder])
        XCTAssertEqual(session.engine.state, .outsideSchedule)
        XCTAssertNil(session.engine.snapshot.stage)
    }

    func testTimeZoneChangeKeepsDeadlineWhenAllowedAndEndsWhenOutside() {
        let clock = TestClock(monday)
        var zone = TimeZone(secondsFromGMT: 8 * 3600)!
        let session = TimerSession(schedule: SchedulePolicy(timeZone: { zone }), now: { clock.now })
        session.handle(.startWork)
        let stage = session.engine.snapshot.stage
        zone = TimeZone(secondsFromGMT: 7 * 3600)!
        XCTAssertTrue(session.handle(.refresh).isEmpty)
        XCTAssertEqual(session.engine.snapshot.stage, stage)
        XCTAssertEqual(session.engine.snapshot.sessionEndsAt, instant("2026-11-02T22:00:00+07:00"))
        zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(session.handle(.refresh), [.clearReminder])
        XCTAssertEqual(session.engine.state, .outsideSchedule)
    }

    func testZeroSnoozesStillAllowsManualHandlingAndUnrestrictedSessionSurvivesDays() throws {
        let clock = TestClock(instant("2026-11-07T23:55:00+08:00"))
        let session = session(clock)
        var settings = session.data.settings
        var schedule = settings.schedule
        schedule.enabled = false
        settings.applySchedule(schedule)
        var timer = original
        timer.maxSnoozeCount = 0
        settings.applyTimer(timer)
        XCTAssertTrue(session.applySettings(settings).isEmpty)
        session.handle(.startWork)
        clock.advance(2 * 86400)
        session.handle(.refresh)
        XCTAssertEqual(session.engine.state, .breakDue)
        XCTAssertFalse(session.engine.canSnooze)
        session.handle(.startBreak(try stageID(session)))
        XCTAssertEqual(session.engine.state, .onBreak)
    }
}

extension SessionConfigurationTests {
    func testApplyingPresetPreservesCycleAndSkipStartsWithPreset() throws {
        let clock = TestClock(monday)
        let session = session(clock)
        configure(original, in: session)
        session.handle(.startWork)
        let stage = session.engine.snapshot.stage
        var settings = session.data.settings
        let preset = try XCTUnwrap(settings.presets.first { $0.id == "relaxed" })
        settings.applyTimer(preset.configuration, presetID: preset.id)
        XCTAssertTrue(session.applySettings(settings).isEmpty)
        XCTAssertEqual(session.engine.snapshot.stage, stage)
        XCTAssertEqual(session.engine.activeConfiguration, original)
        advance(17, clock: clock, session: session)
        session.handle(.skip(try stageID(session)))
        XCTAssertEqual(session.engine.activeConfiguration, preset.configuration)
        XCTAssertEqual(session.engine.remaining(at: clock.now), 45 * 60)
    }
}
