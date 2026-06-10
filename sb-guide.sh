#!/usr/bin/env sh
# sb-guide-optimized.sh
# A lightweight, capability-aware guided wrapper for fscarmen/sing-box.
#
# Goals:
# - Safe download and validation of the upstream installer
# - Low-memory defaults for tiny Alpine/LXC/NAT VPS
# - Guided protocol, port, node-name and subscription configuration
# - Capability-aware BBR/fq tuning (no forced kernel replacement)
# - Clear post-install verification
#
# Usage:
#   sh sb-guide-optimized.sh
#   sh sb-guide-optimized.sh --net-only
#   sh sb-guide-optimized.sh --check
#
# Environment overrides:
#   OFFICIAL_SCRIPT_URL=https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh
#   WORK_DIR=/root/.sb-guide

set -u

VERSION="2.0.0"
OFFICIAL_SCRIPT_URL="${OFFICIAL_SCRIPT_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh}"
WORK_DIR="${WORK_DIR:-/root/.sb-guide}"
OFFICIAL_SCRIPT_PATH="${WORK_DIR}/sing-box.sh"
CONFIG_PATH="${WORK_DIR}/config.conf"
LOG_PATH="${WORK_DIR}/install.log"
SYSCTL_PATH="/etc/sysctl.d/99-sb-guide-network.conf"
MODE="${1:-install}"

if [ -t 1 ] 2>/dev/null; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  RESET="$(printf '\033[0m')"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  RESET=""
fi

say() {
  printf '%s\n' "$*"
}

info() {
  printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"
}

ok() {
  printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"
}

die() {
  printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

has() {
  command -v "$1" >/dev/null 2>&1
}

need_root() {
  uid="$(id -u 2>/dev/null || printf '1')"
  [ "$uid" = "0" ] || die "请使用 root 执行：sudo -i 或 su -"
}

prepare_workdir() {
  mkdir -p "$WORK_DIR" || die "无法创建工作目录：$WORK_DIR"
  chmod 700 "$WORK_DIR" 2>/dev/null || true
}

ask() {
  prompt="$1"
  default="${2:-}"

  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi

  IFS= read -r ans || ans=""
  if [ -z "$ans" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$ans"
  fi
}

confirm() {
  prompt="$1"
  default="${2:-y}"

  if [ "$default" = "y" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  printf '%s %s: ' "$prompt" "$suffix"
  IFS= read -r ans || ans=""
  ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
  [ -n "$ans" ] || ans="$default"

  case "$ans" in
    y|yes|1|true) return 0 ;;
    *) return 1 ;;
  esac
}

quote_sq() {
  # Safe single-quoted value for the upstream KV config.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

redact() {
  value="$1"
  len="$(printf '%s' "$value" | wc -c | awk '{print $1}')"
  if [ "$len" -le 8 ] 2>/dev/null; then
    printf '***'
  else
    first="$(printf '%s' "$value" | cut -c1-4)"
    last="$(printf '%s' "$value" | rev 2>/dev/null | cut -c1-4 | rev 2>/dev/null)"
    [ -n "$last" ] || last="****"
    printf '%s...%s' "$first" "$last"
  fi
}

detect_os() {
  OS_ID="unknown"
  OS_LIKE=""
  OS_NAME="$(uname -s 2>/dev/null || printf 'unknown')"
  OS_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
  elif [ -r /etc/openwrt_release ]; then
    OS_ID="openwrt"
    OS_NAME="OpenWrt"
  fi

  info "系统：$OS_NAME"
  info "架构：$OS_ARCH"
  info "内核：$(uname -r 2>/dev/null || printf 'unknown')"
}

detect_pm() {
  PM=""
  if has apt-get; then PM="apt"
  elif has apk; then PM="apk"
  elif has dnf; then PM="dnf"
  elif has yum; then PM="yum"
  elif has microdnf; then PM="microdnf"
  elif has pacman; then PM="pacman"
  elif has zypper; then PM="zypper"
  elif has xbps-install; then PM="xbps"
  elif has opkg; then PM="opkg"
  fi

  if [ -n "$PM" ]; then
    info "包管理器：$PM"
  else
    warn "未识别包管理器；只能使用系统已有依赖。"
  fi
}

supported_upstream_os() {
  case "$OS_ID:$OS_LIKE" in
    alpine:*|debian:*|ubuntu:*|centos:*|rhel:*|rocky:*|almalinux:*|fedora:*|arch:*|manjaro:*|armbian:*|*:debian*|*:rhel*|*:fedora*|*:arch*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_resources() {
  MEM_MB=0
  DISK_FREE_MB=0

  if [ -r /proc/meminfo ]; then
    MEM_MB="$(awk '/MemTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || printf '0')"
  fi

  DISK_FREE_MB="$(df -Pm "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4; exit}' || printf '0')"
  [ -n "$DISK_FREE_MB" ] || DISK_FREE_MB=0

  info "内存：${MEM_MB} MB"
  info "工作目录可用空间：${DISK_FREE_MB} MB"

  LOW_MEMORY="false"
  if [ "$MEM_MB" -gt 0 ] 2>/dev/null && [ "$MEM_MB" -lt 256 ] 2>/dev/null; then
    LOW_MEMORY="true"
    warn "这是低内存机器。默认只推荐 VLESS Reality，并关闭在线订阅/Nginx。"
  fi

  if [ "$DISK_FREE_MB" -gt 0 ] 2>/dev/null && [ "$DISK_FREE_MB" -lt 180 ] 2>/dev/null; then
    warn "磁盘余量很低，安装可能失败。建议至少留出约 180 MB。"
  fi
}

detect_virtualization() {
  VIRT="unknown"

  if has systemd-detect-virt; then
    v="$(systemd-detect-virt 2>/dev/null || true)"
    [ -n "$v" ] && [ "$v" != "none" ] && VIRT="$v"
  fi

  if [ "$VIRT" = "unknown" ] || [ "$VIRT" = "none" ]; then
    if [ -f /.dockerenv ]; then
      VIRT="docker"
    elif grep -qaE '(lxc|container=lxc)' /proc/1/environ /proc/1/cgroup 2>/dev/null; then
      VIRT="lxc"
    elif grep -qaE '(docker|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
      VIRT="container"
    elif [ -r /proc/vz/veinfo ]; then
      VIRT="openvz"
    elif grep -qi hypervisor /proc/cpuinfo 2>/dev/null; then
      VIRT="vm"
    else
      VIRT="bare-metal-or-unknown"
    fi
  fi

  case "$VIRT" in
    lxc|docker|container|openvz|podman|systemd-nspawn)
      IS_CONTAINER="true"
      ;;
    *)
      IS_CONTAINER="false"
      ;;
  esac

  info "虚拟化：$VIRT"
}

