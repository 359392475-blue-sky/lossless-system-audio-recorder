import AppKit
import Foundation
import Darwin

struct ReferralOperation: Codable, Equatable {
    enum State: String, Codable { case reserved, recording, complete, cancel }
    let id: String
    let ownerPID: Int32
    var state: State
}

@MainActor
protocol ReferralOperationJournaling {
    func read() throws -> [ReferralOperation]
    func save(_ operation: ReferralOperation) throws
    func remove(_ id: String) throws
}

/// One atomic file per operation avoids overwriting another running application's journal.
@MainActor
final class ReferralOperationJournal: ReferralOperationJournaling {
    private let directory: URL
    init(directory: URL? = nil, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        let version = (info["CFBundleShortVersionString"] as? String ?? "unknown").split(separator: ".").prefix(2).joined(separator: ".")
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.lowpower.lossless-system-audio-recorder/ReferralOperations/" + version, isDirectory: true)
    }
    private func path(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw PolicyFailure(message: "录音结算标识无效。") }
        return directory.appendingPathComponent(id + ".json")
    }
    func read() throws -> [ReferralOperation] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ReferralOperation.self, from: Data(contentsOf: $0)) }
    }
    func save(_ operation: ReferralOperation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(operation).write(to: path(operation.id), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func remove(_ id: String) throws {
        let url = try path(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor
final class ReferralCoordinator: ObservableObject {
    @Published private(set) var status: ReferralStatus?
    @Published private(set) var message: String?
    @Published private(set) var checking = false
    private let service: any ReferralChecking
    private let journal: any ReferralOperationJournaling
    private let processAlive: (Int32) -> Bool
    private var activeIDs = Set<String>()
    private var settlingIDs = Set<String>()
    private var terminalIntents: [String: ReferralOperation] = [:]
    private var unresolvedRecovery = 0
    private var requests = 0

    init(service: (any ReferralChecking)? = nil,
         journal: (any ReferralOperationJournaling)? = nil,
         processAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.service = service ?? ReferralService()
        self.journal = journal ?? ReferralOperationJournal()
        self.processAlive = processAlive
    }

    private func busy(_ starting: Bool) {
        requests += starting ? 1 : -1
        checking = requests > 0
    }

    func refresh() async {
        busy(true); defer { busy(false) }
        do {
            try await reconcile()
            status = try await service.status()
            message = unresolvedRecovery == 0 ? nil : "上次异常退出留下未结算的录音预约，暂留 \(unresolvedRecovery) 次额度。请联系维护者核对，已有录音不受影响。"
        } catch { message = error.localizedDescription }
    }

    func claim(_ ticket: String) async {
        busy(true); defer { busy(false) }
        do {
            status = try await service.claim(ticket: ticket)
            message = "邀请已关联。成功完成首次录音后，好友的邀请进度会增加。"
        } catch { message = error.localizedDescription }
    }

    func open(_ url: URL) async {
        guard let ticket = ReferralService.ticket(from: url) else {
            message = "激活链接无效，请回到邀请页面重新打开。"; return
        }
        await claim(ticket)
    }

    func copySupportInfo() {
        guard let reference = service.supportReference ?? status?.publicKey else {
            message = "尚未取得设备支持码，请先重试联网验证。"; return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let operations = (try? journal.read())?.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: "\n") ?? "unavailable"
        let text = "无损系统录音机 \(version) (\(build))\n设备支持码：\(reference)\n待结算操作：\n\(operations)\n提示：\(message ?? "无")"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "排查信息已复制，请私下提供给维护者；不包含录音或原始硬件标识。"
    }

    func copyShareLink() {
        guard let url = status?.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        message = "邀请链接已复制。好友需下载、激活并完成首次录音。"
    }

    func begin() async throws -> String {
        busy(true); defer { busy(false) }
        try await reconcile()
        let id = UUID().uuidString
        let operation = ReferralOperation(id: id, ownerPID: ProcessInfo.processInfo.processIdentifier, state: .reserved)
        try journal.save(operation)
        activeIDs.insert(id)
        do {
            status = try await service.begin(operationID: id)
            try Task.checkCancellation()
            message = nil
            return id
        } catch {
            cancel(id)
            message = error.localizedDescription
            throw error
        }
    }

    func revalidate(_ id: String) async throws {
        busy(true); defer { busy(false) }
        status = try await service.begin(operationID: id)
        try Task.checkCancellation()
        try journal.save(ReferralOperation(id: id, ownerPID: ProcessInfo.processInfo.processIdentifier, state: .recording))
    }

    /// Queue first, then report. Saving/exporting the recording never waits for the network.
    func complete(_ id: String) { queue(id, state: .complete) }
    func cancel(_ id: String) { queue(id, state: .cancel) }

    private func queue(_ id: String, state: ReferralOperation.State) {
        let terminal = ReferralOperation(id: id, ownerPID: ProcessInfo.processInfo.processIdentifier, state: state)
        terminalIntents[id] = terminal
        do {
            try journal.save(terminal)
            terminalIntents.removeValue(forKey: id)
            activeIDs.remove(id)
        } catch {
            message = "录音结算暂未写入，请保留应用数据并重试。已有录音仍可保存。"
            return
        }
        Task { await refresh() }
    }

    func reconcile() async throws {
        for (id, terminal) in terminalIntents {
            try journal.save(terminal)
            terminalIntents.removeValue(forKey: id)
            activeIDs.remove(id)
        }
        unresolvedRecovery = 0
        for var operation in try journal.read() {
            guard !activeIDs.contains(operation.id), !settlingIDs.contains(operation.id) else { continue }
            if operation.state == .recording {
                if !processAlive(operation.ownerPID) { unresolvedRecovery += 1 }
                continue // No durable outcome: never manufacture a completion or refund.
            }
            if operation.state == .reserved {
                // A live second app/process may still be recording. Never refund its reservation.
                guard !processAlive(operation.ownerPID) else { continue }
                operation.state = .cancel
                try journal.save(operation)
            }
            settlingIDs.insert(operation.id)
            defer { settlingIDs.remove(operation.id) }
            switch operation.state {
            case .complete: status = try await service.complete(operationID: operation.id)
            case .cancel: status = try await service.cancel(operationID: operation.id)
            case .reserved, .recording: continue
            }
            try journal.remove(operation.id)
        }
    }
}
