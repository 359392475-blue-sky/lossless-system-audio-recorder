@preconcurrency import CoreAudio
import Foundation

protocol AudioCaptureDriver: AnyObject, Sendable {
    var format: AudioStreamBasicDescription { get }
    var diagnostics: [String: String] { get }
    func prepare() throws
    func start(receive: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void) throws
    func stop() throws
}

/// Owned exclusively by SystemAudioCaptureService. IO only touches its writer.
final class CoreAudioTapDriver: AudioCaptureDriver, @unchecked Sendable {
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var device: AudioObjectID = kAudioObjectUnknown
    private var io: AudioDeviceIOProcID?
    private var running = false
    private let audioQueue = DispatchQueue(label: "app.lowpower.recorder.audio")
    private(set) var format = AudioStreamBasicDescription()

    var diagnostics: [String: String] {
        ["backend": "CoreAudioProcessTap", "tap": String(tap),
         "device": String(device), "io": io == nil ? "none" : "allocated",
         "running": String(running), "sampleRate": String(format.mSampleRate)]
    }

    func prepare() throws {
        try stop()
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "无损系统录音机"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "创建系统音频采集")
            var property = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format), "读取采集格式")
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Lossless Recorder Private Input",
                kAudioAggregateDeviceUIDKey: "app.lowpower.recorder.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "创建录音输入")
        } catch {
            try stop()
            throw error
        }
    }

    func start(receive: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void) throws {
        guard tap != kAudioObjectUnknown, device != kAudioObjectUnknown, io == nil else {
            throw RecorderError.invalidOutput("录音设备未准备好或已开始录制。")
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, audioQueue) {
            _, input, _, _, _ in receive(input)
        }, "注册音频回调")
        try check(AudioDeviceStart(device, io), "开始系统音频录制")
        running = true
    }

    func stop() throws {
        // Attempt every teardown step even when an earlier call fails. Handles
        // remain owned until their corresponding destruction actually succeeds.
        var firstError: Error?
        func record(_ status: OSStatus, _ operation: String) -> Bool {
            guard status == noErr else {
                if firstError == nil { firstError = RecorderError.captureFailed(operation, status) }
                return false
            }
            return true
        }
        if device != kAudioObjectUnknown, let io {
            if running, record(AudioDeviceStop(device, io), "停止音频设备") { running = false }
            if record(AudioDeviceDestroyIOProcID(device, io), "移除音频回调") { self.io = nil }
        }
        if device != kAudioObjectUnknown,
           record(AudioHardwareDestroyAggregateDevice(device), "释放录音输入") {
            device = kAudioObjectUnknown; io = nil; running = false
        }
        if tap != kAudioObjectUnknown,
           record(AudioHardwareDestroyProcessTap(tap), "释放系统音频采集") {
            tap = kAudioObjectUnknown
        }
        audioQueue.sync { }
        if let firstError { throw firstError }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw RecorderError.captureFailed(operation, status) }
    }

    deinit { try? stop() }
}
