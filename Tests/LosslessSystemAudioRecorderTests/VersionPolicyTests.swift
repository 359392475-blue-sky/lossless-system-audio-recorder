import XCTest
import CryptoKit
import CoreAudio
@testable import LosslessSystemAudioRecorder

@MainActor
final class VersionPolicyTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func store() -> UserDefaults {
        let name = "RecorderPolicyTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private var info: [String: Any] {
        ["RecorderPolicyURL": "https://policy.example.invalid/check", "RecorderPolicyPublicKey": key.publicKey.rawRepresentation.base64EncodedString(), "CFBundleVersion": "5"]
    }

    private func body(_ request: URLRequest, changes: [String: Any] = [:]) throws -> Data {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        var value: [String: Any] = ["schema": 1, "product": "lossless-system-audio-recorder", "nonce": query.first { $0.name == "nonce" }!.value!, "clientBuild": 5, "sequence": 10, "issuedAt": 2_000_000_000, "expiresAt": 2_000_000_060, "level": 0, "minimumBuild": 5, "effectiveAt": 2_000_000_000, "latestBuild": 6, "title": "更新", "message": "新功能", "downloadURL": "https://example.invalid/download"]
        value.merge(changes) { _, new in new }
        let payload = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
    }

    private func response(_ request: URLRequest) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    func testFreshSignedRequestAndNoCachedAuthorization() async throws {
        var nonces: [String] = []
        let service = VersionPolicyService(info: info, defaults: store(), clock: { self.now }, transport: { request in
            nonces.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "nonce" }!.value!)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return (try self.body(request), self.response(request))
        })
        _ = try await service.check(); _ = try await service.check()
        XCTAssertEqual(Set(nonces).count, 2)
    }

    func testRejectsInvalidSignedClaims() async throws {
        let changes: [[String: Any]] = [["nonce": UUID().uuidString], ["clientBuild": 4], ["schema": 2], ["product": "haoyu"], ["level": 5], ["sequence": -1], ["minimumBuild": 0], ["latestBuild": 0], ["expiresAt": 2_000_000_061], ["issuedAt": 2_000_000_031, "expiresAt": 2_000_000_060], ["issuedAt": 1_999_999_900, "expiresAt": 1_999_999_960], ["downloadURL": "http://example.invalid"]]
        for change in changes {
            let service = VersionPolicyService(info: info, defaults: store(), clock: { self.now }, transport: { request in (try self.body(request, changes: change), self.response(request)) })
            do { _ = try await service.check(); XCTFail("Accepted \(change)") } catch { }
        }
    }

    func testReplayWrongSignatureRollbackAndOfflineFailClosed() async throws {
        var saved: Data?
        var count = 0
        let defaults = store()
        let replay = VersionPolicyService(info: info, defaults: defaults, clock: { self.now }, transport: { request in
            count += 1
            if saved == nil { saved = try self.body(request) }
            return (saved!, self.response(request))
        })
        _ = try await replay.check()
        do { _ = try await replay.check(); XCTFail("replay accepted") } catch { }
        let rollback = VersionPolicyService(info: info, defaults: defaults, clock: { self.now }, transport: { request in (try self.body(request, changes: ["sequence": 9]), self.response(request)) })
        do { _ = try await rollback.check(); XCTFail("rollback accepted") } catch { }
        var wrongInfo = info
        wrongInfo["RecorderPolicyPublicKey"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let wrong = VersionPolicyService(info: wrongInfo, defaults: store(), clock: { self.now }, transport: { request in (try self.body(request), self.response(request)) })
        do { _ = try await wrong.check(); XCTFail("signature accepted") } catch { }
        let offline = VersionPolicyService(info: info, defaults: defaults, transport: { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.check(); XCTFail("offline accepted") } catch { }
        XCTAssertEqual(count, 2)
    }

    func testMissingConfigurationNeverCallsTransport() async {
        let service = VersionPolicyService(info: [:], defaults: store(), transport: { _ in XCTFail("network should not start"); throw URLError(.badURL) })
        do { _ = try await service.check(); XCTFail("missing config accepted") } catch { }
    }

    func testUnsafeEndpointOrBuildIsNotConfigured() {
        for change: [String: Any] in [["RecorderPolicyURL": "http://example.invalid/check"], ["RecorderPolicyURL": "https://user:pass@example.invalid/check"], ["RecorderPolicyPublicKey": "invalid"], ["CFBundleVersion": "0"]] {
            var configuration = info
            configuration.merge(change) { _, new in new }
            XCTAssertNil(PolicyConfiguration(info: configuration))
        }
    }

    func testRefreshDenialDoesNotInterruptExistingRecording() async throws {
        let driver = PolicyTestDriver()
        let checker = PolicyTestChecker(denyOn: 3)
        let model = RecorderViewModel(recorder: SystemAudioCaptureService(driver: driver), policyService: checker, referrals: recordingTestReferrals(), countdownPause: {})
        model.start()
        for _ in 0..<100 where model.phase != .recording { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.phase, .recording)
        await model.refreshPolicy()
        XCTAssertEqual(checker.calls, 3)
        XCTAssertEqual(model.phase, .recording)
        XCTAssertTrue(driver.active)
        XCTAssertNotNil(model.policyError)
        try await model.shutdownForTermination()
    }

    func testTrialDenialDoesNotPrepareAudio() async throws {
        let driver = PolicyTestDriver(), checker = PolicyTestChecker(denyOn: 99)
        let referrals = RecordingReferralStub()
        referrals.denyBegin = true
        let coordinator = ReferralCoordinator(service: referrals, journal: MemoryReferralJournal())
        let model = RecorderViewModel(recorder: SystemAudioCaptureService(driver: driver), policyService: checker, referrals: coordinator, countdownPause: {})
        model.start()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(driver.prepares, 0)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertTrue(referrals.completed.isEmpty)
    }

    func testFailedAudioFinalizationReleasesTrialReservation() async throws {
        let driver = PolicyTestDriver(), checker = PolicyTestChecker(denyOn: 99)
        let referrals = RecordingReferralStub(), journal = MemoryReferralJournal()
        let coordinator = ReferralCoordinator(service: referrals, journal: journal)
        let model = RecorderViewModel(recorder: SystemAudioCaptureService(driver: driver), policyService: checker, referrals: coordinator, countdownPause: {})
        model.start()
        for _ in 0..<100 where model.phase != .recording { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.phase, .recording)
        model.stop() // Driver supplied no audio frames: output validation fails.
        for _ in 0..<100 where model.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        await coordinator.refresh()
        XCTAssertTrue(referrals.completed.isEmpty)
        XCTAssertEqual(referrals.cancelled.count, 1)
        XCTAssertTrue(journal.operations.isEmpty)
    }

    func testAllLevelsAndDeadline() async throws {
        for level in 0...4 {
            let service = VersionPolicyService(info: info, defaults: store(), clock: { self.now }, transport: { request in (try self.body(request, changes: ["level": level, "minimumBuild": 6, "effectiveAt": 2_000_000_010]), self.response(request)) })
            let policy = try await service.check()
            XCTAssertEqual(policy.blocksRecording(at: now), level == 4)
            XCTAssertEqual(policy.blocksRecording(at: now.addingTimeInterval(10)), level >= 3)
        }
    }

    func testCountdownSecondDenialReleasesDeviceWithoutStartingAudio() async throws {
        let driver = PolicyTestDriver()
        let checker = PolicyTestChecker(denyOn: 2)
        let model = RecorderViewModel(recorder: SystemAudioCaptureService(driver: driver), policyService: checker, referrals: recordingTestReferrals(), countdownPause: {})
        model.start()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(checker.calls, 2)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertFalse(driver.active)
        if case .failed = model.phase { } else { XCTFail("Must block recording") }
    }

    func testFirstDenialDoesNotPrepareAndRetryChecksAgain() async throws {
        let driver = PolicyTestDriver()
        let checker = PolicyTestChecker(denyOn: 1)
        let model = RecorderViewModel(recorder: SystemAudioCaptureService(driver: driver), policyService: checker, referrals: recordingTestReferrals(), countdownPause: {})
        model.start()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(driver.prepares, 0)
        XCTAssertEqual(checker.calls, 1)
        model.start()
        for _ in 0..<100 where model.phase != .recording { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(checker.calls, 3)
        XCTAssertEqual(driver.starts, 1)
        try await model.shutdownForTermination()
    }
}

@MainActor
private final class PolicyTestChecker: VersionPolicyChecking {
    var calls = 0
    let denyOn: Int
    init(denyOn: Int) { self.denyOn = denyOn }
    func check() async throws -> VersionPolicy {
        calls += 1
        if calls == denyOn { throw PolicyFailure(message: "denied") }
        return VersionPolicy(schema: 1, product: "lossless-system-audio-recorder", nonce: UUID().uuidString, clientBuild: 5, sequence: 1, issuedAt: 0, expiresAt: 60, level: 0, minimumBuild: 5, effectiveAt: 0, latestBuild: 5, title: "", message: "", downloadURL: URL(string: "https://example.invalid")!)
    }
}

private final class PolicyTestDriver: AudioCaptureDriver, @unchecked Sendable {
    var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var active = false
    var starts = 0
    var prepares = 0
    var diagnostics: [String: String] { ["active": String(active)] }
    func prepare() throws { active = true; prepares += 1 }
    func start(receive: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void) throws { starts += 1 }
    func stop() throws { active = false }
}
