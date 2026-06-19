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

# ── 检查 root ────────────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }
}

# ── 检测防火墙类型 ───────────────────────────────────────────────
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

# ── 配置开机自启服务 ─────────────────────────────────────────────
setup_autostart() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=SSH Port 22 Manager Auto Restore
After=network-online.target firewalld.service iptables.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ssh-port-manager.service >/dev/null 2>&1
    fi
}

# ── 开机静默恢复状态 (供 systemd 调用) ───────────────────────────
restore_state() {
    # 检查记录的状态
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
            # 可选：如果记录是开启，确保放行（防止其他默认规则拦截）
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

# ── 查看当前状态 ─────────────────────────────────────────────────
show_status() {
    echo -e "\n${CYAN}══════════════ 当前状态 ══════════════${NC}"

    # 脚本开机自启状态
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

    # SSH 服务状态
    echo -e "${YELLOW}【SSH 服务】${NC}"
    if systemctl is-active sshd >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1; then
        echo -e "  ${GREEN}运行中${NC}"
    else
        echo -e "  ${RED}未运行${NC}"
    fi

    # 端口监听状态
    echo -e "${YELLOW}【22 端口监听状态】${NC}"
    if ss -tlnp 2>/dev/null | grep -q ":22 " || netstat -tlnp 2>/dev/null | grep -q ":22 "; then
        echo -e "  ${GREEN}22 端口正在监听${NC}"
    else
        echo -e "  ${RED}22 端口未监听${NC}"
    fi

    # 防火墙状态
    local fw
    fw=$(detect_firewall)
    echo -e "${YELLOW}【防火墙 ($fw)】${NC}"
    case $fw in
        ufw)
            ufw status | grep "22" | sed 's/^/  /'
            ;;
        firewalld)
            if firewall-cmd --list-ports 2>/dev/null | grep -q "22/tcp"; then
                echo -e "  ${GREEN}22/tcp 已放行${NC}"
            else
                echo -e "  ${RED}22/tcp 未放行${NC}"
            fi
            ;;
        iptables)
            if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:22"; then
                echo -e "  ${GREEN}22 端口有相关规则${NC}"
                iptables -L INPUT -n 2>/dev/null | grep "dpt:22" | sed 's/^/  /'
            else
                echo -e "  无针对 22 端口的规则（默认策略生效）"
            fi
            ;;
        none)
            echo -e "  未检测到防火墙"
            ;;
    esac

    echo -e "${CYAN}══════════════════════════════════════${NC}\n"
}

# ── 关闭 SSH 22 端口 ─────────────────────────────────────────────
close_port() {
    echo -e "\n${YELLOW}正在通过防火墙关闭 22 端口...${NC}"
    echo -