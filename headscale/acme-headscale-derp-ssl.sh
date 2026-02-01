#!/bin/bash
# ================================================================
# Headscale + DERP 专用 ACME 证书管理脚本（v3.5）
# 作者：基于 acme.sh 官方工具封装
# 特性：
#   - 彻底删除证书：acme.sh --remove + rm -rf {,_ecc}
#   - 自动 ECC 密钥支持
#   - 通配符兼容任意子域
#   - 安全交互确认
# ================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：此脚本需要以 root 权限运行"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 彻底删除单个域名证书函数 ====================
remove_domain_cert() {
    local domain="$1"
    if [ -z "$domain" ]; then
        echo -e "${RED}❌ 域名不能为空${NC}"
        return 1
    fi

    # 检查是否在 acme.sh 注册列表中
    if ! acme.sh --list | awk 'NR>1 {print $1}' | grep -q "^${domain}$"; then
        echo -e "${YELLOW}⚠️  域名 $domain 未在 acme.sh 中注册，跳过 --remove${NC}"
    else
        echo -e "${YELLOW}正在移除证书注册信息: $domain${NC}"
        acme.sh --remove -d "$domain"
    fi

    # 彻底删除所有可能的证书目录（ECC + RSA）
    echo -e "${YELLOW}正在删除证书文件...${NC}"
    rm -rf "/root/.acme.sh/$domain"
    rm -rf "/root/.acme.sh/${domain}_ecc"

    echo -e "${GREEN}✅ $domain 的证书已彻底清除${NC}"
}

# ==================== 主菜单 ====================
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}     Headscale/DERP 证书管理工具 (v3.5)${NC}"
echo -e "${BLUE}=========================================${NC}"
echo "1. 申请并部署 SSL 证书（自动跳过已存在证书）"
echo "2. 仅部署已有证书（不重新申请）"
echo "3. 清除所有 acme.sh 证书（⚠️ 危险操作）"
echo "4. 退出"

read -p "请选择操作 [1/2/3/4]：" MAIN_CHOICE

case $MAIN_CHOICE in
    3)
        echo -e "\n${RED}⚠️  警告：此操作将删除所有通过 acme.sh 申请的证书！${NC}"
        echo -e "${YELLOW}包括：私钥、证书、配置记录（不可恢复）${NC}"
        read -p "是否确认清除？输入 'YES' 继续：" CONFIRM
        if [[ "$CONFIRM" != "YES" ]]; then
            echo -e "${GREEN}操作已取消${NC}"
            exit 0
        fi

        ALL_DOMAINS=$(acme.sh --list | tail -n +2 | awk '{print $1}')
        if [ -z "$ALL_DOMAINS" ]; then
            echo -e "${GREEN}无证书可删除${NC}"
            exit 0
        fi

        echo -e "${RED}即将删除以下证书：${NC}"
        echo "$ALL_DOMAINS"
        read -p "再次确认删除？输入 'DELETE'：" FINAL_CONFIRM
        if [[ "$FINAL_CONFIRM" != "DELETE" ]]; then
            echo -e "${GREEN}操作已取消${NC}"
            exit 0
        fi

        for domain in $ALL_DOMAINS; do
            remove_domain_cert "$domain"
        done
        echo -e "${GREEN}✅ 所有证书已彻底清除！${NC}"
        exit 0
        ;;

    4)
        echo "退出。"
        exit 0
        ;;

    1|2)
        ;;
    *)
        echo -e "${RED}无效选项${NC}"
        exit 1
        ;;
esac

