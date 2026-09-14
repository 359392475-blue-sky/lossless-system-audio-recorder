import AVFoundation
import XCTest
@testable import LosslessSystemAudioRecorder

final class RecordingFileTests: XCTestCase {
    func testSuggestedFilenameIsStableAndUsesMP4Extension() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 14,
            hour: 12,
            minute: 34,
            second: 56
        )))

        XCTAssertEqual(
            RecordingFile.suggestedFilename(at: date, calendar: calendar),
            "系统音频 2026-09-14 12.34.56.mp4"
        )
    }

    func testALACSettingsAreAcceptedByMP4Writer() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alac-capability-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        XCTAssertTrue(writer.canApply(outputSettings: RecordingFile.alacSettings, forMediaType: .audio))

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingFile.alacSettings)
        XCTAssertTrue(writer.canAdd(input))
    }

    func testTemporaryURLUsesPrivateRecorderDirectory() throws {
        let url = try RecordingFile.makeTemporaryURL()
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "LosslessSystemAudioRecorder")
    }

}
