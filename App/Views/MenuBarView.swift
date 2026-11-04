import SwiftUI
import StandUpCore

extension TimerState {
    var title: String {
        switch self {
        case .idle: return "尚未开始"
        case .working: return "工作中"
        case .breakDue: return "起身活动"
        case .snoozed: return "稍后提醒"
        case .onBreak: return "活动中"
        case .paused: return "已暂停"
        case .outsideSchedule: return "提醒时段外"
        }
    }

    var icon: String {
        switch self {
        case .idle, .outsideSchedule: return "figure.walk"
        case .working: return "timer"
        case .breakDue: return "figure.stand"
        case .snoozed: return "clock.arrow.circlepath"
        case .onBreak: return "figure.run"
        case .paused: return "pause.circle"
        }
    }
}

func countdownText(_ seconds: TimeInterval) -> String {
    let total = Int(ceil(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.state.icon)
            Text(text).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("StandUp，\(model.state.title)，\(text)")
    }

    private var text: String {
        switch model.state {
        case .working, .onBreak, .snoozed: return model.remaining.map(countdownText) ?? ""
        case .paused, .breakDue: return model.state.title
        case .idle, .outsideSchedule: return "StandUp"
        }
    }
}
