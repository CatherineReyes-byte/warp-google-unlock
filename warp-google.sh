#!/bin/bash

# WARP 一键脚本 - 使用 Cloudflare 官方客户端
# 让 Google 流量自动走 WARP，解锁受限服务

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║     🌐 WARP 一键脚本 - Google 自动解锁 🌐           ║"
    echo "║         使用 Cloudflare 官方客户端                  ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 检查 root
[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }

# 检测系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
    CODENAME=$VERSION_CODENAME
else
    echo -e "${RED}无法检测系统${NC}"; exit 1
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
echo -e "${GREEN}系统: $OS $VERSION ($CODENAME) $ARCH${NC}"

# 显示当前 IP
echo -e "\n${YELLOW}当前 IP 信息:${NC}"
CURRENT_IP=$(curl -4 -s --max-time 5 ip.sb)
IP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$CURRENT_IP?lang=zh-CN" 2>/dev/null)
echo -e "IP: ${GREEN}$CURRENT_IP${NC}"
echo -e "位置: ${GREEN}$(echo $IP_INFO | grep -oP '"country":"\K[^"]+') - $(echo $IP_INFO | grep -oP '"city":"\K[^"]+')${NC}"

# 安装 Cloudflare WARP 官方客户端
install_warp() {
    echo -e "\n${CYAN}[1/3] 安装 Cloudflare WARP 官方客户端...${NC}"
    
    case $OS in
        ubuntu|debian)
            # 先安装必要依赖
            apt-get update -y >/dev/null 2>&1
            apt-get install -y gnupg curl wget lsb-release >/dev/null 2>&1
            
            # 添加 Cloudflare GPG 密钥
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            
            # 添加仓库
            echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" > /etc/apt/sources.list.d/cloudflare-client.list
            
            # 安装
            apt-get update -y
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            # 添加仓库
            cat > /etc/yum.repos.d/cloudflare-warp.repo << 'EOF'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
            if command -v dnf &>/dev/null; then
                dnf install -y cloudflare-warp
            else
                yum install -y cloudflare-warp
            fi
            ;;
        *)
            echo -e "${RED}不支持的系统: $OS${NC}"
            echo -e "${YELLOW}支持的系统: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Fedora${NC}"
            exit 1
            ;;
    esac
    
    if ! command -v warp-cli &>/dev/null; then
        echo -e "${RED}WARP 安装失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ WARP 客户端已安装${NC}"
}

# 配置 WARP
configure_warp() {
    echo -e "\n${CYAN}[2/3] 配置 WARP...${NC}"
    
    # 注册设备
    echo -e "正在注册设备..."
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
    
    # 设置为代理模式 (不会接管全部流量，只通过 SOCKS5 代理)
    warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli mode proxy 2>/dev/null || true
    
    # 设置代理端口
    warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli proxy port 40000 2>/dev/null || true
    
    # 连接
    echo -e "正在连接 WARP..."
    warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null
    
    sleep 3
    
    # 显示状态
    STATUS=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null)
    echo -e "状态: ${GREEN}$STATUS${NC}"
    
    echo -e "${GREEN}✓ WARP 配置完成${NC}"
}

# 配置透明代理 (让 Google 流量自动走 WARP)
setup_transparent_proxy() {
    echo -e "\n${CYAN}[3/3] 配置透明代理规则...${NC}"
    
    # 禁用 IPv6 访问 Google（避免 IPv4/IPv6 不匹配导致被检测）
    echo -e "配置 IPv6 规则..."
    
    # 方法1: 添加 IPv6 黑洞路由到 Google IPv6 地址
    # Google IPv6 范围: 2607:f8b0::/32
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
    
    # 方法2: 设置系统优先使用 IPv4
    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi
    
    # 安装 redsocks (透明代理工具)
    case $OS in
        ubuntu|debian)
            apt-get install -y redsocks iptables >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y redsocks iptables >/dev/null 2>&1
            else
                yum install -y redsocks iptables >/dev/null 2>&1
            fi
            ;;
    esac
    
    # 创建 redsocks 配置
    cat > /etc/redsocks.conf << 'EOF'
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 40000;
    type = socks5;
}
EOF

    # 创建 iptables 规则脚本
    cat > /usr/local/bin/warp-google << 'SCRIPT'
