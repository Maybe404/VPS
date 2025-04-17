#!/bin/bash

# 脚本名称
# SCRIPT_NAME="ipblock2.sh"
# 版本号
VERSION="1.4"
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
    
    # 更新软件包列表并显示进度
    echo -e "${BLUE}[→] 正在更新软件包列表...${RESET}"
    if apt update 2>&1 | tee /tmp/apt_update.log; then
        echo -e "${GREEN}[√] 软件包列表更新成功${RESET}"
    else
        echo -e "${RED}[×] 软件包列表更新失败${RESET}"
        echo -e "${YELLOW}错误详情：${RESET}"
        cat /tmp/apt_update.log
        return 1
    fi
    
    # 安装依赖包并显示进度
    local packages=("iptables" "ipset" "iptables-persistent")
    for pkg in "${packages[@]}"; do
        echo -e "${BLUE}[→] 正在安装 ${pkg}...${RESET}"
        if apt install -y "$pkg" 2>&1 | tee /tmp/apt_install.log; then
            echo -e "${GREEN}[√] ${pkg} 安装成功${RESET}"
        else
            echo -e "${RED}[×] ${pkg} 安装失败${RESET}"
            echo -e "${YELLOW}错误详情：${RESET}"
            cat /tmp/apt_install.log
            return 1
        fi
    done
    
    # 验证安装
    echo -e "${BLUE}[→] 验证依赖安装...${RESET}"
    for cmd in iptables ipset; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${GREEN}[√] ${cmd} 已正确安装${RESET}"
        else
            echo -e "${RED}[×] ${cmd} 未找到，安装可能失败${RESET}"
            return 1
        fi
    done
    
    echo -e "${GREEN}[√] 所有依赖安装完成${RESET}"
    return 0
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
    local retry=3
    echo -e "${YELLOW}[+] 正在从 $url 下载IP列表...${RESET}"
    
    for ((i=1; i<=retry; i++)); do
        if wget -qO /tmp/cn.zone "$url"; then
            echo -e "${GREEN}[√] IP列表下载成功${RESET}"
            return 0
        else
            echo -e "${YELLOW}[!] 尝试 $i/$retry 下载失败，正在重试...${RESET}"
            sleep 2
        fi
    done
    
    echo -e "${RED}[×] 下载失败，请检查URL有效性或网络连接${RESET}"
    return 1
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
    local ports="$1" protocol="$2"
    echo -e "${YELLOW}[+] 正在配置iptables规则...${RESET}"
    iptables-save | grep -v "china" | iptables-restore

    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [ "$protocol" == "all" ]; then
            iptables -A INPUT -p tcp --dport "$port" -m set --match-set china src -j DROP
            iptables -A INPUT -p udp --dport "$port" -m set --match-set china src -j DROP
        else
            iptables -A INPUT -p "$protocol" --dport "$port" -m set --match-set china src -j DROP
        fi
        echo -e "${BLUE}[→] 已屏蔽端口：${port} 协议：${protocol}${RESET}"
    done
}

