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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：必须使用root权限运行本脚本！${RESET}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}[+] 正在安装必要依赖...${RESET}"
    apt update >/dev/null 2>&1
    apt install -y iptables ipset iptables-persistent >/dev/null 2>&1
    touch "$RULES_CONF"
    echo -e "${GREEN}[√] 依赖安装完成${RESET}"
}

create_ipset() {
    if ipset list china >/dev/null 2>&1; then
        echo -e "${BLUE}[i] 检测到已存在的china集合，将清空内容${RESET}"
        ipset flush china
    else
        ipset create china hash:net
    fi
}

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

load_ipset() {
    echo -e "${YELLOW}[+] 正在加载IP到china集合...${RESET}"
    while read -r ip; do
        ipset add china "$ip" 2>/dev/null
    done < <(grep -v "^#\|^$" /tmp/cn.zone)
    echo -e "${GREEN}[√] 已加载 $(ipset list china | grep -c "/") 个IP段${RESET}"
}

configure_iptables() {
    echo -e "${YELLOW}[+] 正在配置iptables规则...${RESET}"
    iptables-save | grep -v "CHINA_BLOCK" | iptables-restore

    if [ -f "$RULES_CONF" ]; then
        while IFS= read -r line; do
            IFS=':' read -r ports protocols <<< "$line"
            [ -z "$protocols" ] && protocols="tcp,udp"

            IFS=',' read -ra PORT_LIST <<< "$ports"
            IFS=',' read -ra PROTO_LIST <<< "$protocols"

            for proto in "${PROTO_LIST[@]}"; do
                for port in "${PORT_LIST[@]}"; do
                    iptables -A INPUT -p "$proto" --dport "$port" \
                        -m set --match-set china src -j DROP \
                        -m comment --comment "CHINA_BLOCK:$ports:$proto"
                    echo -e "${BLUE}[→] 屏蔽协议：${proto} 端口：${port}${RESET}"
                done
            done
        done < "$RULES_CONF"
    fi
    echo -e "${GREEN}[√] 防火墙规则配置完成${RESET}"
}

save_config() {
    echo -e "${YELLOW}[+] 正在保存配置...${RESET}"
    iptables-save > /etc/iptables/rules.v4
    ipset save china -f "$IPSET_CONF"

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
    echo -e "${GREEN}[√] 配置已持久化${RESET}"
}

update_ip_list() {
    local url
    read -p "输入新的IP列表URL（留空使用默认源）：" url
    url=${url:-$DEFAULT_CN_URL}
    
    if download_ip_list "$url"; then
        ipset flush china
        load_ipset
        ipset save china -f "$IPSET_CONF"
        echo -e "${GREEN}[√] IP列表更新完成${RESET}"
    fi
}

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

add_rule() {
    while true; do
        read -p "输入要屏蔽的端口/范围（多个用逗号分隔）：" ports
        [[ -z "$ports" || ! "$ports" =~ ^[0-9,-]+$ ]] && {
            echo -e "${RED}错误：端口格式无效${RESET}"
            continue
        }
        break
    done

    read -p "输入协议（tcp,udp，多个用逗号，默认tcp,udp）：" protocols
    protocols=${protocols:-"tcp,udp"}

    IFS=',' read -ra proto_array <<< "$protocols"
    for proto in "${proto_array[@]}"; do
        [[ ! "$proto" =~ ^(tcp|udp)$ ]] && {
            echo -e "${RED}无效协议 '$proto'${RESET}"
            return
        }
    done

    echo "$ports:$protocols" >> "$RULES_CONF"
    echo -e "${GREEN}[√] 规则已添加${RESET}"
    configure_iptables
}

delete_rule() {
    show_rules
    [ ! -s "$RULES_CONF" ] && return
    read -p "输入要删除的规则编号（0取消）：" choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -eq 0 ] && return
    if [ "$choice" -le "$(wc -l < "$RULES_CONF")" ]; then
        sed -i "${choice}d" "$RULES_CONF"
        echo -e "${GREEN}[√] 规则已删除${RESET}"
        configure_iptables
    else
        echo -e "${RED}无效编号${RESET}"
    fi
}

uninstall_all() {
    echo -e "${YELLOW}[!] 正在卸载所有配置...${RESET}"

    # 停止服务
    systemctl disable ipset-persistent >/dev/null 2>&1
    systemctl stop ipset-persistent >/dev/null 2>&1
    rm -f "$SERVICE_FILE"

    # 清空iptables CHINA_BLOCK 相关规则
    iptables-save | grep -v "CHINA_BLOCK" | iptables-restore

    # 删除 ipset 集合
    ipset destroy china >/dev/null 2>&1

    # 删除配置文件和下载文件
    rm -f "$IPSET_CONF" "$RULES_CONF" /tmp/cn.zone

    echo -e "${GREEN}[√] 所有服务与配置已卸载完成${RESET}"
}

main_menu() {
    echo -e "\n${BLUE}=== 中国IP段防火墙管理脚本 v$VERSION ===${RESET}"
    echo -e "${YELLOW}1. 安装/初始化"
    echo -e "2. 更新IP列表"
    echo -e "3. 新增规则"
    echo -e "4. 删除规则"
    echo -e "5. 查看规则"
    echo -e "6. 卸载所有配置"
    echo -e "0. 退出${RESET}"
    echo ""

    read -p "请选择操作：" choice
    case "$choice" in
        1)
            install_dependencies
            create_ipset
            download_ip_list "$DEFAULT_CN_URL" && load_ipset
            configure_iptables
            save_config
            ;;
        2) update_ip_list ;;
        3) add_rule ;;
        4) delete_rule ;;
        5) show_rules ;;
        6) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
}

# 执行入口
check_root
while true; do
    main_menu
done
