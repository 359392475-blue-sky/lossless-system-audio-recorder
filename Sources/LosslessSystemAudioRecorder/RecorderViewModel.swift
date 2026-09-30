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

    private let recorder: SystemAudioCaptureService
    private let policyService: any VersionPolicyChecking
    let referrals: ReferralCoordinator
    private var referralOperationID: String?
    private let countdownPause: () async throws -> Void
    @Published private(set) var policy: VersionPolicy?
    @Published private(set) var policyError: String?
    @Published private(set) var checkingPolicy = false
    private var policyChecks = 0

    init(recorder: SystemAudioCaptureService = SystemAudioCaptureService(),
         policyService: (any VersionPolicyChecking)? = nil,
         referrals: ReferralCoordinator? = nil,
         countdownPause: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) {
        self.referrals = referrals ?? ReferralCoordinator()
        self.recorder = recorder
        self.policyService = policyService ?? VersionPolicyService()
        self.countdownPause = countdownPause
    }

    func refreshPolicy() async {
        do { _ = try await verifyPolicy(requirePermission: false) }
        catch { /* The verification state is already displayed without disturbing active audio. */ }
    }

    @discardableResult
    private func verifyPolicy(requirePermission: Bool = true) async throws -> VersionPolicy {
        policyChecks += 1
        checkingPolicy = true
        defer { policyChecks -= 1; checkingPolicy = policyChecks > 0 }
        do {
            let receipt = try await policyService.check()
            try Task.checkCancellation()
            policy = receipt
            policyError = nil
            if requirePermission, receipt.blocksRecording(at: Date()) {
                throw PolicyFailure(message: "此版本已不能开始新录音，请升级后继续。现有录音仍可保存。")
            }
            return receipt
        } catch {
            if !(error is CancellationError) { policyError = error.localizedDescription }
            throw error
        }
    }

    func openPolicyDownload() {
        guard let url = policy?.downloadURL else { return }
        NSWorkspace.shared.open(url)
    }
    private var actionTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var pendingTemporaryURL: URL?
    private var pendingSummary: RecordingSummary?
    private var activeSavePanel: NSSavePanel?

    private var terminating = false
    @Published var updateInProgress = false

    var canInstallUpdate: Bool {
        Self.permitsUpdate(phase: phase, hasPendingRecording: pendingTemporaryURL != nil) && !terminating
    }

    static func permitsUpdate(phase: Phase, hasPendingRecording: Bool) -> Bool {
        guard !hasPendingRecording else { return false }
        switch phase {
        case .preparing, .countingDown, .recording, .exporting: return false
        case .idle, .finished, .failed: return true
        }
    }

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

    func start() { beginStart(discardPending: false) }

    private func beginStart(discardPending: Bool) {
        guard !isBusy, !terminating, !updateInProgress else { return }
        actionTask?.cancel()
        guard pendingTemporaryURL == nil || discardPending else { return }
        elapsedSeconds = 0
        phase = .preparing

        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await verifyPolicy()
                try Task.checkCancellation()
                referralOperationID = try await referrals.begin()
                try Task.checkCancellation()
                cleanupPendingTemporaryFile()
                try await recorder.prepare()
                for value in stride(from: 3, through: 1, by: -1) {
                    try Task.checkCancellation()
                    phase = .countingDown(value)
                    try await countdownPause()
                }
                try Task.checkCancellation()
                try await verifyPolicy()
                try Task.checkCancellation()
                guard let operationID = referralOperationID else { throw PolicyFailure(message: "缺少录音使用许可。") }
                try await referrals.revalidate(operationID)
                try Task.checkCancellation()
                try await recorder.start()
                try Task.checkCancellation()
                recordingStartedAt = Date()
                phase = .recording
                beginClock()
            } catch is CancellationError {
                cancelReferralOperation()
                do { try await recorder.cancel(); phase = .idle }
                catch { phase = .failed(error.localizedDescription) }
            } catch {
                cancelReferralOperation()
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
        activeSavePanel?.cancel(nil)
        clockTask?.cancel()
        clockTask = nil
        let wasFinishing = phase == .recording || phase == .exporting
        do {
            if case .recording = phase {
                phase = .exporting
                finishRecording()
                await actionTask?.value
            } else if case .exporting = phase {
                await actionTask?.value
            } else {
                actionTask?.cancel()
                await actionTask?.value
            }
            try await recorder.cancel()
            actionTask = nil
            cancelReferralOperation()
            if wasFinishing, case .failed(let message) = phase, pendingTemporaryURL == nil {
                throw RecorderError.invalidOutput(message)
            }
        } catch {
            terminating = false
            throw error
        }
    }

    private var recoveredRecordings: [(URL, RecordingSummary)] = []
    private var recoveryLocks: [URL: FileHandle] = [:]
    private var didRecover = false
    @Published private(set) var recoveryCount = 0

    func recoverRecordings(in directoryOverride: URL? = nil, legacyDirectory: URL? = nil) async {
        guard !didRecover, !isBusy else { return }
        didRecover = true
        guard let directory = directoryOverride ?? (try? RecordingFile.recoveryDirectory()) else { return }
        let fm = FileManager.default
        let oldDirectory = legacyDirectory ?? (directoryOverride == nil
            ? fm.temporaryDirectory.appendingPathComponent("LosslessSystemAudioRecorder", isDirectory: true) : nil)
        phase = .preparing
        // Validate before migrating: incomplete MP4 files are left untouched.
        // Renaming keeps a legacy completed recording in exactly one location.
        let directories = [directory] + (oldDirectory.map { [$0] } ?? [])
        for candidateDirectory in directories {
            guard let urls = try? fm.contentsOfDirectory(at: candidateDirectory,
                    includingPropertiesForKeys: nil) else { continue }
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where url.pathExtension == "mp4" && url.lastPathComponent.hasPrefix("recording-")
                    && !RecordingFile.belongsToRunningProcess(url) {
                guard let fileLock = RecordingFile.acquireRecoveryLock(url),
                      let summary = try? await RecordingFile.validate(url) else { continue }
                var recoveredURL = url
                if candidateDirectory != directory {
                    do {
                        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
                        let destination = directory.appendingPathComponent("recording-recovered-\(UUID().uuidString).mp4")
                        try fm.moveItem(at: url, to: destination)
                        recoveredURL = destination
                        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    } catch {
                        // Even a migration failure must not hide usable audio.
                        recoveredURL = url
                    }
                }
                recoveryLocks[recoveredURL] = fileLock
                recoveredRecordings.append((recoveredURL, summary))
            }
        }
        recoveryCount = recoveredRecordings.count
        phase = .idle
        showNextRecovery()
    }

    private func showNextRecovery() {
        guard pendingTemporaryURL == nil, !isBusy, !terminating,
              !recoveredRecordings.isEmpty else { return }
        let (url, summary) = recoveredRecordings.removeFirst()
        pendingTemporaryURL = url
        pendingSummary = summary
        phase = .finished(url, summary)
        recoveryCount = recoveredRecordings.count + 1
    }

    private func finishRecording() {
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (temporaryURL, summary) = try await recorder.stop()
                pendingTemporaryURL = temporaryURL
                pendingSummary = summary
                phase = .finished(temporaryURL, summary)
                if let operationID = referralOperationID {
                    referrals.complete(operationID)
                    referralOperationID = nil
                }
                // A completed recording stays recoverable when closing while
                // the MP4 is being finalized; never open a save panel on exit.
                guard !Task.isCancelled, !terminating else { return }
                exportPendingRecording()
            } catch is CancellationError {
                cancelReferralOperation()
                do { try await recorder.cancel() }
                catch { phase = .failed(error.localizedDescription) }
            } catch {
                cancelReferralOperation()
                let original = error
                do { try await recorder.cancel(); phase = .failed(original.localizedDescription) }
                catch { phase = .failed(error.localizedDescription) }
            }
        }
    }

    var hasPendingRecording: Bool { pendingTemporaryURL != nil }

    func exportAgain() {
        guard pendingTemporaryURL != nil else { return }
        exportPendingRecording()
    }

    func recordAgain() {
        guard !isBusy, !updateInProgress else { return }

        if pendingTemporaryURL != nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "这段录音还没有导出"
            alert.informativeText = "再次录制会删除当前保留的录音。请先点“再次导出”保存，或者确认放弃后继续。"
            alert.addButton(withTitle: "放弃并再次录制")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        if !recoveredRecordings.isEmpty {
            cleanupPendingTemporaryFile()
            showNextRecovery()
            return
        }
        beginStart(discardPending: true)
    }

    private func cancelReferralOperation() {
        if let operationID = referralOperationID { referrals.cancel(operationID) }
        referralOperationID = nil
    }

    func reset() {
        guard !hasPendingRecording else { return }
        cancelReferralOperation()
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
        guard !terminating else { return }
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

        activeSavePanel = panel
        defer { activeSavePanel = nil }
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            phase = .finished(temporaryURL, summary)
            return
        }

        do {
            try RecordingFile.export(temporaryURL, to: destinationURL)
            try? FileManager.default.removeItem(at: temporaryURL)
            try? recoveryLocks.removeValue(forKey: temporaryURL)?.close()
            pendingTemporaryURL = nil
            pendingSummary = nil
            phase = .finished(destinationURL, summary)
            recoveryCount = recoveredRecordings.count
            showNextRecovery()
        } catch {
            phase = .failed("导出失败：\(error.localizedDescription)")
        }
    }

    private func cleanupPendingTemporaryFile() {
        if let pendingTemporaryURL,
           (pendingTemporaryURL.deletingLastPathComponent() == (try? RecordingFile.recoveryDirectory()) ||
            pendingTemporaryURL.path.hasPrefix(FileManager.default.temporaryDirectory.path)) {
            try? FileManager.default.removeItem(at: pendingTemporaryURL)
            try? recoveryLocks.removeValue(forKey: pendingTemporaryURL)?.close()
        }
        pendingTemporaryURL = nil
        pendingSummary = nil
    }
}
