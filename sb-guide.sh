#!/usr/bin/env sh
# sb-guide-universal.sh
# Universal, capability-aware wrapper for fscarmen/sing-box.
#
# Goals:
# - Broad distro / VM / container compatibility
# - Automatic resource classification and adaptive kernel tuning
# - Explicit TCP-only or TCP+UDP protocol selection
# - Safe BBR + fq activation when the running kernel supports them
# - Upstream protocol-map verification before installation
# - Guided mode plus unattended --auto-tcp / --auto-udp modes
# - Configuration backup, validation and network rollback
#
# Usage:
#   sh sb-guide-universal.sh
#   sh sb-guide-universal.sh --auto-tcp
#   sh sb-guide-universal.sh --auto-udp
#   sh sb-guide-universal.sh --net-only
#   sh sb-guide-universal.sh --rollback-net
#   sh sb-guide-universal.sh --check
#
# Environment overrides:
#   OFFICIAL_SCRIPT_URL=https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh
#   WORK_DIR=/root/.sb-guide

set -u

VERSION="3.0.3-upstream-clean"
OFFICIAL_SCRIPT_URL="${OFFICIAL_SCRIPT_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh}"
OFFICIAL_CONFIG_URL="${OFFICIAL_CONFIG_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/config.conf}"
WORK_DIR="${WORK_DIR:-/root/.sb-guide}"
OFFICIAL_SCRIPT_PATH="${WORK_DIR}/sing-box.sh"
UPSTREAM_CONFIG_PATH="${WORK_DIR}/upstream-config.conf"
CONFIG_PATH="${WORK_DIR}/config.conf"
LOG_PATH="${WORK_DIR}/install.log"
SYSCTL_PATH="/etc/sysctl.d/99-sb-guide-network.conf"
NETWORK_STATE_PATH="${WORK_DIR}/network-before.conf"
MODE="${1:-install}"
AUTO_INSTALL="false"
TRANSPORT_MODE="${SB_TRANSPORT_MODE:-}"
PROTOCOL_PROFILE="${SB_PROFILE:-}"
NAT_LIMITED="${SB_NAT_LIMITED:-}"

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

  if [ "$AUTO_INSTALL" = "true" ]; then
    printf '%s' "$default"
    return 0
  fi

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

  if [ "$AUTO_INSTALL" = "true" ]; then
    [ "$default" = "y" ]
    return
  fi

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
  SWAP_MB=0
  CPU_CORES=1
  DISK_FREE_MB=0
  RESOURCE_CLASS="medium"

  if [ -r /proc/meminfo ]; then
    MEM_MB="$(awk '/MemTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || printf '0')"
    SWAP_MB="$(awk '/SwapTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || printf '0')"
  fi

  if has nproc; then
    CPU_CORES="$(nproc 2>/dev/null || printf '1')"
  elif [ -r /proc/cpuinfo ]; then
    CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '1')"
  fi
  case "$CPU_CORES" in ""|*[!0-9]*) CPU_CORES=1 ;; esac
  [ "$CPU_CORES" -ge 1 ] 2>/dev/null || CPU_CORES=1

  DISK_FREE_MB="$(df -Pm "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4; exit}' || printf '0')"
  [ -n "$DISK_FREE_MB" ] || DISK_FREE_MB=0

  if [ "$MEM_MB" -gt 0 ] 2>/dev/null && [ "$MEM_MB" -lt 256 ] 2>/dev/null; then
    RESOURCE_CLASS="tiny"
  elif [ "$MEM_MB" -lt 768 ] 2>/dev/null; then
    RESOURCE_CLASS="small"
  elif [ "$MEM_MB" -lt 2048 ] 2>/dev/null; then
    RESOURCE_CLASS="medium"
  elif [ "$MEM_MB" -lt 8192 ] 2>/dev/null; then
    RESOURCE_CLASS="large"
  else
    RESOURCE_CLASS="xlarge"
  fi

  LOW_MEMORY="false"
  [ "$RESOURCE_CLASS" = "tiny" ] && LOW_MEMORY="true"

  info "CPU：${CPU_CORES} 核"
  info "内存：${MEM_MB} MB（${RESOURCE_CLASS}）"
  info "Swap：${SWAP_MB} MB"
  info "工作目录可用空间：${DISK_FREE_MB} MB"

  if [ "$LOW_MEMORY" = "true" ]; then
    warn "低内存机器：将使用较小缓冲区，并默认关闭 Nginx/Argo。"
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