run_pkg() {
  info "执行：$*"
  sh -c "$*"
}

install_deps() {
  say
  info "安装最小依赖，不安装编译器、内核或大型面板。"

  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      run_pkg "apt-get update" || die "apt-get update 失败"
      run_pkg "apt-get install -y --no-install-recommends bash curl wget ca-certificates tar gzip openssl iproute2 procps" ||
        die "依赖安装失败"
      ;;
    apk)
      run_pkg "apk update" || die "apk update 失败"
      run_pkg "apk add --no-cache bash curl wget ca-certificates tar gzip openssl iproute2 procps-ng openrc" ||
        die "依赖安装失败"
      update-ca-certificates >/dev/null 2>&1 || true
      ;;
    dnf)
      run_pkg "dnf install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng" ||
        die "依赖安装失败"
      ;;
    yum)
      if ! run_pkg "yum install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng"; then
        run_pkg "yum install -y epel-release" || true
        run_pkg "yum install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng" ||
          die "依赖安装失败"
      fi
      ;;
    microdnf)
      run_pkg "microdnf install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng" ||
        die "依赖安装失败"
      ;;
    pacman)
      run_pkg "pacman -Sy --noconfirm --needed bash curl wget ca-certificates tar gzip openssl iproute2 procps-ng" ||
        die "依赖安装失败"
      ;;
    zypper)
      run_pkg "zypper --non-interactive refresh" || true
      run_pkg "zypper --non-interactive install bash curl wget ca-certificates tar gzip openssl iproute2 procps" ||
        die "依赖安装失败"
      ;;
    xbps)
      run_pkg "xbps-install -Sy bash curl wget ca-certificates tar gzip openssl iproute2 procps-ng" ||
        die "依赖安装失败"
      ;;
    opkg)
      run_pkg "opkg update" || true
      run_pkg "opkg install bash curl wget ca-bundle ca-certificates tar gzip openssl-util ip-full procps-ng-ps" ||
        warn "OpenWrt 依赖未完全安装；上游安装器也可能不支持此系统。"
      ;;
    *)
      warn "跳过自动安装。至少需要：bash、curl 或 wget、CA 证书、tar、gzip、openssl。"
      ;;
  esac

  has bash || die "没有 bash；上游安装器必须使用 bash。"
  if ! has curl && ! has wget; then
    die "没有 curl 或 wget，无法下载。"
  fi
  ok "依赖检查完成。"
}

