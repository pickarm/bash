#!/usr/bin/env sh
# sb-guide.sh
# Guided wrapper for fscarmen/sing-box
# 用途：系统检测、依赖安装、交互生成 config.conf，然后调用官方 sing-box.sh -f 安装
# 建议：以 root 执行

set -u

OFFICIAL_SCRIPT_URL="${OFFICIAL_SCRIPT_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh}"
WORK_DIR="${WORK_DIR:-/root}"
OFFICIAL_SCRIPT_PATH="${WORK_DIR}/sing-box.sh"
CONFIG_PATH="${WORK_DIR}/sb-guide.conf"
LOG_PATH="${WORK_DIR}/sb-guide-install.log"

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
RESET="$(printf '\033[0m')"

say() {
  printf "%s\n" "$*"
}

info() {
  printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"
}

ok() {
  printf "%s[OK]%s %s\n" "$GREEN" "$RESET" "$*"
}

warn() {
  printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"
}

die() {
  printf "%s[ERROR]%s %s\n" "$RED" "$RESET" "$*" >&2
  exit 1
}

need_root() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    die "请使用 root 执行。可以先运行：sudo -i 或 su -"
  fi
}

has() {
  command -v "$1" >/dev/null 2>&1
}

pause_enter() {
  printf "按 Enter 继续..."
  # shellcheck disable=SC2034
  read dummy
}

ask() {
  prompt="$1"
  default="$2"

  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi

  read ans
  if [ -z "$ans" ]; then
    printf "%s" "$default"
  else
    printf "%s" "$ans"
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

  printf "%s %s: " "$prompt" "$suffix"
  read ans
  ans="$(printf "%s" "$ans" | tr 'A-Z' 'a-z')"

  if [ -z "$ans" ]; then
    ans="$default"
  fi

  case "$ans" in
    y|yes|1|true) return 0 ;;
    *) return 1 ;;
  esac
}

