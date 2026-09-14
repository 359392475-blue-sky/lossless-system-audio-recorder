# macOS 系统音频录音器竞品调研

> 调研日期：2026-09-14  
> 用途：供「无损系统录音机」新项目立项、产品定位、竞品分析和发布准备复用。  
> 边界：本文是公开信息调研与当前本机实现的对比，不等于已安装、实测所有竞品。价格、系统要求和功能可能随时间变化，立项决策前应重新核对官网。

## 一、结论

「录制 Mac 系统声音」不是新品类，市场上已有三代方案：

1. 虚拟声卡与手动路由：BlackHole、Soundflower、Loopback 等。
2. 成熟专业录音产品：Audio Hijack、Piezo 等。
3. 使用 Apple 现代音频捕获 API 的轻量工具：Home Rec、AppTape、Soundshine Record、AirCheck、Slop Audio Recorder 等。

当前「无损系统录音机」的单项能力都已有竞品覆盖，不应宣传为「首个」或「独家技术」。仍可成立的组合定位是：

> 免费开源、只录系统声音、不含麦克风采集路径、无屏幕捕获会话、无第三方驱动、无网络上传，并可验证最终 ALAC 音轨的 Mac 录音工具。

最值得强化的不是麦克风、转写、音频库等常规功能，而是「可验证无损」和「最小隐私边界」。

## 二、当前产品事实

以本机当前实现和 README 为准：

- 最低系统：macOS 14.2。
- 捕获技术：Apple Core Audio process tap（进程音频采集）。
- 不使用 ScreenCaptureKit 屏幕捕获会话。
- 不录制麦克风，不向私有聚合设备添加物理输入设备。
- 不安装第三方虚拟音频驱动，不修改默认播放设备。
- 导出：MP4 容器、ALAC 无损立体声音轨；保留 tap 采样率，常见为 48 kHz。
- 交互：开始前 3 秒倒计时，停止后选择保存位置。
- 隐私：本地处理，无账号、无遥测、无网络上传、无后台驻留、无自动更新。
- 分发：MIT 开源；公开包使用 Developer ID 签名并经 Apple 公证；生成 Intel / Apple Silicon 通用包，但 Intel 尚无真机验收。
- 已有测试：真实 ALAC 编码，开始失败清理，重复取消，释放失败重试，tap / device / IO 资源销毁。

源码事实入口：

- `README.md`
- `docs/3.0-lifecycle-fix.md`
- `<local-project>/LosslessSystemAudioRecorder`

## 三、核心竞品

### 1. Home Rec

- 官网：https://homerec.app/
- 源码：https://github.com/melissa-pereira-deel/home-rec
- 定位：免费开源的一键 Mac 系统音频录音器。
- 技术：SwiftUI + ScreenCaptureKit，无虚拟声卡。
- 系统：macOS 15+，Intel / Apple Silicon。
- 格式：WAV、FLAC（无损）和 M4A / AAC（有损）。
- 功能：全系统、单 App、麦克风；菜单栏、波形、可选目录、中断文件恢复、诊断导出、自动更新。
- 分发：免费、Apache 2.0 开源、签名公证 DMG。
- 判断：当前最强的直接竞品之一；功能完整度和英文产品表达已明显超过当前版。它的捕获路径和 M4A 编码与本项目不同。

### 2. AppTape

- 官网：https://apptape.alltuner.com/
- 定位：选择一个 App 或全系统，一键录制。
- 系统：macOS 26+。
- 格式：MP3、AAC、ALAC、WAV。
- 隐私：本地处理，无账号、无分析、无网络；宣称只录音频，不录屏幕、相机或麦克风。
- 价格：免费试用每段 1 分钟；14.99 美元一次性解锁。
- 判断：ALAC、本地、无麦克风的卖点与本项目高度重合；本项目的优势是免费开源和更低的系统要求。

### 3. Slop Audio Recorder

- 源码：https://github.com/meigo/slop-audio-recorder
- 定位：小型 macOS 菜单栏系统音频录音器。
- 技术：Core Audio process tap，无 BlackHole / Loopback / 虚拟声卡。
- 系统：macOS 14.4+。
- 格式：M4A；公开说明未明确指出是 AAC 还是 ALAC。
- 功能：菜单栏录制、Finder 文件入口、波形剪辑、头部无界面定时录音模式。
- 分发：MIT 开源；调研时页面未显示正式 Releases。
- 判断：当前最接近的开源技术同类；本项目的已签名公证可下载应用和显式 ALAC 验证更完整。