fetch_stdout() {
  url="$1"
  if has curl; then
    curl -fsSL --connect-timeout 5 --max-time 10 --retry 1 "$url" 2>/dev/null || true
  elif has wget; then
    wget -qO- --timeout=10 --tries=1 "$url" 2>/dev/null || true
  fi
}

fetch_file() {
  url="$1"
  out="$2"
  tmp="${out}.tmp.$$"
  rm -f "$tmp"

  if has curl; then
    curl -fL --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 2 \
      --retry-all-errors "$url" -o "$tmp" || {
        rm -f "$tmp"
        return 1
      }
  elif has wget; then
    wget --timeout=20 --tries=3 -O "$tmp" "$url" || {
      rm -f "$tmp"
      return 1
    }
  else
    return 1
  fi

  [ -s "$tmp" ] || {
    rm -f "$tmp"
    return 1
  }

  mv "$tmp" "$out"
}

valid_ip_like() {
  ip="$1"
  case "$ip" in
    ""|*" "*|*"	"*) return 1 ;;
  esac

  case "$ip" in
    *.*)
      case "$ip" in *[!0-9.]* ) return 1 ;; *) return 0 ;; esac
      ;;
    *:*)
      case "$ip" in *[!0-9a-fA-F:]* ) return 1 ;; *) return 0 ;; esac
      ;;
  esac
  return 1
}

detect_server_ip() {
  DETECTED_IP=""

  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip_value="$(fetch_stdout "$url" | tr -d '\r\n ')"
    if valid_ip_like "$ip_value"; then
      DETECTED_IP="$ip_value"
      break
    fi
  done

  if [ -z "$DETECTED_IP" ] && has ip; then
    ip_value="$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
    valid_ip_like "$ip_value" && DETECTED_IP="$ip_value"
  fi

  if [ -n "$DETECTED_IP" ]; then
    info "检测到服务器地址：$DETECTED_IP"
  else
    warn "无法自动检测服务器地址。"
  fi
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi

  if has uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return
  fi

  has openssl || die "无法生成 UUID：缺少 /proc UUID、uuidgen 和 openssl"
  hex="$(openssl rand -hex 16)" || die "UUID 生成失败"
  printf '%s-%s-4%s-%s%s-%s\n' \
    "$(printf '%s' "$hex" | cut -c1-8)" \
    "$(printf '%s' "$hex" | cut -c9-12)" \
    "$(printf '%s' "$hex" | cut -c14-16)" \
    "8" \
    "$(printf '%s' "$hex" | cut -c18-20)" \
    "$(printf '%s' "$hex" | cut -c21-32)"
}

valid_uuid() {
  value="$1"
  printf '%s' "$value" |
    grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

valid_reality_key() {
  value="$1"
  [ -z "$value" ] && return 0
  [ "$(printf '%s' "$value" | wc -c | awk '{print $1}')" -eq 43 ] 2>/dev/null || return 1
  printf '%s' "$value" | grep -Eq '^[A-Za-z0-9_-]+$'
}

valid_port() {
  p="$1"
  case "$p" in ""|*[!0-9]*) return 1 ;; esac
  [ "$p" -ge 100 ] 2>/dev/null && [ "$p" -le 65520 ] 2>/dev/null
}

normalize_protocols() {
  input="$1"
  output=""
  rest="$input"

  while [ -n "$rest" ]; do
    ch="$(printf '%s' "$rest" | cut -c1)"
    rest="$(printf '%s' "$rest" | cut -c2-)"
    case "$output" in
      *"$ch"*) ;;
      *) output="${output}${ch}" ;;
    esac
  done

  printf '%s' "$output"
}

