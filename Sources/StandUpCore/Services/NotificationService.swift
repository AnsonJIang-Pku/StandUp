import Foundation
import UserNotifications

public enum NotificationStatus: Equatable {
    case notDetermined, allowed, denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .allowed
        @unknown default: self = .denied
        }
    }
}

public enum NotificationSubmissionState: Equatable {
    case idle, submitting, submitted, failed
}

@MainActor
public protocol LocalNotificationCenter {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest, withCompletionHandler handler: ((Error?) -> Void)?)
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func deliveredNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: LocalNotificationCenter {
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    public func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        await deliveredNotifications().map(\.request)
    }
}

@MainActor
public final class NotificationService {
    public nonisolated static let identifier = "com.standup.reminder.break"
    static let noSnoozeCategory = "com.standup.reminder.break.no-snooze"
    public static let soundName = "StandUpSoft.aiff"
    private nonisolated static let tokenKey = "reminderID"

    private enum Action: String, CaseIterable {
        case start = "STANDUP_START_BREAK"
        case snooze = "STANDUP_SNOOZE"
        case skip = "STANDUP_SKIP"

        var title: String {
            switch self {
            case .start: return "开始活动"
            case .snooze: return "稍后提醒"
            case .skip: return "跳过本次"
            }
        }
    }

    private let center: LocalNotificationCenter
    private let bundle: Bundle
    private let instancePrefix = NotificationService.identifier + "." + UUID().uuidString + "."
    private var latestIntent: UUID?
    private var currentRequest: Submission?
    private var inFlight: [String: Submission] = [:]
    // nil until startup reconciliation finishes or a clear invalidates historical requests.
    private var restoredRequests: [String: UUID]?

    private enum Removal {
        case pending, all
    }

    private final class Submission {
        let token: UUID
        let identifier: String
        var removal: Removal?

        init(token: UUID, identifier: String) {
            self.token = token
            self.identifier = identifier
        }
    }

    public init(center: LocalNotificationCenter, bundle: Bundle = .main) {
        self.center = center
        self.bundle = bundle
    }

