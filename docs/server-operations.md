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

## 发布部署路径与本轮运维演练（2026-09-15）

采用一条正式部署路径：Linux 上 **systemd 管理 Node.js 22.22.3 或更新的22系列运行时，Nginx终止HTTPS**。Node只监听 `127.0.0.1:8787`；不使用容器，也不安装第三方 npm 包。部署模板位于 `server/deploy/recorder.service`、`nginx.conf.example`、`service.env.example`、`release-manifest.example.json`。这些模板没有真实域名、密钥或有效发布清单，不能原样启动上线。

### 私有目录与生产检查

部署管理员先创建专用 `recorder` 账号，代码放 `/opt/recorder/server`，由 root 管理且服务不可写。数据根 `/var/lib/recorder` 及 `data`、`private`、`artifacts`、`backups` 子目录由服务账号持有，权限0700；策略、私钥、SQLite及WAL/SHM、制品ZIP和发布清单权限0600。systemd声明 `UMask=0077`，限制写入 `/var/lib/recorder` 并将私钥和制品子目录设为只读；关闭提权，设置内存、任务和文件描述符上限。环境文件放 `/etc/recorder/service.env`，由root持有0600，仅由systemd读取，不能随代码或制品发布。

生产设置 `NODE_ENV=production` 后，服务启动必须同时满足完整邀请配置、实际发布清单、loopback监听、上述私有文件权限；缺失、占位值或不匹配都会拒绝启动。`RELEASE_MANIFEST_FILE` 是真实打包流程生成的JSON：

- `schema:1`、固定 `product`、实际 `version`（如3.2.0）、`build`；其major.minor必须等于 `REFERRAL_SERIES`。
- 最终ZIP `sha256` 和 `bytes`，必须与本地制品和配置相同。
- `bundleID` 固定为 `app.lowpower.lossless-system-audio-recorder`、最终客户端绑定的 `policyPublicKey`（raw32公钥base64）、实际 `signingTeamID`、已获接受的 `notarizationID`。

生产检查把版本、摘要、大小与策略签名公钥交叉绑定，**但清单本身不能替代Apple签名/公证证据**；签名团队与公证ID必须由真实发布验收填写，不得填测试值。修改制品或清单后需要协调策略和服务重启。普通 `/download` 的目标应是已经存在的GitHub固定Release资产或另外配置好的静态制品地址；当前Node服务不提供任意 `/releases/...` 静态路径。

配置检查命令为 `node server/ops.mjs check`（需要注入完整环境）；它会打开/初始化数据库并验证策略、私钥和制品后退出，不监听公网。systemd的 `ExecStartPre` 会自动运行同样检查。成功只表示本地配置一致，输出特意包含 `publicDeploymentVerified:false`。安装systemd单元前要确认 `/usr/bin/node --version` 确实为受支持版本；系统默认Node可能太旧。

### HTTPS代理与容量边界

管理员替换Nginx模板中的域名、证书路径，放入 `http {}` 的include目录并在目标Linux实际运行 `nginx -t` 后启用。证书取得、自动续期与DNS记录要按实际域名建立；本轮没有替用户建立公网服务。Nginx明确关闭该站点的请求访问日志和可能含URL的错误日志，不向Node传递客户端IP；使用外部状态码/进程/磁盘监控代替请求日志排错。代理关闭响应缓存、响应缓冲及自动重试，传播客户端断线，避免把代理提前读完整ZIP误记成浏览器成功交付。其缓冲行为依据[Nginx官方说明](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffering)。

Node有独立内存容量保护，无IP计数表：

| 环境变量 | 默认值 | 作用 |
| --- | --- | --- |
| `MAX_REQUESTS_PER_MINUTE` | 6000 | 全局一分钟请求上限，超额返回429 |
| `MAX_TICKETS_PER_MINUTE` | 120 | 新邀请票据生成上限，防止无限增长 |
| `MAX_ACTIVE_REQUESTS` | 128 | 正在处理的请求上限 |
| `MAX_ACTIVE_DOWNLOADS` | 4 | 同时流式传送邀请ZIP上限 |

触发上限返回 `{error:"capacity_limited"}` 和 `Retry-After:60`；窗口内存计数不持久化，不用作统计。响应完成或连接断开都会释放并发名额，HEAD不占下载名额。Node另有15秒请求体超时、10秒请求头超时、5秒keepalive。参数需要根据真实服务器容量调整；单机全局限流不等于DDoS防护，过载仍可能暂时影响准入，应监控429/503并预留策略容量。

`/ready` 现在同时检查政策、数据库和邀请制品是否改变/缺失；制品被替换或损坏元数据会503，`/health`仍只报告进程存活。发布前应分别从主机loopback和公网HTTPS检查ready，再进行真实低版本升级及邀请下载中断测试，不能只看systemd进程是active。

### 在线备份与新路径恢复

