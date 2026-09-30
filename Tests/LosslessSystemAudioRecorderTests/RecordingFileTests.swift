import AVFoundation
import XCTest
import Darwin
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
        XCTAssertTrue(RecordingFile.belongsToRunningProcess(url))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "LosslessSystemAudioRecorder")
    }

    func testAtomicExportPreservesSourceAndReplacesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), target = root.appendingPathComponent("target.mp4")
        try Data("new audio".utf8).write(to: source)
        try Data("old audio".utf8).write(to: target)
        try RecordingFile.export(source, to: target)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: target))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testExportRejectsSameFileHardlinkAndDirectoryWithoutLoss() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), link = root.appendingPathComponent("link.mp4")
        let bytes = Data("precious audio".utf8)
        try bytes.write(to: source)
        try fm.linkItem(at: source, to: link)
        XCTAssertThrowsError(try RecordingFile.export(source, to: source))
        XCTAssertThrowsError(try RecordingFile.export(source, to: link))
        XCTAssertThrowsError(try RecordingFile.export(source, to: root))
        XCTAssertThrowsError(try RecordingFile.export(source, to: root.appendingPathComponent("missing/target.mp4")))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: link), bytes)
        XCTAssertThrowsError(try RecordingFile.export(root.appendingPathComponent("missing.mp4"), to: source))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testRecoveryOwnerUsesReleasedLockRatherThanReusedPID() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let marker = root.appendingPathComponent(".owner-\(token).lock")
        let recording = root.appendingPathComponent("recording-\(token)-test.mp4")
        let descriptor = open(marker.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(RecordingFile.belongsToRunningProcess(recording))
        close(descriptor)
        XCTAssertFalse(RecordingFile.belongsToRunningProcess(recording))
        let oldPIDName = root.appendingPathComponent("recording-\(ProcessInfo.processInfo.processIdentifier)-old.mp4")
        XCTAssertFalse(RecordingFile.belongsToRunningProcess(oldPIDName))
    }

}
