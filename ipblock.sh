#!/bin/bash

# 版本号
VERSION="2.0"
# 默认中国IP列表源
DEFAULT_CN_URL="http://www.ipdeny.com/ipblocks/data/countries/cn.zone"
# 配置保存路径
IPSET_CONF="/etc/ipset.conf"
SERVICE_FILE="/etc/systemd/system/ipset-persistent.service"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

# 检查root权限
check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}必须使用root权限运行本脚本！${RESET}"; exit 1; }
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}[+] 安装依赖...${RESET}"
    apt update >/dev/null 2>&1
    apt install -y iptables ipset iptables-persistent >/dev/null 2>&1
}

# 创建/清空ipset
create_ipset() {
    if ! ipset list china >/dev/null 2>&1; then
        ipset create china hash:net
    else
        ipset flush china
    fi
}

# 下载IP列表
download_ip_list() {
    local url="$1"
    echo -e "${YELLOW}[+] 下载IP列表: $url${RESET}"
    wget -qO /tmp/cn.zone "$url" || { echo -e "${RED}下载失败！${RESET}"; return 1; }
}

# 加载IP到集合
load_ipset() {
    while read -r ip; do
        ipset add china "$ip" 2>/dev/null
    done < <(grep -v "^#\|^$" /tmp/cn.zone)
}

# 保存配置
save_config() {
    iptables-save > /etc/iptables/rules.v4
    ipset save china -f $IPSET_CONF
    [ ! -f "$SERVICE_FILE" ] && {
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
    }
}

# 列出当前规则
list_rules() {
    echo -e "\n${YELLOW}当前生效规则：${RESET}"
    iptables -L INPUT -n --line-numbers | grep -E 'DROP|china' | awk '{printf "规则号: %s | 协议: %s | 端口: %s\n", $1, $4, $11}'
}

# 新增规则
add_rule() {
    read -p "输入要新增的端口/范围（例: 443,8000-9000）: " ports
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if iptables -C INPUT -p tcp --dport "$port" -m set --match-set china src -j DROP 2>/dev/null; then
            echo -e "${BLUE}[!] 端口 $port 规则已存在${RESET}"
        else
            iptables -A INPUT -p tcp --dport "$port" -m set --match-set china src -j DROP
            echo -e "${GREEN}[√] 已添加端口: $port${RESET}"
        fi
    done
    save_config
}

# 删除规则
delete_rule() {
    list_rules
    read -p "输入要删除的规则号: " rule_num
    if iptables -D INPUT "$rule_num" 2>/dev/null; then
        echo -e "${GREEN}[√] 规则 $rule_num 已删除${RESET}"
        save_config
    else
        echo -e "${RED}[×] 无效的规则号！${RESET}"
    fi
}

# 修改规则
modify_rule() {
    list_rules
    read -p "输入要修改的规则号: " rule_num
    read -p "输入新的端口/范围: " new_port
    
    # 获取旧规则详情
    old_rule=$(iptables -S INPUT "$rule_num" | awk '{for(i=3;i<=NF;i++) printf $i" "}')
    
    # 删除旧规则
    iptables -D INPUT "$rule_num" 2>/dev/null || {
        echo -e "${RED}无效的规则号！${RESET}"; return 1;
    }
    
    # 添加新规则
    iptables -I INPUT -p tcp --dport "$new_port" -m set --match-set china src -j DROP
    echo -e "${GREEN}[√] 规则已更新：${RESET}"
    echo -e "旧规则: ${RED}$old_rule${RESET}"
    echo -e "新规则: ${GREEN}$(iptables -S INPUT 1 | cut -d' ' -f3-)${RESET}"
    save_config
}

# 主菜单
main_menu() {
    echo -e "\n${BLUE}中国IP屏蔽管理 v$VERSION${RESET}"
    echo "--------------------------------"
    echo "1. 初始配置 (首次使用)"
    echo "2. 更新中国IP列表"
    echo "3. 新增屏蔽规则"
    echo "4. 删除现有规则"
    echo "5. 修改已有规则"
    echo "6. 查看当前规则"
    echo "7. 查看IP集合统计"
    echo "8. 退出"
    echo "--------------------------------"
}

# 主逻辑
main() {
    check_root
    while true; do
        main_menu
        read -p "请输入选项 [1-8]: " choice
        case $choice in
            1)
                read -p "输入要屏蔽的端口/范围（例: 3445,30000-40000）: " ports
                read -p "输入中国IP列表URL（回车默认）: " custom_url
                target_url="${custom_url:-$DEFAULT_CN_URL}"
                
                install_dependencies
                create_ipset
                if download_ip_list "$target_url"; then
                    load_ipset
                    IFS=',' read -ra PORT_LIST <<< "$ports"
                    for port in "${PORT_LIST[@]}"; do
                        iptables -A INPUT -p tcp --dport "$port" -m set --match-set china src -j DROP
                    done
                    save_config
                    echo -e "${GREEN}[√] 初始配置完成！${RESET}"
                fi
                ;;
            2)
                read -p "输入新URL（回车默认）: " url
                url="${url:-$DEFAULT_CN_URL}"
                if download_ip_list "$url"; then
                    ipset flush china
                    load_ipset
                    ipset save china -f $IPSET_CONF
                    echo -e "${GREEN}[√] IP列表已更新！${RESET}"
                fi
                ;;
            3) add_rule ;;
            4) delete_rule ;;
            5) modify_rule ;;
            6) list_rules ;;
            7) ipset list china | head -n 7 ;;
            8) exit 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" ;;
        esac
        echo
    done
}

main
