import Foundation

public struct TimerConfiguration: Codable, Equatable {
    public static let defaults = TimerConfiguration()
    public static let minuteRange = 1...1440
    public static let snoozeCountRange = 0...9999
    public static let retentionDays = 30

    public var workMinutes = 30
    public var activityMinutes = 3
    public var snoozeMinutes = 5
    public var maxSnoozeCount: Int?
    public var autoStartNextWork = true

    public init() {}

    public init(workMinutes: Int, activityMinutes: Int, snoozeMinutes: Int,
                maxSnoozeCount: Int? = nil, autoStartNextWork: Bool = true) {
        self.workMinutes = workMinutes
        self.activityMinutes = activityMinutes
        self.snoozeMinutes = snoozeMinutes
        self.maxSnoozeCount = maxSnoozeCount
        self.autoStartNextWork = autoStartNextWork
    }

    private enum CodingKeys: String, CodingKey {
        case workMinutes, activityMinutes, snoozeMinutes, maxSnoozeCount, autoStartNextWork
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workMinutes = try values.decodeIfPresent(Int.self, forKey: .workMinutes) ?? Self.defaults.workMinutes
        activityMinutes = try values.decodeIfPresent(Int.self, forKey: .activityMinutes) ?? Self.defaults.activityMinutes
        snoozeMinutes = try values.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? Self.defaults.snoozeMinutes
        maxSnoozeCount = try values.decodeIfPresent(Int.self, forKey: .maxSnoozeCount)
        autoStartNextWork = try values.decodeIfPresent(Bool.self, forKey: .autoStartNextWork) ?? true
    }

    public static func parseDuration(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, let value = parseDigits(first) else { return nil }
        let minutes: Int
        switch parts.count {
        case 1:
            minutes = value
        case 2:
            guard value <= minuteRange.upperBound / 60, parts[1].count == 2,
                  let fraction = parseDigits(parts[1]), fraction < 60 else { return nil }
            minutes = value * 60 + fraction
        default:
            return nil
        }
        return minuteRange.contains(minutes) ? minutes : nil
    }

    public static func parseSnoozeCount(_ text: String) -> Int? {
        guard let count = parseDigits(text.trimmingCharacters(in: .whitespacesAndNewlines)[...]),
              snoozeCountRange.contains(count) else { return nil }
        return count
    }

    private static func parseDigits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }

    public var isValid: Bool {
        [workMinutes, activityMinutes, snoozeMinutes].allSatisfy(Self.minuteRange.contains)
            && (maxSnoozeCount.map(Self.snoozeCountRange.contains) ?? true)
    }

    public func duration(for phase: TimerPhase) -> TimeInterval? {
        switch phase {
        case .working: return TimeInterval(workMinutes) * 60
        case .onBreak: return TimeInterval(activityMinutes) * 60
        case .snoozed: return TimeInterval(snoozeMinutes) * 60
        case .breakDue: return nil
        }
    }
}