### 4. Soundshine Record

- 官网：https://www.soundshine.app/record/
- 技术：Core Audio process taps，无驱动。
- 系统：macOS 15+。
- 来源：全系统、单 App、麦克风，可混合成一个文件。
- 格式：AAC、WAV、AIFF，48 kHz 立体声。
- 功能：每来源音量、电平表、监听。
- 价格：14.99 美元一次性买断；试用录音每 30 秒插入提示音。
- 判断：证明 Core Audio tap + 无驱动已经是商品化路线；它选择「多来源混音」，本项目可选择反向的「只有系统声音」边界。

### 5. AirCheck

- 官网：https://aircheckaudio.com/
- 定位：一键录制 Mac 系统声音和 Core Audio 输入设备。
- 技术：系统音频使用 ScreenCaptureKit，无虚拟声卡。
- 系统：macOS 14+，官网规格栏标注 Apple Silicon。
- 格式：WAV 16-bit PCM 或 MP3 320 kbps；内部以 24-bit 捕获后转换。
- 功能：无时长限制、中断检测和同文件恢复、文件库、多通道输入选择。
- 价格：39 美元一次性付费。
- 判断：针对长时录音和音乐用户，可靠性叙事强；本项目的相对优势是 ALAC、开源、Core Audio tap 和不含任何麦克风路径。

### 6. System Audio Recorder

- App Store：https://apps.apple.com/us/app/system-audio-recorder/id6444844662?mt=12
- 定位：直接录制 Mac 上任何网站或 App 正在播放的声音。
- 系统：macOS 13+。
- 格式：M4A，公开页面未宣称 ALAC。
- 功能：不需要附加插件，内置裁剪，提供包括简体中文在内的多语言。
- 价格：7.99 美元。
- 判断：证明「极简系统录音」早已有 App Store 产品；本项目不能仅以「一键录制」作为差异点。

### 7. Piezo

- 官网：https://rogueamoeba.com/piezo/
- 定位：选择一个 App 或音频输入设备，简单录音。
- 系统：macOS 14.4 至 27（调研时官网数据）。
- 功能：单 App、麦克风和设备；音质预设、录音命名与注释。
- 价格：29 美元。
- 判断：「轻量、简单、好看」路线的老牌对手。

### 8. Audio Hijack

- 官网：https://www.rogueamoeba.com/audiohijack/
- 定位：专业级 Mac 音频捕获、处理、混音和直播工作台。
- 来源：单 App、全系统、麦克风、混音器等。
- 格式：MP3、AAC、AIFF、WAV、ALAC、FLAC 等。
- 附加能力：效果、路由、播客、VoIP、直播、广播、本地转写。
- 价格：69 美元。
- 判断：不是同一复杂度级别，但它覆盖了几乎所有录音需求。本项目不应在功能数量上与其竞争。

### 9. BlackHole

- 官网：https://existential.audio/blackhole/
- 类型：开源 macOS 虚拟音频 loopback 驱动，本身不是录音器。
- 用法：创建 Multi-Output Device（多输出设备），将系统输出同时送往扬声器和 BlackHole，再用 DAW、Audacity、OBS 或其他软件录制。
- 优点：免费开源，可灵活路由，支持多种采样率和通道数。
- 缺点：需安装驱动、修改输出设备和手动配置，容易给普通用户带来「没声音」或忘记切回设备的问题。
- 判断：它是本项目最重要的「麻烦替代方案」，但不是界面产品的直接竞品。

## 四、技术背景

Apple 在现代 macOS 中提供两条主要原生捕获路径：

### ScreenCaptureKit

- 可同时处理屏幕和音频捕获。
- Home Rec、AirCheck 等轻量录音器使用该路径。
- 即使只捕获音频，系统权限文案仍可能提及屏幕录制，容易让普通用户误解。

### Core Audio process taps

- Apple 官方文档：https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- `AudioHardwareCreateProcessTap` 在 macOS 14.2+ 可用。
- 可从一个或一组进程捕获输出音频，并将 tap 放入聚合音频设备中读取。
- 当前项目、Slop Audio Recorder、Soundshine Record 使用该路径。
- 它不是本项目独有技术，但能支持「不建立屏幕捕获会话」的更窄隐私边界。

## 五、竞争位置

### 当前已有优势

