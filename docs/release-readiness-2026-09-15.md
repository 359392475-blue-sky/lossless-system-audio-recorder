# 假设 2026-09-15 发布：准备与阻断项

检查日期：2026-09-14。当前目标 3.1.0 / build 5；本文区分已实现、自动化验证与尚未完成的生产验收。

## 已实现

- 0–4 档升级策略；最高档按最低允许构建号立即阻断新录音。
- 每次录制两次新鲜在线签名验证；断网/缺配置/坏签名/过期/回退拒绝新录音，无离线许可缓存；CLI 同样验证。
- 已录文件可保存；更新安装保护录音、导出和未保存状态。
- Node 策略服务、Ed25519 签名、单调序号与并发配置保护；策略版本与下载制品构建号必须一致。
- 下载入口按 UTC 日期/渠道计数，GitHub 资产计数独立列出；管理统计要求令牌。
- 四项在线打包配置缺一即失败；正式打包要求 Developer ID、公证、票据、主程序和更新组件双架构检查。
- 3.1 起自有许可与隐私说明随应用打包；历史 MIT 授权仍有效，不重写历史。

## 明天公开发布前必须完成

| 阻断项 | 具体交付 / 通过条件 |
| --- | --- |
| HTTPS 策略服务 | 部署 server，持久化 SQLite 与策略文件，生成并安全保管独立签名私钥；确认 /ready、签名响应、故障监控、备份恢复；客户端内真实公钥匹配。服务不可用会让所有新录音失败，需明确恢复负责人 |
| 真实升级入口 | 为 build 5 准备固定资产，并在开启停用前先确认允许版本真实可下载；RELEASE_ARTIFACT_BUILD、latestBuild、minimumBuild 和下载地址匹配。不得把旧 3.0 资产标作 build 5 |
| Sparkle 生产清单 | 独立签名 appcast 与安装包签名；核对生产公钥、HTTPS 和版本单调性；不能只填一个格式正确的 URL |
| 新包签名公证 | 对最终含正式配置的通用包运行 prepare-release.sh；核对最终 ZIP 的 SHA-256、公证票据和 Gatekeeper。旧版本已公证不能证明新包合格 |
| 真正跨版本升级 | 用两个均含准入的隔离版本演练：level 1 可关闭；level 3 到期；level 4 阻断旧版；安装新版后重新验证恢复。确认点击下载不解锁、断网拒绝、服务恢复后可录、坏签名拒绝；不覆盖用户现用安装 |
| 录音保存保护 | 真实录音期间启用最高档，当前录音仍能停止并导出，下次开始被拒；取消保存、重试导出、更新待安装时不丢文件；原有普通退出放弃片段文案与实际一致 |
| 下载统计上线 | 网站下载入口指向 /download，并配置明确渠道；真实下载一次后核对数据库及管理接口，禁止将入口访问和 GitHub 计数相加或当作用户数；配置代理日志和隐私告知 |
| 兼容性范围 | Apple Silicon、本声明最低 macOS 14.2、Intel 更新组件与录音权限连续性需实测；缺目标硬件则缩小公开承诺，不声称全平台已验收 |
| 对外页面 | 撤掉“永久离线/免费开源”等不适用新版本的表述，说明每次录音联网验证、免费范围和后续变化；更新隐私与许可链接。网站变更尚未发布 |

服务部署、域名和生产签名配置尚未在本轮上线；未启用真实停用政策，未发布 3.1 安装包。测试候选包只用随机测试公钥和未部署验收地址，故意无法获得生产录音许可，不能作为正式包外发。

## 旧版本控制边界

公开 v3.0.0 release 的旧包不含在线验证，应转为草稿撤下公共安装包，保留资产及历史以便审计。改新许可不撤销旧 MIT 许可，撤下 release 不删除已下载副本，也不保证第三方不能重编历史源码。维护与正式打包流程从 build 5 起拒绝无验证版本。

首次检查旧 GitHub asset 下载计数为 0，只说明该资产接口返回的计数，不证明绝对无人获得副本。

## 验证记录

本机最终结果：Swift 22/22、服务端 8/8、发布配置 Python 4/4 全部通过。双架构候选包编译、嵌套签名、主程序及更新组件的双架构/最低系统检查通过；发布审计在公证票据检查处按预期拒绝该未公证测试包。

Swift 测试涵盖原有采集清理和编码、更新安装保护、版本准入和 Node→Swift 签名互通；服务测试覆盖策略签名、错误拒绝、下载计数、管理鉴权、资产版本匹配与并发配置；Python 测试覆盖发布配置缺失和非法值。CI 同时运行三组测试。

本机日志：`/tmp/lossless-policy-validation/final-tests.log`、`final-build.log`。本机隔离包：`/tmp/lossless-policy-app-build5-validation/无损系统录音机.app`。构建与静态签名验证不代表远程更新、真实录音回归或新包公证完成。

## 官方核查依据

- [Apple：分发前公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)：Developer ID 分发、公证与 Gatekeeper 的要求。
- [Apple：定制公证流程](https://developer.apple.com/documentation/Security/customizing-the-notarization-workflow)：提交、查看结果和装订票据流程。
- [Sparkle：发布更新](https://sparkle-project.org/documentation/publishing/)：签名安装包和发布更新清单，静态集成不等于安装链路已验证。
- [GitHub：Release assets API](https://docs.github.com/en/rest/releases/assets)：资产 download_count 字段；是资产下载计数，不提供独立安装用户数。
- [GitHub：Releases API](https://docs.github.com/en/rest/releases/releases)：草稿、资产与 release 管理。