probe_udp_egress() {
  UDP_PROBE_RESULT="unknown"

  if has timeout && has dig; then
    if timeout 5 dig +time=2 +tries=1 @1.1.1.1 example.com A >/dev/null 2>&1; then
      UDP_PROBE_RESULT="available"
      return 0
    fi
  fi

  if has timeout && has nslookup; then
    if timeout 5 nslookup example.com 1.1.1.1 >/dev/null 2>&1; then
      UDP_PROBE_RESULT="available"
      return 0
    fi
  fi

  if has timeout && has nc; then
    if timeout 4 nc -u -z -w 2 1.1.1.1 53 >/dev/null 2>&1; then
      UDP_PROBE_RESULT="possibly-available"
      return 0
    fi
  fi

  UDP_PROBE_RESULT="unknown"
  return 1
}

choose_transport_mode() {
  case "$TRANSPORT_MODE" in
    tcp|tcp-only)
      TRANSPORT_MODE="tcp"
      ;;
    udp|tcp-udp|all)
      TRANSPORT_MODE="udp"
      ;;
    auto|"")
      if [ "$AUTO_INSTALL" = "true" ]; then
        # Unattended generic mode is deliberately conservative.
        TRANSPORT_MODE="tcp"
      else
        say
        say "传输模式："
        say "  1. 自动探测后确认（默认）"
        say "  2. 仅 TCP：适合禁 UDP、严格防火墙或只映射 TCP 的机器"
        say "  3. TCP + UDP：适合确认 UDP 入站端口可用的机器"
        transport_choice="$(ask "请选择" "1")"

        case "$transport_choice" in
          2)
            TRANSPORT_MODE="tcp"
            ;;
          3)
            TRANSPORT_MODE="udp"
            ;;
          *)
            info "正在进行轻量 UDP 出站探测；该探测不能证明 UDP 入站已放行。"
            if probe_udp_egress; then
              info "UDP 出站探测结果：$UDP_PROBE_RESULT"
              if confirm "你是否确认 VPS 安全组、NAT 映射和防火墙允许 UDP 入站？" "n"; then
                TRANSPORT_MODE="udp"
              else
                TRANSPORT_MODE="tcp"
              fi
            else
              warn "无法确认 UDP 可用，自动选择仅 TCP。"
              TRANSPORT_MODE="tcp"
            fi
            ;;
        esac
      fi
      ;;
    *)
      die "SB_TRANSPORT_MODE 必须为 tcp、udp 或 auto。"
      ;;
  esac

  if [ "$TRANSPORT_MODE" = "tcp" ]; then
    ONLY_TCP="true"
    UDP_ENABLED="false"
    NAT_LIMITED="false"
    ok "已选择：严格 TCP-only。"
  else
    ONLY_TCP="false"
    UDP_ENABLED="true"

    case "$NAT_LIMITED" in
      true|yes|1) NAT_LIMITED="true" ;;
      false|no|0) NAT_LIMITED="false" ;;
      *)
        if confirm "这是端口映射数量有限的 NAT VPS 吗？" "n"; then
          NAT_LIMITED="true"
        else
          NAT_LIMITED="false"
        fi
        ;;
    esac

    ok "已选择：TCP + UDP。"
    if [ "$NAT_LIMITED" = "true" ]; then
      warn "NAT 限端口模式：自动关闭 Hysteria2 端口跳跃，并尽量减少协议端口。"
    fi
  fi
}

run_pkg() {
  info "执行：$*"
  sh -c "$*"
}

install_optional_ethtool() {
  # ethtool is only used for best-effort GRO/GSO/TSO tuning on a full VM or
  # bare-metal host. It is not a hard dependency, and installing it must never
  # abort sing-box installation.
  if [ "${IS_CONTAINER:-false}" = "true" ]; then
    info "容器环境跳过可选依赖 ethtool；虚拟网卡卸载能力通常由宿主机控制。"
    return 0
  fi

  if has ethtool; then
    return 0
  fi

  info "尝试安装可选依赖 ethtool；失败不会中止安装。"
  case "$PM" in
    apt)
      run_pkg "apt-get install -y --no-install-recommends ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    apk)
      run_pkg "apk add --no-cache ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    dnf)
      run_pkg "dnf install -y ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    yum)
      run_pkg "yum install -y ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    microdnf)
      run_pkg "microdnf install -y ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    pacman)
      run_pkg "pacman -S --noconfirm --needed ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    zypper)
      run_pkg "zypper --non-interactive install ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    xbps)
      run_pkg "xbps-install -Sy ethtool" ||
        warn "可选依赖 ethtool 安装失败，跳过网卡卸载参数调整。"
      ;;
    *)
      warn "当前包管理器未配置 ethtool 自动安装；继续执行。"
      ;;
  esac
}

