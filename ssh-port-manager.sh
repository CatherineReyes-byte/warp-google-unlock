cat > ssh-port-manager.sh << 'EOF_SCRIPT'
#!/bin/bash
# ssh-port-manager.sh
# 功能：管理 SSH 22 端口的开启/关闭。不停用SSH服务，通过记录状态和开机自启服务实现重启后自动拦截。

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_PATH="$(realpath "$0")"
STATE_FILE="/etc/ssh-port-manager.state"
SERVICE_FILE="/etc/systemd/system/ssh-port-manager.service"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 运行！${NC}"
        exit 1
    fi
}

detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        echo "ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        echo "firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

setup_autostart() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo "[Unit]" > "$SERVICE_FILE"
        echo "Description=SSH Port 22 Manager Auto Restore" >> "$SERVICE_FILE"
        echo "After=network-online.target firewalld.service iptables.service ufw.service" >> "$SERVICE_FILE"
        echo "Wants=network-online.target" >> "$SERVICE_FILE"
        echo "" >> "$SERVICE_FILE"
        echo "[Service]" >> "$SERVICE_FILE"
        echo "Type=oneshot" >> "$SERVICE_FILE"
        echo "ExecStart=/bin/bash $SCRIPT_PATH restore" >> "$SERVICE_FILE"
        echo "RemainAfterExit=yes" >> "$SERVICE_FILE"
        echo "" >> "$SERVICE_FILE"
        echo "[Install]" >> "$SERVICE_FILE"
        echo "WantedBy=multi-user.target" >> "$SERVICE_FILE"

        systemctl daemon-reload
        systemctl enable ssh-port-manager.service >/dev/null 2>&1
    fi
}

restore_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if [[ "$PORT_STATE" == "closed" ]]; then
            local fw
            fw=$(detect_firewall)
            case $fw in
                ufw)
                    ufw deny 22/tcp >/dev/null 2>&1
                    ;;
                firewalld)
                    firewall-cmd --permanent --remove-port=22/tcp >/dev/null 2>&1
                    firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1
                    firewall-cmd --reload >/dev/null 2>&1
                    ;;
                iptables)
                    iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
                    if ! iptables -C INPUT -p tcp --dport 22 -j DROP 2>/dev/null; then
                        iptables -I INPUT -p tcp --dport 22 -j DROP
                    fi
                    ;;
            esac
        elif [[ "$PORT_STATE" == "opened" ]]; then
            local fw
            fw=$(detect_firewall)
            case $fw in
                iptables)
                    iptables -D INPUT -p tcp --dport 22 -j DROP 2>/dev/null || true
                    ;;
            esac
        fi
    fi
    exit 0
}

show_status() {
    echo -e "\n${CYAN}══════════════ 当前状态 ══════════════${NC}"

    echo -e "${YELLOW}【脚本控制状态】${NC}"
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if [[ "$PORT_STATE" == "closed" ]]; then
            echo -e "  记录选项: ${RED}已选择关闭 (开机会自动拦截)${NC}"
        else
            echo -e "  记录选项: ${GREEN}已选择开启${NC}"
        fi
    else
        echo -e "  记录选项: 未记录"
    fi

    echo -e "${YELLOW}【SSH 服务】${NC}"
    if systemctl is-active sshd >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1; then
        echo -e "  ${GREEN}运行中${NC}"
    else
        echo -e "  ${RED}未运行${NC}"
    fi

    echo -e "${YELLOW}【22 端口监听状态】${NC}"
    if ss -tlnp 2>/dev/null | grep -q ":22 " || netstat -tlnp 2>/dev/null | grep -q ":22 "; then
        echo -e "  ${GREEN}22 端口正在监听${NC}"
    else
        echo -e "  ${RED}22 端口未监听${NC}"
    fi

    local fw
    fw=$(detect_firewall)
    echo -e "${YELLOW}【防火墙 ($fw)】${NC}"
    case $fw in
        ufw) ufw status | grep "22" | sed 's/^/  /' ;;
        firewalld)
            if firewall-cmd --list-ports 2>/dev/null | grep -q "22/tcp"; then
                echo -e "  ${GREEN}22/tcp 已放行${NC}"
            else
                echo -e "  ${RED}22/tcp 未放行${NC}"
            fi ;;
        iptables)
            if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:22"; then
                echo -e "  ${GREEN}22 端口有相关规则${NC}"
                iptables -L INPUT -n 2>/dev/null | grep "dpt:22" | sed 's/^/  /'
            else
                echo -e "  无针对 22 端口的规则（默认策略生效）"
            fi ;;
        none) echo -e "  未检测到防火墙" ;;
    esac
    echo -e "${CYAN}══════════════════════════════════════${NC}\n"
}

