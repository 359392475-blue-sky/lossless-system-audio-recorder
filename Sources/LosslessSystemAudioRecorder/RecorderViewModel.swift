import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class RecorderViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case countingDown(Int)
        case recording
        case exporting
        case finished(URL, RecordingSummary)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    private let recorder = SystemAudioCaptureService()
    private var actionTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var pendingTemporaryURL: URL?
    private var pendingSummary: RecordingSummary?

    private var terminating = false

    var isBusy: Bool {
        switch phase {
        case .preparing, .countingDown, .recording, .exporting:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    var canCancelCountdown: Bool {
        if case .countingDown = phase { return true }
        return false
    }

    func start() {
        guard !isBusy, !terminating else { return }
        actionTask?.cancel()
        cleanupPendingTemporaryFile()
        elapsedSeconds = 0
        phase = .preparing

        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.prepare()
                for value in stride(from: 3, through: 1, by: -1) {
                    try Task.checkCancellation()
                    phase = .countingDown(value)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
                try await recorder.start()
                try Task.checkCancellation()
                recordingStartedAt = Date()
                phase = .recording
                beginClock()
            } catch is CancellationError {
                do { try await recorder.cancel(); phase = .idle }
                catch { phase = .failed(error.localizedDescription) }
            } catch {
                let original = error
                do { try await recorder.cancel(); phase = .failed(original.localizedDescription) }
                catch { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelCountdown() {
        actionTask?.cancel()
    }

    func stop() {
        guard case .recording = phase else { return }
        phase = .exporting
        clockTask?.cancel()
        clockTask = nil

        finishRecording()
    }

    func shutdownForTermination() async throws {
        terminating = true
        let task = actionTask
        task?.cancel()
        clockTask?.cancel()
        clockTask = nil
        try await recorder.cancel()
        await task?.value
        try await recorder.cancel()
        actionTask = nil
    }

    private func finishRecording() {
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (temporaryURL, summary) = try await recorder.stop()
                pendingTemporaryURL = temporaryURL
                pendingSummary = summary
                // A completed recording stays recoverable when closing while
                // the MP4 is being finalized; never open a save panel on exit.
                guard !Task.isCancelled, !terminating else { return }
                exportPendingRecording()
            } catch is CancellationError {
                do { try await recorder.cancel() }
                catch { phase = .failed(error.localizedDescription) }
            } catch {
                let original = error
                do { try await recorder.cancel(); phase = .failed(original.localizedDescription) }
                catch { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func exportAgain() {
        guard pendingTemporaryURL != nil else { return }
        exportPendingRecording()
    }

    func recordAgain() {
        guard !isBusy else { return }

        if pendingTemporaryURL != nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "这段录音还没有导出"
            alert.informativeText = "再次录制会删除当前临时录音。请先点“再次导出”保存，或者确认放弃后继续。"
            alert.addButton(withTitle: "放弃并再次录制")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        reset()
        start()
    }

    func reset() {
        actionTask?.cancel()
        clockTask?.cancel()
        cleanupPendingTemporaryFile()
        elapsedSeconds = 0
        recordingStartedAt = nil
        phase = .idle
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func restartApplication() {
        let applicationURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            NSApplication.shared.terminate(nil)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func beginClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let recordingStartedAt {
                    elapsedSeconds = Date().timeIntervalSince(recordingStartedAt)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func exportPendingRecording() {
        guard let temporaryURL = pendingTemporaryURL,
              let summary = pendingSummary else {
            phase = .failed("找不到刚刚完成的录音。")
            return
        }

        let panel = NSSavePanel()
        panel.title = "导出无损系统音频"
        panel.nameFieldLabel = "文件名："
        panel.nameFieldStringValue = RecordingFile.suggestedFilename()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            phase = .finished(temporaryURL, summary)
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
            try? FileManager.default.removeItem(at: temporaryURL)
            pendingTemporaryURL = nil
            pendingSummary = nil
            phase = .finished(destinationURL, summary)
        } catch {
            phase = .failed("导出失败：\(error.localizedDescription)")
        }
    }

    private func cleanupPendingTemporaryFile() {
        if let pendingTemporaryURL,
           pendingTemporaryURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: pendingTemporaryURL)
        }
        pendingTemporaryURL = nil
        pendingSummary = nil
    }
}