install_deps() {
  say
  info "安装核心依赖；可选调优工具单独安装，失败不会阻断主流程。"

  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      run_pkg "apt-get update" || die "apt-get update 失败"
      run_pkg "apt-get install -y --no-install-recommends bash curl wget ca-certificates tar gzip openssl iproute2 procps" ||
        die "核心依赖安装失败"
      ;;
    apk)
      run_pkg "apk update" || die "apk update 失败"
      # Alpine 正确包名是 procps-ng 和 ethtool；不存在 ethtool-ng。
      run_pkg "apk add --no-cache bash curl wget ca-certificates tar gzip openssl iproute2 procps-ng openrc" ||
        die "核心依赖安装失败"
      update-ca-certificates >/dev/null 2>&1 || true
      ;;
    dnf)
      run_pkg "dnf install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng" ||
        die "核心依赖安装失败"
      ;;
    yum)
      if ! run_pkg "yum install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng"; then
        run_pkg "yum install -y epel-release" || true
        run_pkg "yum install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng" ||
          die "核心依赖安装失败"
      fi
      ;;
    microdnf)
      run_pkg "microdnf install -y bash curl wget ca-certificates tar gzip openssl iproute procps-ng" ||
        die "核心依赖安装失败"
      ;;
    pacman)
      run_pkg "pacman -Sy --noconfirm --needed bash curl wget ca-certificates tar gzip openssl iproute2 procps-ng" ||
        die "核心依赖安装失败"
      ;;
    zypper)
      run_pkg "zypper --non-interactive refresh" || true
      run_pkg "zypper --non-interactive install bash curl wget ca-certificates tar gzip openssl iproute2 procps" ||
        die "核心依赖安装失败"
      ;;
    xbps)
      run_pkg "xbps-install -Sy bash curl wget ca-certificates tar gzip openssl iproute2 procps-ng" ||
        die "核心依赖安装失败"
      ;;
    opkg)
      run_pkg "opkg update" || true
      run_pkg "opkg install bash curl wget ca-bundle ca-certificates tar gzip openssl-util ip-full procps-ng-ps" ||
        warn "OpenWrt 依赖未完全安装；上游安装器也可能不支持此系统。"
      ;;
    *)
      warn "未识别包管理器，跳过自动安装。"
      warn "至少需要：bash、curl 或 wget、CA 证书、tar、gzip、openssl。"
      ;;
  esac

  install_optional_ethtool

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


verify_upstream_protocol_map() {
  info "核对上游协议字母映射：$OFFICIAL_CONFIG_URL"

  fetch_file "$OFFICIAL_CONFIG_URL" "$UPSTREAM_CONFIG_PATH" ||
    die "无法下载上游 config.conf，不能安全确认协议映射。"

  map_ok="true"
  grep -Eiq 'b:[[:space:]]*VLESS[[:space:]]*\+[[:space:]]*Reality' "$UPSTREAM_CONFIG_PATH" || map_ok="false"
  grep -Eiq 'c:[[:space:]]*Hysteria2' "$UPSTREAM_CONFIG_PATH" || map_ok="false"
  grep -Eiq 'd:[[:space:]]*(Tuic|TUIC)[[:space:]]*V5' "$UPSTREAM_CONFIG_PATH" || map_ok="false"
  grep -Eiq 'g:[[:space:]]*Trojan' "$UPSTREAM_CONFIG_PATH" || map_ok="false"
  grep -Eiq 'l:[[:space:]]*AnyTLS' "$UPSTREAM_CONFIG_PATH" || map_ok="false"

  [ "$map_ok" = "true" ] ||
    die "上游协议字母映射已变化。为避免装错协议，本脚本已停止。"

  ok "上游协议映射核对通过。"
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
    # Strict TCP mode excludes QUIC-native c/d, Shadowsocks f (can expose UDP),
    # and Naive m (upstream output may include QUIC).
    case "$protocols" in *a*|*c*|*d*|*f*|*m*) return 2 ;; esac
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

协议映射（运行前会与上游 config.conf 自动核对）：
  a = 全部协议
  b = VLESS + Reality / XTLS Vision       TCP，默认高速主协议
  c = Hysteria2                           UDP / QUIC
  d = TUIC v5                             UDP / QUIC
  e = ShadowTLS                           TCP
  f = Shadowsocks                         TCP/UDP 能力
  g = Trojan                              TCP
  h = VMess + WebSocket                   TCP，需要域名/Argo
  i = VLESS + WebSocket + TLS             TCP，需要域名/Argo
  j = VLESS + H2 + Reality                TCP
  k = VLESS + gRPC + Reality              TCP
  l = AnyTLS                              TCP
  m = NaiveProxy                          可能包含 HTTP/2 / QUIC 输出

