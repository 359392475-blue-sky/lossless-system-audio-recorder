@preconcurrency import AVFoundation
import CoreAudio
import Foundation

enum RecorderError: LocalizedError {
    case noAudioReceived
    case writerStartFailed(String)
    case writerAppendFailed(String)
    case invalidOutput(String)
    case captureFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAudioReceived: return "没有收到系统音频。请检查系统音频录制权限，并确认 Mac 正在播放声音。"
        case let .writerStartFailed(message): return "无法创建无损 MP4：\(message)"
        case let .writerAppendFailed(message): return "录音写入中断：\(message)"
        case let .invalidOutput(message): return message
        case let .captureFailed(operation, status):
            return "\(operation)失败（\(status)）。请检查系统音频录制权限后重试。"
        }
    }
}

/// An actor owns the complete lifecycle. No start/stop/cancel operation can
/// interleave with a partially constructed tap or aggregate device.
actor SystemAudioCaptureService {
    private let driver: any AudioCaptureDriver
    private var sink: AudioSampleWriter?

    init(driver: any AudioCaptureDriver = CoreAudioTapDriver()) {
        self.driver = driver
    }

    func prepare() throws {
        try driver.prepare()
    }

    func start() throws {
        try Task.checkCancellation()
        do {
            let sink = try AudioSampleWriter(format: driver.format)
            self.sink = sink
            try driver.start { [weak sink] buffers in sink?.append(buffers) }
            try Task.checkCancellation()
        } catch {
            try driver.stop()
            sink?.discard()
            sink = nil
            throw error
        }
    }

    func stop() async throws -> (URL, RecordingSummary) {
        // This is synchronous and serialized; capture is gone BEFORE encoding
        // finishes or a save dialog appears.
        try driver.stop()
        guard let sink else { throw RecorderError.noAudioReceived }
        self.sink = nil
        let url = try await sink.finish()
        return (url, try await RecordingFile.validate(url))
    }

    func cancel() throws {
        try driver.stop()
        sink?.discard()
        sink = nil
    }

    func diagnostics() -> [String: String] { driver.diagnostics }
}

/// Called only on the driver's serial audio queue. stop() drains that queue
/// before finish/discard is called, so buffers cannot race writer teardown.
final class AudioSampleWriter: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: AudioStreamBasicDescription
    private let description: CMAudioFormatDescription
    private var frames: Int64 = 0
    private var failure: Error?

    init(format: AudioStreamBasicDescription) throws {
        self.format = format
        var asbd = format
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw RecorderError.captureFailed("读取音频格式", status)
        }
        self.description = description
        url = try RecordingFile.makeTemporaryURL()
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var settings = RecordingFile.alacSettings
        settings[AVSampleRateKey] = format.mSampleRate
        settings[AVNumberOfChannelsKey] = Int(format.mChannelsPerFrame)
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw RecorderError.writerStartFailed("音频设备的格式不能编码为 ALAC。")
        }
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings,
                                   sourceFormatHint: description)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerStartFailed("无法添加音频轨道。") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerStartFailed(writer.error?.localizedDescription ?? "未知错误")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ buffers: UnsafePointer<AudioBufferList>) {
        guard failure == nil, format.mBytesPerFrame > 0 else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard let first = list.first, first.mData != nil else { return }
        let count = Int(first.mDataByteSize / format.mBytesPerFrame)
        guard count > 0 else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.mSampleRate)),
            presentationTimeStamp: CMTime(value: frames, timescale: CMTimeScale(format.mSampleRate)),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            failure = RecorderError.captureFailed("创建音频缓冲", status); return
        }
        // CoreMedia copies the tap's borrowed buffers; they never escape the IO callback.
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sample,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffers)
        guard status == noErr else {
            failure = RecorderError.captureFailed("复制音频缓冲", status); return
        }
        CMSampleBufferSetDataReady(sample)
        guard input.isReadyForMoreMediaData, input.append(sample) else {
            failure = RecorderError.writerAppendFailed(writer.error?.localizedDescription ?? "磁盘写入跟不上录音，已停止接收以避免静默丢帧。")
            return
        }
        frames += Int64(count)
    }

    func finish() async throws -> URL {
        if let failure { discard(); throw failure }
        guard frames > 0 else { discard(); throw RecorderError.noAudioReceived }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            let error = RecorderError.writerAppendFailed(writer.error?.localizedDescription ?? "封装失败")
            discard(); throw error
        }
        return url
    }

    func discard() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
