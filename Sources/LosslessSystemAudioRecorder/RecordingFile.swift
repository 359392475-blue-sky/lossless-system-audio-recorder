import AVFoundation
import Foundation
import Darwin

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
        let directory = try recoveryDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let owner = try processOwner.get()
        return directory.appendingPathComponent("recording-\(owner.token)-\(UUID().uuidString).mp4")
    }

    /// The kernel releases this advisory lock on process exit, including a
    /// crash. Identity is a random token, so PID reuse cannot hide old audio.
    private final class ProcessOwner {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let descriptor: Int32
        init() throws {
            let directory = try RecordingFile.recoveryDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent(".owner-\(token).lock").path
            descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw POSIXError(.EIO)
            }
        }
        deinit { close(descriptor) }
    }
    private static let processOwner: Result<ProcessOwner, Error> = Result { try ProcessOwner() }

    static func acquireRecoveryLock(_ url: URL) -> FileHandle? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            return nil
        }
        return handle
    }

    static func belongsToRunningProcess(_ url: URL) -> Bool {
        let components = url.lastPathComponent.split(separator: "-")
        guard components.count > 2, components[1].count == 32 else { return false }
        let marker = url.deletingLastPathComponent().appendingPathComponent(".owner-\(components[1]).lock")
        let descriptor = open(marker.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    static func recoveryDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true)
            .appendingPathComponent("LosslessSystemAudioRecorder", isDirectory: true)
    }

    /// Copy first, then commit with a same-directory atomic rename. Neither the
    /// recovery source nor an existing destination is removed on copy failure.
    static func export(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL
        let targetPath = destination.resolvingSymlinksInPath().standardizedFileURL
        let sourceAttributes = try fm.attributesOfItem(atPath: sourcePath.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw RecorderError.invalidOutput("录音源文件不是普通文件。")
        }
        if sourcePath == targetPath {
            throw RecorderError.invalidOutput("请选择录音保留目录以外的导出位置。")
        }
        if fm.fileExists(atPath: destination.path) {
            let attributes = try fm.attributesOfItem(atPath: targetPath.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw RecorderError.invalidOutput("不能用录音替换文件夹，请选择文件名。")
            }
            if attributes[.systemNumber] as? NSNumber == sourceAttributes[.systemNumber] as? NSNumber,
               attributes[.systemFileNumber] as? NSNumber == sourceAttributes[.systemFileNumber] as? NSNumber {
                throw RecorderError.invalidOutput("目标与录音源是同一个文件，请选择其他位置。")
            }
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".recorder-export-\(UUID().uuidString).mp4")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func validate(_ url: URL) async throws -> RecordingSummary {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw RecorderError.invalidOutput("导出的 MP4 中没有音频轨道。")
        }

        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let description = formatDescriptions.first(where: {
            CMFormatDescriptionGetMediaSubType($0) == kAudioFormatAppleLossless
        }), let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
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

        return RecordingSummary(duration: duration.seconds, fileSize: fileSize,
                                sampleRate: format.mSampleRate, channelCount: Int(format.mChannelsPerFrame))
    }
}

struct RecordingSummary: Equatable {
    let duration: TimeInterval
    let fileSize: Int
    var sampleRate: Double = 0
    var channelCount: Int = 0

    var formatDescription: String {
        guard sampleRate > 0, channelCount > 0 else { return "ALAC 无损" }
        return "ALAC · \(sampleRate / 1_000) kHz · \(channelCount) 声道"
    }
}
