# xui-vps-cleanup

一个用于审计、清理和整理 Ubuntu/Debian VPS 的 Bash 脚本，目标是把服务器收敛为：

- x-ui / Xray 作为唯一的应用工作负载
- 保留 SSH、systemd、网络、DNS、cron、journald、Fail2Ban 等必要系统服务
- 清理历史遗留的桌面环境、XRDP、CUPS、Avahi、Node.js、npm、PM2 等组件
- 检查并在条件明确时整理 Netplan / systemd-networkd 与 legacy ifupdown 的重复网络配置
- 自动生成“清理前 → 清理后”报告

仓库：

https://github.com/transbot/xui-vps-cleanup

> 这个脚本不会安装 x-ui。它用于已经安装并运行 x-ui/Xray 的 VPS。

## 当前版本

v1.1.1

## 适用场景

适合这样的服务器：

- Ubuntu / Debian 系统
- 使用 systemd
- 使用 apt/dpkg
- 已安装并运行 x-ui/Xray
- 这台 VPS 以后只准备运行 x-ui/Xray，不再需要桌面、XRDP、打印服务、Node.js 网站等其他应用

不建议直接用于：

- 同时运行网站、数据库、Docker 应用、Node.js 服务等其他生产工作负载的服务器
- 网络配置非常特殊、不是常规 Netplan/systemd-networkd 的服务器
- 你无法确认哪些历史应用仍然需要保留的服务器

## 安全设计

脚本以“保守清理”为原则：

- 默认 `audit` 只读，不修改系统
- 删除应用栈前必须显式使用 `--confirm-xui-only`
- 清理桌面/RDP 等软件前会先进行 APT 模拟
- 如果模拟结果涉及 SSH、systemd、Netplan、NetworkManager、ifupdown、Fail2Ban 等保护组件，会停止操作
- 不删除 `/usr/local/x-ui`
- 不删除 x-ui 配置、数据库和 systemd service
- 不修改 SSH 配置
- 不盲删未知的 `/root`、`/var/www` 或其他项目数据
- 未知应用目录只报告，留给用户人工检查
- 网络清理不会在线重启网络
- 修改前会保存配置和系统状态快照

“x-ui only”指的是“只有 x-ui/Xray 作为应用工作负载”，不是让系统只剩一个进程。

## 推荐安装方式

第一次使用时，不建议直接 `curl | bash`。

先下载脚本：

```bash
curl -fsSLo /root/xui-vps-cleanup.sh https://raw.githubusercontent.com/transbot/xui-vps-cleanup/main/xui-vps-cleanup.sh
```

赋予执行权限：

```bash
chmod 700 /root/xui-vps-cleanup.sh
```

可先查看脚本：

```bash
less /root/xui-vps-cleanup.sh
```

检查 Bash 语法：

```bash
bash -n /root/xui-vps-cleanup.sh
```

如果没有任何输出，表示语法检查通过。

查看版本：

```bash
grep '^VERSION=' /root/xui-vps-cleanup.sh
```

## 第一次使用：先执行只读审计

```bash
/root/xui-vps-cleanup.sh audit
```

`audit` 不修改系统。

它会检查：

- 操作系统和版本
- Linux 内核
- uptime / load
- RAM / Swap
- 根分区磁盘占用
- systemd failed units
- x-ui 状态
- Fail2Ban 状态
- TCP / UDP 监听端口
- journald 占用
- `/var`、`/root` 等大目录
- GNOME / XFCE 等桌面环境
- XRDP
- CUPS
- Avahi
- Node.js / npm
- PM2
- Netplan
- systemd-networkd
- legacy `/etc/network/interfaces`
- x-ui 是否存在

建议先查看 audit 输出，再决定是否执行清理。

## 命令

### audit

只读审计：

```bash
/root/xui-vps-cleanup.sh audit
```

不会修改系统。

### clean

低风险清理：

```bash
/root/xui-vps-cleanup.sh clean
```

主要处理：

- 设置 journald 空间上限
- 清理较老 journal
- 清理 APT 缓存
- 清理 Snap 下载缓存

默认 journald 配置：

```text
SystemMaxUse=200M
SystemKeepFree=1G
```

