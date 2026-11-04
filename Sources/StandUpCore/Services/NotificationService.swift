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

@MainActor
public protocol LocalNotificationCenter {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest, withCompletionHandler handler: ((Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: LocalNotificationCenter {
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
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
    private var currentRequest: (token: UUID, attempt: UUID)?

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
                       canSnooze: Bool = true, stillCurrent: () -> Bool) async -> NotificationStatus {
        let status = await status()
        guard status == .allowed, stillCurrent(), token != currentRequest?.token else { return status }
        cancelPending()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        let attempt = UUID()
        currentRequest = (token, attempt)

        let content = UNMutableNotificationContent()
        content.title = "该起来活动一下了！"
        content.body = "你已经连续工作了 \(workMinutes) 分钟。起来走走，活动一下肩颈和腿部吧。"
        content.categoryIdentifier = canSnooze ? Self.identifier : Self.noSnoozeCategory
        content.userInfo = [Self.tokenKey: token.uuidString]
        content.sound = bundle.url(forResource: Self.soundName, withExtension: nil) == nil
            ? .default : UNNotificationSound(named: UNNotificationSoundName(Self.soundName))
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        let error: Error? = await withCheckedContinuation { completion in
            center.add(request) { completion.resume(returning: $0) }
        }
        if let error {
            if currentRequest?.attempt == attempt { currentRequest = nil }
            NSLog("StandUp notification: %@", error.localizedDescription)
        }
        return status
    }

    public func cancelPending() {
        // Removing a request from the system queue does not make the same reminder a new one.
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    public func clear() {
        cancelPending()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    public nonisolated static func token(for request: UNNotificationRequest) -> UUID? {
        guard request.identifier == identifier,
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
