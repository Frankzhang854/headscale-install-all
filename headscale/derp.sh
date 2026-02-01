#!/bin/bash

set -e

echo "🚀 开始安装 DERP 服务（含自动注释默认 URLs）..."

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 用户运行此脚本！"
  exit 1
fi

# 安装 curl
if ! command -v curl &> /dev/null; then
  echo "📦 安装 curl..."
  if [ -f /etc/debian_version ]; then
    apt update && apt install -y curl
  elif [ -f /etc/redhat-release ]; then
    yum install -y curl
  else
    echo "⚠️ 仅支持 Debian/Ubuntu/CentOS/RHEL"
    exit 1
  fi
fi

# === 获取 Go 最新版本 ===
echo "🔍 从 https://go.dev/dl/ 获取最新 Go 版本..."
GO_DL_PAGE=$(curl -s https://go.dev/dl/)
LATEST_GO_VERSION=$(echo "$GO_DL_PAGE" | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed 's/^go//')

if [ -z "$LATEST_GO_VERSION" ]; then
  echo "❌ 无法获取 Go 版本，请检查网络。"
  exit 1
fi
echo "✅ 最新 Go 版本: $LATEST_GO_VERSION"

# 检测架构
case "$(uname -m)" in
  x86_64)   ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "❌ 不支持的架构: $(uname -m)"; exit 1 ;;
esac
OS="linux"
echo "🖥️ 系统: $OS, 架构: $ARCH"

# === 下载 Go（带进度条）===
GO_URL="https://go.dev/dl/go${LATEST_GO_VERSION}.${OS}-${ARCH}.tar.gz"
cd /tmp
echo "📥 正在下载 Go 安装包 (${LATEST_GO_VERSION}) ..."
echo "   URL: $GO_URL"

if ! curl -# -LO "$GO_URL"; then
  echo ""
  echo "❌ Go 下载失败！请检查网络连接。"
  exit 1
fi

[ -d /usr/local/go ] && rm -rf /usr/local/go
tar -C /usr/local -xzf "go${LATEST_GO_VERSION}.${OS}-${ARCH}.tar.gz"

export PATH=$PATH:/usr/local/go/bin
grep -q "/usr/local/go/bin" /etc/profile || echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
source /etc/profile

echo "✅ Go 安装完成:"
go version

