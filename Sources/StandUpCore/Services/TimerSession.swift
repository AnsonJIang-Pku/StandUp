import Foundation

public final class TimerSession {
    public let engine: TimerEngine
    public private(set) var data: LocalData
    private let now: () -> Date

    public init(data: LocalData = LocalData(), schedule: SchedulePolicy? = nil,
                now: @escaping () -> Date = { Date() }) {
        self.data = data
        self.now = now
        let policy = (schedule ?? SchedulePolicy()).withConfiguration(data.settings.schedule)
        self.engine = TimerEngine(snapshot: data.timer, schedule: policy,
                                  configuration: data.settings.timer, now: now)
    }

    @discardableResult
    public func handle(_ event: TimerEvent) -> [TimerEffect] {
        synchronize(engine.handle(event))
    }

    public func applySettings(_ settings: AppSettings) -> [TimerEffect] {
        guard settings.isValid else { return [] }
        let scheduleChanged = data.settings.schedule != settings.schedule
        data.settings = settings
        engine.updateConfiguration(settings.timer)
        return scheduleChanged ? synchronize(engine.updateSchedule(settings.schedule)) : []
    }

    private func synchronize(_ effects: [TimerEffect]) -> [TimerEffect] {
        data.timer = engine.snapshot
        if data.settings.statisticsEnabled {
            for case let .record(statistic, id, date) in effects {
                data.statistics.record(statistic, id: id, at: date, schedule: engine.schedule)
            }
        }
        data.statistics.prune(at: now(), schedule: engine.schedule)
        return effects
    }

    public func setStatisticsEnabled(_ enabled: Bool) {
        data.settings.statisticsEnabled = enabled
    }
}
