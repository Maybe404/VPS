#!/bin/bash

# 中国IP段屏蔽脚本（支持 ipset + iptables + 协议/端口管理）
# 作者: ChatGPT & 你
# 版本: 1.1

IP_LIST_URL="https://www.ipdeny.com/ipblocks/data/countries/cn.zone"
IPSET_NAME="china"
IPTABLES_PORT_RANGE="30000:40000"
VERSION="1.1"

# 颜色设置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
RESET='\033[0m'

# 创建 ipset 集合
create_ipset() {
    if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] ipset 集合 $IPSET_NAME 已存在${RESET}"
    else
        ipset create "$IPSET_NAME" hash:net
        echo -e "${GREEN}[√] 创建 ipset 集合 $IPSET_NAME 成功${RESET}"
    fi
}

# 下载并导入中国IP段
update_ipset() {
    echo -e "${BLUE}正在下载中国IP段...${RESET}"
    TMP_FILE=$(mktemp)
    if curl -s "$IP_LIST_URL" -o "$TMP_FILE"; then
        echo -e "${GREEN}[√] 下载成功，正在更新 IP 集合...${RESET}"
        ipset flush "$IPSET_NAME"
        while IFS= read -r ip; do
            ipset add "$IPSET_NAME" "$ip"
        done < "$TMP_FILE"
        echo -e "${GREEN}[√] 更新 IP 集合完成${RESET}"
    else
        echo -e "${RED}[×] 下载失败，请检查网络连接${RESET}"
    fi
    rm -f "$TMP_FILE"
}

# 添加防火墙规则
add_rule() {
    read -p "请输入端口（如 80 或 30000-40000）: " port
    read -p "请输入协议（tcp/udp/icmp，默认全部）: " proto
    proto=${proto,,}

    if [[ -z "$proto" ]]; then
        proto_flag=""
    else
        proto_flag="-p $proto"
    fi

    iptables -A INPUT $proto_flag -m set --match-set "$IPSET_NAME" src -m multiport --dports "$port" -j DROP
    echo -e "${GREEN}[√] 已添加规则：协议=${proto:-全部} 端口=$port${RESET}"
    save_config
}

# 删除指定规则
delete_rule() {
    echo -e "\n${YELLOW}当前iptables规则：${RESET}"
    iptables -L INPUT -n -v --line-numbers | grep "$IPSET_NAME"
    read -p "请输入要删除的规则编号: " rule_num
    iptables -D INPUT "$rule_num"
    echo -e "${GREEN}[√] 规则已删除${RESET}"
    save_config
}

# 修改规则（删除后重新添加）
modify_rule() {
    delete_rule
    echo -e "${YELLOW}请输入新的规则信息：${RESET}"
    add_rule
}

# 显示规则
show_rules() {
    echo -e "\n${YELLOW}当前iptables规则：${RESET}"
    iptables -L INPUT -n -v --line-numbers | grep --color=auto "$IPSET_NAME\|DROP"
}

# 显示 IP 集合统计
show_ipset_stats() {
    echo -e "\n${YELLOW}当前IP集合统计：${RESET}"
    ipset list "$IPSET_NAME"
}

# 保存配置
save_config() {
    echo -e "${BLUE}正在保存配置...${RESET}"
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    elif command -v service >/dev/null 2>&1; then
        service iptables save
    else
        echo -e "${RED}[×] 未找到保存iptables配置的命令，请手动保存${RESET}"
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
    echo "5. 添加新规则"
    echo "6. 删除规则"
    echo "7. 修改规则"
    echo "8. 退出"
    echo "--------------------------------"
}

# 主程序循环
while true; do
    show_menu
    read -p "请输入选项 [1-8]: " choice
    case $choice in
        1) create_ipset ;;
        2) update_ipset ;;
        3) show_rules ;;
        4) show_ipset_stats ;;
        5) add_rule ;;
        6) delete_rule ;;
        7) modify_rule ;;
        8)
            echo -e "${GREEN}已退出脚本${RESET}"
            exit 0
            ;;
        *) echo -e "${RED}无效选项，请重新输入${RESET}" ;;
    esac
done
