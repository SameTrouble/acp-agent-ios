# TestFlight 发布指南

让 ACP Agent iOS app 上架 TestFlight、在真机上无线更新的完整流程。
对应 issue #14。

## 验收标准对照

| #14 验收项 | 验证步骤 | 对应章节 |
| --- | --- | --- |
| app 经 TestFlight 安装到真机并正常运行 | 从 TestFlight 安装，打开 app 并连上服务器 | §1–§4, §7 |
| 在真实网络下完整走一遍监督回路：发任务、收通知、审批 | 4G + EasyTier 环境下：新建会话、发消息、触发审批、收到 Bark 通知、点同意 | §7 验收清单 |
| 后续构建无需连接电脑即可在手机上更新 | 重新跑一次 release 脚本，手机端 TestFlight 点 Update | §3, §5 |

## 前提条件

- Apple Developer Program 付费账号（个人或团队均可）
- Mac 上安装 Xcode 16+、xcodegen、`gh`
- App Store Connect 上已经创建好一个 app，Bundle ID 为 `com.acp-agent.ios`
- 一个 App Store Connect **API Key**（有 App Manager 或以上权限），
  私钥放在 `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`

## 1. 一次性配置

### 1.1 Bundle ID & App

在 Apple Developer 后台和 App Store Connect 各做一次：

- Developer → Certificates, Identifiers & Profiles → Identifiers →
  新建 `com.acp-agent.ios`
- App Store Connect → My Apps → 新建 App，选刚创建的 Bundle ID

### 1.2 签名

项目用 **自动签名**（`CODE_SIGN_STYLE: Automatic`）。Release 构建时
Xcode 会自动为 App Store 分发生成/下载 Distribution 证书和描述文件，
仓库里不留任何证书或 profile。

唯一需要手动配置的是开发团队 ID，通过环境变量注入：

```sh
export ACP_DEVELOPMENT_TEAM=你的10字符团队ID
```

可以写进 `~/.zshrc` 或单独的 `.env` 文件。

### 1.3 App Store Connect API Key

用于上传构建，不需要登录开发者账号：

- App Store Connect → Users and Access → Keys → App Store Connect API
- 生成一个 Key，给 App Manager 权限
- 下载 `AuthKey_<KEY_ID>.p8`，放到 `~/.appstoreconnect/private_keys/`

```sh
export ACP_ASC_KEY_ID=你的keyId
export ACP_ASC_ISSUER_ID=你的issuerId
```

## 2. 发布一个新版本

### 一键发布

```sh
cd acp-agent-ios
ios/scripts/release-testflight.sh
```

脚本做的事：

1. 用 `git rev-list --count HEAD` 生成单调递增的构建号
2. `xcodegen generate` 生成 Xcode 工程
3. `xcodebuild archive` 归档为 `.xcarchive`
4. `xcodebuild -exportArchive` 导出 `.ipa`
5. `altool --validate-app` 校验元数据
6. `altool --upload-app` 上传到 TestFlight

上传后在 App Store Connect → TestFlight → 构建里能看到，
处理完成通常需要 2–10 分钟。

> 只想打个本地包验证一下？加 `--no-upload`：
> ```sh
> ios/scripts/release-testflight.sh --no-upload
> ```
> 产物在 `ios/App/.build/export/ACPAgent.ipa`。

### 自定义构建号

默认用当前分支的 commit 数量。需要手动指定时：

```sh
ACP_BUILD_NUMBER=42 ios/scripts/release-testflight.sh
```

> ⚠️ 构建号只在同一个分支递增才单调。从 commit 数更少的 hotfix 分支
> 发版会撞上已有的构建号被 TestFlight 拒绝。这种情况务必手动指定。

### 手动方式（用 Xcode UI）

1. 打开 `ios/App/ACPAgent.xcodeproj`
2. 顶部选 **Any iOS Device (arm64)**
3. Product → Archive
4. 归档完成后选 **Distribute App → App Store Connect → Upload**
5. 按提示下一步直到提交

## 3. 真机安装

构建处理完后，在 App Store Connect 的 TestFlight 标签页：

1. Internal Testing → 创建一个组，把自己加进去
2. 找到刚上传的 build，点 + 添加到测试组
3. 在手机上装 **TestFlight** app，用同一个 Apple ID 登录
4. 接受邀请 → 安装 ACP Agent

后续有新版本时，TestFlight 会自动在 Wi-Fi 下更新，或者手动点 Update。
**手机不需要连电脑**。

## 4. 连接 companion 服务器

TestFlight 装的 app 当然不能连 `localhost`。真实使用场景：

