import Foundation

public enum TimerEvent: Equatable, Sendable {
    case startWork, restart, stop, refresh
    case startBreak(UUID), snooze(UUID), skip(UUID)
    case pause, resume, systemWillSleep, systemDidWake, applicationLaunched
}

public enum Statistic: Equatable {
    case work, activity(seconds: Int), skip, snooze
}

public enum TimerEffect: Equatable {
    case remind(UUID)
    case clearReminder
    case record(Statistic, UUID, Date)
}
