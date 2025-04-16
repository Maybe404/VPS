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

# ... 其他原有函数保持不变，这里只展示新增和修改部分 ...

# 卸载所有配置
uninstall() {
    echo -e "\n${RED}警告：这将卸载所有配置，包括服务、规则和文件！${RESET}"
    read -p "确定要卸载吗？(y/N) " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo -e "${BLUE}卸载已取消${RESET}"
        return
    fi

    echo -e "${YELLOW}[+] 停止并禁用服务...${RESET}"
    systemctl stop ipset-persistent 2>/dev/null
    systemctl disable ipset-persistent 2>/dev/null
    rm -f "$SERVICE_FILE" 2>/dev/null

    echo -e "${YELLOW}[+] 删除配置文件...${RESET}"
    rm -f "$IPSET_CONF" "$RULES_CONF" 2>/dev/null

    echo -e "${YELLOW}[+] 清理iptables规则...${RESET}"
    iptables-save | grep -v "CHINA_BLOCK" | iptables-restore
    iptables-save > /etc/iptables/rules.v4 2>/dev/null

    echo -e "${YELLOW}[+] 销毁ipset集合...${RESET}"
    if ipset list china &>/dev/null; then
        ipset destroy china
    fi

    echo -e "${YELLOW}[+] 清理临时文件...${RESET}"
    rm -f /tmp/cn.zone 2>/dev/null

    echo -e "${GREEN}[√] 所有配置已卸载完成${RESET}"
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
    echo "8. 卸载所有配置"
    echo "9. 退出"
    echo "--------------------------------"
}

# 主函数
main() {
    check_root
    while true; do
        show_menu
        read -p "请输入选项 [1-9]: " choice
        
        case $choice in
            1)
                # ... 原有代码不变 ...
                ;;
            8)
                uninstall
                ;;
            9)
                echo -e "${GREEN}已退出脚本${RESET}"
                exit 0
                ;;
            # ... 其他case处理保持不变 ...
        esac
        echo
    done
}

# 执行主函数
main
