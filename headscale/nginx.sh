#!/bin/bash

# =============================================================
# Headscale + Web Portal Nginx 配置脚本（终极修复版）
# 修复：
#   - listen_addr 提取（去除 YAML 引号）
#   - SSL cipher 列表（标准套件）
#   - Nginx 未运行时自动 start（而非 reload）
#   - 证书权限自动修复
#   - 临时证书生成
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# --- 安装 Nginx ---
install_nginx_if_needed() {
    if command -v nginx &> /dev/null; then return 0; fi
    log "正在安装 Nginx..."
    if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else error "无法识别系统"; fi
    case "$OS" in
        ubuntu|debian) export DEBIAN_FRONTEND=noninteractive; apt update -y && apt install -y nginx openssl ;;
        centos|rhel|rocky|almalinux) (command -v dnf &>/dev/null && dnf install -y nginx openssl) || yum install -y nginx openssl; systemctl enable --now nginx ;;
        alpine) apk add --no-cache nginx openssl; rc-update add nginx default ;;
        *) error "不支持的操作系统: $OS" ;;
    esac
    command -v nginx &>/dev/null || error "Nginx 安装失败"
}

# --- 检测 Nginx 用户 ---
detect_nginx_user() {
    if [ -f /etc/nginx/nginx.conf ]; then
        USER=$(grep -E '^\s*user\s' /etc/nginx/nginx.conf | head -n1 | awk '{print $2}' | tr -d ';')
        [ -n "$USER" ] && { echo "$USER"; return; }
    fi
    id www-data &>/dev/null && { echo "www-data"; return; }
    id nginx &>/dev/null && { echo "nginx"; return; }
    echo "www-data"
}

# --- 修复证书权限 ---
fix_cert_permissions() {
    local cert="$1" key="$2" user="$3"
    [ ! -f "$cert" ] || [ ! -f "$key" ] && return
    chown root:root "$cert" 2>/dev/null
    chmod 644 "$cert"
    chown root:"$user" "$key" 2>/dev/null
    chmod 640 "$key"
    log "✅ 证书权限已修复（Nginx 用户: $user）"
}

# --- 生成临时证书 ---
generate_temp_cert() {
    local domain="$1"
    local cert_file="$2"
    local key_file="$3"
    local ssl_dir=$(dirname "$cert_file")

    mkdir -p "$ssl_dir"
    log "正在为 $domain 生成临时自签名证书（有效期365天）..."

    if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key_file" -out "$cert_file" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" 2>/dev/null; then
        cat > /tmp/openssl.cnf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_ext

[dn]
CN = $domain

[v3_ext]
subjectAltName = DNS:$domain
EOF
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$key_file" -out "$cert_file" \
            -config /tmp/openssl.cnf -extensions v3_ext
        rm -f /tmp/openssl.cnf
    fi

    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        log "✅ 临时证书已生成"
        warn "⚠️ 浏览器会显示不安全警告，请尽快替换为正式证书。"
        return 0
    else
        error "临时证书生成失败"
    fi
}

# ==================== 主流程 ====================

install_nginx_if_needed

# --- 输入域名 ---
read -p "$(echo -e ${YELLOW}"请输入域名（用于 server_name，不可留空）: "${NC})" DOMAIN
[ -z "$DOMAIN" ] && error "域名不能为空！"

# --- 默认证书路径 ---
DEFAULT_SSL_DIR="/etc/headscale/config/ssl"
DEFAULT_CERT="$DEFAULT_SSL_DIR/${DOMAIN}.crt"
DEFAULT_KEY="$DEFAULT_SSL_DIR/${DOMAIN}.key"

read -p "$(echo -e ${YELLOW}"证书文件路径 [默认: $DEFAULT_CERT]: "${NC})" CUSTOM_CERT
read -p "$(echo -e ${YELLOW}"私钥文件路径 [默认: $DEFAULT_KEY]: "${NC})" CUSTOM_KEY

CERT_FILE="${CUSTOM_CERT:-$DEFAULT_CERT}"
KEY_FILE="${CUSTOM_KEY:-$DEFAULT_KEY}"

if [[ "$CERT_FILE" == "$DEFAULT_CERT" ]]; then
    mkdir -p "$DEFAULT_SSL_DIR"
fi

# --- 检查 Headscale 配置 ---
HEADSCALE_CONFIG="/etc/headscale/config.yaml"
if [ ! -f "$HEADSCALE_CONFIG" ]; then
    error "Headscale 配置文件不存在: $HEADSCALE_CONFIG"
fi

LOCAL_ADDR=$(grep -E '^\s*listen_addr\s*:' "$HEADSCALE_CONFIG" | head -n1 | \
             sed -E 's/^\s*listen_addr\s*:\s*["'\'']?//; s/["'\'']?\s*$//')

if [ -z "$LOCAL_ADDR" ]; then
    error "无法从 $HEADSCALE_CONFIG 提取有效的 listen_addr"
