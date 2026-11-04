import StandUpCore
import SwiftUI

struct TimerDraft: Equatable {
    var work: String
    var activity: String
    var snooze: String
    var unlimitedSnoozes: Bool
    var snoozeCount: String
    var autoStart: Bool

    init(_ configuration: TimerConfiguration) {
        work = String(configuration.workMinutes)
        activity = String(configuration.activityMinutes)
        snooze = String(configuration.snoozeMinutes)
        unlimitedSnoozes = configuration.maxSnoozeCount == nil
        snoozeCount = String(configuration.maxSnoozeCount ?? 1)
        autoStart = configuration.autoStartNextWork
    }

    var validation: Result<TimerConfiguration, ValidationError> {
        guard let work = TimerConfiguration.parseDuration(work) else { return .failure(.duration("工作时长")) }
        guard let activity = TimerConfiguration.parseDuration(activity) else { return .failure(.duration("活动时长")) }
        guard let snooze = TimerConfiguration.parseDuration(snooze) else { return .failure(.duration("延迟时间")) }
        let count = unlimitedSnoozes ? nil : TimerConfiguration.parseSnoozeCount(snoozeCount)
        if !unlimitedSnoozes && count == nil { return .failure(.count) }
        return .success(TimerConfiguration(workMinutes: work, activityMinutes: activity, snoozeMinutes: snooze,
                                           maxSnoozeCount: count, autoStartNextWork: autoStart))
    }

    enum ValidationError: LocalizedError {
        case duration(String), count

        var errorDescription: String? {
            switch self {
            case .duration(let field): return "\(field)须为 1–1440 分钟，可输入整数或 H:MM。"
            case .count: return "最大延迟次数须为 0–9999 的整数。"
            }
        }
    }
}

struct TimerConfigurationForm: View {
    @Binding var draft: TimerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            field("工作时长", text: $draft.work)
            field("活动时长", text: $draft.activity)
            field("延迟时间", text: $draft.snooze)
            Text("输入分钟数，或用 H:MM 输入小时和分钟。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("延迟次数不限", isOn: $draft.unlimitedSnoozes)
            if !draft.unlimitedSnoozes {
                field("最大延迟次数", text: $draft.snoozeCount, placeholder: "0–9999")
            }
            Toggle("活动结束后自动开始下一轮", isOn: $draft.autoStart)
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String = "分钟") -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 92)
        }
    }
}
