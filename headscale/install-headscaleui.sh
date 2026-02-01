#!/bin/bash

set -e  # 遇到错误立即退出

# 定义变量
URL="https://github.com/gurucomputing/headscale-ui/releases/download/2025.08.23/headscale-ui.zip"
WEB_DIR="/var/www"
ZIP_FILE="/tmp/headscale-ui.zip"
API_KEY_FILE="/etc/headscale/API-KEY.txt"  # 更安全的存储位置
MAX_WAIT=30

# 确保 /etc/headscale 目录存在
if [ ! -d "/etc/headscale" ]; then
    echo "❌ /etc/headscale 目录不存在，请确认 headscale 已正确安装并配置。"
    exit 1
fi

# 检测并安装 unzip
echo "正在检查 unzip 是否已安装..."
if ! command -v unzip &> /dev/null; then
    echo "❌ unzip 未安装，正在自动安装..."

    if command -v apt &> /dev/null; then
        apt update && apt install -y unzip
    elif command -v dnf &> /dev/null; then
        dnf install -y unzip
    elif command -v yum &> /dev/null; then
        yum install -y unzip
    else
        echo "❌ 无法识别包管理器，请手动安装 unzip 后重试。"
        exit 1
    fi
    echo "✅ unzip 已成功安装。"
else
    echo "✅ unzip 已安装。"
fi

# 检查并安装 curl（如果缺失）
if ! command -v curl &> /dev/null; then
    echo "❌ curl 未安装，正在尝试安装..."
    if command -v apt &> /dev/null; then
        apt update && apt install -y curl
    elif command -v dnf &> /dev/null; then
        dnf install -y curl
    elif command -v yum &> /dev/null; then
        yum install -y curl
    else
        echo "❌ 无法安装 curl，请手动安装后重试。"
        exit 1
    fi
    echo "✅ curl 已成功安装。"
else
    echo "✅ curl 已安装。"
fi

# 下载压缩包
echo "正在下载 headscale-ui..."
curl -fsSL -o "$ZIP_FILE" "$URL"

# 解压到 Web 目录
echo "正在解压到 $WEB_DIR..."
unzip -o "$ZIP_FILE" -d "$WEB_DIR"

# 清理临时文件
rm -f "$ZIP_FILE"

# 重启服务
echo "正在重启 headscale 和 nginx..."
systemctl restart headscale nginx

# 等待 headscale 服务激活
echo "等待 headscale 服务启动中..."
for i in $(seq 1 $MAX_WAIT); do
    if systemctl is-active --quiet headscale; then
        echo "✅ headscale 服务已成功启动。"
        break
    fi
    sleep 1
done

if ! systemctl is-active --quiet headscale; then
    echo "❌ headscale 服务未能在 $MAX_WAIT 秒内启动，请检查日志：journalctl -u headscale"
    exit 1
fi

# 验证 headscale 命令是否可用
echo "正在验证 headscale 命令..."
if ! headscale --help >/dev/null 2>&1; then
    echo "❌ headscale 命令不可用，请确认 PATH 或安装状态。"
    exit 1
else
    echo "✅ headscale 命令正常。"
fi

# 创建长期 API Key
echo "正在创建 API Key（有效期 9999 天）..."
API_KEY_OUTPUT=$(headscale apikeys create --expiration 9999d)

# 打印到终端
echo "🔑 生成的 API Key 信息如下："
echo "$API_KEY_OUTPUT"

# 保存到安全位置
echo "$API_KEY_OUTPUT" > "$API_KEY_FILE"
chmod 600 "$API_KEY_FILE"
chown root:root "$API_KEY_FILE"

echo "✅ API Key 已安全保存至 $API_KEY_FILE"
echo "✅ 部署与配置已完成！"