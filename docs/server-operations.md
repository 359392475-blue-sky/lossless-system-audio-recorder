# 版本准入及下载统计服务运维

本目录服务是独立的 Node.js 服务，不依赖第三方 npm 包。生产尚未部署；示例地址不是可发布配置。运行要求 Node.js 22.13 以上（本轮验证 22.22.3，`node:sqlite` 可能提示实验性 API）。必须把更新分发与版本策略服务都真实上线后才发布带强制验证的客户端。

## 配置与启动

`node server/main.mjs` 从环境变量读取配置；不读取 `.env`，不内置生产凭据或默认放行政策。

| 环境变量 | 必需 | 说明 |
| --- | --- | --- |
| `POLICY_FILE` | 是 | 策略 JSON 绝对路径，初始可参考 `server/policy.example.json`，必须替换版本、说明和 HTTPS 下载入口 |
| `POLICY_PRIVATE_KEY_FILE` | 是 | Ed25519 PKCS#8 PEM 私钥路径，仅服务端读取；对应公钥应固化在客户端 |
| `STATS_DB` | 是 | SQLite 数据库绝对路径，父目录必须存在且仅服务账号可写 |
| `ADMIN_TOKEN` | 是 | 至少 32 字节的随机管理凭据，通过部署 secret 注入；不得嵌入客户端 |
| `RELEASE_ARTIFACT_URL` | 是 | 固定版本的 HTTPS 制品地址，不允许 `latest` 路径；运营者保证该版本文件不可覆盖 |
| `RELEASE_ARTIFACT_BUILD` | 是 | 制品实际 build 正整数，至少 5；必须等于策略 `latestBuild` 且不低于 `minimumBuild`，不一致时拒绝签发且不记录新序号 |
| `RELEASE_DOWNLOAD_URL` | 否 | 经过实际验证的 HTTPS 升级入口；默认使用制品直链。策略 `downloadURL` 必须与此配置一致。使用统计入口时配置为服务公网 `/download?channel=other` |
| `HOST` | 否 | 默认 `127.0.0.1`，建议保持，仅由 HTTPS 反向代理转发 |
| `PORT` | 否 | 默认 `8787` |
| `GITHUB_REPOSITORY` | 否 | `owner/repo`，用于读取官方 Release 资产计数 |
| `GITHUB_TOKEN` | 否 | 仅服务端 GitHub API 凭据，公共仓库可不设置；不给客户端 |

从项目根运行：

```sh
node server/main.mjs
node --test server/test/*.test.mjs
```

上面启动命令要求部署环境已注入变量。测试自行在系统临时目录生成测试密钥并清理，不需要生产凭据，也不访问外网。生产密钥通过受控的密钥生成和密钥管理流程另行建立；本实现没有生成正式密钥。

部署时让专用低权限服务账号持有私钥及数据目录（私钥权限 0600、目录 0700），配置进程自动重启、磁盘和证书到期告警。策略请求不得被 CDN 缓存，返回 `Cache-Control: no-store`。反向代理必须提供受信任 HTTPS，关闭包含 IP、完整查询参数或鉴权头的访问日志；应用本身不输出请求、IP、UA、nonce、音频或管理 token 到日志。根据容量在反向代理设置速率限制，避免滥用请求撑大统计或占用策略服务。

## 客户端契约

`GET /v1/policy?build=<正整数>&nonce=<UUID>` 返回：

```json
{"payload":"<原始 UTF-8 JSON 的 base64>","signature":"<Ed25519 签名 base64>"}
```

签名覆盖原始 payload 字节。解码内容是策略文件的十个字段，加 `nonce`、`clientBuild`、`issuedAt`（Unix 秒）、`expiresAt`（签发时间加 60 秒）。客户端需要校验签名、产品标识、nonce、build、时间与单调序号；失败不得进入录音。系统时间需可靠同步，服务响应过期后不得离线续用；客户端具体周期和现有录音保护由客户端实现负责。

`level` 为 0 至 4：0 无升级提示但仍需验证；1 轻提醒；2 强提醒；3 到 `effectiveAt` 后低于 `minimumBuild` 必须升级；4 立即对低于 `minimumBuild` 的版本强制升级。若想停用全部已发布版本，必须先准备并验证可安装的新版本，再把 `minimumBuild` 设置为新版本 build。`latestBuild` 不得低于最低版本。下载点击本身不是准入凭证，只有新版本重新验证成功才允许录音。