# ==================== 安装依赖与 acme.sh ====================
if [ "$MAIN_CHOICE" = "1" ]; then
    echo -e "\n${BLUE}==================== 安装依赖 ====================${NC}"
    apt update -y && apt install -y curl git wget nano screen
    if [ $? -ne 0 ]; then
        echo -e "${RED}依赖安装失败${NC}"
        exit 1
    fi

    while true; do
        read -p "请输入注册邮箱：" USER_EMAIL
        if [[ "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        fi
        echo -e "${RED}邮箱格式无效${NC}"
    done

    echo -e "\n${BLUE}==================== 安装 acme.sh ====================${NC}"
    export AUTO_UPGRADE='0'
    curl https://get.acme.sh | sh -s email="$USER_EMAIL"
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null
fi

# ==================== 选择 DNS 服务商 ====================
declare -A DNS_PROVIDERS=(
    [1]="AliDNS（阿里云）"
    [2]="Cloudflare（CF）"
    [3]="DNSPod（腾讯云）"
    [4]="Godaddy"
    [5]="AWS Route 53"
    [6]="Google Cloud DNS"
    [7]="Namecheap"
    [8]="HuaweiDNS（华为云）"
    [9]="Linode DNS"
    [10]="DigitalOcean DNS"
)
declare -A DNS_SHORT_NAMES=(
    [1]="dns_ali"
    [2]="dns_cf"
    [3]="dns_dp"
    [4]="dns_gd"
    [5]="dns_aws"
    [6]="dns_gcloud"
    [7]="dns_namecheap"
    [8]="dns_huaweicloud"
    [9]="dns_linode"
    [10]="dns_digitalocean"
)

echo -e "\n${BLUE}==================== 选择 DNS 服务商 ====================${NC}"
for i in $(seq 1 ${#DNS_PROVIDERS[@]}); do
    echo "  $i. ${DNS_PROVIDERS[$i]}"
done

while true; do
    read -p "请选择序号：" DNS_CHOICE
    if [[ -n "${DNS_SHORT_NAMES[$DNS_CHOICE]}" ]]; then
        DNS_SHORT_NAME="${DNS_SHORT_NAMES[$DNS_CHOICE]}"
        SELECTED_NAME="${DNS_PROVIDERS[$DNS_CHOICE]}"
        break
    fi
    echo -e "${RED}无效序号，请输入 1-${#DNS_PROVIDERS[@]}${NC}"
done
echo -e "${GREEN}已选择：$SELECTED_NAME${NC}"

# 配置 API 密钥
case $DNS_CHOICE in
    1) read -p "AccessKey ID：" ALI_KEY; read -s -p "AccessKey Secret：" ALI_SECRET; echo; export Ali_Key="$ALI_KEY"; export Ali_Secret="$ALI_SECRET"; echo "export Ali_Key='$ALI_KEY'" >> ~/.bashrc; echo "export Ali_Secret='$ALI_SECRET'" >> ~/.bashrc ;;
    2) echo "1. API Token（推荐）  2. Global Key"; read -p "选择 [1/2]：" CF_TYPE; if [ "$CF_TYPE" = "1" ]; then read -p "API Token：" CF_TOKEN; export CF_Token="$CF_TOKEN"; echo "export CF_Token='$CF_TOKEN'" >> ~/.bashrc; else read -p "Global Key：" CF_KEY; read -p "邮箱：" CF_EMAIL; export CF_Key="$CF_KEY"; export CF_Email="$CF_EMAIL"; echo "export CF_Key='$CF_KEY'" >> ~/.bashrc; echo "export CF_Email='$CF_EMAIL'" >> ~/.bashrc; fi ;;
    3) read -p "SecretId：" DP_ID; read -s -p "SecretKey：" DP_KEY; echo; export DP_Id="$DP_ID"; export DP_Key="$DP_KEY"; echo "export DP_Id='$DP_ID'" >> ~/.bashrc; echo "export DP_Key='$DP_KEY'" >> ~/.bashrc ;;
    4) read -p "API Key：" GD_KEY; read -s -p "API Secret：" GD_SECRET; echo; export GD_Key="$GD_KEY"; export GD_Secret="$GD_SECRET"; echo "export GD_Key='$GD_KEY'" >> ~/.bashrc; echo "export GD_Secret='$GD_SECRET'" >> ~/.bashrc ;;
    5) read -p "Access Key ID：" AWS_KEY; read -s -p "Secret Access Key：" AWS_SECRET; echo; export AWS_ACCESS_KEY_ID="$AWS_KEY"; export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"; echo "export AWS_ACCESS_KEY_ID='$AWS_KEY'" >> ~/.bashrc; echo "export AWS_SECRET_ACCESS_KEY='$AWS_SECRET'" >> ~/.bashrc ;;
    6) read -p "Service Account 文件路径：" GCLOUD_PATH; export GCloud_Key="$GCLOUD_PATH"; echo "export GCloud_Key='$GCLOUD_PATH'" >> ~/.bashrc ;;
    7) read -p "API 用户名：" NC_USER; read -p "API 密钥：" NC_KEY; export NAMECHEAP_USERNAME="$NC_USER"; export NAMECHEAP_API_KEY="$NC_KEY"; echo "export NAMECHEAP_USERNAME='$NC_USER'" >> ~/.bashrc; echo "export NAMECHEAP_API_KEY='$NC_KEY'" >> ~/.bashrc ;;
    8) read -p "Access Key：" HW_KEY; read -s -p "Secret Key：" HW_SECRET; echo; export HUAWEICLOUD_ACCESS_KEY="$HW_KEY"; export HUAWEICLOUD_SECRET_KEY="$HW_SECRET"; echo "export HUAWEICLOUD_ACCESS_KEY='$HW_KEY'" >> ~/.bashrc; echo "export HUAWEICLOUD_SECRET_KEY='$HW_SECRET'" >> ~/.bashrc ;;
    9) read -p "API Token：" LINODE_TOKEN; export LINODE_API_KEY="$LINODE_TOKEN"; echo "export LINODE_API_KEY='$LINODE_TOKEN'" >> ~/.bashrc ;;
    10) read -p "API Token：" DO_TOKEN; export DO_API_KEY="$DO_TOKEN"; echo "export DO_API_KEY='$DO_TOKEN'" >> ~/.bashrc ;;