新增运维CLI使用Node内置SQLite在线备份API，能得到包含WAL中已提交写入的一致快照，不靠运行中直接复制主数据库。以拥有数据库权限的账号运行：

```sh
STATS_DB=/var/lib/recorder/data/state.sqlite node /opt/recorder/server/ops.mjs backup /var/lib/recorder/backups/2026-09-15.sqlite
node /opt/recorder/server/ops.mjs verify-backup /var/lib/recorder/backups/2026-09-15.sqlite
node /opt/recorder/server/ops.mjs restore /var/lib/recorder/backups/2026-09-15.sqlite /var/lib/recorder/data/restored-2026-09-15.sqlite
```

备份目的目录必须0700，生成数据库和 `.manifest.json` 都为0600。清单保存摘要、schema、政策最大序号和聚合行数，备份后运行SQLite完整性检查；恢复时再次核对摘要、完整性和状态。**目标文件或其WAL/SHM已存在就拒绝覆盖**。恢复默认只创建新路径，不修改运行中的 `STATS_DB`；确认服务停止、快照时点及丢失窗口后，运维才可修改环境指向新路径并协调更高政策序号。业务仍在写入时不能直接切回旧快照，否则会丢失已用次数或解锁记录。备份清单防意外损坏，不能抵御有权同时篡改备份和清单的攻击者；异机加密保管和访问控制仍必需。

私钥、pepper和策略文件需独立加密备份。当前CLI不自动删除旧备份或业务数据；请在验证过可恢复副本后执行明确保留计划。定期演练恢复到全新隔离目录，再校验签名验证、政策序号、试用次数与已解锁权益。

### 异常预约人工核对（发布P0）

服务不会猜测预约是否可以退款。新命令只列出未完成预约的匿名操作句柄、系列、随机operationID和状态，不输出设备原始hash、公钥或设备HMAC索引：

```sh
STATS_DB=/var/lib/recorder/data/state.sqlite node /opt/recorder/server/ops.mjs reservations
```

管理员必须根据用户提供的operationID/本地结算日志确认原进程已经结束、该预约没有成功录音结算，再针对**单条句柄**操作：

```sh
STATS_DB=/var/lib/recorder/data/state.sqlite node /opt/recorder/server/ops.mjs cancel-reservation HANDLE operator-name confirmed_process_ended --confirm-process-ended
```

允许的原因仅 `confirmed_process_ended`、`user_confirmed_abandoned`、`incident_recovery`。缺少显式确认、状态已完成/取消或句柄不匹配都拒绝；从未完成预约原子改为取消终态，**不减少已用试用次数、不创建成功录音、不激活设备、不增加邀请奖励**。同一事务在 `referral_admin_audit` 记录时间、管理员标识、固定原因、匿名操作句柄和前后状态，供事后审查；审计不写请求敏感信息，也没有批量自动退款功能。列表最多1000条，异常积压达到上限时应先调查来源，再安排受控分批处置。

本轮本机验证：原策略/邀请测试之外，已实际运行临时WAL库在线备份、验证、恢复、拒绝覆盖和坏备份拒绝；通过独立CLI子进程执行预约查看、显式取消和审计，确认已用次数不变及已完成录音不退款；生产配置检查的匹配测试清单通过，权限/版本/公钥错误拒绝；HTTP限流和制品变化导致ready失败也已验证。测试密钥/制品全部是隔离临时测试数据，未生成正式密钥。当前机器没有Nginx/systemd，因此这些目标系统模板尚待Linux上的 `nginx -t`、服务启动及HTTPS外网验收，不能宣称已经部署可用。

服务器独立实例如使用端口8793，须同时更改环境 `PORT` 与Nginx `proxy_pass`，避免影响既有服务。若另由Nginx提供普通公开制品，可以把已验收的同一ZIP复制到独立公开目录并再次核对SHA-256；Node邀请服务使用的私有制品和清单仍须0600、父目录0700，不能因静态分发而放宽。预发布公开目录应通过运维配置IP白名单，正式域名DNS/HTTPS未验证前不能向用户分发。

## 2026-09-15 增量：页面、定时运维与实际 QA

服务现提供 `/` 下载介绍、`/privacy` 隐私说明、`/license` 完整现行软件许可、`/support` 权益与反馈帮助；邀请页和激活凭证页链接到这些入口。反馈使用项目已有 GitHub Issues，明确它是公开页面，禁止粘贴音频、设备凭据、激活码或个人资料；这里只提供受理入口，没有实现未经核实的自动退款或删除。页面不引用外部资源、不设置 Cookie，发送 no-store、no-referrer 与禁止嵌入的 CSP。`server/public/LICENSE.txt` 与根目录 LICENSE 保持一致，发布前同步 `server/public/privacy.md` 与审定隐私说明。

新增 `node server/maintenance-cli.mjs backup|health`：