#!/bin/bash

# Google IP 段
GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
104.132.0.0/14
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
31.192.112.0/22
31.192.116.0/22
66.254.110.0/24
104.18.0.0/15
185.83.208.0/22
# hub IP 段
66.254.114.0/24
# mata IP 段
31.13.24.0/21
31.13.64.0/18
45.64.40.0/22
66.220.144.0/20
69.63.176.0/20
69.171.224.0/19
74.119.76.0/22
103.4.96.0/22
129.134.0.0/16
157.240.0.0/16
163.70.128.0/17
163.77.128.0/17
163.114.128.0/17
173.252.64.0/18
179.60.192.0/22
185.89.216.0/22
204.15.20.0/22
# reddit IP 段
151.101.0.0/16
54.172.97.0/22
# xda IP 段
52.5.0.0/16
37.19.0.0/16
# hostloc IP 段
23.255.155.0/24
# nba IP 段
23.45.12.0/24
"

start() {
    echo "启动 Google 透明代理..."
    
    # 启动 redsocks
    pkill redsocks 2>/dev/null
    redsocks -c /etc/redsocks.conf
    
    # 创建新的 iptables 链
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE
    
    # 添加 Google IP 规则
    for ip in $GOOGLE_IPS; do
        iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    
    # 应用到 OUTPUT 链
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || iptables -t nat -A OUTPUT -j WARP_GOOGLE
    
    echo "Google 透明代理已启动"
}

stop() {
    echo "停止 Google 透明代理..."
    pkill redsocks 2>/dev/null
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    echo "Google 透明代理已停止"
}

status() {
    echo "=== WARP 状态 ==="
    warp-cli status 2>/dev/null || echo "WARP 未运行"
    echo ""
    echo "=== Redsocks 状态 ==="
    pgrep -x redsocks >/dev/null && echo "运行中" || echo "未运行"
    echo ""
    echo "=== iptables 规则 ==="
    iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | head -5 || echo "无规则"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    *) echo "用法: $0 {start|stop|restart|status}" ;;
esac
SCRIPT

    chmod +x /usr/local/bin/warp-google
    
    # 启动透明代理
    /usr/local/bin/warp-google start
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/warp-google.service << 'EOF'
[Unit]
Description=WARP Google Transparent Proxy
After=network.target warp-svc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-google 2>/dev/null
    
    echo -e "${GREEN}✓ 透明代理配置完成${NC}"
}

# 测试连接
test_connection() {
    echo -e "\n${CYAN}测试连接...${NC}"
    
    sleep 2
    
    # 测试 Google
    GOOGLE_TEST=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$GOOGLE_TEST" = "200" ]; then
        echo -e "${GREEN}✓ Google 连接成功！${NC}"
    else
        echo -e "${YELLOW}Google 测试返回: $GOOGLE_TEST${NC}"
    fi
    
    # 显示 WARP IP
    WARP_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 10 ip.sb 2>/dev/null)
    if [ -n "$WARP_IP" ]; then
        WARP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$WARP_IP?lang=zh-CN" 2>/dev/null)
        echo -e "\nWARP IP: ${GREEN}$WARP_IP${NC}"
        echo -e "WARP 位置: ${GREEN}$(echo $WARP_INFO | grep -oP '"country":"\K[^"]+') - $(echo $WARP_INFO | grep -oP '"city":"\K[^"]+')${NC}"
    fi
}

# 创建管理脚本
create_management() {
    cat > /usr/local/bin/warp << 'EOF'
#!/bin/bash
case "$1" in
    status)
        warp-cli status 2>/dev/null
        echo ""
        /usr/local/bin/warp-google status 2>/dev/null
        ;;
    start)
        warp-cli connect 2>/dev/null
        /usr/local/bin/warp-google start
        ;;
    stop)
        /usr/local/bin/warp-google stop
        warp-cli disconnect 2>/dev/null
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    test)
        echo "测试 Google 连接..."
        curl -s --max-time 10 -o /dev/null -w "状态码: %{http_code}\n" https://www.google.com
        ;;
    ip)
        echo "直连 IP:"
        curl -4 -s ip.sb
        echo ""
        echo "WARP IP:"
        curl -x socks5://127.0.0.1:40000 -s ip.sb
        echo ""
        ;;
    uninstall)
        echo "正在卸载..."
        /usr/local/bin/warp-google stop 2>/dev/null
        warp-cli disconnect 2>/dev/null
        systemctl disable warp-google 2>/dev/null
        rm -f /etc/systemd/system/warp-google.service
        rm -f /usr/local/bin/warp-google
        rm -f /usr/local/bin/warp
        rm -f /etc/redsocks.conf
        apt-get remove -y cloudflare-warp redsocks 2>/dev/null || yum remove -y cloudflare-warp redsocks 2>/dev/null
        echo "WARP 已卸载"
        ;;
    *)
        echo "WARP 管理工具"
        echo ""
        echo "用法: warp <命令>"
        echo ""
        echo "命令:"
        echo "  status    查看状态"
        echo "  start     启动 WARP"
        echo "  stop      停止 WARP"
        echo "  restart   重启 WARP"
        echo "  test      测试 Google"
        echo "  ip        查看 IP"
        echo "  uninstall 卸载 WARP"
        ;;
