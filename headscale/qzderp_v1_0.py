#!/usr/bin/env python3
"""
Tailscale 强制中继切换脚本 (专用 NFT 表 - 双向阻止 - 修复版 - 解析 Ping 输出 - 持久化 IP 映射)

该脚本通过 nftables 在专用表中阻止特定节点的 UDP 直连流量 (入站和出站)，
强制其通过 DERP 中继服务器通信。
此版本使用 JSON 文件持久化存储虚拟 IP 和物理 IP 的映射关系，解决了取消强制中继时无法获取物理 IP 的问题。
"""

import subprocess
import re
import ipaddress
import sys
import time
import json
import os

# --- 配置区域 ---
# 需要强制走中继的 Tailscale 虚拟 IP 列表 (IPv4 或 IPv6)
# 仅在不带参数运行脚本时生效 (即 VPS_TO_FORCE_RELAY_MODE = True)
VPS_TO_FORCE_RELAY = [
    # "100.101.102.103", # 示例: 可以在这里添加初始节点
    # "fd7a:115c:a1e0:b1a:abcd:efgh:ijkl:mnop",
    # 如果列表为空，则默认运行时不强制任何节点。
]

# Tailscale 端口
STUN_PORT = 3478
DERP_PORT = 33445  # <-- 修改为您自定义的 DERP 端口

# 持久化映射文件
MAPPING_FILE_PATH = '/root/ts_relay_mapping.json'

# Ping 参数 (用于唤醒连接)
# 注意：现在脚本将使用 tailscale ping 的默认行为，不再传入 -c 和 -i
PING_COUNT = 5      # 这个变量不再用于构建命令，仅作文档参考
PING_INTERVAL = 1   # 这个变量不再用于构建命令，仅作文档参考

# Ping 重试参数 (用于等待 ping 结果)
MAX_PING_RETRIES = 3  # 减少重试次数，因为单次 ping 应该更有效
PING_RETRY_DELAY = 5   # 增加重试间隔，给连接更多时间

# nftables 专用表和链名称
TABLE_NAME = "ts_relay_control"
SET_WS_DENY_LIST_NAME = "ts_ws_deny_list"
SET_STUNPORT_NAME = "ts_stunport" # 用于存放 STUN 和 DERP 端口
CHAIN_HOOKED_NAME = "ts_block_direct_udp"

# --- 配置区域结束 ---

def load_mapping_file():
    """加载持久化存储的 IP 映射文件"""
    if os.path.exists(MAPPING_FILE_PATH):
        try:
            with open(MAPPING_FILE_PATH, 'r') as f:
                data = json.load(f)
                # 验证数据结构
                if isinstance(data, dict):
                    return data
                else:
                    print(f"警告: {MAPPING_FILE_PATH} 格式不正确，返回空字典。", file=sys.stderr)
                    return {}
        except (json.JSONDecodeError, IOError) as e:
            print(f"警告: 读取 {MAPPING_FILE_PATH} 失败 ({e})，返回空字典。", file=sys.stderr)
            return {}
    return {}

def save_mapping_file(mapping_dict):
    """保存 IP 映射字典到持久化文件"""
    try:
        with open(MAPPING_FILE_PATH, 'w') as f:
            json.dump(mapping_dict, f, indent=4)
        print(f"IP 映射已保存到 {MAPPING_FILE_PATH}")
    except IOError as e:
        print(f"错误: 保存 {MAPPING_FILE_PATH} 失败 ({e})", file=sys.stderr)
        sys.exit(1)

def run_command(cmd, check=True, capture_output=True, input_text=None):
    """执行系统命令的辅助函数"""
    try:
        kwargs = {
            'check': check,
            'capture_output': capture_output,
            'text': True
        }
        if input_text is not None:
            kwargs['input'] = input_text
        
        result = subprocess.run(cmd, **kwargs)
        return result.stdout.strip() if capture_output else None
    except subprocess.CalledProcessError as e:
        print(f"错误: 执行命令失败: {' '.join(cmd)}", file=sys.stderr)
        if e.stderr:
            print(f"错误输出: {e.stderr.strip()}", file=sys.stderr)
        if check:
            sys.exit(e.returncode)
        return None

