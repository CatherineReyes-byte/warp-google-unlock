#!/usr/bin/env bash
# =============================================================================
#  WARP 一键脚本 v2.3 —— Cloudflare 官方客户端 + 精准动态分流
#
#  设计原则:
#    1. 非 Google 系 (extra.list): 完整保留原版解析机制 + WARP_GOOGLE(redsocks) +
#       WARP_GOOGLE_X6(IPv6回落)，全局 WARP 服务始终保持运行。
#    2. Gemini 三域名精准动态分流:
#       - 默认 DIRECT；仅 gemini.google.com 明确地区受限时启用 WARP_GEMINI + SNI 精确匹配
#       - accounts.google.com / www.google.com / 其他 Google 子域名永不进 WARP
#       - 30~60 分钟独立随机检测；连续两轮独立直连确认恢复后回归 DIRECT
#       - WARP 出口受限自动轮换 Endpoint（游标轮询 + 备份回滚 + 全败暂留 WARP）
# =============================================================================

trap '' HUP

CONF_DIR=/etc/warp-google
LIB_DIR=/usr/local/lib/warp-google
LOG_DIR=/var/log/warp-google
BACKUP_BASE=/var/backups/warp-google
ENGINE=/usr/local/bin/warp-google
SHORTCUT=/usr/local/bin/warp
PROXY_PORT=40000
REDIR_PORT=12345
SNI_PORT=12350
DIRECT_MARK=0x5752

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
info() { echo -e "${CYAN}$*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }
err()  { echo -e "${RED}✗ $*${NC}"; }
die()  { err "$*"; exit 1; }

show_banner() {
    [ -t 1 ] && clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   WARP 一键脚本 v2.3 - Gemini 直连优先 & 精准动态分流  ║"
    echo "║   extra.list 稳定保留 · 防竞态锁 · 游标轮换 · 随机检测 ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

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
        openvz|lxc|lxc-libvirt) warn "检测到 $(systemd-detect-virt) 容器虚拟化，可能缺少 iptables nat/mark 模块，若失败请换 KVM 机型" ;;
    esac
}

pkg_install() {
    case $PKG in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        *)   $PKG install -y "$@" ;;
    esac
}

backup_existing() {
    local has_old=0 ts bdir
    [ -e "$ENGINE" ] && has_old=1
    [ -d "$CONF_DIR" ] && has_old=1
    ls /etc/systemd/system/warp-*.service /etc/systemd/system/warp-*.timer >/dev/null 2>&1 && has_old=1
    [ "$has_old" -eq 0 ] && return 0

    ts=$(date +%Y%m%d-%H%M%S)
    bdir="$BACKUP_BASE/$ts"
    mkdir -p "$bdir/systemd" "$bdir/conf"
    [ -e "$ENGINE" ] && cp -a "$ENGINE" "$bdir/warp-google.bin"
    [ -d "$CONF_DIR" ] && cp -a "$CONF_DIR/." "$bdir/conf/"
    [ -d "$LIB_DIR" ] && cp -a "$LIB_DIR" "$bdir/lib"
    cp -a /etc/systemd/system/warp-*.service /etc/systemd/system/warp-*.timer "$bdir/systemd/" 2>/dev/null || true
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$bdir/iptables.v4.rules" 2>/dev/null || true
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$bdir/iptables.v6.rules" 2>/dev/null || true
    {
        echo "# Backup created at $(date -Iseconds)"
        iptables -w -t nat -S WARP_GOOGLE 2>/dev/null || true
        iptables -w -t filter -S WARP_GOOGLE_F 2>/dev/null || true
        ip6tables -w -t filter -S WARP_GOOGLE_X6 2>/dev/null || true
    } > "$bdir/rules-manifest.txt"
    ln -sfn "$bdir" "$BACKUP_BASE/latest"

    # 仅保留最近 5 份带时间戳的备份目录（不删除 manual-*）
    ls -1dt "$BACKUP_BASE"/20* 2>/dev/null | tail -n +6 | xargs -r rm -rf --
    ok "已自动备份原有脚本与配置至: $bdir"
}

write_python_modules() {
    mkdir -p "$LIB_DIR" "$LOG_DIR"

    cat > "$LIB_DIR/sni_proxy.py" << 'SNI_EOF'
#!/usr/bin/env python3
"""
Lightweight TLS SNI & HTTP Host transparent router for exact Gemini hostnames.
- Exact match in ALLOWED_HOSTS -> SOCKS5 (127.0.0.1:PROXY_PORT, Cloudflare WARP)
- Everything else (e.g. accounts.google.com / www.google.com sharing IPs)
  or unparsed SNI -> DIRECT with SO_MARK(DIRECT_MARK) to bypass iptables redirect.
"""
import asyncio
import json
import os
import signal
import socket
import struct
import time

SO_ORIGINAL_DST = 80
SO_MARK = 36

ALLOWED_HOSTS = frozenset({
    "gemini.google.com",
    "aistudio.google.com",
    "generativelanguage.googleapis.com",
})

CONF_FILE = "/etc/warp-google/warp-google.conf"
STATS_FILE = "/run/warp-google/sni-stats.json"


def load_conf():
    cfg = {"PROXY_PORT": 40000, "SNI_PORT": 12350, "DIRECT_MARK": 0x5752}
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k in ("PROXY_PORT", "SNI_PORT"):
                    try:
                        cfg[k] = int(v)
                    except ValueError:
                        pass
                elif k == "DIRECT_MARK":
                    try:
                        cfg[k] = int(v, 0)
                    except ValueError:
                        pass
    return cfg


CFG = load_conf()
STATS = {
    "started_at": int(time.time()),
    "warp_total": 0,
    "direct_total": 0,
    "warp_hosts": {},
    "direct_hosts": {},
}
LAST_FLUSH_TS = 0.0


def flush_stats(force: bool = False):
    global LAST_FLUSH_TS
    now = time.monotonic()
    total = STATS["warp_total"] + STATS["direct_total"]
    if not force and (now - LAST_FLUSH_TS) < 10.0 and (total % 20 != 1):
        return
    try:
        os.makedirs(os.path.dirname(STATS_FILE), exist_ok=True)
        tmp = STATS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(STATS, f, ensure_ascii=False)
        os.replace(tmp, STATS_FILE)
        LAST_FLUSH_TS = now
    except Exception:
        pass


def set_nodelay(writer: asyncio.StreamWriter):
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except Exception:
            pass


def parse_tls_sni(data: bytes):
    if len(data) < 5 or data[0] != 0x16:
        return None
    record_len = int.from_bytes(data[3:5], "big")
    if len(data) < 5 + record_len:
        return "NEED_MORE"
    pos = 5
    end = 5 + record_len
    if pos + 4 > end or data[pos] != 0x01:
        return None
    hs_len = int.from_bytes(data[pos + 1:pos + 4], "big")
    pos += 4
    hs_end = min(end, pos + hs_len)
    if pos + 34 > hs_end:
        return None
    pos += 2 + 32
    if pos + 1 > hs_end:
        return None
    sid_len = data[pos]
    pos += 1 + sid_len
    if pos + 2 > hs_end:
        return None
    cs_len = int.from_bytes(data[pos:pos + 2], "big")
    pos += 2 + cs_len
    if pos + 1 > hs_end:
        return None
    comp_len = data[pos]
    pos += 1 + comp_len
    if pos + 2 > hs_end:
        return None
    ext_total = int.from_bytes(data[pos:pos + 2], "big")
    pos += 2
    ext_end = min(hs_end, pos + ext_total)
    while pos + 4 <= ext_end:
        ext_type = int.from_bytes(data[pos:pos + 2], "big")
        ext_len = int.from_bytes(data[pos + 2:pos + 4], "big")
        pos += 4
        if pos + ext_len > ext_end:
            break
        if ext_type == 0x0000 and ext_len >= 2:
            list_len = int.from_bytes(data[pos:pos + 2], "big")
            p = pos + 2
            lend = min(pos + ext_len, p + list_len)
            while p + 3 <= lend:
                name_type = data[p]
                name_len = int.from_bytes(data[p + 1:p + 3], "big")
                p += 3
                if p + name_len > lend:
                    break
                if name_type == 0:
                    host = data[p:p + name_len].decode("ascii", errors="ignore")
                    return host.strip().rstrip(".").lower()
                p += name_len
        pos += ext_len
    return None


def parse_http_host(data: bytes):
    try:
        head = data.split(b"\r\n\r\n", 1)[0].decode("latin1", errors="ignore")
        for line in head.split("\r\n")[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                if k.strip().lower() == "host":
                    host = v.strip()
                    if ":" in host:
                        host = host.split(":", 1)[0]
                    return host.rstrip(".").lower()
    except Exception:
        pass
    return None


async def read_initial_payload(reader: asyncio.StreamReader, orig_port: int):
    buf = bytearray()
    deadline = time.monotonic() + 2.0
    while len(buf) < 16384:
        rem = deadline - time.monotonic()
        if rem <= 0:
            break
        try:
            chunk = await asyncio.wait_for(reader.read(4096), timeout=rem)
        except (asyncio.TimeoutError, Exception):
            break
        if not chunk:
            break
        buf.extend(chunk)
        if buf[0] == 0x16:
            sni = parse_tls_sni(bytes(buf))
            if sni == "NEED_MORE":
                continue
            return bytes(buf), sni
        if orig_port == 80 or buf.startswith((b"GET ", b"POST ", b"HEAD ", b"PUT ", b"DELETE ", b"OPTIONS ")):
            if b"\r\n\r\n" in buf:
                return bytes(buf), parse_http_host(bytes(buf))
            continue
        return bytes(buf), None
    if buf and buf[0] == 0x16:
        sni = parse_tls_sni(bytes(buf))
        return bytes(buf), (None if sni == "NEED_MORE" else sni)
    return bytes(buf), parse_http_host(bytes(buf))


async def open_socks5(host: str, port: int):
    reader, writer = await asyncio.wait_for(
        asyncio.open_connection("127.0.0.1", CFG["PROXY_PORT"]), timeout=10.0
    )
    try:
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        resp = await asyncio.wait_for(reader.readexactly(2), timeout=5.0)
        if resp != b"\x05\x00":
            raise ConnectionError(f"SOCKS5 auth rejected: {resp!r}")
        hb = host.encode("ascii")
        req = b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack("!H", port)
        writer.write(req)
        await writer.drain()
        hdr = await asyncio.wait_for(reader.readexactly(4), timeout=10.0)
        if hdr[1] != 0x00:
            raise ConnectionError(f"SOCKS5 connect failed code={hdr[1]}")
        atyp = hdr[3]
        if atyp == 1:
            await reader.readexactly(6)
        elif atyp == 3:
            alen = (await reader.readexactly(1))[0]
            await reader.readexactly(alen + 2)
        elif atyp == 4:
            await reader.readexactly(18)
        return reader, writer
    except Exception:
        writer.close()
        raise


async def open_direct_marked(orig_ip: str, orig_port: int):
    loop = asyncio.get_running_loop()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setblocking(False)
    sock.setsockopt(socket.SOL_SOCKET, SO_MARK, CFG["DIRECT_MARK"])
    try:
        await asyncio.wait_for(loop.sock_connect(sock, (orig_ip, orig_port)), timeout=10.0)
        return await asyncio.open_connection(sock=sock)
    except Exception:
        sock.close()
        raise


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter):
    try:
        while True:
            data = await src.read(32768)
            if not data:
                try:
                    if dst.can_write_eof():
                        dst.write_eof()
                        await dst.drain()
                except Exception:
                    pass
                break
            dst.write(data)
            await dst.drain()
    except Exception:
        pass


async def handle_client(c_reader: asyncio.StreamReader, c_writer: asyncio.StreamWriter):
    u_writer = None
    try:
        set_nodelay(c_writer)
        raw_sock = c_writer.get_extra_info("socket")
        if raw_sock is None:
            return
        try:
            raw_dst = raw_sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
            _, orig_port, ip_bytes, _ = struct.unpack("!HH4s8s", raw_dst)
            orig_ip = socket.inet_ntoa(ip_bytes)
        except Exception:
            return

        if orig_ip == "127.0.0.1" and orig_port == CFG["SNI_PORT"]:
            return

        initial, host = await read_initial_payload(c_reader, orig_port)
        use_warp = bool(host and host in ALLOWED_HOSTS)

        if use_warp:
            STATS["warp_total"] += 1
            STATS["warp_hosts"][host] = STATS["warp_hosts"].get(host, 0) + 1
            u_reader, u_writer = await open_socks5(host, orig_port)
        else:
            key = host or f"unknown:{orig_ip}"
            STATS["direct_total"] += 1
            STATS["direct_hosts"][key] = STATS["direct_hosts"].get(key, 0) + 1
            u_reader, u_writer = await open_direct_marked(orig_ip, orig_port)

        set_nodelay(u_writer)
        flush_stats(force=False)

        if initial:
            u_writer.write(initial)
            await u_writer.drain()

        await asyncio.gather(pipe(c_reader, u_writer), pipe(u_reader, c_writer))
    except Exception:
        pass
    finally:
        flush_stats(force=False)
        for w in (u_writer, c_writer):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


async def main():
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)
    try:
        loop.add_signal_handler(signal.SIGUSR1, lambda: flush_stats(force=True))
    except Exception:
        pass

    server = await asyncio.start_server(handle_client, "127.0.0.1", CFG["SNI_PORT"], reuse_address=True)
    flush_stats(force=True)
    async with server:
        await stop_event.wait()
    flush_stats(force=True)


