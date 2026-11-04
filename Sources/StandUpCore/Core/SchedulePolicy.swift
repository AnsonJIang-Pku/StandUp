import Foundation

public struct SchedulePolicy {
    public let configuration: ScheduleConfiguration
    private let timeZone: () -> TimeZone
    private let continuous: Bool

    public init(configuration: ScheduleConfiguration = .defaults,
                timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent }) {
        let valid = configuration.isValid ? configuration : .defaults
        self.configuration = valid
        self.timeZone = timeZone
        self.continuous = !valid.enabled || Self.coversWholeWeek(valid)
    }

    func withConfiguration(_ configuration: ScheduleConfiguration) -> SchedulePolicy {
        SchedulePolicy(configuration: configuration, timeZone: timeZone)
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone()
        return calendar
    }

    public func window(at date: Date) -> DateInterval? {
        if continuous { return DateInterval(start: .distantPast, end: .distantFuture) }

        let calendar = calendar
        let today = calendar.startOfDay(for: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let prior = yesterday.flatMap { dayWindow(on: $0, calendar: calendar) }
        let current = dayWindow(on: today, calendar: calendar)
        guard var window = prior.flatMap({ contains(date, in: $0) ? $0 : nil })
                ?? current.flatMap({ contains(date, in: $0) ? $0 : nil }) else { return nil }

        if let prior, let current, prior.end >= current.start {
            window = DateInterval(start: prior.start, end: max(prior.end, current.end))
        }

        // Adjacent days can extend an overnight or all-day window. Stop at the first gap.
        for offset in 2...7 {
            guard let previousDay = calendar.date(byAdding: .day, value: -offset, to: today),
                  let previous = dayWindow(on: previousDay, calendar: calendar),
                  previous.end >= window.start else { break }
            window = DateInterval(start: previous.start, end: max(window.end, previous.end))
        }
        for offset in 1...7 {
            guard let nextDay = calendar.date(byAdding: .day, value: offset, to: today),
                  nextDay <= window.end,
                  let next = dayWindow(on: nextDay, calendar: calendar), next.start <= window.end
            else { break }
            window = DateInterval(start: window.start, end: max(window.end, next.end))
        }
        return window
    }

    public func nextOpening(after date: Date) -> Date? {
        guard !continuous else { return nil }
        let calendar = calendar
        let earliest = window(at: date)?.end ?? date
        let day = calendar.startOfDay(for: earliest)
        for offset in 0...8 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: day),
                  let opening = dayWindow(on: candidate, calendar: calendar)?.start,
                  opening > date, opening >= earliest else { continue }
            return opening
        }
        return nil
    }

    public func dayKey(at date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public func nextMidnight(after date: Date) -> Date? {
        calendar.dateInterval(of: .day, for: date)?.end
    }

    private func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }

    private func dayWindow(on day: Date, calendar: Calendar) -> DateInterval? {
        guard let weekday = Weekday(rawValue: calendar.component(.weekday, from: day)),
              let civilDay = calendar.dateInterval(of: .day, for: day) else { return nil }
        let rule = configuration[weekday]
        guard rule.enabled else { return nil }
        if rule.allDay { return civilDay }

        let closingDay = rule.endMinute < rule.startMinute ? civilDay.end : civilDay.start
        guard let opening = boundary(rule.startMinute, on: civilDay.start, repeated: .first, calendar: calendar),
              let closing = boundary(rule.endMinute, on: closingDay, repeated: .last, calendar: calendar),
              opening < closing else { return nil }
        return DateInterval(start: opening, end: closing)
    }

    private func boundary(_ minute: Int, on day: Date, repeated: Calendar.RepeatedTimePolicy,
                          calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: day)
        if minute == 0 { return start }
        // Move a nonexistent wall time to the first valid instant. A repeated opening uses
        // the first occurrence, and a repeated closing uses the last.
        let match = calendar.nextDate(after: start.addingTimeInterval(-1),
                                      matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
                                      matchingPolicy: .nextTime, repeatedTimePolicy: repeated, direction: .forward)
        return match.flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil }
    }

    private static func coversWholeWeek(_ configuration: ScheduleConfiguration) -> Bool {
        let day = 1440
        let week = 7 * day
        var segments: [Range<Int>] = []
        for (index, weekday) in Weekday.allCases.enumerated() {
            let rule = configuration[weekday]
            guard rule.enabled else { continue }
            let base = index * day
            let start = base + (rule.allDay ? 0 : rule.startMinute)
            let end = base + (rule.allDay ? day : rule.endMinute + (rule.endMinute < rule.startMinute ? day : 0))
            segments.append(start..<min(end, week))
            if end > week { segments.append(0..<(end - week)) }
        }
        var covered = 0
        for segment in segments.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if segment.lowerBound > covered { return false }
            covered = max(covered, segment.upperBound)
        }
        return covered == week
    }
}
