import Foundation

public final class TimerEngine {
    public private(set) var snapshot: TimerSnapshot
    public private(set) var state: TimerState = .idle
    public private(set) var schedule: SchedulePolicy
    public private(set) var globalConfiguration: TimerConfiguration
    private let now: () -> Date

    public init(snapshot: TimerSnapshot = TimerSnapshot(), schedule: SchedulePolicy = SchedulePolicy(),
                configuration: TimerConfiguration = .defaults,
                now: @escaping () -> Date = { Date() }) {
        self.snapshot = snapshot.isValid ? snapshot : TimerSnapshot()
        self.schedule = schedule
        self.globalConfiguration = configuration.isValid ? configuration : .defaults
        self.now = now
        updateState(at: now())
    }

    public var activeConfiguration: TimerConfiguration {
        snapshot.stage == nil ? globalConfiguration : snapshot.configuration
    }

    public var canSnooze: Bool {
        guard snapshot.stage?.phase == .breakDue, snapshot.stage?.suspension == nil else { return false }
        return snapshot.configuration.maxSnoozeCount.map { snapshot.snoozeCount < $0 } ?? true
    }

    public func isCurrentReminder(_ id: UUID, at date: Date) -> Bool {
        guard let stage = snapshot.stage, let end = snapshot.sessionEndsAt else { return false }
        return isCurrentReminder(id, stage: stage) && date < end && schedule.window(at: date) != nil
    }

    func updateConfiguration(_ configuration: TimerConfiguration) {
        if configuration.isValid { globalConfiguration = configuration }
    }

    func updateSchedule(_ configuration: ScheduleConfiguration) -> [TimerEffect] {
        let date = now()
        let updated = schedule.withConfiguration(configuration)
        var effects: [TimerEffect] = []
        if let end = snapshot.sessionEndsAt {
            if date < end, let window = updated.window(at: date),
               let start = snapshot.sessionStartedAt, window.end > start {
                snapshot.sessionEndsAt = window.end
                snapshot.scheduleTimeZoneID = updated.calendar.timeZone.identifier
            } else {
                endSession(at: date, effects: &effects)
            }
        }
        schedule = updated
        return effects + handle(.refresh)
    }

    public func remaining(at date: Date) -> TimeInterval? {
        guard let stage = snapshot.stage, let duration = snapshot.configuration.duration(for: stage.phase) else { return nil }
        if let suspension = stage.suspension { return suspension.remainingSeconds }
        return stage.deadline.map { min(duration, max(0, $0.timeIntervalSince(date))) }
    }

    public func nextCheck(after date: Date) -> Date? {
        let closing = schedule.window(at: date)?.end
        if snapshot.stage == nil {
            if let closing { return closing == .distantFuture ? nil : closing }
            return schedule.nextOpening(after: date)
        }
        guard let closing, let end = snapshot.sessionEndsAt else { return date }
        return [closing, end, snapshot.stage?.deadline].compactMap { $0 }
            .filter { $0 != .distantFuture }.min()
    }

    @discardableResult
    public func handle(_ event: TimerEvent) -> [TimerEffect] {
        let date = now()
        var effects: [TimerEffect] = []
        defer { updateState(at: date) }

        guard let window = schedule.window(at: date) else {
            endSession(at: date, effects: &effects)
            return effects
        }

        if let end = snapshot.sessionEndsAt {
            if date >= end {
                endSession(at: date, effects: &effects)
            } else {
                let zoneID = schedule.calendar.timeZone.identifier
                if let previousZone = snapshot.scheduleTimeZoneID, previousZone != zoneID {
                    if let start = snapshot.sessionStartedAt, window.end <= start {
                        endSession(at: date, effects: &effects)
                    } else {
                        snapshot.sessionEndsAt = window.end
                    }
                }
                if snapshot.stage != nil { snapshot.scheduleTimeZoneID = zoneID }
            }
        }

        if event == .stop || event == .restart {
            endSession(at: date, effects: &effects)
            if event == .restart { startSession(at: date, until: window.end) }
            return effects
        }

        if snapshot.stage == nil {
            if event == .startWork { startSession(at: date, until: window.end) }
            return effects
        }

        if event == .systemWillSleep {
            advanceIfExpired(at: date, announce: false, effects: &effects)
            suspend(.sleep, at: date, effects: &effects)
            return effects
        }

        advanceIfExpired(at: date, announce: true, effects: &effects)
        guard let stage = snapshot.stage else { return effects }

        switch event {
        case .pause:
            suspend(.user, at: date, effects: &effects)
        case .resume:
            restore(.user, at: date, effects: &effects)
        case .applicationLaunched, .systemDidWake:
            restore(.sleep, at: date, effects: &effects)
        case let .startBreak(id) where isCurrentReminder(id, stage: stage):
            effects.append(.clearReminder)
            setStage(.onBreak, at: date)
        case let .snooze(id) where isCurrentReminder(id, stage: stage) && canSnooze:
            if snapshot.snoozeCount < Int.max { snapshot.snoozeCount += 1 }
            effects += [.clearReminder, .record(.snooze, id, date)]
            setStage(.snoozed, at: date)
        case let .skip(id) where isCurrentReminder(id, stage: stage):
            effects += [.clearReminder, .record(.skip, id, date)]
            setStage(.working, at: date)
        default:
            break
        }
        return effects
    }

