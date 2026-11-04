public struct DailyStatistics: Codable, Equatable {
    public internal(set) var completedActivities = 0
    public internal(set) var activitySeconds = 0
    public internal(set) var skips = 0
    public internal(set) var snoozes = 0
    public internal(set) var completedWork = 0

    public init() {}
}