fi
if [[ "$LOCAL_ADDR" != *:* ]]; then
    error "listen_addr 格式无效: '$LOCAL_ADDR'"
fi
log "Headscale 后端地址: $LOCAL_ADDR"

# --- 静态页面 ---
STATIC_WEB_ROOT="/var/www/web"
[ ! -d "$STATIC_WEB_ROOT" ] && {
    mkdir -p "$STATIC_WEB_ROOT"
    echo "<h1>Web Portal for $DOMAIN</h1>" > "$STATIC_WEB_ROOT/index.html"
    log "已创建示例页面"
}

# --- HTTPS 端口 ---
read -p "$(echo -e ${YELLOW}"HTTPS 端口 [默认: 443]: "${NC})" REMOTE_PORT
REMOTE_PORT=${REMOTE_PORT:-443}

ENABLE_HTTP=false
if [ "$REMOTE_PORT" -eq 443 ]; then
    read -p "$(echo -e ${YELLOW}"启用 HTTP → HTTPS 跳转? (y/N): "${NC})" ENABLE_HTTP_INPUT
    [[ "$ENABLE_HTTP_INPUT" =~ ^[Yy]$ ]] && ENABLE_HTTP=true
else
    warn "非标准端口 ($REMOTE_PORT)，跳过 HTTP 跳转"
fi

# --- 检测 Nginx 用户 ---
NGINX_USER=$(detect_nginx_user)
log "Nginx 运行用户: $NGINX_USER"

# --- 证书处理 ---
CERT_READY=false
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    fix_cert_permissions "$CERT_FILE" "$KEY_FILE" "$NGINX_USER"
    CERT_READY=true
else
    warn "证书文件缺失"
    echo "    $CERT_FILE"
    echo "    $KEY_FILE"
    read -p "$(echo -e ${YELLOW}"是否生成临时自签名证书？(y/N): "${NC})" GEN_TEMP
    if [[ "$GEN_TEMP" =~ ^[Yy]$ ]]; then
        generate_temp_cert "$DOMAIN" "$CERT_FILE" "$KEY_FILE"
        fix_cert_permissions "$CERT_FILE" "$KEY_FILE" "$NGINX_USER"
        CERT_READY=true
    else
        read -p "$(echo -e ${YELLOW}"是否继续生成配置（后续手动放证书）？(Y/n): "${NC})" CONTINUE
        [[ "$CONTINUE" =~ ^[Nn]$ ]] && { log "已取消"; exit 0; }
        CERT_READY=false
    fi
fi

# --- 确认 ---
log "=== 配置预览 ==="
echo "  域名       : $DOMAIN"
echo "  HTTPS 端口 : $REMOTE_PORT"
echo "  证书       : $CERT_FILE"
echo "  私钥       : $KEY_FILE"
echo "  后端地址   : $LOCAL_ADDR"
read -p "$(echo -e ${YELLOW}"确认生成 Nginx 配置？(Y/n): "${NC})" CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && { log "已取消"; exit 0; }

# --- 生成 Nginx 配置 ---
NGINX_SITE_FILE="/etc/nginx/sites-available/headscale"
{
    if [ "$ENABLE_HTTP" = true ]; then
        cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF
    fi

    cat <<EOF
server {
    listen $REMOTE_PORT ssl http2;
    listen [::]:$REMOTE_PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    client_max_body_size 100M;

    location /web {
        alias $STATIC_WEB_ROOT;
        index index.html;
        try_files \$uri \$uri/ =404;
        autoindex off;
    }

    location / {
        proxy_pass http://$LOCAL_ADDR;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
} > "$NGINX_SITE_FILE"

log "配置已生成: $NGINX_SITE_FILE"
mkdir -p /etc/nginx/sites-enabled
ln -sf "$NGINX_SITE_FILE" /etc/nginx/sites-enabled/headscale

# --- 测试并应用配置（关键修复：智能 start/reload）---
log "正在测试 Nginx 配置..."
if nginx -t; then
    if [ "$CERT_READY" = true ]; then
        if systemctl is-active --quiet nginx; then
            log "🔄 Nginx 正在运行，重载配置..."
            systemctl reload nginx
        else
            log "▶️ Nginx 未运行，正在启动服务..."
            systemctl start nginx
            if systemctl is-active --quiet nginx; then
                log "🎉 Nginx 已成功启动！"
            else
                error "Nginx 启动失败！请运行：journalctl -u nginx --no-pager -n 50"
            fi
        fi
        # 确保开机自启
        systemctl enable nginx >/dev/null 2>&1
    else
        log "✅ 配置语法正确，证书就绪后请运行："
        echo "      sudo nginx -t && sudo systemctl reload nginx"
    fi
else
    error "Nginx 配置错误，请检查 $NGINX_SITE_FILE"
fi

echo ""
echo "🔗 你的服务地址："
echo "   Headscale: https://$DOMAIN:$REMOTE_PORT/"
echo "   Web 页面 : https://$DOMAIN:$REMOTE_PORT/web"