validate_protocols() {
  protocols="$1"
  only_tcp="$2"

  [ -n "$protocols" ] || return 1
  case "$protocols" in *[!abcdefghijklm]*) return 1 ;; esac

  if [ "$protocols" != "a" ]; then
    case "$protocols" in *a*) return 1 ;; esac
  fi

  if [ "$only_tcp" = "true" ]; then
    case "$protocols" in *a*|*c*|*d*|*m*) return 2 ;; esac
  fi
  return 0
}

contains_char() {
  string="$1"
  char="$2"
  case "$string" in *"$char"*) return 0 ;; *) return 1 ;; esac
}

count_protocols() {
  protocols="$1"
  if [ "$protocols" = "a" ]; then
    printf '12\n'
  else
    printf '%s' "$protocols" | wc -c | awk '{print $1}'
  fi
}

print_protocol_menu() {
  cat <<'EOF'

协议映射（上游 config.conf）：
  a = 全部协议
  b = VLESS + Reality
  c = Hysteria2                 UDP/QUIC
  d = TUIC v5                   UDP/QUIC
  e = ShadowTLS
  f = Shadowsocks
  g = Trojan
  h = VMess + WebSocket
  i = VLESS + WebSocket + TLS
  j = VLESS + H2 + Reality
  k = VLESS + gRPC + Reality
  l = AnyTLS
  m = NaiveProxy                同时涉及 HTTP/2/QUIC 输出

建议：
  低内存/禁用 UDP：b
  普通 TCP 兼容：bgl
  不建议在 128 MB 机器上一次安装很多协议。

EOF
}

check_ports() {
  start="$1"
  count="$2"
  end=$((start + count - 1))

  [ "$end" -le 65535 ] || die "协议端口会超过 65535。"

  if has ss; then
    used=""
    p="$start"
    while [ "$p" -le "$end" ]; do
      if ss -H -lntu 2>/dev/null | awk '{print $5}' |
        grep -Eq "(^|[.:])${p}$"; then
        used="${used} ${p}"
      fi
      p=$((p + 1))
    done
    [ -z "$used" ] || warn "以下端口似乎正在监听：$used"
  fi
}

choose_protocols() {
  print_protocol_menu

  if [ "$LOW_MEMORY" = "true" ]; then
    default_profile="1"
  else
    default_profile="2"
  fi

  say "配置档："
  say "  1. 轻量单协议：VLESS Reality（推荐小鸡）"
  say "  2. TCP 兼容：Reality + Trojan + AnyTLS"
  say "  3. 自定义协议字母"
  say "  4. 全协议（不推荐低配置机器）"

  profile="$(ask "请选择配置档" "$default_profile")"
  case "$profile" in
    1)
      ONLY_TCP="true"
      PROTOCOLS="b"
      ;;
    2)
      ONLY_TCP="true"
      PROTOCOLS="bgl"
      ;;
    4)
      ONLY_TCP="false"
      PROTOCOLS="a"
      ;;
    *)
      if confirm "是否限制为 TCP 类协议？" "y"; then
        ONLY_TCP="true"
        default_protocols="b"
      else
        ONLY_TCP="false"
        default_protocols="a"
      fi

      while :; do
        PROTOCOLS="$(ask "请输入协议字母组合" "$default_protocols")"
        PROTOCOLS="$(normalize_protocols "$PROTOCOLS")"
        validate_protocols "$PROTOCOLS" "$ONLY_TCP"
        rc=$?
        if [ "$rc" -eq 0 ]; then
          break
        elif [ "$rc" -eq 2 ]; then
          warn "TCP-only 不允许 a/c/d/m。"
        else
          warn "协议组合无效；a 不能与其他字母混用。"
        fi
      done
      ;;
  esac

  info "将安装协议：$PROTOCOLS"
}

