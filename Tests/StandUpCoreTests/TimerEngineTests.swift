import Foundation
import XCTest
@testable import StandUpCore

final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

let testSchedule = SchedulePolicy(timeZone: { TimeZone(secondsFromGMT: 8 * 3600)! })

final class TimerEngineTests: XCTestCase {
    private var clock: TestClock!
    private var engine: TimerEngine!

    override func setUp() {
        clock = TestClock(instant("2026-11-02T09:00:00+08:00"))
        engine = TimerEngine(schedule: testSchedule, now: { [clock] in clock!.now })
    }

    @discardableResult
    private func reachDue() -> UUID {
        engine.handle(.startWork)
        clock.advance(1800)
        engine.handle(.refresh)
        return engine.snapshot.stage!.id
    }

    func testStartsOnce() {
        XCTAssertEqual(engine.state, .idle)
        engine.handle(.startWork)
        let stage = engine.snapshot.stage
        clock.advance(3)
        XCTAssertEqual(engine.handle(.startWork), [])
        XCTAssertEqual(engine.state, .working)
        XCTAssertEqual(engine.snapshot.stage, stage)
        XCTAssertEqual(engine.remaining(at: clock.now), 1797)
    }

    func testWorkDeadlineCreatesOnlyOneReminderAndWorkCompletion() {
        engine.handle(.startWork)
        let work = engine.snapshot.stage!.id
        clock.advance(1799)
        XCTAssertEqual(engine.handle(.refresh), [])
        clock.advance(1)
        let effects = engine.handle(.refresh)
        XCTAssertEqual(engine.state, .breakDue)
        XCTAssertEqual(effects, [.record(.work, work, clock.now), .remind(engine.snapshot.stage!.id)])
        clock.advance(600)
        XCTAssertEqual(engine.handle(.refresh), [])
        XCTAssertEqual(engine.state, .breakDue)
    }

    func testBreakCompletesOnceAndStartsNextWork() {
        let due = reachDue()
        engine.handle(.startBreak(due))
        XCTAssertEqual(engine.state, .onBreak)
        XCTAssertEqual(engine.remaining(at: clock.now), 180)
        XCTAssertEqual(engine.handle(.startBreak(due)), [])
        let activity = engine.snapshot.stage!.id
        clock.advance(180)
        XCTAssertEqual(engine.handle(.refresh), [
            .record(.activity(seconds: 180), activity, clock.now), .activityFinished(startedNextWork: true)
        ])
        XCTAssertEqual(engine.state, .working)
        XCTAssertEqual(engine.remaining(at: clock.now), 1800)
        XCTAssertEqual(engine.handle(.refresh), [])
    }

