import Combine
import Foundation
import UserNotifications
import XCTest
import StandUpCore
@testable import StandUpAppTestSupport

final class AppModelNotificationTests: XCTestCase {
    @MainActor
    func testEnabledActivityCompletionSubmitsOnceAndCanPresentInForeground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PersistenceService(url: directory.appendingPathComponent("state.json"))
        let center = MockNotificationCenter()
        let clock = makeClock()
        let model = AppModel(persistence: store, center: center, now: { clock.now })
        let defaults = UserDefaults.standard
        let key = ReminderSounds.activityEndSoundKey
        let previous = defaults.object(forKey: key)
        defer {
            defaults.set(previous, forKey: key)
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: key)
        model.start()
        model.send(.startWork)
        clock.advance(1800)
        model.send(.refresh)
        let workReminder = try XCTUnwrap(model.notificationTask)
        await workReminder.value
        model.send(.startBreak(try XCTUnwrap(model.stageID)))
        XCTAssertEqual(model.state, .onBreak)

        let submitted = expectation(description: "Activity completion submitted")
        submitted.assertForOverFulfill = true
        center.onAdd = { submitted.fulfill() }
        clock.advance(180)
        model.send(.refresh)
        model.send(.refresh)
        XCTAssertEqual(model.state, .working)
        await fulfillment(of: [submitted], timeout: 3)

