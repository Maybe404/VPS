#!/bin/bash

# 版本号
VERSION="2.1"
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
        read -p "输入要屏蔽的端口/范围（多个用逗号分隔，如 80,443 或 30000:40000）：" ports
        if [[ -z "$ports" ]]; then
            echo -e "${RED}错误：端口不能为空！${RESET}"
            continue
        fi

        # 处理端口范围，如 30000:40000
        valid=true
        IFS=',' read -ra port_array <<< "$ports"  # 拆分端口/范围

        for port in "${port_array[@]}"; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                # 端口号，如 80 或 443
                if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
                    valid=false
                    echo -e "${RED}错误：端口 $port 无效！有效端口范围是 1-65535！${RESET}"
                    break
                fi
            elif [[ "$port" =~ ^[0-9]+:[0-9]+$ ]]; then
                # 端口范围，如 30000:40000
                IFS=':' read -r start_port end_port <<< "$port"
                if [[ "$start_port" -lt 1 || "$end_port" -gt 65535 || "$start_port" -gt "$end_port" ]]; then
                    valid=false
                    echo -e "${RED}错误：端口范围 $port 无效！有效端口范围是 1-65535 且起始端口不能大于结束端口！${RESET}"
                    break
                fi
            else
                valid=false
                echo -e "${RED}错误：端口或端口范围格式无效！请输入有效的端口或范围（如 80 或 30000:40000）。${RESET}"
                break
            fi
        done

        if [ "$valid" = true ]; then
            break
        fi
    done

    # 确认协议输入
    read -p "输入协议（tcp,udp，多个用逗号，默认tcp,udp）：" protocols
    protocols=${protocols:-"tcp,udp"}

    IFS=',' read -ra proto_array <<< "$protocols"
    for proto in "${proto_array[@]}"; do
        [[ ! "$proto" =~ ^(tcp|udp)$ ]] && {
            echo -e "${RED}无效协议 '$proto'${RESET}"
            return
        }
    done

    # 添加规则到配置文件
    echo "$ports:$protocols" >> "$RULES_CONF"
    echo -e "${GREEN}[√] 规则已添加：端口/范围：$ports 协议：$protocols${RESET}"

    # 配置防火墙
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

# 卸载所有配置
uninstall() {
    echo -e "\n${RED}警告：这将卸载所有配置，包括服务、规则和文件！${RESET}"
    read -p "确定要卸载吗？(y/N) " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo -e "${BLUE}卸载已取消${RESET}"
        return
    fi

    ipset flush china
    ipset destroy china
    rm -f "$RULES_CONF" "$IPSET_CONF"
    systemctl disable ipset-persistent >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    iptables -F
    iptables -t nat -F
    echo -e "${GREEN}[√] 卸载完成${RESET}"
}

# 菜单
menu() {
    while true; do
        echo -e "\n${YELLOW}防火墙管理脚本 - 版本 $VERSION${RESET}"
        echo "1. 添加规则"
        echo "2. 删除规则"
        echo "3. 修改规则"
        echo "4. 显示规则"
        echo "5. 更新中国IP列表"
        echo "6. 保存配置"
        echo "7. 卸载配置"
        echo "8. 退出"
        read -p "请输入选项： " option
        case $option in
            1) add_rule ;;
            2) delete_rule ;;
            3) modify_rule ;;
            4) show_rules ;;
            5) update_ip_list ;;
            6) save_config ;;
            7) uninstall ;;
            8) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}" ;;
        esac
    done
}

# 主程序
check_root
install_dependencies
create_ipset
menu
