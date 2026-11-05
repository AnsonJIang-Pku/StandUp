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
    var delivered: [String: UNNotificationRequest] = [:]
    var additions = 0
    var authorization: (() async -> UNAuthorizationStatus)?
    var onAdd: (() -> Void)?
    var beforeDeliveredLookup: (() async -> Void)?
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

    func completeSubmission(at index: Int, error: Error? = nil, deliveredImmediately: Bool = false) {
        let (request, handler) = submissions.remove(at: index)
        if error == nil {
            if deliveredImmediately {
                delivered[request.identifier] = request
            } else {
                pending[request.identifier] = request
            }
        }
        handler?(error)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] { Array(pending.values) }

    func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        await beforeDeliveredLookup?()
        return Array(delivered.values)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for id in identifiers { pending.removeValue(forKey: id) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        for id in identifiers { delivered.removeValue(forKey: id) }
    }
}

final class NotificationTests: XCTestCase {
    @MainActor
    func testActivityCompletionUsesSelectedSoundAndHasNoReminderActions() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let identifier = NotificationService.activityFinishedIdentifier
        await service.notifyActivityFinished(startedNextWork: true, sound: { .default }) { true }
        let audible = try XCTUnwrap(center.pending[identifier])
        XCTAssertEqual(audible.content.title, "活动结束，已开始下一轮")
        XCTAssertNotNil(audible.content.sound)
        XCTAssertTrue(audible.content.categoryIdentifier.isEmpty)
        XCTAssertNil(NotificationService.token(for: audible))