        let request = try XCTUnwrap(center.pending[NotificationService.activityFinishedIdentifier])
        XCTAssertEqual(center.additions, 2)
        XCTAssertTrue(model.canPresentNotification(request))
        defaults.removeObject(forKey: key)
        XCTAssertFalse(model.canPresentNotification(request))
    }

    @MainActor
    func testValidReminderSubmitsAfterSuccessfulPersistence() async throws {
        try await checkReminderSubmission(failStorage: false)
    }

    @MainActor
    func testValidReminderSubmitsEvenWhenPersistenceFails() async throws {
        try await checkReminderSubmission(failStorage: true)
    }

    @MainActor
    func testStateChangeWhileAuthorizationIsPendingPreventsStaleSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceService(url: directory.appendingPathComponent("state.json"))
        let center = MockNotificationCenter()
        let clock = makeClock()
        let model = AppModel(persistence: store, center: center, now: { clock.now })
        let initialStatus = expectation(description: "Initial authorization check completed")
        let initialObservation = model.$notificationStatus.dropFirst().prefix(1).sink { _ in
            initialStatus.fulfill()
        }
        model.start()
        defer { model.shutdown() }
        await fulfillment(of: [initialStatus], timeout: 3)
        initialObservation.cancel()

        let checking = expectation(description: "Reminder authorization is suspended")
        var authorization: CheckedContinuation<UNAuthorizationStatus, Never>?
        center.authorization = {
            await withCheckedContinuation { continuation in
                authorization = continuation
                checking.fulfill()
            }
        }
        model.send(.startWork)
        clock.advance(1800)
        model.send(.refresh)
        let token = try XCTUnwrap(model.stageID)
        let task = try XCTUnwrap(model.notificationTask)
        XCTAssertTrue(model.isCurrentReminder(token))
        await fulfillment(of: [checking], timeout: 3)
        model.send(.stop)
        XCTAssertFalse(model.isCurrentReminder(token))
        try XCTUnwrap(authorization).resume(returning: .authorized)

        await task.value
        XCTAssertEqual(center.additions, 0)
        XCTAssertEqual(center.pending.count, 0)
    }

    @MainActor
    func testFirstFailureRetriesOnceAndSubmits() async throws {
        let fixture = makeRetryFixture()
        defer { fixture.close() }
        let task = try fixture.makeReminder()
        await fulfillment(of: [try XCTUnwrap(fixture.waiting)], timeout: 3)
        XCTAssertEqual(fixture.center.additions, 1)
        XCTAssertTrue(fixture.center.pending.isEmpty)
        XCTAssertEqual(fixture.model.notificationSubmission, .submitting)

        fixture.center.addError = nil
        fixture.releaseDelay()
        await task.value

        XCTAssertEqual(fixture.center.additions, 2)
        XCTAssertEqual(fixture.center.pending.count, 1)
        XCTAssertEqual(fixture.model.notificationSubmission, .submitted)
        XCTAssertEqual(fixture.model.state, .breakDue)
    }

    @MainActor
    func testStoppingDuringSystemSubmissionRejectsLateDeliveryAndAction() async throws {
        let fixture = makeRetryFixture(expectDelay: false)
        defer { fixture.close() }
        fixture.center.deferCompletions = true
        let added = expectation(description: "System submission started")
        fixture.center.onAdd = { added.fulfill() }
        let task = try fixture.makeReminder()
        await fulfillment(of: [added], timeout: 3)

        fixture.model.send(.stop)
        fixture.center.completeSubmission(at: 0, deliveredImmediately: true)
        let lateRequest = try XCTUnwrap(fixture.center.delivered.values.first)
        XCTAssertFalse(fixture.model.canPresentReminder(lateRequest))
        fixture.model.handleReminderAction("STANDUP_START_BREAK", request: lateRequest)
        await task.value

        XCTAssertEqual(fixture.center.additions, 1)
        XCTAssertTrue(fixture.center.pending.isEmpty)
        XCTAssertTrue(fixture.center.delivered.isEmpty)
        XCTAssertEqual(fixture.model.state, .idle)
        XCTAssertEqual(fixture.model.notificationSubmission, .idle)
    }

    @MainActor
    func testTwoFailuresKeepBreakDueAndOfferManualResend() async throws {
        let fixture = makeRetryFixture()
        defer { fixture.close() }
        let task = try fixture.makeReminder()
        let token = fixture.model.stageID
        await fulfillment(of: [try XCTUnwrap(fixture.waiting)], timeout: 3)
        fixture.releaseDelay()
        await task.value

        XCTAssertEqual(fixture.center.additions, 2)
        XCTAssertTrue(fixture.center.pending.isEmpty)
        XCTAssertEqual(fixture.model.notificationStatus, .allowed)
        XCTAssertEqual(fixture.model.notificationSubmission, .failed)
        XCTAssertEqual(fixture.model.state, .breakDue)
        XCTAssertEqual(fixture.model.stageID, token)
        XCTAssertTrue(fixture.model.canResendReminder)

        fixture.center.addError = nil
        fixture.model.resendReminder()
        let resend = try XCTUnwrap(fixture.model.notificationTask)
        await resend.value
        XCTAssertEqual(fixture.center.additions, 3)
        XCTAssertEqual(fixture.center.pending.count, 1)
        XCTAssertEqual(fixture.center.pending.values.first.flatMap(NotificationService.token(for:)), token)
        XCTAssertEqual(fixture.model.notificationSubmission, .submitted)
        XCTAssertFalse(fixture.model.canResendReminder)
    }

    @MainActor
    func testStoppingDuringRetryDelayCancelsRetry() async throws {
        try await checkRetryInterrupted { fixture in
            fixture.model.send(.stop)
            XCTAssertEqual(fixture.model.state, .idle)
        }
    }

    @MainActor
    func testPausingDuringRetryDelayCancelsRetry() async throws {
        try await checkRetryInterrupted { fixture in
            fixture.model.send(.pause)
            XCTAssertEqual(fixture.model.state, .paused)
        }
    }

    @MainActor
    func testExpiringTokenDuringRetryDelaySkipsRetry() async throws {
        try await checkRetryInterrupted { fixture in
            fixture.clock.advance(12 * 3600)
            XCTAssertFalse(fixture.model.isCurrentReminder(fixture.model.stageID!))
        }
    }

    @MainActor
    func testShutdownDuringRetryDelayCancelsRetry() async throws {
        try await checkRetryInterrupted { fixture in
            fixture.model.shutdown()
        }
    }

    @MainActor
    func testDeniedPermissionDoesNotSubmitOrWaitForRetry() async throws {
        let fixture = makeRetryFixture(expectDelay: false)
        defer { fixture.close() }
        fixture.center.permission = .denied
        let task = try fixture.makeReminder()
        await task.value

        XCTAssertNil(fixture.delay)
        XCTAssertEqual(fixture.center.additions, 0)
        XCTAssertTrue(fixture.center.pending.isEmpty)
        XCTAssertEqual(fixture.model.notificationStatus, .denied)
        XCTAssertEqual(fixture.model.notificationSubmission, .idle)
        XCTAssertEqual(fixture.model.state, .breakDue)
    }

    @MainActor
    func testPermissionRevokedDuringSubmissionDoesNotRetry() async throws {
        let fixture = makeRetryFixture(expectDelay: false)
        defer { fixture.close() }
        fixture.center.addError = NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue)
        let task = try fixture.makeReminder()
        await task.value

        XCTAssertNil(fixture.delay)
        XCTAssertEqual(fixture.center.additions, 1)
        XCTAssertTrue(fixture.center.pending.isEmpty)
        XCTAssertEqual(fixture.model.notificationStatus, .denied)
        XCTAssertEqual(fixture.model.notificationSubmission, .idle)
    }

    @MainActor
    func testStartupResubmitsReminderWhenNoSystemRequestExists() async throws {
        let fixture = try StartupFixture(clock: makeClock())
        defer { fixture.close() }
        let added = expectation(description: "Missing reminder submitted")
        fixture.center.onAdd = { added.fulfill() }
        fixture.model.start()
        let cleanup = try XCTUnwrap(fixture.model.notificationCleanupTask)
        await cleanup.value
        await fulfillment(of: [added], timeout: 3)
        await fixture.model.notificationTask?.value

        XCTAssertEqual(fixture.center.additions, 1)
        XCTAssertEqual(fixture.center.pending.count, 1)
        XCTAssertEqual(fixture.center.pending.values.first.flatMap(NotificationService.token(for:)), fixture.token)
        XCTAssertEqual(fixture.model.state, .breakDue)
        XCTAssertEqual(fixture.model.stageID, fixture.token)
        fixture.model.send(.refresh)
        XCTAssertNil(fixture.model.notificationTask)
        XCTAssertEqual(fixture.center.additions, 1)
    }

    @MainActor
    func testStartupRestoresPendingReminderAndRoutesActions() async throws {
        for (action, expected) in [("STANDUP_START_BREAK", TimerState.onBreak),
                                   ("STANDUP_SNOOZE", .snoozed), ("STANDUP_SKIP", .working)] {
            let fixture = try StartupFixture(clock: makeClock())
            defer { fixture.close() }
            let request = NotificationTests.request(NotificationService.identifier + ".old.pending", token: fixture.token)
            fixture.center.pending[request.identifier] = request
            fixture.model.start()
            XCTAssertTrue(fixture.model.canPresentReminder(request))
            let cleanup = try XCTUnwrap(fixture.model.notificationCleanupTask)
            await cleanup.value

            XCTAssertEqual(Set(fixture.center.pending.keys), [request.identifier])
            XCTAssertEqual(fixture.center.additions, 0)
            XCTAssertTrue(fixture.model.canPresentReminder(request))
            fixture.model.handleReminderAction(action, request: request)
            XCTAssertEqual(fixture.model.state, expected)
            XCTAssertFalse(fixture.model.canPresentReminder(request))
            XCTAssertTrue(fixture.center.pending.isEmpty)
            fixture.model.handleReminderAction("STANDUP_START_BREAK", request: request)
            XCTAssertEqual(fixture.model.state, expected)
        }
    }

    @MainActor
    func testStartupKeepsDeliveredReminderWithoutResubmission() async throws {
        let fixture = try StartupFixture(clock: makeClock())
        defer { fixture.close() }
        let request = NotificationTests.request(NotificationService.identifier, token: fixture.token)
        fixture.center.delivered[request.identifier] = request
        fixture.model.start()
        let cleanup = try XCTUnwrap(fixture.model.notificationCleanupTask)
        await cleanup.value

        XCTAssertEqual(Set(fixture.center.delivered.keys), [request.identifier])
        XCTAssertEqual(fixture.center.additions, 0)
        XCTAssertNil(fixture.model.notificationTask)
        XCTAssertEqual(fixture.model.state, .breakDue)
    }

    @MainActor
    func testLaunchEffectWaitsForCleanupAndSubmitsOnlyOnce() async throws {
        let fixture = try StartupFixture(clock: makeClock(), savedBreakDue: false)
        defer { fixture.close() }
        let lookupStarted = expectation(description: "Startup lookup is suspended")
        var resumeLookup: CheckedContinuation<Void, Never>?
        fixture.center.beforeDeliveredLookup = {
            await withCheckedContinuation {
                resumeLookup = $0
                lookupStarted.fulfill()
            }
        }
        fixture.model.start()
        let cleanup = try XCTUnwrap(fixture.model.notificationCleanupTask)
        let submission = try XCTUnwrap(fixture.model.notificationTask)
        await fulfillment(of: [lookupStarted], timeout: 3)
        XCTAssertEqual(fixture.model.state, .breakDue)
        XCTAssertEqual(fixture.center.additions, 0)
        try XCTUnwrap(resumeLookup).resume()
        await cleanup.value
        await submission.value

        XCTAssertEqual(fixture.center.additions, 1)
        XCTAssertEqual(fixture.center.pending.count, 1)
        XCTAssertEqual(fixture.center.pending.values.first.flatMap(NotificationService.token(for:)), fixture.model.stageID)
    }

    @MainActor
    private final class StartupFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let center = MockNotificationCenter()
        let token: UUID
        let model: AppModel

        init(clock: TestClock, savedBreakDue: Bool = true) throws {
            let store = PersistenceService(url: directory.appendingPathComponent("state.json"))
            let session = TimerSession(now: { clock.now })
            session.handle(.startWork)
            clock.advance(1800)
            if savedBreakDue { session.handle(.refresh) }
            token = try XCTUnwrap(session.engine.snapshot.stage?.id)
            try store.save(session.data)
            model = AppModel(persistence: store, center: center, now: { clock.now })
        }

        func close() {
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private func checkRetryInterrupted(_ interrupt: (RetryFixture) -> Void) async throws {
        let fixture = makeRetryFixture()
        defer { fixture.close() }
        let task = try fixture.makeReminder()
        await fulfillment(of: [try XCTUnwrap(fixture.waiting)], timeout: 3)
        interrupt(fixture)
        fixture.releaseDelay()
        await task.value
        XCTAssertEqual(fixture.center.additions, 1)
        XCTAssertTrue(fixture.center.pending.isEmpty)
        XCTAssertFalse(fixture.model.canResendReminder)
        XCTAssertEqual(fixture.model.notificationSubmission, .idle)
    }

    @MainActor
    private func makeRetryFixture(expectDelay: Bool = true) -> RetryFixture {
        RetryFixture(clock: makeClock(), waiting: expectDelay ? expectation(description: "Retry delay reached") : nil)
    }

    @MainActor
    private final class RetryFixture {
        let clock: TestClock
        let waiting: XCTestExpectation?
        let center = MockNotificationCenter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var delay: CheckedContinuation<Void, Never>?
        lazy var model = AppModel(
            persistence: PersistenceService(url: directory.appendingPathComponent("state.json")),
            center: center,
            now: { [clock] in clock.now },
            notificationRetryDelay: { [weak self] in
                guard let self else { return }
                guard self.waiting != nil else {
                    XCTFail("Unexpected retry")
                    throw CancellationError()
                }
                await withCheckedContinuation { continuation in
                    self.delay = continuation
                    self.waiting?.fulfill()
                }
            }
        )

        init(clock: TestClock, waiting: XCTestExpectation?) {
            self.clock = clock
            self.waiting = waiting
            center.addError = CocoaError(.fileWriteUnknown)
        }

        func makeReminder() throws -> Task<Void, Never> {
            model.start()
            model.send(.startWork)
            clock.advance(1800)
            model.send(.refresh)
            return try XCTUnwrap(model.notificationTask)
        }

        func releaseDelay() {
            let waiting = delay
            delay = nil
            waiting?.resume()
        }

        func close() {
            model.shutdown()
            releaseDelay()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private func checkReminderSubmission(failStorage: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDirectory = directory.appendingPathComponent("active")
        let store = PersistenceService(url: stateDirectory.appendingPathComponent("state.json"))
        let center = MockNotificationCenter()
        let clock = makeClock()
        let model = AppModel(persistence: store, center: center, now: { clock.now })
        model.start()
        defer { model.shutdown() }
        model.send(.startWork)
        XCTAssertEqual(try store.load().timer.stage?.phase, .working)

        if failStorage {
            // Replace the state directory with a regular file so writes fail even as root.
            try FileManager.default.moveItem(at: stateDirectory, to: directory.appendingPathComponent("backup"))
            try Data().write(to: stateDirectory)
            XCTAssertThrowsError(try store.save(LocalData()))
        }

        let submitted = expectation(description: "Reminder submitted")
        center.onAdd = {
            if !failStorage {
                XCTAssertEqual((try? store.load())?.timer.stage?.phase, .breakDue)
            }
            submitted.fulfill()
        }
        clock.advance(1800)
        model.send(.refresh)
        XCTAssertEqual(model.state, .breakDue)
        if failStorage {
            XCTAssertTrue(model.storageError?.contains("可能无法恢复当前状态") == true)
            let backup = PersistenceService(url: directory.appendingPathComponent("backup/state.json"))
            XCTAssertEqual(try backup.load().timer.stage?.phase, .working)
        } else {
            XCTAssertNil(model.storageError)
        }

        await fulfillment(of: [submitted], timeout: 3)
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.values.first.flatMap(NotificationService.token(for:)), model.stageID)
    }

    private func makeClock() -> TestClock {
        let calendar = Calendar(identifier: .gregorian)
        return TestClock(calendar.date(from: DateComponents(year: 2030, month: 1, day: 7, hour: 10))!)
    }
}