    public func register() {
        let actions = Action.allCases.map {
            UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: [])
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.identifier, actions: actions,
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.noSnoozeCategory,
                                   actions: actions.filter { $0.identifier != Action.snooze.rawValue },
                                   intentIdentifiers: [], options: [])
        ])
    }

    public func status() async -> NotificationStatus {
        NotificationStatus(await center.authorizationStatus())
    }

    public func requestPermission() async throws -> NotificationStatus {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await status()
    }

    @discardableResult
    public func notify(_ token: UUID, workMinutes: Int = TimerConfiguration.defaults.workMinutes,
                       canSnooze: Bool = true, stillCurrent: () -> Bool) async
        -> (authorization: NotificationStatus, submission: NotificationSubmissionState) {
        let intent = UUID()
        if !Task.isCancelled, stillCurrent(), token != currentRequest?.token, !hasRestoredReminder(token) {
            latestIntent = intent
        }
        let permission = await status()
        guard permission == .allowed, latestIntent == intent, !Task.isCancelled, stillCurrent(),
              token != currentRequest?.token, !hasRestoredReminder(token) else { return (permission, .idle) }

        clear()
        // System removals are asynchronous. Never reuse an identifier across add attempts.
        let submission = Submission(token: token, identifier: instancePrefix + UUID().uuidString)
        currentRequest = submission
        inFlight[submission.identifier] = submission

        let content = UNMutableNotificationContent()
        content.title = "该起来活动一下了！"
        content.body = "你已经连续工作了 \(workMinutes) 分钟。起来走走，活动一下肩颈和腿部吧。"
        content.categoryIdentifier = canSnooze ? Self.identifier : Self.noSnoozeCategory
        content.userInfo = [Self.tokenKey: token.uuidString]
        content.sound = bundle.url(forResource: Self.soundName, withExtension: nil) == nil
            ? .default : UNNotificationSound(named: UNNotificationSoundName(Self.soundName))
        let request = UNNotificationRequest(identifier: submission.identifier, content: content, trigger: nil)
        let error: Error? = await withCheckedContinuation { completion in
            center.add(request) { completion.resume(returning: $0) }
        }
        inFlight.removeValue(forKey: submission.identifier)
        if error != nil, currentRequest === submission { currentRequest = nil }
        if let removal = submission.removal {
            remove([submission.identifier], removal)
            return (permission, .idle)
        }
        guard !Task.isCancelled, stillCurrent() else {
            submission.removal = .all
            remove([submission.identifier], .all)
            return (permission, .idle)
        }
        if let error {
            remove([submission.identifier], .all)
            NSLog("StandUp notification: %@", error.localizedDescription)
            let systemError = error as NSError
            if systemError.domain == UNErrorDomain && systemError.code == UNError.Code.notificationsNotAllowed.rawValue {
                return (.denied, .idle)
            }
            return (permission, .failed)
        }
        return (permission, .submitted)
    }

    public func cancelPending() {
        invalidate(.pending)
    }

    public func clear() {
        invalidate(.all)
    }

    private func invalidate(_ removal: Removal) {
        latestIntent = nil
        var identifiers = Set(inFlight.keys)
        for submission in inFlight.values where submission.removal != .all {
            submission.removal = removal
        }
        if let currentRequest {
            identifiers.insert(currentRequest.identifier)
            if removal == .all { currentRequest.removal = .all }
        }
        if let restoredRequests { identifiers.formUnion(restoredRequests.keys) }
        identifiers.insert(Self.identifier)
        if removal == .all { restoredRequests = [:] }
        remove(Array(identifiers), removal)
    }

    private func remove(_ identifiers: [String], _ removal: Removal) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        if removal == .all { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    }

    public func cleanUpPreviousRequests(keeping isCurrent: (UUID) -> Bool) async {
        // Read pending first so a request moving to delivered during the lookup can still be found.
        let pending = await center.pendingNotificationRequests().filter(isPreviousReminder)
        guard !Task.isCancelled else { return }
        let delivered = await center.deliveredNotificationRequests().filter(isPreviousReminder)
        guard !Task.isCancelled else { return }

        let previous = pending + delivered
        var kept: [String: UUID] = [:]
        for request in previous {
            if canUsePreviousReminder(request), let token = Self.token(for: request), isCurrent(token) {
                kept[request.identifier] = token
            }
        }
        restoredRequests = kept
        // A stale pending request may already have moved to the delivered queue.
        let obsolete = Set(previous.map(\.identifier).filter { kept[$0] == nil })
        remove(Array(obsolete), .all)
    }

    public func hasRestoredReminder(_ token: UUID) -> Bool {
        restoredRequests?.values.contains(token) == true
    }

    private func isPreviousReminder(_ request: UNNotificationRequest) -> Bool {
        Self.isReminderIdentifier(request.identifier) && !request.identifier.hasPrefix(instancePrefix)
    }

    private func canUsePreviousReminder(_ request: UNNotificationRequest) -> Bool {
        // The app also validates the token, including for a notification delivered during startup.
        guard currentRequest == nil, isPreviousReminder(request),
              let token = Self.token(for: request) else { return false }
        return restoredRequests == nil || restoredRequests?[request.identifier] == token
    }

    public func canPresent(_ request: UNNotificationRequest) -> Bool {
        (currentRequest?.identifier == request.identifier && currentRequest?.removal == nil)
            || canUsePreviousReminder(request)
    }

    public func canHandle(_ request: UNNotificationRequest) -> Bool {
        canPresent(request)
    }

    private nonisolated static func isReminderIdentifier(_ value: String) -> Bool {
        value == identifier || value.hasPrefix(identifier + ".")
    }

    public nonisolated static func token(for request: UNNotificationRequest) -> UUID? {
        guard isReminderIdentifier(request.identifier),
              let value = request.content.userInfo[tokenKey] as? String else { return nil }
        return UUID(uuidString: value)
    }

    public nonisolated static func event(for identifier: String, token: UUID) -> TimerEvent? {
        switch Action(rawValue: identifier) {
        case .start: return .startBreak(token)
        case .snooze: return .snooze(token)
        case .skip: return .skip(token)
        case nil: return nil
        }
    }
}