interactive_config() {
  say
  say "======================================"
  say " Sing-box 引导式安装器 v${VERSION}"
  say "======================================"

  LANGUAGE="$(ask "语言：c=中文，e=英文" "c")"
  case "$LANGUAGE" in c|e) ;; *) LANGUAGE="c" ;; esac

  detect_server_ip
  SERVER_IP="$(ask "服务器公网 IP/IPv6" "$DETECTED_IP")"
  [ -n "$SERVER_IP" ] || die "服务器地址不能为空。"

  default_node="$(hostname 2>/dev/null || printf 'sb-node')"
  if confirm "是否自定义节点名？" "y"; then
    NODE_NAME="$(ask "节点名，例如 JP-01 / HK-01-A" "$default_node")"
  else
    NODE_NAME="$default_node"
  fi
  [ -n "$NODE_NAME" ] || die "节点名不能为空。"

  choose_protocols

  while :; do
    START_PORT="$(ask "协议起始端口" "8881")"
    valid_port "$START_PORT" && break
    warn "端口必须为 100-65520。"
  done

  proto_count="$(count_protocols "$PROTOCOLS")"
  end_port=$((START_PORT + proto_count - 1))
  info "预计使用连续端口：${START_PORT}-${end_port}"
  check_ports "$START_PORT" "$proto_count"

  UUID_CONFIRM="$(ask "UUID，留空自动生成" "")"
  [ -n "$UUID_CONFIRM" ] || UUID_CONFIRM="$(gen_uuid)"
  valid_uuid "$UUID_CONFIRM" || die "UUID 格式无效。"

  if [ "$LOW_MEMORY" = "true" ]; then
    sub_default="n"
  else
    sub_default="y"
  fi

  if confirm "是否启用在线订阅？会安装/运行 Nginx" "$sub_default"; then
    SUBSCRIBE="true"
    if confirm "是否自定义订阅 Nginx 端口？" "n"; then
      while :; do
        PORT_NGINX="$(ask "订阅端口" "21865")"
        valid_port "$PORT_NGINX" && break
        warn "订阅端口无效。"
      done
    else
      PORT_NGINX=""
    fi
  else
    SUBSCRIBE="false"
    PORT_NGINX=""
  fi

  VMESS_HOST_DOMAIN=""
  VLESS_HOST_DOMAIN=""
  CDN=""
  ARGO="false"
  ARGO_DOMAIN=""
  ARGO_AUTH=""

  if contains_char "$PROTOCOLS" "h" ||
     contains_char "$PROTOCOLS" "i" ||
     [ "$PROTOCOLS" = "a" ]; then
    warn "你选择了 WebSocket 协议。Cloudflared/Argo 会增加内存占用。"
    if confirm "使用 Argo 临时隧道？" "n"; then
      ARGO="true"
    else
      if contains_char "$PROTOCOLS" "h" || [ "$PROTOCOLS" = "a" ]; then
        VMESS_HOST_DOMAIN="$(ask "VMess WS 域名" "")"
      fi
      if contains_char "$PROTOCOLS" "i" || [ "$PROTOCOLS" = "a" ]; then
        VLESS_HOST_DOMAIN="$(ask "VLESS WS TLS 域名" "")"
      fi
      CDN="$(ask "CDN/优选地址，留空使用上游默认" "")"
    fi
  fi

  HY2_PORT_HOPPING_RANGE=""
  HY2_REALM=""
  HY2_WARP=""

  if contains_char "$PROTOCOLS" "c" || [ "$PROTOCOLS" = "a" ]; then
    warn "Hysteria2 依赖 UDP/QUIC；禁用 UDP 的机器不能使用。"
    if confirm "启用 Hysteria2 端口跳跃？" "n"; then
      HY2_PORT_HOPPING_RANGE="$(ask "端口范围，例如 50000:51000" "50000:51000")"
    fi
    if confirm "启用 Hysteria2 Realm？" "n"; then
      HY2_REALM="true"
      if confirm "启用 WARP 辅助打洞？" "n"; then
        HY2_WARP="true"
      else
        HY2_WARP="false"
      fi
    else
      HY2_REALM="false"
      HY2_WARP="false"
    fi
  fi

  REALITY_PRIVATE="$(ask "Reality privateKey，留空由上游随机生成" "")"
  valid_reality_key "$REALITY_PRIVATE" ||
    die "Reality privateKey 必须是 43 位 base64url 字符。"

  say
  say "------------- 配置确认 -------------"
  say "服务器地址：$SERVER_IP"
  say "节点名：$NODE_NAME"
  say "协议：$PROTOCOLS"
  say "TCP-only：$ONLY_TCP"
  say "端口：${START_PORT}-${end_port}"
  say "UUID：$(redact "$UUID_CONFIRM")"
  say "在线订阅：$SUBSCRIBE"
  say "Argo：$ARGO"
  [ -n "$REALITY_PRIVATE" ] && say "Reality 私钥：$(redact "$REALITY_PRIVATE")"
  say "------------------------------------"

  if [ "$IS_CONTAINER" = "true" ]; then
    warn "检测到容器环境。NAT 公网端口必须正确映射到上述内部端口。"
  fi

  confirm "确认安装？" "y" || die "用户取消。"
}