自动推荐策略：
  仅 TCP：优先 b，避免无意义的多层封装。
  TCP+UDP：b 作为稳定后备，c 作为高吞吐 UDP 主协议；
           资源充足时加入 d，提升客户端选择空间。

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
  [ -n "${TRANSPORT_MODE:-}" ] || choose_transport_mode
  print_protocol_menu

  if [ -z "$PROTOCOL_PROFILE" ]; then
    if [ "$AUTO_INSTALL" = "true" ]; then
      PROTOCOL_PROFILE="auto"
    else
      say "协议配置档："
      say "  1. 自动推荐：按内存、CPU、UDP 和 NAT 情况选择（默认）"
      say "  2. 极简高速：TCP=b；允许 UDP 时=b+c"
      say "  3. 多客户端兼容：TCP=b+g+l；允许 UDP 时=b+c+d+g+l"
      say "  4. 自定义协议字母"
      say "  5. 全协议（不推荐）"
      profile_choice="$(ask "请选择" "1")"
      case "$profile_choice" in
        2) PROTOCOL_PROFILE="lean" ;;
        3) PROTOCOL_PROFILE="compat" ;;
        4) PROTOCOL_PROFILE="custom" ;;
        5) PROTOCOL_PROFILE="all" ;;
        *) PROTOCOL_PROFILE="auto" ;;
      esac
    fi
  fi

  case "$PROTOCOL_PROFILE" in
    auto)
      if [ "$ONLY_TCP" = "true" ]; then
        PROTOCOLS="b"
        PROFILE_REASON="TCP-only：Reality 开销低、无域名要求、兼容性好"
      else
        case "$RESOURCE_CLASS" in
          tiny|small)
            PROTOCOLS="bc"
            PROFILE_REASON="资源较小：Reality 后备 + Hysteria2 高吞吐"
            ;;
          medium)
            if [ "$NAT_LIMITED" = "true" ]; then
              PROTOCOLS="bc"
              PROFILE_REASON="NAT 端口有限：仅保留 Reality + Hysteria2"
            else
              PROTOCOLS="bcd"
              PROFILE_REASON="资源适中：Reality + Hysteria2 + TUIC"
            fi
            ;;
          large|xlarge)
            if [ "$NAT_LIMITED" = "true" ]; then
              PROTOCOLS="bcd"
              PROFILE_REASON="资源充足但 NAT 端口有限：三种核心协议"
            else
              PROTOCOLS="bcdl"
              PROFILE_REASON="资源充足：核心 TCP/UDP 协议并加入 AnyTLS 后备"
            fi
            ;;
          *)
            PROTOCOLS="bc"
            PROFILE_REASON="通用安全推荐"
            ;;
        esac
      fi
      ;;
    lean)
      if [ "$ONLY_TCP" = "true" ]; then
        PROTOCOLS="b"
      else
        PROTOCOLS="bc"
      fi
      PROFILE_REASON="极简高速配置"
      ;;
    compat)
      if [ "$ONLY_TCP" = "true" ]; then
        PROTOCOLS="bgl"
      else
        PROTOCOLS="bcdgl"
      fi
      PROFILE_REASON="多客户端兼容配置"
      ;;
    all)
      if [ "$ONLY_TCP" = "true" ]; then
        warn "严格 TCP 模式不能选择全部协议，自动改为 bgl。"
        PROTOCOLS="bgl"
      else
        PROTOCOLS="a"
      fi
      PROFILE_REASON="全部协议"
      ;;
    custom)
      if [ "$ONLY_TCP" = "true" ]; then
        default_protocols="b"
      else
        default_protocols="bc"
      fi

      while :; do
        PROTOCOLS="$(ask "请输入协议字母组合" "$default_protocols")"
        PROTOCOLS="$(normalize_protocols "$PROTOCOLS")"
        validate_protocols "$PROTOCOLS" "$ONLY_TCP"
        rc=$?
        if [ "$rc" -eq 0 ]; then
          break
        elif [ "$rc" -eq 2 ]; then
          warn "严格 TCP 模式不能使用 a/c/d/f/m。"
        else
          warn "协议组合无效；a 不能与其他字母混用。"
        fi
      done
      PROFILE_REASON="用户自定义"
      ;;
    *)
      die "SB_PROFILE 必须为 auto、lean、compat、custom 或 all。"
      ;;
  esac

  validate_protocols "$PROTOCOLS" "$ONLY_TCP" ||
    die "自动生成的协议组合未通过校验：$PROTOCOLS"

  info "自动评估：CPU=${CPU_CORES}核，内存=${MEM_MB}MB，资源级别=${RESOURCE_CLASS}"
  info "协议选择：$PROTOCOLS"
  info "选择原因：$PROFILE_REASON"
}

interactive_config() {
  say
  say "======================================"
  say " Sing-box 引导式安装器 v${VERSION}"
  say "======================================"

  LANGUAGE="$(ask "语言：c=中文，e=英文" "c")"
  case "$LANGUAGE" in c|e) ;; *) LANGUAGE="c" ;; esac

  [ -n "${TRANSPORT_MODE:-}" ] || choose_transport_mode

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

  if [ "$AUTO_INSTALL" = "true" ] || [ "$LOW_MEMORY" = "true" ]; then
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
    warn "Hysteria2 依赖 UDP/QUIC，请确认对应 UDP 公网端口已放行。"
    if [ "$NAT_LIMITED" = "true" ]; then
      info "NAT 限端口模式：不启用 Hysteria2 端口跳跃。"
    elif confirm "启用 Hysteria2 端口跳跃？" "n"; then
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
  say "传输模式：$TRANSPORT_MODE"
  say "TCP-only：$ONLY_TCP"
  say "NAT 限端口：$NAT_LIMITED"
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


