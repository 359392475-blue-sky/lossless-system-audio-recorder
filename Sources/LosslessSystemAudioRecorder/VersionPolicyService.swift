import Foundation
import CryptoKit

struct VersionPolicy: Codable, Equatable {
    let schema: Int
    let product: String
    let nonce: String
    let clientBuild: Int
    let sequence: Int
    let issuedAt: Int
    let expiresAt: Int
    let level: Int
    let minimumBuild: Int
    let effectiveAt: Int
    let latestBuild: Int
    let title: String
    let message: String
    let downloadURL: URL

    func blocksRecording(at date: Date) -> Bool {
        clientBuild < minimumBuild && (level == 4 || (level == 3 && date.timeIntervalSince1970 >= Double(effectiveAt)))
    }
}

struct PolicyConfiguration {
    let endpoint: URL
    let publicKey: Data
    let build: Int

    init?(info: [String: Any]) {
        guard let raw = info["RecorderPolicyURL"] as? String,
              let endpoint = URL(string: raw), Self.isHTTPS(endpoint),
              let encoded = info["RecorderPolicyPublicKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              let rawBuild = info["CFBundleVersion"] as? String,
              let build = Int(rawBuild), build > 0 else { return nil }
        self.endpoint = endpoint; publicKey = key; self.build = build
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }
}

struct PolicyFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol VersionPolicyChecking {
    func check() async throws -> VersionPolicy
}

/// Every call performs a new nonce-bound request. Only rollback protection is persisted, never an authorization.
@MainActor
final class VersionPolicyService: VersionPolicyChecking {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private struct Envelope: Decodable { let payload: String; let signature: String }
    private let configuration: PolicyConfiguration?
    private let transport: Transport
    private let clock: () -> Date
    private let defaults: UserDefaults
    private let sequenceKey: String

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = Date.init,
         transport: Transport? = nil) {
        configuration = PolicyConfiguration(info: info)
        self.defaults = defaults
        self.clock = clock
        let identity = String(describing: info["RecorderPolicyURL"]) + String(describing: info["RecorderPolicyPublicKey"])
        sequenceKey = "recorder.policy.sequence." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            let session = URLSession(configuration: config)
            self.transport = { request in try await session.data(for: request) }
        }
    }

    func check() async throws -> VersionPolicy {
        guard let configuration else { throw PolicyFailure(message: "此版本缺少在线版本验证配置，不能开始新录音。请安装正式版本。") }
        let nonce = UUID().uuidString
        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)!
        var query = (components.queryItems ?? []).filter { $0.name != "build" && $0.name != "nonce" }
        query += [URLQueryItem(name: "build", value: String(configuration.build)), URLQueryItem(name: "nonce", value: nonce)]
        components.queryItems = query
        guard let url = components.url else { throw PolicyFailure(message: "版本验证地址无效。") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PolicyFailure(message: "无法在线验证当前版本。请检查网络并重试；现有录音仍可停止和保存。") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, PolicyConfiguration.isHTTPS(finalURL),
              data.count <= 128 * 1024 else { throw PolicyFailure(message: "版本验证响应无效，请重试。") }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard let payload = Data(base64Encoded: envelope.payload),
                  let signature = Data(base64Encoded: envelope.signature),
                  signature.count == 64,
                  try Curve25519.Signing.PublicKey(rawRepresentation: configuration.publicKey).isValidSignature(signature, for: payload)
            else { throw PolicyFailure(message: "版本策略签名无效，已阻止开始新录音。") }
            let policy = try JSONDecoder().decode(VersionPolicy.self, from: payload)
            let now = clock().timeIntervalSince1970
            guard policy.schema == 1, policy.product == "lossless-system-audio-recorder",
                  policy.nonce == nonce, policy.clientBuild == configuration.build,
                  policy.sequence >= 0, (0...4).contains(policy.level),
                  policy.minimumBuild > 0, policy.latestBuild > 0,
                  policy.issuedAt >= 0, policy.expiresAt > policy.issuedAt,
                  Double(policy.expiresAt) - Double(policy.issuedAt) <= 60,
                  now >= Double(policy.issuedAt) - 30, now <= Double(policy.expiresAt) + 30,
                  policy.effectiveAt >= 0, PolicyConfiguration.isHTTPS(policy.downloadURL),
                  policy.sequence >= defaults.integer(forKey: sequenceKey)
            else { throw PolicyFailure(message: "版本策略已过期、回退或与本次请求不符，请重试。") }
            defaults.set(policy.sequence, forKey: sequenceKey)
            return policy
        } catch let failure as PolicyFailure { throw failure }
        catch { throw PolicyFailure(message: "无法验证版本策略，已阻止开始新录音。") }
    }
}
