# 无损系统录音机

原生 macOS 小工具：点击开始，倒计时 3 秒，只录制 Mac 正在播放的系统声音。点击停止后，导出带 Apple Lossless（ALAC）音轨的 MP4。

3.2 正在准备发布 · [发布记录](https://github.com/359392475-blue-sky/lossless-system-audio-recorder/releases) · [个人作品集](https://lowpower.me/#lossless-recorder)

## 使用

1. 下载 ZIP，解压后把「无损系统录音机.app」拖到 Applications。
2. 点「开始录制」，首次使用允许 macOS 请求的系统音频录制权限。
3. 倒计时 3 秒后开始录制。点「停止并导出」选择 MP4 保存位置。
4. 点「再次录制」开始下一段。取消保存面板后可用「再次导出」保存临时录音。

关闭最后一个窗口或按 ⌘Q，会先停止录音、销毁设备再退出。录制中直接关闭会放弃当前未导出的片段；需要保留时请先点「停止并导出」。保存面板出现之前，采集已经停止。

## 格式与隐私

- macOS **14.2+**；发布包为 Apple Silicon / Intel 通用版。本机实测为 Apple Silicon，Intel 未做硬件验收。
- Apple Core Audio process tap（进程音频采集）；没有屏幕采集会话、麦克风输入或第三方音频驱动。
- 私有聚合设备仅包含音频 tap，不添加物理输入设备，也不更改系统默认播放设备。
- MP4、ALAC、立体声，保留 tap 的采样率（常见 48 kHz），24-bit 编码提示。
- “无损”指不会再次使用 AAC/MP3 等有损压缩。系统混音、浮点转整数及音源原有压缩不能还原，不承诺与播放器源文件逐字节一致。
- 音频本地处理，无账号或音频上传。**每次开始录音必须联网验证版本**；断网、验证失败或版本被停用时不能新建录音，已录内容仍可保存。关闭可选的 Sparkle 自动更新检查不关闭版本验证。详见 [隐私与下载统计](docs/privacy.md)。
- 更新需用户确认安装；录音、导出及有未保存录音时不允许更新。安装准备期间暂不能开始新录音，检查网络期间仍可录音。详见 [自动更新接入与发布边界](docs/auto-update.md)。
- 系统设置可能把仅音频录制归在「屏幕与系统音频录制」分类；无需开启麦克风。其他应用/验收工具录屏时仍可能出现共享指示。

## 邀请解锁（3.2）

无需账号，先免费成功录音 **5 次**。复制应用内邀请链接；两位新设备用户通过链接下载、安装后点击“打开应用并激活”，再成功完成首次录音，你的 **3.2 系列**即可无限次免费使用。同系列修复版继承权益，仍需联网验证且保留最高档强制升级。取消倒计时、失败不扣次，重复导出不重复扣次。

服务端下载完成与设备首次使用须同时满足，单点链接不发奖励；同一设备、自邀和重复激活不重复计数。详见 [邀请机制与验收边界](docs/referral-unlock.md)。当前是代码实现，正式活动尚未上线。

## 构建

需要 Xcode / Swift 5.10+，以及提供 Core Audio tap API 的 macOS SDK。

```sh
swift test
npm --prefix server test
python3 scripts/test_release_configuration.py
python3 scripts/test_build_path_mapping.py
# 先按 docs/auto-update.md 设置全部四项正式配置
./scripts/build-app.sh
# Intel / Apple Silicon 双架构
LOSSLESS_RECORDER_UNIVERSAL=1 ./scripts/build-app.sh
```

隔离验收可用 `LOSSLESS_RECORDER_SCRATCH_DIR=/tmp/recorder-build LOSSLESS_RECORDER_OUTPUT_DIR=/tmp/recorder-app ./scripts/build-app.sh`，输出目录应为空，避免覆盖旧包。

构建脚本会把 Swift 调试信息中的本机源码／构建路径映射为稳定的 `/source/LosslessSystemAudioRecorder`、`/build/LosslessSystemAudioRecorder` 前缀，并启用 `ConciseMagicFile`，让运行时默认的 `#file` 只包含模块和文件名。显式 `#filePath` 保留原语义，因此产品源码应避免把它带入发布包。不改动已签名的旧安装包。

默认产物：`dist/无损系统录音机.app`。脚本使用钥匙串中可用的签名身份，也可通过 `LOSSLESS_RECORDER_SIGNING_IDENTITY` 指定。没有证书时使用本地临时签名；公开下载使用 Developer ID 签名、公证的发布包。

## 验收

单元测试覆盖启动失败清理、重复取消、释放失败重试及真实 ALAC 编码，不申请系统权限。以下命令会主动录制三段各约 3 秒的系统音频并退出，需要授权：

```sh
open 'dist/无损系统录音机.app' --args --verify-capture /tmp/recorder-check
swift scripts/check-audio.swift /tmp/recorder-check/*.mp4
```

检查 `result.json` 每轮 stopped 为 `tap=0`、`device=0`、`io=none`、`running=false`，同时确认进程退出。录音仅留在指定目录，不上传。

人工覆盖：开始、取消倒计时、停止导出、再次录制、录制中关闭窗口、⌘Q。蓝牙、多通道设备、最低系统及录制中切换设备尚未逐一验证。

## 3.0 修复

移除屏幕共享框架，改用串行管理的 Core Audio 资源；修复 `terminateLater` 嵌套事件循环让主线程清理任务无法运行的问题。[诊断与验收](docs/3.0-lifecycle-fix.md)。

参考：[Apple — Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)。

3.1 起采用 [自有软件使用许可](LICENSE)，支持未来商业化；历史 MIT 授权不追溯撤销。图标由 `scripts/generate-icon.swift` 原生绘制，无外部图片；应用内更新依赖 Sparkle 2.9.6（随应用捆绑，保留其许可证）。

## 发布与运营

当前开发版本 3.2.0（build 6）。[五档升级策略](docs/auto-update.md) · [策略服务与下载统计](docs/server-operations.md) · [明日发布准备检查](docs/release-readiness-2026-09-15.md)。正式发布使用 `scripts/prepare-release.sh`，必须配置真实 HTTPS 服务、签名密钥和公证钥匙串配置；源码测试通过不表示已经上线。