quote_sq() {
  # 输出单引号安全字符串，用于 config.conf
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

detect_os() {
  OS_ID="unknown"
  OS_LIKE=""
  OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
  OS_ARCH="$(uname -m 2>/dev/null || echo unknown)"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
  elif [ "$(uname -s 2>/dev/null)" = "FreeBSD" ]; then
    OS_ID="freebsd"
    OS_NAME="FreeBSD $(freebsd-version 2>/dev/null || true)"
  elif [ -r /etc/openwrt_release ]; then
    OS_ID="openwrt"
    OS_NAME="OpenWrt"
  fi

  info "系统：$OS_NAME"
  info "架构：$OS_ARCH"
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
  elif has emerge; then PM="emerge"
  elif has opkg; then PM="opkg"
  elif has pkg; then PM="pkg"
  else PM=""
  fi

  if [ -n "$PM" ]; then
    info "包管理器：$PM"
  else
    warn "未识别包管理器，后续会跳过自动安装依赖。"
  fi
}

run_cmd() {
  info "执行：$*"
  sh -c "$*"
}

install_deps() {
  say
  info "开始安装常用依赖：bash curl wget ca-certificates tar gzip openssl jq coreutils iproute 等"

  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      run_cmd "apt-get update"
      run_cmd "apt-get install -y --no-install-recommends bash curl wget ca-certificates tar gzip openssl jq coreutils iproute2 procps lsof"
      ;;

    apk)
      run_cmd "apk update"
      run_cmd "apk add --no-cache bash curl wget ca-certificates tar gzip openssl jq coreutils iproute2 procps lsof openrc"
      run_cmd "update-ca-certificates 2>/dev/null || true"
      ;;

    dnf)
      run_cmd "dnf install -y bash curl wget ca-certificates tar gzip openssl jq coreutils iproute procps-ng lsof"
      ;;

    yum)
      run_cmd "yum install -y bash curl wget ca-certificates tar gzip openssl jq coreutils iproute procps-ng lsof || yum install -y epel-release && yum install -y bash curl wget ca-certificates tar gzip openssl jq coreutils iproute procps-ng lsof"
      ;;

    microdnf)
      run_cmd "microdnf install -y bash curl wget ca-certificates tar gzip openssl jq coreutils iproute procps-ng lsof"
      ;;

    pacman)
      run_cmd "pacman -Sy --noconfirm --needed bash curl wget ca-certificates tar gzip openssl jq coreutils iproute2 procps-ng lsof"
      ;;

    zypper)
      run_cmd "zypper --non-interactive refresh || true"
      run_cmd "zypper --non-interactive install bash curl wget ca-certificates tar gzip openssl jq coreutils iproute2 procps lsof"
      ;;

    xbps)
      run_cmd "xbps-install -Sy bash curl wget ca-certificates tar gzip openssl jq coreutils iproute2 procps-ng lsof"
      ;;

    emerge)
      run_cmd "emerge --sync || true"
      run_cmd "emerge app-shells/bash net-misc/curl net-misc/wget app-misc/ca-certificates app-arch/tar app-arch/gzip dev-libs/openssl app-misc/jq sys-apps/coreutils sys-apps/iproute2 app-admin/procps sys-process/lsof"
      ;;

    opkg)
      run_cmd "opkg update"
      run_cmd "opkg install bash curl wget ca-bundle ca-certificates tar gzip openssl-util jq coreutils ip-full procps-ng-pgrep lsof || true"
      warn "OpenWrt/Entware 类系统可能能装依赖，但官方 sing-box.sh 不一定支持。"
      ;;

    pkg)
      run_cmd "pkg update -f || true"
      run_cmd "pkg install -y bash curl wget ca_root_nss gtar gzip openssl jq coreutils lsof || true"
      warn "FreeBSD 可以安装依赖，但官方 sing-box.sh 主要面向 Linux VPS，可能会退出。"
      ;;

    *)
      warn "跳过依赖安装。请手动安装：bash curl wget ca-certificates tar gzip openssl jq coreutils iproute2"
      ;;
  esac

  if ! has bash; then
    die "没有找到 bash。官方脚本需要 bash，请先安装 bash 后再运行。"
  fi

  ok "依赖检查完成。"
}

fetch_stdout() {
  url="$1"
  if has curl; then
    curl -fsSL --max-time 8 "$url" 2>/dev/null || true
  elif has wget; then
    wget -qO- --timeout=8 "$url" 2>/dev/null || true
  else
    return 0
  fi
}

fetch_file() {
  url="$1"
  out="$2"

  if has curl; then
    curl -fsSL --max-time 30 "$url" -o "$out"
  elif has wget; then
    wget -qO "$out" "$url"
  else
    die "没有 curl 或 wget，无法下载官方脚本。"
  fi
}

valid_ip_like() {
  ip="$1"

  case "$ip" in
    ""|*" "*|*"	"*) return 1 ;;
  esac

  # IPv4 粗略判断
  case "$ip" in
    *.*)
      case "$ip" in
        *[!0-9.]* ) return 1 ;;
        * ) return 0 ;;
      esac
      ;;
  esac

  # IPv6 粗略判断
  case "$ip" in
    *:*)
      case "$ip" in
        *[!0-9a-fA-F:]* ) return 1 ;;
        * ) return 0 ;;
      esac
      ;;
  esac

  return 1
}

