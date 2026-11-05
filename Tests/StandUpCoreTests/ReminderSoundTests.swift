import AVFoundation
import XCTest
@testable import StandUpAppTestSupport

final class ReminderSoundTests: XCTestCase {
    @MainActor
    func testBundledSoundsAndClipConversion() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources")
        let expectedDurations = [0.72, 1.8, 3.6]
        XCTAssertEqual(ReminderSounds.builtIn.count, expectedDurations.count)
        for (item, duration) in zip(ReminderSounds.builtIn, expectedDurations) {
            XCTAssertEqual(try ReminderSounds.duration(of: resources.appendingPathComponent(item.filename)),
                           duration, accuracy: 0.002)
        }

        let source = resources.appendingPathComponent("StandUpChime.wav")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: output) }
        try ReminderSounds.writeClip(from: source, to: output, start: 0.9, duration: 2)
        XCTAssertEqual(try ReminderSounds.duration(of: output), 2, accuracy: 0.002)
        var audioFile: AudioFileID?
        XCTAssertEqual(AudioFileOpenURL(output as CFURL, .readPermission, 0, &audioFile), noErr)
        let opened = try XCTUnwrap(audioFile)
        defer { AudioFileClose(opened) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        XCTAssertEqual(AudioFileGetProperty(opened, kAudioFilePropertyDataFormat, &size, &format), noErr)
        XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(format.mBitsPerChannel, 16)
        XCTAssertThrowsError(try ReminderSounds.writeClip(from: source, to: output, start: 3, duration: 2))
        XCTAssertThrowsError(try ReminderSounds.writeClip(from: source, to: output, start: 0, duration: 16))
        XCTAssertEqual(try ReminderSounds.duration(of: output), 2, accuracy: 0.002)
    }
}
