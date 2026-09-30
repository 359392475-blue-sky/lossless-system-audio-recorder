import XCTest
@testable import LosslessSystemAudioRecorder

final class UpdateSafetyTests: XCTestCase {
    func testMissingOrInvalidConfigurationRemainsOffline() {
        XCTAssertNil(UpdateConfiguration(info: [:]))
        XCTAssertNil(UpdateConfiguration(info: ["SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUFeedURL": "https://example.invalid/feed.xml#fragment", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]))
        XCTAssertNil(UpdateConfiguration(info: ["SUFeedURL": "https://example.invalid/feed.xml", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]))
        XCTAssertNil(UpdateConfiguration(info: ["SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUFeedURL": "https://example.invalid/feed.xml"]))
        XCTAssertNil(UpdateConfiguration(info: ["SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUFeedURL": "http://example.invalid/feed.xml", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]))
        XCTAssertNil(UpdateConfiguration(info: ["SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUFeedURL": "https://example.invalid/feed.xml", "SUPublicEDKey": "placeholder"]))
        XCTAssertNotNil(UpdateConfiguration(info: ["SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUFeedURL": "https://example.invalid/feed.xml", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]))
    }

    @MainActor
    func testEveryActiveCapturePhaseBlocksUpdate() {
        let phases: [RecorderViewModel.Phase] = [.preparing, .countingDown(3), .countingDown(1), .recording, .exporting]
        for phase in phases {
            XCTAssertFalse(RecorderViewModel.permitsUpdate(phase: phase, hasPendingRecording: false))
        }
        XCTAssertFalse(RecorderViewModel.permitsUpdate(phase: .finished(URL(fileURLWithPath: "/tmp/test.mp4"), RecordingSummary(duration: 1, fileSize: 1)), hasPendingRecording: true))
        XCTAssertTrue(RecorderViewModel.permitsUpdate(phase: .idle, hasPendingRecording: false))
        XCTAssertTrue(RecorderViewModel.permitsUpdate(phase: .failed("test"), hasPendingRecording: false))
        XCTAssertFalse(RecorderViewModel.permitsUpdate(phase: .idle, hasPendingRecording: true))
        XCTAssertFalse(RecorderViewModel.permitsUpdate(phase: .failed("export failed"), hasPendingRecording: true))
    }

    @MainActor
    func testStagedUpdateExitGatePreservesOrdinaryQuitAndBlocksActiveCapture() {
        let model = RecorderViewModel()
        let updates = UpdateService()
        let delegate = AppDelegate()
        delegate.model = model
        delegate.updates = updates
        updates.model = model
        model.start() // Synchronously enters preparing; no permission request before this test returns.
        XCTAssertFalse(delegate.shouldBlockUpdateTermination)
        updates.markInstallationPending()
        XCTAssertTrue(delegate.shouldBlockUpdateTermination)
        model.reset()
        XCTAssertFalse(delegate.shouldBlockUpdateTermination)
    }

    @MainActor
    func testFailedUpdateRestoresRecordingAndOrdinaryQuit() {
        let model = RecorderViewModel()
        let updates = UpdateService()
        let delegate = AppDelegate()
        delegate.model = model
        delegate.updates = updates
        updates.model = model
        updates.markInstallationPending()
        XCTAssertTrue(model.updateInProgress)
        updates.finishUpdateCycle(error: NSError(domain: "Test", code: 1))
        XCTAssertFalse(updates.installationPending)
        XCTAssertFalse(model.updateInProgress)
        model.start()
        XCTAssertEqual(model.phase, .preparing)
        XCTAssertFalse(delegate.shouldBlockUpdateTermination)
        model.reset()
    }

    @MainActor
    func testUpdateCycleCannotStartRecording() {
        let model = RecorderViewModel()
        model.updateInProgress = true
        model.start()
        XCTAssertEqual(model.phase, .idle)
        model.recordAgain()
        XCTAssertEqual(model.phase, .idle)
    }
}
