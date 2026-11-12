#!/bin/bash
# ============================================================
# 桌面图标安装器（可选，普通用户运行，无需 root）
# 用途：给 optimize-kylin.sh 创建桌面双击图标（扫帚图标）
#   bash install-desktop.sh          # 安装"优化系统卡顿"+"撤销系统优化"
#   bash install-desktop.sh remove   # 移除桌面图标
# ============================================================
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/opt/kylin-perf-optimizer"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
ICON_NAME=kylin-perf-broom
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/桌面")"
# 安全防线：桌面目录必须在当前用户家目录下，防止异常配置写坏别处
case "$DESKTOP_DIR" in
    "$HOME"|"$HOME"/*) ;;
    *) DESKTOP_DIR="$HOME/桌面"; mkdir -p "$DESKTOP_DIR" ;;
esac

[ -f "$REPO_DIR/optimize-kylin.sh" ] || { echo "[错误] 请在本仓库目录内运行本脚本"; exit 1; }

do_remove() {
    rm -f "$APP_DIR/kylin-perf-optimize.desktop" "$APP_DIR/kylin-perf-rollback.desktop"
    rm -f "$DESKTOP_DIR/优化系统卡顿.desktop" "$DESKTOP_DIR/撤销系统优化.desktop"
    rm -f "$BIN_DIR/.kylin-perf-run.sh" "$BIN_DIR/.kylin-perf-rollback.sh"
    rm -f "$BIN_DIR/优化系统卡顿" "$BIN_DIR/撤销系统优化"
    update-desktop-database "$APP_DIR" 2>/dev/null
    echo "已移除桌面图标。"
    exit 0
}

[ "${1:-}" = "remove" ] && do_remove

# 1. 安装脚本本体到用户目录（即使删了仓库目录图标也仍可用）
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$APP_DIR" "$ICON_DIR"
cp -a "$REPO_DIR/optimize-kylin.sh" "$INSTALL_DIR/"
[ -f "$REPO_DIR/assets/broom.png" ] && cp -a "$REPO_DIR/assets/broom.png" "$ICON_DIR/$ICON_NAME.png"

# 2. 生成终端内运行脚本（弹窗后可见全过程，结束不关窗）
cat > "$BIN_DIR/.kylin-perf-run.sh" <<EOF
#!/bin/bash
SCRIPT=$INSTALL_DIR/optimize-kylin.sh
echo "=================================================="
echo "            麒麟系统卡顿 一键优化"
echo "=================================================="
echo "将执行：显卡驱动空转修复(如有) / 内存压缩 zram / 内核参数 /"
echo "        日志瘦身 / SSD TRIM（所有改动均可回滚）"
echo ""
echo "接下来会要求输入密码（输入时屏幕不显示字符，正常）："
echo "  1) 先试你的【登录密码】（即开机密码）"
echo "  2) 若失败会自动改用 root 密码方式重试"
echo ""
RC=0
if [ "\$(id -u)" -eq 0 ]; then
    bash "\$SCRIPT" all; RC=\$?
elif sudo -v; then
    sudo bash "\$SCRIPT" all; RC=\$?
else
    echo "sudo 方式未通过，改用 root 账号（输入 root 密码）："
    su root -c "bash '\$SCRIPT' all"; RC=\$?
fi
echo ""
if [ \$RC -eq 0 ]; then
    echo "  优化完成！建议【重启电脑】一次，效果最佳。"
else
    echo "  执行出错。请把本窗口的文字截图发给帮助者。"
fi
echo ""
read -r -p "按回车键关闭本窗口..." _
EOF

cat > "$BIN_DIR/.kylin-perf-rollback.sh" <<EOF
#!/bin/bash
SCRIPT=$INSTALL_DIR/optimize-kylin.sh
echo "=================================================="
echo "            麒麟系统优化 一键回滚"
echo "=================================================="
echo "将撤销之前优化所做的全部改动（恢复原状）。"
echo ""
RC=0
if [ "\$(id -u)" -eq 0 ]; then
    bash "\$SCRIPT" rollback; RC=\$?
elif sudo -v; then
    sudo bash "\$SCRIPT" rollback; RC=\$?
else
    echo "sudo 方式未通过，改用 root 账号（输入 root 密码）："
    su root -c "bash '\$SCRIPT' rollback"; RC=\$?
fi
echo ""
[ \$RC -eq 0 ] && echo "回滚完成，建议重启一次。" || echo "执行出错，请截图本窗口内容求助。"
echo ""
read -r -p "按回车键关闭本窗口..." _
EOF
chmod +x "$BIN_DIR/.kylin-perf-run.sh" "$BIN_DIR/.kylin-perf-rollback.sh"

# 3. 生成桌面图标入口（三级保险：终端 → pkexec → 通知指路）
make_launcher() {  # $1=RUN脚本 $2=图标文件名 $3=优化模式
    cat > "$BIN_DIR/$2" <<LAUNCHER
#!/bin/bash
RUN="$BIN_DIR/$1"
TITLE="$2"
notify_hint() {
    command -v notify-send >/dev/null 2>&1 && notify-send -u critical -i dialog-warning "\$TITLE" "\$1" 2>/dev/null
    echo "\$1"
}
running() { pgrep -f "^bash \$RUN" >/dev/null 2>&1; }
try_terminal() {
    local term="\$1"
    command -v "\$term" >/dev/null 2>&1 || return 1
    DISPLAY=:0 "\$term" -e "bash \$RUN" 2>/dev/null &
    sleep 6
    running && return 0
    sleep 6
    running && return 0
    return 1
}
if [ -x /usr/bin/mate-terminal ] || command -v x-terminal-emulator >/dev/null 2>&1; then
    if try_terminal mate-terminal || try_terminal x-terminal-emulator; then
        exit 0
    fi
fi
if command -v pkexec >/dev/null 2>&1; then
    OUT=\$(mktemp)
    if pkexec bash "$INSTALL_DIR/optimize-kylin.sh" $3 >"\$OUT" 2>&1; then
        rm -f "\$OUT"
        command -v notify-send >/dev/null 2>&1 && notify-send -u critical -i dialog-information "\$TITLE" "执行完成！建议重启电脑一次。" 2>/dev/null
        exit 0
    fi
    rm -f "\$OUT"
fi
notify_hint "未能自动启动。请打开终端运行：bash $BIN_DIR/$1"
exit 1
LAUNCHER
    chmod +x "$BIN_DIR/$2"
}
make_launcher .kylin-perf-run.sh "优化系统卡顿" all
make_launcher .kylin-perf-rollback.sh "撤销系统优化" rollback

# 4. 桌面启动项
cat > "$APP_DIR/kylin-perf-optimize.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=优化系统卡顿
Name[en]=Kylin Performance Fix
Comment=一键修复麒麟系统卡顿：显卡驱动空转修复、内存压缩、日志瘦身、SSD TRIM，全部可回滚
Exec=$BIN_DIR/优化系统卡顿
Icon=$ICON_NAME
Terminal=false
Categories=Utility;
EOF
cat > "$APP_DIR/kylin-perf-rollback.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=撤销系统优化
Name[en]=Kylin Performance Rollback
Comment=撤销"优化系统卡顿"所做的全部改动，恢复原状
Exec=$BIN_DIR/撤销系统优化
Icon=$ICON_NAME
Terminal=false
Categories=Utility;
EOF

for f in kylin-perf-optimize kylin-perf-rollback; do
    cp "$APP_DIR/$f.desktop" "$DESKTOP_DIR/" 2>/dev/null || true
done
# 中文名桌面项
cp "$APP_DIR/kylin-perf-optimize.desktop" "$DESKTOP_DIR/优化系统卡顿.desktop" 2>/dev/null || true
cp "$APP_DIR/kylin-perf-rollback.desktop" "$DESKTOP_DIR/撤销系统优化.desktop" 2>/dev/null || true
rm -f "$DESKTOP_DIR/kylin-perf-optimize.desktop" "$DESKTOP_DIR/kylin-perf-rollback.desktop" 2>/dev/null || true
chmod +x "$DESKTOP_DIR/优化系统卡顿.desktop" "$DESKTOP_DIR/撤销系统优化.desktop" 2>/dev/null || true

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$APP_DIR/kylin-perf-optimize.desktop" && desktop-file-validate "$APP_DIR/kylin-perf-rollback.desktop" && echo "桌面项校验通过"
fi
update-desktop-database "$APP_DIR" 2>/dev/null

echo ""
echo "安装完成！桌面已出现【优化系统卡顿】和【撤销系统优化】两个图标。"
echo "卸载：bash $(basename "$0") remove"