if __name__ == "__main__":
    asyncio.run(main())
SNI_EOF
    chmod 755 "$LIB_DIR/sni_proxy.py"

    cat > "$LIB_DIR/gemini_mgr.py" << 'MGR_EOF'
#!/usr/bin/env python3
"""
Gemini Direct-First Dynamic Routing & Health Check Manager.
States: DIRECT | WARP | SWITCHING | ERROR
"""
import datetime
import fcntl
import gzip
import http.client
import json
import logging
from logging.handlers import TimedRotatingFileHandler
import os
import re
import secrets
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.parse

CONF_DIR = "/etc/warp-google"
CONF_FILE = os.path.join(CONF_DIR, "warp-google.conf")
STATE_FILE = os.path.join(CONF_DIR, "gemini-state.json")
STATE_BAK = os.path.join(CONF_DIR, "gemini-state.json.bak")
ENDPOINTS_FILE = os.path.join(CONF_DIR, "endpoints.list")
ENDPOINT_BAK = os.path.join(CONF_DIR, "endpoint-backup.json")
STATE_DIR = "/run/warp-google"
CHECK_LOCK_FILE = os.path.join(STATE_DIR, "gemini-check.lock")
STATE_LOCK_FILE = os.path.join(STATE_DIR, "gemini-state.lock")
LOG_DIR = "/var/log/warp-google"
LOG_FILE = os.path.join(LOG_DIR, "gemini.log")
ENGINE = "/usr/local/bin/warp-google"

SO_MARK = 36
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

TARGET_DOMAINS = (
    "gemini.google.com",
    "aistudio.google.com",
    "generativelanguage.googleapis.com",
)
NON_WARP_VERIFY_DOMAINS = ("accounts.google.com", "www.google.com")

GEO_BLOCK_PHRASES = (
    "gemini is not available in your country or region",
    "your country or region is not supported",
    "not available in your country",
    "isn't currently supported in your country",
    "user location is not supported for the api use",
    "当前所在国家或地区不支持",
    "所在国家或地区不支持 gemini",
    "45631641,null,false",
)

STOP_REQUESTED = False


def load_conf():
    cfg = {
        "PROXY_PORT": 40000,
        "SNI_PORT": 12350,
        "DIRECT_MARK": 0x5752,
        "MIN_INTERVAL": 1800,
        "MAX_INTERVAL": 3600,
        "MAX_ENDPOINT_TRIES": 5,
        "ENDPOINT_RETRY_SLEEP": 5,
    }
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k in ("PROXY_PORT", "SNI_PORT", "MIN_INTERVAL", "MAX_INTERVAL",
                         "MAX_ENDPOINT_TRIES", "ENDPOINT_RETRY_SLEEP"):
                    try:
                        cfg[k] = int(v)
                    except ValueError:
                        pass
                elif k == "DIRECT_MARK":
                    try:
                        cfg[k] = int(v, 0)
                    except ValueError:
                        pass
    return cfg


CFG = load_conf()


def setup_logger():
    os.makedirs(LOG_DIR, exist_ok=True)
    logger = logging.getLogger("warp-gemini")
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    handler = TimedRotatingFileHandler(
        LOG_FILE, when="D", interval=1, backupCount=7, encoding="utf-8"
    )
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    handler.setFormatter(fmt)
    logger.addHandler(handler)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    return logger


LOG = setup_logger()


def now_iso(ts=None):
    return datetime.datetime.fromtimestamp(ts or time.time()).strftime("%Y-%m-%d %H:%M:%S")


def default_state():
    return {
        "mode": "DIRECT",
        "last_valid_mode": "DIRECT",
        "direct_recover_streak": 0,
        "last_direct_ok_round": 0,
        "round_id": 0,
        "endpoint_cursor": 0,
        "last_check_start": "",
        "last_check_end": "",
        "last_wait_seconds": 0,
        "next_check_at": "",
        "current_endpoint": "default",
        "verified_endpoint": "",
        "last_direct_ip": "",
        "last_warp_ip": "",
        "last_direct_result": {},
        "last_warp_result": {},
        "last_error": "",
    }


def load_state():
    for path in (STATE_FILE, STATE_BAK):
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict) and data.get("last_valid_mode") in ("DIRECT", "WARP"):
                    base = default_state()
                    base.update(data)
                    if base["mode"] in ("SWITCHING", "ERROR"):
                        base["mode"] = base["last_valid_mode"]
                    return base
            except Exception:
                continue
    return default_state()


def save_state(st: dict, backup_first: bool = False):
    os.makedirs(CONF_DIR, exist_ok=True)
    if backup_first and os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as src:
                old = src.read()
            tmp_b = STATE_BAK + ".tmp"
            with open(tmp_b, "w", encoding="utf-8") as dst:
                dst.write(old)
            os.replace(tmp_b, STATE_BAK)
        except Exception:
            pass
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=2)
    os.replace(tmp, STATE_FILE)


def run_cmd(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as e:
        return 1, "", str(e)


def wcli(*args, timeout=20):
    return run_cmd(["warp-cli", "--accept-tos", *args], timeout=timeout)


def _open_outbound_socket(host: str, port: int, timeout: float, mark: int = 0, socks_port: int = 0):
    resolved_ips = []
    if socks_port:
        sock = socket.create_connection(("127.0.0.1", socks_port), timeout)
        try:
            sock.sendall(b"\x05\x01\x00")
            if sock.recv(2) != b"\x05\x00":
                raise ConnectionError("SOCKS5 handshake rejected")
            hb = host.encode("ascii")
            sock.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack("!H", port))
            hdr = b""
            while len(hdr) < 4:
                chunk = sock.recv(4 - len(hdr))
                if not chunk:
                    raise ConnectionError("SOCKS5 EOF")
                hdr += chunk
            if hdr[1] != 0x00:
                raise ConnectionError(f"SOCKS5 connect status={hdr[1]}")
            atyp = hdr[3]
            if atyp == 1:
                sock.recv(6)
            elif atyp == 3:
                ln = sock.recv(1)[0]
                sock.recv(ln + 2)
            elif atyp == 4:
                sock.recv(18)
            return sock, resolved_ips
        except Exception:
            sock.close()
            raise
    infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
    resolved_ips = sorted({i[4][0] for i in infos})
    last_err = None
    for fam, stype, proto, _, sa in infos:
        s = socket.socket(fam, stype, proto)
        s.settimeout(timeout)
        try:
            if mark:
                s.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
            s.connect(sa)
            return s, resolved_ips
        except Exception as e:
            last_err = e
            s.close()
    raise last_err or ConnectionError("TCP connect failed")


class CustomHTTPConnection(http.client.HTTPConnection):
    def __init__(self, host, port=None, mark=0, socks_port=0, timeout=12):
        super().__init__(host, port=port, timeout=timeout)
        self._mark = mark
        self._socks_port = socks_port
        self.resolved_ips = []

    def connect(self):
        self.sock, self.resolved_ips = _open_outbound_socket(
            self.host, self.port or 80, self.timeout, self._mark, self._socks_port
        )


class CustomHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, port=None, mark=0, socks_port=0, timeout=12, context=None):
        super().__init__(host, port=port, timeout=timeout, context=context)
        self._mark = mark
        self._socks_port = socks_port
        self.resolved_ips = []

    def connect(self):
        sock, self.resolved_ips = _open_outbound_socket(
            self.host, self.port or 443, self.timeout, self._mark, self._socks_port
        )
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def http_fetch(url: str, mark: int = 0, socks_port: int = 0, max_redirects: int = 5, timeout: int = 12):
    ctx = ssl.create_default_context()
    cur = url
    redirects = []
    dns_ips = []
    for _ in range(max_redirects + 1):
        u = urllib.parse.urlparse(cur)
        host = u.hostname
        if u.scheme == "http":
            port = u.port or 80
            conn = CustomHTTPConnection(host, port=port, mark=mark, socks_port=socks_port, timeout=timeout)
        else:
            port = u.port or 443
            conn = CustomHTTPSConnection(host, port=port, mark=mark, socks_port=socks_port, timeout=timeout, context=ctx)
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        try:
            conn.request(
                "GET",
                path,
                headers={
                    "Host": u.netloc,
                    "User-Agent": UA,
                    "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
                    "Accept-Language": "en-US,en;q=0.9",
                    "Accept-Encoding": "gzip, identity",
                    "Connection": "close",
                },
            )
            resp = conn.getresponse()
            if conn.resolved_ips:
                dns_ips = conn.resolved_ips
            raw = resp.read(524288)
            enc = (resp.getheader("Content-Encoding") or "").lower()
            if "gzip" in enc:
                try:
                    raw = gzip.decompress(raw)
                except Exception:
                    pass
            body = raw.decode("utf-8", errors="ignore")
            status = resp.status
            loc = resp.getheader("Location")
        finally:
            conn.close()

        if status in (301, 302, 303, 307, 308) and loc:
            nxt = urllib.parse.urljoin(cur, loc)
            redirects.append(nxt)
            cur = nxt
            continue
        return {
            "status": status,
            "final_url": cur,
            "redirects": redirects,
            "dns_ips": dns_ips,
            "body": body,
        }
    return {"status": 310, "final_url": cur, "redirects": redirects, "dns_ips": dns_ips, "body": ""}


def get_egress_ip(mark: int = 0, socks_port: int = 0):
    for url in ("https://api.ipify.org/", "https://api.ip.sb/ip", "https://ifconfig.me/ip"):
        try:
            res = http_fetch(url, mark=mark, socks_port=socks_port, max_redirects=1, timeout=6)
            ip = res["body"].strip()
            socket.inet_aton(ip)
            return ip
        except Exception:
            continue
    return ""


def check_warp_trace():
    try:
        res = http_fetch("https://www.cloudflare.com/cdn-cgi/trace", socks_port=CFG["PROXY_PORT"], timeout=8)
        return ("warp=on" in res["body"]) or ("warp=plus" in res["body"])
    except Exception:
        return False


def classify_error(exc: Exception):
    if isinstance(exc, socket.gaierror):
        return "DNS_ERROR"
    if isinstance(exc, ssl.SSLError):
        return "TLS_ERROR"
    return "NETWORK_ERROR"


def classify_domain_response(domain: str, res: dict):
    status = res["status"]
    final_url = res["final_url"].lower()
    body_l = res["body"].lower()

    for phrase in GEO_BLOCK_PHRASES:
        if phrase in body_l:
            return "GEO_BLOCKED", f"matched:{phrase}"

    if domain == "aistudio.google.com" and "/available-regions" in final_url:
        return "GEO_BLOCKED", "redirected_to_available_regions"

    if status == 403:
        if domain == "generativelanguage.googleapis.com" and (
            "api key" in body_l or "unregistered callers" in body_l or "permission_denied" in body_l
        ):
            return "AVAILABLE", "api_reachable_unauth_403"
        return "HTTP_403", "http_403"

    if status == 429:
        return "HTTP_429", "http_429"

    if status == 400 and domain == "generativelanguage.googleapis.com":
        if "api key" in body_l or "invalid" in body_l:
            return "AVAILABLE", "api_reachable_unauth_400"
        return "UNCERTAIN", "http_400"

    if "google.com/sorry" in final_url or "recaptcha" in body_l or "unusual traffic" in body_l:
        return "AUTH_OR_CAPTCHA", "captcha_or_sorry"

    if "consent.google.com" in final_url:
        return "UNCERTAIN", "consent_page"

    if status >= 500:
        return "SERVER_ERROR", f"http_{status}"

    if domain == "gemini.google.com":
        if "accounts.google.com" in final_url and "45631641" not in body_l:
            return "AUTH_OR_CAPTCHA", "login_redirect"
        if status == 200:
            if "45631641,null,true" in body_l or '45631641,"' in body_l:
                return "AVAILABLE", "wiz_flag_available"
            if "gemini" in body_l and "wiz_global_data" in body_l:
                return "AVAILABLE", "gemini_shell_200"
            return "UNCERTAIN", "http_200_no_positive_marker"
        return "UNCERTAIN", f"http_{status}"

    if domain == "aistudio.google.com":
        if status in (200, 302):
            return "AVAILABLE", f"http_{status}_no_region_redirect"
        return "UNCERTAIN", f"http_{status}"

    return "UNCERTAIN", f"http_{status}"


def probe_single_domain(domain: str, mark: int = 0, socks_port: int = 0, retries: int = 2):
    url = f"https://{domain}/v1beta/models" if domain == "generativelanguage.googleapis.com" else f"https://{domain}/"
    attempts = 0
    last_cat, last_detail, last_ips = "NETWORK_ERROR", "", []
    while attempts <= retries:
        attempts += 1
        try:
            if not socks_port:
                infos = socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
                last_ips = sorted({i[4][0] for i in infos})
            res = http_fetch(url, mark=mark, socks_port=socks_port, timeout=12)
            if res["dns_ips"]:
                last_ips = res["dns_ips"]
            cat, detail = classify_domain_response(domain, res)
            if cat == "SERVER_ERROR" and attempts <= retries:
                last_cat, last_detail = cat, detail
                time.sleep(5)
                continue
            return {
                "domain": domain, "category": cat, "detail": detail,
                "status": res["status"], "final_url": res["final_url"],
                "dns_ips": last_ips, "attempts": attempts,
            }
        except Exception as exc:
            last_cat = classify_error(exc)
            last_detail = str(exc)[:160]
            if attempts <= retries:
                time.sleep(5)
    return {
        "domain": domain, "category": last_cat, "detail": last_detail,
        "status": 0, "final_url": "", "dns_ips": last_ips, "attempts": attempts,
    }


def probe_path(mode_label: str, mark: int = 0, socks_port: int = 0):
    egress_ip = get_egress_ip(mark=mark, socks_port=socks_port)
    results = {}
    for d in TARGET_DOMAINS:
        results[d] = probe_single_domain(d, mark=mark, socks_port=socks_port, retries=2)
    core = results["gemini.google.com"]
    aux_geo = [
        d for d in ("aistudio.google.com", "generativelanguage.googleapis.com")
        if results[d]["category"] == "GEO_BLOCKED"
    ]
    return {
        "path": mode_label, "egress_ip": egress_ip,
        "verdict": core["category"], "aux_geo_blocked": aux_geo, "domains": results,
    }


def read_current_endpoint():
    rc, out, _ = wcli("settings")
    if rc == 0:
        for line in out.splitlines():
            low = line.lower()
            if "custom endpoint" in low or low.strip().startswith("endpoint:"):
                val = line.split(":", 1)[1].strip()
                if val and val.lower() not in ("(none)", "none", "unset", "not set"):
                    return val
    return "default"


def set_warp_endpoint(ep: str):
    if ep == "default" or not ep:
        rc, _, _ = wcli("tunnel", "endpoint", "reset")
        if rc != 0:
            rc, _, _ = wcli("clear-custom-endpoint")
        return rc == 0
    rc, _, _ = wcli("tunnel", "endpoint", "set", ep)
    if rc != 0:
        rc, _, _ = wcli("set-custom-endpoint", ep)
    return rc == 0


def reconnect_warp():
    wcli("disconnect")
    time.sleep(1.5)
    run_cmd([ENGINE, "ensure-proxy-mode"])
    wcli("connect")
    for _ in range(30):
        rc, out, _ = wcli("status")
        if rc == 0 and "Connected" in out:
            rc_if, _, _ = run_cmd(["ip", "link", "show", "CloudflareWARP"])
            if rc_if == 0:
                wcli("disconnect")
                return False
            for _ in range(10):
                if check_warp_trace():
                    return True
                time.sleep(1.5)
            return False
        time.sleep(1)
    return False


