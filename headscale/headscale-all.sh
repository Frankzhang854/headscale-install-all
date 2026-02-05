#!/bin/bash
# 
# 脚本版本: v4.1
# 描述: Headscale 管理工具 (整合脚本)
# 功能:
# - 交互式安装/配置 Headscale, Nginx, DERP, Headscale UI。
# - 升级/重装 Headscale 并合并配置、恢复数据。
# - 备份和恢复 Headscale 配置与数据。
# - 管理相关服务 (headscale, nginx, derper, tailscale)。
# - 启动时自动为所需脚本赋予执行权限。
# - 选项 14 (升级/重装) 和选项 16 (一键还原) 已移除自动安装UI的步骤。
# 

# ======== 全局配置 ========
# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认的配置文件路径 (仅用于升级时的自动配置)
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/config/upgrade-config.conf"
# 默认的数据备份目录
DEFAULT_BACKUP_DIR="$SCRIPT_DIR/backup"

# 定义需要执行权限的脚本列表
NEEDED_EXECUTABLES=(
    "install-headscale.sh"
    "nginx.sh"
    "derp.sh"
    "install-headscaleui.sh"
    "acme-headscale-derp-ssl.sh"
    "uninstall-headscale.sh"
    "qzderp_v1_0.py"
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 检查 yq 是否安装
check_yq_installed() {
    if ! command -v yq &> /dev/null; then
        log_error "yq 命令未找到。请先安装 yq。"
        log_info "例如: apt update && apt install -y yq"
        log_info "或: curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
        return 1
    fi
}

# 赋予脚本执行权限
make_scripts_executable() {
    log_info "正在检查并赋予所需脚本执行权限..."
    for script in "${NEEDED_EXECUTABLES[@]}"; do
        local full_path="$SCRIPT_DIR/$script"
        if [[ -f "$full_path" ]]; then
            if [[ -x "$full_path" ]]; then
                log_info "  - $script 已具有执行权限。"
            else
                log_info "  - $script 权限不足，正在授予执行权限 (chmod +x)..."
                chmod +x "$full_path"
                if [[ $? -eq 0 ]]; then
                    log_info "  - $script 权限设置成功。"
                else
                    log_error "  - 为 $script 设置执行权限失败！"
                    return 1
                fi
            fi
        else
            log_warn "  - 脚本 $script 在 $SCRIPT_DIR 中不存在。"
        fi
    done
    log_info "所有必需脚本的权限检查完成。"
}

# ======== 配置文件读写与验证 (仅用于升级) ========

# 检查升级配置文件是否存在并加载
check_and_load_upgrade_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "升级配置文件 $CONFIG_FILE 不存在。"
        log_info "请先生成配置文件模板，并填写升级所需参数。"
        return 1
    else
        log_info "加载升级配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
        return 0
    fi
}

# 生成新的升级配置文件模板
generate_new_config() {
    local config_path="$1"
    # 确保目录存在
    mkdir -p "$(dirname "$config_path")"
    
    log_info "正在创建新的升级配置文件模板: $config_path"
    cat > "$config_path" << EOF
# Headscale Manager 升级配置文件
# 此文件仅在升级 Headscale 时使用，用于自动填充安装脚本的交互问题。
# 请根据您之前的安装情况修改以下参数

# --- Headscale 升级时的配置 ---
# 您之前设置的 Headscale 公网访问地址 (server_url)，例如 https://your-domain.com:8080
HEADSCALE_SERVER_URL="https://your-domain.com:8080"

# 是否使用反向代理 (y/n)，取决于您之前的安装选择
USE_REVERSE_PROXY="y" # 或 "n"
EOF
    log_info "升级配置文件模板已创建。请编辑 $config_path 填写正确的参数后，再执行升级操作。"
    exit 0
}

# ======== 功能函数 ========

