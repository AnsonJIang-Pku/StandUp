import Foundation

public struct LocalData: Codable, Equatable {
    public static let currentSchemaVersion = 2

    public private(set) var schemaVersion = currentSchemaVersion
    public var timer = TimerSnapshot()
    public var settings = AppSettings()
    public var statistics = StatisticsService()

    public init() {}
}

public struct PersistenceService {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: PersistenceService {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PersistenceService(url: support.appendingPathComponent("StandUp", isDirectory: true)
            .appendingPathComponent("state.json"))
    }

    public func load() throws -> LocalData {
        guard let bytes = try existingBytes() else { return LocalData() }
        let envelope = try decode(bytes)
        if envelope.version == 1 {
            try preserve(bytes, label: "v1")
            try write(envelope.data)
        }
        return envelope.data
    }

    public func save(_ data: LocalData) throws {
        if let bytes = try existingBytes() {
            let existing = try decode(bytes)
            if existing.version == 1 {
                try preserve(bytes, label: "v1")
            } else if existing.recovered {
                try preserve(bytes, label: "recovery")
            }
        }
        try write(data)
    }

    private func existingBytes() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    // Each root field is decoded independently so a damaged session or settings cannot discard statistics.
    private struct Fields: Decodable {
        let schemaVersion: Int?
        let timer: TimerSnapshot?
        let settings: AppSettings?
        let statistics: StatisticsService?
        let recovered: Bool

        private enum CodingKeys: String, CodingKey { case schemaVersion, timer, settings, statistics }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            timer = (try? values.decode(TimerSnapshot.self, forKey: .timer)).flatMap { $0.isValid ? $0 : nil }
            settings = (try? values.decode(AppSettings.self, forKey: .settings)).flatMap { $0.isValid ? $0 : nil }
            statistics = try? values.decode(StatisticsService.self, forKey: .statistics)
            recovered = (values.contains(.timer) && timer == nil)
                || (values.contains(.settings) && settings == nil)
                || (values.contains(.statistics) && statistics == nil)
        }
    }

    private func decode(_ bytes: Data) throws -> (data: LocalData, version: Int?, recovered: Bool) {
        guard let fields = try? JSONDecoder().decode(Fields.self, from: bytes) else {
            // A readable JSON object with an unrecognized version must not be overwritten.
            if let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
               object["schemaVersion"] != nil {
                throw CocoaError(.fileReadUnknown)
            }
            return (LocalData(), nil, true)
        }

        let version = fields.schemaVersion ?? 1
        guard version == 1 || version == LocalData.currentSchemaVersion else {
            throw CocoaError(.fileReadUnknown)
        }
        var data = LocalData()
        if let timer = fields.timer { data.timer = timer }
        if let settings = fields.settings { data.settings = settings }
        if let statistics = fields.statistics { data.statistics = statistics }
        return (data, version, fields.recovered)
    }

    private func preserve(_ bytes: Data, label: String) throws {
        let directory = url.deletingLastPathComponent()
        let backup = directory.appendingPathComponent("state.\(label).backup.json")
        if let previous = try? Data(contentsOf: backup) {
            if previous == bytes { return }
            let uniqueBackup = directory.appendingPathComponent("state.\(label).\(UUID().uuidString).backup.json")
            try bytes.write(to: uniqueBackup, options: .atomic)
        } else {
            try bytes.write(to: backup, options: .atomic)
        }
    }

    private func write(_ data: LocalData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(data).write(to: url, options: .atomic)
    }
}
