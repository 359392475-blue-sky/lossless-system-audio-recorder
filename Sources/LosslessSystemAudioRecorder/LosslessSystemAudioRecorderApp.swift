import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderViewModel?
    private var isFinishingTermination = false
    private var readyToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        CaptureVerification.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
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

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