def load_candidate_endpoints():
    ep_re = re.compile(r"^(default|\d{1,3}(?:\.\d{1,3}){3}:\d{1,5})$")
    cands = []
    if os.path.exists(ENDPOINTS_FILE):
        with open(ENDPOINTS_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line and ep_re.match(line) and line not in cands:
                    cands.append(line)
    if "default" not in cands:
        cands.append("default")
    return cands


def rotate_endpoint(st: dict):
    old_ep = read_current_endpoint()
    old_ip = get_egress_ip(socks_port=CFG["PROXY_PORT"])
    with open(ENDPOINT_BAK + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"endpoint": old_ep, "warp_ip": old_ip, "saved_at": now_iso()}, f, indent=2)
    os.replace(ENDPOINT_BAK + ".tmp", ENDPOINT_BAK)

    all_cands = load_candidate_endpoints()
    if not all_cands:
        LOG.warning("无可用候选 Endpoint，跳过轮换")
        return False

    cursor = int(st.get("endpoint_cursor", 0)) % len(all_cands)
    ordered = all_cands[cursor:] + all_cands[:cursor]
    cands = [c for c in ordered if c != old_ep]
    max_tries = min(CFG["MAX_ENDPOINT_TRIES"], len(cands))
    if max_tries == 0:
        LOG.warning("无其他候选 Endpoint，跳过轮换")
        return False

    LOG.info("开始 Endpoint 轮换: 当前=%s, 当前WARP_IP=%s, 最大尝试=%d", old_ep, old_ip or "未知", max_tries)
    for idx, cand in enumerate(cands[:max_tries], 1):
        st["endpoint_cursor"] = (all_cands.index(cand) + 1) % len(all_cands)
        LOG.info("Endpoint 尝试 [%d/%d]: %s -> %s", idx, max_tries, old_ep, cand)
        if not set_warp_endpoint(cand):
            LOG.warning("设置 Endpoint 失败: %s", cand)
            continue
        if not reconnect_warp():
            LOG.warning("Endpoint %s 重连 WARP 失败", cand)
            time.sleep(CFG["ENDPOINT_RETRY_SLEEP"])
            continue
        new_ip = get_egress_ip(socks_port=CFG["PROXY_PORT"])
        ip_changed = bool(new_ip and new_ip != old_ip)
        probe = probe_path("WARP_CANDIDATE", socks_port=CFG["PROXY_PORT"])
        st["last_warp_ip"] = new_ip
        st["last_warp_result"] = probe
        LOG.info(
            "Endpoint=%s | 旧IP=%s -> 新IP=%s (变化=%s) | Gemini判定=%s",
            cand, old_ip or "?", new_ip or "?", ip_changed, probe["verdict"],
        )
        if probe["verdict"] == "AVAILABLE":
            st["current_endpoint"] = cand
            st["verified_endpoint"] = cand
            LOG.info("Endpoint %s 验证通过，Gemini 可正常访问", cand)
            return True
        time.sleep(CFG["ENDPOINT_RETRY_SLEEP"])

    LOG.error("已尝试 %d 个候选 Endpoint 均未解除限制，回滚至原 Endpoint 并暂留 WARP 状态: %s", max_tries, old_ep)
    set_warp_endpoint(old_ep)
    if reconnect_warp():
        st["current_endpoint"] = old_ep
        st["last_warp_ip"] = get_egress_ip(socks_port=CFG["PROXY_PORT"])
        LOG.info("已回滚至原 Endpoint=%s (IP=%s)，WARP 服务保持连接", old_ep, st["last_warp_ip"] or "?")
    else:
        set_warp_endpoint("default")
        reconnect_warp()
        st["current_endpoint"] = read_current_endpoint()
        LOG.warning("原 Endpoint 回滚重连失败，已回退 default 以确保 WARP 不断连")
    return False


def wait_sni_ready(timeout_sec: float = 5.0):
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", CFG["SNI_PORT"]), timeout=0.5):
                return True
        except Exception:
            time.sleep(0.2)
    return False


def enable_gemini_warp():
    rc1, _, err1 = run_cmd(["systemctl", "start", "warp-sni"])
    if rc1 != 0:
        return False, f"warp-sni 启动失败: {err1}"
    if not wait_sni_ready(5.0):
        run_cmd(["systemctl", "stop", "warp-sni"])
        return False, f"warp-sni 监听端口 {CFG['SNI_PORT']} 未就绪"
    rc2, out2, err2 = run_cmd([ENGINE, "gemini-rules-on"])
    if rc2 != 0:
        run_cmd(["systemctl", "stop", "warp-sni"])
        return False, f"WARP_GEMINI 规则挂载失败: {out2} {err2}"
    return True, ""


def disable_gemini_warp():
    run_cmd([ENGINE, "gemini-rules-off"])
    run_cmd(["systemctl", "stop", "warp-sni"])
    return True


def verify_unmarked_connectivity():
    res = {}
    for d in TARGET_DOMAINS:
        res[d] = probe_single_domain(d, mark=0, socks_port=0, retries=1)
    non_warp = {}
    for d in NON_WARP_VERIFY_DOMAINS:
        try:
            r = http_fetch(f"https://{d}/generate_204" if d == "www.google.com" else f"https://{d}/",
                           mark=0, socks_port=0, max_redirects=2, timeout=8)
            non_warp[d] = r["status"]
        except Exception as e:
            non_warp[d] = str(e)
    run_cmd(["systemctl", "kill", "-s", "SIGUSR1", "warp-sni"], timeout=5)
    return res, non_warp


def restore_boot_state():
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE_LOCK_FILE, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        st = load_state()
        mode = st.get("last_valid_mode", "DIRECT")
        if mode == "WARP":
            if check_warp_trace():
                ok, err = enable_gemini_warp()
                if ok:
                    st["mode"] = "WARP"
                    LOG.info("重启/启动恢复状态: WARP (已启用三域名精准 SNI 分流)")
                else:
                    disable_gemini_warp()
                    st["mode"] = "ERROR"
                    st["last_error"] = err
                    LOG.error("恢复 WARP 规则失败，已故障放行: %s", err)
            else:
                disable_gemini_warp()
                LOG.warning("启动时 WARP 代理尚未就绪，暂保持直连放行等待首轮检测")
        else:
            disable_gemini_warp()
            st["mode"] = "DIRECT"
            LOG.info("启动默认/恢复状态: DIRECT (三域名全部直连，全局 WARP 与 extra.list 规则不受影响)")
        save_state(st, backup_first=False)


def run_check_round():
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CHECK_LOCK_FILE, "w") as clf:
        try:
            fcntl.flock(clf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            LOG.warning("已有检测任务正在运行，跳过本次并发触发")
            return 0

        with open(STATE_LOCK_FILE, "w") as slf:
            fcntl.flock(slf, fcntl.LOCK_EX)
            st = load_state()
            st["round_id"] = int(st.get("round_id", 0)) + 1
            rid = st["round_id"]
            st["last_check_start"] = now_iso()
            cur_mode = st.get("last_valid_mode", "DIRECT")
            cur_ep = read_current_endpoint()
            st["current_endpoint"] = cur_ep

            LOG.info("======== 第 %d 轮 Gemini 健康检测开始 | 当前模式=%s | Endpoint=%s ========", rid, cur_mode, cur_ep)

            if cur_mode == "DIRECT":
                disable_gemini_warp()
                d_probe = probe_path("DIRECT", mark=CFG["DIRECT_MARK"])
                st["last_direct_ip"] = d_probe["egress_ip"]
                st["last_direct_result"] = d_probe
                verdict = d_probe["verdict"]
                LOG.info(
                    "DIRECT 检测结果: IP=%s | 判定=%s | 详情=%s | aux_geo=%s",
                    d_probe["egress_ip"] or "?", verdict,
                    {k: v["category"] for k, v in d_probe["domains"].items()},
                    d_probe["aux_geo_blocked"],
                )

                if verdict == "GEO_BLOCKED":
                    st["mode"] = "SWITCHING"
                    save_state(st, backup_first=True)
                    LOG.warning("直连明确受到 Gemini 地区限制，准备仅对三域名启用 WARP 精准分流...")
                    if not check_warp_trace():
                        st["mode"] = "ERROR"
                        st["last_error"] = "WARP SOCKS5 代理不可用，保留 DIRECT 防断网"
                        LOG.error(st["last_error"])
                    else:
                        ok, err = enable_gemini_warp()
                        if not ok:
                            disable_gemini_warp()
                            st["mode"] = "ERROR"
                            st["last_error"] = err
                            LOG.error("启用 WARP 分流失败并已回滚: %s", err)
                        else:
                            st["mode"] = "WARP"
                            st["last_valid_mode"] = "WARP"
                            st["direct_recover_streak"] = 0
                            w_probe = probe_path("WARP", socks_port=CFG["PROXY_PORT"])
                            st["last_warp_ip"] = w_probe["egress_ip"]
                            st["last_warp_result"] = w_probe
                            e2e, non_warp = verify_unmarked_connectivity()
                            LOG.info(
                                "已切换至 WARP | WARP_IP=%s | WARP_Gemini=%s | 端到端三域名=%s | 非WARP抽检=%s",
                                w_probe["egress_ip"] or "?", w_probe["verdict"],
                                {k: v["category"] for k, v in e2e.items()}, non_warp,
                            )
                            if w_probe["verdict"] == "GEO_BLOCKED":
                                LOG.warning("当前 WARP 出口也受地区限制，启动 Endpoint 自动轮换...")
                                rotate_endpoint(st)
                elif verdict == "AVAILABLE":
                    st["mode"] = "DIRECT"
                    st["last_valid_mode"] = "DIRECT"
                    st["last_error"] = ""
                else:
                    st["mode"] = "DIRECT"
                    st["last_valid_mode"] = "DIRECT"
                    st["last_error"] = f"direct_probe:{verdict}"
                    LOG.info("非地区限制状态(%s)，不触发 WARP 切换，保持 DIRECT", verdict)

            else:
                if check_warp_trace():
                    ok, err = enable_gemini_warp()
                    if not ok:
                        disable_gemini_warp()
                        st["last_error"] = err
                        LOG.error("WARP_GEMINI 规则异常，已临时放行: %s", err)
                else:
                    disable_gemini_warp()
                    st["last_error"] = "WARP 代理暂不可用，三域名临时放行直连"
                    LOG.warning(st["last_error"])

                w_probe = probe_path("WARP", socks_port=CFG["PROXY_PORT"])
                st["last_warp_ip"] = w_probe["egress_ip"]
                st["last_warp_result"] = w_probe
                LOG.info(
                    "WARP 出口检测: IP=%s | 判定=%s | 详情=%s",
                    w_probe["egress_ip"] or "?", w_probe["verdict"],
                    {k: v["category"] for k, v in w_probe["domains"].items()},
                )
                if w_probe["verdict"] == "GEO_BLOCKED":
                    st["mode"] = "SWITCHING"
                    save_state(st, backup_first=True)
                    rotate_endpoint(st)
                    st["mode"] = "WARP"

                d_probe = probe_path("DIRECT_BYPASS", mark=CFG["DIRECT_MARK"])
                st["last_direct_ip"] = d_probe["egress_ip"]
                st["last_direct_result"] = d_probe
                d_verdict = d_probe["verdict"]
                LOG.info(
                    "独立直连旁路检测(SO_MARK): IP=%s | 判定=%s | 详情=%s",
                    d_probe["egress_ip"] or "?", d_verdict,
                    {k: v["category"] for k, v in d_probe["domains"].items()},
                )

                if d_verdict == "AVAILABLE":
                    if st.get("last_direct_ok_round", 0) != rid:
                        st["direct_recover_streak"] = int(st.get("direct_recover_streak", 0)) + 1
                        st["last_direct_ok_round"] = rid
                    streak = st["direct_recover_streak"]
                    LOG.info("直连恢复检测正常: 连续成功次数 = %d/2", streak)
                    if streak >= 2:
                        st["mode"] = "SWITCHING"
                        save_state(st, backup_first=True)
                        disable_gemini_warp()
                        e2e, non_warp = verify_unmarked_connectivity()
                        st["mode"] = "DIRECT"
                        st["last_valid_mode"] = "DIRECT"
                        st["direct_recover_streak"] = 0
                        st["last_error"] = ""
                        LOG.info(
                            "直连连续两次独立确认恢复，已关闭三域名 WARP 分流回归 DIRECT (全局 WARP 与 extra.list 保持运行) | 验证=%s | 非WARP=%s",
                            {k: v["category"] for k, v in e2e.items()}, non_warp,
                        )
                else:
                    if st.get("direct_recover_streak", 0) != 0:
                        LOG.info("直连探测未通过(%s)，连续成功计数归零，保持 WARP", d_verdict)
                    st["direct_recover_streak"] = 0

            wait_sec = CFG["MIN_INTERVAL"] + secrets.randbelow(CFG["MAX_INTERVAL"] - CFG["MIN_INTERVAL"] + 1)
            end_ts = time.time()
            st["last_check_end"] = now_iso(end_ts)
            st["last_wait_seconds"] = wait_sec
            st["next_check_at"] = now_iso(end_ts + wait_sec)
            save_state(st, backup_first=False)
            LOG.info(
                "======== 第 %d 轮检测结束 | 当前状态=%s | 连续直连正常=%d | 下轮随机等待=%d 秒(约 %.1f 分钟) | 预计下轮=%s ========",
                rid, st["mode"], st["direct_recover_streak"], wait_sec, wait_sec / 60.0, st["next_check_at"],
            )
    return 0


def handle_sigterm(signum, frame):
    global STOP_REQUESTED
    STOP_REQUESTED = True


def run_daemon():
    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)
    restore_boot_state()
    while not STOP_REQUESTED:
        try:
            run_check_round()
        except Exception as exc:
            LOG.exception("检测轮次发生未捕获异常: %s", exc)
        st = load_state()
        wait_sec = int(st.get("last_wait_seconds") or 0)
        if wait_sec < CFG["MIN_INTERVAL"] or wait_sec > CFG["MAX_INTERVAL"]:
            wait_sec = CFG["MIN_INTERVAL"] + secrets.randbelow(CFG["MAX_INTERVAL"] - CFG["MIN_INTERVAL"] + 1)
        slept = 0
        while slept < wait_sec and not STOP_REQUESTED:
            step = min(5, wait_sec - slept)
            time.sleep(step)
            slept += step