detect_server_ip() {
  DETECTED_IP=""

  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip" \
    "https://api64.ipify.org"
  do
    ip="$(fetch_stdout "$url" | tr -d '\r\n ')"
    if valid_ip_like "$ip"; then
      DETECTED_IP="$ip"
      break
    fi
  done

  if [ -z "$DETECTED_IP" ] && has ip; then
    ip_local="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
    if valid_ip_like "$ip_local"; then
      DETECTED_IP="$ip_local"
    fi
  fi

  if [ -n "$DETECTED_IP" ]; then
    info "自动检测到服务器 IP：$DETECTED_IP"
  else
    warn "未能自动检测服务器公网 IP。"
  fi
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi

  if has uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
    return
  fi

  if has openssl; then
    hex="$(openssl rand -hex 16)"
    printf "%s-%s-%s-%s-%s\n" \
      "$(printf "%s" "$hex" | cut -c1-8)" \
      "$(printf "%s" "$hex" | cut -c9-12)" \
      "$(printf "%s" "$hex" | cut -c13-16)" \
      "$(printf "%s" "$hex" | cut -c17-20)" \
      "$(printf "%s" "$hex" | cut -c21-32)"
    return
  fi

  date +%s | awk '{printf "00000000-0000-4000-8000-%012d\n",$1}'
}

valid_port() {
  p="$1"
  case "$p" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [ "$p" -ge 100 ] 2>/dev/null && [ "$p" -le 65520 ] 2>/dev/null
}

contains_char() {
  str="$1"
  ch="$2"
  case "$str" in
    *"$ch"*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_protocols() {
  protocols="$1"
  only_tcp="$2"

  [ -n "$protocols" ] || return 1

  case "$protocols" in
    *[!abcdefghijklm]*)
      return 1
      ;;
  esac

  if [ "$only_tcp" = "true" ]; then
    case "$protocols" in
      *a*|*c*|*d*|*m*)
        return 2
        ;;
    esac
  fi

  return 0
}

print_protocol_menu() {
  cat <<'EOF'

协议字母说明：
  a = 全部协议
  b = VLESS + Reality
  c = Hysteria2                 UDP/QUIC，不适合 UDP 被禁
  d = Tuic V5                   UDP/QUIC，不适合 UDP 被禁
  e = ShadowTLS
  f = Shadowsocks
  g = Trojan
  h = VMESS + WebSocket         需要 Argo 或域名回源
  i = VLESS + WebSocket + TLS   需要 Argo 或域名回源
  j = VLESS + H2 + Reality
  k = VLESS + gRPC + Reality
  l = AnyTLS
  m = NaiveProxy                官方会同时输出 http2/quic，TCP-only 时不建议选

TCP-only 推荐：
  befgjkl      不含 WS，不需要 Argo/域名
  befghijkl    包含 WS，需要 Argo 临时隧道或你自己的域名

EOF
}

count_protocols() {
  p="$1"
  if [ "$p" = "a" ]; then
    echo 12
    return
  fi
  printf "%s" "$p" | sed 's/./& /g' | wc -w | awk '{print $1}'
}