可以临时覆盖：

```bash
JOURNAL_MAX_USE=300M JOURNAL_KEEP_FREE=2G /root/xui-vps-cleanup.sh clean
```

### prune-xui-only

清理已知的非 x-ui 应用栈：

```bash
/root/xui-vps-cleanup.sh prune-xui-only --confirm-xui-only
```

可能清理：

- Ubuntu Desktop
- GNOME
- XFCE
- XRDP / xorgxrdp
- CUPS
- Avahi
- Node.js / npm
- PM2
- 相关的自动依赖

该操作需要显式提供：

```text
--confirm-xui-only
```

表示你确认这台 VPS 不再需要这些其他应用工作负载。

如果仍有 Node.js 进程运行，脚本会拒绝自动卸载 Node.js，并把进程列出来供人工检查。

如果 `/var/www` 中仍然有未知网站数据，脚本不会删除，只会报告。

### fix-network

保守整理网络管理配置：

```bash
/root/xui-vps-cleanup.sh fix-network
```

只有在同时满足以下条件时才会整理 legacy 网络配置：

- 能找到默认路由网卡
- `systemd-networkd` 正在运行
- 存在 Netplan YAML
- `networkctl` 明确显示默认网卡由 Netplan 生成的 systemd-networkd 配置管理

确认后，脚本会：

- 将 `/etc/network/interfaces` 收敛为只保留 loopback
- 禁用 legacy `networking.service`
- 不在线重启网络

因此不会主动在 SSH 会话中重启网卡。

完成后建议正常重启 VPS。

### upgrade

执行系统普通升级：

```bash
/root/xui-vps-cleanup.sh upgrade
```

执行：

- `apt update`
- 普通 `apt upgrade`
- guarded `apt autoremove --purge`
- `apt clean`

不会执行：

```text
apt full-upgrade
```

如果希望升级后自动重启：

```bash
/root/xui-vps-cleanup.sh upgrade --reboot
```

### verify

最终检查：

```bash
/root/xui-vps-cleanup.sh verify
```

检查内容包括：

- 当前内核
- uptime
- RAM / Swap
- 磁盘
- x-ui 是否 active
- Fail2Ban
- failed systemd units
- 监听端口
- 是否仍存在 XRDP / CUPS / Avahi / Node / PM2 等典型额外监听
- journald 占用
- 默认 systemd target
- systemd-networkd
- 路由

如果 x-ui 不 active 或存在 failed units，verify 会报告失败。

## 一次执行完整流程

确认这台 VPS 确实只需要 x-ui/Xray 后，可以运行：

```bash
/root/xui-vps-cleanup.sh all --confirm-xui-only
```

完整顺序：

```text
audit
→ clean
→ prune-xui-only
→ fix-network
→ upgrade
→ verify
```

已经在测试机验证过，并希望非交互执行且完成后重启：

```bash
/root/xui-vps-cleanup.sh all --confirm-xui-only --yes --reboot
```

不建议第一次接触一台陌生 VPS 时直接使用这一条。

建议先运行：

```bash
/root/xui-vps-cleanup.sh audit
```

## 清理前 → 清理后报告

所有会修改系统的操作都会记录执行前状态，并生成 Markdown 报告：

```text
/root/xui-vps-cleanup-report-YYYYMMDD-HHMMSS.md
```

同时保存原始状态快照：

```text
/root/xui-vps-cleanup-state-YYYYMMDD-HHMMSS/
```

以及完整运行日志：

```text
/root/xui-vps-cleanup-YYYYMMDD-HHMMSS.log
```

报告包括：

- 根分区已用空间：Before → After
- 根分区占用率
- 可用磁盘空间
- RAM 已用
- RAM available
- Swap 已用
- systemd journal 占用
- Snap 下载缓存
- failed systemd units
- x-ui 状态
- Fail2Ban 状态
- Node 进程数
- PM2 应用数
- 默认 systemd target
- 内核版本
- 本次删除的软件包
- 本次新增的软件包
- 被停止/禁用/移除的清理目标服务
- 清理前的非 loopback 监听端口
- 清理后的非 loopback 监听端口
- 消失的监听端口
- 新增的监听端口
- 最终路由
- 最终 failed units

