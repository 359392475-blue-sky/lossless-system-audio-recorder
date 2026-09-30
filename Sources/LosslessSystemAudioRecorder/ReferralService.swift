import Foundation
import CryptoKit

struct ReferralStatus: Codable, Equatable {
    let schema: Int
    let product: String
    let nonce: String
    let publicKey: String
    let series: String
    let issuedAt: Int
    let expiresAt: Int
    let referralCode: String
    let shareURL: URL
    let qualifiedCount: Int
    let requiredCount: Int
    let freeLimit: Int
    let usedTrials: Int
    let reservedTrials: Int
    let unlocked: Bool
    let canRecord: Bool
    let pendingOperationIDs: [String]
    let operationID: String?
}

@MainActor
protocol ReferralChecking {
    var supportReference: String? { get }
    func status() async throws -> ReferralStatus
    func claim(ticket: String) async throws -> ReferralStatus
    func begin(operationID: String) async throws -> ReferralStatus
    func complete(operationID: String) async throws -> ReferralStatus
    func cancel(operationID: String) async throws -> ReferralStatus
}

extension ReferralChecking {
    var supportReference: String? { nil }
}

struct ReferralConfiguration {
    let endpoint: URL
    let publicKey: Data
    let build: Int
    let series: String

    init?(info: [String: Any]) {
        guard let policy = PolicyConfiguration(info: info), policy.build >= 6,
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), major >= 0, minor >= 0,
              var origin = URLComponents(url: policy.endpoint, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = "/v1/referral"; origin.query = nil; origin.fragment = nil
        guard let endpoint = origin.url else { return nil }
        self.endpoint = endpoint; publicKey = policy.publicKey; build = policy.build
        series = "\(major).\(minor)"
    }
}

