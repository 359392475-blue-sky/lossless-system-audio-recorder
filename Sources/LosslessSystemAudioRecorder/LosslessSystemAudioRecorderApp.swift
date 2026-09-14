import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderViewModel?
    weak var updates: UpdateService?
    private var isFinishingTermination = false
    private var readyToTerminate = false

    var shouldBlockUpdateTermination: Bool {
        updates?.installationPending == true && model?.canInstallUpdate != true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CaptureVerification.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if shouldBlockUpdateTermination {
            let alert = NSAlert()
            alert.messageText = "请先完成并保存录音"
            alert.informativeText = "更新等待安装，当前不能退出。请保存录音后重试。"
            alert.runModal()
            return .terminateCancel
        }
        guard !isFinishingTermination else { return .terminateCancel }
        guard let model else { return .terminateNow }

        isFinishingTermination = true
        Task { @MainActor [weak self] in
            do {
                try await model.shutdownForTermination()
                self?.readyToTerminate = true
                sender.terminate(nil)
            } catch {
                self?.isFinishingTermination = false
                let alert = NSAlert()
                alert.messageText = "音频设备没有正常释放"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        // terminateLater enters AppKit's nested event loop. Swift MainActor
        // jobs may not run there, including the job meant to reply. Returning
        // cancel lets the normal loop service cleanup; then terminate is called
        // once more with readyToTerminate set, and returns terminateNow.
        return .terminateCancel
    }
}

@main
struct LosslessSystemAudioRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderViewModel()
    @StateObject private var updates = UpdateService()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.updates = updates
                    updates.model = model
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button(updates.isConfigured ? "检查更新…" : "检查更新…（尚未启用）") { updates.checkForUpdates() }
                    .disabled(updates.isChecking)
                if updates.hasDeferredInstallation {
                    Button("录音保存后继续安装更新…") { updates.resumeInstallation() }
                }
                Toggle("自动检查更新", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }))
                    .disabled(!updates.isConfigured)
            }
        }
    }
}
