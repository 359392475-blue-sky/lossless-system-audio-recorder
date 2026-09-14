import AVFoundation
import Foundation

enum RecordingFile {
    static let sampleRate = 48_000
    static let channelCount = 2
    static let encoderBitDepth = 24

    static let alacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatAppleLossless,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channelCount,
        AVEncoderBitDepthHintKey: encoderBitDepth
    ]

    static func suggestedFilename(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "系统音频 %04d-%02d-%02d %02d.%02d.%02d.mp4",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    static func makeTemporaryURL(fileManager: FileManager = .default) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("LosslessSystemAudioRecorder", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("recording-\(UUID().uuidString).mp4")
    }

    static func validate(_ url: URL) async throws -> RecordingSummary {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw RecorderError.invalidOutput("导出的 MP4 中没有音频轨道。")
        }

        let formatDescriptions = try await track.load(.formatDescriptions)
        guard formatDescriptions.contains(where: {
            CMFormatDescriptionGetMediaSubType($0) == kAudioFormatAppleLossless
        }) else {
            throw RecorderError.invalidOutput("导出的音频轨道不是 Apple Lossless（ALAC）格式。")
        }

        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
            throw RecorderError.invalidOutput("导出的 MP4 没有有效时长。")
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw RecorderError.invalidOutput("导出的 MP4 是空文件。")
        }

        return RecordingSummary(duration: duration.seconds, fileSize: fileSize)
    }
}

struct RecordingSummary: Equatable {
    let duration: TimeInterval
    let fileSize: Int
}