def cmd_status():
    st = load_state()
    print(json.dumps(st, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    sub = sys.argv[1] if len(sys.argv) > 1 else "status"
    if sub == "daemon":
        run_daemon()
    elif sub == "once":
        sys.exit(run_check_round())
    elif sub == "restore":
        restore_boot_state()
    elif sub == "status":
        cmd_status()
    else:
        print(f"Unknown command: {sub}", file=sys.stderr)
        sys.exit(1)
MGR_EOF
    chmod 755 "$LIB_DIR/gemini_mgr.py"
}

write_engine() {
    mkdir -p "$CONF_DIR" "$LIB_DIR" "$LOG_DIR"
    write_python_modules
    cat > "$ENGINE" << 'ENGINE_EOF'
#!/usr/bin/env bash
# WARP-GOOGLE-ENGINE v2.3
# extra.list 非 Google 分流走 WARP_GOOGLE + redsocks(12345) + WARP_GOOGLE_X6(IPv6回落)
# Gemini 三域名由 gemini_mgr.py + sni_proxy.py 精准动态管理

CONF_DIR=/etc/warp-google
LIB_DIR=/usr/local/lib/warp-google
LOG_DIR=/var/log/warp-google
BACKUP_BASE=/var/backups/warp-google
# shellcheck disable=SC1091
[ -f "$CONF_DIR/warp-google.conf" ] && . "$CONF_DIR/warp-google.conf"
PROXY_PORT=${PROXY_PORT:-40000}
REDIR_PORT=${REDIR_PORT:-12345}
SNI_PORT=${SNI_PORT:-12350}
DIRECT_MARK=${DIRECT_MARK:-0x5752}
BLOCK_IPV6=${BLOCK_IPV6:-1}

CHAIN=WARP_GOOGLE         # nat/OUTPUT : extra.list TCP 重定向到 redsocks
CHAIN_F=WARP_GOOGLE_F     # filter/OUTPUT : extra.list 拒绝 UDP 443
CHAIN_X6=WARP_GOOGLE_X6   # ip6tables filter/OUTPUT : 仅对 extra.list 域名阻断 IPv6，强制回落 IPv4
CHAIN_6=WARP_GOOGLE6      # v2.0 遗留 Google IPv6 屏蔽链(v2.3 清理)
CHAIN_G=WARP_GEMINI       # nat/OUTPUT : Gemini 三域名 IP 重定向到 SNI 分发器
CHAIN_GF=WARP_GEMINI_F    # filter/OUTPUT : Gemini 三域名 IP 拒绝 UDP 443
CHAIN_G6=WARP_GEMINI6     # ip6tables filter/OUTPUT : 仅三域名 AAAA(仅 WARP 模式挂载)

STATE_DIR=/run/warp-google
GEMINI_HOSTS="gemini.google.com aistudio.google.com generativelanguage.googleapis.com"
EXCLUDES="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"
EXCLUDES_GEMINI="$EXCLUDES 162.159.0.0/16 188.114.96.0/20"
WARP_DOMAINS="api.cloudflareclient.com engage.cloudflareclient.com connectivity.cloudflareclient.com zero-trust-client.cloudflareclient.com"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
say()  { echo -e "$*"; }
log()  { echo "$*"; logger -t warp-google "$*" 2>/dev/null; return 0; }

wcli() { timeout 15 warp-cli --accept-tos "$@"; }
is_connected() { wcli status 2>/dev/null | grep -Eq 'Status update:[[:space:]]*Connected'; }

wait_daemon() {
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

ensure_proxy_mode() {
    wcli mode proxy >/dev/null 2>&1 || wcli set-mode proxy >/dev/null 2>&1 || return 1
    wcli proxy port "$PROXY_PORT" >/dev/null 2>&1 || wcli set-proxy-port "$PROXY_PORT" >/dev/null 2>&1 || return 1
    return 0
}

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

proxy_ok() {
    curl -s -m 8 --socks5-hostname "127.0.0.1:${PROXY_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -Eq '^warp=(on|plus)'
}
wait_proxy() { local i; for i in $(seq 1 "${1:-20}"); do proxy_ok && return 0; sleep 2; done; return 1; }
redsocks_ok() { systemctl is-active --quiet warp-redsocks; }

cmd_setup_warp() {
    systemctl enable --now warp-svc >/dev/null 2>&1
    wait_daemon 40 || { say "${RED}✗ warp-svc 未能启动 (查看: journalctl -u warp-svc -n 50)${NC}"; return 1; }
    wcli disconnect >/dev/null 2>&1
    ensure_registered || { say "${RED}✗ WARP 设备注册失败${NC}"; return 1; }
    ensure_proxy_mode || { say "${RED}✗ 无法切换到代理模式，已中止且不会连接 WARP${NC}"; return 1; }
    say "${GREEN}✓ 已确认代理模式 (SOCKS5 127.0.0.1:${PROXY_PORT})，开始连接...${NC}"
    connect_wait || { say "${RED}✗ WARP 连接超时${NC}"; return 1; }
    guard_no_fulltunnel || { say "${RED}✗ 检测到全局隧道网卡，已紧急断开${NC}"; return 1; }
    wait_proxy 15 || { say "${RED}✗ WARP 已连接但代理不通${NC}"; return 1; }
    return 0
}

extra_list_sig() {
    stat -c '%Y:%s' "$CONF_DIR/extra.list" 2>/dev/null || echo "none"
}

collect_targets() {
    local f="$CONF_DIR/extra.list" line sig prev_sig cache="$STATE_DIR/extra-ips.cache" sigf="$STATE_DIR/extra-ips.sig"
    [ -f "$f" ] || return 0
    mkdir -p "$STATE_DIR"
    sig=$(extra_list_sig)
    prev_sig=$(cat "$sigf" 2>/dev/null || echo "")
    if [ "$sig" != "$prev_sig" ]; then
        rm -f "$cache"
        echo "$sig" > "$sigf"
    fi

    {
        [ -f "$cache" ] && cat "$cache"
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"; line="${line//[[:space:]]/}"
            [ -z "$line" ] && continue
            if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                echo "$line"
            elif [[ "$line" =~ ^[A-Za-z0-9._-]+$ ]]; then
                getent ahostsv4 "$line" 2>/dev/null | awk '{print $1}'
                getent ahostsv4 "$line" 2>/dev/null | awk '{print $1}'
                command -v dig >/dev/null 2>&1 && dig +short +time=2 +tries=1 A "$line" 2>/dev/null
            fi
        done < "$f"
    } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' | sort -u | tee "$cache"
}

collect_extra_v6() {
    local f="$CONF_DIR/extra.list" line
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ ]] && [[ "$line" == *:* ]]; then
            echo "$line"
        elif [[ "$line" =~ ^[A-Za-z0-9._-]+$ ]]; then
            getent ahostsv6 "$line" 2>/dev/null | awk '{print $1}'
        fi
    done | grep -E '^[0-9a-fA-F:]+(/[0-9]+)?$' | sort -u
}

collect_gemini_v4() {
    local d i
    mkdir -p "$STATE_DIR"
    {
        [ -f "$STATE_DIR/gemini-ips.cache" ] && cat "$STATE_DIR/gemini-ips.cache"
        for i in 1 2; do
            for d in $GEMINI_HOSTS; do
                getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}'
            done
        done
    } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | tee "$STATE_DIR/gemini-ips.cache"
}

collect_gemini_v6() {
    local d
    for d in $GEMINI_HOSTS; do
        getent ahostsv6 "$d" 2>/dev/null | awk '{print $1}'
    done | grep -E '^[0-9a-fA-F:]+$' | sort -u
}

warp_endpoints() {
    local d ep
    for d in $WARP_DOMAINS; do getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}'; done
    ep=$(timeout 5 warp-cli --accept-tos settings 2>/dev/null | awk -F: '/[Ee]ndpoint/ {gsub(/[[:space:]]/,"",$2); print $2}' | head -n1)
    [[ "$ep" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ep"
}

restore() { local bin=$1 file=$2; "$bin" -w --noflush < "$file" 2>/dev/null || "$bin" --noflush < "$file"; }
has_v6() { [ -r /proc/net/if_inet6 ] && command -v ip6tables-restore >/dev/null 2>&1 && ip6tables -w -L -n >/dev/null 2>&1; }
has_v4_default() { [ -n "$(ip -4 route show default 2>/dev/null)" ]; }

rules_present() { iptables -w -t nat -C OUTPUT -p tcp -j "$CHAIN" 2>/dev/null; }
gemini_rules_present() { iptables -w -t nat -C OUTPUT -p tcp -j "$CHAIN_G" 2>/dev/null; }

drop_chain() {
    local bin=$1 table=$2 chain=$3; shift 3
    command -v "$bin" >/dev/null 2>&1 || return 0
    while "$bin" -w -t "$table" -D OUTPUT "$@" -j "$chain" 2>/dev/null; do :; done
    "$bin" -w -t "$table" -F "$chain" 2>/dev/null
    "$bin" -w -t "$table" -X "$chain" 2>/dev/null
    return 0
}

rules_on() {
    command -v iptables-restore >/dev/null 2>&1 || { say "${RED}缺少 iptables-restore${NC}"; return 1; }
    local f4 ff fx6 targets targets6 eps n t t6
    targets=$(collect_targets)
    if [ -z "$targets" ]; then
        rules_off_extra
        return 0
    fi
    f4=$(mktemp); ff=$(mktemp); fx6=$(mktemp)
    eps=$(warp_endpoints | sort -u)

    { echo "*nat"; echo ":$CHAIN - [0:0]"
      echo "-A $CHAIN -m mark --mark $DIRECT_MARK -j RETURN"
      for n in $EXCLUDES $eps; do echo "-A $CHAIN -d $n -j RETURN"; done
      for t in $targets; do echo "-A $CHAIN -p tcp -d $t -j REDIRECT --to-ports $REDIR_PORT"; done
      echo "COMMIT"; } > "$f4"

    { echo "*filter"; echo ":$CHAIN_F - [0:0]"
      echo "-A $CHAIN_F -m mark --mark $DIRECT_MARK -j RETURN"
      for n in $EXCLUDES $eps; do echo "-A $CHAIN_F -d $n -j RETURN"; done
      for t in $targets; do echo "-A $CHAIN_F -p udp --dport 443 -d $t -j REJECT --reject-with icmp-port-unreachable"; done
      echo "COMMIT"; } > "$ff"

    if ! restore iptables-restore "$f4"; then
        rm -f "$f4" "$ff" "$fx6"
        say "${RED}写入 WARP_GOOGLE nat 规则失败${NC}"; return 1
    fi
    restore iptables-restore "$ff" || say "${YELLOW}! extra.list QUIC 拦截规则写入失败${NC}"

    iptables -w -t nat -C OUTPUT -p tcp -j "$CHAIN" 2>/dev/null || iptables -w -t nat -I OUTPUT 1 -p tcp -j "$CHAIN"
    iptables -w -C OUTPUT -p udp --dport 443 -j "$CHAIN_F" 2>/dev/null || iptables -w -I OUTPUT 1 -p udp --dport 443 -j "$CHAIN_F" 2>/dev/null

    if [ "$BLOCK_IPV6" = 1 ] && has_v6 && has_v4_default; then
        targets6=$(collect_extra_v6)
        if [ -n "$targets6" ]; then
            { echo "*filter"; echo ":$CHAIN_X6 - [0:0]"
              echo "-A $CHAIN_X6 -m mark --mark $DIRECT_MARK -j RETURN"
              for t6 in $targets6; do
                  echo "-A $CHAIN_X6 -d $t6 -p tcp -j REJECT --reject-with tcp-reset"
                  echo "-A $CHAIN_X6 -d $t6 -p udp -j REJECT --reject-with icmp6-port-unreachable"
              done
              echo "COMMIT"; } > "$fx6"
            if restore ip6tables-restore "$fx6"; then
                ip6tables -w -C OUTPUT -j "$CHAIN_X6" 2>/dev/null || ip6tables -w -I OUTPUT 1 -j "$CHAIN_X6"
            fi
        else
            drop_chain ip6tables filter "$CHAIN_X6"
        fi
    fi

    rm -f "$f4" "$ff" "$fx6"
    mkdir -p "$STATE_DIR"; date +%s > "$STATE_DIR/refresh"
    return 0
}

rules_off_extra() {
    drop_chain iptables  nat    "$CHAIN"    -p tcp
    drop_chain iptables  nat    "$CHAIN"
    drop_chain iptables  filter "$CHAIN_F"  -p udp --dport 443
    drop_chain ip6tables filter "$CHAIN_X6"
    drop_chain ip6tables filter "$CHAIN_6"
    rm -f "$STATE_DIR/refresh" "$STATE_DIR/extra-ips.cache" "$STATE_DIR/extra-ips.sig"
    return 0
}

gemini_rules_on() {
    command -v iptables-restore >/dev/null 2>&1 || return 1
    local f4 ff f6 targets eps n t t6 targets6
    targets=$(collect_gemini_v4)
    if [ -z "$targets" ]; then
        say "${RED}无法解析 Gemini 三域名 IPv4${NC}"; return 1
    fi
    f4=$(mktemp); ff=$(mktemp); f6=$(mktemp)
    eps=$(warp_endpoints | sort -u)

    { echo "*nat"; echo ":$CHAIN_G - [0:0]"
      echo "-A $CHAIN_G -m mark --mark $DIRECT_MARK -j RETURN"
      for n in $EXCLUDES_GEMINI $eps; do echo "-A $CHAIN_G -d $n -j RETURN"; done
      for t in $targets; do
          echo "-A $CHAIN_G -p tcp --dport 443 -d $t -j REDIRECT --to-ports $SNI_PORT"
          echo "-A $CHAIN_G -p tcp --dport 80 -d $t -j REDIRECT --to-ports $SNI_PORT"
      done
      echo "COMMIT"; } > "$f4"

    { echo "*filter"; echo ":$CHAIN_GF - [0:0]"
      echo "-A $CHAIN_GF -m mark --mark $DIRECT_MARK -j RETURN"
      for n in $EXCLUDES_GEMINI $eps; do echo "-A $CHAIN_GF -d $n -j RETURN"; done
      for t in $targets; do echo "-A $CHAIN_GF -p udp --dport 443 -d $t -j REJECT --reject-with icmp-port-unreachable"; done
      echo "COMMIT"; } > "$ff"

    if ! restore iptables-restore "$f4"; then
        rm -f "$f4" "$ff" "$f6"
        say "${RED}写入 WARP_GEMINI nat 规则失败(需要 xt_mark 与 nat 模块)${NC}"; return 1
    fi
    restore iptables-restore "$ff" || say "${YELLOW}! WARP_GEMINI QUIC 拦截规则写入失败${NC}"
    iptables -w -t nat -C OUTPUT -p tcp -j "$CHAIN_G" 2>/dev/null || iptables -w -t nat -I OUTPUT 1 -p tcp -j "$CHAIN_G"
    iptables -w -C OUTPUT -p udp --dport 443 -j "$CHAIN_GF" 2>/dev/null || iptables -w -I OUTPUT 1 -p udp --dport 443 -j "$CHAIN_GF" 2>/dev/null

    if [ "$BLOCK_IPV6" = 1 ] && has_v6 && has_v4_default; then
        targets6=$(collect_gemini_v6)
        if [ -n "$targets6" ]; then
            { echo "*filter"; echo ":$CHAIN_G6 - [0:0]"
              echo "-A $CHAIN_G6 -m mark --mark $DIRECT_MARK -j RETURN"
              for t6 in $targets6; do
                  echo "-A $CHAIN_G6 -d $t6 -p tcp -j REJECT --reject-with tcp-reset"
                  echo "-A $CHAIN_G6 -d $t6 -p udp -j REJECT --reject-with icmp6-port-unreachable"
              done
              echo "COMMIT"; } > "$f6"
            if restore ip6tables-restore "$f6"; then
                ip6tables -w -C OUTPUT -j "$CHAIN_G6" 2>/dev/null || ip6tables -w -I OUTPUT 1 -j "$CHAIN_G6"
            fi
        fi
    fi
    rm -f "$f4" "$ff" "$f6"
    return 0
}

gemini_rules_off() {
    drop_chain iptables  nat    "$CHAIN_G"  -p tcp
    drop_chain iptables  filter "$CHAIN_GF" -p udp --dport 443
    drop_chain ip6tables filter "$CHAIN_G6"
    rm -f "$STATE_DIR/gemini-ips.cache"
    return 0
}

rules_off() {
    gemini_rules_off
    rules_off_extra
}

cmd_boot() {
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
        rules_on && say "${GREEN}✓ 全局 WARP 与 extra.list 规则已启用${NC}" || say "${YELLOW}! extra.list 规则未启用，看门狗将重试${NC}"
    else
        say "${YELLOW}! WARP 暂不可用，extra.list 规则暂未挂载${NC}"
    fi
    return 0
}

cmd_check() {
    mkdir -p "$STATE_DIR"
    # 若 Gemini 管理器正在执行检测/切换/Endpoint 轮换，跳过本轮看门狗以免与 wcli disconnect/connect 发生竞态
    exec 8>"$STATE_DIR/gemini-check.lock"
    if ! flock -n 8; then
        return 0
    fi

    local n last now
    if proxy_ok && redsocks_ok; then
        rm -f "$STATE_DIR/fail"
        if ! rules_present; then
            rules_on && log "WARP 恢复，extra.list 分流规则已重新启用"
        else
            last=$(cat "$STATE_DIR/refresh" 2>/dev/null || echo 0); now=$(date +%s)
            [ $((now - last)) -ge 300 ] && rules_on
        fi
        exec 9>"$STATE_DIR/gemini-state.lock"
        if flock -n 9; then
            if gemini_rules_present; then
                gemini_rules_on >/dev/null 2>&1 || true
            fi
            flock -u 9
        fi
    else
        n=$(( $(cat "$STATE_DIR/fail" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE_DIR/fail"
        redsocks_ok || systemctl restart warp-redsocks >/dev/null 2>&1
        if ! is_connected; then
            ensure_proxy_mode && wcli connect >/dev/null 2>&1
        fi
        if [ "$n" -ge 2 ]; then
            rules_present && { rules_off_extra; log "WARP/redsocks 不可用，已摘除 extra.list 规则故障放行"; }
            exec 9>"$STATE_DIR/gemini-state.lock"
            if flock -n 9; then
                gemini_rules_present && { gemini_rules_off; systemctl stop warp-sni >/dev/null 2>&1; log "WARP 不可用，已临时摘除 Gemini WARP 规则故障放行"; }
                flock -u 9
            fi
        fi
    fi
    flock -u 8
    return 0
}

cmd_start()   { systemctl restart warp-google; systemctl restart warp-gemini; }
cmd_stop()    {
    systemctl stop warp-gemini >/dev/null 2>&1
    systemctl stop warp-google-watchdog.timer >/dev/null 2>&1
    systemctl stop warp-google >/dev/null 2>&1
    rules_off
    systemctl stop warp-sni >/dev/null 2>&1
    systemctl stop warp-redsocks >/dev/null 2>&1
    wcli disconnect >/dev/null 2>&1
    say "${GREEN}✓ 已停止并移除全部规则${NC}"
}
cmd_restart() { cmd_stop; sleep 2; cmd_start; }

geo() {
    local j; j=$(curl -s -m 5 "http://ip-api.com/json/$1?lang=zh-CN" 2>/dev/null)
    echo "$(echo "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p') - $(echo "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')"
}
get_ip() {
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

first_extra_domain() {
    [ -f "$CONF_DIR/extra.list" ] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$CONF_DIR/extra.list" | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' | head -n1
}

cmd_test() {
    local code hits_extra hits_gemini test_extra
    say "${CYAN}── 连通性及精准分流测试 ──${NC}"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204)
    [ "$code" = 204 ] && say "${GREEN}✓ www.google.com (generate_204): $code (保持非 WARP 原有出口)${NC}" || say "${RED}✗ www.google.com: ${code:-无响应}${NC}"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://accounts.google.com/)
    say "  accounts.google.com 状态码: ${code:-无响应} (保持非 WARP 原有出口)"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://gemini.google.com/)
    say "  gemini.google.com 状态码: ${code:-无响应}"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://aistudio.google.com/)
    say "  aistudio.google.com 状态码: ${code:-无响应}"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://generativelanguage.googleapis.com/v1beta/models)
    say "  generativelanguage.googleapis.com 状态码: ${code:-无响应}"
    proxy_ok && say "${GREEN}✓ 全局 WARP 代理: warp=on${NC}" || say "${RED}✗ 全局 WARP 代理不可用${NC}"
    redsocks_ok && say "${GREEN}✓ redsocks 服务: 运行中 (127.0.0.1:${REDIR_PORT})${NC}" || say "${RED}✗ redsocks 未运行${NC}"
    if rules_present; then
        test_extra=$(first_extra_domain)
        [ -n "$test_extra" ] && curl -s -m 8 -o /dev/null "https://$test_extra/" >/dev/null 2>&1 || true
        hits_extra=$(iptables -w -t nat -L "$CHAIN" -nv 2>/dev/null | awk '/REDIRECT/ && $1+0>0 {c++} END{print c+0}')
        say "  extra.list nat 规则(WARP_GOOGLE): ${GREEN}已挂载${NC} (共 $(iptables -w -t nat -S "$CHAIN" 2>/dev/null | grep -c REDIRECT) 条, 已命中规则数: $hits_extra)"
    else
        say "${RED}  extra.list nat 规则(WARP_GOOGLE): 未启用${NC}"
    fi
    if gemini_rules_present; then
        hits_gemini=$(iptables -w -t nat -L "$CHAIN_G" -nv 2>/dev/null | awk '/REDIRECT/ && $1+0>0 {c++} END{print c+0}')
        say "  Gemini 精准 nat 规则(WARP_GEMINI): 已启用, 已命中规则数: $hits_gemini"
        [ -f "$STATE_DIR/sni-stats.json" ] && say "  SNI 分发统计: $(cat "$STATE_DIR/sni-stats.json")"
    else
        say "  Gemini 精准 nat 规则(WARP_GEMINI): 未启用 (当前走 DIRECT 直连)"
    fi
}

cmd_status() {
    say "${CYAN}══════════ WARP & Gemini 状态 ══════════${NC}"
    say "${YELLOW}【WARP 客户端】${NC}"
    command -v warp-cli >/dev/null 2>&1 || { say "${RED}未安装${NC}"; return 1; }
    wcli status 2>&1 | head -3
    wcli settings 2>/dev/null | grep -iE 'mode|endpoint' | head -3
    say "${YELLOW}【服务】${NC}"
    local s
    for s in warp-svc warp-redsocks warp-google warp-google-watchdog.timer warp-sni warp-gemini; do
        printf '  %-28s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
    done
    say "${YELLOW}【WARP 代理】${NC}"
    proxy_ok && say "  ${GREEN}正常 (warp=on)${NC}" || say "  ${RED}不可用${NC}"
    say "${YELLOW}【非 Google 分流规则 (extra.list -> WARP_GOOGLE)】${NC}"
    if rules_present; then
        say "  ${GREEN}已启用${NC}: $(iptables -w -t nat -S "$CHAIN" 2>/dev/null | grep -c REDIRECT) 条 IPv4 重定向规则 (IPv6回落链: $(ip6tables -w -C OUTPUT -j "$CHAIN_X6" 2>/dev/null && echo '已启用' || echo '未启用/无AAAA'))"
    else
        say "  ${RED}未启用${NC}"
    fi
    say "${YELLOW}【Gemini 精准动态分流 (WARP_GEMINI -> SNI 精确匹配)】${NC}"
    if gemini_rules_present; then
        say "  ${GREEN}WARP 模式已启用${NC}: $(iptables -w -t nat -S "$CHAIN_G" 2>/dev/null | grep -c REDIRECT) 条重定向规则"
    else
        say "  ${CYAN}DIRECT 直连模式${NC} (未挂载 Gemini 劫持规则)"
    fi
    say "${YELLOW}【Gemini 状态机详情】${NC}"
    python3 "$LIB_DIR/gemini_mgr.py" status 2>/dev/null || say "  尚无状态记录"
}

cmd_update() {
    say "${YELLOW}! v2.3 中 Gemini 采用三域名 SNI 精准动态匹配，google.list/google6.list 不再用于路由。${NC}"
    return 0
}

cleanup_legacy() {
    systemctl stop warp-google-watchdog.timer warp-redsocks warp-sni >/dev/null 2>&1
    rules_off
    while iptables -w -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null; do :; done
    ip -6 route del blackhole 2607:f8b0::/32 >/dev/null 2>&1
    [ -f /etc/gai.conf ] && sed -i '/^precedence ::ffff:0:0\/96  100$/d' /etc/gai.conf
    systemctl disable --now redsocks >/dev/null 2>&1
    pkill -x redsocks >/dev/null 2>&1
    return 0
}

cmd_rescue() {
    systemctl stop warp-gemini >/dev/null 2>&1
    systemctl stop warp-google-watchdog.timer >/dev/null 2>&1
    rules_off
    cleanup_legacy
    systemctl stop warp-sni >/dev/null 2>&1
    systemctl stop warp-redsocks >/dev/null 2>&1
    if command -v warp-cli >/dev/null 2>&1; then
        wcli disconnect >/dev/null 2>&1
        wcli mode proxy >/dev/null 2>&1 || wcli set-mode proxy >/dev/null 2>&1
    fi
    if ip link show CloudflareWARP >/dev/null 2>&1; then
        systemctl stop warp-svc >/dev/null 2>&1
    fi
    say "${GREEN}✓ 已恢复: 规则已全部移除，WARP 已断开${NC}"
}

cmd_rollback() {
    local bdir
    bdir=$(readlink -f "$BACKUP_BASE/latest" 2>/dev/null)
    [ -d "$bdir" ] || { say "${RED}未找到可用备份: $BACKUP_BASE/latest${NC}"; return 1; }
    say "${YELLOW}正在从备份恢复: $bdir${NC}"
    cmd_stop >/dev/null 2>&1
    [ -d "$bdir/conf" ] && cp -a "$bdir/conf/." "$CONF_DIR/"
    [ -f "$bdir/warp-google.bin" ] && cp -a "$bdir/warp-google.bin" "$ENGINE" && chmod 755 "$ENGINE"
    if ls "$bdir/systemd/"warp-* >/dev/null 2>&1; then
        rm -f /etc/systemd/system/warp-sni.service /etc/systemd/system/warp-gemini.service
        cp -a "$bdir/systemd/"warp-* /etc/systemd/system/
        systemctl daemon-reload
    fi
    say "${GREEN}✓ 配置与服务文件已回滚至 $bdir，请执行 warp start 重新启动${NC}"
}

cmd_uninstall() {
    say "${YELLOW}正在卸载...${NC}"
    cmd_rescue >/dev/null 2>&1
    command -v warp-cli >/dev/null 2>&1 && wcli registration delete >/dev/null 2>&1
    systemctl disable --now warp-gemini.service warp-sni.service warp-google.service warp-google-watchdog.timer warp-redsocks.service >/dev/null 2>&1
    systemctl disable --now warp-svc >/dev/null 2>&1
    rm -f /etc/systemd/system/warp-google.service /etc/systemd/system/warp-redsocks.service \
          /etc/systemd/system/warp-sni.service /etc/systemd/system/warp-gemini.service \
          /etc/systemd/system/warp-google-watchdog.service /etc/systemd/system/warp-google-watchdog.timer \
          /etc/logrotate.d/warp-google
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
    rm -rf "$CONF_DIR" "$LIB_DIR" "$LOG_DIR" "$STATE_DIR" /etc/redsocks.conf.warp-bak
    [ "$(readlink -f /usr/local/bin/warp 2>/dev/null)" = "$(readlink -f "$0")" ] && rm -f /usr/local/bin/warp
    say "${GREEN}✓ WARP 已完全卸载 (备份保留于 $BACKUP_BASE)${NC}"
    rm -f /usr/local/bin/warp-google
    exit 0
}

usage() {
    cat << EOF
WARP 管理工具 v2.3

用法: warp <命令>

  status         查看全局 WARP、extra.list 与 Gemini 动态分流状态
  start          启动全部服务与 Gemini 随机检测守护
  stop           停止全部服务并移除规则
  restart        重启服务 (修改 extra.list / endpoints.list 后执行)
  test           测试非 Google/非 WARP 域名、extra.list 与 Gemini 连通性
  ip             对比直连 IP 与 WARP IP
  gemini-status  查看 Gemini 状态机 JSON 详情
  gemini-check   立即执行一轮带锁的 Gemini 健康检测
  gemini-logs    实时查看 Gemini 检测日志 (保留 7 天)
  rescue         紧急恢复: 移除全部规则并断开 WARP
  rollback       从最近备份回滚脚本与配置
  uninstall      完全卸载

配置目录: $CONF_DIR (extra.list, endpoints.list, gemini-state.json)
EOF
}

case "${1:-}" in
    boot)              cmd_boot ;;
    check)             cmd_check ;;
    start)             cmd_start ;;
    stop)              cmd_stop ;;
    restart)           cmd_restart ;;
    status)            cmd_status ;;
    test)              cmd_test ;;
    ip)                cmd_ip ;;
    update)            cmd_update ;;
    rescue)            cmd_rescue ;;
    rollback)          cmd_rollback ;;
    uninstall)         cmd_uninstall ;;
    rules-on)          rules_on ;;
    rules-off)         rules_off ;;
    gemini-rules-on)   gemini_rules_on ;;
    gemini-rules-off)  gemini_rules_off ;;
    gemini-status)     python3 "$LIB_DIR/gemini_mgr.py" status ;;
    gemini-check)      python3 "$LIB_DIR/gemini_mgr.py" once ;;
    gemini-logs)       tail -n 100 -f "$LOG_DIR/gemini.log" ;;
    ensure-proxy-mode) ensure_proxy_mode ;;
    setup-warp)        cmd_setup_warp ;;
    cleanup-legacy)    cleanup_legacy ;;
    *)                 usage ;;