# 1. 安装 Headscale (交互式)
install_headscale_interactive() {
    log_info "开始安装 Headscale (交互模式)..."
    local script_path="$SCRIPT_DIR/install-headscale.sh"
    if [[ -f "$script_path" ]]; then
        "$script_path"
        log_info "Headscale 安装完成。"
    else
        log_error "找不到安装脚本 $script_path"
    fi
}

# 2. 安装 Nginx 配置 (交互式)
install_nginx_interactive() {
    log_info "开始配置 Nginx (交互模式)..."
    local script_path="$SCRIPT_DIR/nginx.sh"
    if [[ -f "$script_path" ]]; then
        "$script_path"
        log_info "Nginx 配置完成。"
    else
        log_error "找不到配置脚本 $script_path"
    fi
}

# 3. 安装 DERP (交互式)
install_derp_interactive() {
    log_info "开始安装 DERP (交互模式)..."
    local script_path="$SCRIPT_DIR/derp.sh"
    if [[ -f "$script_path" ]]; then
        "$script_path"
        log_info "DERP 安装完成。"
    else
        log_error "找不到安装脚本 $script_path"
    fi
}

# 4. 安装 Headscale UI (交互式)
install_headscale_ui_interactive() {
    log_info "开始安装 Headscale UI (交互模式)..."
    local script_path="$SCRIPT_DIR/install-headscaleui.sh"
    if [[ -f "$script_path" ]]; then
        "$script_path"
        log_info "Headscale UI 安装完成。"
    else
        log_error "找不到安装脚本 $script_path"
    fi
}

# 5. 配置 ACME 证书 (交互式)
configure_acme_interactive() {
    log_info "开始配置 ACME 证书 (交互模式)..."
    local script_path="$SCRIPT_DIR/acme-headscale-derp-ssl.sh"
    if [[ -f "$script_path" ]]; then
        "$script_path"
    else
        log_error "找不到配置脚本 $script_path"
    fi
}

# 6. 安装 Tailscale
install_tailscale() {
    log_info "开始安装 Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    if command -v tailscale &> /dev/null; then
        log_info "Tailscale 安装成功。"
    else
        log_error "Tailscale 安装可能失败，请检查网络连接或手动安装。"
    fi
}

# 7. 重启 Headscale
restart_headscale() {
    log_info "正在重启 Headscale 服务..."
    systemctl restart headscale
    systemctl status headscale --no-pager -l
}

# 8. 重启 Nginx
restart_nginx() {
    log_info "正在重启 Nginx 服务..."
    systemctl restart nginx
    systemctl status nginx --no-pager -l
}

# 9. 重启 DERP (修正服务名)
restart_derp() {
    log_info "正在重启 DERP (derper) 服务..."
    systemctl restart derper # 修正服务名
    systemctl status derper --no-pager -l # 修正服务名
}

# 10. 重启 Tailscale (假设服务名为 tailscaled)
restart_tailscale() {
    log_info "正在重启 Tailscale 服务 (tailscaled)..."
    systemctl restart tailscaled
    systemctl status tailscaled --no-pager -l
}

# 11. 设置配置文件路径 (用于升级)
set_config_file() {
    echo "当前升级配置文件路径: $CONFIG_FILE"
    read -p "请输入新的升级配置文件路径 (留空则使用默认: $DEFAULT_CONFIG_FILE): " new_config
    # 如果用户直接回车，使用默认值
    if [[ -z "$new_config" ]]; then
        CONFIG_FILE="$DEFAULT_CONFIG_FILE"
    else
        CONFIG_FILE="$new_config"
    fi
    export CONFIG_FILE
    log_info "升级配置文件路径已更新为: $CONFIG_FILE"
}

# 12. 设置备份目录路径
set_backup_dir() {
    echo "当前备份目录路径: $BACKUP_DIR"
    read -p "请输入新的备份目录路径 (留空则使用默认: $DEFAULT_BACKUP_DIR): " new_backup_dir
    # 如果用户直接回车，使用默认值
    if [[ -z "$new_backup_dir" ]]; then
        BACKUP_DIR="$DEFAULT_BACKUP_DIR"
    else
        BACKUP_DIR="$new_backup_dir"
    fi
    export BACKUP_DIR
    log_info "备份目录路径已更新为: $BACKUP_DIR"
}

