import Foundation

public struct TimerPreset: Codable, Equatable, Identifiable {
    public let id: String
    public private(set) var name: String
    public private(set) var configuration: TimerConfiguration

    public static let defaultID = "balanced"
    public static let builtIns = [
        TimerPreset(id: "frequent", name: "高频活动",
                    configuration: .init(workMinutes: 20, activityMinutes: 3, snoozeMinutes: 5)),
        TimerPreset(id: defaultID, name: "均衡", configuration: .defaults),
        TimerPreset(id: "relaxed", name: "轻松",
                    configuration: .init(workMinutes: 45, activityMinutes: 5, snoozeMinutes: 5)),
        TimerPreset(id: "pomodoro", name: "番茄工作法",
                    configuration: .init(workMinutes: 25, activityMinutes: 5, snoozeMinutes: 5))
    ]

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    init(id: String, name: String, configuration: TimerConfiguration) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }

    var isValidCustomPreset: Bool {
        UUID(uuidString: id) != nil && Self.validName(name) == name && configuration.isValid
    }

    static func validName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return name
    }
}