def ensure_nftables_setup():
    """确保 nftables 专用表、集合和链存在"""
    print("检查/设置 nftables 专用表规则...")

    # 创建专用表
    run_command(["nft", "create", "table", "ip", TABLE_NAME], check=False)
    run_command(["nft", "create", "table", "ip6", TABLE_NAME], check=False)

    # 创建 IPv4 集合和链
    run_command(["nft", "create", "set", "ip", TABLE_NAME, SET_WS_DENY_LIST_NAME, "{ type ipv4_addr; }"], check=False)
    run_command(["nft", "create", "set", "ip", TABLE_NAME, SET_STUNPORT_NAME, "{ type inet_service; }"], check=False)
    run_command(["nft", "add", "element", "ip", TABLE_NAME, SET_STUNPORT_NAME, f"{{ {STUN_PORT}, {DERP_PORT} }}"], check=False)
    run_command(["nft", "create", "chain", "ip", TABLE_NAME, CHAIN_HOOKED_NAME, "{ type filter hook prerouting priority -150 ; policy accept ; }"], check=False)
    # 创建 IPv6 集合和链
    run_command(["nft", "create", "set", "ip6", TABLE_NAME, SET_WS_DENY_LIST_NAME, "{ type ipv6_addr; }"], check=False)
    run_command(["nft", "create", "set", "ip6", TABLE_NAME, SET_STUNPORT_NAME, "{ type inet_service; }"], check=False)
    run_command(["nft", "add", "element", "ip6", TABLE_NAME, SET_STUNPORT_NAME, f"{{ {STUN_PORT}, {DERP_PORT} }}"], check=False)
    run_command(["nft", "create", "chain", "ip6", TABLE_NAME, CHAIN_HOOKED_NAME, "{ type filter hook prerouting priority -150 ; policy accept ; }"], check=False)

    print("nftables 专用表规则检查/设置完成。")

def extract_physical_ip_from_ping_output(output, target_vip):
    """
    从 tailscale ping 命令的输出中提取目标虚拟 IP 对应的物理 IP 地址。
    """
    # 尝试匹配 direct 连接的物理 IP
    # 示例匹配: pong from mate30pro (100.64.0.2) via 49.93.66.191:4358 in 286ms
    # 示例匹配: pong from device (fdxx::xxxx) via [2001:db8::1]:port in x.xxs
    pattern = rf'pong from .+\({re.escape(target_vip)}\) via (?:\[([0-9a-fA-F:]+)\]|(\d{{1,3}}\.\d{{1,3}}\.\d{{1,3}}\.\d{{1,3}})):\d+'
    match = re.search(pattern, output)
    if match:
        # group(1) 是 IPv6, group(2) 是 IPv4
        physical_ip = match.group(1) or match.group(2)
        try:
            # 验证 IP 格式
            ipaddress.ip_address(physical_ip)
            return physical_ip
        except ValueError:
            pass # 格式不正确，继续
    return None

def ping_and_get_physical_ips(target_virtual_ips, max_retries=MAX_PING_RETRIES, delay=PING_RETRY_DELAY):
    """
    对目标虚拟 IP 进行 ping，并尝试从中提取物理 IP 地址。
    使用 tailscale ping 的默认行为 (不带 -c -i) 以确保连接建立。
    返回一个从虚拟 IP 到物理 IP 的映射字典。
    """
    print(f"正在 ping 虚拟 IP 并等待物理 IP 信息 (使用默认 ping 行为): {target_virtual_ips}")
    found_map = {}

    for v_ip in target_virtual_ips:
        print(f"  开始 ping {v_ip}...")
        for attempt in range(max_retries):
            print(f"    尝试 {attempt + 1}/{max_retries}...")
            # 关键修改：不再使用 -c 和 -i 参数
            ping_cmd = ["tailscale", "ping", v_ip]
            output = run_command(ping_cmd, check=False) # ping 失败也继续

            if output:
                print(f"      Ping 输出:\n{output}") # 打印输出以便调试
                physical_ip = extract_physical_ip_from_ping_output(output, v_ip)
                if physical_ip:
                    print(f"    成功找到 {v_ip} 对应的物理 IP: {physical_ip}")
                    found_map[v_ip] = physical_ip
                    break # 找到了就跳出重试循环
            if attempt < max_retries - 1:
                print(f"    未找到物理 IP，等待 {delay} 秒后重试...")
                time.sleep(delay)
        if v_ip not in found_map:
            print(f"    错误: 即使经过 {max_retries} 次尝试，仍未找到虚拟 IP {v_ip} 的物理地址。", file=sys.stderr)

    return found_map