close_port() {
    echo -e "\n${YELLOW}正在通过防火墙关闭 22 端口...${NC}"
    echo -e "${RED}⚠ 警告：SSH 服务仍会保持运行，但防火墙将切断 22 端口流量！${NC}"

    read -rp "确认关闭 22 端口？(yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消${NC}"
        return
    fi

    echo "PORT_STATE=closed" > "$STATE_FILE"
    setup_autostart

    local fw
    fw=$(detect_firewall)

    case $fw in
        ufw)
            ufw deny 22/tcp >/dev/null 2>&1
            echo -e "${GREEN}✓ UFW：已拒绝 22/tcp${NC}" ;;
        firewalld)
            firewall-cmd --permanent --remove-port=22/tcp 2>/dev/null || true
            firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
            firewall-cmd --reload >/dev/null 2>&1
            echo -e "${GREEN}✓ firewalld：已移除 22/tcp 和 ssh 服务${NC}" ;;
        iptables)
            iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
            if ! iptables -C INPUT -p tcp --dport 22 -j DROP 2>/dev/null; then
                iptables -I INPUT -p tcp --dport 22 -j DROP
            fi
            echo -e "${GREEN}✓ iptables：已添加 DROP 规则${NC}" ;;
        none)
            echo -e "${RED}✗ 未检测到支持的防火墙工具，操作失败。${NC}"
            return ;;
    esac
    echo -e "\n${GREEN}✓ 22 端口已关闭（已记录状态，重启后脚本将自动执行拦截）${NC}\n"
}

open_port() {
    echo -e "\n${CYAN}正在通过防火墙开启 22 端口...${NC}"
    echo "PORT_STATE=opened" > "$STATE_FILE"
    setup_autostart

    local fw
    fw=$(detect_firewall)

    case $fw in
        ufw)
            ufw allow 22/tcp >/dev/null 2>&1
            echo -e "${GREEN}✓ UFW：已允许 22/tcp${NC}" ;;
        firewalld)
            firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1
            firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            echo -e "${GREEN}✓ firewalld：已放行 22/tcp${NC}" ;;
        iptables)
            iptables -D INPUT -p tcp --dport 22 -j DROP 2>/dev/null || true
            if ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -p tcp --dport 22 -j ACCEPT
            fi
            echo -e "${GREEN}✓ iptables：已添加 ACCEPT 规则${NC}" ;;
        none)
            echo -e "${RED}✗ 未检测到支持的防火墙工具，操作失败。${NC}"
            return ;;
    esac
    echo -e "\n${GREEN}✓ 22 端口已开启（已记录状态）${NC}\n"
}

uninstall() {
    echo -e "\n${YELLOW}正在卸载 ssh-port-manager 脚本...${NC}"
    read -rp "确认卸载？(yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消${NC}"
        return
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        systemctl stop ssh-port-manager.service >/dev/null 2>&1
        systemctl disable ssh-port-manager.service >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}✓ 已移除开机自启服务${NC}"
    fi

    rm -f "$STATE_FILE"
    echo -e "${GREEN}✓ 已移除状态记录文件${NC}"

    if [[ -f "$SCRIPT_PATH" ]]; then
        if rm -f "$SCRIPT_PATH"; then
            echo -e "${GREEN}✓ 脚本自身已删除: $SCRIPT_PATH${NC}"
        else
            echo -e "${RED}✗ 删除自身失败，请手动删除: $SCRIPT_PATH${NC}"
        fi
    fi
    echo -e "\n${GREEN}✓ 卸载完成。原防火墙规则未清空，如有需要请手动恢复 22 端口。${NC}\n"
    exit 0
}

show_menu() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════╗"
    echo "║       SSH 22 端口管理工具              ║"
    echo "║       SSH Port 22 Manager              ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"

    show_status

    echo -e "${YELLOW}请选择操作 / Please select an option:${NC}"
    echo -e "  ${RED}1.${NC} 关闭 SSH 22 端口   (记录状态，开机自阻断)"
    echo -e "  ${GREEN}2.${NC} 开启 SSH 22 端口   (记录状态，开机自放行)"
    echo -e "  ${YELLOW}3.${NC} 卸载此脚本         (清除自启和服务记录)"
    echo -e "  ${CYAN}0.${NC} 退出               / Exit"
    echo

    read -rp "请输入选项 / Enter option [0-3]: " choice

    case $choice in
        1) close_port ;;
        2) open_port ;;
        3) uninstall ;;
        0) echo -e "\n${GREEN}再见！/ Goodbye!${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}无效选项 / Invalid option${NC}\n" ;;
    esac
}

check_root

if [[ "$1" == "restore" ]]; then
    restore_state
fi

show_menu
EOF_SCRIPT

chmod +x ssh-port-manager.sh
bash ssh-port-manager.sh