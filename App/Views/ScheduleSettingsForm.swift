import StandUpCore
import SwiftUI

extension Weekday {
    var title: String {
        switch self {
        case .monday: return "周一"
        case .tuesday: return "周二"
        case .wednesday: return "周三"
        case .thursday: return "周四"
        case .friday: return "周五"
        case .saturday: return "周六"
        case .sunday: return "周日"
        }
    }
}

struct ScheduleSettingsForm: View {
    @Binding var draft: ScheduleConfiguration
    @State private var day = Weekday.monday

    private let utc = TimeZone(secondsFromGMT: 0)!

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("限制提醒时段", isOn: $draft.enabled)
            if draft.enabled {
                Picker("编辑日期", selection: $day) {
                    ForEach(Weekday.allCases) { Text($0.title).tag($0) }
                }
                Toggle("\(day.title)启用", isOn: field(\.enabled))
                if draft[day].enabled {
                    Toggle("全天提醒", isOn: field(\.allDay))
                    if !draft[day].allDay {
                        timePicker("开始时间", minute: \.startMinute)
                        timePicker(draft[day].allowsOvernight && draft[day].endMinute < draft[day].startMinute
                                   ? "结束时间（次日）" : "结束时间", minute: \.endMinute)
                        Toggle("允许跨午夜", isOn: field(\.allowsOvernight))
                    }
                }
                Divider()
                ForEach(Weekday.allCases) { weekday in
                    HStack {
                        Button(weekday.title) { day = weekday }
                            .buttonStyle(.borderless)
                        Spacer()
                        Text(summary(draft[weekday]))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            Text("日程保存后立即生效。跨午夜时段归属于开始日。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func field<Value>(_ keyPath: WritableKeyPath<DaySchedule, Value>) -> Binding<Value> {
        let weekday = day
        return Binding(
            get: { draft[weekday][keyPath: keyPath] },
            set: { draft[weekday][keyPath: keyPath] = $0 }
        )
    }

    private func timePicker(_ title: String, minute: WritableKeyPath<DaySchedule, Int>) -> some View {
        let value = field(minute)
        let selection = Binding(
            get: { Date(timeIntervalSinceReferenceDate: TimeInterval(value.wrappedValue * 60)) },
            set: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = utc
                let parts = calendar.dateComponents([.hour, .minute], from: $0)
                value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
        return HStack {
            Text(title)
            Spacer()
            DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.timeZone, utc)
                .environment(\.calendar, Calendar(identifier: .gregorian))
        }
    }

    private func summary(_ day: DaySchedule) -> String {
        if !day.enabled { return "关闭" }
        if day.allDay { return "全天" }
        if !day.isValid { return "请检查时间" }
        let overnight = day.endMinute < day.startMinute ? "次日 " : ""
        return "\(time(day.startMinute))–\(overnight)\(time(day.endMinute))"
    }

    private func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
