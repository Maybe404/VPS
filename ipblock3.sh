#!/bin/bash

# 版本号
VERSION="2.0"
# 默认中国IP列表源
DEFAULT_CN_URL="http://www.ipdeny.com/ipblocks/data/countries/cn.zone"
# 配置保存路径
IPSET_CONF="/etc/ipset.conf"
# 持久化服务名
SERVICE_FILE="/etc/systemd/system/ipset-persistent.service"
# 规则配置文件
RULES_CONF="/etc/ipset-rules.conf"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：必须使用root权限运行本脚本！${RESET}"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}[+] 正在安装必要依赖...${RESET}"
    apt update >/dev/null 2>&1
    apt install -y iptables ipset iptables-persistent >/dev/null 2>&1
    touch "$RULES_CONF"
    echo -e "${GREEN}[√] 依赖安装完成${RESET}"
}

# 创建ipset集合
create_ipset() {
    if ipset list china >/dev/null 2>&1; then
        echo -e "${BLUE}[i] 检测到已存在的china集合，将清空内容${RESET}"
        ipset flush china
    else
        ipset create china hash:net
    fi
}

# 下载IP列表
download_ip_list() {
    local url="$1"
    echo -e "${YELLOW}[+] 正在从 $url 下载IP列表...${RESET}"
    
    if wget -qO /tmp/cn.zone "$url"; then
        echo -e "${GREEN}[√] IP列表下载成功${RESET}"
        return 0
    else
        echo -e "${RED}[×] 下载失败，请检查URL有效性${RESET}"
        return 1
    fi
}

# 加载IP到集合
load_ipset() {
    echo -e "${YELLOW}[+] 正在加载IP到china集合...${RESET}"
    while read -r ip; do
        ipset add china "$ip" 2>/dev/null
    done < <(grep -v "^#\|^$" /tmp/cn.zone)
    echo -e "${GREEN}[√] 已加载 $(ipset list china | grep -c "/") 个IP段${RESET}"
}

# 配置防火墙规则
configure_iptables() {
    echo -e "${YELLOW}[+] 正在配置iptables规则...${RESET}"
    
    # 清除旧规则
    iptables-save | grep -v "CHINA_BLOCK" | iptables-restore
    
    if [ -f "$RULES_CONF" ]; then
        while IFS= read -r line; do
            IFS=':' read -r ports protocols <<< "$line"
            if [ -z "$protocols" ]; then
                protocols="tcp,udp"
            fi
            
            IFS=',' read -ra PORT_LIST <<< "$ports"
            IFS=',' read -ra PROTO_LIST <<< "$protocols"
            
            for proto in "${PROTO_LIST[@]}"; do
                for port in "${PORT_LIST[@]}"; do
                    iptables -A INPUT -p "$proto" --dport "$port" \
                        -m set --match-set china src -j DROP \
                        -m comment --comment "CHINA_BLOCK:$ports:$proto"
                    echo -e "${BLUE}[→] 已屏蔽协议：${proto} 端口：${port}${RESET}"
                done
            done
        done < "$RULES_CONF"
    fi
    echo -e "${GREEN}[√] 防火墙规则配置完成${RESET}"
}

# 保存配置
save_config() {
    echo -e "${YELLOW}[+] 正在保存配置...${RESET}"
    
    # 保存iptables
    iptables-save > /etc/iptables/rules.v4
    
    # 保存ipset
    ipset save china -f $IPSET_CONF
    
    # 创建持久化服务
    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Load ipsets
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -f $IPSET_CONF

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable ipset-persistent >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}[√] 配置已持久化，重启后自动生效${RESET}"
}

# 更新IP列表
update_ip_list() {
    local url
    read -p "输入新的IP列表URL（留空使用默认源）：" url
    url=${url:-$DEFAULT_CN_URL}
    
    if download_ip_list "$url"; then
        ipset flush china
        load_ipset
        ipset save china -f $IPSET_CONF
        echo -e "${GREEN}[√] IP列表更新完成${RESET}"
    fi
}

# 显示规则列表
show_rules() {
    if [ ! -s "$RULES_CONF" ]; then
        echo -e "${YELLOW}当前没有配置任何规则${RESET}"
        return
    fi
    echo -e "\n${YELLOW}已配置规则列表：${RESET}"
    local count=1
    while IFS= read -r line; do
        IFS=':' read -r ports protocols <<< "$line"
        echo -e "${BLUE}$count. 端口：${ports} 协议：${protocols}${RESET}"
        ((count++))
    done < "$RULES_CONF"
}