esac
source ~/.bashrc

# ==================== 输入主域名 ====================
while true; do
    read -p "请输入主域名（如 example.com）：" MAIN_DOMAIN_RAW
    MAIN_DOMAIN=$(echo "$MAIN_DOMAIN_RAW" | xargs)
    if [[ "$MAIN_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        break
    fi
    echo -e "${RED}域名格式无效${NC}"
done

DOMAINS=(-d "$MAIN_DOMAIN")
read -p "包含 www.$MAIN_DOMAIN？[y/n]：" WWW
[[ "$WWW" =~ ^[Yy] ]] && DOMAINS+=(-d "www.$MAIN_DOMAIN")
read -p "申请通配符 *.$MAIN_DOMAIN？[y/n]：" WC
[[ "$WC" =~ ^[Yy] ]] && DOMAINS+=(-d "*.$MAIN_DOMAIN")

# ==================== 申请前清理（使用新函数）====================
if [ "$MAIN_CHOICE" = "1" ]; then
    if acme.sh --list | awk 'NR>1 {print $1}' | grep -q "^${MAIN_DOMAIN}$"; then
        echo -e "\n${YELLOW}⚠️  检测到已存在证书：$MAIN_DOMAIN${NC}"
        read -p "是否彻底删除并重新申请？[y/N]：" CLEAN_OPT
        if [[ "$CLEAN_OPT" =~ ^[Yy]$ ]]; then
            remove_domain_cert "$MAIN_DOMAIN"
        fi
    fi
fi

# ==================== 确定证书目录 ====================
if [ -d "/root/.acme.sh/${MAIN_DOMAIN}_ecc" ]; then
    CERT_DIR="/root/.acme.sh/${MAIN_DOMAIN}_ecc"
elif [ -d "/root/.acme.sh/$MAIN_DOMAIN" ]; then
    CERT_DIR="/root/.acme.sh/$MAIN_DOMAIN"
else
    CERT_DIR="/root/.acme.sh/${MAIN_DOMAIN}_ecc"
fi

PRIMARY_DOMAIN="$MAIN_DOMAIN"
KEY_FILE="$CERT_DIR/$PRIMARY_DOMAIN.key"

# ==================== 申请或跳过 ====================
if [ -f "$CERT_DIR/fullchain.cer" ] && [ "$MAIN_CHOICE" = "1" ]; then
    echo -e "${GREEN}✅ 有效证书已存在，跳过申请！${NC}"
else
    if [ "$MAIN_CHOICE" = "2" ]; then
        if [ ! -f "$CERT_DIR/fullchain.cer" ]; then
            echo -e "${RED}❌ 证书不存在，请先申请（选择选项1）${NC}"
            exit 1
        fi
    else
        ISSUE_CMD="acme.sh --issue --dns $DNS_SHORT_NAME ${DOMAINS[*]}"
        if [ -f "$KEY_FILE" ] && [ ! -f "$CERT_DIR/fullchain.cer" ]; then
            echo -e "${YELLOW}⚠️  私钥存在但无有效证书，启用 --force${NC}"
            ISSUE_CMD="$ISSUE_CMD --force"
        fi

        echo -e "\n${YELLOW}正在申请证书（使用 $SELECTED_NAME）...${NC}"
        source /root/.acme.sh/acme.sh.env 2>/dev/null || true

        if ! eval "$ISSUE_CMD"; then
            echo -e "${RED}❌ 证书申请失败！${NC}"
            echo -e "${YELLOW}建议调试命令：${NC}"
            echo "    $ISSUE_CMD --debug 2"
            exit 1
        fi
        echo -e "${GREEN}✅ 证书申请成功！${NC}"
    fi
fi

# ==================== 部署函数 ====================
deploy_nginx() {
    local NGINX_CONF="/etc/nginx/sites-available/headscale"
    [ ! -f "$NGINX_CONF" ] && { echo -e "${RED}❌ Nginx 配置未找到${NC}"; return 1; }
    local CRT=$(grep -E '^\s*ssl_certificate\s' "$NGINX_CONF" | head -1 | awk '{print $2}' | tr -d ';')
    local KEY=$(grep -E '^\s*ssl_certificate_key\s' "$NGINX_CONF" | head -1 | awk '{print $2}' | tr -d ';')
    [ -z "$CRT" ] || [ -z "$KEY" ] && { echo -e "${RED}❌ 无法解析证书路径${NC}"; return 1; }
    mkdir -p "$(dirname "$CRT")"
    if acme.sh --install-cert -d "$MAIN_DOMAIN" --key-file "$KEY" --fullchain-file "$CRT" --reloadcmd "systemctl reload nginx"; then
        return 0
    else
        echo -e "${RED}❌ 部署失败${NC}"
        return 1
    fi
}

deploy_derp() {
    local DERP_YAML="/etc/headscale/derp.yaml"
    [ ! -f "$DERP_YAML" ] && { echo -e "${RED}❌ DERP 配置未找到${NC}"; return 1; }
    local HOSTNAME=$(grep -E '^\s*hostname:\s*' "$DERP_YAML" | head -1 | sed -E 's/^\s*hostname:\s*["'\'']?//; s/["'\'']?\s*$//')
    [ -z "$HOSTNAME" ] && { echo -e "${RED}❌ 无法解析 hostname${NC}"; return 1; }
    local CRT="/etc/derp/$HOSTNAME.crt"
    local KEY="/etc/derp/$HOSTNAME.key"
    mkdir -p /etc/derp
    if acme.sh --install-cert -d "$MAIN_DOMAIN" --key-file "$KEY" --fullchain-file "$CRT" --reloadcmd "systemctl restart derper"; then
        chmod 600 "$KEY" 2>/dev/null; chmod 644 "$CRT" 2>/dev/null
        return 0
    else
        echo -e "${RED}❌ 部署失败${NC}"
        return 1
    fi
}

# ==================== 部署菜单 ====================
DEPLOYED_NGINX=false
DEPLOYED_DERP=false

while true; do
    echo -e "\n${BLUE}==================== 证书部署菜单 ====================${NC}"
    echo -e "${YELLOW}通配符证书（*.${MAIN_DOMAIN}）可用于任意子域${NC}"

    NGINX_LABEL="1. 部署到 Headscale (Nginx)"
    DERP_LABEL="2. 部署到 DERP"
    [ "$DEPLOYED_NGINX" = true ] && NGINX_LABEL="$NGINX_LABEL ${GREEN}[已部署]${NC}"
    [ "$DEPLOYED_DERP" = true ] && DERP_LABEL="$DERP_LABEL ${GREEN}[已部署]${NC}"

    echo -e "$NGINX_LABEL"
    echo -e "$DERP_LABEL"
    echo "3. 返回主菜单 / 退出部署"

    read -p "请选择操作 [1/2/3]：" DEPLOY_OPT

    case $DEPLOY_OPT in
        1)
            if deploy_nginx; then
                DEPLOYED_NGINX=true
                echo -e "${GREEN}✅ Nginx 部署完成！${NC}"
            else
                echo -e "${RED}❌ Nginx 部署失败${NC}"
            fi
            ;;
        2)
            if deploy_derp; then
                DEPLOYED_DERP=true
                echo -e "${GREEN}✅ DERP 部署完成！${NC}"
            else
                echo -e "${RED}❌ DERP 部署失败${NC}"
            fi
            ;;
        3)
            echo -e "${GREEN}退出部署流程。${NC}"
            break
            ;;
        *)
            echo -e "${RED}无效选项，请重试${NC}"
            ;;
    esac

    echo -e "\n${YELLOW}按回车返回部署菜单...${NC}"
    read -r
done

echo -e "\n🎉 所有操作完成！"