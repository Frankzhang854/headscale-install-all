#!/bin/bash

set -e

echo "⚠️  Headscale 卸载工具"
echo "此操作将移除："
echo "  • Headscale 服务"
echo "  • 配置文件 (/etc/headscale)"
echo "  • 数据库与状态数据 (/var/lib/headscale)"
echo "  • 系统用户 'headscale'（如存在）"
echo ""

read -p "是否继续？(y/N): " CONFIRM
case "${CONFIRM,,}" in
    y|yes)
        echo "✅ 开始卸载..."
        ;;
    *)
        echo "❌ 取消卸载。"
        exit 0
        ;;
esac

# 停止并禁用服务
echo "🛑 停止 Headscale 服务..."
systemctl stop headscale 2>/dev/null || true
systemctl disable headscale 2>/dev/null || true

# 卸载软件包（保留配置选项，但我们后面会手动删）
echo "📦 卸载软件包..."
apt remove --purge -y headscale 2>/dev/null || true

# 彻底删除配置和数据目录
echo "🧹 清理配置与数据..."
rm -rf /etc/headscale/ 2>/dev/null || true
rm -rf /var/lib/headscale/ 2>/dev/null || true

# 清理 systemd 服务文件（双重保险）
rm -f /etc/systemd/system/headscale.service 2>/dev/null || true
rm -f /lib/systemd/system/headscale.service 2>/dev/null || true
systemctl daemon-reload

# 删除专用用户和组（如果存在）
if id "headscale" &>/dev/null; then
    echo "👤 删除用户 'headscale'..."
    deluser --remove-home headscale 2>/dev/null || true
fi
if getent group headscale &>/dev/null; then
    delgroup headscale 2>/dev/null || true
fi

# 清理可能残留的日志（可选）
journalctl --vacuum-time=1s --quiet 2>/dev/null || true

# 删除当前目录下的安装包（如果存在）
rm -f ./headscale.deb 2>/dev/null || true

echo ""
echo "🎉 Headscale 已完全卸载！"
echo "💡 提示：如果你使用了自定义端口或防火墙规则，请手动清理（如 ufw / iptables）。"