esac
ENGINE_EOF
    chmod 755 "$ENGINE"
}

write_config() {
    mkdir -p "$CONF_DIR" "$LOG_DIR"
    # 移除可能与 Python TimedRotatingFileHandler 冲突的外部 logrotate 规则
    rm -f /etc/logrotate.d/warp-google

    cat > "$CONF_DIR/warp-google.conf" << EOF
PROXY_PORT=$PROXY_PORT
REDIR_PORT=$REDIR_PORT
SNI_PORT=$SNI_PORT
DIRECT_MARK=$DIRECT_MARK
BLOCK_IPV6=1
REDSOCKS_BIN=$REDSOCKS_BIN
REDSOCKS_SRC=$REDSOCKS_SRC
MIN_INTERVAL=1800
MAX_INTERVAL=3600
MAX_ENDPOINT_TRIES=5
ENDPOINT_RETRY_SLEEP=5
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

    [ -f "$CONF_DIR/endpoints.list" ] || cat > "$CONF_DIR/endpoints.list" << 'EOF'
# Cloudflare WARP 候选 Endpoint 列表（每行一个 IP:Port 或 default）
162.159.192.1:2408
162.159.193.10:2408
162.159.195.1:500
188.114.96.1:2408
188.114.97.10:1701
188.114.98.1:4500
188.114.99.10:2408
default
EOF

    [ -f "$CONF_DIR/extra.list" ] || cat > "$CONF_DIR/extra.list" << 'EOF'
# 其它需要走 WARP 的站点: 每行一个 域名 或 IPv4/CIDR。域名会在启动时解析并每 5 分钟刷新。
# 不需要的整行删掉或在行首加 # ；修改后执行 `warp restart` 生效。

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
gamer.com.tw
www.gamer.com.tw
54.172.97.0/22
23.255.155.0/24
# 52.5.0.0/16
# 37.19.0.0/16
EOF
}

