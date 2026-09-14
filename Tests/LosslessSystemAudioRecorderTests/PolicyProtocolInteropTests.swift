import XCTest
@testable import LosslessSystemAudioRecorder

/// Node crypto uses the same raw-payload Ed25519 wire protocol as the policy service.
@MainActor
final class PolicyProtocolInteropTests: XCTestCase {
    func testNodeSignatureInteroperatesAndTamperOrNonceMismatchFailsClosed() async throws {
        try await assertFreshNodeResponse(mode: "valid")
        try await assertFreshNodeResponse(mode: "signature")
        try await assertFreshNodeResponse(mode: "nonce")
    }

    private func assertFreshNodeResponse(mode: String) async throws {
        // Start Node as a tiny stdin/stdout signer so Swift can configure its public key
        // before producing the fresh nonce. The ephemeral private key never leaves Node.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", #"""
        const crypto = require('node:crypto');
        const readline = require('node:readline');
        const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
        console.log(Buffer.from(publicKey.export({format:'jwk'}).x, 'base64url').toString('base64'));
        readline.createInterface({input:process.stdin}).once('line', line => {
          const request = JSON.parse(line);
          const payload = Buffer.from(JSON.stringify({schema:1,product:'lossless-system-audio-recorder',
            nonce:request.mode === 'nonce' ? 'wrong-nonce' : request.nonce, clientBuild:5,sequence:42,
            issuedAt:2000000000,expiresAt:2000000060,level:4,minimumBuild:6,effectiveAt:2000000000,
            latestBuild:6,title:'需要升级',message:'已有录音仍可保存',downloadURL:'https://example.invalid/download'}));
          const signature = crypto.sign(null,payload,privateKey);
          if(request.mode === 'signature') signature[0] ^= 1;
          console.log(JSON.stringify({payload:payload.toString('base64'),signature:signature.toString('base64')}));
          process.exit(0);
        });
        """#]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        func readLine() throws -> Data {
            var data = Data()
            while true {
                let byte = try output.fileHandleForReading.read(upToCount: 1) ?? Data()
                guard !byte.isEmpty else { throw NSError(domain: "NodeFixture", code: 1) }
                if byte[0] == 10 { return data }
                data.append(byte)
            }
        }
        let key = try XCTUnwrap(String(data: readLine(), encoding: .utf8))
        let suite = "PolicyInterop." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let service = VersionPolicyService(info: ["RecorderPolicyURL": "https://example.invalid/policy", "RecorderPolicyPublicKey": key, "CFBundleVersion": "5"], defaults: UserDefaults(suiteName: suite)!, clock: { Date(timeIntervalSince1970: 2_000_000_000) }, transport: { request in
            let nonce = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "nonce" }!.value!
            var command = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "mode": mode])
            command.append(10)
            try input.fileHandleForWriting.write(contentsOf: command)
            return (try readLine(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        if mode == "valid" {
            let policy = try await service.check()
            XCTAssertEqual(policy.level, 4)
            XCTAssertTrue(policy.blocksRecording(at: Date(timeIntervalSince1970: 2_000_000_000)))
            XCTAssertEqual(policy.title, "需要升级")
        } else {
            do { _ = try await service.check(); XCTFail("Accepted \(mode)") } catch { }
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
