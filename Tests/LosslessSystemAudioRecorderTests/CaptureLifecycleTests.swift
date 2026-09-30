import CoreAudio
import XCTest
@testable import LosslessSystemAudioRecorder

private final class FakeDriver: AudioCaptureDriver, @unchecked Sendable {
    var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var active = false
    var failStart = false
    var failStop = false
    var diagnostics: [String: String] { ["active": String(active)] }
    func prepare() throws { active = true }
    func start(receive: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void) throws {
        if failStart { throw RecorderError.captureFailed("测试启动", -1) }
        var samples = (0..<960).map { Float(sin(Double($0) * 0.1)) * 0.2 }
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: format.mChannelsPerFrame, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            withUnsafePointer(to: &list) { receive($0) }
        }
    }
    func stop() throws {
        if failStop { throw RecorderError.captureFailed("测试停止", -2) }
        active = false
    }
}

final class CaptureLifecycleTests: XCTestCase {
    func testStartupFailureReleasesResources() async throws {
        let driver = FakeDriver(); driver.failStart = true
        let service = SystemAudioCaptureService(driver: driver)
        try await service.prepare()
        do { try await service.start(); XCTFail("Must throw") } catch { }
        let state = await service.diagnostics()
        XCTAssertEqual(state["active"], "false")
    }

    func testCancelBeforeAndDuringCaptureIsRepeatable() async throws {
        let driver = FakeDriver(), service: SystemAudioCaptureService
        service = SystemAudioCaptureService(driver: driver)
        try await service.prepare(); try await service.cancel(); try await service.cancel()
        try await service.prepare(); try await service.start(); try await service.cancel()
        let state = await service.diagnostics()
        XCTAssertEqual(state["active"], "false")
    }

    func testStopReleasesCaptureBeforeReturningValidLosslessFile() async throws {
        let service = SystemAudioCaptureService(driver: FakeDriver())
        try await service.prepare(); try await service.start()
        let (url, summary) = try await service.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = await service.diagnostics()
        XCTAssertEqual(state["active"], "false")
        XCTAssertGreaterThan(summary.duration, 0)
        XCTAssertGreaterThan(summary.fileSize, 0)
        XCTAssertEqual(summary.sampleRate, 48_000)
        XCTAssertEqual(summary.channelCount, 2)
    }

    func testActualMono44100FormatIsReported() async throws {
        let driver = FakeDriver()
        driver.format.mSampleRate = 44_100
        driver.format.mChannelsPerFrame = 1
        driver.format.mBytesPerFrame = 4
        driver.format.mBytesPerPacket = 4
        let service = SystemAudioCaptureService(driver: driver)
        try await service.prepare(); try await service.start()
        let (url, summary) = try await service.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(summary.sampleRate, 44_100)
        XCTAssertEqual(summary.channelCount, 1)
        XCTAssertTrue(summary.formatDescription.contains("1 声道"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTeardownFailureIsReportedAndCanBeRetried() async throws {
        let driver = FakeDriver(), service: SystemAudioCaptureService
        service = SystemAudioCaptureService(driver: driver)
        try await service.prepare(); driver.failStop = true
        do { try await service.cancel(); XCTFail("Must report teardown failure") } catch { }
        driver.failStop = false
        try await service.cancel()
        let state = await service.diagnostics()
        XCTAssertEqual(state["active"], "false")
    }
    @MainActor
    func testMultipleCompletedRecordingsAreRecoveredWithoutDeletion() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        for index in 1...2 {
            let service = SystemAudioCaptureService(driver: FakeDriver())
            try await service.prepare(); try await service.start()
            let (url, _) = try await service.stop()
            try fm.moveItem(at: url, to: directory.appendingPathComponent("recording-\(index).mp4"))
        }
        let invalid = directory.appendingPathComponent("recording-incomplete.mp4")
        try Data("incomplete".utf8).write(to: invalid)
        let model = RecorderViewModel()
        await model.recoverRecordings(in: directory)
        XCTAssertTrue(model.hasPendingRecording)
        XCTAssertEqual(model.recoveryCount, 2)
        let secondInstance = RecorderViewModel()
        await secondInstance.recoverRecordings(in: directory)
        XCTAssertEqual(secondInstance.recoveryCount, 0)
        XCTAssertFalse(model.canInstallUpdate)
        model.reset()
        XCTAssertTrue(model.hasPendingRecording)
        try await model.shutdownForTermination()
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    @MainActor
    func testLegacyCompletedAudioMigratesAndIncompleteAudioIsUntouched() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = root.appendingPathComponent("old"), destination = root.appendingPathComponent("new")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let service = SystemAudioCaptureService(driver: FakeDriver())
        try await service.prepare(); try await service.start()
        let (url, _) = try await service.stop()
        let oldURL = legacy.appendingPathComponent("recording-old.mp4")
        try fm.moveItem(at: url, to: oldURL)
        let broken = legacy.appendingPathComponent("recording-broken.mp4")
        try Data("unfinished".utf8).write(to: broken)
        let model = RecorderViewModel()
        await model.recoverRecordings(in: destination, legacyDirectory: legacy)
        XCTAssertEqual(model.recoveryCount, 1)
        guard case let .finished(recovered, _) = model.phase else { return XCTFail("Expected recovered audio") }
        XCTAssertEqual(recovered.deletingLastPathComponent().path, destination.path)
        XCTAssertTrue(fm.fileExists(atPath: recovered.path))
        XCTAssertFalse(fm.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try Data(contentsOf: broken), Data("unfinished".utf8))
    }

}