def get_current_nft_set_elements(table_name, set_name, family):
    """获取当前 nftables 集合中的所有元素"""
    cmd = ["nft", "get", "set", family, table_name, set_name]
    output = run_command(cmd, check=False)
    if not output:
        return set()
    
    elements = set()
    for line in output.splitlines():
        # 查找包含 elements 的行
        if 'elements' in line and '{' in line and '}' in line:
            content = line.split('{')[1].split('}')[0].strip()
            if content:
                # 分割元素，注意可能有逗号分隔
                raw_elements = [elem.strip() for elem in content.split(',')]
                for elem in raw_elements:
                    elem = elem.strip()
                    if elem:
                        elements.add(elem)
    return elements

def flush_nft_chain(family, table_name, chain_name):
    """刷新指定的 nftables 链"""
    run_command(["nft", "flush", "chain", family, table_name, chain_name], check=False)

def add_nft_rule(family, table_name, chain_name, rule_parts):
    """添加 nftables 规则，rule_parts 是一个包含规则各部分的列表"""
    cmd = ["nft", "add", "rule", family, table_name, chain_name] + rule_parts
    run_command(cmd, check=True) # 这次 check=True，因为添加规则失败是严重错误

def update_force_relay_rules(target_virtual_ips):
    """
    根据目标虚拟 IP 列表，更新 nftables 规则以强制中继。
    此版本会从持久化文件加载现有映射，并处理 IP 变化的情况。
    """
    print("\n--- 开始更新强制中继规则 ---")
    
    # 1. 加载当前的 IP 映射
    current_mapping = load_mapping_file()
    print(f"当前加载的 IP 映射: {current_mapping}")

    # 2. 通过 ping 获取新请求的目标 IP 的物理 IP 地址
    new_physical_ip_map = ping_and_get_physical_ips(target_virtual_ips)
    
    # 3. 提取需要更新的物理 IP 列表
    new_physical_ips_to_block = list(new_physical_ip_map.values())
    if not new_physical_ips_to_block:
        print("没有找到任何需要阻止的新物理 IP，退出更新。")
        print("--- 强制中继规则更新完成 (无操作) ---\n")
        return

    # 4. 更新映射字典
    # - 如果虚拟 IP 已存在于 current_mapping 中，且物理 IP 发生了变化，我们需要从 nft 集合中移除旧 IP
    # - 然后将新的映射关系写入 current_mapping
    ips_to_remove_from_nft = []
    for v_ip, new_p_ip in new_physical_ip_map.items():
        old_p_ip = current_mapping.get(v_ip)
        if old_p_ip and old_p_ip != new_p_ip:
            print(f"  虚拟 IP {v_ip} 的物理 IP 从 {old_p_ip} 变更为 {new_p_ip}，将移除旧的 IP。")
            ips_to_remove_from_nft.append(old_p_ip)
        # 更新或新增映射
        current_mapping[v_ip] = new_p_ip

    # 5. 获取当前 nft 集合内容
    current_set_v4 = get_current_nft_set_elements(TABLE_NAME, SET_WS_DENY_LIST_NAME, 'ip')
    current_set_v6 = get_current_nft_set_elements(TABLE_NAME, SET_WS_DENY_LIST_NAME, 'ip6')

    # 6. 计算需要从集合中删除的 IP (包括因变化而需要移除的和因取消强制而需要移除的)
    all_ips_to_remove = set(ips_to_remove_from_nft)

    # 计算需要添加到集合的 IP
    desired_set_all = set(current_mapping.values()) # 当前所有需要阻止的物理 IP
    to_add_v4 = {ip for ip in desired_set_all if ipaddress.ip_address(ip).version == 4} - current_set_v4
    to_add_v6 = {ip for ip in desired_set_all if ipaddress.ip_address(ip).version == 6} - current_set_v6

    # 计算需要从集合中删除的 IP
    to_del_v4 = all_ips_to_remove.intersection(current_set_v4)
    to_del_v6 = all_ips_to_remove.intersection(current_set_v6)

    # 7. 执行 nftables 操作
    # 删除旧的或不需要的 IP
    if to_del_v4:
        print(f"  将从 IPv4 阻止列表移除: {list(to_del_v4)}")
        for ip in to_del_v4:
            run_command(["nft", "delete", "element", "ip", TABLE_NAME, SET_WS_DENY_LIST_NAME, f"{{ {ip} }}"], check=False)
    if to_del_v6:
        print(f"  将从 IPv6 阻止列表移除: {list(to_del_v6)}")
        for ip in to_del_v6:
            run_command(["nft", "delete", "element", "ip6", TABLE_NAME, SET_WS_DENY_LIST_NAME, f"{{ {ip} }}"], check=False)

    # 添加新的 IP
    if to_add_v4:
        print(f"  将添加到 IPv4 阻止列表: {list(to_add_v4)}")
        for ip in to_add_v4:
            run_command(["nft", "add", "element", "ip", TABLE_NAME, SET_WS_DENY_LIST_NAME, f"{{ {ip} }}"])
    if to_add_v6:
        print(f"  将添加到 IPv6 阻止列表: {list(to_add_v6)}")
        for ip in to_add_v6:
            run_command(["nft", "add", "element", "ip6", TABLE_NAME, SET_WS_DENY_LIST_NAME, f"{{ {ip} }}"])

    # 8. 关键步骤：刷新链并添加新的阻止规则
    # 首先刷新 IPv4 链
    print("  正在更新 IPv4 阻止规则...")
    flush_nft_chain('ip', TABLE_NAME, CHAIN_HOOKED_NAME)
    if desired_set_all: # 只有当有 IP 需要阻止时才添加规则
        # 分离 IPv4 和 IPv6
        desired_set_v4_final = {ip for ip in desired_set_all if ipaddress.ip_address(ip).version == 4}
        desired_set_v6_final = {ip for ip in desired_set_all if ipaddress.ip_address(ip).version == 6}
        
        if desired_set_v4_final:
            # 添加入站规则 (来自黑名单 IP 的非 STUN/DERP 端口 UDP 包)
            add_nft_rule('ip', TABLE_NAME, CHAIN_HOOKED_NAME, ['udp', 'dport', '!=', f'@{SET_STUNPORT_NAME}', 'ip', 'saddr', f'@{SET_WS_DENY_LIST_NAME}', 'drop'])
            # 添加出站规则 (发往黑名单 IP 的非 STUN/DERP 端口 UDP 包)
            add_nft_rule('ip', TABLE_NAME, CHAIN_HOOKED_NAME, ['udp', 'sport', '!=', f'@{SET_STUNPORT_NAME}', 'ip', 'daddr', f'@{SET_WS_DENY_LIST_NAME}', 'drop'])
    
    # 刷新 IPv6 链
    print("  正在更新 IPv6 阻止规则...")
    flush_nft_chain('ip6', TABLE_NAME, CHAIN_HOOKED_NAME)
    if desired_set_v6_final: # 只有当有 IP 需要阻止时才添加规则
        add_nft_rule('ip6', TABLE_NAME, CHAIN_HOOKED_NAME, ['udp', 'dport', '!=', f'@{SET_STUNPORT_NAME}', 'ip6', 'saddr', f'@{SET_WS_DENY_LIST_NAME}', 'drop'])
        add_nft_rule('ip6', TABLE_NAME, CHAIN_HOOKED_NAME, ['udp', 'sport', '!=', f'@{SET_STUNPORT_NAME}', 'ip6', 'daddr', f'@{SET_WS_DENY_LIST_NAME}', 'drop'])

    # 9. 保存最终的映射
    save_mapping_file(current_mapping)

    print("--- 强制中继规则更新完成 ---\n")


