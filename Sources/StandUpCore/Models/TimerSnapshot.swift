import Foundation

public struct TimerSnapshot: Codable, Equatable {
    public internal(set) var stage: Stage?
    public internal(set) var sessionStartedAt: Date?
    public internal(set) var sessionEndsAt: Date?

    public internal(set) var configuration: TimerConfiguration = .defaults
    public internal(set) var snoozeCount = 0
    public internal(set) var scheduleTimeZoneID: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case stage, sessionStartedAt, sessionEndsAt, configuration, snoozeCount, scheduleTimeZoneID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stage = try values.decodeIfPresent(Stage.self, forKey: .stage)
        sessionStartedAt = try values.decodeIfPresent(Date.self, forKey: .sessionStartedAt)
        sessionEndsAt = try values.decodeIfPresent(Date.self, forKey: .sessionEndsAt)
        configuration = try values.decodeIfPresent(TimerConfiguration.self, forKey: .configuration) ?? .defaults
        snoozeCount = try values.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0
        scheduleTimeZoneID = try values.decodeIfPresent(String.self, forKey: .scheduleTimeZoneID)
    }

    public struct Stage: Codable, Equatable {
        public internal(set) var id: UUID
        public let phase: TimerPhase
        public internal(set) var startedAt: Date
        public internal(set) var deadline: Date?
        public internal(set) var suspension: Suspension?
    }

    public struct Suspension: Codable, Equatable {
        public let reason: Reason
        public let remainingSeconds: TimeInterval?

        public enum Reason: String, Codable, Equatable {
            case user, sleep
        }
    }

    var isValid: Bool {
        guard configuration.isValid, snoozeCount >= 0 else { return false }
        guard let stage else { return sessionStartedAt == nil && sessionEndsAt == nil }
        guard let start = sessionStartedAt, let end = sessionEndsAt, start < end else { return false }
        if let duration = configuration.duration(for: stage.phase) {
            if let suspension = stage.suspension {
                guard let remaining = suspension.remainingSeconds else { return false }
                return stage.deadline == nil && (0...duration).contains(remaining)
            }
            return stage.deadline != nil
        }
        return stage.deadline == nil && stage.suspension?.remainingSeconds == nil
    }
}
