#!/bin/bash

# ipset 与 iptables 脚本：屏蔽中国大陆 IP 段访问特定端口
# 功能：新增、删除、修改 iptables 规则，协议选择，规则查看

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

# 默认 IP 列表地址，可自定义
DEFAULT_CN_URL="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"

VERSION="1.1"

install_dependencies() {
    echo -e "${BLUE}[*] 检查依赖项...${RESET}"
    for cmd in ipset iptables curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}[-] 需要安装 $cmd${RESET}"
            exit 1
        fi
    done
}

create_ipset() {
    echo -e "${BLUE}[*] 创建 IP 集合：china${RESET}"
    ipset list china >/dev/null 2>&1 || ipset create china hash:net maxelem 65536
}

download_ip_list() {
    local url=$1
    echo -e "${BLUE}[*] 下载中国 IP 列表...${RESET}"
    curl -s "$url" -o /tmp/china_ip_list.txt
    if [[ $? -ne 0 || ! -s /tmp/china_ip_list.txt ]]; then
        echo -e "${RED}[-] 下载失败或内容为空${RESET}"
        return 1
    fi
    echo -e "${GREEN}[+] 下载成功${RESET}"
    return 0
}

load_ipset() {
    echo -e "${BLUE}[*] 导入 IP 到 ipset${RESET}"
    ipset flush china
    while read -r ip; do
        [[ "$ip" =~ ^#.*$ || -z "$ip" ]] && continue
        ipset add china "$ip" 2>/dev/null
    done < /tmp/china_ip_list.txt
    echo -e "${GREEN}[+] 导入完成${RESET}"
}

configure_iptables() {
    local ports=$1
    IFS=',' read -ra port_ranges <<< "$ports"
    for port in "${port_ranges[@]}"; do
        for proto in tcp udp; do
            iptables -C INPUT -p $proto --dport $port -m set --match-set china src -j DROP 2>/dev/null || \
            iptables -A INPUT -p $proto --dport $port -m set --match-set china src -j DROP && \
            echo -e "${GREEN}[+] 添加 iptables 规则：$proto:$port${RESET}"
        done
    done
}

save_config() {
    ipset save > /etc/ipset-china.conf
    iptables-save > /etc/iptables-china.rules
    echo -e "${BLUE}[*] 已保存配置${RESET}"
}

update_ip_list() {
    download_ip_list "$DEFAULT_CN_URL" && load_ipset && echo -e "${GREEN}[+] 已更新 IP 集合${RESET}"
}

add_rule() {
    read -p "输入要屏蔽的端口（如 3445 或 30000:40000）：" port
    read -p "输入协议（tcp/udp/all，默认all）：" proto
    proto=${proto,,}
    [[ -z "$proto" || "$proto" == "all" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")

    for p in "${proto_list[@]}"; do
        iptables -C INPUT -p "$p" --dport "$port" -m set --match-set china src -j DROP 2>/dev/null || \
        iptables -A INPUT -p "$p" --dport "$port" -m set --match-set china src -j DROP && \
        echo -e "${GREEN}[+] 已添加 DROP 规则：$p:$port${RESET}"
    done
    save_config
}

delete_rule() {
    read -p "输入要删除的端口（如 3445 或 30000:40000）：" port
    read -p "输入协议（tcp/udp/all，默认all）：" proto
    proto=${proto,,}
    [[ -z "$proto" || "$proto" == "all" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")

    for p in "${proto_list[@]}"; do
        iptables -D INPUT -p "$p" --dport "$port" -m set --match-set china src -j DROP 2>/dev/null && \
        echo -e "${GREEN}[×] 已删除 DROP 规则：$p:$port${RESET}" || \
        echo -e "${YELLOW}[!] 未找到该规则：$p:$port${RESET}"
    done
    save_config
}

modify_rule() {
    echo -e "${YELLOW}请输入要修改的旧规则信息：${RESET}"
    delete_rule
    echo -e "${YELLOW}请输入新的规则信息：${RESET}"
    add_rule
}

list_rules() {
    echo -e "${YELLOW}当前iptables INPUT 链规则（含china）：${RESET}"
    iptables -S INPUT | grep 'china\|DROP'
}

show_menu() {
    echo -e "\n${BLUE}中国IP屏蔽脚本 v$VERSION${RESET}"
    echo "--------------------------------"
    echo "1. 初始配置（首次使用）"
    echo "2. 更新中国IP列表"
    echo "3. 添加新规则"
    echo "4. 删除规则"
    echo "5. 修改规则"
    echo "6. 查看iptables规则详情"
    echo "7. 查看IP集合统计"
    echo "8. 退出"
    echo "--------------------------------"
}

main() {
    while true; do
        show_menu
        read -p "请选择操作：" choice
        case $choice in
            1)
                read -p "输入要屏蔽的端口/范围（如 3445,30000-40000）：" ports
                read -p "输入中国IP列表URL（留空使用默认）：" custom_url
                target_url=${custom_url:-$DEFAULT_CN_URL}
                install_dependencies
                create_ipset
                if download_ip_list "$target_url"; then
                    load_ipset
                    configure_iptables "$ports"
                    save_config
                fi
                ;;
            2) update_ip_list ;;
            3) add_rule ;;
            4) delete_rule ;;
            5) modify_rule ;;
            6) list_rules ;;
            7)
                echo -e "\n${YELLOW}IP集合统计信息：${RESET}"
                ipset list china | head -n 7
                ;;
            8)
                echo -e "${GREEN}已退出脚本${RESET}"
                exit 0
                ;;
            *) echo -e "${RED}无效选项，请重新输入${RESET}" ;;
        esac
    done
}

main