def cancel_force_relay_for_vps(virtual_ips_to_cancel):
    """
    从 nftables 阻止列表中移除指定虚拟 IP 对应的物理 IP，以取消强制中继。
    此函数会从持久化文件中读取物理 IP，无需再次 ping。
    """
    print("\n--- 开始取消强制中继 ---")
    
    # 1. 加载当前的 IP 映射
    current_mapping = load_mapping_file()
    print(f"当前加载的 IP 映射: {current_mapping}")

    # 2. 从映射中查找要取消的物理 IP
    physical_ips_to_remove = []
    remaining_mapping = current_mapping.copy() # 创建副本，准备更新
    for v_ip in virtual_ips_to_cancel:
        p_ip = current_mapping.get(v_ip)
        if p_ip:
            print(f"  找到 {v_ip} 对应的物理 IP: {p_ip}")
            physical_ips_to_remove.append(p_ip)
            del remaining_mapping[v_ip] # 从剩余映射中移除
        else:
            print(f"  警告: 未在映射文件中找到虚拟 IP {v_ip}，跳过。", file=sys.stderr)

    if not physical_ips_to_remove:
        print("没有找到任何需要移除的物理 IP，退出取消操作。")
        print("--- 取消强制中继完成 (无操作) ---\n")
        return

    # 3. 确定需要从 nft 集合中移除的物理 IP
    set_v4_to_remove = [ip for ip in physical_ips_to_remove if ipaddress.ip_address(ip).version == 4]
    set_v6_to_remove = [ip for ip in physical_ips_to_remove if ipaddress.ip_address(ip).version == 6]

    # 4. 从 nft 集合中移除这些 IP
    if set_v4_to_remove:
        print(f"  从 IPv4 阻止列表移除: {set_v4_to_remove}")
        for ip in set_v4_to_remove:
             run_command(["nft", "delete", "element", "ip", TABLE_NAME, SET_WS_DENY_LIST_NAME, f"{{ {ip} }}"], check=False)
    if set_v6_to_remove:
        print(f"  从 IPv6 阻止列表移除: {set_v6_to_remove}")
        for ip in set_v6_to_remove:
             run_command(["nft", "delete", "element", "ip6", TABLE_NAME, SET_WS_DENY_LIST_NAME, f"{{ {ip} }}"], check=False)

    # 5. 关键步骤：刷新链（移除所有规则）
    print("  正在移除阻止规则...")
    flush_nft_chain('ip', TABLE_NAME, CHAIN_HOOKED_NAME)
    flush_nft_chain('ip6', TABLE_NAME, CHAIN_HOOKED_NAME)

    # 6. 保存更新后的映射 (移除了已取消的条目)
    save_mapping_file(remaining_mapping)

    print("--- 取消强制中继完成 ---\n")


