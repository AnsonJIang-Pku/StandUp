import Foundation

public enum TimerState: String, Codable, Equatable {
    case idle, working, breakDue, snoozed, onBreak, paused, outsideSchedule
}

public enum TimerPhase: String, Codable, Equatable {
    case working, breakDue, snoozed, onBreak

    var state: TimerState {
        switch self {
        case .working: return .working
        case .breakDue: return .breakDue
        case .snoozed: return .snoozed
        case .onBreak: return .onBreak
        }
    }
}