# 新增规则
add_rule() {
    while true; do
        read -p "输入要屏蔽的端口/范围（多个用逗号分隔，如 80,443）：" ports
        if [[ -z "$ports" ]]; then
            echo -e "${RED}错误：端口不能为空！${RESET}"
            continue
        fi
        if ! [[ "$ports" =~ ^[0-9,-]+$ ]]; then
            echo -e "${RED}错误：端口格式无效！${RESET}"
            continue
        else
            break
        fi
    done

    read -p "输入协议（逗号分隔，如 tcp,udp，留空默认tcp和udp）：" protocols
    protocols=${protocols:-"tcp,udp"}
    
    IFS=',' read -ra proto_array <<< "$protocols"
    valid=true
    for proto in "${proto_array[@]}"; do
        if ! [[ "$proto" =~ ^(tcp|udp)$ ]]; then
            echo -e "${RED}错误：无效协议 '$proto'，支持的协议为 tcp, udp${RESET}"
            valid=false
            break
        fi
    done
    if ! $valid; then
        return 1
    fi

    echo "$ports:$protocols" >> "$RULES_CONF"
    echo -e "${GREEN}[√] 规则已添加${RESET}"
    configure_iptables
}

# 删除规则
delete_rule() {
    show_rules
    if [ ! -s "$RULES_CONF" ]; then
        return
    fi
    read -p "输入要删除的规则编号（0取消）：" choice
    if [[ "$choice" -eq 0 ]]; then
        return
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le $(wc -l < "$RULES_CONF") ]; then
        sed -i "${choice}d" "$RULES_CONF"
        echo -e "${GREEN}[√] 规则已删除${RESET}"
        configure_iptables
    else
        echo -e "${RED}无效的编号${RESET}"
    fi
}

# 修改规则
modify_rule() {
    show_rules
    if [ ! -s "$RULES_CONF" ]; then
        return
    fi
    read -p "输入要修改的规则编号（0取消）：" choice
    if [[ "$choice" -eq 0 ]]; then
        return
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le $(wc -l < "$RULES_CONF") ]; then
        old_rule=$(sed -n "${choice}p" "$RULES_CONF")
        IFS=':' read -r old_ports old_protos <<< "$old_rule"
        
        read -p "输入新端口（留空保持 $old_ports）：" ports
        ports=${ports:-$old_ports}
        
        read -p "输入新协议（留空保持 $old_protos）：" protocols
        protocols=${protocols:-$old_protos}
        
        # 验证协议
        IFS=',' read -ra proto_array <<< "$protocols"
        valid=true
        for proto in "${proto_array[@]}"; do
            if ! [[ "$proto" =~ ^(tcp|udp)$ ]]; then
                echo -e "${RED}错误：无效协议 '$proto'${RESET}"
                valid=false
                break
            fi
        done
        if ! $valid; then
            return
        fi
        
        sed -i "${choice}s/.*/$ports:$protocols/" "$RULES_CONF"
        echo -e "${GREEN}[√] 规则已修改${RESET}"
        configure_iptables
    else
        echo -e "${RED}无效的编号${RESET}"
    fi
}

# 显示菜单
show_menu() {
    echo -e "\n${BLUE}中国IP屏蔽脚本 v$VERSION${RESET}"
    echo "--------------------------------"
    echo "1. 初始配置（首次使用）"
    echo "2. 更新中国IP列表"
    echo "3. 新增屏蔽规则"
    echo "4. 修改屏蔽规则"
    echo "5. 删除屏蔽规则"
    echo "6. 查看当前规则"
    echo "7. 查看IP集合统计"
    echo "8. 退出"
    echo "--------------------------------"
}

# 主函数
main() {
    check_root
    while true; do
        show_menu
        read -p "请输入选项 [1-8]: " choice
        
        case $choice in
            1)
                read -p "输入要屏蔽的端口/范围（如 80,443）：" ports
                read -p "输入协议（如 tcp,udp，留空默认）：" protocols
                read -p "输入中国IP列表URL（留空默认）：" custom_url
                target_url=${custom_url:-$DEFAULT_CN_URL}
                
                install_dependencies
                create_ipset
                if download_ip_list "$target_url"; then
                    load_ipset
                    echo "$ports:${protocols:-tcp,udp}" > "$RULES_CONF"
                    configure_iptables
                    save_config
                fi
                ;;
            2)
                update_ip_list
                ;;
            3)
                add_rule
                ;;
            4)
                modify_rule
                ;;
            5)
                delete_rule
                ;;
            6)
                echo -e "\n${YELLOW}当前iptables规则：${RESET}"
                iptables -L INPUT -n -v | grep --color=auto 'CHINA_BLOCK\|DROP'
                show_rules
                ;;
            7)
                echo -e "\n${YELLOW}IP集合统计信息：${RESET}"
                ipset list china | head -n 7
                ;;
            8)
                echo -e "${GREEN}已退出脚本${RESET}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${RESET}"
                ;;
        esac
        echo
    done
}

# 执行主函数
main
