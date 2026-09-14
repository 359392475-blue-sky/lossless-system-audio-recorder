import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RecorderViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.14), Color(red: 0.11, green: 0.08, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                header
                statusCard
                controls
                footer
            }
            .padding(28)
        }
        .frame(width: 470, height: 430)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("无损系统录音机")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("只录 Mac 正在播放的声音")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(spacing: 13) {
            statusSymbol
                .frame(height: 70)

            Text(primaryStatus)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(secondaryStatus)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(minHeight: 38)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch model.phase {
        case let .countingDown(value):
            Text("\(value)")
                .font(.system(size: 60, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        case .recording, .exporting:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 70, height: 70)
                Circle()
                    .fill(Color.red)
                    .frame(width: 32, height: 32)
                if case .recording = model.phase {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 2)
                        .frame(width: 58, height: 58)
                }
            }
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62))
                .foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color.orange)
        case .preparing:
            ProgressView()
                .controlSize(.large)
                .scaleEffect(1.25)
        case .idle:
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .idle:
                primaryButton("开始录制", icon: "record.circle", tint: .purple, action: model.start)
            case .preparing:
                primaryButton("正在检查权限…", icon: "lock.shield", tint: .gray, action: {})
                    .disabled(true)
            case .countingDown:
                primaryButton("取消", icon: "xmark.circle", tint: .gray, action: model.cancelCountdown)
            case .recording:
                primaryButton("停止并导出", icon: "stop.fill", tint: .red, action: model.stop)
            case .exporting:
                primaryButton("正在生成 MP4…", icon: "square.and.arrow.down", tint: .gray, action: {})
                    .disabled(true)
            case let .finished(url, _):
                Button("在 Finder 中显示") { model.reveal(url) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    Button("再次导出") { model.exportAgain() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.purple)
                }
                Button("再次录制") { model.recordAgain() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.purple)
            case .failed:
                Button("打开权限设置") { model.openScreenRecordingSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("重新尝试") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.purple)
            }
        }
        .frame(minHeight: 40)
    }

    private func primaryButton(
        _ title: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint)
    }

    private var footer: some View {
        HStack {
            Label("MP4 · ALAC 无损 · 立体声", systemImage: "checkmark.seal")
            Spacer()
            Label("不录麦克风", systemImage: "mic.slash")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private var primaryStatus: String {
        switch model.phase {
        case .idle:
            return "准备就绪"
        case .preparing:
            return "准备录制"
        case .countingDown:
            return "即将开始"
        case .recording:
            return formatDuration(model.elapsedSeconds)
        case .exporting:
            return "正在收尾"
        case .finished:
            return "录音已完成"
        case .failed:
            return "没有完成录制"
        }
    }

    private var secondaryStatus: String {
        switch model.phase {
        case .idle:
            return "点开始后倒计时 3 秒。首次使用请允许系统音频录制。"
        case .preparing:
            return "正在向 macOS 请求系统音频采集权限"
        case .countingDown:
            return "倒计时结束后开始记录系统播放声音"
        case .recording:
            return "正在无损写入临时 MP4，点停止后选择导出位置"
        case .exporting:
            return "正在封装并验证 ALAC 音频轨道"
        case let .finished(url, summary):
            return "\(formatSize(summary.fileSize)) · \(url.lastPathComponent)"
        case let .failed(message):
            return message
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3_600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }

    private func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