alpine_openrc_preflight() {
  [ "${OS_ID:-}" = "alpine" ] || return 0

  # Minimal LXC images sometimes have OpenRC installed but no runtime marker.
  # Creating softlevel is the conventional way to make rc-service usable in
  # an already-running container; no kernel/init replacement is attempted.
  mkdir -p /run/openrc 2>/dev/null || true
  [ -e /run/openrc/softlevel ] || : > /run/openrc/softlevel 2>/dev/null || true

  if ! has rc-service || ! has rc-update; then
    die "Alpine 缺少 rc-service/rc-update；请确认 openrc 已安装。"
  fi

  ok "Alpine OpenRC 运行环境预检完成。"
}

file_sha256() {
  file="$1"
  if has sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  elif has openssl; then
    openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
  else
    printf "unavailable
"
  fi
}

print_install_failure_diagnostics() {
  say
  warn "安装失败诊断："

  if [ "${OS_ID:-}" = "alpine" ]; then
    if has rc-service; then
      rc-service sing-box status 2>&1 || true
    fi
    [ -e /run/openrc/softlevel ] &&
      info "/run/openrc/softlevel：存在" ||
      warn "/run/openrc/softlevel：不存在"
  fi

  [ -e /etc/init.d/sing-box ] &&
    ls -l /etc/init.d/sing-box 2>/dev/null || true
  [ -e /etc/sing-box/sing-box ] &&
    ls -lh /etc/sing-box/sing-box 2>/dev/null || true

  if grep -q 'Sing-box 关闭 失败' "$LOG_PATH" 2>/dev/null; then
    warn "上游日志显示服务停止失败；本包装脚本没有修改或绕过该上游逻辑。"
  fi

  if grep -q 'grep: warning: stray \\ before -' "$LOG_PATH" 2>/dev/null; then
    warn "日志包含 BusyBox grep 的兼容警告；为保持上游原样，本脚本没有改写该语句。"
  fi
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

  # Only prepare the host environment. The downloaded upstream file is never
  # edited, patched, reformatted or sourced by this wrapper.
  alpine_openrc_preflight

  UPSTREAM_SHA256_BEFORE="$(file_sha256 "$OFFICIAL_SCRIPT_PATH")"
  info "原版上游脚本 SHA256：$UPSTREAM_SHA256_BEFORE"
  ok "上游安装器保持原始内容，未做任何源码修改。"
}

run_install() {
  info "开始调用原版上游安装器；日志：$LOG_PATH"
  info "调用方式：bash <official-sing-box.sh> -f <generated-config.conf>"
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

  UPSTREAM_SHA256_AFTER="$(file_sha256 "$OFFICIAL_SCRIPT_PATH")"
  if [ "${UPSTREAM_SHA256_BEFORE:-unavailable}" != "unavailable" ] &&
     [ "$UPSTREAM_SHA256_AFTER" != "$UPSTREAM_SHA256_BEFORE" ]; then
    warn "上游脚本文件在执行期间发生变化："
    warn "执行前：$UPSTREAM_SHA256_BEFORE"
    warn "执行后：$UPSTREAM_SHA256_AFTER"
  else
    ok "已确认执行的是未修改的原版上游脚本。"
  fi

  if [ "$rc" -ne 0 ]; then
    print_install_failure_diagnostics
    die "原版上游安装器返回错误码 $rc。请查看：$LOG_PATH"
  fi
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


tune_service_limits() {
  case "$RESOURCE_CLASS" in
    tiny) NOFILE_LIMIT=65535 ;;
    small) NOFILE_LIMIT=131072 ;;
    medium) NOFILE_LIMIT=262144 ;;
    large|xlarge) NOFILE_LIMIT=524288 ;;
    *) NOFILE_LIMIT=131072 ;;
  esac

  if has systemctl && systemctl cat sing-box.service >/dev/null 2>&1; then
    override_dir="/etc/systemd/system/sing-box.service.d"
    mkdir -p "$override_dir" || return 0
    cat > "${override_dir}/99-sb-guide-limits.conf" <<EOF
