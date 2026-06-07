#!/bin/bash
# ssh-port-manager.sh
# 功能：管理 SSH 22 端口的开启/关闭

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_PATH="$(realpath "$0")"

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

# ── 查看当前状态 ─────────────────────────────────────────────────
show_status() {
    echo -e "\n${CYAN}══════════════ 当前状态 ══════════════${NC}"

    # SSH 服务状态
    echo -e "${YELLOW}【SSH 服务】${NC}"
    if systemctl is-active sshd >/dev/null 2>&1; then
        echo -e "  ${GREEN}运行中${NC}"
    elif systemctl is-active ssh >/dev/null 2>&1; then
        echo -e "  ${GREEN}运行中${NC}"
    else
        echo -e "  ${RED}未运行${NC}"
    fi

    # SSH 配置中的端口
    echo -e "${YELLOW}【SSH 配置端口】${NC}"
    local port
    port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    if [ -z "$port" ]; then
        echo -e "  默认端口: ${GREEN}22${NC}（配置文件未显式设置）"
    else
        echo -e "  配置端口: ${GREEN}$port${NC}"
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
    echo -e "\n${YELLOW}正在关闭 SSH 22 端口...${NC}"
    echo -e "${RED}⚠ 警告：关闭后当前 SSH 连接不会立即断开，但新连接将无法建立！${NC}"
    echo -e "${RED}⚠ 请确保有其他方式（VNC/控制台）访问服务器！${NC}\n"

    read -rp "确认关闭 22 端口？(yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { echo -e "${YELLOW}已取消${NC}"; return; }

    local fw
    fw=$(detect_firewall)

    case $fw in
        ufw)
            ufw deny 22/tcp
            echo -e "${GREEN}✓ UFW：已拒绝 22/tcp${NC}"
            echo -e "\n${GREEN}✓ SSH 22 端口已关闭${NC}"
            echo -e "${YELLOW}提示：已建立的 SSH 连接不受影响，断开后将无法重新连接${NC}\n"
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port=22/tcp 2>/dev/null || true
            firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
            firewall-cmd --reload
            echo -e "${GREEN}✓ firewalld：已移除 22/tcp 和 ssh 服务${NC}"
            echo -e "\n${GREEN}✓ SSH 22 端口已关闭${NC}"
            echo -e "${YELLOW}提示：已建立的 SSH 连接不受影响，断开后将无法重新连接${NC}\n"
            ;;
        iptables)
            # 先删除已有的 ACCEPT 规则，再加 DROP 规则
            iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p tcp --dport 22 -j DROP
            save_iptables
            echo -e "${GREEN}✓ iptables：已添加 DROP 规则${NC}"
            echo -e "\n${GREEN}✓ SSH 22 端口已关闭${NC}"
            echo -e "${YELLOW}提示：已建立的 SSH 连接不受影响，断开后将无法重新连接${NC}\n"
            ;;
        none)
            echo -e "${RED}✗ 未检测到支持的防火墙工具 (ufw/firewalld/iptables)，操作失败。${NC}"
            ;;
    esac
}

# ── 开启 SSH 22 端口 ─────────────────────────────────────────────
open_port() {
    echo -e "\n${CYAN}正在开启 SSH 22 端口...${NC}"

    local fw
    fw=$(detect_firewall)

    case $fw in
        ufw)
            ufw allow 22/tcp
            echo -e "${GREEN}✓ UFW：已允许 22/tcp${NC}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port=22/tcp
            firewall-cmd --permanent --add-service=ssh
            firewall-cmd --reload
            echo -e "${GREEN}✓ firewalld：已放行 22/tcp${NC}"
            ;;
        iptables)
            # 先移除 DROP 规则，再添加 ACCEPT 规则
            iptables -D INPUT -p tcp --dport 22 -j DROP 2>/dev/null || true
            # 检查 ACCEPT 规则是否已存在
            if ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -p tcp --dport 22 -j ACCEPT
            fi
            save_iptables
            echo -e "${GREEN}✓ iptables：已添加 ACCEPT 规则${NC}"
            ;;
        none)
            echo -e "${RED}✗ 未检测到支持的防火墙工具 (ufw/firewalld/iptables)，操作失败。${NC}"
            return
            ;;
    esac

    # 确保 SSH 服务在运行
    if systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null; then
        echo -e "${GREEN}✓ SSH 服务已确认运行${NC}"
    fi

    echo -e "\n${GREEN}✓ SSH 22 端口已开启${NC}\n"
}