preflight() {
    [ -n "$(ip -4 route show default 2>/dev/null)" ] || die "本机没有 IPv4 默认路由，纯 IPv6 VPS 不适用本脚本"
    ensure_tools
}

ensure_tools() {
    local need=()
    command -v curl     >/dev/null 2>&1 || need+=(curl)
    command -v iptables >/dev/null 2>&1 || need+=(iptables)
    command -v python3  >/dev/null 2>&1 || need+=(python3)
    command -v gpg      >/dev/null 2>&1 || { [ "$PKG" = apt ] && need+=(gnupg); }
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        [ "$PKG" = apt ] && apt-get update -y >/dev/null 2>&1
        pkg_install "${need[@]}" >/dev/null 2>&1 || die "依赖安装失败: ${need[*]}"
    fi
    iptables -w -t nat -L -n >/dev/null 2>&1 || die "iptables nat 表不可用，无法使用透明代理"
    iptables -w -t nat -N WARP_MARK_TEST 2>/dev/null || true
    if ! iptables -w -t nat -A WARP_MARK_TEST -m mark --mark "$DIRECT_MARK" -j RETURN >/dev/null 2>&1; then
        iptables -w -t nat -X WARP_MARK_TEST 2>/dev/null || true
        die "内核缺少 xt_mark (-m mark) 模块，无法保证安全旁路与精确 SNI 分流"
    fi
    iptables -w -t nat -F WARP_MARK_TEST 2>/dev/null || true
    iptables -w -t nat -X WARP_MARK_TEST 2>/dev/null || true
}