interactive_config() {
  say
  say "=============================="
  say " Sing-box 引导式安装配置"
  say "=============================="
  say

  LANGUAGE="$(ask "语言：c=中文，e=英文" "c")"
  case "$LANGUAGE" in
    c|e) ;;
    *) LANGUAGE="c" ;;
  esac

  detect_server_ip
  SERVER_IP="$(ask "服务器公网 IP" "$DETECTED_IP")"
  [ -n "$SERVER_IP" ] || die "SERVER_IP 不能为空。"

  DEFAULT_NODE="$(hostname 2>/dev/null || echo sb-node)"
  if confirm "是否自定义节点名？" "y"; then
    NODE_NAME="$(ask "请输入节点名，例如 SG-01 / HK-01-A / 🇸🇬 SG-01" "$DEFAULT_NODE")"
  else
    NODE_NAME="$DEFAULT_NODE"
  fi

  if confirm "是否只安装 TCP 类协议？UDP 被禁建议选 Yes" "y"; then
    ONLY_TCP="true"
    DEFAULT_PROTOCOLS="befgjkl"
  else
    ONLY_TCP="false"
    DEFAULT_PROTOCOLS="a"
  fi

  print_protocol_menu

  while :; do
    PROTOCOLS="$(ask "请输入协议字母组合" "$DEFAULT_PROTOCOLS")"
    validate_protocols "$PROTOCOLS" "$ONLY_TCP"
    rc="$?"
    if [ "$rc" = "0" ]; then
      break
    elif [ "$rc" = "2" ]; then
      warn "你选择了 TCP-only，但协议里包含 a/c/d/m。TCP-only 不允许 all、Hysteria2、Tuic、NaiveProxy。"
      warn "推荐输入：befgjkl"
    else
      warn "协议字母不合法。"
    fi
  done

  if confirm "是否自定义协议起始端口？官方脚本会按协议顺序依次递增" "y"; then
    while :; do
      START_PORT="$(ask "请输入起始端口，范围 100-65520" "8881")"
      if valid_port "$START_PORT"; then
        break
      fi
      warn "端口不合法。"
    done
  else
    START_PORT="8881"
  fi

  proto_count="$(count_protocols "$PROTOCOLS")"
  end_port=$((START_PORT + proto_count - 1))
  info "协议将大致占用连续端口：${START_PORT}-${end_port}"

  UUID_CONFIRM="$(ask "UUID/密码，留空自动生成" "")"
  if [ -z "$UUID_CONFIRM" ]; then
    UUID_CONFIRM="$(gen_uuid)"
  fi

  if confirm "是否启用订阅输出？建议 Yes" "y"; then
    SUBSCRIBE="true"
    if confirm "是否自定义订阅 Nginx 端口？" "n"; then
      while :; do
        PORT_NGINX="$(ask "请输入订阅端口" "21865")"
        if valid_port "$PORT_NGINX"; then
          break
        fi
        warn "端口不合法。"
      done
    else
      PORT_NGINX=""
    fi
  else
    SUBSCRIBE="false"
    PORT_NGINX=""
  fi

  # WS 协议 h/i 需要 Argo 或 Origin Rule 域名
  VMESS_HOST_DOMAIN=""
  VLESS_HOST_DOMAIN=""
  CDN=""
  ARGO="false"
  ARGO_DOMAIN=""
  ARGO_AUTH=""

  if contains_char "$PROTOCOLS" "h" || contains_char "$PROTOCOLS" "i" || [ "$PROTOCOLS" = "a" ]; then
    say
    warn "你选择了 WebSocket 类协议 h/i。它们需要 Argo 临时隧道，或者你自己的域名 + Origin Rule。"

    if confirm "是否使用 Argo 临时隧道？没有域名建议 Yes" "y"; then
      ARGO="true"
      ARGO_DOMAIN=""
      ARGO_AUTH=""
    else
      ARGO="false"
      if contains_char "$PROTOCOLS" "h" || [ "$PROTOCOLS" = "a" ]; then
        VMESS_HOST_DOMAIN="$(ask "请输入 VMESS WS 域名" "")"
      fi
      if contains_char "$PROTOCOLS" "i" || [ "$PROTOCOLS" = "a" ]; then
        VLESS_HOST_DOMAIN="$(ask "请输入 VLESS WS TLS 域名" "")"
      fi
      CDN="$(ask "请输入 CDN/优选域名，留空使用官方默认" "")"
    fi
  fi

  HY2_PORT_HOPPING_RANGE=""
  HY2_REALM=""
  HY2_WARP=""

  if contains_char "$PROTOCOLS" "c" || [ "$PROTOCOLS" = "a" ]; then
    say
    warn "你选择了 Hysteria2。它依赖 UDP/QUIC。"

    if confirm "是否启用 Hysteria2 端口跳跃？" "n"; then
      HY2_PORT_HOPPING_RANGE="$(ask "请输入端口跳跃范围，例如 50000:51000" "50000:51000")"
    fi

    if confirm "是否启用 Hysteria2 Realm？一般公网 VPS 不需要" "n"; then
      HY2_REALM="true"
      if confirm "是否启用 WARP 辅助打洞？" "n"; then
        HY2_WARP="true"
      else
        HY2_WARP="false"
      fi
    else
      HY2_REALM="false"
      HY2_WARP="false"
    fi
  fi

  REALITY_PRIVATE="$(ask "Reality privateKey，留空由官方脚本随机生成" "")"

  say
  say "=============================="
  say " 配置确认"
  say "=============================="
  say "语言：$LANGUAGE"
  say "服务器 IP：$SERVER_IP"
  say "节点名：$NODE_NAME"
  say "协议：$PROTOCOLS"
  say "TCP-only：$ONLY_TCP"
  say "起始端口：$START_PORT"
  say "订阅：$SUBSCRIBE"
  [ -n "$PORT_NGINX" ] && say "订阅端口：$PORT_NGINX"
  say "Argo：$ARGO"
  [ -n "$VMESS_HOST_DOMAIN" ] && say "VMESS 域名：$VMESS_HOST_DOMAIN"
  [ -n "$VLESS_HOST_DOMAIN" ] && say "VLESS 域名：$VLESS_HOST_DOMAIN"
  [ -n "$CDN" ] && say "CDN：$CDN"
  say

  if ! confirm "确认开始安装？" "y"; then
    die "用户取消。"
  fi
}

