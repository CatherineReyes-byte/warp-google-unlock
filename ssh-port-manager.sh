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
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 运行！${NC}"
        exit 1
    fi
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
        # 采用连续 echo 写入，彻底避免 Windows CRLF 换行符造成的 EOF 解析错误
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

# ── 开机静默恢复状态 (供 systemd 调用) ───────────────────────────
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
            fw=$(