1. 免费开源，同时提供签名公证的安装包。
2. 最低 macOS 14.2，比 Home Rec / Soundshine 的 macOS 15 和 AppTape 的 macOS 26 覆盖更早系统。
3. 明确固定为 ALAC，不再使用 AAC / MP3 有损压缩。
4. 代码范围中不存在麦克风捕获用户路径。
5. 无 ScreenCaptureKit 屏幕捕获会话。
6. 无账号、遥测、网络上传、后台驻留或自动更新。
7. 已将「生成的文件是否真为 ALAC」和「tap / device / IO 是否释放」纳入自动验证。
8. 简体中文产品文案与权限说明。

### 当前明显短板

1. 只能录全系统声音，不能选择单个 App。
2. 无菜单栏快速操作、全局快捷键、暂停 / 恢复、波形、音量表、文件历史和剪辑。
3. 用户得到的是仅含音频轨的 `.mp4`，市场更熟悉 `.m4a`、`.wav` 或 `.flac`；需要验证文件后缀和容器选择是否增加理解成本。
4. 没有独立中英文产品页，当前入口是中文作品集中的一张项目卡。
5. 尚无 App Store 分发。
6. 当前 GitHub 公开仓库刚建立，缺少用户、Star、Issue 和第三方反馈。
7. 虽然构建了 Intel / Apple Silicon 通用包，但 Intel 尚无真机验收。
8. 蓝牙、多通道设备、最低系统和录制中切换设备尚未全部覆盖。

## 六、建议的立项方向

### 推荐主定位

> 一款最克制、可验证、不会碰麦克风的 Mac 系统音频录音机。

英文候选：

> A verifiable, lossless Mac system-audio recorder that never touches your microphone.

### 推荐的产品优先级

#### P0：先使当前优势对用户可见

1. 录音结束页显示编码、采样率、位深、声道、时长和文件大小。
2. 直接显示「已验证为 ALAC」，不只在 README 中说明。
3. 显示「未使用麦克风 / 未上传网络 / 未改变系统输出」的简明边界。
4. 为每段录音可选导出 sidecar JSON（侧车元数据）：编码、采样率、声道、时长、SHA-256 和应用版本。
5. 建立独立中英文产品页，展示 15–30 秒真实流程。

#### P1：补齐可靠分发而非功能数量

1. Intel 真机验收。
2. 最低 macOS 14.2 真机或独立环境验收。
3. 蓝牙、AirPods、HDMI、USB 音频、多通道和录音中切换输出设备验收。
4. 长时录音、休眠 / 唤醒、权限被中途撤销、磁盘空间不足、异常退出时的部分文件保全。
5. 独立隐私政策、使用条款、检查和下载哈希。

#### P2：有用户证据后再决定

- 单 App 录制。
- 菜单栏快速录音和全局快捷键。
- 暂停 / 恢复。
- 波形、剪辑、文件历史。
- WAV / FLAC / M4A 多格式。

这些大部分是市场已有功能，可以提升适用面，但不自动形成差异化。建议按真实用户反馈决定，不要立项即全部加入。

## 七、不建议的宣传

不建议：

- 「全球首个 Mac 系统录音器」
- 「首个无驱动系统录音工具」
- 「唯一支持 ALAC 的系统录音器」
- 「唯一不使用麦克风的产品」
- 「比原音质更高」或「与音源文件逐位相同」

可用：

- 「免费开源」
- 「只录 Mac 正在播放的声音」
- 「Apple Core Audio process tap，无第三方虚拟声卡」
- 「导出经程序验证的 ALAC 音轨」
- 「不含麦克风录制路径」
- 「无账号、无遥测、无网络上传」
- 「已签名公证的 Intel / Apple Silicon 通用安装包；Intel 真机验收待补」

## 八、新项目启动时建议继续读取

新任务不应只读本竞品文档，还应读：

1. `README.md`
2. `docs/3.0-lifecycle-fix.md`
3. `docs/competitive-research-2026-09-14.md`
4. 新项目目录内的 `AGENTS.md`、`README.md`、PRD 和当前交付边界。

基于现有成果继续，不要从零重做，不要用新骨架覆盖当前已验证的 Core Audio 采集、ALAC 导出和资源释放逻辑。

## 九、可复制给新任务的指令

```text
请继续「无损系统录音机」项目立项。不要从零重做，先完整读取以下文件：

1. README.md
2. docs/3.0-lifecycle-fix.md
3. docs/competitive-research-2026-09-14.md

竞品文档中的公开市场信息截止 2026-09-14；如用于当前价格、功能或发布判断，请先联网核对可能变动的信息。保留现有 Core Audio process tap、ALAC 导出、隐私边界和资源释放验证，先完成立项文档和产品范围判断，再决定是否修改源码。
```

