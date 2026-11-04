import Foundation
import XCTest
@testable import StandUpCore

final class ConfigurationTests: XCTestCase {
    func testDurationAcceptsArbitraryMinutesOrHoursAndMinutes() {
        for (input, expected) in [("1", 1), ("47", 47), (" 79 ", 79),
                                  ("1:23", 83), ("0:09", 9), ("24:00", 1440)] {
            XCTAssertEqual(TimerConfiguration.parseDuration(input), expected)
        }
    }

    func testInvalidInputAndOverflowAreRejected() {
        for input in ["", " ", "-2", "+2", "0", "0:00", "2.5", "2m", "1:9", "1:60",
                      ":45", "4:", "24:01", "1441", "999999999999999999999999:12"] {
            XCTAssertNil(TimerConfiguration.parseDuration(input), input)
        }
        for input in ["", "-1", "1.5", "10000", "9999999999999999999999999"] {
            XCTAssertNil(TimerConfiguration.parseSnoozeCount(input), input)
        }
        XCTAssertEqual(TimerConfiguration.parseSnoozeCount("0"), 0)
        XCTAssertEqual(TimerConfiguration.parseSnoozeCount(" 99 "), 99)
    }

    func testSavingValidatedConfigurationAndRestoringDefaults() throws {
        var data = LocalData()
        let custom = TimerConfiguration(workMinutes: 93, activityMinutes: 19, snoozeMinutes: 17,
                                        maxSnoozeCount: 2, autoStartNextWork: false)
        XCTAssertTrue(data.settings.applyTimer(custom))
        XCTAssertNil(data.settings.activePreset)
        XCTAssertFalse(data.settings.applyTimer(.init(workMinutes: 0, activityMinutes: 3, snoozeMinutes: 5)))
        XCTAssertEqual(data.settings.timer, custom)
        let decoded = try JSONDecoder().decode(LocalData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded.settings.timer, custom)
        data.settings.restoreTimerDefaults()
        XCTAssertEqual(data.settings.timer, .defaults)
        XCTAssertEqual(data.settings.activePreset?.id, TimerPreset.defaultID)
    }

    func testBuiltInsAndEditingAppliedConfiguration() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.presets.map(\.name), ["高频活动", "均衡", "轻松", "番茄工作法"])
        XCTAssertEqual(settings.presets.map { $0.configuration.workMinutes }, [20, 30, 45, 25])
        let preset = try XCTUnwrap(settings.presets.first { $0.id == "pomodoro" })
        XCTAssertTrue(settings.applyTimer(preset.configuration, presetID: preset.id))
        XCTAssertEqual(settings.activePreset, preset)
        var edited = preset.configuration
        edited.autoStartNextWork = false
        settings.applyTimer(edited, presetID: preset.id)
        XCTAssertNil(settings.activePreset)
        XCTAssertFalse(settings.deletePreset(id: preset.id))
        XCTAssertFalse(settings.editPreset(id: preset.id, name: "更名", configuration: edited))
    }

    func testCustomPresetLifecycleAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceService(url: directory.appendingPathComponent("state.json"))
        var data = LocalData()
        let original = TimerConfiguration(workMinutes: 47, activityMinutes: 8, snoozeMinutes: 9)
        XCTAssertNil(data.settings.createPreset(name: "  ", configuration: original))
        XCTAssertNil(data.settings.createPreset(name: "多\n行", configuration: original))
        let created = try XCTUnwrap(data.settings.createPreset(name: "  深度工作  ", configuration: original))
        XCTAssertEqual(created.name, "深度工作")
        data.settings.applyTimer(created.configuration, presetID: created.id)
        try store.save(data)
        data = try store.load()
        XCTAssertEqual(data.settings.activePreset, created)

        var changed = original
        changed.snoozeMinutes = 16
        XCTAssertTrue(data.settings.editPreset(id: created.id, name: "长周期", configuration: changed))
        XCTAssertEqual(data.settings.customPresets.first?.name, "长周期")
        XCTAssertEqual(data.settings.timer, original)
        XCTAssertNil(data.settings.activePreset)
        data.settings.applyTimer(changed, presetID: created.id)
        XCTAssertEqual(data.settings.activePreset?.id, created.id)
        XCTAssertTrue(data.settings.deletePreset(id: created.id))
        XCTAssertEqual(data.settings.timer, changed)
        XCTAssertNil(data.settings.activePreset)
        try store.save(data)
        XCTAssertTrue(try store.load().settings.customPresets.isEmpty)
    }
}
