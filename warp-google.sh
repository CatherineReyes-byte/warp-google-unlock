#!/usr/bin/env bash
# =============================================================================
#  WARP 一键脚本 v2.0 —— Cloudflare 官方客户端 + 透明代理，让指定站点(Google 等)走 WARP
#
#  工作原理:
#    warp-cli(代理模式, 127.0.0.1:40000) <- redsocks(12345) <- iptables nat OUTPUT 重定向
#    只有目标为 Google 等指定 IP 的【TCP】流量会进入 WARP，其余流量、SSH 完全不受影响。
#
#  相对 v1 修复的致命问题:
#    1. 模式切换失败被静默忽略 -> WARP 以"全局模式"连接 -> 默认路由被改写 -> VPS 失联
#       现在: 必须确认已切到代理模式才会 connect; 连接后检测到 CloudflareWARP 网卡立即断开
#    2. 刚安装完 warp-svc 尚未就绪, 注册/设模式命令全部失败而不自知 -> 现在会等待守护进程
#    3. 规则含 104.18.0.0/15(Cloudflare 自身)、151.101.0.0/16(Fastly, apt/pypi 镜像)、
#       34.0.0.0/9 与 35.x(GCP 租户)、52.5.0.0/16(AWS) 等大网段 -> 误伤大量无关流量/形成回环
#       现在: Google 网段由官方 goog.json 减去 cloud.json 动态生成(失败则用内置精简列表)
#    4. WARP/redsocks 异常时规则仍在 -> 目标流量全断。现在带看门狗, 异常自动摘除规则(故障放行)
#    5. 仓库 codename 不被支持(如 Debian 13)、RPM 仓库地址错误 -> 已做探测与回退
#    6. 重启后规则/IPv6 屏蔽丢失 -> 已纳入 systemd 服务
#
#  用法:  bash warp-google.sh [install|uninstall|status|rescue]      (无参数进入菜单)
#  安装后: warp {status|start|stop|restart|test|ip|update|rescue|uninstall}
# =============================================================================

# 脚本即使 SSH 掉线也要继续跑完(避免安装到一半被 SIGHUP 杀掉)
trap '' HUP

CONF_DIR=/etc/warp-google
ENGINE=/usr/local/bin/warp-google
SHORTCUT=/usr/local/bin/warp
PROXY_PORT=40000
REDIR_PORT=12345

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
info() { echo -e "${CYAN}$*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }
err()  { echo -e "${RED}✗ $*${NC}"; }
die()  { err "$*"; exit 1; }

show_banner() {
    [ -t 1 ] && clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║        WARP 一键脚本 v2.0 - Google 自动解锁          ║"
    echo "║     Cloudflare 官方客户端 · 代理模式 · 故障放行       ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ----------------------------------------------------------------------------
# 环境检测
# ----------------------------------------------------------------------------
detect_env() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行！"
    [ -f /etc/os-release ] || die "无法检测系统"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS=${ID:-unknown}; OS_LIKE=${ID_LIKE:-}; OS_VER=${VERSION_ID:-}; CODENAME=${VERSION_CODENAME:-}

    case " $OS $OS_LIKE " in
        *" ubuntu "*|*" debian "*) PKG=apt ;;
        *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*)
            if command -v dnf >/dev/null 2>&1; then PKG=dnf; else PKG=yum; fi ;;
        *) die "不支持的系统: $OS (支持 Debian/Ubuntu/RHEL 系)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)  ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die "不支持的 CPU 架构: $(uname -m) (WARP 官方仅提供 amd64/arm64)" ;;
    esac

    [ -d /run/systemd/system ] || die "未检测到 systemd，无法安装(容器/精简环境不支持)"
    echo -e "${GREEN}系统: $OS $OS_VER ${CODENAME:+($CODENAME) }$ARCH${NC}"

    case "$(systemd-detect-virt 2>/dev/null)" in
        openvz|lxc|lxc-libvirt) warn "检测到 $(systemd-detect-virt) 容器虚拟化，可能缺少 iptables nat 模块，若失败请换 KVM 机型" ;;
    esac
}

pkg_install() {
    case $PKG in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        *)   $PKG install -y "$@" ;;
    esac
}

