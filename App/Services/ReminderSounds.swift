import AppKit
import AVFoundation
import UserNotifications
import StandUpCore

@MainActor
enum ReminderSounds {
    static let preferenceKey = "reminderSound"
    static let soft = "soft"
    static let silent = "silent"
    static let systemDefault = "system-default"
    static let imported = "imported"
    static let maximumDuration: TimeInterval = 15

    static let builtIn: [(id: String, title: String, filename: String)] = [
        (soft, "轻柔 Soft", NotificationService.soundName),
        ("tap", "木敲 Tap", "StandUpTap.wav"),
        ("chime", "清铃 Chime", "StandUpChime.wav")
    ]

    static func systemFiles() -> [URL] {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["aiff", "wav", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func systemSelection(_ source: URL) -> String {
        "system:" + source.deletingPathExtension().lastPathComponent
    }

    static func title(_ selection: String) -> String {
        if let item = builtIn.first(where: { $0.id == selection }) { return item.title }
        switch selection {
        case silent: return "无声"
        case systemDefault: return "跟随系统默认"
        case imported: return "自定义音频"
        default: return selection.hasPrefix("system:") ? String(selection.dropFirst("system:".count)) : "轻柔 Soft"
        }
    }

    static func fileURL(for selection: String) -> URL? {
        let candidate: URL?
        if let item = builtIn.first(where: { $0.id == selection }) {
            candidate = Bundle.main.url(forResource: item.filename, withExtension: nil)
        } else if selection == imported || selection.hasPrefix("system:") {
            candidate = storedURL(for: selection)
        } else {
            candidate = nil
        }
        if let candidate, FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        return Bundle.main.url(forResource: NotificationService.soundName, withExtension: nil)
    }

    static func notificationSound() -> UNNotificationSound? {
        let selection = UserDefaults.standard.string(forKey: preferenceKey) ?? soft
        if selection == silent { return nil }
        if selection == systemDefault { return .default }
        guard let file = fileURL(for: selection) else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(file.lastPathComponent))
    }

    static var hasImportedSound: Bool {
        FileManager.default.isReadableFile(atPath: storedURL(for: imported).path)
    }

    private static func storedURL(for selection: String) -> URL {
        let kind = selection == imported ? "imported" : "system"
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Sounds", isDirectory: true)
            .appendingPathComponent("com.standup.reminder.\(kind).caf")
    }

    static func install(_ file: URL, selection: String) throws {
        let destination = storedURL(for: selection)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: file).write(to: destination, options: .atomic)
    }

    static func duration(of source: URL) throws -> TimeInterval {
        let audio = try AVAudioFile(forReading: source)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw SoundError.invalidRange }
        return duration
    }

    static func writeClip(from source: URL, to destination: URL, start: TimeInterval, duration: TimeInterval) throws {
        let audio = try AVAudioFile(forReading: source)
        let format = audio.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 192_000,
              (1...2).contains(format.channelCount) else { throw SoundError.unsupportedFormat }
        let total = Double(audio.length) / sampleRate
        guard start.isFinite, duration.isFinite, start >= 0, start < total, duration > 0,
              duration <= maximumDuration, start + duration <= total + 0.000_001 else {
            throw SoundError.invalidRange
        }
        let first = AVAudioFramePosition((start * sampleRate).rounded(.down))
        audio.framePosition = first
        var frames = min(audio.length - first, AVAudioFramePosition((duration * sampleRate).rounded(.down)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw SoundError.invalidRange
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        while frames > 0 {
            try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(frames, 4096)))
            guard buffer.frameLength > 0 else { throw SoundError.invalidRange }
            try output.write(from: buffer)
            frames -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    enum SoundError: LocalizedError {
        case invalidRange, unsupportedFormat, playbackFailed

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "请选择音频内一段大于 0 且不超过 15 秒的片段。"
            case .unsupportedFormat: return "请选择单声道或双声道、采样率不超过 192 kHz 的音频。"
            case .playbackFailed: return "无法试听这段音频。"
            }
        }
    }
}
