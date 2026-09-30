import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RecorderViewModel
    @State private var dismissedPolicySequence: Int?

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
                policyNotice
                ReferralPanel(coordinator: model.referrals)
                footer
            }
            .padding(28)
        }
        .frame(width: 470)
        .frame(minHeight: 430)
        .preferredColorScheme(.dark)
        .task { await model.recoverRecordings(); await model.refreshPolicy() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshPolicy() }
        }
    }

    @ViewBuilder
    private var policyNotice: some View {
        if model.checkingPolicy {
            HStack { ProgressView().controlSize(.small); Text("正在联网验证版本…").font(.caption) }
        }
        if let error = model.policyError {
            VStack(spacing: 8) {
                Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                Button("重新验证") { Task { await model.refreshPolicy() } }
            }
        }
        if let policy = model.policy, policy.level > 0,
           policy.level >= 3 || dismissedPolicySequence != policy.sequence {
            VStack(alignment: .leading, spacing: 8) {
                Text(policy.title).font(policy.level >= 2 ? .headline : .subheadline)
                Text(policy.message).font(.caption)
                if policy.level == 3 {
                    Text("旧版本使用期限：" + Date(timeIntervalSince1970: Double(policy.effectiveAt)).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                }
                if policy.blocksRecording(at: Date()) {
                    Text("需升级后才能开始新录音；已有录音可以保存。").font(.caption).bold()
                }
                HStack {
                    Button("下载升级版本") { model.openPolicyDownload() }
                    if policy.level <= 2 {
                        Button("暂不提醒") { dismissedPolicySequence = policy.sequence }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background((policy.level >= 2 ? Color.orange : Color.blue).opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        }
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
                primaryButton(model.updateInProgress ? "正在准备更新…" : "开始录制", icon: "record.circle", tint: .purple, action: model.start)
                    .disabled(model.updateInProgress)
            case .preparing:
                primaryButton(model.checkingPolicy ? "正在联网验证…" : "正在检查权限…", icon: "lock.shield", tint: .gray, action: {})
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
                if model.hasPendingRecording {
                    Button("再次导出") { model.exportAgain() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.purple)
                }
                Button(model.updateInProgress ? "更新待安装" : "再次录制") { model.recordAgain() }
                    .disabled(model.updateInProgress)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.purple)
            case .failed:
                if model.hasPendingRecording { Button("再次导出") { model.exportAgain() } }
                if !model.hasPendingRecording, model.policyError == nil {
                    Button("打开权限设置") { model.openScreenRecordingSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button(model.updateInProgress ? "更新待安装" : (model.hasPendingRecording ? "再次录制" : "重新尝试")) { model.recordAgain() }
                    .disabled(model.updateInProgress)
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
            Label("MP4 · ALAC 无损", systemImage: "checkmark.seal")
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
            return model.hasPendingRecording ? "录音已保留，导出未完成" : "没有完成录制"
        }
    }

    private var secondaryStatus: String {
        switch model.phase {
        case .idle:
            return "每次录音需要联网验证版本，再倒计时 3 秒。首次使用请允许系统音频录制。"
        case .preparing:
            return model.checkingPolicy ? "每次录制都需要在线验证当前版本" : "正在向 macOS 请求系统音频采集权限"
        case .countingDown:
            return "倒计时结束后开始记录系统播放声音"
        case .recording:
            return "正在无损写入临时 MP4，点停止后选择导出位置"
        case .exporting:
            return "正在封装并验证 ALAC 音频轨道"
        case let .finished(url, summary):
            return "\(summary.formatDescription) · \(formatSize(summary.fileSize))\n\(model.hasPendingRecording ? "尚未导出，已保留" : url.lastPathComponent)\(model.recoveryCount > 1 ? " · 待保存 \(model.recoveryCount) 段" : "")"
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


private struct ReferralPanel: View {
    @ObservedObject var coordinator: ReferralCoordinator
    @State private var activationTicket = ""
    @State private var showActivation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let status = coordinator.status {
                HStack {
                    Image(systemName: status.unlocked ? "gift.fill" : "person.2.fill")
                    Text(status.unlocked ? "\(status.series) 系列已解锁无限免费" : "邀请 2 位好友，解锁当前系列无限免费")
                        .font(.subheadline.bold())
                }
                if status.unlocked {
                    Text("同系列修复版继承免费权益；仍需联网验证版本。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("有效邀请 \(min(status.qualifiedCount, status.requiredCount))/\(status.requiredCount) · 剩余试用 \(max(0, status.freeLimit - status.usedTrials - status.reservedTrials)) 次")
                        .font(.caption)
                    Text("好友通过链接下载、激活并完成首次录音才计入。取消或失败不扣次。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("复制邀请链接", action: coordinator.copyShareLink)
                    Button("刷新进度") { Task { await coordinator.refresh() } }
                        .disabled(coordinator.checking)
                    Spacer()
                    Button("激活邀请") { showActivation.toggle() }
                }
            } else {
                HStack {
                    Text("免登录试用 5 次，邀请 2 位好友解锁无限免费").font(.caption)
                    Spacer()
                    Button("重试") { Task { await coordinator.refresh() } }
                        .disabled(coordinator.checking)
                }
                Button("已有邀请激活码") { showActivation.toggle() }
            }
            if showActivation {
                HStack {
                    TextField("粘贴邀请页面上的激活码", text: $activationTicket)
                        .textFieldStyle(.roundedBorder)
                    Button("关联") {
                        Task { await coordinator.claim(activationTicket.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }.disabled(coordinator.checking || activationTicket.isEmpty)
                }
            }
            Button("复制排查信息", action: coordinator.copySupportInfo).font(.caption)
            if coordinator.checking { ProgressView().controlSize(.small) }
            if let message = coordinator.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .task { await coordinator.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await coordinator.refresh() }
        }
    }
}