# 13. 生成新的升级配置文件模板
# (函数保持不变，只是重新编号)

# 14. 升级/重装 Headscale (核心功能，使用配置文件)
upgrade_headscale() {
    log_info "开始升级/重装 Headscale..."

    if ! check_and_load_upgrade_config; then
        return 1
    fi

    local backup_dir="$BACKUP_DIR/$(date +%Y%m%d_%H%M%S)_upgrade_backup"
    log_info "创建备份目录: $backup_dir"
    mkdir -p "$backup_dir"

    # 定义需要备份的文件列表
    local files_to_backup=(
        "/etc/headscale/derp.yaml"
        "/etc/headscale/config"      # 备份 config 文件夹
        "/var/lib/headscale"         # 备份数据目录
        "/etc/headscale/config.yaml" # 备份主要配置文件
    )

    # 执行备份
    for file in "${files_to_backup[@]}"; do
        if [[ -e "$file" ]]; then
            log_info "备份 $file -> $backup_dir/"
            cp -r "$file" "$backup_dir/"
        else
            log_warn "要备份的文件/目录不存在: $file"
        fi
    done

    # 停止 Headscale 服务
    log_info "停止 Headscale 服务..."
    systemctl stop headscale || true

    # 卸载旧版
    log_info "卸载旧版 Headscale..."
    local script_path="$SCRIPT_DIR/uninstall-headscale.sh"
    if [[ -f "$script_path" ]]; then
        "$script_path"
    else
        log_error "找不到卸载脚本 $script_path"
        return 1
    fi

    # 安装新版 (使用配置文件自动填充)
    log_info "安装新版 Headscale (使用配置文件)..."

    script_path="$SCRIPT_DIR/install-headscale.sh"
    if [[ -f "$script_path" ]]; then
        # 使用 here document 提供预设答案
        {
            echo "$HEADSCALE_SERVER_URL"
            echo "$USE_REVERSE_PROXY"
        } | "$script_path"
        log_info "Headscale 新版本安装完成。"
    else
        log_error "找不到安装脚本 $script_path"
        return 1
    fi

    # --- 配置文件合并逻辑 (与 restore_headscale 保持一致)---
    log_info "开始合并配置文件..."
    if ! check_yq_installed; then
        log_error "无法进行配置合并，yq 未安装。将跳过合并步骤，使用新安装的默认配置。"
    else
        local old_config_path="$backup_dir/config.yaml"
        local new_template_path="/etc/headscale/config.yaml" # 新安装的模板位置
        
        if [[ -f "$old_config_path" ]] && [[ -f "$new_template_path" ]]; then
            log_info "发现旧配置 $old_config_path 和新模板 $new_template_path，开始合并..."
            
            # 创建临时文件存储合并结果
            local temp_merged_config="/tmp/headscale_config_merged_$(date +%s).yaml"
            
            # 使用 yq 合并，新模板结构优先，旧值覆盖对应字段
            # select(fileIndex == 1) 选择第二个文件（新模板）
            # select(fileIndex == 0) 选择第一个文件（旧配置）
            # * 操作符进行合并
            yq eval-all 'select(fileIndex == 1) * select(fileIndex == 0)' "$old_config_path" "$new_template_path" > "$temp_merged_config"
            
            if [[ $? -eq 0 ]] && [[ -f "$temp_merged_config" ]]; then
                log_info "配置合并成功，结果暂存于 $temp_merged_config"
                
                # 检查合并后的配置是否有效 (语法检查)
                if yq eval '.' "$temp_merged_config" >/dev/null 2>&1; then
                    log_info "合并后的配置语法有效。"
                    # 将合并后的配置复制回最终位置
                    cp "$temp_merged_config" "$new_template_path"
                    log_info "已将合并后的配置写入 $new_template_path"
                else
                    log_error "合并后的配置文件语法无效！"
                    log_error "请手动检查 $temp_merged_config 和 $old_config_path, $new_template_path"
                    log_warn "将保留新安装的默认配置 $new_template_path，不进行合并。"
                    rm -f "$temp_merged_config" # 清理临时文件
                fi
            else
                log_error "yq 合并命令执行失败或未生成临时文件。"
                log_warn "将保留新安装的默认配置 $new_template_path，不进行合并。"
            fi
        else
            log_warn "无法找到旧配置 ($old_config_path) 或新模板 ($new_template_path)，跳过合并。"
        fi
    fi
    # --- 配置文件合并逻辑结束 ---

    # 还原其他备份文件 (安装后进行)
    log_info "从备份还原关键文件..."
    if [[ -f "$backup_dir/derp.yaml" ]]; then
        log_info "还原 derp.yaml..."
        cp "$backup_dir/derp.yaml" /etc/headscale/
    fi
    if [[ -d "$backup_dir/config" ]]; then
        log_info "还原 config 文件夹..."
        rm -rf /etc/headscale/config/* # 清空目标文件夹
        cp -r "$backup_dir/config/"* /etc/headscale/config/
    fi
    if [[ -d "$backup_dir/var_lib_headscale" ]]; then
        log_info "还原数据目录 /var/lib/headscale (请确认此操作安全)..."
        rm -rf /var/lib/headscale/*
        cp -r "$backup_dir/var_lib_headscale/"* /var/lib/headscale/
    fi

    # 重启相关 services
    log_info "重启相关服务..."
    systemctl restart headscale
    systemctl restart nginx
    systemctl restart derper # 修正服务名
    # 重启 tailscaled 服务 (Tailscale 客户端守护进程)
    # 注意: 此命令仅在当前机器也作为 Tailscale 客户端运行时才有效
    if systemctl is-active --quiet tailscaled; then
        log_info "检测到 tailscaled 服务正在运行，正在重启..."
        systemctl restart tailscaled
    else
        log_info "tailscaled 服务未运行，跳过重启。"
    fi

    log_info "Headscale 升级/重装完成！备份已保存至 $backup_dir"
    # 自动安装UI的步骤已移除
}

# 15. 一键备份 Headscale
backup_headscale() {
    log_info "开始一键备份 Headscale..."

    local backup_dir="$BACKUP_DIR/$(date +%Y%m%d_%H%M%S)_manual_backup"
    log_info "创建备份目录: $backup_dir"
    mkdir -p "$backup_dir"

    local files_to_backup=(
        "/etc/headscale/derp.yaml"
        "/etc/headscale/config"      # 备份 config 文件夹
        "/var/lib/headscale"         # 备份数据目录
        "/etc/headscale/config.yaml" # 备份主要配置文件
    )

    for file in "${files_to_backup[@]}"; do
        if [[ -e "$file" ]]; then
            log_info "备份 $file -> $backup_dir/"
            cp -r "$file" "$backup_dir/"
        else
            log_warn "要备份的文件/目录不存在: $file"
        fi
    done

    log_info "Headscale 一键备份完成！备份已保存至 $backup_dir"
}

# 16. 一键还原 Headscale
restore_headscale() {
    log_info "开始一键还原 Headscale..."
    
    echo "请输入要还原的备份目录完整路径:"
    echo "备份通常位于: $BACKUP_DIR"
    read -rp "备份目录路径: " restore_source_dir

    # 检查源备份目录是否存在
    if [[ ! -d "$restore_source_dir" ]]; then
        log_error "指定的备份目录 '$restore_source_dir' 不存在！"
        return 1
    fi

    log_info "将从 '$restore_source_dir' 还原数据。"

    # 停止 Headscale 服务
    log_info "停止 Headscale 服务..."
    systemctl stop headscale || true

    # --- 配置文件合并逻辑 (与 upgrade_headscale 保持一致)---
    log_info "开始合并配置文件..."
    if ! check_yq_installed; then
        log_error "无法进行配置合并，yq 未安装。将跳过合并步骤，使用当前的默认配置。"
    else
        local old_config_path="$restore_source_dir/config.yaml"
        local new_template_path="/etc/headscale/config.yaml" # 当前系统上的配置文件
        
        if [[ -f "$old_config_path" ]] && [[ -f "$new_template_path" ]]; then
            log_info "发现备份配置 $old_config_path 和当前配置 $new_template_path，开始合并..."
            
            # 创建临时文件存储合并结果
            local temp_merged_config="/tmp/headscale_config_restored_$(date +%s).yaml"
            
            # 使用 yq 合并，当前系统上的配置（new_template_path）结构优先，备份中的旧值（old_config_path）覆盖对应字段
            # select(fileIndex == 1) 选择第二个文件（当前系统上的配置）
            # select(fileIndex == 0) 选择第一个文件（备份中的配置）
            # * 操作符进行合并
            yq eval-all 'select(fileIndex == 1) * select(fileIndex == 0)' "$old_config_path" "$new_template_path" > "$temp_merged_config"
            
            if [[ $? -eq 0 ]] && [[ -f "$temp_merged_config" ]]; then
                log_info "配置合并成功，结果暂存于 $temp_merged_config"
                
                # 检查合并后的配置是否有效 (语法检查)
                if yq eval '.' "$temp_merged_config" >/dev/null 2>&1; then
                    log_info "合并后的配置语法有效。"
                    # 将合并后的配置复制回最终位置
                    cp "$temp_merged_config" "$new_template_path"
                    log_info "已将合并后的配置写入 $new_template_path"
                else
                    log_error "合并后的配置文件语法无效！"
                    log_error "请手动检查 $temp_merged_config 和 $old_config_path, $new_template_path"
                    log_warn "将保留当前的配置 $new_template_path，不进行合并。"
                    rm -f "$temp_merged_config" # 清理临时文件
                fi
            else
                log_error "yq 合并命令执行失败或未生成临时文件。"
                log_warn "将保留当前的配置 $new_template_path，不进行合并。"
            fi
        else
            log_warn "无法找到备份配置 ($old_config_path) 或当前配置 ($new_template_path)，跳过合并。"
        fi
    fi
    # --- 配置文件合并逻辑结束 ---

    # 定义需要还原的文件列表及其目标位置 (除了 config.yaml，因为已经合并处理)
    local restore_map=(
        "$restore_source_dir/derp.yaml:/etc/headscale/derp.yaml"
        "$restore_source_dir/config:/etc/headscale/config"
        "$restore_source_dir/var_lib_headscale:/var/lib/headscale"
        # 注意: $restore_source_dir/config.yaml 不在此列表中，因为它已被合并处理
    )

    # 执行还原
    for item in "${restore_map[@]}"; do
        IFS=':' read -r src dst <<< "$item"
        if [[ -e "$src" ]]; then
            if [[ -d "$src" ]]; then
                # 如果源是目录，则清空目标目录后再复制
                log_info "还原目录 $src -> $dst"
                rm -rf "$dst"/*
                cp -r "$src/"* "$dst"/
            elif [[ -f "$src" ]]; then
                # 如果源是文件，则直接复制覆盖
                log_info "还原文件 $src -> $dst"
                cp "$src" "$dst"
            fi
        else
            log_warn "要还原的源文件/目录不存在: $src"
        fi
    done

    # 重启相关 services
    log_info "还原完成，正在重启相关 services..."
    systemctl restart headscale
    systemctl restart nginx
    systemctl restart derper # 修正服务名
    # 重启 tailscaled 服务 (Tailscale 客户端守护进程)
    # 注意: 此命令仅在当前机器也作为 Tailscale 客户端运行时才有效
    if systemctl is-active --quiet tailscaled; then
        log_info "检测到 tailscaled 服务正在运行，正在重启..."
        systemctl restart tailscaled
    else
        log_info "tailscaled 服务未运行，跳过重启。"
    fi

    log_info "Headscale 一键还原完成！"
    # 自动安装UI的步骤已移除
}

# 17. 卸载 Headscale (交互式)
uninstall_headscale_interactive() {
    log_info "开始卸载 Headscale (交互模式)..."
    local script_path="$SCRIPT_DIR/uninstall-headscale.sh"
    if [[ -f "$script_path" ]]; then
        "$script_path"
        log_info "Headscale 卸载完成。"
    else
        log_error "找不到卸载脚本 $script_path"
    fi
}

# 18. 显示菜单
show_menu() {
    clear
    echo "========================================="
    echo "      Headscale 管理工具 (整合脚本)"
    echo "========================================="
    echo "当前升级配置文件: $CONFIG_FILE"
    echo "当前备份目录: $BACKUP_DIR"
    echo "本机强制指定节点中转: python3 qzderp_persistent_map.py force ips_1 ips_2 ips_3"
    echo "查看强制指定节点中转列表: python3 qzderp_persistent_map.py list"
    echo "取消本机强制指定节点中转: python3 qzderp_persistent_map.py cancel ips_1 ips_2 ips_3"
    echo "-----------------------------------------"
    echo "1. 安装/配置 Headscale "
    echo "2. 配置 Nginx 反向代理 "
    echo "3. 安装 DERP 中继服务 "
    echo "4. 安装 Headscale UI "
    echo "5. 配置 ACME SSL 证书 "
    echo "6. 安装 Tailscale"
    echo "7. 重启 Headscale 服务"
    echo "8. 重启 Nginx 服务"
    echo "9. 重启 DERP 服务"
    echo "10. 重启 Tailscale 服务"
    echo "11. 设置/切换升级配置文件路径"
    echo "12. 设置/切换备份目录路径"
    echo "13. 生成新的升级配置文件模板"
    echo "14. 升级/重装 Headscale (备份 -> 卸载 -> 安装 -> 配置合并 -> 还原 -> 重启服务)"
    echo "15. 一键备份 Headscale (备份关键文件夹、目录和 config.yaml)"
    echo "16. 一键还原 Headscale (从指定备份目录智能合并 config.yaml -> 还原 -> 重启服务)"
    echo "17. 卸载 Headscale "
    echo "0. 退出"
    echo "========================================="
    read -p "请选择操作 [0-17]: " choice
}

# ======== 主程序入口 ========
main() {
    # 初始化默认值
    export CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
    export BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"

    # 在主程序开始时检查并设置权限
    make_scripts_executable
    if [[ $? -ne 0 ]]; then
        log_error "脚本权限设置失败，无法继续执行。请手动检查并设置脚本权限。"
        exit 1
    fi

    while true; do
        show_menu
        case $choice in
            1) install_headscale_interactive ;;
            2) install_nginx_interactive ;;
            3) install_derp_interactive ;;
            4) install_headscale_ui_interactive ;;
            5) configure_acme_interactive ;;
            6) install_tailscale ;;
            7) restart_headscale ;;
            8) restart_nginx ;;
            9) restart_derp ;;
            10) restart_tailscale ;;
            11) set_config_file ;;
            12) set_backup_dir ;;
            13) generate_new_config "$CONFIG_FILE" ;;
            14) upgrade_headscale ;; # 移动到这里，已移除自动安装UI步骤
            15) backup_headscale ;; # 移动到这里
            16) restore_headscale ;; # 移动到这里，已移除自动安装UI步骤
            17) uninstall_headscale_interactive ;;
            0) log_info "退出管理工具。"; exit 0 ;;
            *) log_error "无效选项，请重新选择。" ;;
        esac

        # 操作完成后暂停，等待用户按键返回主菜单
        log_info "按任意键返回主菜单..."
        read -n 1 -s -r -p ""
    done
}

# 启动主程序
main "$@"