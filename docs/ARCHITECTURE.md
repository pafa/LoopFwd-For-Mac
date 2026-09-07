# Architecture

LoopFwd 当前是一个本机 SwiftPM 原生 macOS 单体应用。先保持这个结构，直到真实产品路径证明需要拆进程、数据库或共享服务。

源码仍属于一个 executable target，只按职责分目录：`App` 负责生命周期，`Core` 负责统一契约与扫描，`Providers` 隔离外部数据格式，`System` 封装 macOS 能力，`UI` 只消费统一 session 列表。

0.1.0 的运行范围以 `SupportRegistry.shippedKinds` 为唯一白名单：Codex、OpenCode、Copilot、Claude、Gemini、Qwen、Kimi、Grok。`Pref.disabledKinds` 将用户禁用项与非首发项合并；旧启用设置也不能复活暂缓 Reader。设置、Setup、About 和诊断使用同一名单。以下保留的 Cursor、DeepSeek、Mistral、WorkBuddy 模块说明是后续开发与旧配置恢复参考，不表示本版会扫描或提供安装入口。Doubao 没有生产 Reader。

“预览实测”仅对应 `codex.desktop`、`opencode.tui-http`、`copilot.cli` 的既有基础真实任务证据；不是稳定版认证，也不授予任何状态或控制能力。其他五款新安装默认关闭，已存的用户偏好不被改写。

```text
macOS process table + provider stores + DSH observer
                ↓
           AgentMonitor
   ┌────────────┼──────────────────┐
ClaudeSessions CodexSessions      OpenCodeSessions + fallback
               + Desktop reader   + Desktop reader
   └────────────┼──────────────────┘
                ↓
       raw AgentSession projections
                ↓
       IntegrationProfile + AgentLifecycleReducer
       ┌────────┴────────┐
 normalized sessions     lifecycle events
       ↓                     ↓
 presentation policy     notification router
       ↓                     ↓
 NotchPanel / IslandView   macOS notification
       ↓
 TerminalBridge / provider-authenticated control
```

## 关键模块

