<div align="center">

# 🧹 kylin-perf-optimizer

**一键优化银河麒麟操作系统 V10 的桌面卡顿（全部操作可回滚）**

**One-click performance fix for Kylin OS V10 desktop lag (fully rollbackable)**

[中文](#中文说明) | [English](#english)

</div>

---

## 中文说明

针对**银河麒麟操作系统 V10** 桌面卡顿问题的一键优化脚本，全部操作可回滚。
源自一台麒麟桌面 V10 SP1 + 飞腾 D2000 + 8GB 内存的机器实测诊断与修复。

### 实测效果（原始验证机）

| 指标 | 优化前 | 优化后 |
|---|---|---|
| 整机 CPU（20 秒均值） | 628% / 800% | 239%（其中监控工具自身约 200%） |
| 显卡驱动服务 CPU | 105%（死循环） | 6.4% |
| 磁盘 swap 占用 | 8.0G | 0（由 zram 3.9G 承接） |
| 可用内存 | 1.2G | 2.0G |
| systemd 日志占用 | 2.6G | 184M |
| 磁盘换页速率 | 频繁 | ≈0 |

### 它修了什么

1. **景嘉微 mwv206 显卡驱动死循环**（仅该机型，无此硬件自动跳过）
   厂商脚本 `/usr/sbin/mwv206-server.sh` 原版 `while true` 循环内每轮 fork `pgrep` 且无 `sleep`，常驻烧满 1 个 CPU 核心、制造每秒数万次上下文切换。修复版保持原有语义，仅每 2 秒检查一次。
2. **zram 内存压缩**：约为物理内存一半的压缩交换空间，优先于磁盘 swap，减少 NVMe 换页（8GB 内存机型收益明显）。
3. **内核参数**：swappiness=80（配合 zram）、vfs_cache_pressure=50、脏页回写限流，缓解桌面输入卡顿。
4. **日志瘦身**：journald 限制在 200M。
5. **SSD TRIM**：立即执行一次并启用每周自动 TRIM。

### 适用范围

| 项目 | 说明 |
|---|---|
| 系统 | 银河麒麟桌面/服务器 V10（含 SP1/SP2/SP3），bash + systemd 环境即可 |
| 架构 | 通用（纯 shell，x86_64 / aarch64 / mips64el / loongarch64 均可） |
| 硬件 | 第 1 项仅对景嘉微 mwv206 显卡机型生效；其余 4 项通用 |
| 权限 | 需 root（`sudo` 或 `su root`） |

**不适用**：Ubuntu/Debian/统信 UOS 等非麒麟系统原则上也能跑（均为标准 Linux 机制），但未做验证，后果自负。

### 使用方法

```bash
# 体检（不改任何东西）
sudo bash optimize-kylin.sh check

# 一键优化
sudo bash optimize-kylin.sh all

# 全部回滚
sudo bash optimize-kylin.sh rollback
```

执行完 `all` 后建议**重启一次**，清掉历史累积的 swap 占用，收益最大。

#### 可选：桌面双击图标（给不熟悉命令行的用户）

```bash
bash install-desktop.sh          # 桌面出现"优化系统卡顿""撤销系统优化"扫帚图标
bash install-desktop.sh remove   # 卸载图标
```

图标双击后自动弹出终端并引导输入密码；若终端方案失败，自动降级为 pkexec 图形授权 + 桌面通知。

### 回滚与备份

- 每次修改前，被改动的原文件备份到 `/var/backups/kylin-perf/<时间戳>/`
- `sudo bash optimize-kylin.sh rollback` 撤销全部改动（zram、内核参数、日志限制、GPU 脚本）
- 各单项也可独立执行：`gpu` / `zram` / `sysctl` / `journal` / `trim` / `check`

### 已知边界

- GPU 修复会对比脚本特征（`while true` 且无 `sleep`）才动手，已修复或已改版的脚本不会被误改
- 机械硬盘机型 TRIM 项会提示"不支持"，可忽略
- 本脚本不升级内核、不动 glibc、不卸载任何软件

### 免责声明

本脚本只使用标准 Linux（systemd / sysctl / zram / fstrim）机制，不修改麒麟系统组件。
但生产/办公关键环境请先运行 `check` 与单项确认，再执行 `all`。使用风险自负。

---

## English

A one-click optimization script for **desktop lag on Kylin OS V10** (Galaxy Kylin Desktop/Server V10), fully rollbackable.
Born from real-world diagnosis and repair on a Kylin Desktop V10 SP1 machine (Phytium D2000, 8 GB RAM).

### Measured results (original test machine)

| Metric | Before | After |
|---|---|---|
| Total CPU (20s average) | 628% / 800% | 239% (~200% of it is the monitoring tool itself) |
| GPU driver service CPU | 105% (busy loop) | 6.4% |
| Disk swap usage | 8.0G | 0 (taken over by 3.9G zram) |
| Available memory | 1.2G | 2.0G |
| systemd journal size | 2.6G | 184M |
| Disk paging rate | frequent | ≈0 |

### What it fixes

1. **JingJiaMicro (mwv206) GPU driver busy loop** (only on such hardware; skipped automatically otherwise)
   The vendor script `/usr/sbin/mwv206-server.sh` forks `pgrep` every iteration inside a `while true` loop with no `sleep`, permanently burning one full CPU core and tens of thousands of context switches per second. The fixed version keeps the original semantics but checks every 2 seconds.
2. **zram compressed swap**: about half of RAM as compressed swap, prioritized over disk swap, reducing NVMe paging (big win on 8 GB machines).
3. **Kernel parameters**: swappiness=80 (paired with zram), vfs_cache_pressure=50, dirty writeback throttling to smooth desktop input.
4. **Journal slimming**: journald capped at 200M.
5. **SSD TRIM**: run once immediately and enable weekly automatic TRIM.

### Compatibility

| Item | Notes |
|---|---|
| OS | Kylin Desktop/Server V10 (SP1/SP2/SP3), requires bash + systemd |
| Architecture | Universal (pure shell: x86_64 / aarch64 / mips64el / loongarch64) |
| Hardware | Fix #1 only applies to JingJiaMicro mwv206 GPU machines; the other 4 are universal |
| Privileges | root required (`sudo` or `su root`) |

**Not tested on** non-Kylin systems (Ubuntu/Debian/UOS). They should technically work since only standard Linux mechanisms are used, but use at your own risk.

### Usage

```bash
# Health check only (changes nothing)
sudo bash optimize-kylin.sh check

# One-click optimization
sudo bash optimize-kylin.sh all

# Roll back everything
sudo bash optimize-kylin.sh rollback
```

After `all`, **reboot once** to flush the accumulated swap for the biggest gain.

#### Optional: desktop launcher icons (for non-CLI users)

```bash
bash install-desktop.sh          # adds "Optimize" & "Rollback" broom icons to your desktop
bash install-desktop.sh remove   # removes them
```

Double-clicking opens a terminal window and walks you through the password prompt; if the terminal fails, it falls back to pkexec GUI authentication + desktop notification.

### Rollback & backups

- Original files are backed up to `/var/backups/kylin-perf/<timestamp>/` before every change
- `sudo bash optimize-kylin.sh rollback` undoes everything (zram, sysctl, journal cap, GPU script)
- Each step can also run standalone: `gpu` / `zram` / `sysctl` / `journal` / `trim` / `check`

### Known limits

- The GPU fix verifies the script signature (`while true` without `sleep`) before touching anything; already-fixed or modified scripts are left alone
- On machines with HDDs the TRIM step reports "not supported" — safe to ignore
- This script never upgrades the kernel, touches glibc, or uninstalls any software

### Disclaimer

The script only uses standard Linux mechanisms (systemd / sysctl / zram / fstrim) and does not modify Kylin system components.
For critical production or office machines, run `check` and individual steps first before `all`. Use at your own risk.

---

<div align="center">

License: MIT · Verified on: Kylin Desktop V10 SP1 · Phytium D2000 · aarch64

Issues and feedback from other machines/models are welcome!

欢迎反馈其他机型上的运行效果！

</div>