[Service]
LimitNOFILE=${NOFILE_LIMIT}
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || true
    ok "systemd sing-box 文件句柄上限：$NOFILE_LIMIT"
    return 0
  fi

  if has rc-service && [ -f /etc/init.d/sing-box ]; then
    conf="/etc/conf.d/sing-box"
    touch "$conf" 2>/dev/null || return 0
    tmp_conf="${conf}.tmp.$$"
    grep -v '^[[:space:]]*rc_ulimit=' "$conf" > "$tmp_conf" 2>/dev/null || true
    printf 'rc_ulimit="-n %s"\n' "$NOFILE_LIMIT" >> "$tmp_conf"
    mv "$tmp_conf" "$conf"
    rc-service sing-box restart >/dev/null 2>&1 || true
    ok "OpenRC sing-box 文件句柄上限：$NOFILE_LIMIT"
  fi
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


snapshot_network_state() {
  # Keep the first pre-tuning state so --rollback-net can restore it.
  [ -s "$NETWORK_STATE_PATH" ] && return 0

  umask 077
  : > "$NETWORK_STATE_PATH"

  for key in \
    net.ipv4.tcp_congestion_control \
    net.core.default_qdisc \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.rmem_default \
    net.core.wmem_default \
    net.core.optmem_max \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_max_syn_backlog \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_window_scaling \
    net.ipv4.tcp_sack \
    net.ipv4.tcp_timestamps \
    net.ipv4.tcp_syncookies \
    net.ipv4.tcp_moderate_rcvbuf \
    net.ipv4.tcp_autocorking \
    net.ipv4.tcp_early_retrans \
    net.ipv4.tcp_recovery \
    net.ipv4.udp_rmem_min \
    net.ipv4.udp_wmem_min \
    net.ipv4.tcp_retries2 \
    net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_keepalive_time \
    net.ipv4.tcp_keepalive_intvl \
    net.ipv4.tcp_keepalive_probes \
    net.ipv4.ip_local_port_range \
    fs.file-max
  do
    if sysctl_key_exists "$key"; then
      value="$(sysctl -n "$key" 2>/dev/null || true)"
      [ -n "$value" ] && printf '%s=%s\n' "$key" "$value" >> "$NETWORK_STATE_PATH"
    fi
  done

  chmod 600 "$NETWORK_STATE_PATH" 2>/dev/null || true
  ok "已保存优化前参数：$NETWORK_STATE_PATH"
}

rollback_network() {
  need_root
  prepare_workdir

  if [ ! -s "$NETWORK_STATE_PATH" ]; then
    die "找不到优化前参数快照：$NETWORK_STATE_PATH"
  fi

  warn "正在恢复优化前的 sysctl 参数。"
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    if sysctl_key_exists "$key"; then
      if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
        ok "已恢复：$key=$value"
      else
        warn "恢复失败：$key"
      fi
    fi
  done < "$NETWORK_STATE_PATH"

  rm -f "$SYSCTL_PATH"

  # Remove the explicitly attached root qdisc, allowing the interface/kernel
  # default to take over again. This is best-effort.
  if has ip && has tc; then
    main_if="$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
    [ -n "$main_if" ] && tc qdisc del dev "$main_if" root >/dev/null 2>&1 || true
  fi

  ok "回滚完成。持久化文件已移除：$SYSCTL_PATH"
  show_network_status
}

