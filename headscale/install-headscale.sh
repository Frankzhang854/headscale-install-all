#!/bin/bash

set -e

# 判断是否为 root
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    if ! command -v sudo &> /dev/null; then
        echo "❌ 未安装 sudo，且当前不是 root 用户，请以 root 身份运行或安装 sudo。"
        exit 1
    fi
    SUDO="sudo"
fi

echo "🚀 开始安装 Headscale..."

# 1. 获取最新版本
LATEST_VERSION=$(curl -s https://api.github.com/repos/juanfont/headscale/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
if [ -z "$LATEST_VERSION" ]; then
    echo "❌ 无法获取最新版本号。"
    exit 1
fi

# 2. 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)   HEADSCALE_ARCH="amd64" ;;
    aarch64)  HEADSCALE_ARCH="arm64" ;;
    armv7l)   HEADSCALE_ARCH="armv7" ;;
    *)
        echo "❌ 不支持的架构: $ARCH"
        exit 1
        ;;
esac

DOWNLOAD_URL="https://github.com/juanfont/headscale/releases/download/v${LATEST_VERSION}/headscale_${LATEST_VERSION}_linux_${HEADSCALE_ARCH}.deb"

echo "📦 最新版本: $LATEST_VERSION"
echo "💻 系统架构: $HEADSCALE_ARCH"
echo "🔗 下载链接: $DOWNLOAD_URL"

# 3. 下载并安装
wget --quiet --output-document=headscale.deb "$DOWNLOAD_URL"
$SUDO apt install -y ./headscale.deb

CONFIG_FILE="/etc/headscale/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "⚠️ 配置文件不存在：$CONFIG_FILE"
    exit 1
fi

# === 第一步：安装完成后立即启动服务（使用默认配置）===
echo "🔄 正在首次启动 Headscale 服务（使用默认配置）..."
$SUDO systemctl enable --now headscale

echo "✅ 服务已启动（默认配置）"

# === 第二步：交互式配置 ===
echo ""
echo "🌐 请提供 Headscale 的公网访问地址（例如：https://headscale.example.com 或 http://192.168.1.10:9999）"
read -p "请输入 server_url: " SERVER_URL

if [[ ! "$SERVER_URL" =~ ^https?:// ]]; then
    echo "❌ 必须以 http:// 或 https:// 开头！"
    exit 1
fi

# 提取端口
HOST_AND_PORT="${SERVER_URL#http://}"
HOST_AND_PORT="${HOST_AND_PORT#https://}"
if [[ "$HOST_AND_PORT" == *:* ]] && [[ "$HOST_AND_PORT" != *: ]]; then
    PORT="${HOST_AND_PORT#*:}"
    PORT="${PORT%%/*}"
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "❌ 无效端口: $PORT"
        exit 1
    fi
else
    if [[ "$SERVER_URL" == https://* ]]; then
        PORT="443"
    else
        PORT="80"
    fi
fi

# 询问反向代理
echo ""
echo "❓ 你是否使用 Nginx、Caddy 或其他反向代理？"
echo "   • 如果是（推荐生产环境），Headscale 将仅监听本地 (127.0.0.1:8080)"
echo "   • 如果否（直连模式），Headscale 将监听所有接口 (0.0.0.0:<端口>)"
read -p "使用反向代理？(Y/n): " USE_PROXY

case "${USE_PROXY,,}" in
    n|no)
        LISTEN_ADDR="0.0.0.0:$PORT"
        ;;
    *)
        LISTEN_ADDR="127.0.0.1:8080"
        ;;
esac

# 写入配置
if command -v yq &> /dev/null; then
    $SUDO yq -i ".server_url = \"$SERVER_URL\"" "$CONFIG_FILE"
    $SUDO yq -i ".listen_addr = \"$LISTEN_ADDR\"" "$CONFIG_FILE"
else
    # server_url
    if grep -q "^server_url:" "$CONFIG_FILE"; then
        $SUDO sed -i "s|^server_url:.*|server_url: \"$SERVER_URL\"|" "$CONFIG_FILE"
    else
        $SUDO sed -i "1i server_url: \"$SERVER_URL\"" "$CONFIG_FILE"
    fi
    # listen_addr
    if grep -q "^listen_addr:" "$CONFIG_FILE"; then
        $SUDO sed -i "s|^listen_addr:.*|listen_addr: \"$LISTEN_ADDR\"|" "$CONFIG_FILE"
    else
        if grep -q "^server_url:" "$CONFIG_FILE"; then
            $SUDO sed -i "/^server_url:.*/a listen_addr: \"$LISTEN_ADDR\"" "$CONFIG_FILE"
        else
            $SUDO sed -i "1i listen_addr: \"$LISTEN_ADDR\"" "$CONFIG_FILE"
        fi
    fi
fi

echo "✅ 配置已更新：server_url=$SERVER_URL, listen_addr=$LISTEN_ADDR"

# === 第三步：重启服务使新配置生效 ===
echo "🔁 正在重启 Headscale 服务以应用新配置..."
$SUDO systemctl restart headscale

# === 第四步：查看最终服务状态 ===
echo ""
echo "📋 最终服务状态如下："
$SUDO systemctl status headscale --no-pager -l

echo ""
echo "🎉 安装与配置完成！"
echo "📄 配置文件: /etc/headscale/config.yaml"
if [[ "$LISTEN_ADDR" == 0.0.0.0:* ]]; then
    echo "⚠️  注意：服务监听公网端口 ${LISTEN_ADDR#*:}，请确保防火墙安全！"
else
    echo "🔒 安全提示：服务仅监听本地，记得配置反向代理。"
fi