pick_codename() {
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
    "$ENGINE" setup-warp || die "WARP 配置失败。可用 '$ENGINE rescue' 清理。"
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
            build_redsocks || die "redsocks 安装失败"
        fi
    fi
    REDSOCKS_BIN=$(command -v redsocks)
    systemctl disable --now redsocks >/dev/null 2>&1
    ok "redsocks: $REDSOCKS_BIN"
}

pick_ports() {
    local p
    for p in 12345 12346 12347 12348 12349; do
        if ! ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then REDIR_PORT=$p; break; fi
    done
    for p in 12350 12351 12352 12353 12354; do
        if ! ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then SNI_PORT=$p; return 0; fi
    done
    die "12345-12354 端口被占用"
}

write_units() {
    cat > /etc/systemd/system/warp-redsocks.service << EOF
[Unit]
Description=redsocks transparent proxy (WARP extra.list)
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

    cat > /etc/systemd/system/warp-sni.service << EOF
[Unit]
Description=WARP Gemini exact SNI/Host dispatcher
After=network-online.target warp-svc.service
BindsTo=warp-svc.service

[Service]
Type=simple
ExecStart=/usr/bin/env python3 $LIB_DIR/sni_proxy.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/warp-google.service << EOF
[Unit]
Description=WARP global proxy & extra.list routing rules
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
Description=WARP extra.list watchdog

[Service]
Type=oneshot
ExecStart=$ENGINE check
EOF

    cat > /etc/systemd/system/warp-google-watchdog.timer << EOF
[Unit]
Description=WARP extra.list watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/warp-gemini.service << EOF
[Unit]
Description=WARP Gemini Direct-First Dynamic Router & Random Scheduler (30-60m)
After=network-online.target warp-svc.service warp-google.service
Wants=network-online.target warp-google.service

[Service]
Type=simple
ExecStart=/usr/bin/env python3 $LIB_DIR/gemini_mgr.py daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-svc warp-redsocks warp-google warp-google-watchdog.timer warp-gemini >/dev/null 2>&1
    systemctl disable warp-sni >/dev/null 2>&1 || true
}

setup_proxy_rules() {
    info "\n[4/4] 配置非 Google 分流规则与 Gemini 默认直连动态调度..."
    write_config
    write_units
    systemctl restart warp-redsocks
    sleep 1
    systemctl is-active --quiet warp-redsocks || { journalctl -u warp-redsocks -n 15 --no-pager; die "redsocks 启动失败"; }
    systemctl restart warp-google
    if ! iptables -w -t nat -C OUTPUT -p tcp -j WARP_GOOGLE 2>/dev/null; then
        warn "首次启动未自动挂载 WARP_GOOGLE，尝试显式应用并输出日志..."
        "$ENGINE" rules-on || { journalctl -u warp-google -n 20 --no-pager; die "extra.list 规则挂载失败"; }
    fi
    systemctl start warp-google-watchdog.timer
    systemctl restart warp-gemini

    if [ -e "$SHORTCUT" ] && ! grep -q 'WARP-GOOGLE-ENGINE' "$SHORTCUT" 2>/dev/null && [ ! -L "$SHORTCUT" ]; then
        warn "$SHORTCUT 已被其它程序占用，请使用 warp-google"
    else
        ln -sf "$ENGINE" "$SHORTCUT"
    fi
}

do_install() {
    detect_env
    trap '' HUP
    preflight
    info "\n备份现有脚本与配置..."
    backup_existing
    info "清理旧版全局 Google 劫持链..."
    write_engine
    "$ENGINE" cleanup-legacy
    pick_ports
    install_warp_pkg
    configure_warp
    install_redsocks
    setup_proxy_rules

    sleep 3
    echo
    "$ENGINE" test
    echo
    ok "安装/更新完成！extra.list 走 WARP 已校验，Gemini 默认为 DIRECT 直连。"
    echo -e "日志查看: ${CYAN}warp gemini-logs${NC}  |  状态查看: ${CYAN}warp status${NC}  |  回滚: ${CYAN}warp rollback${NC}"
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

show_menu() {
    local choice
    while true; do
        echo -e "${YELLOW}请选择操作:${NC}\n"
        echo -e "  ${GREEN}1.${NC} 安装 / 增量升级 WARP (v2.3 稳定版)"
        echo -e "  ${GREEN}2.${NC} 卸载 WARP"
        echo -e "  ${GREEN}3.${NC} 查看状态 / 测试"
        echo -e "  ${GREEN}4.${NC} 重启服务"
        echo -e "  ${GREEN}5.${NC} 立即执行一轮 Gemini 检测"
        echo -e "  ${GREEN}6.${NC} 紧急恢复 (移除规则并断开 WARP)"
        echo -e "  ${GREEN}7.${NC} 回滚至上一次备份"
        echo -e "  ${GREEN}0.${NC} 退出\n"
        read -r -p "请输入选项 [0-7]: " choice < /dev/tty || exit 0
        echo
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_status ;;
            4) [ -x "$ENGINE" ] && "$ENGINE" restart || err "尚未安装" ;;
            5) [ -x "$ENGINE" ] && "$ENGINE" gemini-check || err "尚未安装" ;;
            6) do_rescue ;;
            7) [ -x "$ENGINE" ] && "$ENGINE" rollback || err "尚未安装" ;;
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
