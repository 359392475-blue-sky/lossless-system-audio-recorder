import AVFoundation
import Foundation

// Read-only audio validation. Does not request capture permission.
for path in CommandLine.arguments.dropFirst() {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var peak: Float = 0
    var count: Int64 = 0
    var sum: Double = 0
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<Int(buffer.frameLength) {
                let sample = channels[channel][index * buffer.stride]
                peak = max(peak, abs(sample)); sum += Double(sample * sample); count += 1
            }
        }
    }
    print("\(URL(fileURLWithPath: path).lastPathComponent): duration=\(Double(file.length) / format.sampleRate), sampleRate=\(format.sampleRate), channels=\(format.channelCount), peak=\(peak), rms=\(sqrt(sum / Double(max(1, count))))")
    if peak == 0 { fputs("ERROR: all decoded samples are silent\n", stderr); exit(1) }
}