    func testActivityCompletionWithoutAutoStartReturnsToIdleAndAnnouncesOnce() {
        var configuration = TimerConfiguration.defaults
        configuration.autoStartNextWork = false
        engine.updateConfiguration(configuration)
        engine.handle(.startBreak(reachDue()))
        let activity = engine.snapshot.stage!.id
        clock.advance(180)

        XCTAssertEqual(engine.handle(.refresh), [
            .record(.activity(seconds: 180), activity, clock.now), .activityFinished(startedNextWork: false)
        ])
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.handle(.refresh), [])
    }

    func testManualSessionEndAndLaunchCatchUpDoNotAnnounceElapsedActivity() {
        for event in [TimerEvent.stop, .restart, .applicationLaunched, .systemWillSleep] {
            engine.handle(.restart)
            clock.advance(1800)
            engine.handle(.refresh)
            engine.handle(.startBreak(engine.snapshot.stage!.id))
            let activity = engine.snapshot.stage!.id
            clock.advance(180)

            let effects = engine.handle(event)
            XCTAssertTrue(effects.contains(.record(.activity(seconds: 180), activity, clock.now)))
            XCTAssertFalse(effects.contains(.activityFinished(startedNextWork: true)))
        }
    }

    func testSnoozeCanRepeatAndOldActionsAreIgnored() {
        let first = reachDue()
        XCTAssertEqual(engine.handle(.snooze(first)), [.clearReminder, .record(.snooze, first, clock.now)])
        XCTAssertEqual(engine.state, .snoozed)
        XCTAssertEqual(engine.remaining(at: clock.now), 300)
        XCTAssertEqual(engine.handle(.snooze(first)), [])
        clock.advance(300)
        let effects = engine.handle(.refresh)
        let second = engine.snapshot.stage!.id
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(effects, [.remind(second)])
        XCTAssertEqual(engine.handle(.skip(first)), [])
        engine.handle(.snooze(second))
        XCTAssertEqual(engine.state, .snoozed)
    }

    func testSkipStartsFreshWorkWithoutActivityCredit() {
        let due = reachDue()
        XCTAssertEqual(engine.handle(.skip(due)), [.clearReminder, .record(.skip, due, clock.now)])
        XCTAssertEqual(engine.state, .working)
        XCTAssertEqual(engine.remaining(at: clock.now), 1800)
    }

    func testPauseAndResumeTimedStages() {
        for phase in [TimerState.working, .onBreak, .snoozed] {
            engine.handle(.stop)
            engine.handle(.startWork)
            if phase != .working {
                let due = reachDue()
                engine.handle(phase == .onBreak ? .startBreak(due) : .snooze(due))
            }
            clock.advance(20)
            let remaining = engine.remaining(at: clock.now)
            engine.handle(.pause)
            clock.advance(300)
            XCTAssertEqual(engine.state, .paused)
            XCTAssertEqual(engine.remaining(at: clock.now), remaining)
            engine.handle(.resume)
            XCTAssertEqual(engine.state, phase)
            XCTAssertEqual(engine.remaining(at: clock.now), remaining)
        }
    }

    func testPauseAndResumeDue() {
        let due = reachDue()
        XCTAssertEqual(engine.handle(.pause), [.clearReminder])
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.handle(.resume), [.remind(engine.snapshot.stage!.id)])
        XCTAssertEqual(engine.state, .breakDue)
        XCTAssertEqual(engine.handle(.startBreak(due)), [])
    }

    func testCutoffWinsOverWorkDeadlineAndClearsReminder() {
        clock.now = instant("2026-11-06T21:30:00+08:00")
        engine.handle(.startWork)
        clock.advance(1800)
        XCTAssertEqual(engine.handle(.refresh), [.clearReminder])
        XCTAssertEqual(engine.state, .outsideSchedule)
        clock.now = instant("2026-11-09T09:00:00+08:00")
        XCTAssertEqual(engine.handle(.refresh), [])
        XCTAssertEqual(engine.state, .idle)
    }

    func testPreviousDayCannotResumeDuringNextWindow() {
        engine.handle(.startWork)
        let work = engine.snapshot.stage!
        clock.advance(86400)
        XCTAssertEqual(engine.handle(.refresh), [.clearReminder, .record(.work, work.id, work.deadline!)])
        XCTAssertEqual(engine.state, .idle)
    }

    func testSleepFreezesTwentyMinutesOfWork() {
        engine.handle(.startWork)
        clock.advance(600)
        engine.handle(.systemWillSleep)
        clock.advance(3600)
        engine.handle(.refresh)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.remaining(at: clock.now), 1200)
        XCTAssertEqual(engine.handle(.systemDidWake), [])
        XCTAssertEqual(engine.state, .working)
        XCTAssertEqual(engine.remaining(at: clock.now), 1200)
    }

    func testSleepFreezesActivity() {
        engine.handle(.startBreak(reachDue()))
        clock.advance(60)
        engine.handle(.systemWillSleep)
        clock.advance(3600)
        XCTAssertEqual(engine.handle(.systemDidWake), [])
        XCTAssertEqual(engine.state, .onBreak)
        XCTAssertEqual(engine.remaining(at: clock.now), 120)
    }

    func testSleepWhileDueReissuesOnlyOnce() {
        let previous = reachDue()
        XCTAssertEqual(engine.handle(.systemWillSleep), [.clearReminder])
        clock.advance(3600)
        XCTAssertEqual(engine.handle(.systemDidWake), [.remind(engine.snapshot.stage!.id)])
        XCTAssertNotEqual(previous, engine.snapshot.stage!.id)
        XCTAssertEqual(engine.handle(.systemDidWake), [])
        XCTAssertEqual(engine.handle(.refresh), [])
    }

    func testWakeAfterCutoffEndsSessionAndWakeDoesNotResumeManualPause() {
        clock.now = instant("2026-11-02T21:50:00+08:00")
        engine.handle(.startWork)
        engine.handle(.pause)
        engine.handle(.systemWillSleep)
        engine.handle(.systemDidWake)
        XCTAssertEqual(engine.state, .paused)
        engine.handle(.resume)
        engine.handle(.systemWillSleep)
        clock.advance(600)
        XCTAssertEqual(engine.handle(.systemDidWake), [.clearReminder])
        XCTAssertEqual(engine.state, .outsideSchedule)
    }
}

extension TimerEngineTests {
    func testStartAt2150EndsAt2200WithoutAnIncompleteWorkCredit() {
        clock.now = instant("2026-11-06T21:50:00+08:00")
        engine.handle(.startWork)
        XCTAssertEqual(engine.nextCheck(after: clock.now), instant("2026-11-06T22:00:00+08:00"))
        clock.advance(600)
        XCTAssertEqual(engine.handle(.refresh), [.clearReminder])
        clock.advance(1800)
        XCTAssertEqual(engine.handle(.refresh), [])
        XCTAssertEqual(engine.state, .outsideSchedule)
    }

    func testSnoozeIsDiscardedAtCutoffAndOldActionsCannotRestartSession() {
        clock.now = instant("2026-11-06T21:29:00+08:00")
        let due = reachDue()
        engine.handle(.snooze(due))
        clock.advance(60)
        XCTAssertEqual(engine.handle(.refresh), [.clearReminder])
        XCTAssertEqual(engine.handle(.startBreak(due)), [])
        XCTAssertEqual(engine.state, .outsideSchedule)
    }

    func testLateCheckCreditsAnActivityCompletedBeforeCutoffWithoutStartingWork() {
        clock.now = instant("2026-11-06T21:26:00+08:00")
        engine.handle(.startBreak(reachDue()))
        let activity = engine.snapshot.stage!
        clock.advance(240)
        XCTAssertEqual(engine.handle(.refresh), [
            .clearReminder, .record(.activity(seconds: 180), activity.id, activity.deadline!)
        ])
        XCTAssertEqual(engine.state, .outsideSchedule)
        XCTAssertEqual(engine.handle(.refresh), [])
    }

    func testWeekendCannotStartOrRestart() {
        clock.now = instant("2026-11-07T12:00:00+08:00")
        XCTAssertEqual(engine.handle(.startWork), [])
        XCTAssertEqual(engine.handle(.restart), [])
        XCTAssertEqual(engine.state, .outsideSchedule)
        XCTAssertNil(engine.snapshot.stage)
    }
}
