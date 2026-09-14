import AppKit
import Foundation

/// Opt-in integration check. Never runs on a normal launch, never uploads data.
enum CaptureVerification {
    @MainActor static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--verify-capture"), args.count > index + 1 else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task {
            let service = SystemAudioCaptureService()
            let policyService = VersionPolicyService()
            var result: [String: Any] = ["backend": "CoreAudioProcessTap", "cycles": []]
            var cycles: [[String: Any]] = []
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for index in 1...3 {
                    let before = try await policyService.check()
                    guard !before.blocksRecording(at: Date()) else { throw PolicyFailure(message: "当前版本禁止录音验收，请升级。") }
                    try await service.prepare()
                    let after = try await policyService.check()
                    guard !after.blocksRecording(at: Date()) else { throw PolicyFailure(message: "当前版本禁止录音验收，请升级。") }
                    try await service.start()
                    let active = await service.diagnostics()
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let (url, summary) = try await service.stop()
                    let stopped = await service.diagnostics()
                    guard stopped["tap"] == "0", stopped["device"] == "0", stopped["io"] == "none" else {
                        throw RecorderError.invalidOutput("停止后仍有采集资源。")
                    }
                    let destination = directory.appendingPathComponent("cycle-\(index)-\(UUID().uuidString).mp4")
                    try FileManager.default.moveItem(at: url, to: destination)
                    cycles.append(["active": active, "stopped": stopped,
                                   "duration": summary.duration, "file": destination.lastPathComponent])
                }
                let finalPolicy = try await policyService.check()
                guard !finalPolicy.blocksRecording(at: Date()) else { throw PolicyFailure(message: "当前版本禁止录音验收，请升级。") }
                try await service.prepare(); try await service.cancel(); try await service.cancel()
                result["cancelled"] = await service.diagnostics()
                result["status"] = "passed"
            } catch {
                result["status"] = "failed"; result["error"] = error.localizedDescription
                do { try await service.cancel() }
                catch { result["cleanupError"] = error.localizedDescription }
            }
            result["cycles"] = cycles
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
            } catch { NSLog("Capture verification report failed: %@", error.localizedDescription) }
            NSApplication.shared.terminate(nil)
        }
    }
}
