import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReminderSoundSettings: View {
    @AppStorage(ReminderSounds.preferenceKey) private var selection = ReminderSounds.soft
    @State private var preview: NSSound?

    var body: some View {
        HStack {
            Text("提醒声音")
            Spacer()
            Menu(ReminderSounds.title(selection)) {
                Section("内置") {
                    ForEach(ReminderSounds.builtIn.map(\.id), id: \.self) { id in
                        option(id)
                    }
                }
                Section("系统") {
                    option(ReminderSounds.systemDefault)
                    Menu("选择系统音效") {
                        ForEach(ReminderSounds.systemFiles(), id: \.self) { file in
                            Button(file.deletingPathExtension().lastPathComponent) {
                                changeSound {
                                    let id = ReminderSounds.systemSelection(file)
                                    try SoundClipEditor.withClip(from: file, start: 0,
                                                                 duration: ReminderSounds.duration(of: file)) {
                                        try ReminderSounds.install($0, selection: id)
                                    }
                                    selection = id
                                }
                            }
                        }
                    }
                }
                Section("自定义") {
                    if ReminderSounds.hasImportedSound { option(ReminderSounds.imported) }
                    Button("导入音频…", action: importSound)
                    option(ReminderSounds.silent)
                }
            }
            .fixedSize()
            .accessibilityLabel("选择提醒声音")
            Button("试听", action: playPreview)
                .disabled(selection == ReminderSounds.silent)
                .help(selection == ReminderSounds.systemDefault ? "试听 macOS 系统提示声" : "试听所选声音")
        }
        .onDisappear { preview?.stop() }
    }

    private func option(_ id: String) -> some View {
        Button {
            preview?.stop()
            selection = id
        } label: {
            if selection == id {
                Label(ReminderSounds.title(id), systemImage: "checkmark")
            } else {
                Text(ReminderSounds.title(id))
            }
        }
    }

    private func playPreview() {
        changeSound {
            if selection == ReminderSounds.systemDefault {
                NSSound.beep()
            } else if let file = ReminderSounds.fileURL(for: selection) {
                preview = try SoundClipEditor.play(file)
            } else {
                NSSound.beep()
            }
        }
    }

    private func importSound() {
        changeSound {
            let panel = NSOpenPanel()
            panel.title = "导入提醒声音"
            panel.allowedContentTypes = [.audio]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let source = panel.url else { return }
            let editor = try SoundClipEditor(source: source)
            if try editor.run() { selection = ReminderSounds.imported }
        }
    }

    private func changeSound(_ action: () throws -> Void) {
        preview?.stop()
        do { try action() } catch { SoundClipEditor.show(error) }
    }
}

@MainActor
private final class SoundClipEditor: NSObject {
    private let source: URL
    private let totalDuration: TimeInterval
    private let startField = NSTextField(string: "0")
    private let durationField: NSTextField
    private var preview: NSSound?

    init(source: URL) throws {
        self.source = source
        totalDuration = try ReminderSounds.duration(of: source)
        durationField = NSTextField(string: String(min(5, totalDuration)))
    }

    func run() throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "截取提醒音频"
        alert.informativeText = "\(source.lastPathComponent)\n总长 \(String(format: "%.2f", totalDuration)) 秒。片段最长 15 秒。"
        alert.addButton(withTitle: "用作提醒声")
        alert.addButton(withTitle: "取消")

        let previewButton = NSButton(title: "试听片段", target: self, action: #selector(playClip))
        let fields = NSGridView(views: [
            [NSTextField(labelWithString: "起点（秒）"), startField],
            [NSTextField(labelWithString: "时长（秒）"), durationField],
            [NSGridCell.emptyContentView, previewButton]
        ])
        startField.setAccessibilityLabel("起点（秒）")
        durationField.setAccessibilityLabel("时长（秒）")
        fields.frame.size = fields.fittingSize
        alert.accessoryView = fields
        alert.window.initialFirstResponder = startField

        while alert.runModal() == .alertFirstButtonReturn {
            preview?.stop()
            do {
                try withSelection { try ReminderSounds.install($0, selection: ReminderSounds.imported) }
                return true
            } catch {
                Self.show(error)
            }
        }
        preview?.stop()
        return false
    }

    @objc private func playClip() {
        preview?.stop()
        do { try withSelection { preview = try Self.play($0) } }
        catch { Self.show(error) }
    }

    private func withSelection(_ action: (URL) throws -> Void) throws {
        func number(_ field: NSTextField) -> Double? {
            Double(field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        guard let start = number(startField), let duration = number(durationField) else {
            throw ReminderSounds.SoundError.invalidRange
        }
        try Self.withClip(from: source, start: start, duration: duration, action)
    }

    static func withClip(from source: URL, start: TimeInterval, duration: TimeInterval,
                         _ action: (URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try ReminderSounds.writeClip(from: source, to: temporary, start: start, duration: duration)
        try action(temporary)
    }

    static func play(_ url: URL) throws -> NSSound {
        guard let sound = NSSound(contentsOf: url, byReference: false), sound.play() else {
            throw ReminderSounds.SoundError.playbackFailed
        }
        return sound
    }

    static func show(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