network_optimize() {
  say
  say "======================================"
  say " 自适应网络优化：BBR / FQ / TCP / UDP"
  say "======================================"

  has sysctl || {
    warn "缺少 sysctl，无法应用网络参数。"
    show_network_status
    return
  }

  [ -n "${TRANSPORT_MODE:-}" ] || choose_transport_mode
  detect_virtualization
  detect_resources
  show_network_status

  available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"

  if ! printf '%s
' "$available" | grep -qw bbr; then
    if [ "$IS_CONTAINER" = "false" ] && has modprobe; then
      modprobe tcp_bbr >/dev/null 2>&1 || true
      available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
    fi
  fi

  snapshot_network_state

  temp_sysctl="${WORK_DIR}/sysctl.$$"
  : > "$temp_sysctl"

  # BBR/FQ applies to TCP. QUIC protocols maintain their own user-space CC.
  if printf '%s
' "$available" | grep -qw bbr; then
    apply_one_sysctl "net.ipv4.tcp_congestion_control" "bbr" "$temp_sysctl" || true
  elif printf '%s
' "$available" | grep -qw cubic; then
    apply_one_sysctl "net.ipv4.tcp_congestion_control" "cubic" "$temp_sysctl" || true
    warn "运行内核没有注册 BBR，已使用 CUBIC。"
  else
    warn "运行内核没有 BBR/CUBIC 可供选择，保留当前拥塞控制。"
  fi

  case "$RESOURCE_CLASS" in
    tiny)
      BUF_MAX=8388608
      UDP_DEFAULT=131072
      BACKLOG=4096
      SOMAX=4096
      FILE_MAX=131072
      ;;
    small)
      BUF_MAX=16777216
      UDP_DEFAULT=262144
      BACKLOG=8192
      SOMAX=8192
      FILE_MAX=262144
      ;;
    medium)
      BUF_MAX=33554432
      UDP_DEFAULT=524288
      BACKLOG=16384
      SOMAX=16384
      FILE_MAX=524288
      ;;
    large)
      BUF_MAX=67108864
      UDP_DEFAULT=1048576
      BACKLOG=32768
      SOMAX=32768
      FILE_MAX=1048576
      ;;
    xlarge)
      BUF_MAX=134217728
      UDP_DEFAULT=2097152
      BACKLOG=65536
      SOMAX=65535
      FILE_MAX=2097152
      ;;
    *)
      BUF_MAX=33554432
      UDP_DEFAULT=524288
      BACKLOG=16384
      SOMAX=16384
      FILE_MAX=524288
      ;;
  esac

  # Scale packet backlog on multi-core machines without making tiny nodes absurd.
  if [ "$CPU_CORES" -ge 8 ] 2>/dev/null && [ "$BACKLOG" -lt 65536 ] 2>/dev/null; then
    BACKLOG=$((BACKLOG * 2))
    [ "$BACKLOG" -le 65536 ] || BACKLOG=65536
  elif [ "$CPU_CORES" -ge 4 ] 2>/dev/null && [ "$BACKLOG" -lt 32768 ] 2>/dev/null; then
    BACKLOG=$((BACKLOG + BACKLOG / 2))
    [ "$BACKLOG" -le 32768 ] || BACKLOG=32768
  fi

  info "资源级别：$RESOURCE_CLASS"
  info "TCP 自动缓冲上限：$((BUF_MAX / 1024 / 1024)) MiB"
  info "netdev backlog：$BACKLOG"
  info "文件句柄总上限：$FILE_MAX"

  apply_one_sysctl "net.core.rmem_max" "$BUF_MAX" "$temp_sysctl" || true
  apply_one_sysctl "net.core.wmem_max" "$BUF_MAX" "$temp_sysctl" || true
  apply_one_sysctl "net.core.optmem_max" "65536" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_rmem" "4096 131072 $BUF_MAX" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_wmem" "4096 65536 $BUF_MAX" "$temp_sysctl" || true
  apply_one_sysctl "net.core.netdev_max_backlog" "$BACKLOG" "$temp_sysctl" || true
  apply_one_sysctl "net.core.somaxconn" "$SOMAX" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_max_syn_backlog" "$SOMAX" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_fastopen" "3" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_mtu_probing" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_slow_start_after_idle" "0" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_window_scaling" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_sack" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_timestamps" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_syncookies" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_moderate_rcvbuf" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_autocorking" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_early_retrans" "3" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.tcp_recovery" "1" "$temp_sysctl" || true
  apply_one_sysctl "net.ipv4.ip_local_port_range" "10240 65535" "$temp_sysctl" || true
  apply_one_sysctl "fs.file-max" "$FILE_MAX" "$temp_sysctl" || true

  if [ "$UDP_ENABLED" = "true" ]; then
    info "正在应用 UDP/QUIC 自适应缓冲配置。"
    apply_one_sysctl "net.core.rmem_default" "$UDP_DEFAULT" "$temp_sysctl" || true
    apply_one_sysctl "net.core.wmem_default" "$UDP_DEFAULT" "$temp_sysctl" || true
    apply_one_sysctl "net.ipv4.udp_rmem_min" "16384" "$temp_sysctl" || true
    apply_one_sysctl "net.ipv4.udp_wmem_min" "16384" "$temp_sysctl" || true
  fi

  # Set fq as the default where possible. veth devices may still show noqueue.
  if has modprobe && [ "$IS_CONTAINER" = "false" ]; then
    modprobe sch_fq >/dev/null 2>&1 || true
  fi
  apply_one_sysctl "net.core.default_qdisc" "fq" "$temp_sysctl" || true

  if [ "$IS_CONTAINER" = "false" ] && has ip && has tc; then
    MAIN_IF="$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
    if [ -n "$MAIN_IF" ]; then
      if tc qdisc replace dev "$MAIN_IF" root fq >/dev/null 2>&1; then
        ok "当前接口 $MAIN_IF 已应用 fq。"
      else
        warn "无法在接口 $MAIN_IF 直接应用 fq；保留内核/虚拟化平台的队列。"
      fi
    fi
  else
    warn "容器环境不强改 veth 根 qdisc；宿主机可能显示 noqueue。"
  fi

  # Keep common offloads enabled when the virtual/physical NIC allows it.
  if [ "$IS_CONTAINER" = "false" ] && has ethtool && has ip; then
    MAIN_IF="$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
    if [ -n "$MAIN_IF" ]; then
      ethtool -K "$MAIN_IF" gro on gso on tso on >/dev/null 2>&1 || true
      info "已尝试保持 $MAIN_IF 的 GRO/GSO/TSO 开启。"
    fi
  fi

  governor_changed="false"
  for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$governor" ] || continue
    if printf 'performance
