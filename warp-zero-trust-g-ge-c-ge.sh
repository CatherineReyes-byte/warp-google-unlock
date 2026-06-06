#!/bin/bash
# warp-zero-trust-fixed.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ZT_CONFIG="/etc/warp-zero-trust.conf"

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }
}

save_zero_trust_config() {
    cat > "$ZT_CONFIG" << EOF
ZT_ORG="$1"
ZT_MODE="proxy"
ZT_PORT="40000"
ZT_ENABLED="1"
EOF
    chmod 600 "$ZT_CONFIG"
    echo -e "${GREEN}✓ 配置已保存到 $ZT_CONFIG${NC}"
}

setup_zero_trust_service() {
    cat > /usr/local/bin/warp-zt-restore << 'ZTEOF'
#!/bin/bash
ZT_CONFIG="/etc/warp-zero-trust.conf"
[ -f "$ZT_CONFIG" ] && source "$ZT_CONFIG" || exit 0
[ "$ZT_ENABLED" != "1" ] && exit 0

sleep 5

# Zero Trust 模式下，代理模式需在 Cloudflare Dashboard 的 Profile 策略中设置为 "Local proxy mode"
warp-cli --accept-tos mode proxy 2>/dev/null || true
warp-cli --accept-tos proxy port "${ZT_PORT:-40000}" 2>/dev/null || true
warp-cli --accept-tos connect 2>/dev/null || true
ZTEOF

    chmod +x /usr/local/bin/warp-zt-restore

    cat > /etc/systemd/system/warp-zt-restore.service << 'SVCEOF'
[Unit]
Description=WARP Zero Trust Auto Restore
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-zt-restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable warp-zt-restore >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ 开机自动恢复服务已启用${NC}"
}

setup_zero_trust() {
    # ── 检查 warp-cli ────────────────────────────────────────────
    if ! command -v warp-cli >/dev/null 2>&1; then
        echo -e "${RED}未检测到 warp-cli，请先安装 Cloudflare WARP 客户端${NC}"
        exit 1
    fi

    # ── 输入组织名称 ─────────────────────────────────────────────
    read -rp "请输入 Zero Trust Team Name: " ORG_NAME
    [ -z "$ORG_NAME" ] && { echo -e "${RED}组织名称不能为空${NC}"; exit 1; }

    # ── 清理旧注册 ───────────────────────────────────────────────
    echo -e "${CYAN}开始清理旧配置...${NC}"
    warp-cli --accept-tos registration delete 2>/dev/null || true
    warp-cli --accept-tos disconnect 2>/dev/null || true
    sleep 1

    # ── 注册 Zero Trust (使用现代语法) ───────────────────────────
    echo -e "${CYAN}正在生成 Zero Trust 注册链接...${NC}"
    # 修正：直接将组织名作为参数传入，不使用 --team，也不使用废弃的 teams-enroll
    if ! warp-cli --accept-tos registration new "$ORG_NAME"; then
        echo -e "${RED}生成注册链接失败，请确认 warp-cli 状态正常${NC}"
        exit 1
    fi

    # ── 操作指南 ─────────────────────────────────────────────────
    echo
    echo -e "${YELLOW}================ 操作指南 =================${NC}"
    echo -e "1. 在浏览器中打开上方终端输出的验证链接。"
    echo -e "2. 输入邮箱并完成验证码验证。"
    echo -e "3. 页面显示 ${GREEN}Success${NC} 后，${RED}不要${NC}直接点击\"打开 Cloudflare WARP\"。"
    echo -e "4. 右键点击该按钮 → 选择\"复制链接地址\" (或从浏览器 F12 网络请求中提取)。"
    echo -e "   链接格式必须为：${CYAN}com.cloudflare.warp://.../auth?token=eyJ...${NC}"
    echo -e "${YELLOW}===========================================${NC}"

    # ── 输入 token URI ───────────────────────────────────────────
    read -rp "请输入完整的 Callback URI: " TOKEN_INPUT
    [ -z "$TOKEN_INPUT" ] && { echo -e "${RED}URI 不能为空${NC}"; exit 1; }

    if [[ "$TOKEN_INPUT" != com.cloudflare.warp://* ]]; then
        echo -e "${RED}格式错误！必须输入以 com.cloudflare.warp:// 开头的完整链接。${NC}"
        exit 1
    fi

    # ── 提交完整的 Token URI ─────────────────────────────────────
    echo -e "${CYAN}正在验证 token...${NC}"
    # 修正：直接提交完整的 URI，不要截取纯 JWT
    if ! warp-cli --accept-tos registration token "$TOKEN_INPUT"; then
        echo -e "${RED}✗ Token 验证失败，请检查链接是否完整且未过期。${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Token 验证成功${NC}"

    # ── 等待注册状态就绪 ─────────────────────────────────────────
    echo -e "${CYAN}等待注册状态确认...${NC}"
    local max_wait=15
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local reg_status
        reg_status=$(warp-cli --accept-tos registration show 2>/dev/null || echo "")
        if echo "$reg_status" | grep -qi "registered\|enrolled\|success"; then
            echo -e "${GREEN}✓ 注册状态已确认${NC}"
            break
        fi
        sleep 2
        waited=$((waited + 2))
        echo -e "  等待中... (${waited}s/${max_wait}s)"
    done

    # ── 设置代理模式及端口 ───────────────────────────────────────
    echo -e "${CYAN}配置代理模式...${NC}"
    warp-cli --accept-tos mode proxy 2>/dev/null || true
    warp-cli --accept-tos proxy port 40000 2>/dev/null || true

    # ── 连接 ─────────────────────────────────────────────────────
    echo -e "${CYAN}正在连接 Zero Trust...${NC}"
    if ! warp-cli --accept-tos connect; then
        echo -e "${RED}✗ 连接失败${NC}"
        exit 1
    fi

    sleep 3

    # ── 保存配置并注册开机自动恢复服务 ───────────────────────────
    save_zero_trust_config "$ORG_NAME"
    setup_zero_trust_service

    # ── 显示最终状态 ─────────────────────────────────────────────
    echo
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ✅ Zero Trust 配置完成！               ║${NC}"
    echo -e "${GREEN}║      重启后将自动恢复 Zero Trust 连接       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo
    warp-cli --accept-tos status
}

check_root
setup_zero_trust