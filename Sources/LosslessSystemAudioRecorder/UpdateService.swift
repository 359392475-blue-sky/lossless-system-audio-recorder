import AppKit
import Sparkle

/// An independent signed feed is required. Merely linking Sparkle never starts networking.
struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: String

    init?(info: [String: Any]) {
        guard info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              let rawURL = info["SUFeedURL"] as? String,
              let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String,
              let decoded = Data(base64Encoded: key), decoded.count == 32 else { return nil }
        feedURL = url
        publicKey = key
    }
}

@MainActor
final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var isConfigured = false
    @Published private(set) var isChecking = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var hasDeferredInstallation = false
    private var deferredInstallHandler: (() -> Void)?
    weak var model: RecorderViewModel?
    private var controller: SPUStandardUpdaterController?
    // Retained through a postponed installation so an update-triggered quit cannot discard audio.
    private(set) var installationPending = false

    override init() {
        super.init()
        guard UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        controller.startUpdater()
        isConfigured = true
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func setAutomaticallyChecks(_ value: Bool) {
        guard let controller, isConfigured else { return }
        controller.updater.automaticallyChecksForUpdates = value
        automaticallyChecks = value
    }

    func checkForUpdates() {
        guard let controller, isConfigured else {
            showMessage("应用内更新尚未启用", "此构建尚未配置独立的签名更新源。录音功能可正常离线使用。")
            return
        }
        guard model?.canInstallUpdate == true else {
            showMessage("请先完成并保存录音", "准备、倒计时、录制、导出或有未保存录音时不能更新。")
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard model?.canInstallUpdate == true else {
            throw NSError(domain: "RecorderUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先完成并保存录音，再检查更新。"])
        }
        isChecking = true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        installationPending = true
        // A second live check, independent of the check-start gate. Never resume automatically.
        guard model?.canInstallUpdate == true else {
            deferredInstallHandler = installHandler
            hasDeferredInstallation = true
            return true
        }
        return false
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        markInstallationPending()
    }

    func markInstallationPending() {
        installationPending = true
        model?.updateInProgress = true
    }

    func resumeInstallation() {
        guard model?.canInstallUpdate == true, let handler = deferredInstallHandler else {
            showMessage("请先完成并保存录音", "录音安全保存后，可从应用菜单继续安装更新。")
            return
        }
        deferredInstallHandler = nil
        hasDeferredInstallation = false
        model?.updateInProgress = true
        handler()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishUpdateCycle(error: error)
    }

    func finishUpdateCycle(error: Error?) {
        isChecking = false
        model?.updateInProgress = false
        deferredInstallHandler = nil
        hasDeferredInstallation = false
        // A failed driver cycle has aborted; do not misclassify later ordinary quits.
        // On success an already staged update may still install on quit.
        if error != nil { installationPending = false }
    }

    private func showMessage(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
