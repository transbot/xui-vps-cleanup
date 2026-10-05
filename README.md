# xui-vps-cleanup

用于审计并清理一台“仅把 x-ui/Xray 作为应用工作负载”的 Ubuntu/Debian VPS。

> “仅 x-ui”不等于系统只剩一个进程。SSH、systemd、网络、DNS、cron、journald，以及可选的 Fail2Ban 等基础系统服务会保留。

## 安全设计

- 默认 `audit` 只读，不修改系统。
- 会保护 x-ui、SSH、Netplan/systemd-networkd、systemd、Fail2Ban 等关键组件。
- 桌面环境、XRDP、CUPS、Avahi、Node.js/PM2 的移除需要显式使用 `prune-xui-only --confirm-xui-only`。
- 不会盲删未知的 `/root` 项目目录或其他用户数据；发现后只报告。
- 网络清理由单独的 `fix-network` 阶段执行；只有确认默认网卡由 Netplan + systemd-networkd 管理时才会退役 legacy `/etc/network/interfaces` 管理，而且不会在线重启网络。
- 每次会在 `/root/xui-cleanup-backup-时间戳/` 保存关键配置快照，并把运行记录写到 `/root/xui-vps-cleanup-时间戳.log`。

## 推荐使用方法

先下载，不要第一次就直接 `curl | bash`：

```bash
curl -fsSLo /root/xui-vps-cleanup.sh \
  https://raw.githubusercontent.com/<你的GitHub用户名>/<仓库名>/main/xui-vps-cleanup.sh
chmod 700 /root/xui-vps-cleanup.sh
less /root/xui-vps-cleanup.sh
```

先做只读审计：

```bash
/root/xui-vps-cleanup.sh audit
```

低风险清理（journald 上限、旧 journal、APT 缓存、Snap 下载缓存）：

```bash
/root/xui-vps-cleanup.sh clean
```

确认这台 VPS 不再需要桌面、XRDP、打印、mDNS、Node/PM2 等应用栈后：

```bash
/root/xui-vps-cleanup.sh prune-xui-only --confirm-xui-only
```

如果审计确认 Netplan + systemd-networkd 才是真正的网络管理链路：

```bash
/root/xui-vps-cleanup.sh fix-network
```

系统普通升级（不是 full-upgrade）：

```bash
/root/xui-vps-cleanup.sh upgrade
```

最终验证：

```bash
/root/xui-vps-cleanup.sh verify
```

如果已经在测试机/已确认环境中验证过，也可以一次执行：

```bash
/root/xui-vps-cleanup.sh all --confirm-xui-only --yes --reboot
```

第一次在新 VPS 上不建议直接使用这一条；先跑 `audit`。

## 主要检查内容

- `/etc/os-release`、内核、uptime
- RAM / Swap
- 根分区磁盘占用
- systemd failed units
- x-ui / Fail2Ban 状态
- TCP/UDP 监听端口
- journald 使用量
- `/var`、`/root` 大目录
- GNOME/XFCE、XRDP、CUPS、Avahi、Node.js/npm、PM2
- Netplan、systemd-networkd、legacy `/etc/network/interfaces`

## 主要清理内容

在明确确认“x-ui-only”后，脚本可清理：

- Ubuntu Desktop / GNOME / XFCE 等入口包及其自动依赖
- XRDP
- CUPS
- Avahi
- 无活动 Node 进程时的 Node.js/npm
- PM2 任务与 PM2 daemon
- Snap 下载缓存
- APT 缓存
- 过大的 systemd journal，并永久设置默认 200 MB 上限

未知项目数据不会自动删除。

## 清理前 → 清理后报告

从 v1.1.0 开始，所有会修改系统的命令都会自动保存“执行前”状态，并在结束时生成 Markdown 报告：

```text
/root/xui-vps-cleanup-report-YYYYMMDD-HHMMSS.md
```

同时保存用于复核的原始状态快照：

```text
/root/xui-vps-cleanup-state-YYYYMMDD-HHMMSS/
```

以及完整执行日志：

```text
/root/xui-vps-cleanup-YYYYMMDD-HHMMSS.log
```

报告会清楚列出：

- 根分区已用空间和占用率：例如 `18 GiB (95%) -> 11 GiB (59%)`
- 根分区可用空间
- RAM 已用 / available
- Swap 已用：例如 `150 MiB -> 0 B`
- systemd journal 占用
- Snap 下载缓存占用
- failed systemd units 数量
- x-ui / Fail2Ban 状态
- Node 进程数 / PM2 应用数
- `graphical.target -> multi-user.target` 等启动目标变化
- 内核版本变化
- 本次删除的软件包数量及完整列表
- XRDP、CUPS、Avahi、GDM、PM2 等清理目标服务中，哪些被停止/禁用/移除
- 清理前与清理后的非 loopback 监听端口
- 消失的监听端口和新增的监听端口
- 最终路由和 failed units

“Network-facing listener”只表示绑定到了非 loopback 地址；是否真正能从互联网访问，还取决于 VPS 自身防火墙以及云厂商安全组/防火墙。

报告开头会给出紧凑摘要，例如：

```text
Root disk used       18 GiB (95%) -> 11 GiB (59%)
Swap used            150 MiB      -> 0 B
Failed units         1            -> 0
x-ui                 active       -> active
PM2 apps             1            -> 0
Default target       graphical    -> multi-user
Removed packages     200+
Removed listeners    :3389/xrdp, :631/cups, :5353/avahi ...
Remaining listeners  SSH + x-ui/Xray + required OS networking
```

如果使用：

```bash
/root/xui-vps-cleanup.sh all --confirm-xui-only --yes --reboot
```

脚本不会在 SSH 即将断开前把“重启前状态”冒充为最终状态。它会自动安装一个一次性的 systemd 报告任务；机器重启并重新启动网络/x-ui 后，自动采集真正的“清理后”状态，生成最终报告，然后自动删除这个一次性任务。

因此新内核、重启后的 Swap、最终监听端口、Netplan/systemd-networkd 接管后的网络状态都会体现在最终报告里。