- `Agent.swift`：产品的 Provider 入口、正式/实验分级、稳定字符串 session identity、可选 PID、统一 `ReturnTarget` 与 `ObservationHealth`。新增 WorkBuddy 为实验桌面表面，不以普通 CodeBuddy/WorkBuddy 可执行文件名称发现任务。
- `IntegrationProfile.swift`：按 `claude.cli`、`codex.desktop`、`opencode.tui-http` 等具体表面声明证据、控制、跳转、Reader 时间预算、支持版本、降级策略、stalled 阈值和重连宽限；品牌名称本身不授予能力。
- `TaskPresentationResolver.swift`：稳定拆分项目、用户任务和当前步骤，过滤无语义短确认，并限制卡片文本长度。
- `AgentMonitor.swift`：本机发现与扫描请求合并；一个执行中加最多一个待执行。它消费 provider reader，不拥有控制权威。
- Qwen/Gemini 的 Node 入口按准确包路径识别；同一安装、TTY 及官方 launcher/relaunch 环境字段证明启动关系后，才剔除外层启动器。同品牌的独立子 CLI 不因此消失。KERN_PROCARGS2 只读取所需配置/身份字段，保留空 argv 的边界；CPU 仍只能提供 process-only。Qwen 尚无唯一记录时保留已验证 registry 身份，不借历史正文，数据时间为登记时间而非扫描时间。
- `AgentLifecycle.swift`：所有 Provider 共用的状态归一、转换事件、进展新鲜度、`Possibly stalled` 和主界面排序/可见性。CPU 和进程信号不能产生 Completed。
- `NotificationRouter.swift`：独立处理完成、需要用户、失败、可能停滞与启动通知；按 session/turn/event 去重，小批量聚合，同一会话更新同一条系统通知，点击优先返回精确会话。
- `ClaudeSessions.swift`、`CodexSessions.swift`：各自读取本地权威文件并提取最近上下文、任务和状态。
- Claude CLI 登记按实际配置目录、PID、官方 UTC `procStart` 与 Darwin 域核验；跨目录旧文件不参与状态或错误聚合。第二次出生查询确认已退出的 PID 不再进入本批投影，查询失败则保留未知，不当成成功空列表。
- Codex CLI 的目录发现读取对应进程的 `CODEX_HOME`，不要求 LoopFwd 的 GUI 环境继承 shell 环境；按目录隔离发现缓存，打开的 rollout 必须通过 session metadata 校验，多个匹配不直接猜选。目录约定参考 [官方配置说明](https://learn.chatgpt.com/docs/config-file/config-advanced#config-and-state-locations)。
- `CodexDesktopSessions.swift`：只读查询 Codex 本机 thread registry 以获得顶层用户任务及其准确 rollout；状态与上下文仍由 rollout 提供。它不启动 app-server、不提供 Stop/Reply，但会使用经过校验的 thread deep link 精确返回对应 Codex 任务。
- `OpenCodeSessions.swift`：只连接目标 OpenCode 进程自己开放的 loopback HTTP 端口；读取官方状态，并在回复前重新核对 request/session 是否仍存活。官方接口不可用时不改变 process/TTY fallback。
- OpenCode TUI HTTP 读取和控制均核验稳定版 1.18.x；不兼容结果不能降级为成功空列表。除活动 ID 外短暂读取最近更新的会话，以捕获退出 `/session/status` 后的明确结果；成功要求最后一个非摘要 assistant 匹配当前 user ID、`finish=stop`、有效 `time.completed` 且无 error。`MessageAbortedError` 为 Stopped，其他明确错误为 Failed；busy/retry 仍优先于旧结果。摘要缓存绑定 session header revision，未刷新不能使用上一轮的成功结果。依据官方 [1.18.29 processor](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/opencode/src/session/processor.ts)，不把工具或中间消息结束当作成功。
- `OpenCodeDesktopSessions.swift`：只读查询 OpenCode Desktop 自己的 SQLite store，投影顶层会话、状态、模型、todo 和最近文本；只允许激活 OpenCode。数据库观察永远不产生 Reply/Approve 权限，带随机 Basic Auth 的 Desktop sidecar 未有可证明凭据时保持 fail closed。
- `CursorSessions.swift`：只按进程实际打开的精确 transcript 或完整 UUID resume 参数读取当前工作区的 `agent-transcripts` JSONL，投影稳定 `cursor:<UUID>`；不猜最新聊天、不做 ID 前缀匹配、不扫描正文寻找 cwd。已发现新会话但文件不可用、跨工作区或多文件歧义时，不回退旧 resume。固定核对官方 CLI `2026.09.02-c22c1a3`：transcript 使用独立 `CURSOR_DATA_DIR`（默认 ~/.cursor），不跟随 `CURSOR_CONFIG_DIR` / `XDG_CONFIG_HOME`；workspace slug 只保留 ASCII，覆盖中文、空 slug、空格和重音路径。chat metadata 从 config/chats/MD5(cwd)/UUID/store.db 精确读取，hex→UTF-8 JSON 且 agentId 必须匹配；MD5 仅用于官方路径寻址，不作安全校验。元数据只补标题/模型，不能更新任务新鲜度；正文缓存以 inode/size/mtime 失效，历史/CPU/未经核实的 turn_ended 均不授予运行或完成状态。坏数据 stale，其余历史观察为 processOnly；不写私有 SQLite、不自动恢复聊天。官方 CLI Hook 的 conversation/generation/stop 与自动 follow-up 仍需固定版本真实验证，暂不把 IDE 字段或 headless stdout result 当成本地 transcript 协议；依据 [官方 Hooks](https://cursor.com/docs/hooks)、[CLI 更新记录](https://cursor.com/docs/cli/changelog)。
- `GeminiSessions.swift`：对照官方 Gemini CLI 0.58.0 项目 registry、JSONL recording 与 Hook 输入。`GEMINI_CLI_HOME` 指向 home 父目录，项目 hash 保留官方词法路径。进程出生身份匹配的 Hook 可优先于旧 resume 参数绑定当前 UUID，但 transcript/cwd/projectHash 仍须核验；没有 Hook 时只接受明确 UUID 或进程打开的文件，不猜最新聊天。重放消息更新、rewind/checkpoint 与准确迁移对，历史仅补正文。`gemini.cli` Profile 的 AfterModel 只表示会话（可含子任务）的近期生成进展，输入是官方转换后的字符串 parts，不是原始 SDK 格式。Hook 后置结果/权限通知均不赋予完成或审批能力；按源时间排序，歧义及过期降级。安装入口、实际模型和精准返回仍待验收。接口依据：[官方 recording](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/core/src/services/chatRecordingService.ts)、[项目 registry](https://github.com/google-gemini/gemini-cli/blob/v0.58.0/packages/core/src/config/projectRegistry.ts)。
- `DeepSeekSessions.swift`：只读 `@loopfwd/dsh-observer` 产生的最小快照，固定支持 DeepSeek Harness `0.1.2-alpha.5`。多会话以 `dsh:<sessionId>` 独立展示；版本、schema、更新时间和 loopback URL 均验证后才采用。
- DeepSeek 版本边界：当前版本检查确认的是 CLI，不是整个 runtime。官方 alpha.5 npm 子依赖采用宽松范围，现有安装的 Web/API/session 等实际解析为 rc.1；不以 CLI 字符串声称完整 alpha.5 运行图已验证，也不只降级两个包冒充对齐。观察器保持 Experimental，真实模型生命周期与混合依赖兼容性仍待验收。已核对当前官方 API 的 list.updatedAt 仅为 max(createdAt,lastPromptAt)，因此周期读取取历史摘要与真实事件进展的最大值，不将摘要时间覆盖实时进展。列表先全量校验再提交，损坏/重复/超预算不刷新成功时间；读取期间的新状态、会话和删除受有界修订/删除屏障保护，容量拒绝保留 degraded。卸载先禁止后续写入、等待已开始的原子写结束，不等待可能挂起的 list，防止热替换后的旧实例覆盖新快照。这些回归使用隔离宿主，不等于真实模型验证。
- `DeepSeekHarnessIntegration.swift`：只在用户点击后，通过官方 `dsh plugin --profile web add/remove` 安装或卸载；App 内 Bundle 先复制到私有内容寻址目录，避免 App 移动导致安装源失效。操作前备份 Web profile 元数据；首次安装失败执行官方 remove，替换失败通过官方 add 恢复已核验的原本地安装包，不卸掉原有安装后声称恢复成功。
- `QwenSessions.swift`：对照官方 Qwen Code 0.23.0 的只读 PID registry，校验 schema/版本/UUID/cwd/进程出生，不读取控制 token。当前身份始终以 registry 为准；如较新 Hook 身份与异步更新中的登记不一致，暂缓富状态，不能复活旧任务或擅自绑定新任务。匹配的 transcript 只补正文，匹配的 MessageDisplay 非最终文本事件提供近期生成进展；同一 messageID 已 final 后不允许迟到片段复活。工具结束/中断不证明仍运行，Stop 不是成功；明确 StopFailure 还要求保留窗口内有当前源序的用户提交，旧事件不得覆盖较新任务。没有 Hook 时仍 Process only，不借用 ACP turn_result；没有审批控制能力。新增 `qwen.cli` Profile，真实账号任务、Hook 安装及精准返回未验收。
- `CopilotSessions.swift`：读取 `COPILOT_HOME` 下 schema 1 的 `open-sessions-state.json`，以当前 PID 的 `inuse.<pid>.lock` 与进程启动时间确认归属，支持同进程多个标签页，不用最新聊天或启动 argv 猜任务。Tracker 的 working 是状态变化记录，不是心跳，读取时不能刷新进展时间。固定 1.0.83 事件格式：`session.task_complete` 的字段均可选，兼容旧式 success 和显式 completed，拒绝 false、blocked、continue 及类型损坏；旧结果、子 Agent、普通 turn_end、idle、shutdown 和历史审批均无完成/审批权威。Autopilot 额外读取原生 version/current 磁盘封装，不使用公开 SDK 投影或 nextId 代替当前目标；完成须匹配 current.id、completed 状态与最新目标事件，读取前后有界字节变化则延后。普通任务允许目标文件确实不存在，但悬空链接、权限失败和未知格式不能提供完成依据；create/delete/resume 作废旧结果，同目标暂停不抹除明确错误/取消。该保守策略可能延后 Autopilot 完成，待真实账户验收。事件日志损坏显示 stale/incompatible；原生 CLI 未登录时的实际 Idle 已经生产 Reader/Scanner 复验，不代表模型生命周期通过。TTY 不能精确选择内部标签页，已知 Terminal/iTerm 仅应用级返回，控制关闭。官方配置说明：[CLI 配置目录](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)；实时审批后续参考[官方 hooks](https://docs.github.com/en/copilot/reference/hooks-reference)。
- `KimiSessions.swift`：针对官方 Kimi Code 0.41.0 的 main-agent wire 1.5；仅匹配明确 session ID 或进程持有的主 wire，不按同目录最新历史猜测。`turn.ended` 的明确 reason 区分成功、取消与失败，step.end/历史 assistant 不是完成；子 Agent 的结束不结束主任务。损坏/未知 wire 版本分别标记 stale/incompatible，独立 `kimi.cli` Profile 不授予审批或控制能力。当前全量 wire 读取上限 4 MiB，超过预算诚实降级，后续长会话需要增量读取；有界缓存按实际文件大小/修改时间失效。官方依据：[数据位置](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/configuration/data-locations.md)。此版本已安装启动，但真实账户生命周期尚未验收。
- `GrokSessions.swift`：对照 xAI 官方 event schema 1.0；`GROK_HOME` 的实时 registry、summary 身份和进程实际持有的 events 文件共同绑定稳定 session ID，支持同 PID 多会话。registry 的 opened_at 必须不早于当前进程出生；缓存纳入本次打开身份，历史 turn 不能因重开恢复 Working/审批/结果，也不刷新历史进展时间。只有打开之后的 primary turn 及明确 `turn_ended.outcome` 可区分成功、取消与错误；实时 permission_requested/resolved 仅观察，不提供审批。独立 grok.cli Profile 保持 Experimental。损坏/缺少边界/未知 schema 降级；读取最后 4 MiB，必须包含有效 turn_started 才恢复任务富状态，真正零字节事件文件与超大记录截断后无完整记录严格区分。后者保持 stale，后续新边界可恢复。按文件顺序归一化、用最大事件时间记录新鲜度，兼容官方并发写入时间倒序。官方客户端已隔离安装；公开源码验证了 writer 持有 FD，但不等于已安装二进制的真实账户生命周期验收。
- `LocalHookEvents.swift` 与 `Integrations/LocalHooks/observe-hook.mjs`：明确安装后才运行的只读事件入口，按 Provider/PID/进程出生/会话分目录，每个最多 64 条。字段白名单不包含提示词、工具参数/结果或凭据，目录/文件为 0700/0600；脚本只返回中性的 `{}`。源时间与接收时间分开，流事件只保存内容存在布尔值、消息 ID/final、工具中断及白名单错误码；不保存模型正文。当前收集覆盖 Mistral/Gemini/Qwen/Copilot，生产消费已接 Mistral/Gemini/Qwen，但不等于三款真实验收完成。每个祖先进程用一次 ps 读取出生和命令，识别实际官方 Node 入口；启动 App 不自动配置 Hook。
- Cursor 增量：收集器支持九类官方 Hook，保存 conversation/generation/version/loopCount，不保存 prompt、thought、response 或工具参数；没有源时钟时只标接收时间。固定官方 HookExecutor 的 argv_heredoc→实际 shell→本收集器已用合成事件验证中性 `{}` 与 0600；测试宿主正确为 unbound，不等于真实 CLI 模型任务。生产 Reader 可按实际 PID/出生身份 Hook 定位关闭文件句柄的精确 transcript；排队 beforeSubmit 不替换进展，同代 stop/response 阻止迟到 thought 重新显活跃。thought 只报告 processOnly 近期模型进展，不声明 busy；stop 可能触发新 generation 自动 followup，不据此宣称 Completed。独立 cursor.cli Profile 无 phase/attention/completion 权威，未知 Hook 版本 incompatible。显式安装入口已实现；GUI 操作、登录后的状态/返回仍待验收，不自动写用户 hooks.json。
- Cursor 安装复用 JSONHookIntegration/configure-json-hooks 事务，仅格式分支使用 hooks.json、version:1、flat command 与秒级 timeout。生成配置已通过固定官方 ConfigLoader→HookExecutor→真实 shell→收集器→卸载的隔离验证。Cursor JSONC 解析限制单独核验，不把 BOM、尾逗号或会改变字符串值的注释标记写成“有效安装”；其他 Provider 的 JSONC 行为不变。归属 marker 改引号/空白但内容不匹配时拒绝覆盖或追加。设置一次管理一个目标，先移除才能换目录；成功安装后才更新目标，未确定的写入单独保留待恢复目标，旧安装身份不被失败覆盖。
- 新 scope 遇到 128 上限时，有界回收超过 24 小时且 owner PID 明确 ESRCH 的私有事件目录。检查 schema、名称 hash、mtime、大小、权限、inode 和符号链接，原子迁入私有 `.gc` 后再验证，仅 unlink 已验证事件及 rmdir 空目录，不递归删除。每次约 200ms 协作预算、最多迁入 4 项；Hook 总期限仍为 1800ms。隔离溢出先分批恢复旧项，再拒绝新增；活跃 PID、unbound、近期或未知数据均保留。全部为活跃/未知或隔离数据不可验证时仍可能拒绝新 scope，不声称无限容量或自动清理所有情况。安装副本内容寻址，已有安装需要显式重装才更新；App 重启不静默覆盖用户 Hook。
- `JSONHookIntegration.swift` 与 `configure-json-hooks.mjs`：Gemini 0.58.0 / Qwen 0.23.0 显式安装、重装和移除入口。使用固定 Microsoft jsonc-parser 3.3.1（MIT）局部修改用户所选 settings.json，不调用 Provider 设置加载器、不更改禁用或信任开关。配置检查、备份、安装意图和写入在排他锁内；失败仅恢复仍等于本次写入内容的配置，保留插入的用户修改。重复失败的升级仍记录实际旧定义，缺失脚本可重装修复。异常终止留下的锁须人工确认进程结束后恢复，不自动抢锁。版本探测清理会覆盖版本或参数的 CLI/relaunch 环境变量；观察身份不因此得到审批权威。隔离安装/官方合成事件契约已验证，GUI 安装、真实模型任务和精准返回仍待验收。
- `MistralHookIntegration.swift` 与 `install-mistral.py`：设置页显式选择 VIBE_HOME、Node 24+ 后，由所选 Vibe 的 Python 校验 2.25.0 版本及官方 HookConfig，再备份并原子添加校验和保护的独立配置块。脚本副本按内容寻址，不受 App 移动影响。原生 Swift 卸载不依赖 Vibe/Python，保留块外原文；安装与卸载共用文件锁，配置和备份从临时写入起保持 0600。超时不能证明未修改，必须显示结果不确定及确定的备份目录；不会假称自动恢复成功。真实模型生命周期仍须另外验收。
- `WorkBuddySessions.swift`：WorkBuddy 5.5.3 / 内置 CodeBuddy 2.137.1 的实验桌面表面。Scanner 从运行应用的 Bundle ID、实际位置与版本发现内置引擎；核验 Hook 中主 session、CLI/宿主双出生身份，跨 PID 依据事件新旧合并同一任务；同时间宿主冲突 stale 且禁用返回。同宿主的状态冲突不伪造结果，但身份明确时仍可返回检查。按私有会话 scope 逐批读，超预算报告 partial 并续扫；保留未访问宿主的较新观察但不刷新源时间。PostToolUse 只提供短时进展，20秒无新进展标 stale；FinalStop completed 只表示 run 结束，不宣称用户目标成功；generation_id 随模型请求变化，不作用户 turn ID。明确 failed/cancelled/interrupted 分别投影失败/停止，PermissionRequest 和 StopFailure 不授予审批/任务失败权威。可用准确主 session 构造 workbuddy://chat/<编码后的sessionID>，Handler 仍由共用 ReturnResolver 检查；未知版本只提供应用级打开。可选正文只读配置目录中精确 session/store ID 的文件，排除 tool_result；--no-session-persistence 下不猜别的历史。收集器空 stdout/exit0、只存白名单元数据，写盘前过滤已证明的子任务，避免挤占主任务缓冲；没有复制闭源代码。显式安装入口复用 JSONC 事务，版本检查只读 App/package 元数据；嵌套 command Hook 使用秒级 timeout:2。拒绝官方不支持的 BOM 配置，但允许保留 BOM 的精确自有移除并提示不兼容。设置界面、真实安装、任务与 GUI 返回仍待验收，不把 Reader 测试当作深度集成完成。
- `MistralSessions.swift`：已安装官方 Vibe 2.25.0，对照真实 HookExecutor 完成 stdin→收集器契约验证；按活跃父进程及出生身份、准确 transcript/session_id/cwd 绑定，不再扫描全部历史或按 cwd/前缀猜任务。pre_tool 在审批前触发，仅读“工具请求”而不声称运行或需要用户；post_tool 是工具结束边界，不是整项任务成功；post_agent 无最终结果，标记未知/stale。独立 mistral.cli Profile 不提供成功/审批/控制能力。真实账号、完整生命周期和终端返回尚未验收。
- `CodexAppServer.swift`：只在用户明确新建、续发或停止任务后使用官方 stdio app-server；持有 LoopFwd 自己创建的 thread、当前 turn 身份并接收实时 turn/item 事件。只把自建 thread 身份和 rollout 路径保存到 LoopFwd 偏好，启动时从 Codex rollout 只读恢复卡片，不启动控制进程。首版固定 `workspace-write + never`，在尚无审批 UI 时禁止静默越过 workspace sandbox。
- Mistral 2.25.0 在解析参数前以 setproctitle 改名为准确的 `Vibe CLI`，并使 macOS 的 KERN_PROCARGS2 不再返回 VIBE_HOME。收集器匹配准确标题，由其子进程自身环境计算并写入可选 providerDataRoot（schema 1），不接受事件载荷指定根目录；Reader 仍先匹配 PID/出生身份，再校验绝对路径、长度、当前进程可读根的一致性及 transcript/session/cwd。没有这项元数据的旧观察器不猜自定义目录，更新仍须显式重装。当前验证为真实欢迎页/退出、进程归属与合成事件传输，不等于真实模型生命周期。
- `TerminalBridge.swift`：把用户返回到实际终端；只有可验证 TTY/pane/thread 的目标标记 exact，应用激活标记 provider-only，无法定位时 fail closed 并记录诊断。
- `ApprovalCenter.swift`：可选 Claude hook。启动时不安装，只有用户主动操作才修改配置。
- Claude Hook v1 在发射时记录最多八层祖先 PID/UTC 出生身份；旧版无源身份的 spool 不再生成 attention，设置提供显式更新并备份旧脚本。读取限长且只接受最近30秒文件，请求时间不随消费刷新；会话/目录/进程身份均须匹配，问题由官方 `tool_use_id` 配对，Notification 只接受 `permission_prompt` 而不匹配文本关键词（[官方 Hook 字段](https://code.claude.com/docs/en/hooks)）。缓存、卡片与回复入口共用身份，发送前再验进程出生/TTY/Provider；控制继续为未实测 Labs，不把本地脚本回归当真实模型审批验收。
- `NotchPanel.swift`、`IslandView.swift`：成熟的刘海窗口、收展动画、session cards 和交互。展开态以 `NSTrackingArea` 驱动进入/离开和 150ms 收起缓冲；收起态由 AppKit 全局/本地指针监听按统一几何分成左翼、中央刘海与右翼。
- 收起态不改变 clean/detailed 视觉尺寸：仅中央刘海区接管鼠标以打开 Island，左右翼及大窗口的其余透明区均保持 click-through。指针在某翼停留 120ms 后只淡出该翼，离开 200ms 后恢复，无需 Accessibility 授权。
- 显示策略由 `NotchMetrics.hasNotch` 决定：真实刘海屏保留可见收起态；无刘海屏的收起态只留下顶部中央隐形热区，显式悬停或快捷键才展开，任务事件不自动常驻。
- 岛体不绘制外扩阴影或状态光晕，NSPanel 系统阴影也保持关闭，避免在全屏浅色内容上形成灰色外圈。深度提示保留在岛内渐变、细边框与卡片中；内容与背景继续共享轮廓/左右翼遮罩，不改变几何尺寸与点击区域。用户已确认原报告场景不再闪烁且灰圈已消失；不据此推断其他显示器、全屏应用、Space 或睡眠唤醒场景均已通过。
- “全屏时隐藏”由 AppKit 原生 Space 资格控制：开启时用 `fullScreenPrimary` 排除加入其他应用的全屏空间，关闭时用 `fullScreenAuxiliary`；普通桌面仍保留 `canJoinAllSpaces`/`stationary`。不再通过菜单栏高度猜测全屏，也不再用定时器反复修改窗口透明度。快捷键与指针读取 `isOnActiveSpace`，避免拉出当前空间不可见的窗口。依据 [Apple 窗口空间说明](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)，真实全屏/多屏切换仍需实机验收。
- `SessionList` 是菜单栏、Island、通知和快捷键共享的合并入口；相同稳定 ID 只显示一次，带真实控制能力的托管投影优先。
- 状态契约将结果与操作请求分开：Completed 只表示成功结束，Needs attention 只表示真实 question/approval/auth/confirmation，Failed 与 Stopped 保留原始结果，Idle 不进入主 Island。`Possibly stalled` 只在 rich 会话已确认运行且超过当前 IntegrationProfile 阈值时出现；普通响应与已知长工具任务使用不同预算。`OutcomePresentation` 处理结果展示：Completed 保留 5 秒，Stopped 保留 8 秒，Failed 持续到用户查看/返回或新 turn 恢复；它不持久化结果列表，也不把启动扫描中的旧短暂结果当成新事件。
- stale 是短暂失联诊断态，不是历史列表。Idle 即使 stale 也不会进入活动 Island；原本处于 Working 的会话在各 Profile 的短暂 reconciliation grace 内保留，超过宽限仍未恢复便退出，Provider 自己的对话文件不受影响。

## 扩展方式

Kimi 0.41.0 的生命周期 Hook（SessionStart/SessionHeartbeat/SessionEnd）通过显式安装的
只读收集器记录 PID/出生身份和配置命令中的数据根；心跳每60秒，仅续身份租约，不续任务进展。
Reader 同时读取全部匹配会话的 `state.id/cwd` 与准确 `agents/main/wire.jsonl`，避免官方
每批写入即关闭文件句柄导致漏报。150秒未续租标 stale，SessionEnd 后的迟到心跳不重新打开会话，
只有新的 SessionStart 才可恢复。生命周期不提供成功、审批或控制权威；主 wire 1.5 仍是状态源。
官方 `client_type=kimi_code_cli` 被 TUI/Web/ACP 共用，不能据此声明 TUI 模式或精确跳转；
统一返回解析只提供可验证的应用级打开。配置使用现有 TOML 事务的 Kimi 分支，固定 npm0.41.0，
保留备份/移除/脚本修复路径，Python3.11+仅在明确设置操作中运行。未修改真实 Kimi 配置或验证模型任务。

共用 Hook 脚本启动判断使用真实路径比较，兼容 macOS `/var` 路径别名和脚本符号链接；
普通模块导入仍不启动收集。该问题由官方 Kimi 分发器的隔离 shell 契约复现，修复后中性空输出及私有事件落盘通过。

Mistral 的相对 VIBE_HOME 和 session_logging.save_dir 均按实际工作目录解析；CLI 已执行 --workdir 的 chdir 后，不再次应用原始相对参数。未知数据根不从最近历史推测。

Desktop 的只读发现使用 `DesktopRegistryScan`：按稳定身份分页补全历史，最近更新及已知活动会话优先刷新。未扫描完显示 partial，并保存未访问队列；缓存不刷新进展时间，超过 20 秒未重读时标记 stale。SQLite 使用原生 progress handler 中断超时查询，Codex/OpenCode 两个独立数据库最多并行读取，不增加自有数据库或后台服务。

CLI 进程读取由 `ProviderProcessReadSchedule` 在进程之间分配各 Provider 的独立预算，未访问的 PID 下一轮优先；暂未读取不当作成功空列表，统一 reducer 保留最后可信状态并按既有宽限处理。耗时使用单调时钟。它是批次准入上限，不是同步文件 I/O 的强制取消；子进程仍使用 `BoundedProcess` 的真实期限。Codex CLI 不再遍历历史目录猜绑定，只接受已核验的打开文件；未找到绑定时保留 process-only，既有绑定失联时保留 stale。

所有 provider 先通过同一进程发现路径进入 `AgentSession`。需要富状态时再增加独立的 `<Provider>Sessions.swift` reader，并在 `AgentMonitor` 中合并；只有 provider 有真实实时协议时才增加连接器，不先创建通用 Adapter 框架。

### 统一任务模型

一条会话必须分开四个维度，不允许用一个文案混合：

1. Task phase：Working、Possibly stalled、Completed、Failed、Stopped、Idle。
2. Attention：question、approval、authentication、confirmation；只有真实待操作请求才能进入 Needs attention。
3. Observation health：rich、process-only、stale、incompatible。
4. Evidence/freshness：official live → official local store → versioned observer → process heuristic，同时保留 source updated time。

Reader 只负责生成原始观察；`AgentLifecycleReducer` 负责跨 Provider 的转换和去重。Reader 读取失败时不得把上一个已知状态改成 Idle；只能改变 health，等待恢复或超过有界 grace period 退出。

### 新 Agent 适配准则

每个新 Reader 必须提供或明确缺失：`providerID`、稳定 `sessionID`、可选 `turnID/processID`、项目身份、最新用户任务、当前步骤、原始 phase、attention request、最后进展/状态/数据时间、health、authority/source、`ReturnTarget` 与实际 capabilities。

- 稳定身份不得仅使用 PID；两个会话必须能同时区分，进程重启不得换卡。
- 任务标题来自最新用户任务或结构化 Goal；当前步骤来自 tool/activity/todo，两者不互相覆盖。
- 只有 Provider 明确的 turn/tool/stream 边界可声明 Working/Completed/Failed/Stopped；CPU 只能声明 Activity detected。
- 只有当前存活的问题、审批、登录或确认请求可声明 Needs attention。“打开 Provider”与“精确返回会话”是两个 capability；Reply、Approve 和 Stop 也必须另外证明当前存活的控制坐标。
- 新增一个品牌入口不等于完成适配；未通过实机矩阵前只能标记 Experimental。

0.1.0 预览以基础监控、稳定身份、明确结果、按实际能力返回和安全降级为门槛；未认证的可选接入标为 Experimental，不以穷举账户/环境阻塞发布。审批和控制只在来源确实支持时验证，缺失则不宣称支持。稳定版再扩展权限拒绝/恢复、崩溃、睡眠唤醒等组合验证。自动 fixture 验证解析契约，不冒充真实 Provider 任务证据。

### 通知准则

- Needs attention 和 Failed 默认开；Completed 一个 turn 仅一次；Possibly stalled 默认关；Started/Stopped 默认关。
- 首次扫描、App 重启恢复、stale/incompatible 和 CPU 状态变化不产生通知。
- 同一 session + turn + event + revision 去重；350ms 内同类型爆发合并。
- 只有确认正在查看同一任务时才抑制 banner、声音和自动展开；仅 Provider App 在前台不足以抑制，不丢失 Island 内部状态。单条通知点击按实际能力返回，批量通知点击展开 Island。

终端可见性按批次在后台查询，同一事件类型最多一个查询执行中；后续事件合并等待。查询仅在已有 Apple Events 授权时读取选中 TTY，不申请权限。迟到结果按会话检查令牌和当前通知开关，任务恢复、已查看或设置关闭后不会重新投递旧提醒。Island 只消费统一 router 已接受的事件，不重复探测终端。通知正文和聚合标题来源均限制文本长度。

通知队列、查询和聚合只保留 `AgentNotificationRecord`：原始语义去重键、会话 ID、80 字标题、180 字目标摘要及被动终端定位字段。不会连带持有 transcript、长提示词、计划、Todo 或控制载荷；通知点击仍按 ID 查询当前真实会话，不把旧通知快照当控制授权。

OpenCode TUI 在显式开放端口时以官方 HTTP polling 为状态权威，permission/question 只回复同一进程仍然存活的官方 loopback 请求；Desktop 当前只读其本地 store，不从数据库身份推导控制权。SSE 只在版本实测可靠后用作加速。Codex 需要双向控制时直接使用官方 app-server，不自造协议。

Codex 外部终端进程与 LoopFwd 托管 thread 是两条明确路径：前者只观察并 Jump，后者才允许 app-server 指令。独立 app-server 不能证明拥有任意正在运行的 TUI，因此不得用 rollout 路径猜测控制权。

托管 Codex 的 Stop 使用官方 `turn/interrupt(threadId, turnId)`，只在服务端返回中断完成事件后结束 UI 工作态，且不发送普通完成通知。它停止的是 Agent turn，不承诺撤销已经发生的文件、网络或命令副作用；已经交给底层执行器的进程可能自行收尾。

移除托管卡片只删除 LoopFwd 偏好中的 thread 身份和当前内存投影，不调用 provider 删除接口，也不触碰 Codex conversation 或 rollout。工作中的 turn 必须先 Stop；UI 明示保留 provider history 并要求二次确认。

## 权威边界

- `ps`、`lsof`、CPU 和 transcript tail 可以用于发现、观察和 Jump；reader 失败必须以 process-only、stale 或 incompatible 显示。
- Approve、Deny、Answer 必须对应仍然存活的 provider/terminal 请求。
- 解析失败、桥接失败或请求过期必须关闭控制，不得生成成功结果。
- 启动路径不得自动改登录项、通知权限或 provider 配置。

## 暂不建设

SQLite、UDS、后台 daemon、云端账号、手机同步、Policy Engine、History/Memory 和跨设备路由都留到对应真实需求出现之后。
