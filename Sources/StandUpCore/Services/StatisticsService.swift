import Foundation

public struct StatisticsService: Codable, Equatable {
    private struct Day: Codable, Equatable {
        var totals = DailyStatistics()
        var eventIDs: Set<UUID> = []
    }

    private var days: [String: Day] = [:]

    public init() {}

    public func totals(at date: Date, schedule: SchedulePolicy) -> DailyStatistics {
        days[schedule.dayKey(at: date)]?.totals ?? DailyStatistics()
    }

    public mutating func record(_ statistic: Statistic, id: UUID, at date: Date,
                                schedule: SchedulePolicy) {
        guard !days.values.contains(where: { $0.eventIDs.contains(id) }) else { return }
        let key = schedule.dayKey(at: date)
        var day = days[key, default: Day()]
        day.eventIDs.insert(id)
        switch statistic {
        case .work: day.totals.completedWork += 1
        case let .activity(seconds):
            day.totals.completedActivities += 1
            day.totals.activitySeconds += seconds
        case .skip: day.totals.skips += 1
        case .snooze: day.totals.snoozes += 1
        }
        days[key] = day
    }

    public mutating func prune(at date: Date, schedule: SchedulePolicy) {
        let calendar = schedule.calendar
        guard let first = calendar.date(byAdding: .day, value: 1 - TimerConfiguration.retentionDays,
                                        to: calendar.startOfDay(for: date)) else { return }
        let firstKey = schedule.dayKey(at: first)
        days = days.filter { $0.key >= firstKey }
    }
}
