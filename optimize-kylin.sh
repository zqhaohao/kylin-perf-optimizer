#!/bin/bash
# ============================================================
# kylin-perf-optimizer：麒麟 V10 桌面系统卡顿一键优化（全部操作可回滚）
# 原始验证环境：银河麒麟桌面操作系统 V10 SP1（2503）/ 飞腾 D2000 / 8GB 内存
# 用法：
#   sudo bash optimize-kylin.sh check      # 只体检，不改任何东西
#   sudo bash optimize-kylin.sh all        # 执行全部优化
#   sudo bash optimize-kylin.sh gpu        # 单项：修复景嘉微 GPU 服务死循环（无此硬件自动跳过）
#   sudo bash optimize-kylin.sh zram       # 单项：启用 zram 压缩内存
#   sudo bash optimize-kylin.sh sysctl     # 单项：内核参数
#   sudo bash optimize-kylin.sh journal    # 单项：日志瘦身
#   sudo bash optimize-kylin.sh trim       # 单项：SSD TRIM
#   sudo bash optimize-kylin.sh rollback   # 回滚（含恢复 GPU 脚本）
# ============================================================

set -u

BK_ROOT=/var/backups/kylin-perf
STAMP=$(date +%Y%m%d-%H%M%S)
BK="$BK_ROOT/$STAMP"
GPU_SCRIPT=/usr/sbin/mwv206-server.sh
ZRAM_HELPER=/usr/local/sbin/zram-swap.sh
ZRAM_UNIT=/etc/systemd/system/zram-swap.service
SYSCTL_CONF=/etc/sysctl.d/99-kylin-perf.conf
JOURNAL_CONF=/etc/systemd/journald.conf.d/10-size.conf

c_ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n' "$*"; }
hr()     { printf '%s\n' "------------------------------------------------------------"; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        c_err "请用 sudo 运行：sudo bash $0 $*"
        exit 1
    fi
}

# ---------- 0. 体检 ----------
do_check() {
    hr; echo "① 系统与架构"
    if command -v nkvers >/dev/null 2>&1; then nkvers 2>/dev/null | head -4; else cat /etc/os-release 2>/dev/null | head -3; fi
    echo "架构: $(uname -m)  内核: $(uname -r)"

    hr; echo "② 内存与交换"
    free -h
    echo; echo "swap 明细："; cat /proc/swaps
    echo "swappiness = $(cat /proc/sys/vm/swappiness)"

    hr; echo "③ CPU 占用 TOP（按单核百分比，合计 = 100% × 核数）"
    if command -v top >/dev/null 2>&1; then
        top -bn2 -d 1 2>/dev/null | awk '/^top -/{n++} n==2' | sed -n '7,18p'
    fi

    hr; echo "④ GPU 驱动服务 CPU（景嘉微 mwv206 机型正常应接近 0%）"
    ps -eo pcpu,comm 2>/dev/null | awk '$2 ~ /mwv206|genload/ {printf "  %s%%  %s\n", $1, $2}'

    hr; echo "⑤ 日志占用"
    journalctl --disk-usage 2>/dev/null

    hr; echo "⑥ zram 状态"
    if [ -b /dev/zram0 ]; then
        cat /sys/block/zram0/disksize 2>/dev/null | awk '{printf "  zram0 已启用，容量 %.1f GB\n", $1/1024/1024/1024}'
    else
        echo "  zram0 未启用"
    fi
    hr
}

