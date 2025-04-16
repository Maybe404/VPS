#!/bin/bash

# 版本号
VERSION="1.2"
# 默认中国IP列表源
DEFAULT_CN_URL="http://www.ipdeny.com/ipblocks/data/countries/cn.zone"
# 配置保存路径
IPSET_CONF="/etc/ipset.conf"
# 持久化服务名
SERVICE_FILE="/etc/systemd/system/ipset-persistent.service"

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
    local ports="$1"
    echo -e "${YELLOW}[+] 正在配置iptables规则...${RESET}"
    
    # 清除旧规则
    iptables-save | grep -v "china" | iptables-restore
    
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        iptables -A INPUT -p tcp --dport "$port" -m set --match-set china src -j DROP
        echo -e "${BLUE}[→] 已屏蔽端口：${port}${RESET}"
    done
    
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

# 显示菜单
show_menu() {
    echo -e "\n${BLUE}中国IP屏蔽脚本 v$VERSION${RESET}"
    echo "--------------------------------"
    echo "1. 初始配置（首次使用）"
    echo "2. 更新中国IP列表"
    echo "3. 查看当前规则"
    echo "4. 查看IP集合统计"
    echo "5. 退出"
    echo "--------------------------------"
}

# 主函数
main() {
    check_root
    
    while true; do
        show_menu
        read -p "请输入选项 [1-5]: " choice
        
        case $choice in
            1)
                # 获取配置信息
                read -p "输入要屏蔽的端口/范围（多个用逗号分隔，如 3445,30000-40000）：" ports
                read -p "输入中国IP列表URL（留空使用默认）：" custom_url
                target_url=${custom_url:-$DEFAULT_CN_URL}
                
                # 执行流程
                install_dependencies
                create_ipset
                if download_ip_list "$target_url"; then
                    load_ipset
                    configure_iptables "$ports"
                    save_config
                fi
                ;;
            2)
                update_ip_list
                ;;
            3)
                echo -e "\n${YELLOW}当前iptables规则：${RESET}"
                iptables -L INPUT -n -v | grep --color=auto 'china\|DROP'
                ;;
            4)
                echo -e "\n${YELLOW}IP集合统计信息：${RESET}"
                ipset list china | head -n 7
                ;;
            5)
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