# ── 保存 iptables 规则（持久化）────────────────────────────────
save_iptables() {
    if command -v iptables-save >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then
            # Debian/Ubuntu
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save 2>/dev/null
            elif command -v iptables-persistent >/dev/null 2>&1; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
            else
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                iptables-save > /etc/iptables.rules 2>/dev/null || true
            fi
        else
            # RHEL/CentOS
            service iptables save 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
        echo -e "${GREEN}✓ iptables 规则已持久化${NC}"
    fi
}

# ── 卸载脚本 ─────────────────────────────────────────────────────
uninstall() {
    echo -e "\n${YELLOW}正在卸载 ssh-port-manager 脚本...${NC}"

    read -rp "确认卸载？(yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { echo -e "${YELLOW}已取消${NC}"; return; }

    # 检查是否为本地文件执行 (避免管道运行时误删系统终端解释器)
    if [[ -f "$0" ]]; then
        if rm -f "$SCRIPT_PATH"; then
            echo -e "${GREEN}✓ 脚本已删除: $SCRIPT_PATH${NC}"
        else
            echo -e "${RED}✗ 删除失败，请手动删除: $SCRIPT_PATH${NC}"
        fi
    else
        echo -e "${YELLOW}检测到脚本非本地文件执行（如通过管道运行），无本地文件需删除。${NC}"
    fi

    echo -e "${CYAN}提示：防火墙规则未自动还原，如需恢复请手动执行：${NC}"
    echo -e "  UFW:       ufw allow 22/tcp"
    echo -e "  firewalld: firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload"
    echo -e "  iptables:  iptables -I INPUT -p tcp --dport 22 -j ACCEPT"
    echo -e "\n${GREEN}✓ 卸载完成${NC}\n"

    exit 0
}

# ── 主菜单 ───────────────────────────────────────────────────────
# Main menu: displays banner, current status, and prompts user for action
show_menu() {
    # 打印标题横幅 / Print title banner
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════╗"
    echo "║       SSH 22 端口管理工具              ║"
    echo "║       SSH Port 22 Manager              ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"

    # 显示当前 SSH 及防火墙状态 / Show current SSH service and firewall status
    show_status

    # 打印操作选项 / Print operation options
    echo -e "${YELLOW}请选择操作 / Please select an option:${NC}"
    echo -e "  ${RED}1.${NC} 关闭 SSH 22 端口   / Close SSH port 22"
    echo -e "  ${GREEN}2.${NC} 开启 SSH 22 端口   / Open  SSH port 22"
    echo -e "  ${YELLOW}3.${NC} 卸载此脚本         / Uninstall this script"
    echo -e "  ${CYAN}0.${NC} 退出               / Exit"
    echo

    # 读取用户输入 / Read user input
    read -rp "请输入选项 / Enter option [0-3]: " choice

    # 根据选项调用对应函数 / Dispatch to corresponding function based on choice
    case $choice in
        1) close_port ;;   # 关闭端口 / Close port
        2) open_port ;;    # 开启端口 / Open port
        3) uninstall ;;    # 卸载脚本 / Uninstall script
        0) echo -e "\n${GREEN}再见！/ Goodbye!${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}无效选项 / Invalid option${NC}\n" ;;
    esac
}

# ── 入口 ─────────────────────────────────────────────────────────
check_root
show_menu