def list_currently_forced():
    """列出当前被强制中继的虚拟 IP 及其对应的物理 IP"""
    print("\n--- 当前被强制中继的节点列表 ---")
    current_mapping = load_mapping_file()
    if not current_mapping:
        print("当前没有任何节点被强制中继。")
    else:
        print(json.dumps(current_mapping, indent=4))
    print("--- 列表结束 ---\n")


def main():
    ensure_nftables_setup()

    if len(sys.argv) > 1:
        command = sys.argv[1]
        if command == "force":
            if len(sys.argv) < 3:
                print("使用方法: python3 this_script.py force <virtual_ip1> <virtual_ip2> ...")
                sys.exit(1)
            virtual_ips_to_force = sys.argv[2:]
            print(f"收到强制指令，将强制以下虚拟 IP 走中继: {virtual_ips_to_force}")
            update_force_relay_rules(virtual_ips_to_force)
        elif command == "cancel":
            if len(sys.argv) < 3:
                print("使用方法: python3 this_script.py cancel <virtual_ip1> <virtual_ip2> ...")
                sys.exit(1)
            virtual_ips_to_cancel = sys.argv[2:]
            print(f"收到取消指令，将取消对以下虚拟 IP 的强制中转: {virtual_ips_to_cancel}")
            cancel_force_relay_for_vps(virtual_ips_to_cancel)
        elif command == "list":
            list_currently_forced()
        else:
            print(f"未知参数: {sys.argv[1]}. 使用 'force <virtual_ip> ...', 'cancel <virtual_ip> ...', 'list' 或不带参数运行。")
            sys.exit(1)
    else:
        # 默认行为：强制中继 VPS_TO_FORCE_RELAY 列表中的节点
        print(f"默认运行，将强制中转配置列表中的虚拟 IP: {VPS_TO_FORCE_RELAY}")
        if VPS_TO_FORCE_RELAY:
            update_force_relay_rules(VPS_TO_FORCE_RELAY)
        else:
            print("配置列表为空，无操作。")


if __name__ == "__main__":
    main()