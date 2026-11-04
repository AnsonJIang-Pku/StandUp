import Foundation

public enum Weekday: Int, CaseIterable, Codable, Identifiable {
    case monday = 2, tuesday, wednesday, thursday, friday, saturday, sunday = 1

    public var id: Int { rawValue }
}

public struct DaySchedule: Codable, Equatable {
    public var enabled: Bool
    public var startMinute: Int
    public var endMinute: Int
    public var allowsOvernight: Bool
    public var allDay: Bool

    public init(enabled: Bool = true, startMinute: Int = 9 * 60, endMinute: Int = 22 * 60,
                allowsOvernight: Bool = false, allDay: Bool = false) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.allowsOvernight = allowsOvernight
        self.allDay = allDay
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, startMinute, endMinute, allowsOvernight, allDay
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  startMinute: try values.decodeIfPresent(Int.self, forKey: .startMinute) ?? 9 * 60,
                  endMinute: try values.decodeIfPresent(Int.self, forKey: .endMinute) ?? 22 * 60,
                  allowsOvernight: try values.decodeIfPresent(Bool.self, forKey: .allowsOvernight) ?? false,
                  allDay: try values.decodeIfPresent(Bool.self, forKey: .allDay) ?? false)
    }

    public var isValid: Bool {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else { return false }
        return !enabled || allDay || startMinute < endMinute || (allowsOvernight && startMinute > endMinute)
    }
}

public struct ScheduleConfiguration: Codable, Equatable {
    public static let defaults = ScheduleConfiguration()
    public var enabled = true
    private var days: [Weekday: DaySchedule] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, days }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        days = try values.decodeIfPresent([Weekday: DaySchedule].self, forKey: .days) ?? [:]
    }

    public subscript(day: Weekday) -> DaySchedule {
        get { days[day] ?? DaySchedule(enabled: day != .saturday && day != .sunday) }
        set { days[day] = newValue }
    }

    public var isValid: Bool { Weekday.allCases.allSatisfy { self[$0].isValid } }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && Weekday.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }
}