        await service.notifyActivityFinished(startedNextWork: false, sound: { nil }) { true }
        let silent = try XCTUnwrap(center.pending[identifier])
        XCTAssertEqual(silent.content.title, "活动结束，可以开始工作了")
        XCTAssertNil(silent.content.sound)
        XCTAssertNil(silent.trigger)
        service.clear()
        XCTAssertEqual(center.pending.count, 1)
    }

    @MainActor
    func testActivityCompletionRequiresPermissionAndAnEnabledSwitch() async {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        center.permission = .denied
        await service.notifyActivityFinished(startedNextWork: true, sound: { .default }) { true }
        center.permission = .authorized
        await service.notifyActivityFinished(startedNextWork: true, sound: { .default }) { false }
        XCTAssertEqual(center.additions, 0)
    }

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
        XCTAssertTrue(request.identifier.hasPrefix(NotificationService.identifier + "."))
        XCTAssertEqual(request.content.categoryIdentifier, NotificationService.identifier)
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
    func testClearRemovesLatePendingAndDeliveredSubmissions() async {
        for deliveredImmediately in [false, true] {
            let center = MockNotificationCenter()
            let service = NotificationService(center: center)
            let token = UUID()
            let task = await beginDeferredSubmission(token, service: service, center: center)

            service.clear()
            center.completeSubmission(at: 0, deliveredImmediately: deliveredImmediately)
            let result = await task.value

            XCTAssertEqual(result.submission, .idle)
            XCTAssertEqual(center.additions, 1)
            XCTAssertTrue(center.pending.isEmpty)
            XCTAssertTrue(center.delivered.isEmpty)
        }
    }

    @MainActor
    func testCancelledSubmissionCompletesBeforeNewerSubmission() async {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let old = await beginDeferredSubmission(UUID(), service: service, center: center)
        service.cancelPending()

        let newToken = UUID()
        let new = await beginDeferredSubmission(newToken, service: service, center: center)
        center.completeSubmission(at: 0)
        _ = await old.value
        XCTAssertTrue(center.pending.isEmpty)
        center.completeSubmission(at: 0)
        _ = await new.value

        XCTAssertEqual(center.additions, 2)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.values.first.flatMap(NotificationService.token(for:)), newToken)
        XCTAssertTrue(center.delivered.isEmpty)
    }

    @MainActor
    func testLateSuccessfulSubmissionDoesNotRemoveNewerSubmission() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let old = await beginDeferredSubmission(UUID(), service: service, center: center)
        let newToken = UUID()
        let new = await beginDeferredSubmission(newToken, service: service, center: center)

        center.completeSubmission(at: 1)
        _ = await new.value
        let newRequest = try XCTUnwrap(center.pending.values.first)
        center.completeSubmission(at: 0, deliveredImmediately: true)
        _ = await old.value

        XCTAssertEqual(center.additions, 2)
        XCTAssertEqual(Set(center.pending.keys), [newRequest.identifier])
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertTrue(service.canPresent(newRequest))
        XCTAssertEqual(NotificationService.token(for: newRequest), newToken)
    }

    @MainActor
    func testCancelPendingPreservesDeliveredNotification() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let task = await beginDeferredSubmission(UUID(), service: service, center: center)
        center.completeSubmission(at: 0, deliveredImmediately: true)
        _ = await task.value
        let delivered = try XCTUnwrap(center.delivered.values.first)

        service.cancelPending()
        XCTAssertEqual(center.additions, 1)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(Set(center.delivered.keys), [delivered.identifier])
        XCTAssertTrue(service.canHandle(delivered))
        service.clear()
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertFalse(service.canHandle(delivered))
    }

    @MainActor
    func testStartupCleansUpPriorAttemptsAndPreservesCurrentDeliveredReminder() async {
        let center = MockNotificationCenter()
        let previousService = NotificationService(center: center)
        let currentToken = UUID()
        let delivered = await beginDeferredSubmission(currentToken, service: previousService, center: center)
        center.completeSubmission(at: 0, deliveredImmediately: true)
        _ = await delivered.value
        let otherContent = UNMutableNotificationContent()
        otherContent.userInfo = ["reminderID": UUID().uuidString]
        let obsolete = UNNotificationRequest(identifier: NotificationService.identifier, content: otherContent, trigger: nil)
        center.pending[obsolete.identifier] = obsolete
        center.delivered[obsolete.identifier] = obsolete

        let service = NotificationService(center: center)
        await service.cleanUpPreviousRequests { $0 == currentToken }

        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.delivered.values.first.flatMap(NotificationService.token(for:)), currentToken)
        XCTAssertTrue(center.delivered.values.allSatisfy(service.canHandle))
        service.clear()
        XCTAssertTrue(center.delivered.isEmpty)
    }

    @MainActor
    func testStartupPreservesCurrentPendingReminder() async throws {
        let center = MockNotificationCenter()
        let token = UUID()
        let previous = NotificationService(center: center)
        await previous.notify(token) { true }
        let request = try XCTUnwrap(center.pending.values.first)
        let service = NotificationService(center: center)

        await service.cleanUpPreviousRequests { $0 == token }

        XCTAssertEqual(Set(center.pending.keys), [request.identifier])
        XCTAssertTrue(service.hasRestoredReminder(token))
        XCTAssertTrue(service.canPresent(request))
        XCTAssertTrue(service.canHandle(request))
        await service.notify(token) { true }
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(Set(center.pending.keys), [request.identifier])
    }

    @MainActor
    func testStartupRemovesStalePendingReminders() async {
        let center = MockNotificationCenter()
        let token = UUID()
        let prefix = NotificationService.identifier + ".old."
        let current = Self.request(prefix + "current", token: token)
        let stale = Self.request(prefix + "stale", token: UUID())
        let staleLegacy = Self.request(NotificationService.identifier, token: UUID())
        let malformed = Self.request(prefix + "malformed", token: nil)
        let unrelated = Self.request("unrelated.reminder", token: token)
        for request in [current, stale, staleLegacy, malformed, unrelated] {
            center.pending[request.identifier] = request
        }
        let service = NotificationService(center: center)

        await service.cleanUpPreviousRequests { $0 == token }

        XCTAssertEqual(Set(center.pending.keys), [current.identifier, unrelated.identifier])
        for request in [stale, staleLegacy, malformed, unrelated] {
            XCTAssertFalse(service.canPresent(request))
            XCTAssertFalse(service.canHandle(request))
        }
    }

    @MainActor
    func testStartupCleanupAndLateOldCompletionDoNotRemoveNewSubmission() async throws {
        let center = MockNotificationCenter()
        let previous = NotificationService(center: center)
        let oldToken = UUID()
        let oldSubmission = await beginDeferredSubmission(oldToken, service: previous, center: center)
        previous.clear()
        let stale = Self.request(NotificationService.identifier + ".old.stale", token: UUID())
        center.pending[stale.identifier] = stale

        let lookupStarted = expectation(description: "Startup lookup is suspended")
        var resumeLookup: CheckedContinuation<Void, Never>?
        center.beforeDeliveredLookup = {
            await withCheckedContinuation {
                resumeLookup = $0
                lookupStarted.fulfill()
            }
        }
        let service = NotificationService(center: center)
        let newToken = UUID()
        let cleanup = Task { await service.cleanUpPreviousRequests { $0 == newToken } }
        await fulfillment(of: [lookupStarted], timeout: 3)
        center.deferCompletions = false
        let result = await service.notify(newToken) { true }
        XCTAssertEqual(result.submission, .submitted)
        let newRequest = try XCTUnwrap(center.pending.values.first {
            NotificationService.token(for: $0) == newToken
        })
        // Both requests reach the delivered queue before startup takes its second snapshot.
        center.pending[newRequest.identifier] = nil
        center.delivered[newRequest.identifier] = newRequest
        center.pending[stale.identifier] = nil
        center.delivered[stale.identifier] = stale
        try XCTUnwrap(resumeLookup).resume()
        await cleanup.value

        center.completeSubmission(at: 0, deliveredImmediately: true)
        _ = await oldSubmission.value
        XCTAssertEqual(center.additions, 2)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(Set(center.delivered.keys), [newRequest.identifier])
        XCTAssertTrue(service.canPresent(newRequest))
        XCTAssertTrue(service.canHandle(newRequest))
    }

    @MainActor
    func testCancellationSemanticsForRestoredNotifications() async {
        let center = MockNotificationCenter()
        let token = UUID()
        let pending = Self.request(NotificationService.identifier + ".old.pending", token: token)
        let delivered = Self.request(NotificationService.identifier + ".old.delivered", token: token)
        center.pending[pending.identifier] = pending
        center.delivered[delivered.identifier] = delivered
        let service = NotificationService(center: center)
        await service.cleanUpPreviousRequests { $0 == token }

        service.cancelPending()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(Set(center.delivered.keys), [delivered.identifier])
        XCTAssertTrue(service.canHandle(delivered))

        // Simulate the request reaching the queue after pending cancellation.
        center.pending[pending.identifier] = pending
        service.clear()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertFalse(service.canHandle(delivered))
        XCTAssertFalse(service.hasRestoredReminder(token))
    }

    static func request(_ identifier: String, token: UUID?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        if let token { content.userInfo = ["reminderID": token.uuidString] }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    @MainActor
    private func beginDeferredSubmission(
        _ token: UUID, service: NotificationService, center: MockNotificationCenter
    ) async -> Task<(authorization: NotificationStatus, submission: NotificationSubmissionState), Never> {
        center.deferCompletions = true
        let added = expectation(description: "Request handed to the notification center")
        center.onAdd = { added.fulfill() }
        let task = Task { await service.notify(token) { true } }
        await fulfillment(of: [added], timeout: 3)
        center.onAdd = nil
        return task
    }

    @MainActor
    func testSilentSoundStillSubmitsNotification() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let token = UUID()
        let result = await service.notify(token, sound: { nil }) { true }
        let request = try XCTUnwrap(center.pending.values.first)
        XCTAssertEqual(result.submission, .submitted)
        XCTAssertEqual(NotificationService.token(for: request), token)
        XCTAssertNil(request.content.sound)
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
