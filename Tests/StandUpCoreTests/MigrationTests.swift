import Foundation
import XCTest
@testable import StandUpCore

final class MigrationTests: XCTestCase {
    private func withStore(_ test: (PersistenceService) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try test(PersistenceService(url: dir.appendingPathComponent("state.json")))
    }

    func testV1PreservesSnapshotStatisticsAndExactBackup() throws {
        try withStore { store in
            let id = UUID()
            let started = instant("2026-11-02T10:00:00+08:00")
            let end = instant("2026-11-02T22:00:00+08:00")
            let deadline = started.addingTimeInterval(1800)
            let bytes = Data("""
            {"timer":{"sessionStartedAt":\(started.timeIntervalSinceReferenceDate),
                      "sessionEndsAt":\(end.timeIntervalSinceReferenceDate),
                      "stage":{"id":"\(id)","phase":"working","startedAt":\(started.timeIntervalSinceReferenceDate),
                               "deadline":\(deadline.timeIntervalSinceReferenceDate)}},
             "settings":{"statisticsEnabled":false},
             "statistics":{"days":{"2026-11-02":{"totals":{"completedActivities":1,"activitySeconds":180,
                                      "skips":2,"snoozes":3,"completedWork":4},"eventIDs":["\(id)"]}}}}
            """.utf8)
            try bytes.write(to: store.url)
            let result = try store.load()
            XCTAssertEqual(result.schemaVersion, 2)
            XCTAssertEqual(result.timer.stage?.id, id)
            XCTAssertEqual(result.timer.stage?.deadline, deadline)
            XCTAssertEqual(result.timer.configuration, .defaults)
            XCTAssertEqual(result.settings.timer, .defaults)
            XCTAssertEqual(result.settings.schedule, .defaults)
            XCTAssertFalse(result.settings.statisticsEnabled)
            XCTAssertEqual(result.statistics.totals(at: started, schedule: testSchedule).completedWork, 4)
            XCTAssertEqual(result.statistics.totals(at: started, schedule: testSchedule).activitySeconds, 180)
            XCTAssertEqual(try store.load(), result)
            XCTAssertEqual(try Data(contentsOf: store.url.deletingLastPathComponent()
                .appendingPathComponent("state.v1.backup.json")), bytes)
        }
    }

    func testDamagedFieldsPreserveValidStatisticsAndOriginalBeforeReplacement() throws {
        try withStore { store in
            let bytes = Data("""
            {"schemaVersion":2,"timer":"bad","settings":{"statisticsEnabled":false},
             "statistics":{"days":{"2026-11-02":{"totals":{"completedActivities":0,"activitySeconds":0,
                                           "skips":0,"snoozes":0,"completedWork":7},"eventIDs":[]}}}}
            """.utf8)
            try bytes.write(to: store.url)
            let data = try store.load()
            XCTAssertNil(data.timer.stage)
            XCTAssertFalse(data.settings.statisticsEnabled)
            XCTAssertEqual(data.settings.timer, .defaults)
            XCTAssertEqual(data.statistics.totals(at: instant("2026-11-02T10:00:00+08:00"),
                                                 schedule: testSchedule).completedWork, 7)
            try store.save(data)
            XCTAssertEqual(try Data(contentsOf: store.url.deletingLastPathComponent()
                .appendingPathComponent("state.recovery.backup.json")), bytes)
        }
    }

    func testFutureVersionCannotBeOverwritten() throws {
        try withStore { store in
            let bytes = Data(#"{"schemaVersion":9000}"#.utf8)
            try bytes.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(LocalData()))
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }
}

extension MigrationTests {
    func testMissingFieldsInCurrentSettingsUseDefaults() throws {
        try withStore { store in
            try Data(#"{"schemaVersion":2,"settings":{"timer":{"workMinutes":73},"schedule":{"enabled":false}}}"#.utf8)
                .write(to: store.url)
            let data = try store.load()
            XCTAssertEqual(data.settings.timer, .init(workMinutes: 73, activityMinutes: 3, snoozeMinutes: 5))
            XCTAssertFalse(data.settings.schedule.enabled)
            XCTAssertEqual(data.settings.schedule[.monday], DaySchedule())
            XCTAssertFalse(data.settings.schedule[.saturday].enabled)
        }
    }
}
