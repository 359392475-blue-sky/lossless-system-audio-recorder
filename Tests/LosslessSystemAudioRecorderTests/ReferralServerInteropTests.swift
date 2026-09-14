import XCTest
import CryptoKit
@testable import LosslessSystemAudioRecorder

/// Real Swift client -> current Node service -> SQLite; only HTTPS routing is replaced in this test.
@MainActor
final class ReferralServerInteropTests: XCTestCase {
    func testRealDownloadsFirstRecordingsUnlockSeriesAndRetriesStayIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReferralServerInterop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "-e", #"""
        import { generateKeyPairSync, createHash } from 'node:crypto';
        import { writeFileSync } from 'node:fs';
        import { join } from 'node:path';
        const { createService } = await import(process.argv[1]);
        const dir = process.argv[2], keys = generateKeyPairSync('ed25519');
        const zip = Buffer.concat([Buffer.from('504b0304','hex'),Buffer.alloc(1024,31)]);
        const env = {
          POLICY_FILE:join(dir,'policy.json'), POLICY_PRIVATE_KEY_FILE:join(dir,'key.pem'),
          STATS_DB:join(dir,'stats.sqlite'), ADMIN_TOKEN:'test-admin-only-'.repeat(3),
          RELEASE_ARTIFACT_URL:'https://recorder.example.invalid/releases/6/Recorder.zip',RELEASE_ARTIFACT_BUILD:'6',
          REFERRAL_PUBLIC_ORIGIN:'https://recorder.example.invalid',REFERRAL_DEVICE_PEPPER:'test-pepper-only-'.repeat(3),
          REFERRAL_SERIES:'3.2',REFERRAL_ARTIFACT_FILE:join(dir,'Recorder.zip'),
          REFERRAL_ARTIFACT_SHA256:createHash('sha256').update(zip).digest('hex')
        };
        writeFileSync(env.POLICY_FILE,JSON.stringify({schema:1,product:'lossless-system-audio-recorder',sequence:1,
          level:0,minimumBuild:6,effectiveAt:0,latestBuild:6,title:'Interop fixture',message:'',downloadURL:env.RELEASE_ARTIFACT_URL}));
        writeFileSync(env.POLICY_PRIVATE_KEY_FILE,keys.privateKey.export({format:'pem',type:'pkcs8'}),{mode:0o600});
        writeFileSync(env.REFERRAL_ARTIFACT_FILE,zip);
        const server=createService(env,{now:()=>2000000000000});
        let closing=false;
        const close=()=>{if(closing)return;closing=true;server.closeAllConnections();server.close(()=>process.exit(0));};
        process.stdin.resume();process.stdin.on('end',close);process.on('SIGTERM',close);
        setTimeout(close,45000).unref();
        server.listen(0,'127.0.0.1',()=>console.log(JSON.stringify({port:server.address().port,
          publicKey:Buffer.from(keys.publicKey.export({format:'jwk'}).x,'base64url').toString('base64')})));
        """#, root.appendingPathComponent("server/service.mjs").absoluteString, directory.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        try process.run()
        var handshake = Data()
        while true {
            let byte = try output.fileHandleForReading.read(upToCount: 1) ?? Data()
            guard !byte.isEmpty else {
                let reason = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(domain: "ReferralServerInterop", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            if byte[0] == 10 { break }
            handshake.append(byte)
        }
        let connection = try XCTUnwrap(JSONSerialization.jsonObject(with: handshake) as? [String: Any])
        let port = try XCTUnwrap(connection["port"] as? Int)
        let publicKey = try XCTUnwrap(connection["publicKey"] as? String)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport: ReferralService.Transport = { original in
            var components = URLComponents(url: original.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "recorder.example.invalid")
            components.scheme = "http"; components.host = "127.0.0.1"; components.port = port
            var routed = original; routed.url = components.url!
            let (data, rawResponse) = try await session.data(for: routed)
            let http = try XCTUnwrap(rawResponse as? HTTPURLResponse)
            let response = try XCTUnwrap(HTTPURLResponse(url: original.url!, statusCode: http.statusCode, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let info: [String: Any] = ["RecorderPolicyURL": "https://recorder.example.invalid/v1/policy", "RecorderPolicyPublicKey": publicKey, "CFBundleVersion": "6", "CFBundleShortVersionString": "3.2.0"]
        let inviterIdentity = InteropReferralIdentity(character: "a")
        let inviter = ReferralService(info: info, identityProvider: inviterIdentity, clock: { Date(timeIntervalSince1970: 2_000_000_000) }, transport: transport)
        let initial = try await inviter.status()
        XCTAssertEqual(initial.qualifiedCount, 0)
        XCTAssertFalse(initial.unlocked)
        for (index, character) in ["b", "c"].enumerated() {
            let friend = ReferralService(info: info, identityProvider: InteropReferralIdentity(character: character), clock: { Date(timeIntervalSince1970: 2_000_000_000) }, transport: transport)
            var ticketRequest = URLRequest(url: URL(string: "https://recorder.example.invalid/r/\(initial.referralCode)/ticket")!)
            ticketRequest.httpMethod = "POST"
            ticketRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            let (ticketBytes, ticketResponse) = try await transport(ticketRequest)
            XCTAssertEqual((ticketResponse as? HTTPURLResponse)?.statusCode, 200)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: ticketBytes) as? [String: Any])
            let ticket = try XCTUnwrap(result["ticket"] as? String)
            let activationURL = try XCTUnwrap(URL(string: XCTUnwrap(result["activationURL"] as? String)))
            XCTAssertEqual(ReferralService.ticket(from: activationURL), ticket)
            do { _ = try await friend.claim(ticket: ticket); XCTFail("Undownloaded ticket accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("完整下载")) }
            let downloadURL = try XCTUnwrap(URL(string: XCTUnwrap(result["downloadURL"] as? String)))
            let (download, downloadResponse) = try await transport(URLRequest(url: downloadURL))
            XCTAssertEqual((downloadResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(download, Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 31, count: 1024))
            _ = try await friend.claim(ticket: ticket)
            let operation = UUID().uuidString
            let first = try await friend.begin(operationID: operation)
            let repeated = try await friend.begin(operationID: operation)
            XCTAssertEqual(first.operationID, operation)
            XCTAssertEqual(repeated.reservedTrials, 1)
            let completed = try await friend.complete(operationID: operation)
            let completedAgain = try await friend.complete(operationID: operation)
            XCTAssertEqual(completed.usedTrials, 1)
            XCTAssertEqual(completedAgain.usedTrials, 1)
            let progress = try await inviter.status()
            XCTAssertEqual(progress.qualifiedCount, index + 1)
            XCTAssertEqual(progress.unlocked, index == 1)
        }
        // Exceed the five-trial limit using the unlocked inviter's real signed operations.
        for _ in 0..<7 {
            let operation = UUID().uuidString
            let permit = try await inviter.begin(operationID: operation)
            XCTAssertEqual(permit.operationID, operation)
            XCTAssertTrue(permit.unlocked)
            let completed = try await inviter.complete(operationID: operation)
            XCTAssertTrue(completed.canRecord)
            XCTAssertEqual(completed.qualifiedCount, 2)
        }
        var patchInfo = info; patchInfo["CFBundleShortVersionString"] = "3.2.9"
        let patched = ReferralService(info: patchInfo, identityProvider: inviterIdentity, clock: { Date(timeIntervalSince1970: 2_000_000_000) }, transport: transport)
        let inherited = try await patched.status()
        XCTAssertTrue(inherited.unlocked)
        XCTAssertEqual(inherited.series, "3.2")
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

@MainActor
private final class InteropReferralIdentity: DeviceIdentityProviding {
    private let value: DeviceIdentity
    init(character: String) {
        value = DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey(), deviceHash: String(repeating: character, count: 64))
    }
    func identity() throws -> DeviceIdentity { value }
}
