import Foundation
public struct AppSettings: Codable, Equatable {
    public var statisticsEnabled = true
    public internal(set) var timer: TimerConfiguration = .defaults
    public internal(set) var schedule: ScheduleConfiguration = .defaults
    public internal(set) var customPresets: [TimerPreset] = []
    public internal(set) var selectedPresetID: String? = TimerPreset.defaultID

    public init() {}

    public var presets: [TimerPreset] { TimerPreset.builtIns + customPresets }

    public var activePreset: TimerPreset? {
        presets.first { $0.id == selectedPresetID && $0.configuration == timer }
    }

    private enum CodingKeys: String, CodingKey {
        case statisticsEnabled, timer, schedule, customPresets, selectedPresetID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        statisticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .statisticsEnabled) ?? true
        timer = try values.decodeIfPresent(TimerConfiguration.self, forKey: .timer) ?? .defaults
        schedule = try values.decodeIfPresent(ScheduleConfiguration.self, forKey: .schedule) ?? .defaults
        customPresets = try values.decodeIfPresent([TimerPreset].self, forKey: .customPresets) ?? []
        selectedPresetID = try values.decodeIfPresent(String.self, forKey: .selectedPresetID)
        if !values.contains(.timer) { selectedPresetID = TimerPreset.defaultID }
    }

    var isValid: Bool {
        timer.isValid && schedule.isValid
            && customPresets.allSatisfy(\.isValidCustomPreset)
            && Set(customPresets.map(\.id)).count == customPresets.count
    }
}

extension AppSettings {
    @discardableResult
    public mutating func applyTimer(_ configuration: TimerConfiguration, presetID: String? = nil) -> Bool {
        guard configuration.isValid else { return false }
        timer = configuration
        selectedPresetID = presets.first { $0.id == presetID && $0.configuration == configuration }?.id
        return true
    }

    public mutating func restoreTimerDefaults() {
        applyTimer(.defaults, presetID: TimerPreset.defaultID)
    }

    @discardableResult
    public mutating func applySchedule(_ configuration: ScheduleConfiguration) -> Bool {
        guard configuration.isValid else { return false }
        schedule = configuration
        return true
    }

    @discardableResult
    public mutating func createPreset(name: String, configuration: TimerConfiguration) -> TimerPreset? {
        guard let name = TimerPreset.validName(name), configuration.isValid else { return nil }
        let preset = TimerPreset(id: UUID().uuidString, name: name, configuration: configuration)
        customPresets.append(preset)
        return preset
    }

    @discardableResult
    public mutating func editPreset(id: String, name: String, configuration: TimerConfiguration) -> Bool {
        guard let index = customPresets.firstIndex(where: { $0.id == id }),
              let name = TimerPreset.validName(name), configuration.isValid else { return false }
        customPresets[index] = TimerPreset(id: id, name: name, configuration: configuration)
        if selectedPresetID == id && configuration != timer { selectedPresetID = nil }
        return true
    }

    @discardableResult
    public mutating func deletePreset(id: String) -> Bool {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return false }
        customPresets.remove(at: index)
        if selectedPresetID == id { selectedPresetID = nil }
        return true
    }
}