# 保存配置
save_config() {
    echo -e "${YELLOW}[+] 正在保存配置...${RESET}"
    iptables-save > /etc/iptables/rules.v4
    ipset save china -f $IPSET_CONF
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

# 修改验证端口格式函数
validate_ports() {
    local ports="$1"
    # 允许单个端口或端口范围(使用:分隔)，支持逗号分隔
    if [[ ! "$ports" =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]]; then
        echo -e "${RED}错误：端口格式不正确！请使用单个端口(如80)或范围(如30000:40000)，多个端口用逗号分隔${RESET}" >&2
        return 1
    fi
    return 0
}

# 修改获取有效端口输入函数
get_valid_ports() {
    local prompt="$1"
    local ports
    while true; do
        read -r -p "$prompt" ports
        # 自动将用户输入的-替换为:
        ports=${ports//-/:}
        if [ -z "$ports" ]; then
            echo -e "${RED}错误：端口不能为空${RESET}" >&2
            continue
        fi
        if validate_ports "$ports"; then
            echo "$ports"
            return
        fi
    done
}

# 修改configure_iptables函数中的端口处理部分
configure_iptables() {
    local ports="$1" protocol="$2"
    echo -e "${YELLOW}[+] 正在配置iptables规则...${RESET}"
    iptables-save | grep -v "china" | iptables-restore

    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [ "$protocol" == "all" ]; then
            iptables -A INPUT -p tcp --dport "$port" -m set --match-set china src -j DROP
            iptables -A INPUT -p udp --dport "$port" -m set --match-set china src -j DROP
        else
            iptables -A INPUT -p "$protocol" --dport "$port" -m set --match-set china src -j DROP
        fi
        echo -e "${BLUE}[→] 已屏蔽端口：${port} 协议：${protocol}${RESET}"
    done
}

# 修改add_rule函数中的端口处理部分
add_rule() {
    # 检查china集合是否存在
    if ! ipset list china >/dev/null 2>&1; then
        echo -e "${RED}错误：china集合不存在，请先执行初始配置！${RESET}"
        return 1
    fi
    
    # 检查IP集合是否为空
    if [ $(ipset list china | grep -c "/") -eq 0 ]; then
        echo -e "${RED}错误：china集合为空，请先更新IP列表！${RESET}"
        return 1
    fi
    
    # 获取端口和协议输入
    local ports=$(get_valid_ports "输入要新增屏蔽的端口/范围（如 80,443 或 30000-40000）：")
    local protocol=$(get_valid_protocol "选择协议（tcp/udp/all，默认all）：")
    
    # 处理端口范围
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port_range in "${PORT_LIST[@]}"; do
        if [[ "$port_range" =~ ^[0-9]+:[0-9]+$ ]]; then
            # 处理端口范围(已经是:分隔)
            if [ "$protocol" == "all" ]; then
                iptables -A INPUT -p tcp --dport "$port_range" -m set --match-set china src -j DROP
                iptables -A INPUT -p udp --dport "$port_range" -m set --match-set china src -j DROP
            else
                iptables -A INPUT -p "$protocol" --dport "$port_range" -m set --match-set china src -j DROP
            fi
            echo -e "${BLUE}[→] 已新增屏蔽端口范围：${port_range} 协议：${protocol}${RESET}"
        else
            # 处理单个端口
            if [ "$protocol" == "all" ]; then
                iptables -A INPUT -p tcp --dport "$port_range" -m set --match-set china src -j DROP
                iptables -A INPUT -p udp --dport "$port_range" -m set --match-set china src -j DROP
            else
                iptables -A INPUT -p "$protocol" --dport "$port_range" -m set --match-set china src -j DROP
            fi
            echo -e "${BLUE}[→] 已新增屏蔽端口：${port_range} 协议：${protocol}${RESET}"
        fi
    done
    
    save_config
    echo -e "${GREEN}[√] 规则添加成功${RESET}"
}

# 需要确保get_valid_protocol函数存在，如果没有请添加：
get_valid_protocol() {
    local prompt="$1"
    local protocol
    while true; do
        read -r -p "$prompt" protocol
        protocol=${protocol:-all}
        if [[ "$protocol" =~ ^(tcp|udp|all)$ ]]; then
            echo "$protocol"
            return
        else
            echo -e "${RED}错误：协议必须是tcp、udp或all${RESET}" >&2
        fi
    done
}

# 显示菜单函数
show_menu() {
    echo -e "\n${BLUE}中国IP屏蔽脚本 v$VERSION${RESET}"
    echo "--------------------------------"
    echo "1. 初始配置（首次使用）"
    echo "2. 更新中国IP列表"
    echo "3. 查看当前规则"
    echo "4. 查看IP集合统计"
    echo "5. 新增防火墙规则"
    echo "6. 修改防火墙规则"
    echo "7. 删除防火墙规则"
    echo "8. 卸载脚本及其安装内容"
    echo "9. 退出"
    echo "--------------------------------"
}



# 修改防火墙规则（修复版）
modify_rule() {
    echo -e "${YELLOW}[+] 当前规则如下：${RESET}"
    iptables -L INPUT -n --line-numbers | grep china
    local rule_number new_ports protocol
    
    # 获取有效输入
    read -p "输入要修改的规则编号：" rule_number
    new_ports=$(get_valid_ports "输入新的端口/范围（如 3445 或 30000-40000）：")
    protocol=$(get_valid_protocol "选择协议（tcp/udp/all，默认all）：")
    
    # 删除旧规则
    iptables -D INPUT "$rule_number"
    
    # 添加新规则（直接调用add_rule的逻辑）
    IFS=',' read -ra PORT_LIST <<< "$new_ports"
    for port_range in "${PORT_LIST[@]}"; do
        port_range=${port_range//-/:}  # 统一替换为冒号分隔
        if [ "$protocol" == "all" ]; then
            iptables -A INPUT -p tcp --dport "$port_range" -m set --match-set china src -j DROP
            iptables -A INPUT -p udp --dport "$port_range" -m set --match-set china src -j DROP
        else
            iptables -A INPUT -p "$protocol" --dport "$port_range" -m set --match-set china src -j DROP
        fi
        echo -e "${BLUE}[→] 已更新规则：${port_range} 协议：${protocol}${RESET}"
    done
    
    save_config
    echo -e "${GREEN}[√] 规则修改成功${RESET}"
}

# 在show_menu函数后添加缺失的update_ip_list函数（如果不存在）
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

# 删除防火墙规则
delete_rule() {
    echo -e "${YELLOW}[+] 当前规则如下：${RESET}"
    iptables -L INPUT -n --line-numbers | grep china
    
    # 获取要删除的规则编号
    read -p "输入要删除的规则编号（输入0取消）：" rule_number
    if [[ "$rule_number" == "0" ]]; then
        echo -e "${YELLOW}[!] 已取消删除操作${RESET}"
        return
    fi
    
    # 验证输入是否为数字
    if ! [[ "$rule_number" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：请输入有效的规则编号${RESET}"
        return 1
    fi
    
    # 删除规则
    if iptables -D INPUT "$rule_number"; then
        echo -e "${GREEN}[√] 规则 ${rule_number} 删除成功${RESET}"
        save_config
    else
        echo -e "${RED}[×] 删除失败，请检查规则编号是否正确${RESET}"
    fi
}

# 卸载脚本及其安装内容（修复版）
uninstall_script() {
    echo -e "${YELLOW}[+] 正在卸载脚本安装内容...${RESET}"
    
    # 清除iptables规则
    echo -e "${BLUE}[→] 正在清除iptables规则...${RESET}"
    iptables-save | grep -v "china" | iptables-restore
    
    # 删除ipset集合
    echo -e "${BLUE}[→] 正在删除ipset集合...${RESET}"
    ipset destroy china >/dev/null 2>&1 || true
    
    # 停止并删除持久化服务
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${BLUE}[→] 正在删除持久化服务...${RESET}"
        systemctl stop ipset-persistent >/dev/null 2>&1
        systemctl disable ipset-persistent >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    
    # 删除配置文件
    echo -e "${BLUE}[→] 正在删除配置文件...${RESET}"
    rm -f "$IPSET_CONF" >/dev/null 2>&1
    
    # 卸载依赖包
    echo -e "${BLUE}[→] 正在卸载相关依赖...${RESET}"
    apt remove --purge -y iptables-persistent >/dev/null 2>&1
    
    echo -e "${GREEN}[√] 脚本卸载完成，建议手动执行以下命令："
    echo -e "1. 手动卸载ipset: ${YELLOW}apt remove ipset${RESET}"
    echo -e "2. 删除残留配置: ${YELLOW}rm -f /etc/iptables/rules.v4${RESET}"
}

# 主函数
main() {
    check_root
    while true; do
        show_menu
        read -p "请输入选项 [1-9]: " choice
        case $choice in
            1)
                ports=$(get_valid_ports "输入要屏蔽的端口/范围（如 80,443 或 30000-40000）：")
                protocol=$(get_valid_protocol "选择协议（tcp/udp/all，默认all）：")
                read -p "输入中国IP列表URL（留空使用默认）：" custom_url
                target_url=${custom_url:-$DEFAULT_CN_URL}
                if ! install_dependencies; then
                    echo -e "${RED}[×] 依赖安装失败，请检查错误信息${RESET}" >&2
                    continue
                fi
                create_ipset
                if download_ip_list "$target_url"; then
                    load_ipset
                    configure_iptables "$ports" "$protocol"
                    save_config
                else
                    echo -e "${RED}[×] IP列表下载失败，初始化未完成${RESET}" >&2
                fi
                ;;
            2) update_ip_list ;;
            3) iptables -L INPUT -n -v | grep --color=auto 'china\|DROP' ;;
            4) ipset list china | head -n 7 ;;
            5) add_rule ;;
            6) modify_rule ;;
            7) delete_rule ;;
            8) uninstall_script ;;
            9) echo -e "${GREEN}已退出脚本${RESET}"; exit 0 ;;
            *) echo -e "${RED}无效选项，请重新输入${RESET}" ;;
        esac
        echo
    done
}

# 执行主函数
main