# ----------------------------------------------------------------------------
# 引擎脚本(安装为 /usr/local/bin/warp-google，同时也是 `warp` 命令)
# ----------------------------------------------------------------------------
write_engine() {
    mkdir -p "$CONF_DIR"
    cat > "$ENGINE" << 'ENGINE_EOF'
#!/usr/bin/env bash
# WARP-GOOGLE-ENGINE
# 由 warp-google.sh 生成。要改规则请编辑 /etc/warp-google/*.list 后执行: warp restart

CONF_DIR=/etc/warp-google
# shellcheck disable=SC1091
[ -f "$CONF_DIR/warp-google.conf" ] && . "$CONF_DIR/warp-google.conf"
PROXY_PORT=${PROXY_PORT:-40000}
REDIR_PORT=${REDIR_PORT:-12345}
BLOCK_IPV6=${BLOCK_IPV6:-1}
CHAIN=WARP_GOOGLE        # nat/OUTPUT : TCP 重定向到 redsocks
CHAIN_F=WARP_GOOGLE_F    # filter/OUTPUT : 拒绝 UDP 443(QUIC)，迫使其回落到 TCP
CHAIN_6=WARP_GOOGLE6     # ip6tables filter/OUTPUT : 拒绝直连 Google IPv6，迫使其回落到 IPv4
STATE_DIR=/run/warp-google
# 永不重定向的目的地: 内网/回环 + WARP 自身的 Cloudflare 端点(防止自我回环)
EXCLUDES="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 162.159.0.0/16"
WARP_DOMAINS="api.cloudflareclient.com engage.cloudflareclient.com connectivity.cloudflareclient.com zero-trust-client.cloudflareclient.com"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
say()  { echo -e "$*"; }
log()  { echo "$*"; logger -t warp-google "$*" 2>/dev/null; return 0; }

wcli() { warp-cli --accept-tos "$@"; }
is_connected() { wcli status 2>/dev/null | grep -Eq 'Status update:[[:space:]]*Connected'; }

# ---------------------------------------------------------------- WARP 客户端
wait_daemon() {                     # 等待 warp-svc 守护进程可连接
    local i out
    for i in $(seq 1 "${1:-30}"); do
        out=$(wcli status 2>&1)
        echo "$out" | grep -qi 'unable to connect' || return 0
        sleep 1
    done
    return 1
}

ensure_registered() {
    local i
    wcli registration show >/dev/null 2>&1 && return 0
    for i in 1 2 3; do
        wcli registration new >/dev/null 2>&1 || wcli register >/dev/null 2>&1
        wcli registration show >/dev/null 2>&1 && return 0
        sleep 3
    done
    return 1
}

# 切到代理模式(兼容新旧子命令)。返回 0 才表示确认成功。
ensure_proxy_mode() {
    wcli mode proxy >/dev/null 2>&1 || wcli set-mode proxy >/dev/null 2>&1 || return 1
    wcli proxy port "$PROXY_PORT" >/dev/null 2>&1 || wcli set-proxy-port "$PROXY_PORT" >/dev/null 2>&1 || return 1
    return 0
}

# 全局模式会创建 CloudflareWARP 网卡并改写路由 -> 立刻断开，保住 SSH
guard_no_fulltunnel() {
    if ip link show CloudflareWARP >/dev/null 2>&1; then
        wcli disconnect >/dev/null 2>&1
        return 1
    fi
    return 0
}

connect_wait() {
    local i
    wcli connect >/dev/null 2>&1
    for i in $(seq 1 40); do
        is_connected && return 0
        sleep 1
    done
    return 1
}

proxy_ok() {                        # 经 WARP SOCKS5 访问 Cloudflare trace，确认 warp=on
    curl -s -m 8 --socks5-hostname "127.0.0.1:${PROXY_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -Eq '^warp=(on|plus)'
}
wait_proxy() { local i; for i in $(seq 1 "${1:-20}"); do proxy_ok && return 0; sleep 2; done; return 1; }
redsocks_ok() { systemctl is-active --quiet warp-redsocks; }
google_ok()   { [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204)" = 204 ]; }

# 安装阶段调用: 安全地把 WARP 配置好并连接(绝不在代理模式未确认时 connect)
cmd_setup_warp() {
    systemctl enable --now warp-svc >/dev/null 2>&1
    wait_daemon 40 || { say "${RED}✗ warp-svc 未能启动 (查看: journalctl -u warp-svc -n 50)${NC}"; return 1; }
    wcli disconnect >/dev/null 2>&1                      # 若曾处于全局模式，先断开恢复默认路由
    ensure_registered || { say "${RED}✗ WARP 设备注册失败 (网络到 Cloudflare 不通或被限速，稍后重试)${NC}"; return 1; }
    ensure_proxy_mode || { say "${RED}✗ 无法切换到代理模式，已中止且不会连接 WARP (否则 VPS 会失联)${NC}"; return 1; }
    say "${GREEN}✓ 已确认代理模式 (SOCKS5 127.0.0.1:${PROXY_PORT})，开始连接...${NC}"
    connect_wait || { say "${RED}✗ WARP 连接超时 (UDP 443 可能被你的 VPS 商封锁)${NC}"; return 1; }
    guard_no_fulltunnel || { say "${RED}✗ 检测到全局隧道网卡，已紧急断开，安装中止${NC}"; return 1; }
    wait_proxy 15 || { say "${RED}✗ WARP 已连接但代理不通${NC}"; return 1; }
    return 0
}

# ---------------------------------------------------------------- 规则目标收集
collect_targets() {                 # 输出 IPv4/CIDR，域名即时解析
    local f line
    for f in "$CONF_DIR/google.list" "$CONF_DIR/extra.list"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"; line="${line//[[:space:]]/}"
            [ -z "$line" ] && continue
            if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                echo "$line"
            elif [[ "$line" =~ ^[A-Za-z0-9._-]+$ ]]; then
                getent ahostsv4 "$line" 2>/dev/null | awk '{print $1}'
            fi
        done < "$f"
    done | sort -u
}
collect_targets6() {
    [ -f "$CONF_DIR/google6.list" ] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$CONF_DIR/google6.list" | grep -E '^[0-9a-fA-F:]+(/[0-9]+)?$' | sort -u
}
warp_endpoints() {
    local d
    for d in $WARP_DOMAINS; do getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}'; done | sort -u
}

restore() { local bin=$1 file=$2; "$bin" -w --noflush < "$file" 2>/dev/null || "$bin" --noflush < "$file"; }
has_v6() { [ -r /proc/net/if_inet6 ] && command -v ip6tables-restore >/dev/null 2>&1 && ip6tables -w -L -n >/dev/null 2>&1; }
has_v4_default() { [ -n "$(ip -4 route show default 2>/dev/null)" ]; }

rules_present() { iptables -w -t nat -C OUTPUT -p tcp -j "$CHAIN" 2>/dev/null; }

# 原子写入/刷新规则(iptables-restore --noflush 会整体替换自定义链)
rules_on() {
    command -v iptables-restore >/dev/null 2>&1 || { say "${RED}缺少 iptables-restore${NC}"; return 1; }
    local f4 ff f6 targets eps n t t6
    f4=$(mktemp); ff=$(mktemp); f6=$(mktemp)
    targets=$(collect_targets)
    if [ -z "$targets" ]; then rm -f "$f4" "$ff" "$f6"; say "${RED}规则列表为空${NC}"; return 1; fi
    eps=$(warp_endpoints)

    { echo "*nat"; echo ":$CHAIN - [0:0]"
      for n in $EXCLUDES $eps; do echo "-A $CHAIN -d $n -j RETURN"; done
      for t in $targets; do echo "-A $CHAIN -p tcp -d $t -j REDIRECT --to-ports $REDIR_PORT"; done
      echo "COMMIT"; } > "$f4"

    { echo "*filter"; echo ":$CHAIN_F - [0:0]"
      for n in $EXCLUDES $eps; do echo "-A $CHAIN_F -d $n -j RETURN"; done
      for t in $targets; do echo "-A $CHAIN_F -p udp --dport 443 -d $t -j REJECT --reject-with icmp-port-unreachable"; done
      echo "COMMIT"; } > "$ff"

    if ! restore iptables-restore "$f4"; then
        rm -f "$f4" "$ff" "$f6"
        say "${RED}写入 nat 规则失败 (系统可能缺少 iptables nat 模块)${NC}"; return 1
    fi
    restore iptables-restore "$ff" || say "${YELLOW}! QUIC 拦截规则写入失败(不影响主功能)${NC}"
    iptables -w -t nat -C OUTPUT -p tcp -j "$CHAIN" 2>/dev/null || iptables -w -t nat -I OUTPUT 1 -p tcp -j "$CHAIN"
    iptables -w -C OUTPUT -p udp --dport 443 -j "$CHAIN_F" 2>/dev/null || iptables -w -I OUTPUT 1 -p udp --dport 443 -j "$CHAIN_F" 2>/dev/null

    # IPv6: 仅在本机同时具备 IPv4 出口时才屏蔽，避免纯 IPv6 机器直接断网
    if [ "$BLOCK_IPV6" = 1 ] && has_v6 && has_v4_default; then
        { echo "*filter"; echo ":$CHAIN_6 - [0:0]"
          for t6 in $(collect_targets6); do
              echo "-A $CHAIN_6 -d $t6 -p tcp -j REJECT --reject-with tcp-reset"
              echo "-A $CHAIN_6 -d $t6 -p udp -j REJECT --reject-with icmp6-port-unreachable"
          done
          echo "COMMIT"; } > "$f6"
        if restore ip6tables-restore "$f6"; then
            ip6tables -w -C OUTPUT -j "$CHAIN_6" 2>/dev/null || ip6tables -w -I OUTPUT 1 -j "$CHAIN_6"
        fi
    fi
    rm -f "$f4" "$ff" "$f6"
    mkdir -p "$STATE_DIR"; date +%s > "$STATE_DIR/refresh"
    return 0
}

drop_chain() {                      # drop_chain <iptables|ip6tables> <table> <chain> [hook args...]
    local bin=$1 table=$2 chain=$3; shift 3
    command -v "$bin" >/dev/null 2>&1 || return 0
    while "$bin" -w -t "$table" -D OUTPUT "$@" -j "$chain" 2>/dev/null; do :; done
    "$bin" -w -t "$table" -F "$chain" 2>/dev/null
    "$bin" -w -t "$table" -X "$chain" 2>/dev/null
    return 0
}
rules_off() {
    drop_chain iptables  nat    "$CHAIN"   -p tcp
    drop_chain iptables  nat    "$CHAIN"            # v1 遗留的无 -p tcp 挂钩
    drop_chain iptables  filter "$CHAIN_F" -p udp --dport 443
    drop_chain ip6tables filter "$CHAIN_6"
    rm -f "$STATE_DIR/refresh"
    return 0
}

# 启用规则 + 端到端验证; 验证失败自动回滚(故障放行)
apply_rules() {
    rules_on || return 1
    if google_ok || { sleep 3; google_ok; }; then return 0; fi
    rules_off
    log "透明代理端到端验证失败，已回滚规则(Google 将直连)"
    return 1
}

# ---------------------------------------------------------------- 子命令
cmd_boot() {                        # systemd 开机/启动入口: 永远 exit 0，不阻塞开机
    systemctl start warp-svc >/dev/null 2>&1
    if wait_daemon 60; then
        if ensure_proxy_mode; then
            is_connected || wcli connect >/dev/null 2>&1
        else
            log "无法确认代理模式，拒绝连接 WARP(保护 SSH)"
        fi
    fi
    systemctl start warp-redsocks >/dev/null 2>&1
    systemctl start warp-google-watchdog.timer >/dev/null 2>&1
    if wait_proxy 30 && redsocks_ok; then
        apply_rules && say "${GREEN}✓ 透明代理规则已启用${NC}" || say "${YELLOW}! 规则未启用，看门狗会自动重试${NC}"
    else
        say "${YELLOW}! WARP 暂不可用，规则未启用，看门狗会自动重试${NC}"
    fi
    return 0
}

cmd_check() {                       # 看门狗: 每分钟由 timer 调用
    mkdir -p "$STATE_DIR"
    local n last now
    if proxy_ok && redsocks_ok; then
        rm -f "$STATE_DIR/fail"
        if ! rules_present; then
            apply_rules && log "WARP 恢复，透明代理规则已重新启用"
        else
            last=$(cat "$STATE_DIR/refresh" 2>/dev/null || echo 0); now=$(date +%s)
            [ $((now - last)) -ge 1800 ] && rules_on      # 域名 IP 定期刷新
        fi
    else
        n=$(( $(cat "$STATE_DIR/fail" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE_DIR/fail"
        redsocks_ok || systemctl restart warp-redsocks >/dev/null 2>&1
        if ! is_connected; then
            ensure_proxy_mode && wcli connect >/dev/null 2>&1
        fi
        if [ "$n" -ge 2 ] && rules_present; then
            rules_off
            log "WARP/redsocks 不可用，已摘除透明代理规则，流量恢复直连"
        fi
    fi
    return 0
}

cmd_start()   { systemctl restart warp-google; }
cmd_stop()    {
    systemctl stop warp-google-watchdog.timer >/dev/null 2>&1
    systemctl stop warp-google >/dev/null 2>&1
    rules_off
    systemctl stop warp-redsocks >/dev/null 2>&1
    wcli disconnect >/dev/null 2>&1
    say "${GREEN}✓ 已停止并移除规则${NC}"
}
cmd_restart() { cmd_stop; sleep 2; cmd_start; }

geo() {
    local j; j=$(curl -s -m 5 "http://ip-api.com/json/$1?lang=zh-CN" 2>/dev/null)
    echo "$(echo "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p') - $(echo "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')"
}
get_ip() {                          # get_ip [curl 额外参数...]
    local u ip
    for u in https://api.ip.sb/ip https://ifconfig.me/ip https://api.ipify.org; do
        ip=$(curl -4 -s -m 6 "$@" "$u" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

cmd_ip() {
    local d w
    say "${YELLOW}直连 IP:${NC}"
    d=$(get_ip) && say "  $d  ($(geo "$d"))" || say "  ${RED}获取失败${NC}"
    say "${YELLOW}WARP IP:${NC}"
    w=$(get_ip --socks5-hostname "127.0.0.1:${PROXY_PORT}") && say "  $w  ($(geo "$w"))" || say "  ${RED}获取失败 (WARP 未运行?)${NC}"
}

cmd_test() {
    local code hits
    say "${CYAN}── 连通性测试 ──${NC}"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204)
    [ "$code" = 204 ] && say "${GREEN}✓ Google (generate_204): $code${NC}" || say "${RED}✗ Google (generate_204): ${code:-无响应}${NC}"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://gemini.google.com/)
    say "  Gemini 页面状态码: ${code:-无响应} (200/301/302 为正常)"
    proxy_ok && say "${GREEN}✓ WARP 代理: warp=on${NC}" || say "${RED}✗ WARP 代理不可用${NC}"
    if rules_present; then
        hits=$(iptables -w -t nat -L "$CHAIN" -nv 2>/dev/null | awk '/REDIRECT/ && $1+0>0 {c++} END{print c+0}')
        say "  nat 规则: 已启用, 已命中规则数: $hits"
    else
        say "${YELLOW}  nat 规则: 未启用 (Google 目前直连)${NC}"
    fi
}

cmd_status() {
    say "${CYAN}══════════ WARP 状态 ══════════${NC}"
    say "${YELLOW}【WARP 客户端】${NC}"
    command -v warp-cli >/dev/null 2>&1 || { say "${RED}未安装${NC}"; return 1; }
    wcli status 2>&1 | head -3
    wcli settings 2>/dev/null | grep -i 'mode' | head -2
    say "${YELLOW}【服务】${NC}"
    local s
    for s in warp-svc warp-redsocks warp-google warp-google-watchdog.timer; do
        printf '  %-28s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
    done
    say "${YELLOW}【WARP 代理】${NC}"
    proxy_ok && say "  ${GREEN}正常 (warp=on)${NC}" || say "  ${RED}不可用${NC}"
    say "${YELLOW}【透明代理规则】${NC}"
    if rules_present; then
        say "  ${GREEN}已启用${NC}: $(iptables -w -t nat -S "$CHAIN" 2>/dev/null | grep -c REDIRECT) 条重定向规则"
    else
        say "  ${YELLOW}未启用${NC}"
    fi
}

# 动态更新 Google 网段 = goog.json - cloud.json (即: Google 自有服务网段，排除 GCP 租户)
cmd_update() {
    command -v python3 >/dev/null 2>&1 || { say "${YELLOW}! 需要 python3，保留现有 google.list${NC}"; return 1; }
    local tmp; tmp=$(mktemp -d)
    if ! curl -fsSL -m 30 https://www.gstatic.com/ipranges/goog.json  -o "$tmp/goog.json"  ||
       ! curl -fsSL -m 30 https://www.gstatic.com/ipranges/cloud.json -o "$tmp/cloud.json"; then
        rm -rf "$tmp"; say "${YELLOW}! 下载官方网段失败，保留现有 google.list${NC}"; return 1
    fi
    python3 - "$tmp" "$CONF_DIR" << 'PY'
import ipaddress, json, os, sys, time
tmp, conf = sys.argv[1], sys.argv[2]
def load(n):
    with open(os.path.join(tmp, n)) as f: return json.load(f)["prefixes"]
goog, cloud = load("goog.json"), load("cloud.json")
def nets(ps, key): return [ipaddress.ip_network(p[key]) for p in ps if key in p]
def subtract(base, remove):
    out = []
    for n in base:
        parts = [n]
        for r in remove:
            nxt = []
            for p in parts:
                if p.version != r.version or not p.overlaps(r): nxt.append(p)
                elif r.supernet_of(p): continue
                else: nxt.extend(p.address_exclude(r))
            parts = nxt
            if not parts: break
        out.extend(parts)
    return sorted(ipaddress.collapse_addresses(out), key=lambda x: (int(x.network_address), x.prefixlen))
g4 = subtract(nets(goog, "ipv4Prefix"), nets(cloud, "ipv4Prefix"))
g6 = subtract(nets(goog, "ipv6Prefix"), nets(cloud, "ipv6Prefix"))
if len(g4) < 5 or len(g6) < 1:
    sys.exit("结果异常(%d/%d)，放弃更新" % (len(g4), len(g6)))
hdr = "# 自动生成 %s: Google 官方 goog.json 减去 cloud.json (不含 GCP 租户网段)\n" % time.strftime("%Y-%m-%d")
for name, data in (("google.list", g4), ("google6.list", g6)):
    with open(os.path.join(conf, name + ".new"), "w") as f:
        f.write(hdr + "\n".join(str(x) for x in data) + "\n")
    os.replace(os.path.join(conf, name + ".new"), os.path.join(conf, name))
print("IPv4 %d 段 / IPv6 %d 段" % (len(g4), len(g6)))
PY
    local rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then say "${YELLOW}! 更新失败，保留现有列表${NC}"; return 1; fi
    say "${GREEN}✓ Google 网段已更新${NC}"
    if rules_present; then rules_on; fi
    return 0
}

# 清理 v1 遗留物(旧版会导致失联/回环的配置)
cleanup_legacy() {
    systemctl stop warp-google-watchdog.timer warp-redsocks >/dev/null 2>&1
    rules_off
    while iptables -w -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null; do :; done
    ip -6 route del blackhole 2607:f8b0::/32 >/dev/null 2>&1
    [ -f /etc/gai.conf ] && sed -i '/^precedence ::ffff:0:0\/96  100$/d' /etc/gai.conf
    systemctl disable --now redsocks >/dev/null 2>&1   # 发行版自带的 redsocks 服务会抢占 12345 端口
    pkill -x redsocks >/dev/null 2>&1
    return 0
}

# 紧急恢复: 摘除所有规则并断开 WARP，恢复 VPS 原始网络
cmd_rescue() {
    systemctl stop warp-google-watchdog.timer >/dev/null 2>&1
    rules_off
    cleanup_legacy
    systemctl stop warp-redsocks >/dev/null 2>&1
    if command -v warp-cli >/dev/null 2>&1; then
        wcli disconnect >/dev/null 2>&1
        wcli mode proxy >/dev/null 2>&1 || wcli set-mode proxy >/dev/null 2>&1   # 保证下次连接不是全局模式
    fi
    if ip link show CloudflareWARP >/dev/null 2>&1; then
        systemctl stop warp-svc >/dev/null 2>&1                                  # 断开不掉网卡则停服务
    fi
    say "${GREEN}✓ 已恢复: 规则已移除，WARP 已断开${NC}"
}

cmd_uninstall() {
    say "${YELLOW}正在卸载...${NC}"
    cmd_rescue >/dev/null 2>&1
    command -v warp-cli >/dev/null 2>&1 && wcli registration delete >/dev/null 2>&1
    systemctl disable --now warp-google.service warp-google-watchdog.timer warp-redsocks.service >/dev/null 2>&1
    systemctl disable --now warp-svc >/dev/null 2>&1
    rm -f /etc/systemd/system/warp-google.service /etc/systemd/system/warp-redsocks.service \
          /etc/systemd/system/warp-google-watchdog.service /etc/systemd/system/warp-google-watchdog.timer
    systemctl daemon-reload >/dev/null 2>&1
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y --purge cloudflare-warp >/dev/null 2>&1
        [ "$REDSOCKS_SRC" = pkg ] && apt-get remove -y --purge redsocks >/dev/null 2>&1
        rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    else
        local pm=yum; command -v dnf >/dev/null 2>&1 && pm=dnf
        $pm remove -y cloudflare-warp >/dev/null 2>&1
        [ "$REDSOCKS_SRC" = pkg ] && $pm remove -y redsocks >/dev/null 2>&1
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    fi
    [ "$REDSOCKS_SRC" = source ] && rm -f /usr/local/sbin/redsocks
    rm -rf "$CONF_DIR" "$STATE_DIR" /etc/redsocks.conf.warp-bak
    [ "$(readlink -f /usr/local/bin/warp 2>/dev/null)" = "$(readlink -f "$0")" ] && rm -f /usr/local/bin/warp
    say "${GREEN}✓ WARP 已完全卸载${NC}"
    rm -f /usr/local/bin/warp-google
    exit 0
}

usage() {
    cat << EOF
WARP 管理工具

用法: warp <命令>

  status     查看状态
  start      启动 (连接 WARP 并启用规则)
  stop       停止 (移除规则并断开 WARP)
  restart    重启 (修改 /etc/warp-google/*.list 后执行)
  test       测试 Google / WARP 连通性
  ip         对比直连 IP 与 WARP IP
  update     更新 Google 官方网段
  rescue     紧急恢复: 移除全部规则并断开 WARP
  uninstall  完全卸载

规则文件: $CONF_DIR/google.list  google6.list  extra.list
EOF
}

case "${1:-}" in
    boot)          cmd_boot ;;
    check)         cmd_check ;;
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_restart ;;
    status)        cmd_status ;;
    test)          cmd_test ;;
    ip)            cmd_ip ;;
    update)        cmd_update ;;
    rescue)        cmd_rescue ;;
    uninstall)     cmd_uninstall ;;
    rules-on)      rules_on ;;
    rules-off)     rules_off ;;
    setup-warp)    cmd_setup_warp ;;
    cleanup-legacy) cleanup_legacy ;;
    *)             usage ;;
esac
ENGINE_EOF
    chmod 755 "$ENGINE"
}

# ----------------------------------------------------------------------------
# 配置文件 / 规则列表
# ----------------------------------------------------------------------------
write_config() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/warp-google.conf" << EOF
PROXY_PORT=$PROXY_PORT
REDIR_PORT=$REDIR_PORT
BLOCK_IPV6=1
REDSOCKS_BIN=$REDSOCKS_BIN
REDSOCKS_SRC=$REDSOCKS_SRC
EOF

    cat > "$CONF_DIR/redsocks.conf" << EOF
base {
    log_debug = off;
    log_info = off;
    log = "stderr";
    daemon = off;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = $REDIR_PORT;
    ip = 127.0.0.1;
    port = $PROXY_PORT;
    type = socks5;
}
EOF
    chmod 644 "$CONF_DIR"/*.conf

    # 内置 Google 服务网段(精简、不含 GCP 租户)。安装时会尝试用官方数据覆盖。
    cat > "$CONF_DIR/google.list" << 'EOF'
# Google 服务 IPv4 网段（每行一个，# 为注释）。执行 `warp update` 可用官方数据刷新。
8.8.4.0/24
8.8.8.0/24
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
192.178.0.0/15
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
EOF
    cat > "$CONF_DIR/google6.list" << 'EOF'
# Google IPv6 网段: 这些地址会被拒绝直连，让应用回落到 IPv4(走 WARP)，避免 v4/v6 出口不一致
2001:4860::/32
2404:6800::/32
2607:f8b0::/32
2800:3f0::/32
2a00:1450::/32
2c0f:fb50::/32
EOF
    [ -f "$CONF_DIR/extra.list" ] || cat > "$CONF_DIR/extra.list" << 'EOF'
# 其它需要走 WARP 的站点: 每行一个 域名 或 IPv4/CIDR。域名会在启动时解析并每 30 分钟刷新。
# 不需要的整行删掉或在行首加 # ；修改后执行 `warp restart` 生效。
#
# 注意: 不要加入 Cloudflare(104.16.0.0/13 等)、Fastly(151.101.0.0/16) 这类 CDN 大网段，
#       否则会连带劫持无数无关站点以及 apt/pip 镜像源。

# --- PornHub 系 ---
pornhub.com
www.pornhub.com
31.192.112.0/22
31.192.116.0/22
66.254.110.0/24
66.254.114.0/24
185.83.208.0/22

# --- Meta 系 (Facebook / Instagram / WhatsApp / Threads) ---
facebook.com
www.facebook.com
instagram.com
www.instagram.com
whatsapp.com
threads.com
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

# --- 其它 ---
reddit.com
www.reddit.com
old.reddit.com
xdaforums.com
xda-developers.com
hostloc.com
www.hostloc.com
54.172.97.0/22
23.255.155.0/24
# 以下两段体积很大(AWS us-east-1 / Datacamp CDN)，v1 曾默认启用，容易误伤，默认关闭:
# 52.5.0.0/16
# 37.19.0.0/16
EOF
}

# ----------------------------------------------------------------------------
# 安装步骤
# ----------------------------------------------------------------------------
preflight() {
    [ -n "$(ip -4 route show default 2>/dev/null)" ] || die "本机没有 IPv4 默认路由，纯 IPv6 VPS 不适用本脚本"
    ensure_tools
}

ensure_tools() {
    local need=()
    command -v curl     >/dev/null 2>&1 || need+=(curl)
    command -v iptables >/dev/null 2>&1 || need+=(iptables)
    command -v gpg      >/dev/null 2>&1 || { [ "$PKG" = apt ] && need+=(gnupg); }
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        [ "$PKG" = apt ] && apt-get update -y >/dev/null 2>&1
        pkg_install "${need[@]}" >/dev/null 2>&1 || die "依赖安装失败: ${need[*]}"
    fi
    iptables -w -t nat -L -n >/dev/null 2>&1 || die "iptables nat 表不可用 (内核缺少 nat 模块/容器受限)，无法使用透明代理"
}

pick_codename() {                   # 找到 Cloudflare 仓库实际存在的 codename
    local c="${CODENAME:-$(lsb_release -cs 2>/dev/null)}" fallback try
    if [ "$OS" = ubuntu ] || [[ " $OS_LIKE " == *" ubuntu "* ]]; then
        if [ "${OS_VER%%.*}" -ge 24 ] 2>/dev/null; then fallback=noble; else fallback=jammy; fi
    else
        fallback=bookworm
    fi
    for try in "$c" "$fallback"; do
        [ -n "$try" ] || continue
        if curl -fs -m 15 -o /dev/null "https://pkg.cloudflareclient.com/dists/$try/InRelease"; then
            [ "$try" != "$c" ] && warn "Cloudflare 仓库暂无 '$c'，回退使用 '$try'"
            echo "$try"; return 0
        fi
    done
    return 1
}

install_warp_pkg() {
    info "\n[1/4] 安装 Cloudflare WARP 官方客户端..."
    if command -v warp-cli >/dev/null 2>&1; then ok "WARP 客户端已存在，跳过安装"; return 0; fi

    if [ "$PKG" = apt ]; then
        local cn
        apt-get update -y >/dev/null 2>&1
        pkg_install ca-certificates lsb-release gnupg >/dev/null 2>&1
        cn=$(pick_codename) || die "Cloudflare 仓库不支持当前系统，也无可用回退版本"
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
            || die "下载 Cloudflare GPG 密钥失败"
        echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $cn main" \
            > /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -y 2>&1 | tail -n 3
        pkg_install cloudflare-warp || die "cloudflare-warp 安装失败"
    else
        curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo -o /etc/yum.repos.d/cloudflare-warp.repo \
            || die "下载 Cloudflare yum 仓库文件失败"
        rpm --import https://pkg.cloudflareclient.com/pubkey.gpg >/dev/null 2>&1
        pkg_install cloudflare-warp || die "cloudflare-warp 安装失败"
    fi
    command -v warp-cli >/dev/null 2>&1 || die "WARP 安装失败"
    ok "WARP 客户端已安装"
}

configure_warp() {
    info "\n[2/4] 配置 WARP(代理模式，确认后才连接)..."
    "$ENGINE" setup-warp || die "WARP 配置失败。你的 VPS 网络未被改动，可用 '$ENGINE rescue' 清理。"
    ok "WARP 已连接 (SOCKS5 127.0.0.1:$PROXY_PORT)，SSH/默认路由不受影响"
}

build_redsocks() {
    info "从源码编译 redsocks ..."
    local tmp; tmp=$(mktemp -d)
    if [ "$PKG" = apt ]; then pkg_install git build-essential libevent-dev >/dev/null 2>&1
    else pkg_install git gcc make libevent-devel >/dev/null 2>&1; fi
    git clone --depth 1 https://github.com/darkk/redsocks "$tmp/redsocks" >/dev/null 2>&1 \
        && make -C "$tmp/redsocks" >/dev/null 2>&1 \
        && install -m 755 "$tmp/redsocks/redsocks" /usr/local/sbin/redsocks
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

install_redsocks() {
    info "\n[3/4] 安装透明代理组件 redsocks..."
    REDSOCKS_SRC=existing
    if ! command -v redsocks >/dev/null 2>&1; then
        REDSOCKS_SRC=pkg
        [ "$PKG" != apt ] && [ "$OS" != fedora ] && pkg_install epel-release >/dev/null 2>&1
        if ! pkg_install redsocks >/dev/null 2>&1 || ! command -v redsocks >/dev/null 2>&1; then
            REDSOCKS_SRC=source
            build_redsocks || die "redsocks 安装失败(软件源无此包且编译失败)。WARP 代理模式已就绪，但未修改任何路由。"
        fi
    fi
    REDSOCKS_BIN=$(command -v redsocks)
    systemctl disable --now redsocks >/dev/null 2>&1     # 发行版自带服务会占用端口
    ok "redsocks: $REDSOCKS_BIN"
}

pick_redir_port() {
    local p
    for p in 12345 12346 12347 12348 12349; do
        if ! ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then REDIR_PORT=$p; return 0; fi
    done
    die "12345-12349 端口均被占用"
}

write_units() {
    cat > /etc/systemd/system/warp-redsocks.service << EOF
[Unit]
Description=redsocks transparent proxy (WARP Google)
After=network-online.target warp-svc.service
Wants=warp-svc.service

[Service]
Type=simple
User=nobody
ExecStart=$REDSOCKS_BIN -c $CONF_DIR/redsocks.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/warp-google.service << EOF
[Unit]
Description=WARP Google routing rules
After=network-online.target warp-svc.service warp-redsocks.service
Wants=network-online.target warp-svc.service warp-redsocks.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
ExecStart=$ENGINE boot
ExecStop=$ENGINE rules-off

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/warp-google-watchdog.service << EOF
[Unit]
Description=WARP Google watchdog (故障自动放行)

[Service]
Type=oneshot
ExecStart=$ENGINE check
EOF

    cat > /etc/systemd/system/warp-google-watchdog.timer << EOF
[Unit]
Description=WARP Google watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable warp-svc warp-redsocks warp-google warp-google-watchdog.timer >/dev/null 2>&1
}

setup_proxy_rules() {
    info "\n[4/4] 配置透明代理规则..."
    write_config
    "$ENGINE" update >/dev/null 2>&1 && ok "已载入 Google 官方最新网段" || warn "使用内置 Google 网段"
    write_units
    systemctl restart warp-redsocks
    sleep 1
    systemctl is-active --quiet warp-redsocks || { journalctl -u warp-redsocks -n 15 --no-pager; die "redsocks 启动失败"; }
    systemctl restart warp-google      # 内部会做端到端验证，失败自动回滚规则
    systemctl start warp-google-watchdog.timer

    if [ -e "$SHORTCUT" ] && ! grep -q 'WARP-GOOGLE-ENGINE' "$SHORTCUT" 2>/dev/null && [ ! -L "$SHORTCUT" ]; then
        warn "$SHORTCUT 已被其它程序占用，未创建 warp 快捷命令，请使用 warp-google"
    else
        ln -sf "$ENGINE" "$SHORTCUT"
    fi
}

do_install() {
    detect_env
    trap '' HUP
    preflight
    info "\n清理旧版本遗留配置..."
    write_engine
    "$ENGINE" cleanup-legacy
    pick_redir_port
    install_warp_pkg
    configure_warp
    install_redsocks
    setup_proxy_rules

    echo
    "$ENGINE" test
    echo
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  安装完成                          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "
${YELLOW}• 仅目标站点的 TCP 流量走 WARP，其余流量与 SSH 不受影响
• WARP/redsocks 异常时看门狗会自动摘除规则，Google 恢复直连(不会断网)
• 自定义站点: 编辑 ${CONF_DIR}/extra.list 后执行 warp restart${NC}

管理命令: ${CYAN}warp {status|start|stop|restart|test|ip|update|rescue|uninstall}${NC}
万一出问题(控制台/VNC 中执行): ${CYAN}warp rescue${NC}  或  ${CYAN}warp-cli disconnect; systemctl stop warp-svc${NC}
"
}

do_uninstall() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行！"
    [ -x "$ENGINE" ] || write_engine
    [ -f "$CONF_DIR/warp-google.conf" ] || { mkdir -p "$CONF_DIR"; echo "REDSOCKS_SRC=existing" > "$CONF_DIR/warp-google.conf"; }
    "$ENGINE" uninstall
}

do_rescue() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行！"
    [ -x "$ENGINE" ] || write_engine
    "$ENGINE" rescue
}

do_status() {
    [ -x "$ENGINE" ] || die "尚未安装"
    "$ENGINE" status; echo; "$ENGINE" ip; echo; "$ENGINE" test
}

# ----------------------------------------------------------------------------
# 菜单
# ----------------------------------------------------------------------------
show_menu() {
    local choice
    while true; do
        echo -e "${YELLOW}请选择操作:${NC}\n"
        echo -e "  ${GREEN}1.${NC} 安装 WARP (解锁 Gemini / Play 商店等)"
        echo -e "  ${GREEN}2.${NC} 卸载 WARP"
        echo -e "  ${GREEN}3.${NC} 查看状态 / 测试"
        echo -e "  ${GREEN}4.${NC} 重启服务"
        echo -e "  ${GREEN}5.${NC} 更新 Google 网段"
        echo -e "  ${GREEN}6.${NC} 紧急恢复 (移除规则并断开 WARP)"
        echo -e "  ${GREEN}0.${NC} 退出\n"
        read -r -p "请输入选项 [0-6]: " choice < /dev/tty || exit 0
        echo
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_status ;;
            4) [ -x "$ENGINE" ] && "$ENGINE" restart || err "尚未安装" ;;
            5) [ -x "$ENGINE" ] && "$ENGINE" update || err "尚未安装" ;;
            6) do_rescue ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) err "无效选项" ;;
        esac
        echo
    done
}

main() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行！"
    case "${1:-}" in
        install)   show_banner; do_install ;;
        uninstall) do_uninstall ;;
        status)    do_status ;;
        rescue)    do_rescue ;;
        "")        show_banner; show_menu ;;
        *)         echo "用法: $0 [install|uninstall|status|rescue]"; exit 1 ;;
    esac
}

main "$@"