- `backup` 使用 `STATS_DB`、`BACKUP_DIR`，创建新时间戳文件并立即验证，绝不覆盖或删除已有快照。新快照在独立文件内切换为 DELETE 日志模式，便于单文件携带；不会修改正在使用的数据库 WAL 模式。
- `health` 只请求 `127.0.0.1:$PORT/ready`（10秒超时），核查备份目录至少 1 GiB 可用空间、最近 scheduled 快照不超过36小时，以及其摘要和 SQLite 完整性。失败以非零状态退出，不打印秘密或设备身份。该检查不能证明公网 DNS、证书或客户端可达。
- `server/deploy/recorder-{backup,health}.{service,timer}` 是可调整的 systemd 模板；备份每日运行，健康每5分钟运行。首次启用前先手动备份一次，再运行健康检查。
- 失败记录在 systemd 状态和 journal。**尚未绑定外部通知接收人**，不能把本机失败状态宣称为已收到故障告警；正式上线前需接入现有告警渠道。备份不自动清理，需监控磁盘并确定保留周期、异机加密副本和适用的数据处理流程。

已在实际 Linux 主机新增独立代码目录 `/opt/lossless-recorder/releases/qa-ops-20260915/server`，保留旧 `qa-3.2.1-7` 代码及现有 QA 数据库。原 `lossless-recorder-qa.service` 通过 `operations-code.conf` drop-in 使用新代码，依旧只监听 `127.0.0.1:8793`，继续使用原 QA 环境和 build7制品，没有改成正式公开服务。

已启用 `lossless-recorder-qa-backup.timer`、`lossless-recorder-qa-health.timer`，手动备份与健康检查均已成功。当前备份路径 `/var/lib/lossless-recorder/backups`，服务账号 `lossless-recorder`；主机 Node 位于 `/usr/local/bin/node`。本机与Linux均通过32项服务端测试，覆盖页面入口、备份缺失/过期拒绝、非ready拒绝及原邀请/政策业务。

此主机已有 Nginx 是 `/www/server/nginx/sbin/nginx -c /www/server/nginx/conf/nginx.conf` 管理的实例，不应安装或启动第二个 Nginx。独立 recorder vhost 由主任务配置：DNS指向实际服务器后，先配置仅用于证书验证的 `/.well-known/acme-challenge/` webroot，使用既有 Certbot 获取单域证书；HTTPS反代8793并保持预发布访问限制。每次变更先用该实际二进制和配置路径 `-t` 检查，再 reload 同一实例。不得复用其他产品证书或改变其他服务站点；公网可达、证书续期和真实客户端仍需分别验收。

### QA 已接入 3.2.2 build8

最终公证包已保存到新私有目录 `/var/lib/lossless-recorder/releases/qa-3.2.2-8`，环境为 `/etc/lossless-recorder/qa-3.2.2-8.env`。ZIP 大小2505709字节，SHA-256 `3ea704e89540e4585c4fc9c6c363cc542dce5417d931787501bb3e27435f0a68`，公证 Accepted ID `c98ad281-790d-4d39-ba67-b38c9e397de1` 与最终清单一致。旧build7制品、环境和备份保留；QA仍沿用原数据库，未清空权益记录。主服务及两个维护服务通过独立 `build8.conf` drop-in 选择新环境。

实际回环验证：ready和四个页面200，隐私页面包含3.2.2恢复说明；客户端build5/7/8请求均验签通过，策略序号2、最新build8，旧build5强制升级，7和8正常策略。另在新随机端口、新隔离数据库执行完整qa-smoke，验证了完整ZIP下载摘要、五次上限、两邀请解锁、人工取消审计和备份恢复；这些合成事件没有写入现用QA库，也不证明真实Mac录音。

回退服务代码和回退策略并不相同：现用数据库已记住序号2，不可直接启用旧序号1策略。若要回退制品，需使用更高序号并协调制品清单、配置和客户端升级行为，不能删除数据库避开序号规则。DNS/HTTPS、公开静态制品路径、外部告警与真实三机邀请仍需独立验收。

最终ZIP另已复制到 `/var/www/lossless-recorder/public/artifacts/LosslessSystemAudioRecorder-3.2.2-8-universal.zip`，appcast复制到 `/var/www/lossless-recorder/public/appcast.xml`。分别核对与私有最终资产逐字节摘要一致，ZIP大小及清单摘要也匹配；采用只创建缺失文件、同路径内容不同即拒绝的方式，没有覆盖旧资产。未改Nginx访问控制；当前只有ACME验证路径可达，其它入口仍503。build8环境与appcast统一使用 `/artifacts/LosslessSystemAudioRecorder-3.2.2-8-universal.zip`，HTTPS静态站点根应为上述public目录；不能把磁盘就位当成已可下载。原环境副本 `.env.before-artifacts-path` 保留。