# ---------- 1. 修复 GPU 服务死循环（收益最大，仅景嘉微机型）----------
do_gpu() {
    hr; echo "① 修复 mwv206-server 死循环"
    if [ ! -f "$GPU_SCRIPT" ]; then
        c_warn "未找到 $GPU_SCRIPT（本机不是景嘉微 mwv206 显卡），跳过"
        return 0
    fi
    if ! grep -q "while true" "$GPU_SCRIPT" || grep -q "sleep" "$GPU_SCRIPT"; then
        c_warn "GPU 脚本不像已知的问题版本（可能已修复或已改版），跳过以免误伤"
        return 0
    fi
    mkdir -p "$BK"
    cp -a "$GPU_SCRIPT" "$BK/mwv206-server.sh.bak"
    c_ok "原脚本已备份到 $BK/mwv206-server.sh.bak"

    cat > "$GPU_SCRIPT" <<'EOS'
#!/bin/bash
# 由 kylin-perf-optimizer 重写。
# 原版问题：while true 循环内既 fork pgrep 又 echo，且没有 sleep，
# 导致常驻占满 1 个 CPU 核心、并制造每秒数万次上下文切换。
# 本版保持原有语义（依据 genload 进程切换 video_mode），仅每 2 秒检查一次。
if [ ! -c /dev/mwv206_0 ]; then
    exit 0
fi

echo 0 > /dev/shm/mwv206_video_mode
chmod 777 /dev/shm/mwv206_video_mode

while true; do
    if pgrep -x genload >/dev/null 2>&1; then
        echo 1 > /dev/shm/mwv206_video_mode
    else
        echo 0 > /dev/shm/mwv206_video_mode
    fi
    sleep 2
done
EOS
    chmod 755 "$GPU_SCRIPT"
    systemctl restart mwv206-server.service 2>/dev/null && c_ok "服务已重启" || c_warn "服务重启失败，请手动 systemctl restart mwv206-server"

    sleep 6
    echo "复核该服务 CPU 占用："
    ps -eo pcpu,comm 2>/dev/null | awk '$2 ~ /mwv206/ {printf "  %s%%  %s\n", $1, $2}'
    c_ok "预期：从约 100% 降到 0~1%"
}

# ---------- 2. zram 压缩内存 ----------
do_zram() {
    hr; echo "② 启用 zram 压缩内存（替代部分磁盘换页）"
    if [ ! -e /sys/module/zram ] && ! modinfo zram >/dev/null 2>&1; then
        c_warn "内核不支持 zram，跳过"
        return 0
    fi
    if [ -b /dev/zram0 ] && grep -q zram0 /proc/swaps 2>/dev/null; then
        c_warn "zram0 已在用，跳过"
        return 0
    fi
    modprobe zram num_devices=1 2>/dev/null || { c_err "zram 模块加载失败"; return 1; }

    # 压缩算法优先 lz4，不支持则回退 lzo
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null \
        || echo lzo > /sys/block/zram0/comp_algorithm 2>/dev/null

    local kb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 2 ))
    echo "${kb}K" > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 100 /dev/zram0 2>/dev/null && c_ok "zram0 已启用：$(( kb / 1024 / 1024 )) GB，优先级 100（优先于磁盘 swap）" \
        || { c_err "zram swapon 失败"; return 1; }

    # 持久化
    cat > "$ZRAM_HELPER" <<'EOS'
#!/bin/bash
case "$1" in
  start)
    modprobe zram num_devices=1 2>/dev/null
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || echo lzo > /sys/block/zram0/comp_algorithm 2>/dev/null
    kb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 2 ))
    echo "${kb}K" > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 100 /dev/zram0
    ;;
  stop)
    swapoff /dev/zram0 2>/dev/null
    ;;
esac
EOS
    chmod 755 "$ZRAM_HELPER"

    cat > "$ZRAM_UNIT" <<'EOS'
[Unit]
Description=zram compressed swap (added by kylin-perf-optimizer)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap.sh start
ExecStop=/usr/local/sbin/zram-swap.sh stop

[Install]
WantedBy=multi-user.target
EOS
    systemctl daemon-reload 2>/dev/null
    systemctl enable zram-swap.service >/dev/null 2>&1 && c_ok "已设置开机自动启用"
}

