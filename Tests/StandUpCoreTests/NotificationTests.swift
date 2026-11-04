import AVFoundation
import Foundation
import UserNotifications
import XCTest
@testable import StandUpCore

@MainActor
final class MockNotificationCenter: LocalNotificationCenter {
    var permission = UNAuthorizationStatus.authorized
    var categories: Set<UNNotificationCategory> = []
    var requestedOptions: UNAuthorizationOptions = []
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: Set<String> = []
    var additions = 0
    var authorization: (() async -> UNAuthorizationStatus)?
    var onAdd: (() -> Void)?
    var addError: Error?
    var deferCompletions = false
    private var submissions: [(UNNotificationRequest, ((Error?) -> Void)?)] = []

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        if let authorization { return await authorization() }
        return permission
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        return permission == .authorized
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler handler: ((Error?) -> Void)?) {
        additions += 1
        submissions.append((request, handler))
        if !deferCompletions { completeSubmission(at: submissions.count - 1, error: addError) }
        onAdd?()
    }

    func completeSubmission(at index: Int, error: Error? = nil) {
        let (request, handler) = submissions.remove(at: index)
        if error == nil { pending[request.identifier] = request }
        handler?(error)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for id in identifiers { pending.removeValue(forKey: id) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        delivered.subtract(identifiers)
    }
}

final class NotificationTests: XCTestCase {
    @MainActor
    func testPermissionDeniedLeavesNoRequestAndGrantCanSubmit() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let token = UUID()
        center.permission = .denied
        let denied = try await service.requestPermission()
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(center.requestedOptions, [.alert, .sound])
        await service.notify(token) { true }
        XCTAssertEqual(center.additions, 0)

        center.permission = .authorized
        let allowed = try await service.requestPermission()
        XCTAssertEqual(allowed, .allowed)
        await service.notify(token) { true }
        let request = try XCTUnwrap(center.pending.values.first)
        XCTAssertEqual(request.identifier, NotificationService.identifier)
        XCTAssertEqual(request.content.categoryIdentifier, request.identifier)
        XCTAssertEqual(request.content.title, "该起来活动一下了！")
        XCTAssertTrue(request.content.body.contains("30 分钟"))
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(NotificationService.token(for: request), token)
    }

    @MainActor
    func testCategoryRegistersAndMapsAllActions() throws {
        let center = MockNotificationCenter()
        NotificationService(center: center).register()
        let category = try XCTUnwrap(center.categories.first { $0.identifier == NotificationService.identifier })
        XCTAssertEqual(category.identifier, NotificationService.identifier)
        XCTAssertEqual(category.actions.map(\.title), ["开始活动", "稍后提醒", "跳过本次"])
        let id = UUID()
        XCTAssertEqual(category.actions.map { NotificationService.event(for: $0.identifier, token: id) },
                       [.startBreak(id), .snooze(id), .skip(id)])
        XCTAssertNil(NotificationService.event(for: UNNotificationDefaultActionIdentifier, token: id))
        XCTAssertNil(NotificationService.event(for: UNNotificationDismissActionIdentifier, token: id))
    }

    @MainActor
    func testSnoozeCancelsOldRequestAndCreatesExactlyOneNewRequest() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let clock = TestClock(instant("2026-11-02T09:00:00+08:00"))
        let engine = TimerEngine(schedule: testSchedule, now: { clock.now })

        engine.handle(.startWork)
        clock.advance(1800)
        engine.handle(.refresh)
        let first = try XCTUnwrap(engine.snapshot.stage?.id)
        await service.notify(first) { true }
        await service.notify(first) { true }
        XCTAssertEqual(center.additions, 1)

        let effects = engine.handle(.snooze(first))
        XCTAssertTrue(effects.contains(.clearReminder))
        service.clear()
        XCTAssertTrue(center.pending.isEmpty)
        clock.advance(299)
        XCTAssertEqual(engine.handle(.refresh), [])
        clock.advance(1)
        let nextEffects = engine.handle(.refresh)
        let second = try XCTUnwrap(engine.snapshot.stage?.id)
        XCTAssertEqual(nextEffects, [.remind(second)])
        await service.notify(second) { true }
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.additions, 2)
        XCTAssertEqual(NotificationService.token(for: try XCTUnwrap(center.pending.values.first)), second)
    }

    @MainActor
    func testExhaustedSnoozeUsesManualActionsAndCycleWorkDuration() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        service.register()
        let id = UUID()
        await service.notify(id, workMinutes: 73, canSnooze: false) { true }
        let request = try XCTUnwrap(center.pending.values.first)
        XCTAssertTrue(request.content.body.contains("73 分钟"))
        let category = try XCTUnwrap(center.categories.first { $0.identifier == request.content.categoryIdentifier })
        XCTAssertEqual(category.actions.map(\.title), ["开始活动", "跳过本次"])
        XCTAssertEqual(NotificationService.token(for: request), id)
    }

    @MainActor
    func testStaleRequestIsDiscardedAfterAuthorizationCheck() async {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        await service.notify(UUID()) { false }
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.additions, 0)
    }

    @MainActor
    func testFailedNotificationCanRetrySameToken() async {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let token = UUID()
        center.addError = CocoaError(.fileWriteUnknown)

        await service.notify(token) { true }
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(center.pending.count, 0)

        center.addError = nil
        await service.notify(token) { true }
        XCTAssertEqual(center.additions, 2)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.values.first.flatMap(NotificationService.token(for:)), token)
    }

    @MainActor
    func testSuccessfulNotificationIsStillDeduplicated() async {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let token = UUID()

        await service.notify(token) { true }
        await service.notify(token) { true }
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(center.pending.count, 1)

        service.cancelPending()
        service.clear()
        await service.notify(token) { true }
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(center.pending.count, 0)
    }

    @MainActor
    func testStaleFailureCallbackDoesNotClearNewerToken() async {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let oldToken = UUID()
        let newToken = UUID()
        center.deferCompletions = true

        let oldAdded = expectation(description: "Old request added")
        center.onAdd = { oldAdded.fulfill() }
        let old = Task { await service.notify(oldToken) { true } }
        await fulfillment(of: [oldAdded], timeout: 3)

        let newAdded = expectation(description: "New request added")
        center.onAdd = { newAdded.fulfill() }
        let new = Task { await service.notify(newToken) { true } }
        await fulfillment(of: [newAdded], timeout: 3)
        center.onAdd = nil
        XCTAssertEqual(center.additions, 2)
        XCTAssertEqual(center.pending.count, 0)

        center.deferCompletions = false
        await service.notify(newToken) { true }
        XCTAssertEqual(center.additions, 2, "A submission in progress must be deduplicated too")
        center.completeSubmission(at: 1)
        _ = await new.value
        center.completeSubmission(at: 0, error: CocoaError(.fileWriteUnknown))
        _ = await old.value

        await service.notify(newToken) { true }
        XCTAssertEqual(center.additions, 2)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.values.first.flatMap(NotificationService.token(for:)), newToken)
    }

    @MainActor
    func testSoftSoundIsReadableAndShort() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources").appendingPathComponent(NotificationService.soundName)
        let audio = try AVAudioFile(forReading: source)
        let length = Double(audio.length) / audio.fileFormat.sampleRate
        XCTAssertEqual(length, 0.72, accuracy: 0.001)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
    }
}