# === 基于 IP 地理位置判断是否在中国 ===
is_in_china() {
  echo "🌍 检测服务器地理位置..."
  COUNTRY=$(curl -s --connect-timeout 5 https://ipinfo.io/country 2>/dev/null)
  if [ "$COUNTRY" = "CN" ]; then
    echo "📍 位置: 中国 (Country Code: CN)"
    return 0
  else
    echo "📍 位置: 国外 (Country Code: ${COUNTRY:-Unknown})"
    return 1
  fi
}

if is_in_china; then
  echo "🇨🇳 设置国内 Go 代理..."
  go env -w GO111MODULE=on
  go env -w GOPROXY=https://goproxy.cn,direct
else
  echo "🌐 位于国外，使用默认模块源。"
fi

# === 安装 derper（显示完整日志）===
echo ""
echo "🛠️ 正在执行 'go install tailscale.com/cmd/derper@main' ..."
echo "   此过程将显示模块下载和编译日志，请耐心等待。"
echo ""

go install tailscale.com/cmd/derper@main

echo ""
echo "✅ derper 编译并安装完成。"

# === 交互式配置 ===
HEADSCALE_DIR="/etc/headscale"
DERP_DIR="/etc/derp"
mkdir -p "$HEADSCALE_DIR" "$DERP_DIR"

echo ""
echo "📝 请配置 DERP 节点信息："
read -p "regioncode (例如: thk): " REGIONCODE
read -p "regionname (例如: Tencent Hongkong): " REGIONNAME
read -p "hostname (例如: derp.example.com): " HOSTNAME

read -p "stunport (默认 3478): " STUNPORT_INPUT
STUNPORT=${STUNPORT_INPUT:-3478}

while true; do
  read -p "derpport (默认 33445): " DERP_PORT_INPUT
  DERP_PORT=${DERP_PORT_INPUT:-33445}
  # === 修正：使用英文半角 =~ ===
  if [[ "$DERP_PORT" =~ ^[0-9]+$ ]] && [ "$DERP_PORT" -ge 1 ] && [ "$DERP_PORT" -le 65535 ]; then
    break
  else
    echo "❌ 请输入有效的端口号（1-65535）"
  fi
done

# === 新增：停止旧服务避免 "Text file busy" ===
systemctl stop derper 2>/dev/null || true
cp "/root/go/bin/derper" "$DERP_DIR/"

# === 生成 systemd 服务 ===
cat > /etc/systemd/system/derper.service <<EOF
[Unit]
Description=TS Derper
After=network.target
Wants=network.target

[Service]
User=root
Restart=always
ExecStart=/etc/derp/derper -hostname $HOSTNAME -a :$DERP_PORT -http-port -1 --certdir /etc/derp --certmode manual --stun-port $STUNPORT --verify-clients
RestartPreventExitStatus=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable derper
systemctl start derper
echo "✅ DERP 服务已启动（域名: $HOSTNAME，端口: $DERP_PORT）"

# === 生成 derp.yaml ===
cat > "$HEADSCALE_DIR/derp.yaml" <<EOF
# /etc/headscale/derp.yaml
regions:
  900:
    regionid: 900
    regioncode: $REGIONCODE
    regionname: $REGIONNAME
    nodes:
      - name: 900a
        regionid: 900
        hostname: $HOSTNAME
        stunport: $STUNPORT
        stunonly: false
        derpport: $DERP_PORT
EOF

echo "✅ DERP 配置已保存到 $HEADSCALE_DIR/derp.yaml"

# === 更新 HeadScale config.yaml ===
CONFIG_YAML="$HEADSCALE_DIR/config.yaml"

if [ -f "$CONFIG_YAML" ]; then
  # 修复 paths: [] → paths:
  if grep -q "^[[:space:]]*paths:[[:space:]]*\[\]" "$CONFIG_YAML"; then
    sed -i 's/^[[:space:]]*paths:[[:space:]]*\[\]/  paths:/g' "$CONFIG_YAML"
    echo "🔧 已修复 config.yaml 中的 'paths: []'"
  fi

  # 注入 derp.yaml 路径
  if grep -q "^[[:space:]]*derp:" "$CONFIG_YAML"; then
    if ! grep -q "^[[:space:]]*paths:" "$CONFIG_YAML"; then
      sed -i '/^[[:space:]]*derp:/a\  paths:' "$CONFIG_YAML"
    fi
    if ! grep -q "/etc/headscale/derp.yaml" "$CONFIG_YAML"; then
      sed -i '/^[[:space:]]*paths:/a\    - /etc/headscale/derp.yaml' "$CONFIG_YAML"
      echo "✅ 已将 derp.yaml 添加到 config.yaml"
    else
      echo "ℹ️ 路径已存在，跳过。"
    fi
  else
    echo "⚠️ config.yaml 中缺少 'derp:' 块，请手动添加："
    echo "derp:"
    echo "  paths:"
    echo "    - /etc/headscale/derp.yaml"
  fi

  # === 注释掉 derp.urls 下的所有 URL 条目 ===
  if grep -q "^[[:space:]]*urls:[[:space:]]*$" "$CONFIG_YAML"; then
    echo "🧹 正在注释 config.yaml 中的 derp.urls 默认地址..."
    sed -i '/^[[:space:]]*urls:[[:space:]]*$/{
        n
        :loop
        /^[[:space:]]*-[[:space:]]/ {
            s/^[[:space:]]*-/#   -/
            n
            b loop
        }
    }' "$CONFIG_YAML"
    echo "✅ 已注释 derp.urls 下的所有默认 URL。"
  else
    echo "ℹ️ config.yaml 中未找到 'urls:'，跳过注释。"
  fi

  # 重启 headscale 服务
  if systemctl is-active --quiet headscale 2>/dev/null; then
    echo "🔄 重启 headscale 服务..."
    systemctl restart headscale
  elif systemctl list-unit-files 2>/dev/null | grep -q "^headscale.service"; then
    echo "🔄 启动 headscale 服务..."
    systemctl start headscale
    systemctl enable headscale
  else
    echo "ℹ️ 未检测到 headscale 服务。"
  fi
else
  echo "⚠️ HeadScale 配置文件不存在: $CONFIG_YAML"
fi

echo ""
echo "🎉 安装与配置全部完成！"
echo "💡 重要提醒："
echo "   - 域名 $HOSTNAME 必须解析到本机公网 IP"
echo "   - 开放防火墙端口：TCP $DERP_PORT, UDP/TCP $STUNPORT"
echo "   - 手动放入 TLS 证书到 /etc/derp/，文件名必须为："
echo "        /etc/derp/${HOSTNAME}.crt"
echo "        /etc/derp/${HOSTNAME}.key"