esac
EOF
    chmod +x /usr/local/bin/warp
}

# 安装主流程
do_install() {
    install_warp
    configure_warp
    setup_transparent_proxy
    create_management
    test_connection
    
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            🎉 安装完成！Google 已解锁 🎉            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${YELLOW}所有 Google 流量现已自动通过 WARP！${NC}"
    echo -e "${YELLOW}无需任何额外配置，直接访问即可。${NC}"
    echo -e "\n管理命令: ${CYAN}warp {status|start|stop|restart|test|ip|uninstall}${NC}\n"
}

# 卸载
do_uninstall() {
    echo -e "\n${YELLOW}正在卸载 WARP...${NC}"
    /usr/local/bin/warp-google stop 2>/dev/null
    warp-cli disconnect 2>/dev/null
    systemctl disable warp-google 2>/dev/null
    systemctl stop warp-svc 2>/dev/null
    rm -f /etc/systemd/system/warp-google.service
    rm -f /usr/local/bin/warp-google
    rm -f /usr/local/bin/warp
    rm -f /etc/redsocks.conf
    
    # 清理 Zero Trust 配置
    systemctl disable warp-zt-restore 2>/dev/null
    systemctl stop warp-zt-restore 2>/dev/null
    rm -f /etc/systemd/system/warp-zt-restore.service
    rm -f /usr/local/bin/warp-zt-restore
    rm -f "$ZT_CONFIG"
    
    # 清理 iptables 规则
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    
    # 删除 IPv6 黑洞路由
    ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null
    
    # 卸载软件包
    case $OS in
        ubuntu|debian)
            apt-get remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum remove -y cloudflare-warp redsocks 2>/dev/null || dnf remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac
    
    echo -e "${GREEN}✓ WARP 已完全卸载${NC}\n"
}

# 查看状态
do_status() {
    echo -e "\n${CYAN}══════════════ WARP 运行状态 ══════════════${NC}\n"
    
    # WARP 客户端状态
    echo -e "${YELLOW}【WARP 客户端】${NC}"
    if command -v warp-cli &>/dev/null; then
        warp-cli status 2>/dev/null || echo "未运行"
    else
        echo -e "${RED}未安装${NC}"
    fi
    
    echo ""
    
    # Redsocks 状态
    echo -e "${YELLOW}【透明代理】${NC}"
    if pgrep -x redsocks >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
    
    echo ""
    
    # iptables 规则
    echo -e "${YELLOW}【iptables 规则】${NC}"
    iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | head -3 || echo -e "${RED}无规则${NC}"
    
    echo -e "\n${CYAN}════════════════════════════════════════════${NC}\n"
}