    private func updateState(at date: Date) {
        if let stage = snapshot.stage {
            state = stage.suspension == nil ? stage.phase.state : .paused
        } else {
            state = schedule.window(at: date) == nil ? .outsideSchedule : .idle
        }
    }

    private func startSession(at date: Date, until end: Date) {
        snapshot.sessionStartedAt = date
        snapshot.sessionEndsAt = end
        snapshot.scheduleTimeZoneID = schedule.calendar.timeZone.identifier
        setStage(.working, at: date)
    }

    private func setStage(_ phase: TimerPhase, at date: Date) {
        if phase == .working {
            snapshot.configuration = globalConfiguration
            snapshot.snoozeCount = 0
        }
        snapshot.stage = .init(id: UUID(), phase: phase, startedAt: date,
                               deadline: snapshot.configuration.duration(for: phase).map { date.addingTimeInterval($0) },
                               suspension: nil)
    }

    private func isCurrentReminder(_ id: UUID, stage: TimerSnapshot.Stage) -> Bool {
        stage.id == id && stage.phase == .breakDue && stage.suspension == nil
    }

    private func advanceIfExpired(at date: Date, announce: Bool, effects: inout [TimerEffect]) {
        guard let stage = snapshot.stage, let deadline = stage.deadline, date >= deadline else { return }
        if let completion = completionEffect(for: stage, deadline: deadline) {
            effects.append(completion)
        }
        if stage.phase == .onBreak && !snapshot.configuration.autoStartNextWork {
            snapshot = TimerSnapshot()
            return
        }
        setStage(stage.phase == .onBreak ? .working : .breakDue, at: date)
        if announce, let due = snapshot.stage, due.phase == .breakDue {
            effects.append(.remind(due.id))
        }
    }

    private func endSession(at date: Date, effects: inout [TimerEffect]) {
        guard let stage = snapshot.stage else { return }
        effects.append(.clearReminder)
        if let deadline = stage.deadline, let end = snapshot.sessionEndsAt,
           date >= deadline, deadline < end,
           let completion = completionEffect(for: stage, deadline: deadline) {
            effects.append(completion)
        }
        snapshot = TimerSnapshot()
    }

    private func completionEffect(for stage: TimerSnapshot.Stage, deadline: Date) -> TimerEffect? {
        switch stage.phase {
        case .working: return .record(.work, stage.id, deadline)
        case .onBreak:
            return .record(.activity(seconds: snapshot.configuration.activityMinutes * 60), stage.id, deadline)
        case .snoozed, .breakDue: return nil
        }
    }

    private func suspend(_ reason: TimerSnapshot.Suspension.Reason, at date: Date,
                         effects: inout [TimerEffect]) {
        guard var stage = snapshot.stage, stage.suspension == nil else { return }
        if stage.phase == .breakDue {
            effects.removeAll { $0 == .remind(stage.id) }
            effects.append(.clearReminder)
        }
        stage.suspension = .init(reason: reason, remainingSeconds: remaining(at: date))
        stage.deadline = nil
        snapshot.stage = stage
    }

    private func restore(_ reason: TimerSnapshot.Suspension.Reason, at date: Date,
                         effects: inout [TimerEffect]) {
        guard var stage = snapshot.stage, let suspension = stage.suspension,
              suspension.reason == reason else { return }
        if let remaining = suspension.remainingSeconds, let duration = snapshot.configuration.duration(for: stage.phase) {
            stage.startedAt = date.addingTimeInterval(remaining - duration)
            stage.deadline = date.addingTimeInterval(remaining)
        } else {
            stage.id = UUID()
            effects.append(.remind(stage.id))
        }
        stage.suspension = nil
        snapshot.stage = stage
    }
}
