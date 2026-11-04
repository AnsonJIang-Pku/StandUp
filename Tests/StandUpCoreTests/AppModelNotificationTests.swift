import Combine
import Foundation
import UserNotifications
import XCTest
import StandUpCore
@testable import StandUpAppTestSupport

final class AppModelNotificationTests: XCTestCase {
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
        let finished = expectation(description: "Notification attempt completed")
        let observation = model.$notificationStatus.dropFirst().prefix(1).sink { _ in
            finished.fulfill()
        }
        defer { observation.cancel() }

        model.send(.startWork)
        clock.advance(1800)
        model.send(.refresh)
        let token = try XCTUnwrap(model.stageID)
        XCTAssertTrue(model.isCurrentReminder(token))
        await fulfillment(of: [checking], timeout: 3)
        model.send(.stop)
        XCTAssertFalse(model.isCurrentReminder(token))
        try XCTUnwrap(authorization).resume(returning: .authorized)

        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(center.additions, 0)
        XCTAssertEqual(center.pending.count, 0)
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