# 查看 IP
do_show_ip() {
    echo -e "\n${CYAN}══════════════ IP 信息 ══════════════${NC}\n"
    
    echo -e "${YELLOW}【直连 IP】${NC}"
    DIRECT_IP=$(curl -4 -s --max-time 5 ip.sb)
    DIRECT_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$DIRECT_IP?lang=zh-CN" 2>/dev/null)
    echo -e "IP: ${GREEN}$DIRECT_IP${NC}"
    echo -e "位置: $(echo $DIRECT_INFO | grep -oP '"country":"\K[^"]+') - $(echo $DIRECT_INFO | grep -oP '"city":"\K[^"]+')\n"
    
    echo -e "${YELLOW}【WARP IP】${NC}"
    WARP_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 5 ip.sb 2>/dev/null)
    if [ -n "$WARP_IP" ]; then
        WARP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$WARP_IP?lang=zh-CN" 2>/dev/null)
        echo -e "IP: ${GREEN}$WARP_IP${NC}"
        echo -e "位置: $(echo $WARP_INFO | grep -oP '"country":"\K[^"]+') - $(echo $WARP_INFO | grep -oP '"city":"\K[^"]+')\n"
    else
        echo -e "${RED}无法获取 (WARP 可能未运行)${NC}\n"
    fi
    
    echo -e "${CYAN}══════════════════════════════════════${NC}\n"
}

# 测试 Google 连接
do_test_google() {
    echo -e "\n${CYAN}测试 Google 连接...${NC}"
    RESULT=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$RESULT" = "200" ]; then
        echo -e "${GREEN}✓ Google 连接成功！状态码: $RESULT${NC}\n"
    else
        echo -e "${RED}✗ Google 连接失败，状态码: $RESULT${NC}\n"
    fi
}

# 启动服务
do_start() {
    echo -e "\n${CYAN}启动 WARP 服务...${NC}"
    warp-cli connect 2>/dev/null
    /usr/local/bin/warp-google start 2>/dev/null
    echo -e "${GREEN}✓ WARP 已启动${NC}\n"
}

# 停止服务
do_stop() {
    echo -e "\n${CYAN}停止 WARP 服务...${NC}"
    /usr/local/bin/warp-google stop 2>/dev/null
    warp-cli disconnect 2>/dev/null
    echo -e "${GREEN}✓ WARP 已停止${NC}\n"
}

# Zero Trust 配置持久化文件
ZT_CONFIG="/etc/warp-zero-trust.conf"

# 切换到 Zero Trust 模式
do_setup_zero_trust() {
    echo -e "\n${CYAN}══════════════ 配置 Zero Trust 模式 ══════════════${NC}\n"
    
    # 检查 warp-cli 是否已安装
    if ! command -v warp-cli &>/dev/null; then
        echo -e "${RED}错误：WARP 未安装，请先选择选项 1 安装${NC}\n"
        return 1
    fi
    
    # 输入 Zero Trust 组织名称
    local org_name=""
    while [ -z "$org_name" ]; do
        read -p "请输入 Zero Trust 组织名称 (Team Name): " org_name
    done
    
    echo -e "\n${CYAN}正在注册到 Zero Trust 组织: ${org_name}${NC}"
    
    # 断开当前连接
    warp-cli disconnect 2>/dev/null
    sleep 1
    
    # 切换到 Zero Trust 模式并注册组织
    if warp-cli --accept-tos teams-enroll "$org_name" 2>/dev/null || \
       warp-cli --accept-tos registration new --team "$org_name" 2>/dev/null; then
        echo -e "${GREEN}✓ 已发送注册请求${NC}"
    else
        echo -e "${YELLOW}提示：正在等待验证码...${NC}"
    fi
    
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}请检查你的邮箱，获取 Zero Trust 验证码${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    # 输入验证码
    local token=""
    while [ -z "$token" ]; do
        read -p "请输入验证码 (Token): " token
    done
    
    echo -e "\n${CYAN}正在验证...${NC}"
    
    # 提交验证码
    if warp-cli --accept-tos registration token "$token" 2>/dev/null || \
       warp-cli --accept-tos teams-enroll-token "$token" 2>/dev/null; then
        echo -e "${GREEN}✓ 验证成功${NC}"
    else
        echo -e "${RED}✗ 验证失败，请检查验证码是否正确${NC}\n"
        return 1
    fi
    
    # 设置代理模式（保持与原脚本一致）
    warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli mode proxy 2>/dev/null
    warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli proxy port 40000 2>/dev/null
    
    # 连接
    echo -e "${CYAN}正在连接 Zero Trust...${NC}"
    warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null
    sleep 3
    
    # 保存配置，用于开机自动恢复
    save_zero_trust_config "$org_name"
    
    # 更新 systemd 服务支持 Zero Trust 自动恢复
    setup_zero_trust_service
    
    # 验证连接
    local status
    status=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null)
    echo -e "\n${CYAN}当前状态: ${GREEN}$status${NC}"
    
    # 测试连通性
    echo -e "\n${CYAN}测试连接...${NC}"
    local test_result
    test_result=$(curl -x socks5://127.0.0.1:40000 \
        -s --max-time 10 -o /dev/null \
        -w "%{http_code}" https://www.google.com 2>/dev/null)
    
    if [ "$test_result" = "200" ]; then
        echo -e "${GREEN}✓ Zero Trust 连接成功！${NC}"
    else
        echo -e "${YELLOW}连接测试返回: $test_result（可能需要等待几秒）${NC}"
    fi
    
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ✅ Zero Trust 模式配置完成！                 ║${NC}"
    echo -e "${GREEN}║        重启后将自动恢复 Zero Trust 连接             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}\n"
}

# 保存 Zero Trust 配置
save_zero_trust_config() {
    cat > "$ZT_CONFIG" << EOF
# WARP Zero Trust 配置
# 由 warp 脚本自动生成
ZT_ORG="$1"
ZT_MODE="proxy"
ZT_PORT="40000"
ZT_ENABLED="1"
EOF
    chmod 600 "$ZT_CONFIG"
    echo -e "${GREEN}✓ Zero Trust 配置已保存到 $ZT_CONFIG${NC}"
}

# 配置开机自动恢复 Zero Trust
setup_zero_trust_service() {
    # 创建自动恢复脚本
    cat > /usr/local/bin/warp-zt-restore << 'ZTSCRIPT'
#!/bin/bash

ZT_CONFIG="/etc/warp-zero-trust.conf"

# 加载配置
[ -f "$ZT_CONFIG" ] && source "$ZT_CONFIG"

# 如果不是 ZT 模式则退出
[ "$ZT_ENABLED" != "1" ] && exit 0

echo "$(date): 恢复 Zero Trust 连接模式..."

# 等待网络就绪
sleep 5

# 确保模式正确
warp-cli mode proxy 2>/dev/null
warp-cli proxy port "${ZT_PORT:-40000}" 2>/dev/null

# 连接
warp-cli connect 2>/dev/null

echo "$(date): Zero Trust 模式已恢复"
ZTSCRIPT

    chmod +x /usr/local/bin/warp-zt-restore
    
    # 创建开机恢复服务
    cat > /etc/systemd/system/warp-zt-restore.service << 'EOF'
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
EOF

    systemctl daemon-reload
    systemctl enable warp-zt-restore 2>/dev/null
    echo -e "${GREEN}✓ 开机自动恢复服务已启用${NC}"
}

# 显示菜单
show_menu() {
    echo -e "${YELLOW}请选择操作:${NC}\n"
    echo -e "  ${GREEN}1.${NC} 安装 WARP (解锁 Gemini和商店等)"
    echo -e "  ${GREEN}2.${NC} 卸载 WARP"
    echo -e "  ${GREEN}3.${NC} 查看状态"
    echo -e "  ${GREEN}4.${NC} 切换到 Zero Trust 模式"
    echo -e "  ${GREEN}0.${NC} 退出\n"
    
    read -p "请输入选项 [0-4]: " choice
    
    case $choice in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_status; do_show_ip; do_test_google ;;
        4) do_setup_zero_trust ;;
        0) echo -e "\n${GREEN}再见！${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}无效选项${NC}\n" ;;
    esac
}

# 主入口
main() {
    show_banner
    
    # 检查 root
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }
    
    # 检测系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        CODENAME=$VERSION_CODENAME
    else
        echo -e "${RED}无法检测系统${NC}"; exit 1
    fi
    
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    echo -e "${GREEN}系统: $OS $VERSION ($CODENAME) $ARCH${NC}\n"
    
    show_menu
}

main