例如：

```text
Root disk used    18 GiB (95%) → 11 GiB (59%)
Swap used         150 MiB      → 0 B
Failed units      1            → 0
x-ui              active       → active
PM2 apps          1            → 0
Default target    graphical    → multi-user
```

“Network-facing listener”只表示监听地址不是 loopback。

是否真正能从互联网访问，还取决于：

- VPS 本机防火墙
- 云厂商 Security Group
- 云厂商防火墙
- NAT / 路由规则

## 使用 --reboot 时的最终报告

如果执行：

```bash
/root/xui-vps-cleanup.sh all --confirm-xui-only --yes --reboot
```

或者：

```bash
/root/xui-vps-cleanup.sh upgrade --reboot
```

脚本不会把“重启前状态”当作最终结果。

它会在重启前安装一个一次性的 systemd report service。

重启后，该任务会：

1. 等待网络和 x-ui 启动
2. 重新采集最终状态
3. 覆盖并完成 Before → After 报告
4. 删除自己
5. 删除临时的 post-reboot helper

因此最终报告可以反映：

- 新内核
- 重启后的 Swap
- 最终监听端口
- 最终网络状态
- x-ui 重启后的真实状态

查看最新报告：

```bash
REPORT=$(ls -t /root/xui-vps-cleanup-report-*.md | head -1)
cat "$REPORT"
```

## 自动备份

执行修改操作前，脚本会创建类似目录：

```text
/root/xui-cleanup-backup-YYYYMMDD-HHMMSS/
```

备份内容包括可用的：

- `/etc/network/interfaces`
- `/etc/netplan`
- x-ui systemd unit
- x-ui systemd drop-in
- journald 配置
- `/etc/x-ui`
- x-ui 数据库 / config 文件
- 已安装软件包状态
- enabled systemd units
- 监听端口
- IP 地址
- 路由

这些备份用于人工复核和故障排查，不等同于完整 VPS 快照。

对于重要生产服务器，仍建议先在 VPS 提供商处创建 Snapshot / Backup。

## 脚本不会自动删除的内容

为避免误删数据，以下内容不会因为“x-ui only”而被盲目清除：

- 未知 `/var/www` 项目
- 未知 `/root` 项目
- 用户自己的文件
- 未识别的数据库
- 未识别的 Docker 数据
- `/usr/lib/node_modules` 中无法安全判断的残留内容

发现这些内容时，脚本会报告并留给用户人工检查。

## 建议使用流程

新服务器建议：

```text
1. 下载脚本
2. bash -n 做语法检查
3. audit
4. 人工检查 audit
5. clean
6. prune-xui-only --confirm-xui-only
7. fix-network
8. upgrade
9. verify
10. reboot
11. 再次 verify
12. 查看 Before → After 报告
```

测试过的环境可以考虑：

```bash
/root/xui-vps-cleanup.sh all --confirm-xui-only --yes --reboot
```

## 更新脚本

重新从 GitHub 下载：

```bash
curl -fsSLo /root/xui-vps-cleanup.sh https://raw.githubusercontent.com/transbot/xui-vps-cleanup/main/xui-vps-cleanup.sh
chmod 700 /root/xui-vps-cleanup.sh
```

确认版本：

```bash
grep '^VERSION=' /root/xui-vps-cleanup.sh
```

## 查看帮助

```bash
/root/xui-vps-cleanup.sh --help
```

或：

```bash
/root/xui-vps-cleanup.sh -h
```

## 注意事项

这是一个会执行系统清理、卸载软件包和调整网络配置的管理脚本。

在生产服务器上使用前建议：

1. 先创建 VPS Snapshot
2. 确保有云厂商 Console / VNC / Serial Console 等带外管理方式
3. 先运行 `audit`
4. 确认 x-ui 当前正常
5. 确认没有其他需要保留的应用
6. 不要在不理解 audit 结果时直接运行 `all --yes`
7. 网络相关操作完成后保持当前 SSH 会话，直到确认新会话可以正常建立

## License

目前仓库如果尚未添加 LICENSE，则默认不授予额外的开源许可。

如果希望其他人可以自由使用、修改和分发，建议后续添加 MIT License。