## 修改与撤回

编辑单独的拟发布 JSON，完整包含示例中的字段。每次修改（包括撤回强制升级）都增加 `sequence`，然后执行：

```sh
node server/cli.mjs policy /absolute/path/proposed-policy.json
```

CLI 使用 `POLICY_FILE` 环境变量，持有同目录 `.lock` 跨进程排他锁后，读取现有序号、校验再原子替换，不需要客户端凭据。并发调用遇到锁立即失败，不覆盖先前成功的新策略；`sequence` 必须严格大于锁内读取到的现有文件。意外强杀进程可能留下锁：确认锁文件内 PID 已退出且没有更新操作后，由运维删除残留锁再重试，程序不自动抢锁。服务每次读取时通过数据库事务持久化已见最大序号，同一序号只接受同一策略；重新启动后也拒绝回滚。不要直接恢复较老策略；撤回时使用更大的新序号。损坏策略或序号倒退会返回 503，使客户端无法准入；通过新序号恢复有效策略即可恢复服务。策略变更后检查 `/ready` 与真实客户端行为，不能仅看 CLI 成功。

**更换目标版本必须协调策略与服务配置。**先完成真实新制品的签名、公证、下载、安装和 build 核对，验证 `RELEASE_DOWNLOAD_URL` 确实指向此可用升级入口，再在受控维护窗口停止旧服务，设置新 `RELEASE_ARTIFACT_URL`、匹配实际 build 的 `RELEASE_ARTIFACT_BUILD`，安装更高序号且 `latestBuild` 一致的策略，重启并检查 `/ready` 和低版本升级全过程。不能仅热改最低版本却继续分发旧包。服务会拒绝不匹配配置，但不会替运营者下载分析安装包，也不能证明外部地址可用；生产启用强制档位前必须实际验证目标资产，安排维护窗口并优先使用平滑切换部署减少准入中断。

## 统计口径

对外入口：`GET /download?channel=website`，其他允许值为 `github`、`other`。渠道必填且只允许一个参数，不接受任意跳转地址。成功返回 302 前，以数据库单语句原子累加 UTC 日期/渠道计数；HEAD、无效参数、错误请求不计数。此值名称是 **`download_entry_requests`（下载入口请求数）**，包括重复请求、自动程序请求、中断和可能被客户端缓存外的重试；不是完成下载、安装或独立用户数。记录不含用户、设备标识或音频数据。

