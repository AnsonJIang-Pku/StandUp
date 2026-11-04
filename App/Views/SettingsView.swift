import SwiftUI
import StandUpCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var section: Section = .timer
    @State private var timerDraft: TimerDraft
    @State private var draftPresetID: String?
    @State private var scheduleDraft: ScheduleConfiguration
    @State private var presetEditor: PresetEditor?
    @State private var pendingDeletion: String?
    @State private var message: String?
    @State private var isError = false

    private enum Section: String, CaseIterable {
        case timer = "计时"
        case presets = "预设"
        case schedule = "日程"
        case general = "通用"
    }

    private struct PresetEditor {
        var id: String?
        var name: String
        var timer: TimerDraft
    }

    init(model: AppModel) {
        self.model = model
        _timerDraft = State(initialValue: TimerDraft(model.settings.timer))
        _draftPresetID = State(initialValue: model.settings.activePreset?.id)
        _scheduleDraft = State(initialValue: model.settings.schedule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("设置分类", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: section) { _ in message = nil }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch section {
                    case .timer: timerSection
                    case .presets: presetsSection
                    case .schedule: ScheduleSettingsForm(draft: $scheduleDraft)
                    case .general: generalSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(height: contentHeight)
            .id(section)

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer

            Text("开发者 · @HoshinoJiang")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var contentHeight: CGFloat {
        switch section {
        case .timer, .schedule: return 325
        case .presets: return 355
        case .general: return 190
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch section {
        case .timer:
            HStack {
                Button("恢复默认") {
                    timerDraft = TimerDraft(.defaults)
                    draftPresetID = TimerPreset.defaultID
                    message = nil
                }
                Button("存为预设") { openPresetEditor() }
                Spacer()
                Button("保存计时", action: saveTimer)
                    .buttonStyle(.borderedProminent)
            }
        case .schedule:
            HStack {
                Button("恢复默认") {
                    scheduleDraft = .defaults
                    message = nil
                }
                Spacer()
                Button("保存日程", action: saveSchedule)
                    .buttonStyle(.borderedProminent)
            }
        case .presets, .general:
            EmptyView()
        }
    }

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前生效的全局配置")
                .font(.headline)
            Text("\(model.settings.activePreset?.name ?? "自定义") · \(summary(model.settings.timer))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()
            Text("正在编辑 · \(draftPresetName)")
                .font(.headline)
            TimerConfigurationForm(draft: $timerDraft)
            Text("每轮工作开始时重置延迟次数。本轮的工作、活动和延迟沿用原配置。保存后下一轮生效，重新开始可立即应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var draftPresetName: String {
        guard let preset = model.settings.presets.first(where: { $0.id == draftPresetID }),
              case .success(let config) = timerDraft.validation, preset.configuration == config else {
            return "自定义"
        }
        return preset.name
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let editor = Binding($presetEditor) {
                Text(editor.wrappedValue.id == nil ? "新建预设" : "编辑预设")
                    .font(.headline)
                TextField("预设名称", text: editor.name)
                    .textFieldStyle(.roundedBorder)
                TimerConfigurationForm(draft: editor.timer)
                HStack {
                    Button("取消") {
                        presetEditor = nil
                        message = nil
                    }
                    Spacer()
                    Button("保存预设") { savePreset(editor.wrappedValue) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text("选择「填入」后，可以在计时页调整并保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.settings.presets) { preset in
                    presetRow(preset)
                    Divider()
                }
                Button("新建自定义预设") { openPresetEditor() }
            }
        }
    }

    private func presetRow(_ preset: TimerPreset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.headline)
                    Text(summary(preset.configuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("填入") {
                    timerDraft = TimerDraft(preset.configuration)
                    draftPresetID = preset.id
                    section = .timer
                }
            }
            if !preset.isBuiltIn {
                HStack {
                    if pendingDeletion == preset.id {
                        Text("删除此预设？").font(.caption)
                        Spacer()
                        Button("取消") { pendingDeletion = nil }
                        Button("确认删除", role: .destructive) { deletePreset(preset) }
                    } else {
                        Button("编辑") {
                            presetEditor = PresetEditor(id: preset.id, name: preset.name,
                                                       timer: TimerDraft(preset.configuration))
                            message = nil
                        }
                        Button("删除", role: .destructive) {
                            pendingDeletion = preset.id
                            message = nil
                        }
                    }
                }
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("提醒声音")
                Spacer()
                Text("Soft（轻柔）").foregroundStyle(.secondary)
            }
            if model.notificationStatus == .notDetermined {
                Button("启用系统通知", action: model.requestNotifications)
            }
            Divider()
            Toggle("登录时自动启动", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if let detail = model.loginMessage {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.loginNeedsApproval {
                Button("打开登录项设置", action: model.openLoginSettings)
            }
            Toggle("记录每日统计", isOn: Binding(
                get: { model.statisticsEnabled },
                set: { model.setStatisticsEnabled($0) }
            ))
        }
    }

    private func summary(_ configuration: TimerConfiguration) -> String {
        "工作 \(configuration.workMinutes) / 活动 \(configuration.activityMinutes) / 延迟 \(configuration.snoozeMinutes) 分钟"
    }

    private func openPresetEditor() {
        presetEditor = PresetEditor(name: "", timer: timerDraft)
        pendingDeletion = nil
        message = nil
        section = .presets
    }

    private func validated(_ draft: TimerDraft) -> TimerConfiguration? {
        switch draft.validation {
        case .success(let configuration): return configuration
        case .failure(let error):
            show(error.localizedDescription, error: true)
            return nil
        }
    }

    private func saveTimer() {
        guard let configuration = validated(timerDraft) else { return }
        var settings = model.settings
        settings.applyTimer(configuration, presetID: draftPresetID)
        if save(settings, success: "计时配置已保存。") {
            timerDraft = TimerDraft(configuration)
            draftPresetID = settings.activePreset?.id
        }
    }

    private func savePreset(_ editor: PresetEditor) {
        guard let configuration = validated(editor.timer) else { return }
        var settings = model.settings
        let accepted: Bool
        if let id = editor.id {
            accepted = settings.editPreset(id: id, name: editor.name, configuration: configuration)
        } else {
            accepted = settings.createPreset(name: editor.name, configuration: configuration) != nil
        }
        guard accepted else {
            show("请输入 1–40 个字符的预设名称。", error: true)
            return
        }
        if save(settings, success: "预设已保存。") { presetEditor = nil }
    }

    private func deletePreset(_ preset: TimerPreset) {
        var settings = model.settings
        guard settings.deletePreset(id: preset.id) else { return }
        if save(settings, success: "预设已删除。") {
            pendingDeletion = nil
            if draftPresetID == preset.id { draftPresetID = nil }
        }
    }

    private func saveSchedule() {
        var settings = model.settings
        guard settings.applySchedule(scheduleDraft) else {
            if let day = Weekday.allCases.first(where: { !scheduleDraft[$0].isValid }) {
                let hint = scheduleDraft[day].startMinute == scheduleDraft[day].endMinute
                    ? "开始和结束时间相同。若要覆盖全天，请选择「全天提醒」。"
                    : "结束时间早于开始时间。若要延续到次日，请开启「允许跨午夜」。"
                show("\(day.title)\(hint)", error: true)
            }
            return
        }
        _ = save(settings, success: "日程已保存并生效。")
    }

    @discardableResult
    private func save(_ settings: AppSettings, success: String) -> Bool {
        guard model.saveSettings(settings) else {
            show("保存失败，请检查本地数据存储后重试。", error: true)
            return false
        }
        show(success, error: false)
        return true
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
