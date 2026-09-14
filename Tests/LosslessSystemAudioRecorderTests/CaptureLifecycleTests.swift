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
                mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
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
}