write_config() {
  umask 077
  cat > "$CONFIG_PATH" <<EOF
LANGUAGE=$(quote_sq "$LANGUAGE")
CHOOSE_PROTOCOLS=$(quote_sq "$PROTOCOLS")
START_PORT=$(quote_sq "$START_PORT")
PORT_NGINX=$(quote_sq "$PORT_NGINX")
SERVER_IP=$(quote_sq "$SERVER_IP")
CDN=$(quote_sq "$CDN")
UUID_CONFIRM=$(quote_sq "$UUID_CONFIRM")
SUBSCRIBE=$(quote_sq "$SUBSCRIBE")
ARGO=$(quote_sq "$ARGO")
VMESS_HOST_DOMAIN=$(quote_sq "$VMESS_HOST_DOMAIN")
VLESS_HOST_DOMAIN=$(quote_sq "$VLESS_HOST_DOMAIN")
ARGO_DOMAIN=$(quote_sq "$ARGO_DOMAIN")
ARGO_AUTH=$(quote_sq "$ARGO_AUTH")
HY2_PORT_HOPPING_RANGE=$(quote_sq "$HY2_PORT_HOPPING_RANGE")
HY2_REALM=$(quote_sq "$HY2_REALM")
HY2_WARP=$(quote_sq "$HY2_WARP")
REALITY_PRIVATE=$(quote_sq "$REALITY_PRIVATE")
NODE_NAME_CONFIRM=$(quote_sq "$NODE_NAME")
EOF
  chmod 600 "$CONFIG_PATH" 2>/dev/null || true
  ok "配置已写入：$CONFIG_PATH（权限 600）"
}

download_official_script() {
  info "下载上游安装器：$OFFICIAL_SCRIPT_URL"
  fetch_file "$OFFICIAL_SCRIPT_URL" "$OFFICIAL_SCRIPT_PATH" ||
    die "上游脚本下载失败。请检查 DNS、GitHub 连通性和系统时间。"

  chmod 700 "$OFFICIAL_SCRIPT_PATH" 2>/dev/null || true
  bash -n "$OFFICIAL_SCRIPT_PATH" ||
    die "下载内容未通过 bash 语法检查，已停止执行。"

  first_line="$(head -n 1 "$OFFICIAL_SCRIPT_PATH" 2>/dev/null || true)"
  case "$first_line" in
    *bash*) ;;
    *) warn "上游脚本首行不是常见 Bash shebang，请人工检查：$OFFICIAL_SCRIPT_PATH" ;;
  esac

  ok "上游脚本已下载并通过语法检查。"
}

run_install() {
  info "开始安装；日志：$LOG_PATH"
  rm -f "$LOG_PATH"

  # Preserve the upstream exit code while still showing live output.
  if has tee; then
    bash -o pipefail -c '
      bash "$1" -f "$2" 2>&1 | tee "$3"
    ' _ "$OFFICIAL_SCRIPT_PATH" "$CONFIG_PATH" "$LOG_PATH"
    rc=$?
  else
    bash "$OFFICIAL_SCRIPT_PATH" -f "$CONFIG_PATH" >"$LOG_PATH" 2>&1
    rc=$?
    cat "$LOG_PATH"
  fi

  [ "$rc" -eq 0 ] || die "上游安装器返回错误码 $rc。请查看：$LOG_PATH"
}

service_is_running() {
  if has rc-service; then
    rc-service sing-box status >/dev/null 2>&1
  elif has systemctl; then
    systemctl is-active --quiet sing-box
  elif has pgrep; then
    pgrep -x sing-box >/dev/null 2>&1
  else
    ps 2>/dev/null | grep '[s]ing-box' >/dev/null 2>&1
  fi
}

find_singbox_binary() {
  if has sing-box; then
    command -v sing-box
    return
  fi

  for candidate in \
    /etc/sing-box/sing-box \
    /usr/local/bin/sing-box \
    /usr/bin/sing-box
  do
    [ -x "$candidate" ] && {
      printf '%s\n' "$candidate"
      return
    }
  done
  return 1
}

