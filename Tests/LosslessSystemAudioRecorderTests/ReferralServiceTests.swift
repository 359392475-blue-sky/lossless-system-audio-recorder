import XCTest
import CryptoKit
@testable import LosslessSystemAudioRecorder

@MainActor
final class ReferralServiceTests: XCTestCase {
    private let serverKey = Curve25519.Signing.PrivateKey()
    private let identity = MemoryReferralIdentity()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var info: [String: Any] {
        ["RecorderPolicyURL": "https://example.invalid:8443/v1/policy?ignored=1", "RecorderPolicyPublicKey": serverKey.publicKey.rawRepresentation.base64EncodedString(), "CFBundleVersion": "6", "CFBundleShortVersionString": "3.2.7"]
    }

    private func signedResponse(_ request: URLRequest, changes: [String: Any] = [:]) throws -> Data {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        let bytes = try XCTUnwrap(Data(base64Encoded: envelope["payload"]!))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: payload["publicKey"] as! String)))
        XCTAssertTrue(publicKey.isValidSignature(Data(base64Encoded: envelope["signature"]!)!, for: bytes))
        XCTAssertEqual(payload["deviceHash"] as? String, String(repeating: "a", count: 64))
        XCTAssertNil(payload["audio"])
        XCTAssertEqual(payload["series"] as? String, "3.2")
        XCTAssertEqual(payload["build"] as? Int, 6)
        var result: [String: Any] = ["schema": 1, "product": "lossless-system-audio-recorder", "nonce": payload["nonce"]!, "publicKey": identity.value.publicKey, "series": "3.2", "issuedAt": 2_000_000_000, "expiresAt": 2_000_000_060, "referralCode": "invite-code", "shareURL": "https://example.invalid/invite/invite-code", "qualifiedCount": 0, "requiredCount": 2, "freeLimit": 5, "usedTrials": 4, "reservedTrials": 1, "unlocked": false, "canRecord": false, "pendingOperationIDs": []]
        if let operationID = payload["operationID"] { result["operationID"] = operationID }
        result.merge(changes) { _, new in new }
        let responseBytes = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        return try JSONSerialization.data(withJSONObject: ["payload": responseBytes.base64EncodedString(), "signature": serverKey.signature(for: responseBytes).base64EncodedString()])
    }

    private func http(_ request: URLRequest, status: Int = 200) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testOriginSeriesSignedRequestsAndFifthReservationPermit() async throws {
        var actions: [String] = []
        let service = ReferralService(info: info, identityProvider: identity, clock: { self.now }, transport: { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid:8443/v1/referral")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            let envelope = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"]!)!) as! [String: Any]
            actions.append(payload["action"] as! String)
            return (try self.signedResponse(request), self.http(request))
        })
        _ = try await service.status()
        _ = try await service.claim(ticket: String(repeating: "a", count: 43))
        let operation = UUID().uuidString
        let permit = try await service.begin(operationID: operation)
        XCTAssertEqual(permit.operationID, operation)
        XCTAssertFalse(permit.canRecord) // A granted fifth reservation still permits this operation.
        _ = try await service.complete(operationID: operation)
        _ = try await service.cancel(operationID: operation)
        XCTAssertEqual(actions, ["status", "claim", "begin", "complete", "cancel"])
    }

    func testRejectsMismatchedDeviceReplayTimeQuotaURLAndOperation() async throws {
        let changes: [[String: Any]] = [["publicKey": "another-device"], ["nonce": UUID().uuidString], ["series": "3.3"], ["schema": 2], ["product": "other"], ["expiresAt": 2_000_000_061], ["issuedAt": 1_999_999_900, "expiresAt": 1_999_999_960], ["issuedAt": 2_000_000_031], ["qualifiedCount": -1], ["requiredCount": 1], ["freeLimit": 6], ["usedTrials": -1], ["reservedTrials": -1], ["shareURL": "http://example.invalid"], ["operationID": UUID().uuidString], ["pendingOperationIDs": ["invalid"]], ["usedTrials": "five"]]
        for change in changes {
            let service = ReferralService(info: info, identityProvider: identity, clock: { self.now }, transport: { request in (try self.signedResponse(request, changes: change), self.http(request)) })
            do { _ = try await service.status(); XCTFail("Accepted \(change)") } catch { }
        }
    }

    func testTamperedSignatureAndReusedReceiptFailClosed() async throws {
        var first: Data?
        let service = ReferralService(info: info, identityProvider: identity, clock: { self.now }, transport: { request in
            if first == nil { first = try self.signedResponse(request) }
            return (first!, self.http(request))
        })
        _ = try await service.status()
        do { _ = try await service.status(); XCTFail("Replay accepted") } catch { }
        let tampered = ReferralService(info: info, identityProvider: identity, clock: { self.now }, transport: { request in
            var object = try JSONSerialization.jsonObject(with: self.signedResponse(request)) as! [String: String]
            object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
            return (try JSONSerialization.data(withJSONObject: object), self.http(request))
        })
        do { _ = try await tampered.status(); XCTFail("Signature accepted") } catch { }
    }

    func testChineseErrorsAndNoConfigurationNeverCreatesIdentity() async throws {
        for (code, phrase) in [("trial_exhausted", "5 次"), ("version_blocked", "升级")] {
            let service = ReferralService(info: info, identityProvider: identity, transport: { request in
                (try JSONSerialization.data(withJSONObject: ["error": code]), self.http(request, status: 403))
            })
            do { _ = try await service.status(); XCTFail("Error accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains(phrase)) }
        }
        let missing = ReferralService(info: [:], identityProvider: FailingReferralIdentity(), transport: { _ in XCTFail("No network"); throw URLError(.badURL) })
        do { _ = try await missing.status(); XCTFail("Missing config accepted") } catch { }
        let offline = ReferralService(info: info, identityProvider: identity, transport: { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.status(); XCTFail("Offline accepted") } catch { }
    }

    func testPermanentClaimFailuresDoNotSuggestBlindRetry() async throws {
        for (code, phrase) in [("ticket_expired_or_unknown", "重新获取"), ("download_not_completed", "完整下载"), ("self_invite", "另一台"), ("device_already_activated", "不能重复"), ("ticket_already_bound", "另一台"), ("device_identity_mismatch", "联系支持")] {
            let service = ReferralService(info: info, identityProvider: identity, transport: { request in
                (try JSONSerialization.data(withJSONObject: ["error": code]), self.http(request, status: 409))
            })
            do { _ = try await service.claim(ticket: String(repeating: "a", count: 43)); XCTFail("Accepted permanent failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains(phrase)) }
        }
    }

    func testStrictTicketAndConfigurationParsing() {
        let ticket = String(repeating: "a", count: 43)
        XCTAssertEqual(ReferralService.ticket(from: URL(string: "lossless-recorder://activate?ticket=\(ticket)")!), ticket)
        XCTAssertEqual(ReferralService.ticket(from: URL(string: "lossless-recorder://activate/?ticket=\(ticket)")!), ticket)
        for url in ["https://activate?ticket=\(ticket)", "lossless-recorder://other?ticket=\(ticket)", "lossless-recorder://activate/path?ticket=\(ticket)", "lossless-recorder://activate?ticket=\(ticket)&ticket=\(ticket)", "lossless-recorder://activate?ticket=short", "lossless-recorder://activate?ticket=\(ticket)#fragment", "lossless-recorder://activate:443?ticket=\(ticket)", "lossless-recorder://activate?ticket=\(ticket)&x=1"] {
            XCTAssertNil(ReferralService.ticket(from: URL(string: url)!))
        }
        for change in [["CFBundleVersion": "5"], ["CFBundleShortVersionString": "3.x"], ["RecorderPolicyURL": "http://example.invalid"]] {
            var invalid = info; invalid.merge(change) { _, new in new }
            XCTAssertNil(ReferralConfiguration(info: invalid))
        }
    }
}

@MainActor
private final class MemoryReferralIdentity: DeviceIdentityProviding {
    let value = DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey(), deviceHash: String(repeating: "a", count: 64))
    func identity() throws -> DeviceIdentity { value }
}

@MainActor
private final class FailingReferralIdentity: DeviceIdentityProviding {
    func identity() throws -> DeviceIdentity { XCTFail("Must not read identity without configuration"); throw URLError(.unknown) }
}