' > "$governor" 2>/dev/null; then
      governor_changed="true"
    fi
  done
  [ "$governor_changed" = "true" ] && ok "CPU governor 已切换为 performance。"

  if [ -s "$temp_sysctl" ]; then
    if [ -f "$SYSCTL_PATH" ]; then
      backup="${SYSCTL_PATH}.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'old')"
      cp "$SYSCTL_PATH" "$backup" 2>/dev/null || true
      info "旧配置已备份：$backup"
    fi
    {
      printf '# Managed by sb-guide-universal-v3.0.3-upstream-clean.sh v%s
' "$VERSION"
      printf '# Resource class: %s; transport: %s
' "$RESOURCE_CLASS" "$TRANSPORT_MODE"
      cat "$temp_sysctl"
    } > "$SYSCTL_PATH"
    chmod 644 "$SYSCTL_PATH" 2>/dev/null || true
    ok "持久化网络配置：$SYSCTL_PATH"
  else
    warn "没有网络参数成功写入。"
  fi

  rm -f "$temp_sysctl"
  show_network_status

  current="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
  if [ "$current" = "bbr" ]; then
    ok "BBR 已对新建 TCP 连接生效。"
  else
    warn "当前 TCP 拥塞控制：${current:-未知}"
  fi

  if [ "$UDP_ENABLED" = "true" ]; then
    info "Hysteria2/TUIC 的 QUIC 拥塞控制位于应用层；系统 BBR 主要优化 TCP 协议。"
  fi

  if [ "$IS_CONTAINER" = "true" ] && ! printf '%s
' "$available" | grep -qw bbr; then
    warn "容器无法自行替换宿主内核；若要 BBR，需要商家宿主提供或更换 KVM。"
  fi

  warn "脚本不能突破商家端口限速、CPU 配额、共享带宽或线路本身的物理上限。"
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
  say "  sh $0 --auto-tcp"
  say "  sh $0 --auto-udp"
  say "  sh $0 --net-only"
  say "  sh $0 --rollback-net"
}

main() {
  case "$MODE" in
    --help|-h|help)
      say "用法："
      say "  sh $0                 引导式自动安装"
      say "  sh $0 --auto-tcp      无人值守：仅 TCP，自动选择 Reality"
      say "  sh $0 --auto-udp      无人值守：确认 UDP 入站可用，自动选择 TCP+UDP 协议"
      say "  sh $0 --net-only      只应用自适应 BBR/FQ/TCP/UDP 优化"
      say "  sh $0 --rollback-net  恢复首次优化前参数"
      say "  sh $0 --check         只查看网络状态"
      say
      say "环境变量："
      say "  SB_TRANSPORT_MODE=tcp|udp|auto"
      say "  SB_PROFILE=auto|lean|compat|custom|all"
      say "  SB_NAT_LIMITED=true|false"
      say
      say "安装原则：原样下载并执行官方 sing-box.sh；不对上游源码打补丁。"
      exit 0
      ;;
    --auto-tcp|auto-tcp)
      AUTO_INSTALL="true"
      TRANSPORT_MODE="tcp"
      PROTOCOL_PROFILE="auto"
      MODE="install"
      ;;
    --auto-udp|auto-udp)
      AUTO_INSTALL="true"
      TRANSPORT_MODE="udp"
      PROTOCOL_PROFILE="auto"
      NAT_LIMITED="${NAT_LIMITED:-false}"
      MODE="install"
      ;;
  esac

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
      choose_transport_mode
      network_optimize
      exit 0
      ;;
    --rollback-net|rollback-net)
      rollback_network
      exit 0
      ;;
    --help|-h|help)
      say "用法："
      say "  sh $0                 引导式自动安装"
      say "  sh $0 --auto-tcp      无人值守：仅 TCP，自动选择 Reality"
      say "  sh $0 --auto-udp      无人值守：确认 UDP 入站可用，自动选择 TCP+UDP 协议"
      say "  sh $0 --net-only      只应用自适应 BBR/FQ/TCP/UDP 优化"
      say "  sh $0 --rollback-net  恢复首次优化前参数"
      say "  sh $0 --check         只查看网络状态"
      say
      say "环境变量："
      say "  SB_TRANSPORT_MODE=tcp|udp|auto"
      say "  SB_PROFILE=auto|lean|compat|custom|all"
      say "  SB_NAT_LIMITED=true|false"
      say
      say "安装原则：原样下载并执行官方 sing-box.sh；不对上游源码打补丁。"
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

  verify_upstream_protocol_map
  choose_transport_mode

  if confirm "安装前应用自适应 BBR/FQ 与 TCP/UDP 网络优化？" "y"; then
    network_optimize
  fi

  interactive_config
  write_config
  download_official_script
  run_install
  tune_service_limits
  post_check
  export_nodes
  print_summary
}

main "$@"