post_check() {
  say
  say "------------- 安装验证 -------------"

  binary="$(find_singbox_binary 2>/dev/null || true)"
  [ -n "$binary" ] || die "未找到 sing-box 二进制；安装并未真正成功。"

  "$binary" version 2>/dev/null || warn "无法读取 sing-box 版本。"

  if service_is_running; then
    ok "sing-box 服务正在运行。"
  else
    warn "sing-box 服务没有处于运行状态。"
  fi

  config_file=""
  for candidate in \
    /etc/sing-box/config.json \
    /etc/sing-box/sing-box.json \
    /etc/sing-box/config.jsonc
  do
    [ -f "$candidate" ] && {
      config_file="$candidate"
      break
    }
  done

  if [ -n "$config_file" ]; then
    if "$binary" check -c "$config_file" >/dev/null 2>&1; then
      ok "服务端配置通过 sing-box check。"
    else
      warn "服务端配置未通过 sing-box check：$config_file"
    fi
  fi

  if grep -RqsE 'pbk=(&|$)|"public_key"[[:space:]]*:[[:space:]]*""' \
      /etc/sing-box/list /etc/sing-box/subscribe "$LOG_PATH" 2>/dev/null; then
    warn "检测到 Reality 公钥可能为空。请不要使用该链接；先检查下载和密钥生成。"
  fi

  if grep -qE 'No such file|cannot stat|download.*failed' "$LOG_PATH" 2>/dev/null; then
    warn "安装日志包含下载/文件错误，请检查：$LOG_PATH"
  fi
}

export_nodes() {
  say
  say "------------- 节点输出 -------------"
  if has sb; then
    sb -n
  elif [ -x "$OFFICIAL_SCRIPT_PATH" ]; then
    bash "$OFFICIAL_SCRIPT_PATH" -n
  else
    warn "找不到 sb 命令。请检查 /etc/sing-box/subscribe/"
  fi
}

show_network_status() {
  say
  say "------------- 网络状态 -------------"

  available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || printf '不可读取')"
  current="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || printf '不可读取')"
  qdisc="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || printf '不可读取')"

  say "可用拥塞控制：$available"
  say "当前拥塞控制：$current"
  say "默认 qdisc：$qdisc"

  if has tc; then
    tc qdisc show 2>/dev/null || true
  fi
}

sysctl_key_exists() {
  key="$1"
  path="/proc/sys/$(printf '%s' "$key" | tr . /)"
  [ -e "$path" ]
}

apply_one_sysctl() {
  key="$1"
  value="$2"
  output_file="$3"

  sysctl_key_exists "$key" || {
    warn "内核没有参数：$key"
    return 1
  }

  if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
    printf '%s=%s\n' "$key" "$value" >> "$output_file"
    ok "已应用：$key=$value"
    return 0
  fi

  warn "无法写入：$key（容器权限或宿主限制）"
  return 1
}

