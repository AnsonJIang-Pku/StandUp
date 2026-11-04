import SwiftUI
import StandUpCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(showingSettings ? "设置" : "StandUp")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    showingSettings.toggle()
                    if showingSettings { model.refreshSystemSettings() }
                } label: {
                    Label(showingSettings ? "返回" : "设置",
                          systemImage: showingSettings ? "chevron.left" : "gearshape")
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(showingSettings ? "返回" : "设置")
            }

            if showingSettings {
                SettingsView(model: model)
            } else {
                timerPanel
                actions
                if model.statisticsEnabled {
                    Divider()
                    StatisticsView(stats: model.today)
                }
            }

            if model.notificationStatus == .denied {
                HStack {
                    Label("系统通知已关闭", systemImage: "bell.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开通知设置", action: model.openNotificationSettings)
                        .buttonStyle(.borderless)
                }
            } else if model.notificationStatus == .notDetermined && !showingSettings {
                HStack {
                    Label("允许在工作结束时提醒", systemImage: "bell")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("启用系统通知", action: model.requestNotifications)
                        .buttonStyle(.borderless)
                }
            }

            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Text(model.scheduleSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出 StandUp") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 332)
        .onAppear(perform: model.refreshSystemSettings)
    }

    private var timerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.state.title, systemImage: model.state.icon)
                .font(.headline)
            Text(model.remaining.map(countdownText) ?? "—:—")
                .font(.system(size: 44, weight: .medium, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("剩余时间")
                .accessibilityValue(model.remaining.map(countdownText) ?? "无倒计时")
            ProgressView(value: model.progress)
                .accessibilityLabel("当前阶段进度")
            Text("工作 \(model.activeConfiguration.workMinutes) 分钟 · 活动 \(model.activeConfiguration.activityMinutes) 分钟")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.state {
        case .idle:
            Button("开始工作") { model.send(.startWork) }
                .buttonStyle(.borderedProminent)
        case .outsideSchedule:
            Text("请在允许提醒的时段开始，或前往设置调整日程。")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .breakDue:
            if let id = model.stageID {
                HStack {
                    Button("开始活动") { model.send(.startBreak(id)) }
                        .buttonStyle(.borderedProminent)
                    if model.canSnooze {
                        Button("稍后提醒") { model.send(.snooze(id)) }
                    }
                    Button("跳过本次") { model.send(.skip(id)) }
                }
                if !model.canSnooze {
                    Text("本轮已无可用的延迟次数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            sessionControls
        case .working, .onBreak, .paused, .snoozed:
            sessionControls
        }
    }

    private var sessionControls: some View {
        HStack {
            Button(model.state == .paused ? "恢复" : "暂停") {
                model.send(model.state == .paused ? .resume : .pause)
            }
            Button("重新开始") { model.send(.restart) }
            Spacer()
            Button("停止") { model.send(.stop) }
        }
    }
}