@MainActor
final class ReferralService: ReferralChecking {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private struct Envelope: Codable { let payload: String; let signature: String }
    private(set) var supportReference: String?
    private let configuration: ReferralConfiguration?
    private let identityProvider: any DeviceIdentityProviding
    private let transport: Transport
    private let clock: () -> Date

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], identityProvider: (any DeviceIdentityProviding)? = nil,
         clock: @escaping () -> Date = Date.init, transport: Transport? = nil) {
        configuration = ReferralConfiguration(info: info)
        self.identityProvider = identityProvider ?? DeviceIdentityStore()
        self.clock = clock
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
            let session = URLSession(configuration: config)
            self.transport = { try await session.data(for: $0) }
        }
    }

    nonisolated static func ticket(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "lossless-recorder", url.host?.lowercased() == "activate",
              url.path.isEmpty || url.path == "/", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 1, items[0].name == "ticket",
              let ticket = items[0].value, validTicket(ticket) else { return nil }
        return ticket
    }

    nonisolated private static func validTicket(_ ticket: String) -> Bool {
        ticket.utf8.count == 43 && ticket.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    func status() async throws -> ReferralStatus { try await request(action: "status") }
    func claim(ticket: String) async throws -> ReferralStatus {
        guard Self.validTicket(ticket) else { throw PolicyFailure(message: "邀请凭证无效，请重新打开邀请链接。") }
        return try await request(action: "claim", ticket: ticket)
    }
    func begin(operationID: String) async throws -> ReferralStatus { try await request(action: "begin", operationID: operationID) }
    func complete(operationID: String) async throws -> ReferralStatus { try await request(action: "complete", operationID: operationID) }
    func cancel(operationID: String) async throws -> ReferralStatus { try await request(action: "cancel", operationID: operationID) }

    private static func failureMessage(code: String?) -> String? {
        switch code {
        case "trial_exhausted", "trial_limit_reached":
            return "5 次免费试用已用完。邀请 2 位新设备用户完成下载和首次录音，即可解锁本系列无限免费录音。"
        case "version_blocked", "upgrade_required":
            return "此版本已暂停新录音，请升级后重试。已有录音仍可保存。"
        case "ticket_expired_or_unknown", "ticket_expired", "invalid_ticket":
            return "邀请凭证已过期或无效，请从邀请页面重新获取下载链接。"
        case "download_not_completed", "download_incomplete":
            return "请先通过邀请页面完整下载应用，再打开激活链接。"
        case "self_invite", "self_referral":
            return "不能使用自己的邀请链接激活，请邀请另一台新设备。"
        case "device_already_activated", "already_activated":
            return "这台设备已激活，不能重复计为新的受邀设备。"
        case "ticket_already_bound", "ticket_used":
            return "此邀请凭证已被另一台设备使用，请重新获取邀请下载链接。"
        case "device_identity_mismatch", "device_key_already_registered", "device_conflict":
            return "此 Mac 的设备凭据与已登记记录不一致，请保留原钥匙串凭据并联系支持。"
        case "operation_finalized":
            return "这次录音操作已经结算，请刷新状态后开始新的录音。"
        case "unknown_operation", "invalid_operation":
            return "服务器无法识别这次录音操作，请保留已生成的录音并联系支持。"
        case "invalid_signature", "invalid_public_key":
            return "本机设备凭据验证失败，请保留原钥匙串凭据并联系支持。"
        default: return nil
        }
    }

    private func request(action: String, operationID: String? = nil, ticket: String? = nil) async throws -> ReferralStatus {
        guard let configuration else { throw PolicyFailure(message: "此版本缺少在线试用验证配置，请安装正式版本。") }
        if let operationID, UUID(uuidString: operationID) == nil { throw PolicyFailure(message: "录音操作标识无效，请重试。") }
        let identity = try identityProvider.identity()
        supportReference = identity.publicKey
        guard identity.deviceHash.utf8.count == 64, identity.deviceHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PolicyFailure(message: "本机设备标识无效。") }
        let nonce = UUID().uuidString
        var object: [String: Any] = ["schema": 1, "product": "lossless-system-audio-recorder", "action": action, "publicKey": identity.publicKey, "deviceHash": identity.deviceHash, "series": configuration.series, "build": configuration.build, "nonce": nonce, "issuedAt": Int(clock().timeIntervalSince1970)]
        if let operationID { object["operationID"] = operationID }
        if let ticket { object["ticket"] = ticket }
        let payload = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let envelope = Envelope(payload: payload.base64EncodedString(), signature: try identity.privateKey.signature(for: payload).base64EncodedString())
        var request = URLRequest(url: configuration.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let data: Data; let response: URLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PolicyFailure(message: "无法在线验证试用资格，请检查网络后重试。已有录音不会被删除。") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, PolicyConfiguration.isHTTPS(finalURL), data.count <= 128 * 1024 else { throw PolicyFailure(message: "试用验证响应无效，请重试。") }
        guard http.statusCode == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = error?["error"] as? String ?? error?["code"] as? String
            if (400..<500).contains(http.statusCode), let message = Self.failureMessage(code: code) {
                throw PolicyFailure(message: message)
            }
            throw PolicyFailure(message: "暂时无法验证试用资格，请稍后重试。")
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard let bytes = Data(base64Encoded: envelope.payload), let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
                  try Curve25519.Signing.PublicKey(rawRepresentation: configuration.publicKey).isValidSignature(signature, for: bytes) else { throw PolicyFailure(message: "试用资格签名无效，请重试。") }
            let status = try JSONDecoder().decode(ReferralStatus.self, from: bytes)
            let now = clock().timeIntervalSince1970
            guard status.schema == 1, status.product == "lossless-system-audio-recorder", status.nonce == nonce,
                  status.publicKey == identity.publicKey, status.series == configuration.series,
                  status.issuedAt >= 0, status.expiresAt > status.issuedAt, Double(status.expiresAt) - Double(status.issuedAt) <= 60,
                  now >= Double(status.issuedAt) - 30, now <= Double(status.expiresAt) + 30,
                  PolicyConfiguration.isHTTPS(status.shareURL), status.qualifiedCount >= 0, status.requiredCount == 2,
                  status.freeLimit == 5, status.usedTrials >= 0, status.reservedTrials >= 0,
                  status.pendingOperationIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
                  Set(status.pendingOperationIDs).count == status.pendingOperationIDs.count,
                  status.operationID == operationID else { throw PolicyFailure(message: "试用资格响应已过期或与当前设备、录音操作不符，请重试。") }
            return status
        } catch let error as PolicyFailure { throw error }
        catch { throw PolicyFailure(message: "无法验证试用资格，请重试。") }
    }
}
