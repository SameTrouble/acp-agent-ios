# ACP Agent

在手机上监督与驱动 AI 编码 agent 会话：iOS app 通过自托管的 companion
服务器，连接运行 [opencode](https://opencode.ai) 的 [ACP](https://agentclientprotocol.com)
（Agent Client Protocol）进程。随时随地发起任务、看流式回复、审批工具调用。

```
┌────────────┐   WebSocket JSON-RPC   ┌──────────────────┐   ACP 子进程   ┌──────────┐
│  iPhone app │ ◄────────────────────► │  companion 服务器 │ ◄────────────► │ opencode │
│  (ACP Agent)│   auth + session/*    │   (Bun/TS, 自托管) │  init/auth/... │   acp    │
└────────────┘                        └──────────────────┘                └──────────┘
```

## 功能一览

| 功能 | 说明 |
| --- | --- |
| 流式回复 | agent 消息实时滚动显示，markdown 渲染 |
| Thinking 气泡 | agent 的思考过程单独成组，可折叠 |
| `@` 文件引用 | 输入 `@` 模糊搜索项目文件，以 chip 形式附加到消息 |
| `/` 命令补全 | 列出 agent 公布的所有斜杠命令，直接选 |
| Diff 卡片 | 文件修改折叠成卡片，展开看红绿 unified diff |
| 审批卡片 | agent 请求权限时逐项 Approve / Reject |
| Bark 通知 | 需要审批、会话完成/失败时推送到手机 |
| 模型/模式切换 | 会话内直接切换 agent 配置项（模型、模式等） |
| 会话历史 | 按项目分组，已结束的会话归入 Ended，随时回看 |
| 断线恢复 | 从上次读到的位置续传消息，不丢内容 |
| 多端同步 | 多个设备连接同一服务器，会话状态实时一致 |

## 快速开始

从零到第一次在手机上给 agent 发任务，大约 10 分钟。

### 1. 跑起 companion 服务器

**方式 A：在 Mac 上直接跑（体验最快）**

需要先装 [Bun](https://bun.sh) 和 [opencode](https://opencode.ai)：

```sh
cd companion
bun install

# 写一份最小配置（首次）
mkdir -p ~/.config/acp-agent
cat > ~/.config/acp-agent/companion.json <<'EOF'
{
  "tokens": ["换成你自己的随机字符串"]
}
EOF

bun run start
```

看到 `agent initialized` 日志即启动成功，默认监听 `0.0.0.0:8787`。

**方式 B：部署到 Linux 服务器（长期使用）**

```sh
cd companion
bun run build:linux     # 产出 dist/acp-companion-linux-x64 单文件二进制
```

服务器上不需要装 bun/node。systemd 托管、EasyTier 组网等完整流程见
[`companion/DEPLOY.md`](companion/DEPLOY.md)。

### 2. 手机装 app

App 通过 TestFlight 分发（无需连接电脑）。完整发布与安装流程见
[`ios/RELEASE.md`](ios/RELEASE.md)，要点：

- 手机装 TestFlight，用同一个 Apple ID 登录
- 接受邀请，安装 **ACP Agent**

### 3. 手机连接服务器

打开 app 进入 Server 配置页，填两样东西：

- **Server endpoint**：`ws://<服务器地址>:8787`
- **Access token**：与 `companion.json` 里 `tokens` 数组中的任一个一致
  （token 存在手机 Keychain 里，不离开设备）

| 场景 | 填什么 | 示例 |
| --- | --- | --- |
| 手机和 Mac 同一局域网 | Mac 的局域网 IP | `ws://192.168.1.20:8787` |
| EasyTier 虚拟局域网 | 虚拟 IP | `ws://10.126.126.2:8787` |
| Tailscale / WireGuard | 任意可达的虚拟 IP | `ws://100.64.x.x:8787` |
| 公网服务器 | 域名 + TLS | `wss://acp.example.com:8787` |

<!-- TODO(截图): docs/screenshots/server-config.png — Server 配置页 -->

### 4. 新建会话，发第一条消息

连接成功后进入会话列表页，点右上角 `+`：

- 顶部是**最近项目**快捷入口，直接点即用
- 下方是**服务器目录浏览器**，一路点进项目文件夹，点 **Use This Folder**

会话创建后自动进入详情页，在输入框发一条消息试试。agent 的回复会
流式显示。

<!-- TODO(截图): docs/screenshots/session-list.png — 会话列表（含 Ended 分组） -->

## 使用教程

### 发消息与流式回复

输入框支持多行（1–6 行），发送后 agent 的回复以 markdown 流式渲染。
回复期间输入框变为取消按钮，可以随时 **Cancel** 终止当前回合。

### Thinking 气泡

agent 的思考过程以紫色气泡显示在回复上方，可折叠。想只看结论时点一下
就收起来。

### `@` 引用文件

输入 `@` 会弹出模糊搜索面板，搜索范围是当前会话的工作目录（子串优先、
basename/前缀命中排前，`node_modules`、`.git` 等目录自动跳过）。选中后
文件变成可移除的 chip，消息里可以混排多个 `@` 引用和普通文字。

发送时 app 只发文件路径，**不发文件内容**；由 companion 把引用展开成
agent 能读的形式（详见[协议参考](#companion-协议参考)）。

### `/` 命令补全

输入 `/` 列出 agent 公布的斜杠命令（来自会话更新流），选中后输入框
自动填入命令等待参数。

### Diff 卡片

agent 修改文件时，每个文件一张可折叠卡片：折叠时看文件名和状态摘要，
展开看红绿 unified diff（删除红、新增绿）。

<!-- TODO(截图): docs/screenshots/session-detail.png — 会话详情（含 diff 卡片） -->

### 审批卡片

当 agent 请求权限（比如要执行命令、改文件）时，会话里出现审批卡片，
每个可选项一个按钮，例如 **Allow once / Always allow / Reject**。
选完卡片显示最终结果；会话列表中待审批的会话会带红色角标。

> ⚠️ **为什么我发任务从不弹审批？** opencode 的权限默认是放行的——
> 大多数工具默认 `allow`，只有访问会话目录之外的路径（`external_directory`）
> 默认询问。要让 bash / 编辑等操作先问你再执行，需要在 agent 配置里设
> `"permission": { "bash": "ask", "edit": "ask" }`（详见 [ADR-005](docs/adr/0005-request-permission-wire.md)）。

<!-- TODO(截图): docs/screenshots/approval-card.png — 审批卡片 -->

### Bark 通知

app 本身不注册推送；通知由 companion 通过 [Bark](https://github.com/Finb/Bark)
发出，**需要审批**和**会话完成/失败**两类，各自可以独立开关（见
[companion 配置](#bark-通知配置)）。手机装 Bark 并填入设备 key 后，
agent 卡住等你审批时会推送到手机，点通知直接跳回 app 审批。

### 会话历史与断线恢复

会话列表按项目分组；已结束的会话自动归入 **Ended** 分组，可随时进入
回看完整记录。杀掉 app、切换网络后重连，会话从上次读到的位置续传，
已看过的内容不重复。

### 模型/模式切换

会话详情输入栏左侧的胶囊 chip 显示当前模型/配置摘要，点它打开
Configuration 面板，按 agent 公布的可选项切换（模型、模式等），选中即生效。

## companion 配置

companion 读取 `$XDG_CONFIG_HOME/acp-agent/companion.json`
（默认 `~/.config/acp-agent/companion.json`），也可以启动时指定路径：

```sh
bun run start /path/to/companion.json
```

完整示例见 [`companion/config.example.json`](companion/config.example.json)：

```json
{
  "host": "0.0.0.0",
  "port": 8787,
  "tokens": ["replace-me-with-a-real-token"],
  "agent": { "command": "opencode", "args": ["acp"] },
  "eventBufferCapacity": 1000,
  "bark": {
    "deviceKey": "replace-with-your-bark-device-key",
    "url": "https://api.day.app",
    "notifyOnApproval": true,
    "notifyOnSessionEnd": true
  }
}
```

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `host` / `port` | `0.0.0.0` / `8787` | 监听地址与端口 |
| `tokens` | — | 客户端连接凭证，非空数组，多个设备各用其一 |
| `agent.command` / `agent.args` | `opencode` / `["acp"]` | agent 子进程命令（测试时可用 mock 替换） |
| `eventBufferCapacity` | `1000` | 会话事件缓冲上限，断线重连时从此补发 |
| `bark` | 无 | 推送配置，整个小节省略即关闭通知 |

`--version`（或 `-v`）打印版本号后退出。

### Bark 通知配置

- `bark.deviceKey` — 手机 Bark app 里的设备 key，填了才推送
- `bark.url` — 默认 `https://api.day.app`，自建 Bark 服务器时覆盖
- `bark.notifyOnApproval` — 需要审批时推送，同一个待审批请求只推一次
- `bark.notifyOnSessionEnd` — 会话完成/失败时推送（失败推送带 agent 报错；
  你自己 Cancel 的不推）

## companion 协议参考

给客户端（或未来接入的其它客户端）的协议细节。

### `@` 引用展开（`file_ref`）

客户端发消息时把 `@` 引用写成 `file_ref` 块，companion 按 agent 在
`initialize` 时声明的能力展开：

```json
{
  "jsonrpc": "2.0", "id": 3, "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc",
    "prompt": [
      { "type": "text", "text": "compare " },
      { "type": "file_ref", "path": "src/server.ts" },
      { "type": "text", "text": " with " },
      { "type": "file_ref", "path": "src/acp.ts" }
    ]
  }
}
```

| agent 声明 | `file_ref` 变成 | agent 收到 |
| --- | --- | --- |
| `promptCapabilities.embeddedContext: true` | `resource` | 文件文本内联 |
| 其它 | `resource_link` | `file://` URI 自行读取 |

文件缺失、不可读、大于 1 MiB，或路径逃出会话 `cwd`（如 `../`）时，
一律降级为 `resource_link`——逃逸路径只给链接，不读文件。非 `file_ref`
块原样透传，文字与引用保持用户输入时的顺序。

### `files.search`

```json
{ "jsonrpc": "2.0", "id": 2, "method": "files.search",
  "params": { "sessionId": "sess_abc", "query": "srvr", "limit": 20 } }
```

返回 `{ "files": [{ "path": "src/server.ts", "score": 812 }, …] }`，
按匹配度排序，路径相对会话 `cwd`。匹配规则：子串优先，其次子序列，
basename/前缀命中排在深层路径之前；跳过 `.git`、`node_modules`、
`dist` 等目录，遍历有界，大仓库不会卡住。

### `dir.browse`

```json
{ "jsonrpc": "2.0", "id": 3, "method": "dir.browse",
  "params": { "path": "/Users/me/code" } }
```

返回 `{ "path": ..., "parent": ..., "entries": [...] }`——只列子目录，
按名称不区分大小写排序；`parent` 在文件系统根为 `null`；省略 `path`
从服务器 home 目录开始。客户端把返回的 `path`/`parent` 作为下一次请求
的 `path` 逐级导航。路径不存在或不是目录返回 InvalidParams（`-32602`）。

## 架构与仓库布局

Monorepo，两个可交付物：

```
acp-agent-ios/
├── companion/            # Bun + TypeScript WebSocket 服务器
│   ├── src/              #   server.ts（编排）/ acp.ts（ACP 子进程）/ session.ts（会话状态机）
│   ├── test/             #   用 mock agent 跑的完整测试套件
│   └── DEPLOY.md         #   Linux 部署指南
├── ios/
│   ├── ACPAgentKit/      # Swift 6 包，导出 ACPAgentCore
│   │   └── Sources/ACPAgentCore/   # ACPClient、ConversationStore、协议模型（纯逻辑，可测）
│   ├── App/              # SwiftUI app（xcodegen 从 project.yml 生成）
│   └── RELEASE.md        # TestFlight 发布指南
├── CONTEXT.md            # 领域术语表（Session、Conversation、Transcript…）
└── docs/adr/             # 架构决策记录（ADR-001 ~ 005）
```

关键设计：

- **companion 是唯一的桥**：spawn `opencode acp` 子进程，完成 ACP
  `initialize`/`authenticate` 握手；连接第一个消息必须是 `auth`；
  之后 `session/*` 方法透传给 agent，`session/update` 广播给所有已认证
  连接。客户端断开不影响会话和 agent 子进程。
- **iOS 端 ACPClient 是唯一视图缝**：SwiftUI 视图只读 `ACPClient`
  的发布状态、调它的公开方法，不直接碰 `JsonRpcClient`；
  `ConversationStore` 独占每个会话的对话状态（详见 [ADR-001](docs/adr/0001-core-ui-split.md)、
  [ADR-004](docs/adr/0004-conversation-store-split.md)）。
- **已知 wire 变体必须结构化解码**：即使暂不渲染也不允许落进
  `unsupported`（[ADR-003](docs/adr/0003-decode-known-variants-even-unrendered.md)）。

## 开发

### companion

```sh
cd companion
bun install
bun run typecheck   # tsc --noEmit
bun test            # 全套测试：mock agent 起服务器，覆盖 auth/透传/广播/断连
```

单文件测试：`bun test test/server.test.ts`。

### iOS

```sh
cd ios/ACPAgentKit && swift test          # 包内测试
cd ios/App && xcodegen generate           # 工程由 project.yml 生成，改文件后要重新生成
open ios/App/ACPAgent.xcodeproj
```

发布 TestFlight：`ios/scripts/release-testflight.sh`（`--no-upload` 只出
本地 IPA），完整流程见 [`ios/RELEASE.md`](ios/RELEASE.md)。

### 协作约定

- `main` 只通过 pull request 修改；提交信息引用 issue 号（如 `(closes #14)`）
- 给 AI agent 的仓库指南见 [`AGENTS.md`](AGENTS.md)，领域术语见
  [`CONTEXT.md`](CONTEXT.md)

## 已知限制

- **无 elicitation 卡片**：实测 opencode ACP 不发送 `elicitation/create`
  （[ADR-002](docs/adr/0002-elicitation-probe.md)），所以没有结构化提问
  界面；agent 用 markdown 提问时用普通输入框回答即可。
- **审批卡默认不出现**：opencode 权限默认放行，需要审批体验请在 agent
  配置里把工具设为 `ask`（见[审批卡片](#审批卡片)）。
- **plan / usage 暂不渲染**：`plan` 条目和 token 用量统计已结构化解码，
  但界面尚未展示（ADR-003）。
- **ATS 放行任意加载**：app 允许连接任意地址的 HTTP/WS，因为用户连的
  是自己的服务器（局域网 IP、虚拟 IP、自托管域名等）；只有用户手动输入
  的 token 会被发送，且存在 Keychain 中。提交 App Store（非 TestFlight）
  审核时需在审核说明中解释这一点。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [`companion/DEPLOY.md`](companion/DEPLOY.md) | Linux 服务器部署完整指南（systemd、EasyTier） |
| [`ios/RELEASE.md`](ios/RELEASE.md) | TestFlight 发布与真机安装、验收清单、故障排查 |
| [`CONTEXT.md`](CONTEXT.md) | 领域术语表：Session、Conversation、Transcript、Cursor… |
| [`docs/adr/`](docs/adr/) | 架构决策记录（Core/UI 拆分、协议解码、ConversationStore…） |
| [`AGENTS.md`](AGENTS.md) | 面向 AI agent 的仓库指南 |