network_optimize() {
  say
  say "======================================"
  say " 网络能力检测与安全优化"
  say "======================================"

  has sysctl || {
    warn "缺少 sysctl，无法应用网络参数。"
    show_network_status
    return
  }

  detect_virtualization
  show_network_status

  available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"

  if ! printf '%s\n' "$available" | grep -qw bbr; then
    if [ "$IS_CONTAINER" = "false" ] && has modprobe; then
      modprobe tcp_bbr >/dev/null 2>&1 || true
      available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
    fi
  fi

  temp_sysctl="${WORK_DIR}/sysctl.$$"
  : > "$temp_sysctl"

  # BBR can only be selected if the running host kernel exposes it.
  if printf '%s\n' "$available" | grep -qw bbr; then
    apply_one_sysctl "net.ipv4.tcp_congestion_control" "bbr" "$temp_sysctl" || true
  else
    warn "当前运行内核没有提供 BBR。"
    if [ "$IS_CONTAINER" = "true" ]; then
      warn "LXC/OpenVZ/Docker 不能在容器内更换宿主内核；请让商家在宿主机启用 BBR。"
    else
      warn "本脚本不会自动替换内核。先升级发行版官方内核，再重新运行 --net-only。"
    fi
  fi

  # On veth/container interfaces default_qdisc is commonly ignored/noqueue.
  if [ "$IS_CONTAINER" = "false" ]; then
    if has modprobe; then
      modprobe sch_fq >/dev/null 2>&1 || true
    fi
    apply_one_sysctl "net.core.default_qdisc" "fq" "$temp_sysctl" || true
  else
    warn "容器环境跳过 default_qdisc=fq：veth 的实际队列通常由宿主机控制。"
  fi

  # Conservative resilience setting; no large memory buffers on tiny VPS.
  apply_one_sysctl "net.ipv4.tcp_mtu_probing" "1" "$temp_sysctl" || true

  if [ -s "$temp_sysctl" ]; then
    if [ -f "$SYSCTL_PATH" ]; then
      backup="${SYSCTL_PATH}.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'old')"
      cp "$SYSCTL_PATH" "$backup" 2>/dev/null || true
      info "旧配置已备份：$backup"
    fi
    {
      printf '# Managed by sb-guide-optimized.sh v%s\n' "$VERSION"
      cat "$temp_sysctl"
    } > "$SYSCTL_PATH"
    chmod 644 "$SYSCTL_PATH" 2>/dev/null || true
    ok "持久化网络配置：$SYSCTL_PATH"
  else
    warn "没有任何网络参数成功写入。"
  fi

  rm -f "$temp_sysctl"
  show_network_status

  current="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
  if [ "$current" = "bbr" ]; then
    ok "BBR 已对新建 TCP 连接生效。"
  else
    warn "当前 TCP 拥塞控制仍为：${current:-未知}"
  fi

  say
  warn "网络算法不能修复差线路、宿主超售、端口限速或 NAT 映射问题。"
  warn "本脚本不会设置超大 TCP 缓冲区，也不会在 LXC 内强装内核模块。"
}

handle_existing_install() {
  if has sb || [ -d /etc/sing-box ]; then
    warn "检测到系统中可能已经安装 sing-box。"
    say "  1. 只查看节点"
    say "  2. 只做网络检测/优化"
    say "  3. 卸载后重新安装"
    say "  4. 退出"

    existing_choice="$(ask "请选择" "2")"
    case "$existing_choice" in
      1)
        export_nodes
        exit 0
        ;;
      2)
        network_optimize
        exit 0
        ;;
      3)
        confirm "重新安装会删除现有节点配置，确认继续？" "n" ||
          die "用户取消。"
        if has sb; then
          sb -u
        else
          die "找不到 sb 管理命令，请先手动备份/卸载。"
        fi
        ;;
      *)
        exit 0
        ;;
    esac
  fi
}

print_summary() {
  say
  say "常用命令："
  say "  sb -n      查看节点/订阅"
  say "  sb -d      修改配置"
  say "  sb -r      增删协议"
  say "  sb -s      启停 sing-box"
  say "  sb -v      更新 sing-box"
  say "  sb -u      卸载"
  say
  say "网络复查："
  say "  sh $0 --check"
  say "  sh $0 --net-only"
}

main() {
  need_root
  prepare_workdir
  detect_os
  detect_pm
  detect_resources
  detect_virtualization

  case "$MODE" in
    --check|check)
      show_network_status
      exit 0
      ;;
    --net-only|net-only)
      if ! has sysctl; then
        install_deps
      fi
      network_optimize
      exit 0
      ;;
    --help|-h|help)
      say "用法："
      say "  sh $0              安装 sing-box"
      say "  sh $0 --net-only   只检测并安全启用 BBR/fq"
      say "  sh $0 --check      只查看网络状态"
      exit 0
      ;;
    install|"")
      ;;
    *)
      die "未知参数：$MODE"
      ;;
  esac

  supported_upstream_os ||
    warn "上游 fscarmen/sing-box 未明确支持当前系统；安装可能退出。"

  handle_existing_install

  if confirm "自动安装/补齐最小依赖？" "y"; then
    install_deps
  else
    has bash || die "缺少 bash。"
    if ! has curl && ! has wget; then
      die "缺少 curl/wget。"
    fi
  fi

  if confirm "安装前执行网络能力检测并安全启用 BBR（若宿主支持）？" "y"; then
    network_optimize
  fi

  interactive_config
  write_config
  download_official_script
  run_install
  post_check
  export_nodes
  print_summary
}

main "$@"