| 场景 | 怎么填 | 说明 |
| --- | --- | --- |
| 家里/公司局域网 | `ws://192.168.1.20:8787` | 同局域网直连 |
| 公网服务器 | `wss://acp.example.com:8787` | 建议配 TLS |
| EasyTier 虚拟局域网 | `ws://10.126.126.2:8787` | 虚拟 IP，异地穿透 |
| Tailscale / WireGuard | `ws://100.64.x.x:8787` | 任意 VPN 虚拟 IP |

参考 `companion/DEPLOY.md` 把 companion 部署到一台一直开机的机器上，
推荐用 EasyTier 组网，手机装 EasyTier 客户端直连虚拟 IP。

> **关于 ATS**：App 开启了 `NSAllowsArbitraryLoads`，因为用户连接的
> 是自己的 companion 服务器，地址不固定（局域网 IP、EasyTier 虚拟 IP、
> 自托管域名…）。只有用户手动输入的 token 会被发送，且 token 存在
> Keychain 里不外传。提交 App Store 审核（不是 TestFlight）时需要
> 在审核说明里解释这一点。

## 5. 后续更新

```sh
# 在主分支上提交你的代码
git add -A && git commit -m "feat: ..."

# 发新版，构建号自动递增
ios/scripts/release-testflight.sh
```

手机上 TestFlight 会自动提示更新。

## 6. 通知

ACP Agent 本身不注册 APNs 推送 —— 通知通过 **Bark** 第三方 app 发送，
由 companion 服务器在需要审批/会话结束时触发。要在真机上验证通知：

1. 手机 App Store 装 Bark，打开后复制设备 key
2. 在 companion 的 `companion.json` 里配好 `bark.deviceKey`
   （详见 `companion/README.md`）
3. 重启 companion 服务
4. 发起一个需要审批的任务，Bark 会弹出通知 → 点通知 → 跳到 ACP Agent → 在 app 里审批

## 7. 验收清单

上传第一个 build 后，按以下步骤逐项核对，确认 #14 三项 AC 全部通过：

### AC1: TestFlight 安装并正常运行

- [ ] TestFlight 里能看到 ACP Agent，点 Install 能装上
- [ ] 打开 app 不闪退，出现 Server 配置页面
- [ ] 填一个有效 endpoint + token，点 Connect，能连上并看到会话列表

### AC2: 真实网络下完整走一遍监督回路

**前置条件**：
- companion 已部署到服务器（见 `companion/DEPLOY.md`）
- 手机和服务器在 EasyTier 虚拟网里（或其它可达方式）
- Bark 通知已配置好

**步骤**：
- [ ] 手机切到 4G/5G（不是 Wi-Fi）
- [ ] 打开 EasyTier 客户端，确认组网正常
- [ ] 打开 ACP Agent → 连接 `ws://<EasyTier虚拟IP>:8787`
- [ ] 新建一个会话，发一条简单消息（比如 "hi"）→ 能收到回复 ✅ 发任务
- [ ] 发起一个需要工具审批的任务（比如让它修改一个文件）→ Bark 弹出通知 ✅ 收通知
- [ ] 点通知 → 跳回 app → 在审批卡片上点 Approve → agent 继续执行 ✅ 审批

### AC3: 无线更新

- [ ] 本地做一个微小改动（比如改个文案）并 commit
- [ ] 重新跑 `ios/scripts/release-testflight.sh`
- [ ] 构建处理完后，手机 TestFlight 里出现 Update 按钮
- [ ] 点 Update，新版能正常安装并打开

## 8. 故障排查

### 签名失败

```
error: No profiles for 'com.acp-agent.ios' were found
```

检查 `ACP_DEVELOPMENT_TEAM` 环境变量是否设置，以及 Xcode 里
是否登录了对应 Apple ID（Xcode → Settings → Accounts）。

### 上传失败 "Invalid Provisioning Profile"

多半是自动签名拉到了旧的 profile。清一下缓存：

```sh
rm -rf ~/Library/MobileDevice/Provisioning\ Profiles
# 然后重新跑 release 脚本，Xcode 会重新下载
```

### altool 报错 "Unable to upload"

- 确认 `AuthKey_*.p8` 在 `~/.appstoreconnect/private_keys/` 下
- 确认 key id 和 issuer id 拼写正确
- 网络问题：换个网络或挂代理

### 真机连不上服务器

- 确认服务器端 companion 在运行：`systemctl status acp-companion`
- 确认端口可达：手机浏览器访问 `http://<ip>:8787/health`（如果服务器开了 health endpoint）
- EasyTier 场景：手机上 `easytier-cli peer` 看对端是否在线
- ATS 问题：App 已开 `NSAllowsArbitraryLoads`，理论上不会被拦；如果遇到连接失败先检查网络本身