官网等传播链接应统一指向这个入口。用户直接使用 GitHub 下载链接会绕过此入口，因此可另外读取 GitHub 官方 Release 资产 `download_count`。这个指标仍不能证明安装或活跃，也不能与入口数相加，因为可能重复覆盖。API 异常明确返回 `unavailable`，没有配置仓库返回 `not_configured`，不以 0 代替未知值。官方 API 文档：[列出 Releases](https://docs.github.com/en/rest/releases/releases#list-releases)。

`GET /admin/stats` 需要 `Authorization: Bearer <ADMIN_TOKEN>`，恒定时间比较令牌。生产查看可使用：

```sh
node server/cli.mjs stats
```

需注入 `STATS_ORIGIN=https://your-service-host` 和管理 token。命令不把 token 放在参数或日志中。统计按 UTC 日期、渠道返回，GitHub 结果单独列出资产累计计数；不提供合并总量。若未来需要安装量、留存或活跃统计，需另做明确产品方案和隐私告知，当前没有这些上报。

## 健康、备份、恢复与迁移

- `/health` 只表示进程存活；`/ready` 会校验当前策略和数据库事务可用性。策略无效时前者 200、后者 503，监控必须用后者告警。
- 单实例使用 SQLite WAL 和 5 秒 busy timeout；不要让多台主机各自保存独立数据库再声称是同一计数。多实例部署需要先换成共享事务数据库。
- 备份使用 SQLite 在线备份能力，或者停止服务后一起复制数据库及尚存在的 `-wal`、`-shm` 文件，再启动。不要只在运行时复制 `.db` 而漏掉 WAL。策略文件和私钥独立加密备份，不把 secret 上传进 Git。
- `schema_version` 基础服务为 1，启用邀请服务后迁移为 2；高于 2 的版本拒绝启动。将来改表时先备份、停写、运行明确版本化迁移和恢复验证，不自动破坏性重建。首次启动仅建缺失表。
- 恢复时同时检查数据库 `policy_state.sequence`、策略 JSON 序号和已发布客户端缓存的最大序号；以更高序号发布恢复策略，防止旧备份导致客户端永久拒绝。切勿通过删除数据库逃避序号限制。
- 保留策略审计副本（序号、内容、时间、操作人），但不要记录客户端请求明细。策略故障会直接影响所有用户，正式发布前必须演练坏配置、服务中断、限期到期、强制升级、撤回、备份恢复。

## 发布前仍需真实验证

这份代码和本地测试不能证明公网可用。待办包括域名与 HTTPS、实际服务器和持久卷、正式策略签名公钥绑定、固定版本的签名公证制品、下载入口、Sparkle 更新源、发布签名、低版本到高版本真实更新、联网失败及录音保存保护、监控/备份演练、下载计数对账，以及隐私说明与“启动和使用需联网验证”的显著告知。

## 3.2 邀请解锁服务

当前规则为每台设备五次**成功生成 ALAC 录音**的试用。开始录音只预留额度；失败或取消释放预留，成功停止且生成录音结果才扣一次。两台有效新设备经邀请完整下载、绑定邀请、各自首次成功录音后，邀请人的 **3.2 系列**解锁无限免费，没有到期时间或次数上限，同系列补丁版继承；仍需联网验证并遵守最高档强制升级。新 major.minor 系列不自动继承。

除前述配置外，生产必须完整提供：

| 环境变量 | 说明 |
| --- | --- |
| `REFERRAL_PUBLIC_ORIGIN` | 邀请页面和下载入口的 HTTPS origin，例如 `https://recorder.your-domain`，不带子路径或查询参数 |
| `REFERRAL_DEVICE_PEPPER` | 至少32字节的高熵随机服务端秘密；用于 HMAC 去重，严禁轮换或丢失，必须安全备份 |
| `REFERRAL_SERIES` | 当前 `3.2`，必须与分发包版本的 major.minor 一致，patch 变动保持此值 |
| `REFERRAL_ARTIFACT_FILE` | 本地固定版本 ZIP 的绝对路径；必须是已完成签名、公证及真实安装验收的应用压缩包 |
| `REFERRAL_ARTIFACT_SHA256` | 上述 ZIP 的小写64位 SHA-256；启动完整读取并校验 ZIP 标识、非空字节数、摘要 |

`RELEASE_ARTIFACT_BUILD` 至少6，必须与 ZIP 内应用实际 build 一致；服务不能从 ZIP 标识判断内部版本或签名，运营发布流程必须核对包内元数据和 `codesign`/公证结果。邀请服务完整启用后，服务会对请求 build 小于6的旧客户端签发最高档策略，最低版本至少6，并附明确升级文案；这项兼容性保护独立于运营选择的提醒档位，即使配置 level0 也不能让缺少试用模块的 build5 继续准入。build6及以上仍遵守正常运营档位。必须先完整发布并验收 build6及对应制品，再启用邀请服务，避免无可用升级目标。未启用邀请服务时，这项最低兼容版本保护不会自动生效。新的受控客户端缺失邀请服务会拒绝录音，不存在离线免验证兜底。

全新、未初始化邀请服务的数据库未提供任何邀请配置时，旧服务接口仍可运行，但邀请接口返回503；只提供一部分邀请配置则拒绝启动。数据库一旦保存邀请配置标记，此后移除部分或全部邀请配置都拒绝启动，防止静默降级让旧版本恢复免额度准入。部署含邀请的正式版本必须将这些配置和服务 `/v1/referral` 的真实验收作为发布门槛。数据库保存 pepper 的 HMAC 固定标记；后续以不同 pepper 启动会拒绝，避免无意清空去重身份、重置试用。恢复旧备份不得覆盖当前已使用次数或解锁状态；需受控恢复和对账，不能通过删库重新开始。

### 邀请下载与激活

`GET /r/:code` 返回免脚本的邀请页面。`POST /r/:code/ticket` 创建32随机字节的 base64url 凭证（43字符），有效七天；默认返回包含下载链接、安装后激活链接及可手动复制凭证的页面，`Accept: application/json` 可取得 `{ticket, downloadURL, activationURL, expiresAt}`。

`GET /r/download?ticket=...` **直接流式发送本地 ZIP**，不再使用302归因。服务完成响应、已发送字节数等于启动校验的制品大小、流内容 SHA-256 一致后，记录该票据完整交付一次；HEAD、Range、断线、错误、过期及改变过的文件不记完整交付。这里的“完整交付”仍仅是服务端完成发送，不证明用户保存或安装成功。反向代理不得缓存此路由；应禁用响应缓冲并传递客户端断线，避免代理提前完整读取制品使服务误以为已交付给浏览器。

安装后用户明确点击 `lossless-recorder://activate?ticket=...` 或在应用中粘贴凭证。客户端调用签名 `claim`，只有已完整交付、未过期且未绑定其他设备的票据可以领取；自邀、已经首次录音激活的设备、同硬件换密钥均拒绝。注册状态本身不算激活，首次成功录音才计有效邀请。一台受邀设备在全部系列全局只资格一次；同设备重复成功录音不重复奖励。下载链接、凭证和客户端请求体禁止记录到代理访问日志。

### 签名接口和幂等结算

`POST /v1/referral` 接收 `{payload,signature}`，均为标准 base64。payload 是原始 UTF-8 JSON，签名使用该设备 Ed25519 私钥。字段为 `schema:1`、固定产品标识、`action`、raw32 公钥 base64 `publicKey`、64位十六进制 `deviceHash`、`series`、`build`、UUID `nonce`、Unix秒 `issuedAt`；`begin/complete/cancel` 必带UUID `operationID`，`claim` 必带43字符 `ticket`，其他动作不带这两个可选字段。签名验证、请求时间正负60秒和持久化120秒 nonce 防重全部通过后才执行。

成功响应复用版本服务签名私钥，签名载荷回显 nonce、公钥、系列，60秒有效，含邀请链接、有效人数、五次试用已使用和预留数量、无限解锁布尔值、`canRecord`、`pendingOperationIDs`；操作动作还回显 operationID。`canRecord` 表示额度能力，实际开始仍检查最新强制政策。`begin` 幂等预留一份额度，每次调用都重新查政策；同操作终态不可重新预约。`complete` 幂等扣一次并激活设备；`cancel` 幂等释放，对未知操作也写取消终态，防止网络重排后的迟到 begin 重新占额，已完成操作不能退款。

`status/claim/complete/cancel` 不受政策停用影响，保证已录音的结算和保存能完成。网络中断后客户端应持久化并重试相同 operationID，使用新的 nonce 和签名；不要以新的 operationID 重试一次已成功录音。`pendingOperationIDs` 供崩溃恢复，但不能无差别取消别的仍在运行实例的录音。客户端按本地结算日志重试，或确认原进程已经结束后取消未完成预约。

常用错误为403 `trial_limit_reached` / `upgrade_required`，409 `ticket_expired_or_unknown` / `download_not_completed` / `self_invite` / `device_already_activated` / `ticket_already_bound` / `device_key_already_registered` / `device_identity_mismatch` / `replayed_nonce` / `operation_finalized` / `unknown_operation`，401 `invalid_signature`，400无效请求，503未配置或服务故障。恢复客户端 Keychain 私钥丢失需要人工受控处理，不允许自动创建新身份获得额外试用。

### 统计、隐私与边界

管理统计新增 `referrals` 聚合：`inviteTickets` 生成票据数、`deliveredTickets` 完整服务交付票据数、`activatedDevices` 首次成功录音设备数、`qualifiedInvites` 有效邀请数、`unlockedDeviceSeries` 已解锁设备系列数和 `bySeries`。这些漏斗指标不能互相相加，也不等于真实独立自然人数；接口不返回设备身份、票据或原始密钥。

数据库仅保存经服务 pepper HMAC 处理后的公钥/硬件标识和票据索引、随机操作ID、暂存防重 nonce、额度和邀请关系，不保存原始公钥、原始硬件hash、音频、录音时长、IP、UA或账户信息。需要在客户端隐私说明明确身份去重和次数结算，而不能继续声称完全没有设备相关数据。此机制可防同一标识重复计数、网络重试和一般重装，不是可信硬件认证：修改客户端、伪造硬件hash或自制签名客户端仍可能作弊，不能宣传为不可破解的反刷系统。

启用时数据库以事务新增 schema2 邀请表，保留 schema1 的策略和下载统计；旧版本服务无法识别新schema，应保留迁移前加密备份并用新服务恢复，不通过降级数据库绕开状态。nonce 定期在有效请求时清理过期项，操作终态永久保留以防重，已绑定票据和解锁记录随权益保留。未绑定过期票据的定期清理需另设受控维护，当前没有自动删除邀请审计数据。