# ---------- 3. 内核参数 ----------
do_sysctl() {
    hr; echo "③ 内核内存参数调优"
    mkdir -p "$BK"
    [ -f "$SYSCTL_CONF" ] && cp -a "$SYSCTL_CONF" "$BK/" 2>/dev/null
    cat > "$SYSCTL_CONF" <<'EOS'
# 由 kylin-perf-optimizer 生成
# 有 zram 时适当提高 swappiness，让冷页先进压缩内存而不是直接打到磁盘
vm.swappiness = 80
# 保留更多目录/文件缓存，减少重复磁盘读取
vm.vfs_cache_pressure = 50
# 降低一次性回写峰值，避免桌面输入卡顿
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
EOS
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 && c_ok "参数已生效" || c_warn "参数部分生效失败，可重启后再看"
    sysctl vm.swappiness vm.vfs_cache_pressure 2>/dev/null
}

# ---------- 4. 日志瘦身 ----------
do_journal() {
    hr; echo "④ systemd 日志瘦身"
    echo "当前占用：$(journalctl --disk-usage 2>/dev/null)"
    mkdir -p /etc/systemd/journald.conf.d
    cat > "$JOURNAL_CONF" <<'EOS'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOS
    journalctl --vacuum-size=200M >/dev/null 2>&1 && c_ok "已压缩到 200M 以内"
    systemctl restart systemd-journald 2>/dev/null
    echo "现在占用：$(journalctl --disk-usage 2>/dev/null)"
}

# ---------- 5. SSD TRIM ----------
do_trim() {
    hr; echo "⑤ SSD TRIM"
    fstrim -av 2>/dev/null || c_warn "fstrim 执行失败（文件系统可能不支持在线 TRIM，机械硬盘可忽略此项）"
    systemctl enable --now fstrim.timer >/dev/null 2>&1 && c_ok "已启用每周自动 TRIM"
}

# ---------- 回滚 ----------
do_rollback() {
    hr; echo "回滚"
    local last
    last=$(ls -1d "$BK_ROOT"/*/ 2>/dev/null | sort | tail -1)
    if [ -n "$last" ] && [ -f "$last/mwv206-server.sh.bak" ]; then
        cp -a "$last/mwv206-server.sh.bak" "$GPU_SCRIPT"
        systemctl restart mwv206-server.service 2>/dev/null
        c_ok "已恢复原 GPU 服务脚本（来自 $last）"
    else
        c_warn "未找到 GPU 脚本备份（可能本来就没有此硬件或未修复过）"
    fi

    if grep -q zram0 /proc/swaps 2>/dev/null; then
        swapoff /dev/zram0 2>/dev/null
        c_ok "已关闭 zram"
    fi
    systemctl disable zram-swap.service >/dev/null 2>&1
    rm -f "$ZRAM_UNIT" "$ZRAM_HELPER"
    systemctl daemon-reload 2>/dev/null

    [ -f "$SYSCTL_CONF" ] && rm -f "$SYSCTL_CONF" && sysctl --system >/dev/null 2>&1 && c_ok "已移除内核参数"
    [ -f "$JOURNAL_CONF" ] && rm -f "$JOURNAL_CONF" && c_ok "已移除日志限制"
    hr; echo "回滚完成，建议重启一次使全部状态复位。"
}

case "${1:-check}" in
    check)    need_root "$@"; do_check ;;
    gpu)      need_root "$@"; do_gpu ;;
    zram)     need_root "$@"; do_zram ;;
    sysctl)   need_root "$@"; do_sysctl ;;
    journal)  need_root "$@"; do_journal ;;
    trim)     need_root "$@"; do_trim ;;
    rollback) need_root "$@"; do_rollback ;;
    all)
        need_root "$@"
        do_gpu; do_zram; do_sysctl; do_journal; do_trim
        hr; echo "全部完成。建议重启一次，让长期累积的 swap 占用彻底释放。"
        do_check
        ;;
    *)
        sed -n '2,16p' "$0"
        ;;
esac
