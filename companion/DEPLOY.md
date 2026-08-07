# companion 服务器部署指南

从一台空的 Linux 服务器到手机连通的完整流程。companion 经
`bun build --compile` 交叉编译为单个 Linux 二进制，服务器上**不需要安装
bun 或 node**。唯一的外部依赖是 agent 本身（默认 `opencode`）。

对应 issue #13 的验收标准：

| 验收项 | 对应章节 |
| --- | --- |
| Mac 交叉编译出可运行的 Linux 二进制 | §1 构建 |
| systemd 开机自启、崩溃重启、journalctl 日志 | §5 systemd 托管 |
| 从空服务器到手机连通的完整流程 | §2–§7 |
| 二进制版本与 `~/.config` 配置约定 | §3、§4 |

## 1. 在 Mac 上构建

```sh
cd companion
bun run build:linux
# 产出：dist/acp-companion-linux-x64（约 90 MB，ELF x86-64）
```

产物自带版本号，构建后即可在 Mac 上核对行为逻辑（darwin 等价冒烟）：

```sh
bun run src/main.ts --version   # acp-agent-companion 0.1.0
```

目标服务器为 arm64 时改用
`bun build --compile --minify --target=bun-linux-arm64 src/main.ts --outfile dist/acp-companion-linux-arm64`。

## 2. 上传并安装二进制

```sh
scp companion/dist/acp-companion-linux-x64 you@server:/tmp/
ssh you@server
sudo mv /tmp/acp-companion-linux-x64 /usr/local/bin/acp-companion
sudo chmod +x /usr/local/bin/acp-companion
acp-companion --version          # acp-agent-companion 0.1.0
```

## 3. 创建服务用户并写配置

companion 从运行用户的 `$XDG_CONFIG_HOME`（默认 `~/.config`）读取配置，
符合 `~/.config` 约定：

```sh
sudo useradd --create-home --shell /usr/sbin/nologin acp
sudo -u acp mkdir -p /home/acp/.config/acp-agent
sudo -u acp tee /home/acp/.config/acp-agent/companion.json > /dev/null <<'EOF'
{
  "host": "0.0.0.0",
  "port": 8787,
  "tokens": ["换成你自己的强随机串"],
  "agent": { "command": "opencode", "args": ["acp"] }
}
EOF
sudo chmod 600 /home/acp/.config/acp-agent/companion.json
```

`tokens` 是手机连接时的凭据，可以放多个；泄露的 token 从数组里删掉再
重启服务即视为吊销。

## 4. 安装 agent（opencode）

companion 通过 `agent.command` 拉起 agent 子进程。opencode 是单二进制，
同样不依赖 node：

```sh
curl -fsSL https://opencode.ai/install | bash
sudo ln -s /home/you/.opencode/bin/opencode /usr/local/bin/opencode
sudo -u acp opencode --version
```

首次使用 opencode 需要登录模型提供商（`opencode auth login`），在 `acp`
用户下完成一次即可，凭据落在 `/home/acp/.local/share/opencode`。

## 5. systemd 托管

仓库自带单元文件 `companion/deploy/acp-companion.service`：开机自启、
崩溃 2 秒后自动重启（5 分钟内连续失败 10 次后暂停重试，防止配置错误
无限抖动）、日志进 journal。

```sh
scp companion/deploy/acp-companion.service you@server:/tmp/
ssh you@server
sudo mv /tmp/acp-companion.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now acp-companion
```

验证：

```sh
systemctl status acp-companion
journalctl -u acp-companion -f
# 期望看到：
#   agent initialized: ...
#   companion listening on http://0.0.0.0:8787 with N token(s)
```

崩溃重启用 `kill -9 $(pidof acp-companion)` 演练一次，应看到 2 秒后
重新拉起。不想被 systemd 托管时，也可以前台裸跑：

```sh
sudo -u acp /usr/local/bin/acp-companion            # Ctrl-C 退出
```

## 6. 组网：让手机够得着服务器

两条路，按服务器网络条件二选一。

### 方案 A：服务器有公网 IP / 已做端口转发

放行 8787 端口（ufw 示例）：

```sh
sudo ufw allow 8787/tcp
```

手机直连 `ws://<公网IP>:8787`。注意 WebSocket 全程明文，公网直连时
token 就是唯一防线，务必用强随机串并定期轮换；在意安全请前置 TLS
反代或改用方案 B。

### 方案 B（推荐）：EasyTier 虚拟局域网

服务器没有公网 IP，或不想暴露端口时，用
[EasyTier](https://easytier.cn) 把服务器和手机拉进同一个虚拟局域网。

**服务器侧**（一键安装脚本会装到 `/opt/easytier` 并注册 systemd 服务）：

```sh
wget -O /tmp/easytier.sh "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh"
sudo bash /tmp/easytier.sh install
# 加入你的网络：网络名与密码在所有设备上保持一致
sudo systemctl start easytier@default
sudo /opt/easytier/easytier-cli peer          # 看到对端即组网成功
```

若用自定义网络，编辑 `/opt/easytier/config/default.conf`（或
`easytier-cli` 重新配置）填入 `--network-name` / `--network-secret`，
并记录本节点分配到的虚拟 IP（默认 `10.126.126.0/24` 网段，例如
`10.126.126.2`）。

**手机侧**：安装 EasyTier 手机客户端，填同样的网络名与密码，连接后手机
也拿到一个虚拟 IP。

**推荐配置要点**：

- companion 的 `host` 保持 `0.0.0.0` 即可，虚拟网卡也在监听范围内；
  想只暴露给虚拟网可改为 EasyTier 的虚拟 IP。
- 服务器防火墙只需对 EasyTier 虚拟网卡放行 8787，公网不暴露任何端口。
- 手机 App 里填 `ws://10.126.126.2:8787`（换成你服务器的虚拟 IP）。

## 7. 手机连通验证

打开 iOS App 的连接界面：

1. Server 填 `ws://<服务器IP或EasyTier虚拟IP>:8787`；
2. Token 填 companion.json 里的任一 token；
3. Connect，进入会话列表即连通。

服务器侧同步确认：

```sh
journalctl -u acp-companion -n 20     # 出现 auth 成功的连接日志
```

## 8. 升级与卸载

```sh
# 升级：Mac 上重新构建 → 覆盖二进制 → 重启服务
scp companion/dist/acp-companion-linux-x64 you@server:/tmp/
ssh you@server 'sudo mv /tmp/acp-companion-linux-x64 /usr/local/bin/acp-companion \
  && sudo chmod +x /usr/local/bin/acp-companion \
  && sudo systemctl restart acp-companion'
acp-companion --version               # 核对新版本

# 卸载
sudo systemctl disable --now acp-companion
sudo rm /etc/systemd/system/acp-companion.service /usr/local/bin/acp-companion
sudo rm -r /home/acp                   # 配置与会话存储一并清除
```

## 故障排查

| 现象 | 排查 |
| --- | --- |
| 服务反复重启后进 `failed` | `journalctl -u acp-companion -n 50`；多为配置缺 `tokens` 或 opencode 未装。修复后 `sudo systemctl reset-failed acp-companion && sudo systemctl start acp-companion` |
| 日志报 `agent process exited` | 以 `acp` 用户手动跑一遍 `opencode acp`，确认登录态与版本 |
| 手机连不上但服务器本地正常 | `ss -ltnp | grep 8787` 确认监听；检查防火墙/EasyTier `peer` 列表 |
| 配置找不到 | 单元以 `User=acp` 运行，配置必须在 `/home/acp/.config/acp-agent/companion.json`；或在 ExecStart 后追加显式路径 |