write_config() {
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

  ok "已生成配置文件：$CONFIG_PATH"
  say
  cat "$CONFIG_PATH"
  say
}

download_official_script() {
  info "下载官方 sing-box.sh：$OFFICIAL_SCRIPT_URL"
  fetch_file "$OFFICIAL_SCRIPT_URL" "$OFFICIAL_SCRIPT_PATH" || die "下载官方脚本失败。"
  chmod +x "$OFFICIAL_SCRIPT_PATH"
  ok "官方脚本已保存：$OFFICIAL_SCRIPT_PATH"
}

run_install() {
  say
  info "开始调用官方脚本安装：bash $OFFICIAL_SCRIPT_PATH -f $CONFIG_PATH"
  say "安装日志会同时保存到：$LOG_PATH"
  say

  # 使用 tee 记录日志；部分极简系统可能没有 tee，但 coreutils/busybox 通常都有
  if has tee; then
    bash "$OFFICIAL_SCRIPT_PATH" -f "$CONFIG_PATH" 2>&1 | tee "$LOG_PATH"
  else
    bash "$OFFICIAL_SCRIPT_PATH" -f "$CONFIG_PATH"
  fi
}

export_nodes() {
  say
  say "=============================="
  say " 节点信息输出"
  say "=============================="

  if has sb; then
    sb -n
  elif [ -x "$OFFICIAL_SCRIPT_PATH" ]; then
    bash "$OFFICIAL_SCRIPT_PATH" -n
  else
    warn "没有找到 sb 命令。你可以手动查看：/etc/sing-box/subscribe/"
  fi

  say
  say "常用命令："
  say "  sb -n    查看节点/订阅"
  say "  sb -d    修改节点配置"
  say "  sb -r    增删协议"
  say "  sb -s    停止/开启 sing-box"
  say "  sb -u    卸载"
}

post_check() {
  say
  say "=============================="
  say " 安装后检查"
  say "=============================="

  if has sing-box; then
    sing-box version 2>/dev/null || true
  fi

  if has rc-service; then
    rc-service sing-box status 2>/dev/null || true
  elif has systemctl; then
    systemctl status sing-box --no-pager 2>/dev/null || true
  fi

  if [ -f "$LOG_PATH" ]; then
    if grep -q "pbk=&" "$LOG_PATH" 2>/dev/null || grep -q "public-key: ," "$LOG_PATH" 2>/dev/null; then
      warn "检测到 Reality public key 可能为空。若 Reality 节点不能用，请重新运行并填写/生成 Reality privateKey，或先使用 Trojan/ShadowTLS。"
    fi
  fi
}

main() {
  need_root
  detect_os
  detect_pm

  if confirm "是否自动安装/补齐常用依赖？" "y"; then
    install_deps
  else
    warn "跳过依赖安装。"
    if ! has bash; then
      die "未安装 bash，无法继续。"
    fi
  fi

  interactive_config
  write_config
  download_official_script
  run_install
  post_check
  export_nodes
}

main "$@"
