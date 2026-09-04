#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ORIG_CLI_ARGS=("$@")

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="0.0.2"
readonly SCRIPT_INSTALL_PATH="/usr/local/bin/sbox"
readonly SCRIPT_SYMLINK_PATH="/usr/bin/sbox"

readonly CONFIG_DIR="${CONFIG_DIR:-/etc/sing-box}"
readonly CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.json}"
readonly CERT_DIR="${CERT_DIR:-${CONFIG_DIR}/certs}"
readonly STATE_DIR="${STATE_DIR:-/etc/sbox}"
readonly STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.json}"
readonly BACKUP_DIR="${BACKUP_DIR:-${STATE_DIR}/backups}"
readonly TRAFFIC_LOG="${TRAFFIC_LOG:-${STATE_DIR}/traffic_reset.log}"

readonly DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/sing-box"
readonly DNSPOD_CREDENTIAL_FILE="${STATE_DIR}/dnspod.json"
readonly DNSPOD_HOOK="${STATE_DIR}/dnspod-hook"
readonly DNSPOD_AUTH_HOOK="${STATE_DIR}/dnspod-auth"
readonly DNSPOD_CLEANUP_HOOK="${STATE_DIR}/dnspod-cleanup"

readonly CF_CREDENTIAL_FILE="${STATE_DIR}/cf.json"
readonly CF_HOOK="${STATE_DIR}/cf-hook"
readonly CF_AUTH_HOOK="${STATE_DIR}/cf-auth"
readonly CF_CLEANUP_HOOK="${STATE_DIR}/cf-cleanup"

readonly SYSTEMD_SERVICE="sing-box.service"
readonly NFT_TABLE="sing_box_traffic"
readonly CRON_TAG="sing-box-traffic"

readonly API_DIR="${STATE_DIR}/api"
readonly API_CONFIG_FILE="${STATE_DIR}/api.json"
readonly API_SCRIPT_FILE="${API_DIR}/http_server.py"
readonly API_SYSTEMD_SERVICE="sbox-api.service"

OS_ID=""
OS_LIKE=""
PKG_MGR=""
INIT_SYSTEM="systemd"
DOMAIN=""
EMAIL=""
PORT=""
PASSWORD=""
PROTOCOL=""
NODE_NAME=""
NODE_DOMAIN=""
NODE_PORT=""
NODE_PASSWORD=""
NODE_USERNAME=""
HTTP_TLS="false"
CERT_MODE=""
WEBROOT=""
OUTBOUND=""
SS_SERVER=""
SS_PORT=""
SS_METHOD=""
SS_PASSWORD=""
NODE_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_HANDSHAKE_SERVER="www.microsoft.com"
REALITY_HANDSHAKE_PORT="443"
TRAFFIC_BILLING="single"
TRAFFIC_LIMIT="unlimited"
TRAFFIC_RESET_DAY=""
SKIP_PROTOCOL_PROMPT=0
DNSPOD_TOKEN_ID=""
DNSPOD_TOKEN_KEY=""
CF_API_TOKEN=""
CF_API_KEY=""
CF_EMAIL=""
NON_INTERACTIVE=0
DRY_RUN=0
ASSUME_YES=0
FORCE_UPDATE=0

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_RESET=""
fi

info() { printf "%s[信息]%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf "%s[完成]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s[警告]%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf "%s[错误]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
      exec sudo -E bash "$0" "${ORIG_CLI_ARGS[@]}"
    else
      die "请使用 root 权限运行：sudo sbox"
    fi
  fi
}

detect_init_system() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || $(cat /proc/1/comm 2>/dev/null) == "systemd" ]]; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  elif command -v systemctl >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  else
    INIT_SYSTEM="openrc"
  fi
}

detect_os() {
  local os_release="/etc/os-release"
  if [[ -r "$os_release" ]]; then
    # shellcheck disable=SC1091
    . "$os_release"
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  elif [[ -f /etc/redhat-release ]]; then
    OS_ID="centos"
    OS_LIKE="rhel"
  elif [[ -f /etc/alpine-release ]]; then
    OS_ID="alpine"
  else
    OS_ID="unknown"
  fi

  if [[ "$OS_ID" =~ ^(debian|ubuntu|kali|armbian|deepin|linuxmint)$ ]] || [[ "$OS_LIKE" =~ (debian|ubuntu) ]]; then
    PKG_MGR="apt"
  elif [[ "$OS_ID" =~ ^(centos|rhel|almalinux|rocky|fedora|ol|amzn)$ ]] || [[ "$OS_LIKE" =~ (rhel|fedora|centos) ]]; then
    if command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    else
      PKG_MGR="yum"
    fi
  elif [[ "$OS_ID" == "alpine" ]]; then
    PKG_MGR="apk"
  else
    PKG_MGR="unknown"
  fi

  detect_init_system
}

service_is_installed() {
  command -v sing-box >/dev/null 2>&1 || [[ -f "/etc/systemd/system/${SYSTEMD_SERVICE}" ]] || [[ -f "/etc/init.d/sing-box" ]] || [[ -s "$CONFIG_FILE" ]]
}

service_is_running() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl is-active "$service" >/dev/null 2>&1
  else
    rc-service "$name" status >/dev/null 2>&1
  fi
}

service_is_enabled() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl is-enabled "$service" >/dev/null 2>&1
  else
    [[ -e "/etc/runlevels/default/$name" ]] || rc-status default 2>/dev/null | grep -qw "$name"
  fi
}

service_start() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl start "$service"
  else
    rc-service "$name" start
  fi
}

service_stop() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl stop "$service" >/dev/null 2>&1 || true
  else
    rc-service "$name" stop >/dev/null 2>&1 || true
  fi
}

service_restart() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl restart "$service"
  else
    rc-service "$name" restart
  fi
}

service_reload_or_restart() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl reload-or-restart "$service" >/dev/null 2>&1 || systemctl restart "$service"
  else
    rc-service "$name" restart
  fi
}

service_enable() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl enable "$service" >/dev/null 2>&1 || true
  else
    rc-update add "$name" default >/dev/null 2>&1 || true
  fi
}

service_disable() {
  local service=${1:-$SYSTEMD_SERVICE}
  local name="${service%.service}"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl disable --now "$service" >/dev/null 2>&1 || true
  else
    rc-service "$name" stop >/dev/null 2>&1 || true
    rc-update del "$name" default >/dev/null 2>&1 || true
  fi
}

service_daemon_reload() {
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

migrate_legacy_state() {
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"

  # 1. 迁移旧版状态与凭据数据
  if [[ -f "/etc/sing-box/state.json" && ! -f "$STATE_FILE" ]]; then
    mv "/etc/sing-box/state.json" "$STATE_FILE"
  fi
  rm -f "/etc/sing-box/state.json" >/dev/null 2>&1 || true

  if [[ -f "/etc/sing-box/api.json" && ! -f "$API_CONFIG_FILE" ]]; then
    mv "/etc/sing-box/api.json" "$API_CONFIG_FILE"
  fi
  rm -f "/etc/sing-box/api.json" >/dev/null 2>&1 || true

  if [[ -f "/etc/sing-box/dnspod.json" && ! -f "$DNSPOD_CREDENTIAL_FILE" ]]; then
    mv "/etc/sing-box/dnspod.json" "$DNSPOD_CREDENTIAL_FILE"
  fi
  rm -f "/etc/sing-box/dnspod.json" >/dev/null 2>&1 || true
  rm -f "/etc/sing-box/traffic_data.json" >/dev/null 2>&1 || true

  # 2. 迁移旧版 dnspod hooks、日志与备份目录
  local item
  for item in dnspod-auth dnspod-cleanup dnspod-hook traffic_reset.log; do
    if [[ -f "/etc/sing-box/${item}" ]]; then
      if [[ ! -f "${STATE_DIR}/${item}" ]]; then
        mv "/etc/sing-box/${item}" "${STATE_DIR}/${item}" 2>/dev/null || true
      else
        rm -f "/etc/sing-box/${item}" >/dev/null 2>&1 || true
      fi
    fi
  done
  if [[ -d "/etc/sing-box/backups" ]]; then
    cp -a /etc/sing-box/backups/* "$BACKUP_DIR/" 2>/dev/null || true
    rm -rf /etc/sing-box/backups 2>/dev/null || true
  fi

  # 3. 强力清除 /etc/sing-box 下除 config.json 之外的所有 .json 文件
  # 防止 sing-box 在任何情况下因加载配置目录中多余的 json 文件而崩溃
  if [[ -d "/etc/sing-box" ]]; then
    local orphan_json
    shopt -s nullglob
    for orphan_json in /etc/sing-box/*.json; do
      if [[ "${orphan_json##*/}" != "config.json" ]]; then
        mv "$orphan_json" "${BACKUP_DIR}/" 2>/dev/null || rm -f "$orphan_json"
      fi
    done
    shopt -u nullglob
  fi
}

auto_heal_service() {
  migrate_legacy_state
  if [[ -s "$CONFIG_FILE" ]] && command -v sing-box >/dev/null 2>&1; then
    ensure_service_file
    if ! service_is_running; then
      if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        service_restart "$SYSTEMD_SERVICE" >/dev/null 2>&1 || true
      fi
    fi
  fi
}

ensure_sbox_cli() {
  local self_path="" real_self=""
  install -d -m 0755 /usr/local/bin /usr/bin

  # 定位当前正在执行的物理脚本路径
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "/dev/fd/"* ]]; then
    self_path="${BASH_SOURCE[0]}"
  elif [[ -n "${0:-}" && -f "$0" && "$0" != "/dev/fd/"* ]]; then
    self_path="$0"
  fi

  if [[ -n "$self_path" ]]; then
    real_self=$(realpath "$self_path" 2>/dev/null || readlink -f "$self_path" 2>/dev/null || echo "$self_path")
    if [[ "$real_self" != "$SCRIPT_INSTALL_PATH" ]]; then
      cp -f "$real_self" "$SCRIPT_INSTALL_PATH"
      chmod 0755 "$SCRIPT_INSTALL_PATH"
    fi
  elif [[ ! -s "$SCRIPT_INSTALL_PATH" ]]; then
    # 若通过管道 curl | bash 运行，从 GitHub 官方源拉取保存至全局目录
    curl -fsSL https://raw.githubusercontent.com/elunez/sbox/main/sbox.sh -o "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    [[ -s "$SCRIPT_INSTALL_PATH" ]] && chmod 0755 "$SCRIPT_INSTALL_PATH"
  fi

  # 建立双重系统 PATH 软链，保证任何环境无论 PATH 顺序均可在任意目录直接输入 sbox
  if [[ -s "$SCRIPT_INSTALL_PATH" ]]; then
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_SYMLINK_PATH" 2>/dev/null || true
  fi
}

preflight() {
  require_root
  detect_os
  ensure_sbox_cli
  auto_heal_service
}

validate_domain() {
  local value=$1
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" != \*.* ]] || return 1
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_port() {
  local val=${1:-}
  [[ "$val" =~ ^[1-9][0-9]*$ ]] || return 1
  local num=$((10#$val))
  (( num >= 1 && num <= 65535 ))
}

validate_host() {
  [[ -n "$1" && "$1" != *[[:space:]/]* ]]
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validate_ss_method() {
  case "$1" in
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|\
    aes-128-gcm|aes-192-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|\
    aes-128-ctr|aes-192-ctr|aes-256-ctr|aes-128-cfb|aes-192-cfb|aes-256-cfb|\
    rc4-md5|chacha20-ietf|xchacha20|none) return 0 ;;
    *) return 1 ;;
  esac
}

validate_ss_password() {
  local method=$1 password=$2 pattern
  local -a keys=()
  [[ -n "$password" ]] || return 1
  case "$method" in
    2022-blake3-aes-128-gcm) pattern='^[A-Za-z0-9+/]{22}==$' ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) pattern='^[A-Za-z0-9+/]{43}=$' ;;
    *) return 0 ;;
  esac
  [[ "$password" != :* && "$password" != *: && "$password" != *::* ]] || return 1
  IFS=: read -r -a keys <<< "$password"
  ((${#keys[@]} == 1 || ${#keys[@]} == 2)) || return 1
  local key
  for key in "${keys[@]}"; do
    [[ "$key" =~ $pattern ]] || return 1
  done
}

ss2022_key_bytes() {
  case "$1" in
    2022-blake3-aes-128-gcm) printf "16" ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf "32" ;;
    *) return 1 ;;
  esac
}

validate_quota() {
  local val=$1
  [[ "$val" == "unlimited" || "$val" == "0" || "$val" =~ ^[0-9]+([kKmMgGtT][bB]?|[bB])?$ ]]
}

validate_reset_day() {
  local val=${1:-}
  [[ "$val" =~ ^[0-9]+$ ]] || return 1
  local num=$((10#$val))
  (( num >= 0 && num <= 31 ))
}

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr "[:upper:]" "[:lower:]"
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed -E "s/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/"
  fi
}

random_password() {
  openssl rand -base64 24 | tr "/+" "_-" | tr -d "=\n"
}

generate_ss_password() {
  local method=$1 bytes
  if bytes=$(ss2022_key_bytes "$method"); then
    openssl rand -base64 "$bytes"
  else
    random_password
  fi
}

generate_reality_keypair() {
  local out priv pub
  if command -v sing-box >/dev/null 2>&1; then
    out=$(sing-box generate reality-keypair 2>/dev/null || true)
    priv=$(echo "$out" | awk "/PrivateKey:/{print $2}" | head -n1)
    pub=$(echo "$out" | awk "/PublicKey:/{print $2}" | head -n1)
    if [[ -n "$priv" && -n "$pub" ]]; then
      printf "%s %s" "$priv" "$pub"
      return 0
    fi
  fi
  # 备用方案：通过 python 或 openssl
  if command -v python3 >/dev/null 2>&1; then
    out=$(python3 -c 'import base64, os
try:
    from cryptography.hazmat.primitives.asymmetric import x25519
    from cryptography.hazmat.primitives import serialization
    priv = x25519.X25519PrivateKey.generate()
    pub = priv.public_key()
    priv_b = priv.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    pub_b = pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    print(base64.urlsafe_b64encode(priv_b).decode().rstrip("="), base64.urlsafe_b64encode(pub_b).decode().rstrip("="))
except Exception:
    pass' 2>/dev/null || true)
    if [[ -n "$out" ]]; then
      printf "%s" "$out"
      return 0
    fi
  fi
  # 终极占位符（提示用户或之后生成）
  printf "%s %s" "$(openssl rand -base64 32)" "$(openssl rand -base64 32)"
}

json_get() {
  local file=$1 filter=$2
  [[ -r "$file" ]] || return 0
  jq -er "$filter // empty" "$file" 2>/dev/null || true
}

prompt_value() {
  local target=$1 label=$2 default=${3:-} value=""
  if (( NON_INTERACTIVE )); then
    [[ -n "$default" ]] && printf -v "$target" "%s" "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${label} [默认: ${default}]: " value
    value=${value:-$default}
  else
    read -r -p "${label}: " value
  fi
  printf -v "$target" "%s" "$value"
}

prompt_secret() {
  local target=$1 label=$2 default=${3:-} value=""
  if (( NON_INTERACTIVE )); then
    [[ -n "$default" ]] && printf -v "$target" "%s" "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${label} [默认: ${default}]: " value
    value=${value:-$default}
  else
    read -r -p "${label}: " value
  fi
  printf -v "$target" "%s" "$value"
}

prompt_choice() {
  local target=$1 title=$2 default=$3 choice item_key item_desc
  shift 3
  local -a items=("$@")
  local default_index=1 index=1
  for item in "${items[@]}"; do
    item_key="${item%%|*}"
    if [[ "$item_key" == "$default" ]]; then
      default_index=$index
      break
    fi
    index=$((index + 1))
  done

  local back_index=$(( ${#items[@]} + 1 ))

  echo >&2
  printf "%s=== %s ===%s\n" "$C_CYAN" "$title" "$C_RESET" >&2
  index=1
  for item in "${items[@]}"; do
    item_desc="${item#*|}"
    printf "  %2d) %s\n" "$index" "$item_desc" >&2
    index=$((index + 1))
  done
  printf "  %2d) 返回上级\n" "$back_index" >&2
  if (( NON_INTERACTIVE )); then
    local selected="${items[$((default_index - 1))]}"
    printf -v "$target" "%s" "${selected%%|*}"
    return 0
  fi
  while true; do
    read -r -p "请输入选择【${title}】[0-${back_index}，默认: ${default_index}]: " choice
    choice=${choice:-$default_index}
    if [[ "$choice" == "0" || "$choice" == "$back_index" ]]; then
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      local c_idx=$((10#$choice))
      if (( c_idx >= 1 && c_idx <= ${#items[@]} )); then
        local selected="${items[$((c_idx - 1))]}"
        printf -v "$target" "%s" "${selected%%|*}"
        return 0
      fi
    fi
    warn "输入无效，请输入 0 到 ${back_index} 之间的数字。"
  done
}

protocol_label() {
  case "$1" in
    anytls) printf "AnyTLS" ;;
    shadowsocks) printf "Shadowsocks" ;;
    trojan) printf "Trojan" ;;
    hysteria2) printf "Hysteria2" ;;
    vless-reality) printf "VLESS + REALITY" ;;
    socks5|socks) printf "SOCKS5" ;;
    http) printf "HTTP / HTTPS" ;;
    direct) printf "Direct" ;;
    *) printf "%s" "$1" ;;
  esac
}

choose_protocol() {
  local target=$1 default=$2 title=${3:-入站协议选择}
  (( NON_INTERACTIVE )) && { printf -v "$target" "%s" "$default"; return; }
  prompt_choice "$target" "$title" "$default" \
    "anytls|AnyTLS" \
    "shadowsocks|Shadowsocks" \
    "trojan|Trojan" \
    "hysteria2|Hysteria2" \
    "vless-reality|VLESS + REALITY" \
    "socks5|SOCKS5" \
    "http|HTTP / HTTPS"
}

choose_outbound_protocol() {
  local target=$1 default=$2 title=${3:-出口协议设置}
  (( NON_INTERACTIVE )) && { printf -v "$target" "%s" "$default"; return; }
  prompt_choice "$target" "$title" "$default" \
    "direct|Direct" \
    "anytls|AnyTLS" \
    "shadowsocks|Shadowsocks" \
    "trojan|Trojan" \
    "hysteria2|Hysteria2" \
    "vless-reality|VLESS + REALITY" \
    "socks5|SOCKS5 / SOCKS5H" \
    "http|HTTP / HTTPS"
}

choose_ss_method() {
  local default_method=${SS_METHOD:-2022-blake3-aes-128-gcm}
  prompt_choice SS_METHOD "Shadowsocks 加密方法" "$default_method" \
    "2022-blake3-aes-128-gcm|2022-blake3-aes-128-gcm (推荐，16字节密钥)" \
    "2022-blake3-aes-256-gcm|2022-blake3-aes-256-gcm (32字节密钥)" \
    "2022-blake3-chacha20-poly1305|2022-blake3-chacha20-poly1305 (32字节密钥)" \
    "aes-256-gcm|aes-256-gcm (传统标准)" \
    "aes-128-gcm|aes-128-gcm" \
    "chacha20-ietf-poly1305|chacha20-ietf-poly1305"
}

derive_dnspod_zone() {
  local domain last_two last_three
  local -a labels=()
  domain=$(printf "%s" "$1" | tr "[:upper:]" "[:lower:]")
  IFS=. read -r -a labels <<< "$domain"
  ((${#labels[@]} >= 2)) || return 1
  last_two="${labels[*]:${#labels[@]}-2:2}"
  last_two=${last_two// /.}
  case "$last_two" in
    com.cn|net.cn|org.cn|gov.cn|com.hk|com.tw|co.uk|org.uk|co.jp|com.sg)
      ((${#labels[@]} >= 3)) || return 1
      last_three="${labels[*]:${#labels[@]}-3:3}"
      printf "%s" "${last_three// /.}"
      ;;
    *) printf "%s" "$last_two" ;;
  esac
}

write_dnspod_credentials() {
  local tmp
  install -d -m 0700 "$STATE_DIR"
  tmp=$(mktemp "${STATE_DIR}/dnspod.XXXXXX")
  jq -n \
    --arg id "$DNSPOD_TOKEN_ID" \
    --arg token "$DNSPOD_TOKEN_KEY" \
    '{id:$id,token:$token}' > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$DNSPOD_CREDENTIAL_FILE"
  rm -f "$tmp"
}

install_dnspod_hooks() {
  install -d -m 0700 "$STATE_DIR"
  cat > "$DNSPOD_HOOK" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly CREDENTIAL_FILE=/etc/sbox/dnspod.json
readonly API_ENDPOINT="https://dnsapi.cn"
readonly RUNTIME_DIR=/run/sing-box
readonly PROPAGATION_SECONDS=60
readonly PROGRESS_INTERVAL=5

die() { printf "[DNSPod] %s\n" "$*" >&2; exit 1; }

check_txt_record() {
  local target=$1 expected=$2 txt_resp
  if command -v dig >/dev/null 2>&1; then
    txt_resp=$(dig +short TXT "$target" @1.1.1.1 2>/dev/null || true)
    if [[ "$txt_resp" == *"$expected"* ]]; then
      return 0
    fi
  fi
  txt_resp=$(curl -fsS --connect-timeout 3 --max-time 4 "https://1.1.1.1/dns-query?name=${target}&type=TXT" -H "accept: application/dns-json" 2>/dev/null || true)
  if [[ -n "$txt_resp" && "$txt_resp" == *"$expected"* ]]; then
    return 0
  fi
  txt_resp=$(curl -fsS --connect-timeout 3 --max-time 4 "https://dns.google/resolve?name=${target}&type=TXT" -H "accept: application/dns-json" 2>/dev/null || true)
  if [[ -n "$txt_resp" && "$txt_resp" == *"$expected"* ]]; then
    return 0
  fi
  return 1
}

notify() {
  if ! printf "[DNSPod] %s\n" "$*" 2>/dev/null >/dev/tty; then
    printf "[DNSPod] %s\n" "$*" >&2
  fi
}

dnspod_api() {
  local action=$1 payload=${2:-}
  local token_id token_key login_token
  token_id=$(jq -r '.id // .token_id // empty' "$CREDENTIAL_FILE" 2>/dev/null || true)
  token_key=$(jq -r '.token // .token_key // empty' "$CREDENTIAL_FILE" 2>/dev/null || true)
  [[ -n "$token_id" && -n "$token_key" ]] || die "缺少 DNSPod Token 凭据（Token ID 与 Token Key）。"
  login_token="${token_id},${token_key}"

  local -a curl_args=(
    --proto '=https' --tlsv1.2 -fsS
    --connect-timeout 10
    --max-time 30
    --retry 2
    --retry-delay 2
    -A "sbox-certbot/0.0.1"
    "${API_ENDPOINT}/${action}"
    -d "login_token=${login_token}"
    -d "format=json"
  )

  if [[ -n "$payload" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      curl_args+=(-d "$line")
    done <<<"$payload"
  fi

  curl "${curl_args[@]}"
}

derive_dnspod_zone() {
  local domain last_two last_three
  local -a labels=()
  domain=$(printf "%s" "$1" | tr "[:upper:]" "[:lower:]")
  IFS=. read -r -a labels <<< "$domain"
  ((${#labels[@]} >= 2)) || return 1
  last_two="${labels[*]:${#labels[@]}-2:2}"
  last_two=${last_two// /.}
  case "$last_two" in
    com.cn|net.cn|org.cn|gov.cn|com.hk|com.tw|co.uk|org.uk|co.jp|com.sg)
      ((${#labels[@]} >= 3)) || return 1
      last_three="${labels[*]:${#labels[@]}-3:3}"
      printf "%s" "${last_three// /.}"
      ;;
    *) printf "%s" "$last_two" ;;
  esac
}

dnspod_get_zone() {
  local domain=$1
  local current="$domain"
  local response
  while [[ "$current" == *.* ]]; do
    if response=$(dnspod_api Domain.Info "domain=${current}" 2>/dev/null); then
      if [[ $(jq -r '.status.code // empty' <<<"$response") == "1" ]]; then
        printf "%s" "$current"
        return 0
      fi
    fi
    current="${current#*.}"
  done
  derive_dnspod_zone "$domain"
}

main() {
  local operation=${1:-} fqdn zone subdomain prefix key record_file payload response error record_id remaining
  [[ -r "$CREDENTIAL_FILE" ]] || die "缺少凭据文件 ${CREDENTIAL_FILE}"
  [[ -n "${CERTBOT_DOMAIN:-}" ]] || die "CERTBOT_DOMAIN 为空"
  fqdn=${CERTBOT_DOMAIN#\*.}
  fqdn=$(printf "%s" "$fqdn" | tr "[:upper:]" "[:lower:]")

  key=$(printf "%s" "${fqdn}:${CERTBOT_VALIDATION:-}" | sha256sum | awk '{print $1}')
  install -d -m 0700 "$RUNTIME_DIR"
  record_file="${RUNTIME_DIR}/dnspod_${key}.json"

  case "$operation" in
    auth)
      [[ -n "${CERTBOT_VALIDATION:-}" ]] || die "CERTBOT_VALIDATION 为空"
      notify "正在查询域名 ${fqdn} 对应的 DNSPod Zone……"
      zone=$(dnspod_get_zone "$fqdn") || die "无法确定域名 ${fqdn} 的根域名。"
      if [[ "$fqdn" == "$zone" ]]; then
        subdomain='_acme-challenge'
      elif [[ "$fqdn" == *."$zone" ]]; then
        prefix=${fqdn:0:${#fqdn}-${#zone}-1}
        subdomain="_acme-challenge.${prefix}"
      else
        subdomain="_acme-challenge"
      fi

      notify "正在通过 DNSPod Token API 创建 TXT 记录 ${subdomain}.${zone}……"
      payload=$(printf "domain=%s\nsub_domain=%s\nrecord_type=TXT\nrecord_line=默认\nvalue=%s" \
        "$zone" "$subdomain" "$CERTBOT_VALIDATION")

      if ! response=$(dnspod_api Record.Create "$payload"); then
        die "DNSPod API 请求失败。"
      fi

      if [[ $(jq -r '.status.code // empty' <<<"$response") != "1" ]]; then
        error=$(jq -r '.status.message // "未知错误"' <<<"$response")
        die "创建 TXT 记录失败：${error}"
      fi

      record_id=$(jq -er '.record.id' <<<"$response")
      [[ -n "$record_id" ]] || die "未获取到 DNSPod Record ID。"

      jq -n --arg domain "$zone" --arg record_id "$record_id" --arg subdomain "$subdomain" \
        '{domain:$domain,record_id:$record_id,subdomain:$subdomain}' > "$record_file"

      local check_name="${subdomain}.${zone}"
      notify "TXT 记录 ${check_name} 已创建，等待 DNS 解析生效（最长 ${PROPAGATION_SECONDS} 秒）……"
      for ((remaining=PROPAGATION_SECONDS; remaining>0; remaining-=PROGRESS_INTERVAL)); do
        notify "DNS 传播等待中，剩余 ${remaining} 秒……"
        sleep "$PROGRESS_INTERVAL"
        if (( PROPAGATION_SECONDS - remaining >= 20 )); then
          if check_txt_record "$check_name" "$CERTBOT_VALIDATION"; then
            notify "检测到 DNS TXT 记录已全网生效，提前结束等待。"
            break
          fi
        fi
      done
      ;;
    cleanup)
      if [[ ! -r "$record_file" ]]; then
        notify "未找到记录文件 ${record_file}，跳过清理。"
        exit 0
      fi
      zone=$(jq -r '.domain' "$record_file")
      record_id=$(jq -r '.record_id' "$record_file")
      subdomain=$(jq -r '.subdomain // "_acme-challenge"' "$record_file")

      notify "正在删除 TXT 记录 ${subdomain}.${zone} (RecordId: ${record_id})……"
      payload=$(printf "domain=%s\nrecord_id=%s" "$zone" "$record_id")

      if response=$(dnspod_api Record.Remove "$payload" 2>/dev/null); then
        if [[ $(jq -r '.status.code // empty' <<<"$response") == "1" ]]; then
          notify "TXT 记录已删除。"
        else
          error=$(jq -r '.status.message // "未知错误"' <<<"$response")
          notify "删除 TXT 记录失败：${error}"
        fi
      else
        notify "DNSPod API 请求失败，记录未能自动删除。"
      fi
      rm -f "$record_file"
      ;;
    *)
      die "用法：$0 {auth|cleanup}"
      ;;
  esac
}

main "$@"
EOF
  chmod 0700 "$DNSPOD_HOOK"
  cat > "$DNSPOD_AUTH_HOOK" <<EOF
#!/usr/bin/env bash
exec "${DNSPOD_HOOK}" auth
EOF
  chmod 0700 "$DNSPOD_AUTH_HOOK"
  cat > "$DNSPOD_CLEANUP_HOOK" <<EOF
#!/usr/bin/env bash
exec "${DNSPOD_HOOK}" cleanup
EOF
  chmod 0700 "$DNSPOD_CLEANUP_HOOK"
}

collect_dnspod_settings() {
  local existing_id="" existing_token="" raw_input="" raw_key=""
  if [[ -r "$DNSPOD_CREDENTIAL_FILE" ]]; then
    existing_id=$(jq -r '.id // .token_id // empty' "$DNSPOD_CREDENTIAL_FILE" 2>/dev/null || true)
    existing_token=$(jq -r '.token // .token_key // empty' "$DNSPOD_CREDENTIAL_FILE" 2>/dev/null || true)
  fi

  DNSPOD_TOKEN_ID=${DNSPOD_TOKEN_ID:-$existing_id}
  DNSPOD_TOKEN_KEY=${DNSPOD_TOKEN_KEY:-$existing_token}

  echo
  info "配置 DNSPod Token (可在 DNSPod 控制台「我的账号」->「API密钥」->「DNSPod Token」中创建)"
  prompt_value raw_input "DNSPod Token [格式: ID,Token 或直接输入 ID]" "$DNSPOD_TOKEN_ID"
  [[ -n "$raw_input" ]] || die "DNSPod Token ID 不能为空。"

  if [[ "$raw_input" == *,* ]]; then
    DNSPOD_TOKEN_ID="${raw_input%%,*}"
    DNSPOD_TOKEN_KEY="${raw_input#*,}"
  else
    DNSPOD_TOKEN_ID="$raw_input"
    if [[ -n "$DNSPOD_TOKEN_KEY" ]]; then
      read -r -p "DNSPod Token Key [默认: 已配置] (回车保持不变): " raw_key
      DNSPOD_TOKEN_KEY="${raw_key:-$DNSPOD_TOKEN_KEY}"
    else
      read -r -p "DNSPod Token Key: " raw_key
      DNSPOD_TOKEN_KEY="$raw_key"
    fi
  fi

  [[ -n "$DNSPOD_TOKEN_ID" && -n "$DNSPOD_TOKEN_KEY" ]] || die "DNSPod Token ID 与 Token Key 不能为空。"
  write_dnspod_credentials
  install_dnspod_hooks
}

write_cf_credentials() {
  local tmp
  install -d -m 0700 "$STATE_DIR"
  tmp=$(mktemp "${STATE_DIR}/cf.XXXXXX")
  jq -n \
    --arg api_token "$CF_API_TOKEN" \
    --arg api_key "$CF_API_KEY" \
    --arg email "$CF_EMAIL" \
    '{api_token:$api_token,api_key:$api_key,email:$email}' > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$CF_CREDENTIAL_FILE"
  rm -f "$tmp"
}

install_cf_hooks() {
  install -d -m 0700 "$STATE_DIR"
  cat > "$CF_HOOK" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly CREDENTIAL_FILE=/etc/sbox/cf.json
readonly API_ENDPOINT="https://api.cloudflare.com/client/v4"
readonly RUNTIME_DIR=/run/sing-box
readonly PROPAGATION_SECONDS=60
readonly PROGRESS_INTERVAL=5

die() { printf "[Cloudflare] %s\n" "$*" >&2; exit 1; }

notify() {
  if ! printf "[Cloudflare] %s\n" "$*" 2>/dev/null >/dev/tty; then
    printf "[Cloudflare] %s\n" "$*" >&2
  fi
}

check_txt_record() {
  local target=$1 expected=$2 txt_resp
  txt_resp=$(curl -fsS --connect-timeout 3 --max-time 4 "https://1.1.1.1/dns-query?name=${target}&type=TXT" -H "accept: application/dns-json" 2>/dev/null || true)
  if [[ -n "$txt_resp" && "$txt_resp" == *"$expected"* ]]; then
    return 0
  fi
  txt_resp=$(curl -fsS --connect-timeout 3 --max-time 4 "https://doh.pub/dns-query?name=${target}&type=TXT" -H "accept: application/dns-json" 2>/dev/null || true)
  if [[ -n "$txt_resp" && "$txt_resp" == *"$expected"* ]]; then
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    txt_resp=$(dig +short TXT "$target" @1.1.1.1 2>/dev/null || true)
    if [[ "$txt_resp" == *"$expected"* ]]; then
      return 0
    fi
  fi
  return 1
}

cf_api() {
  local method=$1 path=$2 data=${3:-}
  local api_token api_key email
  local -a auth_headers=()

  api_token=$(jq -r '.api_token // empty' "$CREDENTIAL_FILE" 2>/dev/null || true)
  api_key=$(jq -r '.api_key // empty' "$CREDENTIAL_FILE" 2>/dev/null || true)
  email=$(jq -r '.email // empty' "$CREDENTIAL_FILE" 2>/dev/null || true)

  if [[ -n "$api_token" ]]; then
    auth_headers+=(-H "Authorization: Bearer ${api_token}")
  elif [[ -n "$api_key" && -n "$email" ]]; then
    auth_headers+=(-H "X-Auth-Key: ${api_key}" -H "X-Auth-Email: ${email}")
  else
    die "Cloudflare 凭据不完整（需要 API Token 或 Global Key + 邮箱）。"
  fi

  local -a curl_args=(
    --proto '=https' --tlsv1.2 -fsS
    --connect-timeout 10
    --max-time 30
    --retry 2
    --retry-delay 2
    -X "$method"
    "${API_ENDPOINT}${path}"
    -H "Content-Type: application/json"
    "${auth_headers[@]}"
  )

  if [[ -n "$data" ]]; then
    curl_args+=(--data "$data")
  fi

  curl "${curl_args[@]}"
}

cf_get_zone_id() {
  local domain=$1
  local current="$domain"
  local zone_id="" response
  while [[ "$current" == *.* ]]; do
    if response=$(cf_api GET "/zones?name=${current}&status=active" 2>/dev/null); then
      zone_id=$(jq -r '.result[0].id // empty' <<<"$response")
      if [[ -n "$zone_id" ]]; then
        printf "%s" "$zone_id"
        return 0
      fi
    fi
    current="${current#*.}"
  done
  return 1
}

main() {
  local operation=${1:-} fqdn key record_file zone_id record_name response record_id error remaining
  [[ -r "$CREDENTIAL_FILE" ]] || die "缺少凭据文件 ${CREDENTIAL_FILE}"
  [[ -n "${CERTBOT_DOMAIN:-}" ]] || die "CERTBOT_DOMAIN 为空"

  fqdn=${CERTBOT_DOMAIN#\*.}
  fqdn=$(printf "%s" "$fqdn" | tr "[:upper:]" "[:lower:]")
  record_name="_acme-challenge.${fqdn}"

  key=$(printf "%s" "${fqdn}:${CERTBOT_VALIDATION:-}" | sha256sum | awk '{print $1}')
  install -d -m 0700 "$RUNTIME_DIR"
  record_file="${RUNTIME_DIR}/cf_${key}.json"

  case "$operation" in
    auth)
      [[ -n "${CERTBOT_VALIDATION:-}" ]] || die "CERTBOT_VALIDATION 为空"
      notify "正在查询域名 ${fqdn} 对应的 Cloudflare Zone ID……"
      zone_id=$(cf_get_zone_id "$fqdn") || die "无法在 Cloudflare 账户中找到域名 ${fqdn} 的活动 Zone。"

      notify "正在通过 Cloudflare API 创建 TXT 记录 ${record_name}……"
      local payload
      payload=$(jq -cn \
        --arg name "$record_name" \
        --arg content "$CERTBOT_VALIDATION" \
        '{type:"TXT",name:$name,content:$content,ttl:120}')

      if ! response=$(cf_api POST "/zones/${zone_id}/dns_records" "$payload"); then
        die "Cloudflare API 请求失败。"
      fi

      if [[ $(jq -r '.success' <<<"$response") != "true" ]]; then
        error=$(jq -r '.errors[]?.message // "未知错误"' <<<"$response" | tr '\n' ' ')
        die "创建 TXT 记录失败：${error}"
      fi

      record_id=$(jq -er '.result.id' <<<"$response")
      [[ -n "$record_id" ]] || die "未获取到 Cloudflare Record ID。"

      jq -n --arg zone_id "$zone_id" --arg record_id "$record_id" --arg name "$record_name" \
        '{zone_id:$zone_id,record_id:$record_id,name:$name}' > "$record_file"

      notify "TXT 记录 ${record_name} 已创建，等待 DNS 解析生效（最长 ${PROPAGATION_SECONDS} 秒）……"
      for ((remaining=PROPAGATION_SECONDS; remaining>0; remaining-=PROGRESS_INTERVAL)); do
        notify "DNS 传播等待中，剩余 ${remaining} 秒……"
        sleep "$PROGRESS_INTERVAL"
        if (( PROPAGATION_SECONDS - remaining >= 15 )); then
          if check_txt_record "$record_name" "$CERTBOT_VALIDATION"; then
            notify "检测到 DNS TXT 记录已全网生效，提前结束等待。"
            break
          fi
        fi
      done
      ;;
    cleanup)
      if [[ ! -r "$record_file" ]]; then
        notify "未找到记录文件 ${record_file}，跳过清理。"
        exit 0
      fi
      zone_id=$(jq -r '.zone_id' "$record_file")
      record_id=$(jq -r '.record_id' "$record_file")
      record_name=$(jq -r '.name' "$record_file")

      notify "正在删除 TXT 记录 ${record_name} (RecordId: ${record_id})……"
      if response=$(cf_api DELETE "/zones/${zone_id}/dns_records/${record_id}" 2>/dev/null); then
        if [[ $(jq -r '.success' <<<"$response") == "true" ]]; then
          notify "TXT 记录已删除。"
        else
          error=$(jq -r '.errors[]?.message // "未知错误"' <<<"$response" | tr '\n' ' ')
          notify "删除 TXT 记录失败：${error}"
        fi
      else
        notify "Cloudflare API 请求失败，记录未能删除。"
      fi
      rm -f "$record_file"
      ;;
    *)
      die "用法：$0 {auth|cleanup}"
      ;;
  esac
}

main "$@"
EOF
  chmod 0700 "$CF_HOOK"
  cat > "$CF_AUTH_HOOK" <<EOF
#!/usr/bin/env bash
exec "${CF_HOOK}" auth
EOF
  chmod 0700 "$CF_AUTH_HOOK"
  cat > "$CF_CLEANUP_HOOK" <<EOF
#!/usr/bin/env bash
exec "${CF_HOOK}" cleanup
EOF
  chmod 0700 "$CF_CLEANUP_HOOK"
}

collect_cf_settings() {
  local existing_token="" existing_key="" existing_email="" auth_type="token" raw_val=""
  if [[ -r "$CF_CREDENTIAL_FILE" ]]; then
    existing_token=$(jq -r '.api_token // empty' "$CF_CREDENTIAL_FILE" 2>/dev/null || true)
    existing_key=$(jq -r '.api_key // empty' "$CF_CREDENTIAL_FILE" 2>/dev/null || true)
    existing_email=$(jq -r '.email // empty' "$CF_CREDENTIAL_FILE" 2>/dev/null || true)
  fi

  CF_API_TOKEN=${CF_API_TOKEN:-$existing_token}
  CF_API_KEY=${CF_API_KEY:-$existing_key}
  CF_EMAIL=${CF_EMAIL:-$existing_email}

  if [[ -n "$CF_API_TOKEN" ]]; then
    auth_type="token"
  elif [[ -n "$CF_API_KEY" ]]; then
    auth_type="global"
  fi

  prompt_choice auth_type "Cloudflare 认证方式" "$auth_type" \
    "token|API Token (推荐，仅需具备 Zone.DNS 权限)" \
    "global|Global API Key + 账户邮箱" || return 1

  if [[ "$auth_type" == "token" ]]; then
    if [[ -n "$CF_API_TOKEN" ]]; then
      read -r -p "Cloudflare API Token [默认: 已配置] (回车保持不变): " raw_val
      CF_API_TOKEN="${raw_val:-$CF_API_TOKEN}"
    else
      read -r -p "Cloudflare API Token: " CF_API_TOKEN
    fi
    [[ -n "$CF_API_TOKEN" ]] || die "Cloudflare API Token 不能为空。"
    CF_API_KEY=""
    CF_EMAIL=""
  else
    prompt_value CF_EMAIL "Cloudflare 账户邮箱" "$CF_EMAIL"
    if [[ -n "$CF_API_KEY" ]]; then
      read -r -p "Cloudflare Global API Key [默认: 已配置] (回车保持不变): " raw_val
      CF_API_KEY="${raw_val:-$CF_API_KEY}"
    else
      read -r -p "Cloudflare Global API Key: " CF_API_KEY
    fi
    [[ -n "$CF_EMAIL" && -n "$CF_API_KEY" ]] || die "Cloudflare 邮箱与 Global Key 不能为空。"
    CF_API_TOKEN=""
  fi

  write_cf_credentials
  install_cf_hooks
}

detect_public_ip() {
  local ip
  # 优先从出口路由直接获取本机公网 IP（内网/无外部 curl 时也能秒级探测）
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)
  if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != 127.* && "$ip" != 10.* && "$ip" != 172.1[6-9].* && "$ip" != 172.2[0-9].* && "$ip" != 172.3[0-1].* && "$ip" != 192.168.* ]]; then
    printf "%s" "$ip"
    return 0
  fi
  # 外部权威公网 IP 接口降级探测
  ip=$(curl -s4m 3 https://api.ipify.org 2>/dev/null || curl -s4m 3 https://ip.sb 2>/dev/null || curl -s4m 3 https://icanhazip.com 2>/dev/null || curl -s4m 3 https://checkip.amazonaws.com 2>/dev/null || true)
  ip=$(echo "$ip" | tr -d "[:space:]")
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != 127.* ]]; then
    printf "%s" "$ip"
    return 0
  fi
  return 1
}

node_requires_certificate() {
  local proto=$1
  local tls_flag=${2:-false}
  case "$proto" in
    anytls|trojan|hysteria2) return 0 ;;
    http)
      if [[ "$tls_flag" == "true" ]]; then
        return 0
      fi
      return 1
      ;;
    *) return 1 ;;
  esac
}

node_cert_file() {
  printf "%s/%s/fullchain.pem" "$CERT_DIR" "$1"
}

node_key_file() {
  printf "%s/%s/privkey.pem" "$CERT_DIR" "$1"
}

choose_cert_mode() {
  local default_mode=${CERT_MODE:-dnspod}
  prompt_choice CERT_MODE "证书申请模式" "$default_mode" \
    "dnspod|Dnspod" \
    "cf|Cloudflare" \
    "webroot|Webroot (复用现有 Nginx / Apache 等 Web 目录)" \
    "standalone|Standalone (临时监听 TCP 80，适合未安装网站环境的机器)"
}

copy_certificate() {
  local domain=$1 source_dir target_dir group
  source_dir="/etc/letsencrypt/live/${domain}"
  target_dir="${CERT_DIR}/${domain}"
  group=$(service_group)
  [[ -s "${source_dir}/fullchain.pem" && -s "${source_dir}/privkey.pem" ]] || die "找不到 ${domain} 的 Certbot 证书。"
  install -d -m 0750 -o root -g "$group" "$CERT_DIR" "$target_dir"
  install -m 0640 -o root -g "$group" "${source_dir}/fullchain.pem" "${target_dir}/fullchain.pem"
  install -m 0640 -o root -g "$group" "${source_dir}/privkey.pem" "${target_dir}/privkey.pem"
  openssl x509 -in "${target_dir}/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || die "证书无效或已经过期。"
  openssl pkey -in "${target_dir}/privkey.pem" -noout >/dev/null 2>&1 || die "证书私钥无效。"
}

sync_certificate() {
  local domain
  if [[ -r "$STATE_FILE" ]]; then
    while IFS= read -r domain; do
      [[ -n "$domain" ]] || continue
      if [[ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        copy_certificate "$domain"
      fi
    done < <(jq -r '.nodes[]?.domain // empty' "$STATE_FILE" 2>/dev/null | sort -u)
  fi
}

ensure_certbot_environment() {
  command -v certbot >/dev/null 2>&1 || return 0
  if certbot --version >/dev/null 2>&1; then
    return 0
  fi

  info "检测到 certbot 运行异常，正在尝试自愈 Python 依赖环境……"
  local err_msg
  err_msg=$(certbot --version 2>&1 || true)

  if [[ "$err_msg" == *"X509_V_FLAG_NOTIFY_POLICY"* || "$err_msg" == *"AttributeError: module 'lib' has no attribute"* ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 -c "
import sys
sys.path = [p for p in sys.path if not p.startswith('/usr/local')]
try:
    from pip._internal.cli.main import main
    sys.argv = ['pip3', 'install', '--upgrade', 'pyOpenSSL']
    main()
except Exception:
    pass
" >/dev/null 2>&1 || true
    fi
  fi

  if ! certbot --version >/dev/null 2>&1; then
    if command -v python3 >/dev/null 2>&1 && python3 -c "import sys; sys.path = [p for p in sys.path if not p.startswith('/usr/local')]; from certbot.main import main; sys.argv = ['certbot', '--version']; main()" >/dev/null 2>&1; then
      install -d -m 0755 /usr/local/bin
      cat >/usr/local/bin/certbot <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 -c "
import sys
sys.path = [p for p in sys.path if not p.startswith('/usr/local')]
from certbot.main import main
sys.argv = sys.argv[1:]
main()
" "$0" "$@"
EOF
      chmod 0755 /usr/local/bin/certbot
    fi
  fi

  if certbot --version >/dev/null 2>&1; then
    ok "certbot 运行环境已成功自愈恢复。"
  else
    warn "certbot 运行环境自愈未完全成功，后续证书申请可能受阻。"
  fi
}

issue_certificate() {
  ensure_certbot_environment
  local domain=$1 email=$2 mode=$3 webroot=$4
  local -a args=(certonly --non-interactive --agree-tos --keep-until-expiring --cert-name "$domain" -d "$domain")
  if [[ -n "$email" && "$email" != "none" ]]; then
    args+=(-m "$email")
  else
    args+=(--register-unsafely-without-email)
  fi

  case "$mode" in
    standalone)
      [[ -z "$(port_listener 80)" ]] || die "HTTP-01 standalone 需要 TCP 80，但该端口已被占用；请改用 webroot 模式。"
      args+=(--standalone --preferred-challenges http)
      ;;
    webroot)
      [[ -n "$webroot" && -d "$webroot" ]] || die "webroot 目录不存在：${webroot:-<空>}"
      args+=(--webroot -w "$webroot" --preferred-challenges http)
      ;;
    dnspod)
      [[ -x "$DNSPOD_AUTH_HOOK" && -x "$DNSPOD_CLEANUP_HOOK" && -r "$DNSPOD_CREDENTIAL_FILE" ]] || \
        die "DNSPod 凭据或验证钩子未就绪。"
      args+=(--manual --preferred-challenges dns \
        --manual-auth-hook "$DNSPOD_AUTH_HOOK" \
        --manual-cleanup-hook "$DNSPOD_CLEANUP_HOOK")
      if certbot certonly --help all 2>/dev/null | grep -q -- '--manual-public-ip-logging-ok'; then
        args+=(--manual-public-ip-logging-ok)
      fi
      ;;
    cf)
      [[ -x "$CF_AUTH_HOOK" && -x "$CF_CLEANUP_HOOK" && -r "$CF_CREDENTIAL_FILE" ]] || \
        die "Cloudflare 凭据或验证钩子未就绪。"
      args+=(--manual --preferred-challenges dns \
        --manual-auth-hook "$CF_AUTH_HOOK" \
        --manual-cleanup-hook "$CF_CLEANUP_HOOK")
      if certbot certonly --help all 2>/dev/null | grep -q -- '--manual-public-ip-logging-ok'; then
        args+=(--manual-public-ip-logging-ok)
      fi
      ;;
    *) die "证书模式仅支持 dnspod、cf、webroot 或 standalone。" ;;
  esac

  info "通过 Let's Encrypt 为 ${domain} 申请/同步证书……"
  certbot "${args[@]}"
  [[ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] || die "未找到签发后的证书。"
  copy_certificate "$domain"
  ok "域名 ${domain} 证书已就绪。"
}

install_deploy_hook() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >"$DEPLOY_HOOK" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_FILE=/etc/sbox/state.json
CONFIG_FILE=/etc/sing-box/config.json
CERT_DIR=/etc/sing-box/certs
[[ -r "$STATE_FILE" ]] || exit 0
group=root; getent group sing-box >/dev/null 2>&1 && group=sing-box
while IFS= read -r domain; do
  [[ -n "$domain" ]] || continue
  lineage="/etc/letsencrypt/live/$domain"
  [[ -s "$lineage/fullchain.pem" && -s "$lineage/privkey.pem" ]] || continue
  install -d -m 0750 -o root -g "$group" "$CERT_DIR/$domain"
  install -m 0640 -o root -g "$group" "$lineage/fullchain.pem" "$CERT_DIR/$domain/fullchain.pem"
  install -m 0640 -o root -g "$group" "$lineage/privkey.pem" "$CERT_DIR/$domain/privkey.pem"
done < <(jq -r '.nodes[]?.domain // empty' "$STATE_FILE" | sort -u)
if [[ -s "$CONFIG_FILE" ]] && command -v sing-box >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 && (systemctl reload-or-restart sing-box || systemctl restart sing-box) || true
  elif command -v rc-service >/dev/null 2>&1; then
    sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1 && rc-service sing-box restart || true
  fi
fi
EOF
  chmod 0755 "$DEPLOY_HOOK"
}

ensure_node_certificate() {
  local node=$1 protocol domain email mode webroot tls
  protocol=$(jq -r '.protocol // "anytls"' <<<"$node")
  domain=$(jq -r '.domain // empty' <<<"$node")
  tls=$(jq -r '.tls // false' <<<"$node")
  node_requires_certificate "$protocol" "$tls" || return 0
  validate_domain "$domain" || die "协议 $(protocol_label "$protocol") 需要有效域名：${domain:-<空>}"
  if [[ -s "$(node_cert_file "$domain")" && -s "$(node_key_file "$domain")" ]]; then
    if openssl x509 -in "$(node_cert_file "$domain")" -noout -checkend 86400 >/dev/null 2>&1; then
      info "域名 ${domain} 已存在本地有效证书，直接使用。"
      return 0
    fi
  fi
  if [[ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" && -s "/etc/letsencrypt/live/${domain}/privkey.pem" ]]; then
    info "检测到 /etc/letsencrypt/live/${domain} 存在证书，直接同步……"
    copy_certificate "$domain"
    return 0
  fi
  echo
  info "节点域名 ${domain} 暂无证书，开始申请 Let's Encrypt 证书……"
  email=$(json_get "$STATE_FILE" '.email')
  mode=$(json_get "$STATE_FILE" '.cert_mode')
  webroot=$(json_get "$STATE_FILE" '.webroot')
  [[ -n "$email" ]] || email="$EMAIL"
  [[ -n "$webroot" ]] || webroot="$WEBROOT"

  if (( ! NON_INTERACTIVE )); then
    CERT_MODE="${mode:-${CERT_MODE:-dnspod}}"
    choose_cert_mode || return 1
    mode="$CERT_MODE"
  else
    [[ -n "$mode" ]] || mode="${CERT_MODE:-dnspod}"
  fi

  if [[ "$mode" != "dnspod" && "$mode" != "cf" && "$mode" != "webroot" && "$mode" != "standalone" ]]; then
    mode="dnspod"
  fi

  if [[ "$mode" == "webroot" ]]; then
    if [[ -z "$webroot" || ! -d "$webroot" ]]; then
      prompt_value WEBROOT "网站根目录" "${WEBROOT:-/var/www/html}"
      webroot="$WEBROOT"
    elif (( ! NON_INTERACTIVE )); then
      prompt_value WEBROOT "网站根目录" "$webroot"
      webroot="$WEBROOT"
    fi
  fi

  if [[ "$mode" == "dnspod" ]]; then
    if [[ ! -r "$DNSPOD_CREDENTIAL_FILE" ]] || ! jq -e '(.id // .token_id) and (.token // .token_key)' "$DNSPOD_CREDENTIAL_FILE" >/dev/null 2>&1; then
      DOMAIN="$domain"
      EMAIL="$email"
      CERT_MODE="$mode"
      collect_dnspod_settings || return 1
    elif (( ! NON_INTERACTIVE )); then
      local cur_id reuse_choice="yes"
      cur_id=$(jq -r '.id // .token_id // empty' "$DNSPOD_CREDENTIAL_FILE" 2>/dev/null || true)
      info "检测到已保存的 DNSPod Token (ID: ${cur_id})"
      prompt_choice reuse_choice "DNSPod 凭据确认" "yes" \
        "yes|直接复用已保存凭据" \
        "no|重新配置新的凭据" || return 1
      if [[ "$reuse_choice" == "no" ]]; then
        DOMAIN="$domain"
        EMAIL="$email"
        CERT_MODE="$mode"
        collect_dnspod_settings || return 1
      else
        install_dnspod_hooks
      fi
    else
      install_dnspod_hooks
    fi
  fi

  if [[ "$mode" == "cf" ]]; then
    if [[ ! -r "$CF_CREDENTIAL_FILE" ]] || ! jq -e '.api_token or (.api_key and .email)' "$CF_CREDENTIAL_FILE" >/dev/null 2>&1; then
      DOMAIN="$domain"
      EMAIL="$email"
      CERT_MODE="$mode"
      collect_cf_settings || return 1
    elif (( ! NON_INTERACTIVE )); then
      local reuse_choice="yes"
      info "检测到已保存的 Cloudflare 凭据"
      prompt_choice reuse_choice "Cloudflare 凭据确认" "yes" \
        "yes|直接复用已保存凭据" \
        "no|重新配置新的凭据" || return 1
      if [[ "$reuse_choice" == "no" ]]; then
        DOMAIN="$domain"
        EMAIL="$email"
        CERT_MODE="$mode"
        collect_cf_settings || return 1
      else
        install_cf_hooks
      fi
    else
      install_cf_hooks
    fi
  fi

  issue_certificate "$domain" "$email" "$mode" "$webroot"
  CERT_MODE="$mode"
  WEBROOT="$webroot"
  if [[ -s "$STATE_FILE" ]]; then
    local state_tmp
    state_tmp=$(mktemp)
    jq --arg email "$email" --arg mode "$mode" --arg webroot "$webroot" \
      '.email=$email | .cert_mode=$mode | .webroot=$webroot' "$STATE_FILE" >"$state_tmp"
    install -m 0600 "$state_tmp" "$STATE_FILE"
    rm -f "$state_tmp"
  fi
}

service_group() {
  if getent group sing-box >/dev/null 2>&1; then
    printf "sing-box"
  else
    printf "root"
  fi
}

port_listener() {
  local port=$1
  ss -H -ltnp "sport = :${port}" 2>/dev/null || true
}

assert_port_available() {
  local port=$1 listeners
  listeners=$(port_listener "$port")
  if [[ -n "$listeners" && "$listeners" != *sing-box* ]]; then
    printf "%s\n" "$listeners" >&2
    warn "TCP 端口 ${port} 已被其他进程占用。"
    return 1
  fi
  return 0
}

ensure_sing_box_repository() {
  if grep -Rqs 'deb.sagernet.org' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null; then
    info "sing-box 官方软件源已存在，跳过添加。"
    return 0
  fi
  info "添加 sing-box 官方 APT 软件源……"
  install -d -m 0755 /etc/apt/keyrings
  local key_tmp
  key_tmp=$(mktemp)
  curl --proto '=https' --tlsv1.2 -fsSL https://sing-box.app/gpg.key -o "$key_tmp"
  gpg --batch --quiet --show-keys "$key_tmp" >/dev/null 2>&1 || die "sing-box 软件源密钥验证失败。"
  install -m 0644 "$key_tmp" /etc/apt/keyrings/sing-box.asc
  rm -f "$key_tmp"
  cat > /etc/apt/sources.list.d/sing-box.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sing-box.asc
EOF
}

ensure_service_file() {
  local bin_path
  bin_path=$(command -v sing-box || echo "/usr/local/bin/sing-box")
  install -d -m 0750 /var/lib/sing-box
  install -d -m 0755 /var/log

  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    local unit_file="/etc/systemd/system/${SYSTEMD_SERVICE}"
    if [[ ! -f "$unit_file" ]] || ! grep -q "\-c ${CONFIG_FILE}" "$unit_file" 2>/dev/null || ! grep -q "LogRateLimitIntervalSec" "$unit_file" 2>/dev/null; then
      info "配置 ${SYSTEMD_SERVICE} 服务单元……"
      cat > "$unit_file" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${bin_path} -D /var/lib/sing-box -c ${CONFIG_FILE} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity
LogRateLimitIntervalSec=30s
LogRateLimitBurst=500

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
    fi
  else
    local rc_file="/etc/init.d/sing-box"
    cat > "$rc_file" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="${bin_path}"
command_args="-D /var/lib/sing-box -c ${CONFIG_FILE} run"
command_background="true"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
EOF
    chmod 0755 "$rc_file"
    rc-update add sing-box default >/dev/null 2>&1 || true
  fi
}

ensure_systemd_service() {
  ensure_service_file "$@"
}

install_singbox_binary() {
  local target_ver=${1:-}
  local current_ver=""
  if command -v sing-box >/dev/null 2>&1; then
    current_ver=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}' || true)
    current_ver=${current_ver#v}
  fi

  if [[ -n "$current_ver" && -z "$target_ver" ]]; then
    local maj min
    maj=$(echo "$current_ver" | cut -d. -f1)
    min=$(echo "$current_ver" | cut -d. -f2)
    if [[ "$maj" -ge 1 && "$min" -ge 10 ]]; then
      info "已安装 sing-box v${current_ver}。"
      ensure_service_file
      return 0
    fi
  fi

  local raw_arch arch
  raw_arch=$(uname -m)
  case "$raw_arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7*|armhf) arch="armv7" ;;
    s390x) arch="s390x" ;;
    riscv64) arch="riscv64" ;;
    *) die "不支持的 CPU 架构：$raw_arch" ;;
  esac

  local ver="$target_ver"
  if [[ -z "$ver" || "$ver" == "FORCE" ]]; then
    info "获取 sing-box 最新版本信息……"
    ver=$(curl -fsSL --connect-timeout 8 -m 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//' || true)
    if [[ -z "$ver" || "$ver" == "null" ]]; then
      ver="1.11.4"
    fi
  fi

  info "正在下载 sing-box v${ver} (linux-${arch}) 核心……"
  local pkg_name="sing-box-${ver}-linux-${arch}"
  local tar_file="/tmp/${pkg_name}.tar.gz"
  local tmp_dir="/tmp/${pkg_name}"
  rm -rf "$tar_file" "$tmp_dir"

  local -a urls=(
    "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg_name}.tar.gz"
    "https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg_name}.tar.gz"
    "https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg_name}.tar.gz"
  )

  local dl_ok=0
  for u in "${urls[@]}"; do
    if curl -fSL --connect-timeout 10 -m 90 "$u" -o "$tar_file" 2>/dev/null && [[ -s "$tar_file" ]]; then
      dl_ok=1
      break
    fi
    rm -f "$tar_file"
  done

  [[ $dl_ok -eq 1 && -s "$tar_file" ]] || die "下载 sing-box 核心失败，请检查服务器网络连接。"

  mkdir -p "$tmp_dir"
  tar -xzf "$tar_file" -C "$tmp_dir"
  local bin
  bin=$(find "$tmp_dir" -type f -name "sing-box" | head -n 1)
  [[ -n "$bin" && -f "$bin" ]] || die "解压 sing-box 核心失败，未找到二进制文件。"

  install -d -m 0755 /usr/local/bin /usr/bin
  install -m 0755 "$bin" /usr/local/bin/sing-box
  ln -sf /usr/local/bin/sing-box /usr/bin/sing-box 2>/dev/null || true
  rm -rf "$tar_file" "$tmp_dir"

  local installed_ver
  installed_ver=$(sing-box version 2>/dev/null | head -n 1 || true)
  [[ -n "$installed_ver" ]] || die "sing-box 核心二进制无法执行，请检查系统架构兼容性。"

  ensure_service_file
  ok "sing-box 安装就绪：${installed_ver}"
}

install_dependencies_and_core() {
  detect_os
  info "检测操作系统与环境：${OS_ID:-Linux} (${PKG_MGR:-未知}) / ${INIT_SYSTEM}……"

  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg jq openssl certbot iproute2 nftables cron python3 tar gzip
      ensure_certbot_environment
      ;;
    dnf)
      dnf install -y epel-release 2>/dev/null || true
      dnf install -y ca-certificates curl gnupg2 jq openssl certbot iproute nftables cronie python3 tar gzip
      systemctl enable --now crond >/dev/null 2>&1 || true
      ensure_certbot_environment
      ;;
    yum)
      yum install -y epel-release 2>/dev/null || true
      yum install -y ca-certificates curl gnupg2 jq openssl certbot iproute nftables cronie python3 tar gzip
      systemctl enable --now crond >/dev/null 2>&1 || true
      ensure_certbot_environment
      ;;
    apk)
      apk update
      apk add --no-cache bash ca-certificates curl gnupg jq openssl certbot iproute2 nftables tzdata python3 tar gzip coreutils dcron
      rc-update add dcron default >/dev/null 2>&1 || rc-update add crond default >/dev/null 2>&1 || true
      rc-service dcron start >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
      ensure_certbot_environment
      ;;
    *)
      warn "未识别的包管理器，跳过系统依赖自动安装，请确保已安装 curl、jq、python3、nftables、openssl 等工具。"
      ;;
  esac

  install_singbox_binary
}

upgrade_sing_box() {
  preflight
  install_dependencies_and_core
  info "正在检查并更新 sing-box 核心……"
  install_singbox_binary "FORCE"
  if [[ -s "$CONFIG_FILE" ]]; then
    sing-box check -c "$CONFIG_FILE" || die "新版本下配置校验失败，请检查 ${CONFIG_FILE}。"
    service_restart "$SYSTEMD_SERVICE"
  fi
  update_self_script "silent" 2>/dev/null || true
  local new_ver
  new_ver=$(sing-box version 2>/dev/null | head -n 1 || echo "未知")
  ok "sing-box 核心已更新：${new_ver}"
}

size_to_bytes() {
  local size_str=$1
  [[ "$size_str" == "unlimited" || "$size_str" == "0" || -z "$size_str" ]] && { echo "0"; return 0; }
  local number unit
  if [[ "$size_str" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit=$(printf "%s" "${BASH_REMATCH[2]}" | tr '[:lower:]' '[:upper:]')
  else
    echo "0"
    return 0
  fi
  case "$unit" in
    "MB"|"M") echo $((number * 1048576)) ;;
    "GB"|"G") echo $((number * 1073741824)) ;;
    "TB"|"T") echo $((number * 1099511627776)) ;;
    "KB"|"K") echo $((number * 1024)) ;;
    "B"|"")   echo "$number" ;;
    *) echo "0" ;;
  esac
}

bytes_to_human() {
  local bytes=${1:-0}
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1099511627776) printf "%.2f TB", b / 1099511627776;
    else if (b >= 1073741824) printf "%.2f GB", b / 1073741824;
    else if (b >= 1048576) printf "%.2f MB", b / 1048576;
    else if (b >= 1024) printf "%.2f KB", b / 1024;
    else printf "%d B", b;
  }'
}

traffic_init_table() {
  nft add table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  nft add chain inet "$NFT_TABLE" input '{ type filter hook input priority 0; policy accept; }' >/dev/null 2>&1 || true
  nft add chain inet "$NFT_TABLE" output '{ type filter hook output priority 0; policy accept; }' >/dev/null 2>&1 || true
  nft add chain inet "$NFT_TABLE" forward '{ type filter hook forward priority 0; policy accept; }' >/dev/null 2>&1 || true
}

traffic_counter_value() {
  local port=$1 direction=$2 output bytes
  output=$(nft list counter inet "$NFT_TABLE" "node_${port}_${direction}" 2>/dev/null || true)
  bytes=$(awk '/bytes/ {for(i=1;i<=NF;i++) if($i=="bytes") {print $(i+1); exit}}' <<<"$output")
  echo "${bytes:-0}"
}

traffic_remove_rule_matches() {
  local marker=$1
  local chain handle deleted=0 chain_out
  for chain in input output forward; do
    while true; do
      chain_out=$(nft -a list chain inet "$NFT_TABLE" "$chain" 2>/dev/null || true)
      handle=$(awk -v m="$marker" '$0 ~ m {for(i=1;i<=NF;i++) if($i=="handle") {print $(i+1); exit}}' <<<"$chain_out")
      [[ -n "$handle" ]] || break
      nft delete rule inet "$NFT_TABLE" "$chain" handle "$handle" >/dev/null 2>&1 || true
      deleted=$((deleted + 1))
      [[ $deleted -ge 100 ]] && break
    done
  done
}

traffic_remove_port() {
  local port=$1
  traffic_remove_rule_matches "node_${port}_quota"
  traffic_remove_rule_matches "node_${port}_in"
  traffic_remove_rule_matches "node_${port}_out"
  nft delete quota inet "$NFT_TABLE" "node_${port}_quota" >/dev/null 2>&1 || true
  nft delete counter inet "$NFT_TABLE" "node_${port}_in" >/dev/null 2>&1 || true
  nft delete counter inet "$NFT_TABLE" "node_${port}_out" >/dev/null 2>&1 || true
  remove_traffic_cron "$port"
}

traffic_install_port() {
  local node=$1
  local port billing limit quota_bytes
  port=$(jq -r '.port' <<<"$node")
  billing=$(jq -r '.traffic.billing_mode // "single"' <<<"$node")
  limit=$(jq -r '.traffic.monthly_limit // "unlimited"' <<<"$node")

  traffic_init_table

  # 保证基础计数器和统计规则存在
  if ! nft list counter inet "$NFT_TABLE" "node_${port}_in" >/dev/null 2>&1; then
    nft add counter inet "$NFT_TABLE" "node_${port}_in" >/dev/null 2>&1 || true
    nft add rule inet "$NFT_TABLE" input tcp dport "$port" counter name "node_${port}_in" >/dev/null 2>&1 || true
    nft add rule inet "$NFT_TABLE" input udp dport "$port" counter name "node_${port}_in" >/dev/null 2>&1 || true
  fi

  if ! nft list counter inet "$NFT_TABLE" "node_${port}_out" >/dev/null 2>&1; then
    nft add counter inet "$NFT_TABLE" "node_${port}_out" >/dev/null 2>&1 || true
    nft add rule inet "$NFT_TABLE" output tcp sport "$port" counter name "node_${port}_out" >/dev/null 2>&1 || true
    nft add rule inet "$NFT_TABLE" output udp sport "$port" counter name "node_${port}_out" >/dev/null 2>&1 || true
  fi

  # 清理旧的配额与丢包规则
  traffic_remove_rule_matches "node_${port}_quota"
  nft delete quota inet "$NFT_TABLE" "node_${port}_quota" >/dev/null 2>&1 || true

  # 如果设置了有限配额，计算当前已用字节并注入配额规则
  if [[ "$limit" != "unlimited" && "$limit" != "0" ]]; then
    quota_bytes=$(size_to_bytes "$limit")
    if [[ "$quota_bytes" -gt 0 ]]; then
      local in_bytes out_bytes current_used
      in_bytes=$(traffic_counter_value "$port" in)
      out_bytes=$(traffic_counter_value "$port" out)
      if [[ "$billing" == "double" ]]; then
        current_used=$((in_bytes + out_bytes))
      else
        current_used=$out_bytes
      fi
      nft add quota inet "$NFT_TABLE" "node_${port}_quota" "{ over ${quota_bytes} bytes used ${current_used} bytes }" >/dev/null 2>&1 || true
      if [[ "$billing" == "double" ]]; then
        nft insert rule inet "$NFT_TABLE" input tcp dport "$port" quota name "node_${port}_quota" drop >/dev/null 2>&1 || true
        nft insert rule inet "$NFT_TABLE" input udp dport "$port" quota name "node_${port}_quota" drop >/dev/null 2>&1 || true
      fi
      nft insert rule inet "$NFT_TABLE" output tcp sport "$port" quota name "node_${port}_quota" drop >/dev/null 2>&1 || true
      nft insert rule inet "$NFT_TABLE" output udp sport "$port" quota name "node_${port}_quota" drop >/dev/null 2>&1 || true
    fi
  fi

  setup_traffic_cron "$node"
}

setup_traffic_cron() {
  local node=$1 port day tmp
  port=$(jq -r '.port' <<<"$node")
  day=$(jq -r '.traffic.reset_day // empty' <<<"$node")
  tmp=$(mktemp)
  (crontab -l 2>/dev/null || true) | awk -v tag="${CRON_TAG}-${port}" 'index($0, tag) == 0' >"$tmp" || true
  if [[ -n "$day" && "$day" =~ ^[0-9]+$ && "$day" -ge 1 && "$day" -le 31 ]]; then
    echo "5 0 $day * * ${SCRIPT_INSTALL_PATH} --reset-traffic $port >/dev/null 2>&1 # ${CRON_TAG}-${port}" >>"$tmp"
  fi
  crontab "$tmp" >/dev/null 2>&1 || true
  rm -f "$tmp"
}

remove_traffic_cron() {
  local port=$1 tmp
  tmp=$(mktemp)
  (crontab -l 2>/dev/null || true) | awk -v tag="${CRON_TAG}-${port}" 'index($0, tag) == 0' >"$tmp" || true
  crontab "$tmp" >/dev/null 2>&1 || true
  rm -f "$tmp"
}

sync_traffic_rules() {
  local nodes=${1:-$(current_nodes_json)} node
  traffic_init_table
  while IFS= read -r node; do
    [[ -n "$node" ]] && traffic_install_port "$node"
  done < <(jq -c '.[]?' <<<"$nodes")
}

reset_traffic_port() {
  local port=$1 node_name=${2:-} is_auto=${3:-0}
  local in_bytes out_bytes total_bytes
  in_bytes=$(traffic_counter_value "$port" in)
  out_bytes=$(traffic_counter_value "$port" out)
  total_bytes=$((in_bytes + out_bytes))

  nft reset counter inet "$NFT_TABLE" "node_${port}_in" >/dev/null 2>&1 || true
  nft reset counter inet "$NFT_TABLE" "node_${port}_out" >/dev/null 2>&1 || true
  nft reset quota inet "$NFT_TABLE" "node_${port}_quota" >/dev/null 2>&1 || true

  if [[ -r "$STATE_FILE" ]]; then
    local node
    node=$(jq -c --argjson port "$port" '.nodes[]? | select(.port == $port)' "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$node" ]]; then
      traffic_install_port "$node"
      [[ -z "$node_name" ]] && node_name=$(jq -r '.name // empty' <<<"$node")
    fi
  fi

  install -d -m 0700 "$STATE_DIR"
  local now action_type
  now=$(date '+%Y-%m-%d %H:%M:%S')
  action_type="手动重置"
  (( is_auto )) && action_type="自动定时重置"
  printf "%s | 端口 %s (%s) | %s | 重置前: 入站 %s, 出站 %s, 总计 %s\n" \
    "$now" "$port" "${node_name:-未知}" "$action_type" \
    "$(bytes_to_human "$in_bytes")" "$(bytes_to_human "$out_bytes")" "$(bytes_to_human "$total_bytes")" >> "$TRAFFIC_LOG"
  info "端口 $port 流量统计与配额已重置（已释放流量：$(bytes_to_human "$total_bytes")）。"
}

reset_traffic_all() {
  local nodes node port name count=0
  nodes=$(current_nodes_json)
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    port=$(jq -r '.port' <<<"$node")
    name=$(jq -r '.name' <<<"$node")
    reset_traffic_port "$port" "$name" 0
    count=$((count + 1))
  done < <(jq -c '.[]?' <<<"$nodes")
  ok "已重置全部 ${count} 个节点的流量统计。"
}

traffic_defaults_json() {
  jq -cn \
    --arg billing "${1:-single}" \
    --arg limit "${2:-unlimited}" \
    --arg day "${3:-}" \
    '{enabled:true,billing_mode:$billing,monthly_limit:$limit,reset_day:(if $day == "" then null else ($day|tonumber) end)}'
}

collect_traffic_settings() {
  local old=${1:-} target=${2:-}
  local old_billing old_limit old_day traffic_json
  old_billing=$(jq -r '.traffic.billing_mode // "single"' <<<"${old:-"{}"}")
  old_limit=$(jq -r '.traffic.monthly_limit // "unlimited"' <<<"${old:-"{}"}")
  old_day=$(jq -r '.traffic.reset_day // empty' <<<"${old:-"{}"}")
  TRAFFIC_BILLING="$old_billing"; TRAFFIC_LIMIT="$old_limit"; TRAFFIC_RESET_DAY="$old_day"
  if (( ! NON_INTERACTIVE )); then
    prompt_choice TRAFFIC_BILLING "流量计费统计方式" "$TRAFFIC_BILLING" \
      "single|单向计费（仅统计出站/下行流量）" \
      "double|双向计费（同时统计入站与出站流量）" || return 1
  fi
  prompt_value TRAFFIC_LIMIT "月流量配额（如 100GB、1TB，输入 0 或 unlimited 表示不限额）" "$TRAFFIC_LIMIT"
  validate_quota "$TRAFFIC_LIMIT" || die "流量配额格式无效，请输入类似 100MB、500GB、2TB 或 unlimited。"
  [[ "$TRAFFIC_LIMIT" == "0" ]] && TRAFFIC_LIMIT="unlimited"
  prompt_value TRAFFIC_RESET_DAY "每月重置日（1-31日，输入 0 或留空表示不自动重置）" "${TRAFFIC_RESET_DAY:-1}"
  if [[ -n "$TRAFFIC_RESET_DAY" && "$TRAFFIC_RESET_DAY" != "0" ]]; then
    validate_reset_day "$TRAFFIC_RESET_DAY" || die "重置日必须在 1 到 31 之间。"
  else
    TRAFFIC_RESET_DAY=""
  fi
  traffic_json=$(traffic_defaults_json "$TRAFFIC_BILLING" "$TRAFFIC_LIMIT" "$TRAFFIC_RESET_DAY")
  if [[ -n "$target" ]]; then
    printf -v "$target" "%s" "$traffic_json"
  else
    printf "%s" "$traffic_json"
  fi
}

collect_reality_settings() {
  local old=${1:-} keypair priv pub
  NODE_UUID=$(jq -r '.uuid // empty' <<<"${old:-"{}"}")
  NODE_UUID=${NODE_UUID:-$(generate_uuid)}
  prompt_value NODE_UUID "VLESS UUID" "$NODE_UUID"
  validate_uuid "$NODE_UUID" || die "VLESS UUID 格式无效。"
  REALITY_PRIVATE_KEY=$(jq -r '.reality.private_key // empty' <<<"${old:-"{}"}")
  REALITY_PUBLIC_KEY=$(jq -r '.reality.public_key // empty' <<<"${old:-"{}"}")
  REALITY_SHORT_ID=$(jq -r '.reality.short_id // empty' <<<"${old:-"{}"}")
  REALITY_HANDSHAKE_SERVER=$(jq -r '.reality.handshake_server // "www.microsoft.com"' <<<"${old:-"{}"}")
  REALITY_HANDSHAKE_PORT=$(jq -r '.reality.handshake_port // 443' <<<"${old:-"{}"}")
  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    keypair=$(generate_reality_keypair)
    priv=$(echo "$keypair" | awk '{print $1}')
    pub=$(echo "$keypair" | awk '{print $2}')
    REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY:-$priv}
    REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY:-$pub}
  fi
  prompt_secret REALITY_PRIVATE_KEY "REALITY 私钥 (Private Key)" "$REALITY_PRIVATE_KEY"
  prompt_value REALITY_PUBLIC_KEY "REALITY 公钥 (Public Key)" "$REALITY_PUBLIC_KEY"
  prompt_value REALITY_SHORT_ID "REALITY Short ID (Hex)" "${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
  prompt_value REALITY_HANDSHAKE_SERVER "REALITY 握手伪装域名" "$REALITY_HANDSHAKE_SERVER"
  prompt_value REALITY_HANDSHAKE_PORT "REALITY 握手端口" "$REALITY_HANDSHAKE_PORT"
  validate_host "$REALITY_HANDSHAKE_SERVER" || die "REALITY 握手域名无效。"
  validate_port "$REALITY_HANDSHAKE_PORT" || die "REALITY 握手端口无效。"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" && "$REALITY_SHORT_ID" =~ ^[0-9a-fA-F]{2,32}$ ]] || die "REALITY 密钥或 Short ID 无效。"
}

collect_ss_settings() {
  local old=${1:-} current_method
  current_method=$(jq -r '.method // "2022-blake3-aes-128-gcm"' <<<"${old:-"{}"}")
  SS_METHOD=${SS_METHOD:-$current_method}
  if (( ! NON_INTERACTIVE )); then choose_ss_method || return 1; fi
  [[ -n "$SS_METHOD" ]] || SS_METHOD="2022-blake3-aes-128-gcm"
  validate_ss_method "$SS_METHOD" || die "不支持的 Shadowsocks 加密方法：${SS_METHOD}"
  local default_pass
  default_pass=$(jq -r '.password // empty' <<<"${old:-"{}"}")
  default_pass=${default_pass:-$(generate_ss_password "$SS_METHOD")}
  NODE_PASSWORD="$default_pass"
  prompt_secret NODE_PASSWORD "Shadowsocks 密码/密钥" "$NODE_PASSWORD"
  if ! validate_ss_password "$SS_METHOD" "$NODE_PASSWORD"; then
    local key_bytes
    if key_bytes=$(ss2022_key_bytes "$SS_METHOD"); then
      die "${SS_METHOD} 要求每段密钥是 ${key_bytes} 字节的标准 Base64 编码。"
    fi
    die "Shadowsocks 密码格式无效。"
  fi
}

collect_inbound_settings() {
  local old=${1:-} protocol="$PROTOCOL"
  case "$protocol" in
    anytls|trojan|hysteria2)
      local default_pass
      default_pass=$(jq -r '.password // empty' <<<"${old:-"{}"}")
      default_pass=${default_pass:-${PASSWORD:-$(random_password)}}
      NODE_PASSWORD="$default_pass"
      prompt_secret NODE_PASSWORD "$(protocol_label "$protocol") 认证密码" "$NODE_PASSWORD"
      [[ -n "$NODE_PASSWORD" ]] || die "密码不能为空。"
      ;;
    shadowsocks)
      collect_ss_settings "$old" || return 1
      ;;
    vless-reality)
      collect_reality_settings "$old"
      ;;
    socks5)
      local default_user default_pass
      default_user=$(jq -r '.username // empty' <<<"${old:-"{}"}")
      default_pass=$(jq -r '.password // empty' <<<"${old:-"{}"}")
      NODE_USERNAME="${NODE_USERNAME:-$default_user}"
      NODE_PASSWORD="${NODE_PASSWORD:-$default_pass}"
      prompt_value NODE_USERNAME "SOCKS5 认证用户名 (可选，留空表示免密认证)" "$NODE_USERNAME"
      if [[ -n "$NODE_USERNAME" ]]; then
        NODE_PASSWORD=${NODE_PASSWORD:-$(random_password)}
        prompt_secret NODE_PASSWORD "SOCKS5 认证密码" "$NODE_PASSWORD"
        [[ -n "$NODE_PASSWORD" ]] || die "配置了认证用户名时，认证密码不能为空。"
      else
        NODE_PASSWORD=""
      fi
      ;;
    http)
      local default_user default_pass
      default_user=$(jq -r '.username // empty' <<<"${old:-"{}"}")
      default_pass=$(jq -r '.password // empty' <<<"${old:-"{}"}")
      NODE_USERNAME="${NODE_USERNAME:-$default_user}"
      NODE_PASSWORD="${NODE_PASSWORD:-$default_pass}"
      local proto_title="HTTP"
      [[ "$HTTP_TLS" == "true" ]] && proto_title="HTTPS"
      prompt_value NODE_USERNAME "${proto_title} 代理认证用户名 (可选，留空表示免密认证)" "$NODE_USERNAME"
      if [[ -n "$NODE_USERNAME" ]]; then
        NODE_PASSWORD=${NODE_PASSWORD:-$(random_password)}
        prompt_secret NODE_PASSWORD "${proto_title} 代理认证密码" "$NODE_PASSWORD"
        [[ -n "$NODE_PASSWORD" ]] || die "配置了认证用户名时，认证密码不能为空。"
      else
        NODE_PASSWORD=""
      fi
      ;;
    *) die "不支持的入站协议：$protocol" ;;
  esac
}

collect_outbound_settings() {
  local old=${1:-} target=${2:-}
  local mode outbound_json
  if [[ -n "$OUTBOUND" ]]; then
    mode="$OUTBOUND"
  else
    mode=$(jq -r '.outbound.type // "direct"' <<<"${old:-"{}"}")
  fi
  OUTBOUND="$mode"
  [[ "$OUTBOUND" == "ss" ]] && OUTBOUND="shadowsocks"
  choose_outbound_protocol OUTBOUND "$OUTBOUND" "出口协议设置" || return 1
  case "$OUTBOUND" in
    direct)
      outbound_json=$(jq -cn '{type:"direct"}')
      ;;
    socks5|socks)
      local socks_server socks_port socks_user socks_pass
      socks_server=$(jq -r '.outbound.server // empty' <<<"${old:-"{}"}")
      socks_port=$(jq -r '.outbound.port // "1080"' <<<"${old:-"{}"}")
      socks_user=$(jq -r '.outbound.username // empty' <<<"${old:-"{}"}")
      socks_pass=$(jq -r '.outbound.password // empty' <<<"${old:-"{}"}")
      prompt_value socks_server "出口 SOCKS5 服务器地址 (域名或 IP)" "$socks_server"
      prompt_value socks_port "出口 SOCKS5 端口" "$socks_port"
      prompt_value socks_user "出口 SOCKS5 认证用户名 (可选，留空表示无认证)" "$socks_user"
      prompt_secret socks_pass "出口 SOCKS5 认证密码 (可选，留空表示无认证)" "$socks_pass"
      validate_host "$socks_server" && validate_port "$socks_port" || die "SOCKS5 出口参数无效。"
      outbound_json=$(jq -cn \
        --arg server "$socks_server" \
        --argjson port "$socks_port" \
        --arg username "$socks_user" \
        --arg password "$socks_pass" \
        '{type:"socks5",server:$server,port:$port,username:$username,password:$password}')
      ;;
    http)
      local http_server http_port http_user http_pass http_tls http_sni
      http_server=$(jq -r '.outbound.server // empty' <<<"${old:-"{}"}")
      http_port=$(jq -r '.outbound.port // "8080"' <<<"${old:-"{}"}")
      http_user=$(jq -r '.outbound.username // empty' <<<"${old:-"{}"}")
      http_pass=$(jq -r '.outbound.password // empty' <<<"${old:-"{}"}")
      http_tls=$(jq -r '.outbound.tls.enabled // false' <<<"${old:-"{}"}")
      http_sni=$(jq -r '.outbound.tls.server_name // empty' <<<"${old:-"{}"}")
      prompt_value http_server "出口 HTTP 代理服务器地址 (域名或 IP)" "$http_server"
      prompt_value http_port "出口 HTTP 代理端口" "$http_port"
      prompt_value http_user "出口 HTTP 认证用户名 (可选，留空表示无认证)" "$http_user"
      prompt_secret http_pass "出口 HTTP 认证密码 (可选，留空表示无认证)" "$http_pass"
      local tls_choice="no"
      [[ "$http_tls" == "true" ]] && tls_choice="yes"
      prompt_choice tls_choice "是否启用 HTTPS/TLS 代理连接" "$tls_choice" \
        "no|普通 HTTP 代理 (明文传输)" \
        "yes|HTTPS 代理 (TLS 加密传输)" || return 1
      if [[ "$tls_choice" == "yes" ]]; then
        prompt_value http_sni "TLS SNI / 证书域名" "${http_sni:-$http_server}"
        http_tls="true"
      else
        http_tls="false"
        http_sni=""
      fi
      validate_host "$http_server" && validate_port "$http_port" || die "HTTP 代理出口参数无效。"
      outbound_json=$(jq -cn \
        --arg server "$http_server" \
        --argjson port "$http_port" \
        --arg username "$http_user" \
        --arg password "$http_pass" \
        --argjson tls "$http_tls" \
        --arg sni "$http_sni" \
        '{type:"http",server:$server,port:$port,username:$username,password:$password,tls:{enabled:$tls,server_name:$sni}}')
      ;;
    shadowsocks)
      local ss_server ss_port ss_method ss_password
      ss_server=$(jq -r '.outbound.server // empty' <<<"${old:-"{}"}")
      ss_port=$(jq -r '.outbound.port // "8388"' <<<"${old:-"{}"}")
      ss_method=$(jq -r '.outbound.method // "2022-blake3-aes-128-gcm"' <<<"${old:-"{}"}")
      ss_password=$(jq -r '.outbound.password // empty' <<<"${old:-"{}"}")
      prompt_value ss_server "出口 Shadowsocks 服务器地址" "$ss_server"
      prompt_value ss_port "出口 Shadowsocks 端口" "$ss_port"
      SS_METHOD="$ss_method"
      if (( ! NON_INTERACTIVE )); then choose_ss_method || return 1; fi
      ss_method="$SS_METHOD"
      prompt_secret ss_password "出口 Shadowsocks 密码" "$ss_password"
      validate_host "$ss_server" && validate_port "$ss_port" && validate_ss_method "$ss_method" || die "Shadowsocks 出口参数无效。"
      validate_ss_password "$ss_method" "$ss_password" || die "Shadowsocks 出口密码格式不匹配。"
      outbound_json=$(jq -cn --arg server "$ss_server" --argjson port "$ss_port" --arg method "$ss_method" --arg password "$ss_password" \
        '{type:"shadowsocks",server:$server,port:$port,method:$method,password:$password}')
      ;;
    anytls|trojan|hysteria2)
      local server port password server_name
      server=$(jq -r '.outbound.server // empty' <<<"${old:-"{}"}")
      port=$(jq -r '.outbound.port // "443"' <<<"${old:-"{}"}")
      password=$(jq -r '.outbound.password // empty' <<<"${old:-"{}"}")
      server_name=$(jq -r '.outbound.server_name // empty' <<<"${old:-"{}"}")
      prompt_value server "出口服务器地址" "$server"
      prompt_value port "出口端口" "$port"
      prompt_secret password "$(protocol_label "$OUTBOUND") 出口密码" "$password"
      prompt_value server_name "TLS 域名 (SNI)" "${server_name:-$server}"
      validate_host "$server" && validate_port "$port" && [[ -n "$password" ]] || die "出口参数无效。"
      outbound_json=$(jq -cn --arg type "$OUTBOUND" --arg server "$server" --argjson port "$port" --arg password "$password" --arg server_name "$server_name" \
        '{type:$type,server:$server,port:$port,password:$password,server_name:$server_name}')
      ;;
    vless-reality)
      local server port uuid server_name public_key short_id
      server=$(jq -r '.outbound.server // empty' <<<"${old:-"{}"}")
      port=$(jq -r '.outbound.port // "443"' <<<"${old:-"{}"}")
      uuid=$(jq -r '.outbound.uuid // empty' <<<"${old:-"{}"}")
      server_name=$(jq -r '.outbound.server_name // "www.microsoft.com"' <<<"${old:-"{}"}")
      public_key=$(jq -r '.outbound.public_key // empty' <<<"${old:-"{}"}")
      short_id=$(jq -r '.outbound.short_id // empty' <<<"${old:-"{}"}")
      prompt_value server "出口服务器地址" "$server"
      prompt_value port "出口端口" "$port"
      prompt_value uuid "出口 VLESS UUID" "$uuid"
      prompt_value server_name "出口 REALITY SNI 握手域名" "$server_name"
      prompt_value public_key "出口 REALITY 公钥" "$public_key"
      prompt_value short_id "出口 REALITY Short ID" "$short_id"
      validate_host "$server" && validate_port "$port" && validate_uuid "$uuid" || die "VLESS 出口参数无效。"
      [[ -n "$public_key" && "$short_id" =~ ^[0-9a-fA-F]{2,32}$ ]] || die "REALITY 出口公钥或 Short ID 无效。"
      outbound_json=$(jq -cn --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg server_name "$server_name" --arg public_key "$public_key" --arg short_id "$short_id" \
        '{type:"vless-reality",server:$server,port:$port,uuid:$uuid,server_name:$server_name,public_key:$public_key,short_id:$short_id}')
      ;;
    *) die "不支持的出口协议：$OUTBOUND" ;;
  esac
  if [[ -n "$target" ]]; then
    printf -v "$target" "%s" "$outbound_json"
  else
    printf "%s" "$outbound_json"
  fi
}

collect_node_json() {
  local old=${1:-} target=${2:-}
  local default_protocol default_domain traffic outbound default_port node_json
  default_protocol=$(jq -r '.protocol // "anytls"' <<<"${old:-"{}"}")
  default_domain=$(jq -r '.domain // empty' <<<"${old:-"{}"}")
  PROTOCOL="${PROTOCOL:-$default_protocol}"
  if (( ! SKIP_PROTOCOL_PROMPT )); then
    choose_protocol PROTOCOL "$PROTOCOL" "入站协议选择" || return 1
  fi
  if [[ "$PROTOCOL" == "http" ]]; then
    local http_tls_choice="plain"
    local default_http_mode="1"
    local old_tls
    old_tls=$(jq -r '.tls // false' <<<"${old:-"{}"}")
    if [[ "$HTTP_TLS" == "true" || "$old_tls" == "true" ]]; then
      default_http_mode="2"
    fi
    prompt_choice http_tls_choice "HTTP 代理加密模式" "$default_http_mode"       "plain|普通 HTTP 代理 (明文传输)"       "tls|HTTPS 代理 (开启 TLS 证书加密)" || return 1
    if [[ "$http_tls_choice" == "tls" ]]; then
      HTTP_TLS="true"
    else
      HTTP_TLS="false"
    fi
  else
    HTTP_TLS="false"
  fi
  NODE_NAME=$(jq -r '.name // empty' <<<"${old:-"{}"}")
  NODE_NAME=${NODE_NAME:-"节点1"}
  prompt_value NODE_NAME "节点名称" "$NODE_NAME"
  NODE_DOMAIN="${NODE_DOMAIN:-$default_domain}"
  NODE_DOMAIN=${NODE_DOMAIN:-${DOMAIN:-$(json_get "$STATE_FILE" '.domain')}}
  if node_requires_certificate "$PROTOCOL" "$HTTP_TLS"; then
    prompt_value NODE_DOMAIN "节点连接地址 (域名)" "$NODE_DOMAIN"
    validate_domain "$NODE_DOMAIN" || die "当前协议 [$(protocol_label "$PROTOCOL")] 需要 SSL 证书，请输入已解析到本机公网 IP 的有效域名 (如 example.com)。"
  else
    local fallback_ip
    fallback_ip="${NODE_DOMAIN:-$(detect_public_ip || true)}"
    if [[ -n "$fallback_ip" ]]; then
      prompt_value NODE_DOMAIN "节点连接地址 (域名或公网 IP)" "$fallback_ip"
    else
      prompt_value NODE_DOMAIN "节点连接地址 (域名或公网 IP，请勿填写 127.0.0.1)" ""
    fi
    [[ -n "$NODE_DOMAIN" ]] || die "节点连接地址不能为空。"
    if [[ "$NODE_DOMAIN" == "127.0.0.1" || "$NODE_DOMAIN" == "localhost" ]]; then
      warn "注意：127.0.0.1 是本机回环地址，外部客户端将无法连接！建议输入服务器公网 IP。"
    fi
    validate_host "$NODE_DOMAIN" || die "节点连接地址无效。"
  fi
  default_port=$(jq -r '.port // empty' <<<"${old:-"{}"}")
  default_port=${default_port:-${PORT:-}}
  if [[ -z "$default_port" ]]; then
    case "$PROTOCOL" in
      anytls|trojan|vless-reality) default_port="443" ;;
      shadowsocks) default_port="8388" ;;
      hysteria2) default_port="8443" ;;
      socks5) default_port="1080" ;;
      http)
        if [[ "$HTTP_TLS" == "true" ]]; then
          default_port="8443"
        else
          default_port="8080"
        fi
        ;;
      *) default_port="443" ;;
    esac
  fi
  NODE_PORT="${NODE_PORT:-$default_port}"
  prompt_value NODE_PORT "监听端口 (Port)" "$NODE_PORT"
  validate_port "$NODE_PORT" || die "监听端口无效。"
  collect_inbound_settings "$old" || return 1
  echo
  info "配置流量管理与配额策略……"
  collect_traffic_settings "$old" traffic || return 1
  echo
  info "配置节点出口分流路由……"
  collect_outbound_settings "$old" outbound || return 1
  case "$PROTOCOL" in
    vless-reality)
      node_json=$(jq -cn --arg name "$NODE_NAME" --arg protocol "$PROTOCOL" --arg domain "$NODE_DOMAIN" --argjson port "$NODE_PORT" \
        --arg uuid "$NODE_UUID" --arg private_key "$REALITY_PRIVATE_KEY" --arg public_key "$REALITY_PUBLIC_KEY" \
        --arg short_id "$REALITY_SHORT_ID" --arg handshake_server "$REALITY_HANDSHAKE_SERVER" --argjson handshake_port "$REALITY_HANDSHAKE_PORT" \
        --argjson traffic "$traffic" --argjson outbound "$outbound" \
        '{name:$name,protocol:$protocol,domain:$domain,port:$port,uuid:$uuid,reality:{private_key:$private_key,public_key:$public_key,short_id:$short_id,handshake_server:$handshake_server,handshake_port:$handshake_port},traffic:$traffic,outbound:$outbound}')
      ;;
    shadowsocks)
      node_json=$(jq -cn --arg name "$NODE_NAME" --arg protocol "$PROTOCOL" --arg domain "$NODE_DOMAIN" --argjson port "$NODE_PORT" \
        --arg method "$SS_METHOD" --arg password "$NODE_PASSWORD" --argjson traffic "$traffic" --argjson outbound "$outbound" \
        '{name:$name,protocol:$protocol,domain:$domain,port:$port,method:$method,password:$password,traffic:$traffic,outbound:$outbound}')
      ;;
    socks5)
      node_json=$(jq -cn --arg name "$NODE_NAME" --arg protocol "$PROTOCOL" --arg domain "$NODE_DOMAIN" --argjson port "$NODE_PORT" \
        --arg username "$NODE_USERNAME" --arg password "$NODE_PASSWORD" \
        --argjson traffic "$traffic" --argjson outbound "$outbound" \
        '{name:$name,protocol:$protocol,domain:$domain,port:$port,username:$username,password:$password,traffic:$traffic,outbound:$outbound}')
      ;;
    http)
      node_json=$(jq -cn --arg name "$NODE_NAME" --arg protocol "$PROTOCOL" --arg domain "$NODE_DOMAIN" --argjson port "$NODE_PORT" \
        --arg username "$NODE_USERNAME" --arg password "$NODE_PASSWORD" --argjson tls "$HTTP_TLS" \
        --argjson traffic "$traffic" --argjson outbound "$outbound" \
        '{name:$name,protocol:$protocol,domain:$domain,port:$port,username:$username,password:$password,tls:$tls,traffic:$traffic,outbound:$outbound}')
      ;;
    *)
      node_json=$(jq -cn --arg name "$NODE_NAME" --arg protocol "$PROTOCOL" --arg domain "$NODE_DOMAIN" --argjson port "$NODE_PORT" \
        --arg password "$NODE_PASSWORD" --argjson traffic "$traffic" --argjson outbound "$outbound" \
        '{name:$name,protocol:$protocol,domain:$domain,port:$port,password:$password,traffic:$traffic,outbound:$outbound}')
      ;;
  esac
  if [[ -n "$target" ]]; then
    printf -v "$target" "%s" "$node_json"
  else
    printf "%s" "$node_json"
  fi
}

state_has_nodes() {
  [[ -r "$STATE_FILE" ]] && jq -e '(.nodes | type == "array") and (.nodes | length > 0)' "$STATE_FILE" >/dev/null 2>&1
}

ensure_state_schema() {
  [[ -r "$STATE_FILE" ]] || return 0
  local version
  version=$(jq -r '.version // 0' "$STATE_FILE" 2>/dev/null || printf '0')
  if [[ "$version" -ge 3 ]]; then return 0; fi

  if jq -e '.nodes | type == "array" and length > 0' "$STATE_FILE" >/dev/null 2>&1; then
    local tmp top_domain
    tmp=$(mktemp)
    top_domain=$(json_get "$STATE_FILE" '.domain')
    jq --arg top_domain "$top_domain" '.version = 3 | .nodes = (.nodes | map(. + {protocol:(.protocol // "anytls"),domain:(if (.domain // "") == "" then $top_domain else .domain end),traffic:(.traffic // {enabled:true,billing_mode:"single",monthly_limit:"unlimited",reset_day:null}),outbound:(if (.outbound.type // "direct") == "ss" then (.outbound + {type:"shadowsocks"}) else (.outbound // {type:"direct"}) end)}))' "$STATE_FILE" >"$tmp"
    install -m 0600 "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    return 0
  fi
}

current_nodes_json() {
  ensure_state_schema
  [[ -r "$STATE_FILE" ]] || { echo "[]"; return; }
  jq -c '.nodes // []' "$STATE_FILE"
}

node_count() {
  local nodes=${1:-$(current_nodes_json)}
  jq 'length' <<<"$nodes" 2>/dev/null || echo 0
}

validate_nodes_state() {
  local state_file=$1 node protocol outbound_type
  jq -e '(.nodes|type=="array") and (if (.nodes|length > 0) then (([.nodes[].port]|length==(unique|length)) and all(.nodes[]; (.name|type=="string" and length>0) and (.port|type=="number" and floor==. and .>=1 and .<=65535) and (.protocol|IN("anytls","shadowsocks","vless-reality","trojan","hysteria2","socks5","http")) and (.traffic.monthly_limit|type=="string") and (.traffic.reset_day==null or (.traffic.reset_day|type=="number" and floor==. and .>=1 and .<=31)))) else true end)' "$state_file" >/dev/null 2>&1 || die "节点状态校验失败：请检查协议类型、名称、端口、流量配置是否存在冲突或非法值。"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    protocol=$(jq -r '.protocol' <<<"$node")
    case "$protocol" in
      vless-reality)
        validate_uuid "$(jq -r '.uuid // empty' <<<"$node")" || die "VLESS UUID 无效。"
        [[ -n "$(jq -r '.reality.private_key // empty' <<<"$node")" && -n "$(jq -r '.reality.public_key // empty' <<<"$node")" ]] || die "REALITY 密钥不能为空。"
        ;;
      shadowsocks)
        validate_ss_method "$(jq -r '.method // empty' <<<"$node")" || die "Shadowsocks 加密方法无效。"
        validate_ss_password "$(jq -r '.method' <<<"$node")" "$(jq -r '.password // empty' <<<"$node")" || die "Shadowsocks 密码格式不匹配。"
        ;;
      socks5|http)
        local u_val p_val
        u_val=$(jq -r '.username // empty' <<<"$node")
        p_val=$(jq -r '.password // empty' <<<"$node")
        if [[ -n "$u_val" ]]; then
          [[ -n "$p_val" ]] || die "$(protocol_label "$protocol") 配置了认证用户名时，密码不能为空。"
        fi
        ;;
      *) [[ -n "$(jq -r '.password // empty' <<<"$node")" ]] || die "$(protocol_label "$protocol") 密码不能为空。" ;;
    esac
    outbound_type=$(jq -r '.outbound.type // "direct"' <<<"$node")
    [[ "$outbound_type" == "direct" || "$outbound_type" == "socks5" || "$outbound_type" == "socks" || "$outbound_type" == "http" || "$outbound_type" == "shadowsocks" || "$outbound_type" == "anytls" || "$outbound_type" == "vless-reality" || "$outbound_type" == "trojan" || "$outbound_type" == "hysteria2" ]] || die "不支持的出口协议：$outbound_type"
    if [[ "$outbound_type" != "direct" ]]; then
      validate_host "$(jq -r '.outbound.server // empty' <<<"$node")" || die "出口服务器地址无效。"
      validate_port "$(jq -r '.outbound.port // empty' <<<"$node")" || die "出口端口无效。"
    fi
    case "$outbound_type" in
      shadowsocks)
        validate_ss_method "$(jq -r '.outbound.method // empty' <<<"$node")" || die "Shadowsocks 出口加密方法无效。"
        validate_ss_password "$(jq -r '.outbound.method' <<<"$node")" "$(jq -r '.outbound.password // empty' <<<"$node")" || die "Shadowsocks 出口密码格式不匹配。"
        ;;
      vless-reality)
        validate_uuid "$(jq -r '.outbound.uuid // empty' <<<"$node")" || die "VLESS 出口 UUID 无效。"
        [[ -n "$(jq -r '.outbound.public_key // empty' <<<"$node")" ]] || die "REALITY 出口公钥不能为空。"
        ;;
      anytls|trojan|hysteria2)
        [[ -n "$(jq -r '.outbound.password // empty' <<<"$node")" ]] || die "出口密码不能为空。"
        ;;
    esac
  done < <(jq -c '.nodes[]?' "$state_file")
}

generate_config_from_state() {
  local output=$1 state_file=${2:-$STATE_FILE}
  validate_nodes_state "$state_file"
  jq --arg cert_dir "$CERT_DIR" '
    def cert_tls($n): {
      enabled: true,
      server_name: $n.domain,
      certificate_path: ($cert_dir + "/" + $n.domain + "/fullchain.pem"),
      key_path: ($cert_dir + "/" + $n.domain + "/privkey.pem")
    };
    def inbound($n; $i):
      if $n.protocol == "anytls" then
        {
          type: "anytls",
          tag: ("in-" + (($i + 1)|tostring)),
          listen: "::",
          listen_port: $n.port,
          users: [{name: $n.name, password: $n.password}],
          padding_scheme: [
            "stop=8",
            "0=32-76",
            "1=84-252",
            "2=204-508,c,276-668,c,116-332",
            "3=68-204,c,124-324",
            "4=88-268",
            "5=60-204",
            "6=44-172",
            "7=28-140"
          ],
          tls: cert_tls($n)
        }
      elif $n.protocol == "shadowsocks" then
        {
          type: "shadowsocks",
          tag: ("in-" + (($i + 1)|tostring)),
          listen: "::",
          listen_port: $n.port,
          network: "tcp",
          method: $n.method,
          password: $n.password
        }
      elif $n.protocol == "vless-reality" then
        {
          type: "vless",
          tag: ("in-" + (($i + 1)|tostring)),
          listen: "::",
          listen_port: $n.port,
          users: [{name: $n.name, uuid: $n.uuid, flow: "xtls-rprx-vision"}],
          tls: {
            enabled: true,
            server_name: $n.reality.handshake_server,
            reality: {
              enabled: true,
              handshake: {
                server: $n.reality.handshake_server,
                server_port: $n.reality.handshake_port
              },
              private_key: $n.reality.private_key,
              short_id: [$n.reality.short_id]
            }
          }
        }
      elif $n.protocol == "trojan" then
        {
          type: "trojan",
          tag: ("in-" + (($i + 1)|tostring)),
          listen: "::",
          listen_port: $n.port,
          users: [{name: $n.name, password: $n.password}],
          tls: cert_tls($n)
        }
      elif $n.protocol == "hysteria2" then
        {
          type: "hysteria2",
          tag: ("in-" + (($i + 1)|tostring)),
          listen: "::",
          listen_port: $n.port,
          users: [{name: $n.name, password: $n.password}],
          tls: cert_tls($n)
        }
      elif $n.protocol == "socks5" then
        ({
          type: "socks",
          tag: ("in-" + (($i + 1)|tostring)),
          listen: "::",
          listen_port: $n.port
        } + (if (($n.username // "") != "" and ($n.password // "") != "") then {users: [{username: $n.username, password: $n.password}]} else {} end))
      elif $n.protocol == "http" then
        ({
          type: "http",
          tag: ("in-" + (($i + 1)|tostring)),
          listen: "::",
          listen_port: $n.port
        } + (if (($n.username // "") != "" and ($n.password // "") != "") then {users: [{username: $n.username, password: $n.password}]} else {} end)
          + (if ($n.tls // false) then {tls: cert_tls($n)} else {} end))
      else
        empty
      end;
    def outbound($o; $i):
      if $o.type == "direct" then
        {type: "direct", tag: ("out-" + (($i + 1)|tostring))}
      elif $o.type == "socks5" or $o.type == "socks" then
        ({
          type: "socks",
          tag: ("out-" + (($i + 1)|tostring)),
          server: $o.server,
          server_port: $o.port,
          version: "5"
        } + (if ($o.username // "") != "" then {username: $o.username} else {} end)
          + (if ($o.password // "") != "" then {password: $o.password} else {} end))
      elif $o.type == "http" then
        ({
          type: "http",
          tag: ("out-" + (($i + 1)|tostring)),
          server: $o.server,
          server_port: $o.port
        } + (if ($o.username // "") != "" then {username: $o.username} else {} end)
          + (if ($o.password // "") != "" then {password: $o.password} else {} end)
          + (if ($o.tls.enabled // false) then {tls: {enabled: true, server_name: ($o.tls.server_name // $o.server)}} else {} end))
      elif $o.type == "shadowsocks" then
        {
          type: "shadowsocks",
          tag: ("out-" + (($i + 1)|tostring)),
          server: $o.server,
          server_port: $o.port,
          method: $o.method,
          password: $o.password
        }
      elif $o.type == "anytls" then
        {
          type: "anytls",
          tag: ("out-" + (($i + 1)|tostring)),
          server: $o.server,
          server_port: $o.port,
          password: $o.password,
          tls: {enabled: true, server_name: $o.server_name}
        }
      elif $o.type == "vless-reality" then
        {
          type: "vless",
          tag: ("out-" + (($i + 1)|tostring)),
          server: $o.server,
          server_port: $o.port,
          uuid: $o.uuid,
          flow: "xtls-rprx-vision",
          tls: {
            enabled: true,
            server_name: $o.server_name,
            reality: {
              enabled: true,
              public_key: $o.public_key,
              short_id: $o.short_id
            }
          }
        }
      elif $o.type == "trojan" then
        {
          type: "trojan",
          tag: ("out-" + (($i + 1)|tostring)),
          server: $o.server,
          server_port: $o.port,
          password: $o.password,
          tls: {enabled: true, server_name: $o.server_name}
        }
      elif $o.type == "hysteria2" then
        {
          type: "hysteria2",
          tag: ("out-" + (($i + 1)|tostring)),
          server: $o.server,
          server_port: $o.port,
          password: $o.password,
          tls: {enabled: true, server_name: $o.server_name}
        }
      else
        {type: "direct", tag: ("out-" + (($i + 1)|tostring))}
      end;
    .nodes as $nodes | {
      log: {level: (.log_level // "warn"), timestamp: true},
      inbounds: ([$nodes | to_entries[] | inbound(.value; .key)]),
      outbounds: ([$nodes | to_entries[] | outbound(.value.outbound; .key)] + [{type: "direct", tag: "direct"}, {type: "block", tag: "block"}]),
      route: {
        rules: ([$nodes | to_entries[] | {
          inbound: [("in-" + ((.key + 1)|tostring))],
          action: "route",
          outbound: ("out-" + ((.key + 1)|tostring))
        }]),
        final: "direct"
      }
    }' "$state_file" >"$output"
}

backup_config() {
  [[ -e "$CONFIG_FILE" ]] || return 0
  install -d -m 0700 "$BACKUP_DIR"
  local backup
  backup=$(mktemp "${BACKUP_DIR}/config.$(date +%Y%m%d-%H%M%S).XXXXXX")
  cp -a "$CONFIG_FILE" "$backup"
  printf "%s" "$backup"
}

apply_config() {
  local candidate=$1 backup="" group
  group=$(service_group)
  sing-box check -c "$candidate" || die "配置校验未通过，已放弃应用更改。"
  backup=$(backup_config)
  install -d -m 0750 -o root -g "$group" "$CONFIG_DIR"
  install -m 0640 -o root -g "$group" "$candidate" "$CONFIG_FILE"
  if ! sing-box check -c "$CONFIG_FILE"; then
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$CONFIG_FILE"
    else
      rm -f "$CONFIG_FILE"
    fi
    die "安装后配置校验失败，已自动恢复原配置。"
  fi
  migrate_legacy_state
  ensure_service_file
  service_daemon_reload
  service_enable "$SYSTEMD_SERVICE"
  if ! service_restart "$SYSTEMD_SERVICE"; then
    warn "sing-box 重启命令执行失败，正在查看日志……"
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$SYSTEMD_SERVICE" --no-pager -n 30 || true
    else
      tail -n 30 /var/log/sing-box.log 2>/dev/null || true
    fi
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$CONFIG_FILE"
      service_restart "$SYSTEMD_SERVICE" || true
      die "新配置无法启动服务，已自动回滚备份。"
    fi
    die "sing-box 启动失败。"
  fi
  sleep 1
  if ! service_is_running; then
    warn "sing-box 启动后未能持续运行（已退出），日志摘要："
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$SYSTEMD_SERVICE" --no-pager -n 30 || true
    else
      tail -n 30 /var/log/sing-box.log 2>/dev/null || true
    fi
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$CONFIG_FILE"
      service_restart "$SYSTEMD_SERVICE" || true
      die "新配置启动后异常退出，已自动回滚备份。请检查上方日志。"
    fi
    die "sing-box 服务启动后异常退出，请检查上方日志排查原因。"
  fi
  ok "sing-box 配置文件已生效并成功加载，服务正常运行中。"
}

save_nodes_json() {
  local nodes=$1 state_tmp candidate
  state_tmp=$(mktemp)
  candidate=$(mktemp)

  local base_json='{"version":3,"nodes":[]}'
  if [[ -s "$STATE_FILE" ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    base_json=$(cat "$STATE_FILE")
  fi

  local first_domain
  first_domain=$(jq -r '.[0].domain // empty' <<<"$nodes")
  jq --arg domain "$first_domain" --argjson nodes "$nodes" \
    '.version = 3 | .nodes = $nodes | if ((.domain // "") == "") then .domain = $domain else . end' <<<"$base_json" >"$state_tmp"

  generate_config_from_state "$candidate" "$state_tmp"
  apply_config "$candidate"
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  install -m 0600 "$state_tmp" "$STATE_FILE"
  rm -f "$candidate" "$state_tmp"
  install_deploy_hook
  sync_traffic_rules "$nodes"
  ensure_sbox_cli
}

render_node_table_fallback() {
  local raw=$1
  local headers=("序号" "节点名称" "协议类型" "域名/端口" "当前流量" "月配额/比例" "重置日")
  local min_widths=(6 14 26 24 12 16 8)

  _calc_w() {
    local s=$1 c_bytes c_chars
    c_bytes=$(LC_ALL=C printf "%s" "$s" | wc -c)
    c_chars=$(printf "%s" "$s" | wc -m)
    local w=$(( (c_bytes + c_chars) / 2 ))
    (( w > 0 )) || w=${#s}
    echo "$w"
  }

  _pad() {
    local s=$1 target_w=$2
    local w pad_len
    w=$(_calc_w "$s")
    if (( w >= target_w )); then
      printf "%s  " "$s"
    else
      pad_len=$(( target_w - w ))
      printf "%s%*s" "$s" "$pad_len" ""
    fi
  }

  printf "%s================================================= 节点列表 =================================================%s\n" "$C_CYAN" "$C_RESET"
  local i
  for (( i=0; i<7; i++ )); do
    _pad "${headers[i]}" "${min_widths[i]}"
  done
  printf "\n%s------------------------------------------------------------------------------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  local line c1 c2 c3 c4 c5 c6 c7 c8 rest
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    c1=${line%%|@@|*}; rest=${line#*|@@|}
    c2=${rest%%|@@|*}; rest=${rest#*|@@|}
    c3=${rest%%|@@|*}; rest=${rest#*|@@|}
    c4=${rest%%|@@|*}; rest=${rest#*|@@|}
    c5=${rest%%|@@|*}; rest=${rest#*|@@|}
    c6=${rest%%|@@|*}; rest=${rest#*|@@|}
    c7=${rest%%|@@|*}; c8=${rest#*|@@|}
    _pad "$c1" "${min_widths[0]}"
    _pad "$c2" "${min_widths[1]}"
    _pad "$c3" "${min_widths[2]}"
    _pad "$c4" "${min_widths[3]}"
    _pad "$c5" "${min_widths[4]}"
    _pad "$c6" "${min_widths[5]}"
    _pad "$c7" "${min_widths[6]}"
    if [[ -n "$c8" ]]; then
      printf "%s%s%s" "$C_RED" "$c8" "$C_RESET"
    fi
    printf "\n"
  done <<<"$raw"
  printf "%s============================================================================================================%s\n" "$C_CYAN" "$C_RESET"
}

print_node_list() {
  local nodes=${1:-$(current_nodes_json)}
  local node_cnt
  node_cnt=$(node_count "$nodes")
  if (( node_cnt == 0 )); then
    echo
    info "暂无任何节点配置。"
    return 0
  fi

  local table_data="" index=1 node port in_b out_b total_b limit day percent limit_b status_tag b_mode
  local name protocol domain day_str traffic_str limit_str
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    port=$(jq -r '.port' <<<"$node")
    in_b=$(traffic_counter_value "$port" in)
    out_b=$(traffic_counter_value "$port" out)
    b_mode=$(jq -r '.traffic.billing_mode // "single"' <<<"$node")
    if [[ "$b_mode" == "double" ]]; then
      total_b=$((in_b + out_b))
    else
      total_b=$out_b
    fi
    limit=$(jq -r '.traffic.monthly_limit // "unlimited"' <<<"$node")
    day=$(jq -r '.traffic.reset_day // empty' <<<"$node")
    day_str="无"
    [[ -n "$day" && "$day" != "null" ]] && day_str="${day}日"
    percent="-"
    status_tag=""
    if [[ "$limit" != "unlimited" && "$limit" != "0" ]]; then
      limit_b=$(size_to_bytes "$limit")
      if [[ "$limit_b" -gt 0 ]]; then
        percent=$((total_b * 100 / limit_b))
        if [[ $percent -ge 100 ]]; then
          status_tag="[已超额阻断]"
        fi
      fi
    fi
    name=$(jq -r '.name' <<<"$node")
    protocol=$(protocol_label "$(jq -r '.protocol' <<<"$node")")
    domain=$(jq -r '.domain // "127.0.0.1"' <<<"$node")
    traffic_str=$(bytes_to_human "$total_b")
    limit_str="${limit}(${percent}%)"

    table_data+="${index}|@@|${name}|@@|${protocol}|@@|${domain}:${port}|@@|${traffic_str}|@@|${limit_str}|@@|${day_str}|@@|${status_tag}"$'\n'
    index=$((index + 1))
  done < <(jq -c '.[]?' <<<"$nodes")

  echo
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, re, unicodedata

c_cyan = sys.argv[1]
c_red = sys.argv[2]
c_reset = sys.argv[3]
raw = sys.stdin.read()

def display_width(s):
    clean_s = re.sub(r"\x1b\[[0-9;]*m", "", s)
    w = 0
    for ch in clean_s:
        status = unicodedata.east_asian_width(ch)
        if status in ("F", "W", "A"):
            w += 2
        else:
            w += 1
    return w

def pad_str(s, target_w):
    w = display_width(s)
    if w >= target_w:
        return s + "  "
    return s + (" " * (target_w - w))

headers = ["序号", "节点名称", "协议类型", "域名/端口", "当前流量", "月配额/比例", "重置日"]
min_widths = [6, 14, 16, 24, 12, 16, 8]

rows = []
for line in raw.split("\n"):
    if not line:
        continue
    parts = line.split("|@@|")
    if len(parts) >= 7:
        rows.append(parts)

if not rows:
    sys.exit(0)

widths = list(min_widths)
for i in range(len(headers)):
    h_w = display_width(headers[i]) + 2
    r_max = max((display_width(r[i]) + 2 for r in rows), default=0)
    widths[i] = max(min_widths[i], h_w, r_max)

total_w = sum(widths)
title = " 节点列表 "
title_w = display_width(title)
side_len = max(2, (total_w - title_w) // 2)
top_bar = "=" * side_len + title + "=" * (total_w - title_w - side_len)
bot_bar = "=" * total_w
sep_line = "-" * total_w

print(c_cyan + top_bar + c_reset)
print("".join(pad_str(c, w) for c, w in zip(headers, widths)))
print(c_cyan + sep_line + c_reset)

for r in rows:
    cols = r[:7]
    tag = r[7] if len(r) > 7 and r[7] else ""
    out = "".join(pad_str(c, w) for c, w in zip(cols, widths))
    if tag:
        out += c_red + tag + c_reset
    print(out)

print(c_cyan + bot_bar + c_reset)
' "$C_CYAN" "$C_RED" "$C_RESET" <<<"$table_data"
  else
    render_node_table_fallback "$table_data"
  fi
}

select_node_index() {
  local nodes=$1 prompt=${2:-请选择节点序号} choice count
  count=$(node_count "$nodes")
  if (( count == 0 )); then
    warn "当前无任何节点。"
    return 1
  fi
  while true; do
    read -r -p "${prompt} [1-${count}，0/回车返回]: " choice
    [[ -n "$choice" ]] || return 1
    if [[ "$choice" == "0" ]]; then
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      local c_idx=$((10#$choice))
      if (( c_idx >= 1 && c_idx <= count )); then
        printf "%s" "$((c_idx - 1))"
        return 0
      fi
    fi
    warn "请输入有效序号 (1 到 ${count}，或输入 0 返回)。"
  done
}

install_flow() {
  preflight
  install_dependencies_and_core
  ensure_state_schema
  local old nodes node state_tmp candidate first_domain
  old='{}'
  if state_has_nodes; then
    old=$(jq -c '.nodes[0]' "$STATE_FILE")
  fi
  echo
  info "开始安装并初始化 sing-box 服务……"
  PROTOCOL="${PROTOCOL:-$(jq -r '.protocol // "anytls"' <<<"$old")}"
  choose_protocol PROTOCOL "$PROTOCOL" "首节点协议选择" || { warn "已取消首节点配置。"; return 0; }
  EMAIL=${EMAIL:-$(json_get "$STATE_FILE" '.email')}
  CERT_MODE=${CERT_MODE:-$(json_get "$STATE_FILE" '.cert_mode')}
  CERT_MODE=${CERT_MODE:-dnspod}
  WEBROOT=${WEBROOT:-$(json_get "$STATE_FILE" '.webroot')}
  DOMAIN="${DOMAIN:-$(jq -r '.domain // empty' <<<"$old")}"
  NODE_PORT="${NODE_PORT:-$(jq -r '.port // empty' <<<"$old")}"
  NODE_PASSWORD="${NODE_PASSWORD:-$(jq -r '.password // empty' <<<"$old")}"
  SKIP_PROTOCOL_PROMPT=1
  collect_node_json "$old" node || { warn "已取消首节点配置。"; return 0; }
  SKIP_PROTOCOL_PROMPT=0
  ensure_node_certificate "$node" || { warn "已取消证书申请。"; return 0; }
  if state_has_nodes; then
    nodes=$(current_nodes_json)
    nodes=$(jq -c --argjson node "$node" '.[0]=$node' <<<"$nodes")
  else
    nodes=$(jq -cn --argjson node "$node" '[$node]')
  fi
  first_domain=$(jq -r '.[0].domain' <<<"$nodes")
  state_tmp=$(mktemp)
  jq -n --arg domain "$first_domain" --arg email "$EMAIL" --arg cert_mode "$CERT_MODE" --arg webroot "$WEBROOT" --argjson nodes "$nodes" \
    '{version:3,domain:$domain,email:$email,cert_mode:$cert_mode,webroot:$webroot,nodes:$nodes}' >"$state_tmp"
  candidate=$(mktemp)
  generate_config_from_state "$candidate" "$state_tmp"
  apply_config "$candidate"
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  install -m 0600 "$state_tmp" "$STATE_FILE"
  rm -f "$candidate" "$state_tmp"
  install_deploy_hook
  sync_traffic_rules "$nodes"
  if [[ "" == "systemd" ]]; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  else
    local cert_cron_tmp
    cert_cron_tmp=$(mktemp)
    (crontab -l 2>/dev/null || true) | awk '$0 !~ /certbot renew/' > "$cert_cron_tmp" || true
    echo "0 3,15 * * * certbot renew --quiet --no-self-upgrade" >> "$cert_cron_tmp"
    crontab "$cert_cron_tmp" >/dev/null 2>&1 || true
    rm -f "$cert_cron_tmp"
  fi
  # 安装管理脚本到系统 PATH，支持全局 sbox 指令
  ensure_sbox_cli
  ok "服务安装完成！已启用首节点 [$(protocol_label "$PROTOCOL")]。"
  ok "快捷指令已就绪：今后在任意目录下输入 sbox 即可快捷打开管理面板。"
  show_client
  read -r -p "按回车键继续……" _
}

add_node_flow() {
  local nodes node new_port
  nodes=$(current_nodes_json)
  PROTOCOL=""
  SKIP_PROTOCOL_PROMPT=0
  PORT=""
  OUTBOUND=""
  NODE_DOMAIN=""
  NODE_PORT=""
  NODE_PASSWORD=""
  NODE_USERNAME=""
  HTTP_TLS="false"
  echo
  info "添加新节点……"
  if ! collect_node_json '{}' node; then
    warn "已放弃添加新节点，返回上级菜单。"
    return 0
  fi
  new_port=$(jq -r '.port' <<<"$node")
  if jq -e --argjson port "$new_port" 'any(.[]; .port == $port)' <<<"$nodes" >/dev/null 2>&1; then
    warn "端口 ${new_port} 已被现有节点使用，无法重复添加。"
    return 0
  fi
  if ! assert_port_available "$new_port"; then
    return 0
  fi
  if ! ensure_node_certificate "$node"; then
    warn "已放弃证书申请，取消添加节点。"
    return 0
  fi
  save_nodes_json "$(jq -c --argjson node "$node" '. + [$node]' <<<"$nodes")"
  ok "新节点添加成功！"
  show_client
  read -r -p "按回车键继续……" _
}

edit_node_flow() {
  local nodes index old node old_port new_port
  nodes=$(current_nodes_json)
  print_node_list "$nodes"
  index=$(select_node_index "$nodes" "请选择要修改的节点") || return 0
  old=$(jq -c ".[$index]" <<<"$nodes")
  old_port=$(jq -r '.port' <<<"$old")
  PROTOCOL=$(jq -r '.protocol // "anytls"' <<<"$old")
  SKIP_PROTOCOL_PROMPT=0
  PORT=""
  NODE_DOMAIN=""
  NODE_PORT=""
  NODE_PASSWORD=""
  NODE_USERNAME=$(jq -r '.username // empty' <<<"$old")
  HTTP_TLS=$(jq -r '.tls // false' <<<"$old")
  OUTBOUND=""
  SS_METHOD=""
  echo
  info "修改节点：$(jq -r '.name' <<<"$old")……"
  if ! collect_node_json "$old" node; then
    warn "已放弃修改节点，返回上级菜单。"
    return 0
  fi
  new_port=$(jq -r '.port' <<<"$node")
  if jq -e --argjson port "$new_port" --argjson index "$index" 'any(to_entries[]; .key != $index and .value.port == $port)' <<<"$nodes" >/dev/null 2>&1; then
    warn "端口 ${new_port} 已被其他节点占用。"
    return 0
  fi
  if [[ "$old_port" != "$new_port" ]]; then
    if ! assert_port_available "$new_port"; then
      return 0
    fi
    traffic_remove_port "$old_port"
  fi
  if ! ensure_node_certificate "$node"; then
    warn "已放弃证书申请，取消修改节点。"
    return 0
  fi
  save_nodes_json "$(jq -c --argjson index "$index" --argjson node "$node" '.[ $index ] = $node' <<<"$nodes")"
  ok "节点修改成功！"
  show_client
  read -r -p "按回车键继续……" _
}

delete_node_flow() {
  local nodes index port answer name count
  nodes=$(current_nodes_json)
  count=$(node_count "$nodes")
  if (( count == 0 )); then
    warn "当前暂无任何节点配置，无法删除。"
    return 0
  fi
  print_node_list "$nodes"
  index=$(select_node_index "$nodes" "请选择要删除的节点") || return 0
  port=$(jq -r ".[$index].port" <<<"$nodes")
  name=$(jq -r ".[$index].name" <<<"$nodes")
  if (( count == 1 )); then
    read -r -p "这是最后一个节点，删除后将清空全部节点（服务将保持空载运行）。确认删除 [${name}]？[y/N]: " answer
  else
    read -r -p "确认删除节点 [${name}] (端口: ${port})？[y/N]: " answer
  fi
  [[ "$answer" =~ ^[yY]$ ]] || { warn "已取消删除。"; return 0; }
  traffic_remove_port "$port"
  save_nodes_json "$(jq -c --argjson index "$index" 'del(.[$index])' <<<"$nodes")"
  ok "节点 [${name}] 已成功删除。"
  read -r -p "按回车键继续……" _
}

outbound_flow() {
  local nodes index old outbound new_nodes name
  nodes=$(current_nodes_json)
  if (( $(node_count "$nodes") == 0 )); then
    warn "当前暂无任何节点配置，请先选择 [1) 新增节点]。"
    return 0
  fi
  print_node_list "$nodes"
  index=$(select_node_index "$nodes" "请选择要单独修改出口的节点") || return 0
  old=$(jq -c ".[$index]" <<<"$nodes")
  name=$(jq -r '.name' <<<"$old")
  echo
  info "修改节点 [${name}] 的出口分流路由……"
  if ! collect_outbound_settings "$old" outbound; then
    warn "已放弃修改出口，返回上级菜单。"
    return 0
  fi
  new_nodes=$(jq -c --argjson index "$index" --argjson outbound "$outbound" '.[ $index ].outbound = $outbound' <<<"$nodes")
  save_nodes_json "$new_nodes"
  ok "节点 [${name}] 的出口配置已更新！"
  show_client
  read -r -p "按回车键继续……" _
}

show_client() {
  local nodes node index=1 name protocol domain port pass uuid pbk sid method sni
  nodes=$(current_nodes_json)
  if (( $(node_count "$nodes") == 0 )); then
    warn "当前暂无任何节点配置，请先添加节点。"
    return 0
  fi
  echo
  printf "%s=========================== 客户端连接信息 ===========================%s\n" "$C_CYAN" "$C_RESET"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    name=$(jq -r '.name' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    domain=$(jq -r '.domain' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    printf "\n%s[%d] 节点名称: %s%s\n" "$C_GREEN" "$index" "$name" "$C_RESET"
    printf "  协议类型: %s\n" "$(protocol_label "$protocol")"
    printf "  连接地址: %s:%s\n" "$domain" "$port"
    case "$protocol" in
      anytls)
        pass=$(jq -r '.password' <<<"$node")
        printf "  AnyTLS 密码: %s\n" "$pass"
        printf "  分享链接: anytls://%s@%s:%s?sni=%s#%s\n" "$pass" "$domain" "$port" "$domain" "$(printf "%s" "$name" | jq -sRr @uri)"
        ;;
      shadowsocks)
        method=$(jq -r '.method' <<<"$node")
        pass=$(jq -r '.password' <<<"$node")
        printf "  加密方式: %s\n" "$method"
        printf "  连接密码: %s\n" "$pass"
        local ss_b64
        ss_b64=$(printf "%s:%s" "$method" "$pass" | base64 | tr -d "\n")
        printf "  分享链接: ss://%s@%s:%s#%s\n" "$ss_b64" "$domain" "$port" "$(printf "%s" "$name" | jq -sRr @uri)"
        ;;
      vless-reality)
        uuid=$(jq -r '.uuid' <<<"$node")
        pbk=$(jq -r '.reality.public_key' <<<"$node")
        sid=$(jq -r '.reality.short_id' <<<"$node")
        sni=$(jq -r '.reality.handshake_server' <<<"$node")
        printf "  UUID: %s\n" "$uuid"
        printf "  Flow: xtls-rprx-vision\n"
        printf "  REALITY 公钥: %s\n" "$pbk"
        printf "  REALITY ShortId: %s\n" "$sid"
        printf "  伪装 SNI: %s\n" "$sni"
        printf "  分享链接: vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n" \
          "$uuid" "$domain" "$port" "$sni" "$pbk" "$sid" "$(printf "%s" "$name" | jq -sRr @uri)"
        ;;
      trojan)
        pass=$(jq -r '.password' <<<"$node")
        printf "  Trojan 密码: %s\n" "$pass"
        printf "  分享链接: trojan://%s@%s:%s?sni=%s#%s\n" "$pass" "$domain" "$port" "$domain" "$(printf "%s" "$name" | jq -sRr @uri)"
        ;;
      hysteria2)
        pass=$(jq -r '.password' <<<"$node")
        printf "  Hysteria2 认证: %s\n" "$pass"
        printf "  分享链接: hy2://%s@%s:%s?sni=%s&insecure=0#%s\n" "$pass" "$domain" "$port" "$domain" "$(printf "%s" "$name" | jq -sRr @uri)"
        ;;
      socks5)
        local s_user s_pass
        s_user=$(jq -r '.username // empty' <<<"$node")
        s_pass=$(jq -r '.password // empty' <<<"$node")
        if [[ -n "$s_user" ]]; then
          printf "  认证用户名: %s\n" "$s_user"
          printf "  认证密码:   %s\n" "$s_pass"
          local s_auth
          s_auth=$(printf "%s:%s" "$s_user" "$s_pass" | base64 | tr -d "\n")
          printf "  分享链接:   socks5://%s@%s:%s#%s\n" "$s_auth" "$domain" "$port" "$(printf "%s" "$name" | jq -sRr @uri)"
        else
          printf "  认证方式:   免密无认证\n"
          printf "  分享链接:   socks5://%s:%s#%s\n" "$domain" "$port" "$(printf "%s" "$name" | jq -sRr @uri)"
        fi
        ;;
      http)
        local h_user h_pass h_tls
        h_user=$(jq -r '.username // empty' <<<"$node")
        h_pass=$(jq -r '.password // empty' <<<"$node")
        h_tls=$(jq -r '.tls // false' <<<"$node")
        local scheme="http"
        [[ "$h_tls" == "true" ]] && scheme="https"
        printf "  代理协议:   %s\n" "${scheme^^} 代理"
        if [[ -n "$h_user" ]]; then
          printf "  认证用户名: %s\n" "$h_user"
          printf "  认证密码:   %s\n" "$h_pass"
          local h_auth
          h_auth=$(printf "%s:%s" "$h_user" "$h_pass" | base64 | tr -d "\n")
          printf "  分享链接:   %s://%s@%s:%s#%s\n" "$scheme" "$h_auth" "$domain" "$port" "$(printf "%s" "$name" | jq -sRr @uri)"
        else
          printf "  认证方式:   免密无认证\n"
          printf "  分享链接:   %s://%s:%s#%s\n" "$scheme" "$domain" "$port" "$(printf "%s" "$name" | jq -sRr @uri)"
        fi
        ;;
    esac
    index=$((index + 1))
  done < <(jq -c '.[]?' <<<"$nodes")
  echo
  info "sing-box 客户端参考 outbounds 配置："
  jq -c '.outbounds' "$CONFIG_FILE" 2>/dev/null || true
  printf "%s====================================================================%s\n" "$C_CYAN" "$C_RESET"
}

nodes_menu() {
  if ! service_is_installed; then
    warn "尚未安装 sing-box 核心服务。"
    local init_ans
    read -r -p "是否立即安装并初始化服务？[Y/n]: " init_ans
    init_ans=${init_ans:-Y}
    if [[ "$init_ans" =~ ^[yY]$ ]]; then
      install_flow
    else
      warn "已取消。请先在主菜单选择 [1. 安装服务]。"
    fi
    return 0
  fi

  local choice nodes
  while true; do
    nodes=$(current_nodes_json)
    print_node_list "$nodes"
    echo
    printf "%s=== 节点管理菜单 ===%s\n" "$C_CYAN" "$C_RESET"
    printf "  1) 新增节点\n"
    printf "  2) 修改节点信息\n"
    printf "  3) 单独修改节点出口\n"
    printf "  4) 修改节点流量配额与重置日\n"
    printf "  5) 删除节点\n"
    printf "  6) 查看客户端配置与分享链接\n"
    printf "  0) 返回主菜单\n"
    read -r -p "请输入选择 [0-6，默认: 0]: " choice
    choice=${choice:-0}
    case "$choice" in
      1) add_node_flow ;;
      2)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，请先选择 [1) 新增节点]。"
          read -r -p "按回车键继续……" _
        else
          edit_node_flow
        fi
        ;;
      3)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，请先选择 [1) 新增节点]。"
          read -r -p "按回车键继续……" _
        else
          outbound_flow
        fi
        ;;
      4)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，请先选择 [1) 新增节点]。"
          read -r -p "按回车键继续……" _
        else
          configure_traffic_flow "$nodes"
        fi
        ;;
      5)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，请先选择 [1) 新增节点]。"
          read -r -p "按回车键继续……" _
        else
          delete_node_flow
        fi
        ;;
      6)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，请先选择 [1) 新增节点]。"
          read -r -p "按回车键继续……" _
        else
          show_client
          read -r -p "按回车键继续……" _
        fi
        ;;
      0|"") return ;;
      *)
        warn "无效选择。"
        sleep 1
        ;;
    esac
  done
}

configure_traffic_flow() {
  local nodes=${1:-$(current_nodes_json)} index old traffic new_nodes name
  print_node_list "$nodes"
  index=$(select_node_index "$nodes" "请选择要设置流量的节点") || return 0
  old=$(jq -c ".[$index]" <<<"$nodes")
  name=$(jq -r '.name' <<<"$old")
  echo
  info "配置节点 [${name}] 的流量管理策略……"
  if ! collect_traffic_settings "$old" traffic; then
    warn "已放弃流量设置，返回上级菜单。"
    return 0
  fi
  new_nodes=$(jq -c --argjson index "$index" --argjson traffic "$traffic" '.[ $index ].traffic = $traffic' <<<"$nodes")
  save_nodes_json "$new_nodes"
  ok "节点 [${name}] 的流量管理策略已更新！"
  show_client
  read -r -p "按回车键继续……" _
}

immediate_traffic_reset_flow() {
  local nodes=${1:-$(current_nodes_json)} index port name
  print_node_list "$nodes"
  index=$(select_node_index "$nodes" "请选择要立即重置流量的节点") || return 0
  port=$(jq -r ".[$index].port" <<<"$nodes")
  name=$(jq -r ".[$index].name" <<<"$nodes")
  reset_traffic_port "$port" "$name" 0
  ok "节点 [${name}] 流量统计与配额已重置。"
}

init_api_config() {
  if [[ ! -r "$API_CONFIG_FILE" ]]; then
    install -d -m 0750 "$CONFIG_DIR"
    echo '{"enabled":false,"port":6666,"host":"0.0.0.0","token":""}' > "$API_CONFIG_FILE"
    chmod 0600 "$API_CONFIG_FILE"
  fi
}

get_api_port() {
  init_api_config
  jq -r '.port // 6666' "$API_CONFIG_FILE" 2>/dev/null || echo "6666"
}

get_api_host() {
  init_api_config
  jq -r '.host // "0.0.0.0"' "$API_CONFIG_FILE" 2>/dev/null || echo "0.0.0.0"
}

get_api_token() {
  init_api_config
  jq -r '.token // empty' "$API_CONFIG_FILE" 2>/dev/null || true
}

install_api_server_script() {
  install -d -m 0750 "$API_DIR"
  cat > "$API_SCRIPT_FILE" << 'PY_SERVER_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import http.server
import socketserver
import os
import subprocess
import urllib.parse
import json
import sys

SCRIPT_INSTALL_PATH = os.environ.get("SBOX_SCRIPT_PATH", "/usr/local/bin/sbox")
API_CONFIG_FILE = os.environ.get("SBOX_API_CONFIG", "/etc/sbox/api.json")

def load_api_config():
    try:
        if os.path.exists(API_CONFIG_FILE):
            with open(API_CONFIG_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass
    return {"port": 6666, "host": "0.0.0.0", "token": ""}

def get_traffic_from_script(port=None):
    script = SCRIPT_INSTALL_PATH if os.path.exists(SCRIPT_INSTALL_PATH) else "./sbox.sh"
    cmd = ["bash", script, "--api-json"]
    if port:
        cmd.append(str(port))
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        if res.returncode == 0 and res.stdout.strip():
            return json.loads(res.stdout.strip())
    except Exception as e:
        return {"error": "ExecutionError", "message": str(e)}
    return {"error": "FailedToRetrieveData", "message": "Script returned no data"}

class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, getattr(socket, "SO_REUSEPORT", 15), 1)
        except Exception:
            pass
        super().server_bind()

class APIHandler(http.server.BaseHTTPRequestHandler):
    def send_json(self, data, code=200):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def check_auth(self, query_params):
        config = load_api_config()
        token = config.get("token", "").strip()
        if not token:
            return True
        auth_header = self.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            if auth_header[7:].strip() == token:
                return True
        if query_params.get("token", [""])[0] == token:
            return True
        return False

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        query = urllib.parse.parse_qs(parsed.query)

        if not self.check_auth(query):
            self.send_json({"error": "Unauthorized", "message": "Missing or invalid Bearer token / ?token= query parameter"}, 401)
            return

        if path == "" or path == "/api":
            self.send_json({
                "service": "sbox-traffic-api",
                "version": "1.0",
                "endpoints": {
                    "all_traffic": "/api/traffic",
                    "port_traffic": "/api/traffic/{port}",
                    "status": "/api/status"
                }
            })
        elif path == "/api/status" or path == "/api/health":
            data = get_traffic_from_script()
            self.send_json({
                "status": "ok",
                "service": "sing-box",
                "service_status": data.get("status", "unknown"),
                "total_nodes": data.get("total_nodes", 0),
                "timestamp": data.get("timestamp", "")
            })
        elif path == "/api/traffic" or path == "/api/traffic/all":
            data = get_traffic_from_script()
            self.send_json(data)
        elif path.startswith("/api/traffic/"):
            parts = path.split("/")
            port_str = parts[-1]
            if not port_str.isdigit():
                self.send_json({"error": "InvalidPort", "message": "Port must be an integer"}, 400)
                return
            port = int(port_str)
            data = get_traffic_from_script(port)
            nodes = data.get("nodes", [])
            matched = [n for n in nodes if n.get("port") == port]
            if matched:
                node_obj = matched[0]
                node_obj["instance_id"] = data.get("instance_id")
                node_obj["timestamp"] = data.get("timestamp")
                self.send_json(node_obj)
            else:
                self.send_json({"error": "PortNotFound", "message": f"Port {port} is not being monitored or does not exist", "port": port}, 404)
        else:
            self.send_json({"error": "NotFound", "path": path}, 404)

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    cfg = load_api_config()
    port = int(os.environ.get("API_PORT", cfg.get("port", 6666)))
    host = os.environ.get("API_HOST", cfg.get("host", "0.0.0.0"))
    print(f"sbox Traffic API Server running on http://{host}:{port}")
    try:
        with ThreadingTCPServer((host, port), APIHandler) as httpd:
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nAPI Server stopped.")
PY_SERVER_EOF
  chmod +x "$API_SCRIPT_FILE"
}

ensure_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    require_root
    detect_os
    info "检测到系统未安装 Python3，正在自动安装依赖..."
    case "$PKG_MGR" in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends python3
        ;;
      dnf)
        dnf install -y python3
        ;;
      yum)
        yum install -y python3
        ;;
      apk)
        apk add --no-cache python3
        ;;
      *)
        die "未识别的包管理器，请手动安装 python3 后重试。"
        ;;
    esac
    if ! command -v python3 >/dev/null 2>&1; then
      die "Python3 自动安装失败，请手动安装 python3 后重试。"
    fi
    ok "Python3 依赖已成功安装。"
  fi
}

ensure_api_service_file() {
  local py_bin
  py_bin=$(command -v python3 || echo "/usr/bin/python3")
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    cat > "/etc/systemd/system/${API_SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=sbox Traffic API Server
After=network.target sing-box.service

[Service]
Type=simple
User=root
Environment=SBOX_SCRIPT_PATH=${SCRIPT_INSTALL_PATH}
ExecStart=${py_bin} ${API_SCRIPT_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    service_daemon_reload
  else
    local rc_file="/etc/init.d/sbox-api"
    cat > "$rc_file" <<EOF
#!/sbin/openrc-run
description="sbox Traffic API Server"
command="${py_bin}"
command_args="${API_SCRIPT_FILE}"
command_background="yes"
pidfile="/run/sbox-api.pid"
output_log="/var/log/sbox-api.log"
error_log="/var/log/sbox-api.log"
export SBOX_SCRIPT_PATH="${SCRIPT_INSTALL_PATH}"

depend() {
  need net
  after sing-box
}
EOF
    chmod 0755 "$rc_file"
  fi
}

install_api_service() {
  local port=${1:-$(get_api_port)} host=${2:-$(get_api_host)} token=${3:-$(get_api_token)}
  require_root
  service_disable "$API_SYSTEMD_SERVICE"
  rm -f "/etc/systemd/system/${API_SYSTEMD_SERVICE}" "/etc/init.d/sbox-api" >/dev/null 2>&1 || true
  ensure_python3
  install_api_server_script
  init_api_config
  local tmp
  tmp=$(mktemp)
  jq --argjson port "$port" --arg host "$host" --arg token "$token" \
    '.enabled=true | .port=$port | .host=$host | .token=$token' "$API_CONFIG_FILE" > "$tmp"
  install -m 0600 "$tmp" "$API_CONFIG_FILE"
  rm -f "$tmp"

  ensure_api_service_file
  service_enable "$API_SYSTEMD_SERVICE"
  service_start "$API_SYSTEMD_SERVICE"
  ok "API 服务已成功安装并启动！监听地址: http://${host}:${port}"
}

start_api_service() {
  require_root
  ensure_python3
  if ! service_is_installed "$API_SYSTEMD_SERVICE"; then
    install_api_service
    return
  fi
  service_start "$API_SYSTEMD_SERVICE"
  ok "API 服务已启动。"
}

stop_api_service() {
  require_root
  service_stop "$API_SYSTEMD_SERVICE"
  ok "API 服务已停止。"
}

restart_api_service() {
  require_root
  service_restart "$API_SYSTEMD_SERVICE"
  ok "API 服务已重启。"
}

uninstall_api_service() {
  require_root
  service_disable "$API_SYSTEMD_SERVICE"
  rm -f "/etc/systemd/system/${API_SYSTEMD_SERVICE}" "/etc/init.d/sbox-api" >/dev/null 2>&1 || true
  service_daemon_reload
  init_api_config
  local tmp
  tmp=$(mktemp)
  jq '.enabled=false' "$API_CONFIG_FILE" > "$tmp"
  install -m 0600 "$tmp" "$API_CONFIG_FILE"
  rm -f "$tmp"
  ok "API 服务已卸载。"
}

run_api_foreground() {
  ensure_python3
  install_api_server_script
  local port=${1:-$(get_api_port)} host=${2:-$(get_api_host)}
  local py_bin
  py_bin=$(command -v python3 || echo "python3")
  info "正在前台启动 API 服务测试 (按 Ctrl+C 停止)..."
  API_PORT="$port" API_HOST="$host" "$py_bin" "$API_SCRIPT_FILE"
}

get_traffic_json() {
  local port_filter="${1:-}"
  local nodes node port in_b out_b b_mode total_b limit day limit_b percent is_blocked
  local total_input=0 total_output=0 total_all=0 node_count=0
  local temp_file
  temp_file=$(mktemp)
  echo "[]" > "$temp_file"

  nodes=$(current_nodes_json)
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    port=$(jq -r '.port' <<<"$node")
    if [[ -n "$port_filter" && "$port" != "$port_filter" ]]; then
      continue
    fi

    in_b=$(traffic_counter_value "$port" in 2>/dev/null || echo 0)
    out_b=$(traffic_counter_value "$port" out 2>/dev/null || echo 0)
    in_b=${in_b:-0}
    out_b=${out_b:-0}
    b_mode=$(jq -r '.traffic.billing_mode // "single"' <<<"$node")
    if [[ "$b_mode" == "double" ]]; then
      total_b=$((in_b + out_b))
    else
      total_b=$out_b
    fi

    limit=$(jq -r '.traffic.monthly_limit // "unlimited"' <<<"$node")
    day=$(jq -r '.traffic.reset_day // empty' <<<"$node")
    limit_b=$(size_to_bytes "$limit")
    percent="-"
    is_blocked=false
    if [[ "$limit" != "unlimited" && "$limit" != "0" && "$limit_b" -gt 0 ]]; then
      percent=$((total_b * 100 / limit_b))
      if [[ $percent -ge 100 ]]; then
        is_blocked=true
      fi
    fi

    total_input=$((total_input + in_b))
    total_output=$((total_output + out_b))
    total_all=$((total_all + total_b))
    node_count=$((node_count + 1))

    jq --arg name "$(jq -r '.name' <<<"$node")" \
       --arg protocol "$(jq -r '.protocol' <<<"$node")" \
       --arg domain "$(jq -r '.domain' <<<"$node")" \
       --argjson port "$port" \
       --argjson input_bytes "$in_b" \
       --argjson output_bytes "$out_b" \
       --argjson total_bytes "$total_b" \
       --arg input_formatted "$(bytes_to_human "$in_b")" \
       --arg output_formatted "$(bytes_to_human "$out_b")" \
       --arg total_formatted "$(bytes_to_human "$total_b")" \
       --arg billing_mode "$b_mode" \
       --arg monthly_limit "$limit" \
       --argjson monthly_limit_bytes "$limit_b" \
       --arg reset_day "${day:-null}" \
       --arg percent "$percent" \
       --argjson is_blocked "$is_blocked" \
       '. += [{
         name: $name,
         protocol: $protocol,
         domain: $domain,
         port: $port,
         input_bytes: $input_bytes,
         output_bytes: $output_bytes,
         total_bytes: $total_bytes,
         input_formatted: $input_formatted,
         output_formatted: $output_formatted,
         total_formatted: $total_formatted,
         billing_mode: $billing_mode,
         quota: {
           enabled: ($monthly_limit != "unlimited" and $monthly_limit != "0"),
           monthly_limit: $monthly_limit,
           monthly_limit_bytes: $monthly_limit_bytes,
           reset_day: (if $reset_day == "null" or $reset_day == "" then null else ($reset_day|tonumber) end),
           used_percent: (if $percent == "-" then null else ($percent|tonumber) end)
         },
         is_blocked: $is_blocked
       }]' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
  done < <(jq -c '.[]?' <<<"$nodes")

  local inst_id
  inst_id=$(cat /etc/machine-id 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "sbox-instance")
  local now_iso
  now_iso=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)

  jq --arg instance_id "$inst_id" \
     --arg timestamp "$now_iso" \
     --arg service_status "$(if service_is_running; then echo "active"; else echo "stopped"; fi)" \
     --argjson total_nodes "$node_count" \
     --argjson total_input "$total_input" \
     --argjson total_output "$total_output" \
     --argjson total_all "$total_all" \
     --arg input_formatted "$(bytes_to_human "$total_input")" \
     --arg output_formatted "$(bytes_to_human "$total_output")" \
     --arg total_formatted "$(bytes_to_human "$total_all")" \
     '{
       instance_id: $instance_id,
       timestamp: $timestamp,
       service: "sing-box",
       status: $service_status,
       total_nodes: $total_nodes,
       nodes: .,
       total_traffic: {
         input_bytes: $total_input,
         output_bytes: $total_output,
         total_bytes: $total_all,
         input_formatted: $input_formatted,
         output_formatted: $output_formatted,
         total_formatted: $total_formatted
       }
     }' "$temp_file"

  rm -f "$temp_file"
}

api_service_menu() {
  local choice port token host status_text
  while true; do
    port=$(get_api_port)
    host=$(get_api_host)
    token=$(get_api_token)
    if service_is_running "$API_SYSTEMD_SERVICE"; then
      status_text="${C_GREEN}运行中 (Active)${C_RESET}"
    elif [[ -f "/etc/systemd/system/${API_SYSTEMD_SERVICE}" || -f "/etc/init.d/sbox-api" ]]; then
      status_text="${C_YELLOW}已停止 (Inactive)${C_RESET}"
    else
      status_text="${C_YELLOW}未启用 / 未安装${C_RESET}"
    fi

    echo
    printf "%s=== sbox 流量 API 接口服务 ===%s\n" "$C_CYAN" "$C_RESET"
    printf "  服务状态: %s\n" "$status_text"
    printf "  监听地址: %s:%s\n" "$host" "$port"
    if [[ -n "$token" ]]; then
      printf "  安全认证: Token 已启用 (%s)\n" "$token"
    else
      printf "  安全认证: %s无 (完全公开访问)%s\n" "$C_GREEN" "$C_RESET"
    fi
    printf "  接口地址:\n"
    printf "    - 全部节点流量: http://服务器IP:%s/api/traffic\n" "$port"
    printf "    - 单端口流量:   http://服务器IP:%s/api/traffic/{端口}\n" "$port"
    printf "    - 健康状态:     http://服务器IP:%s/api/status\n" "$port"
    printf "%s----------------------------------------%s\n" "$C_CYAN" "$C_RESET"
    printf "  1) 开启 API 服务 (后台自启)\n"
    printf "  2) 停止 API 服务\n"
    printf "  3) 重启 API 服务\n"
    printf "  4) 修改监听端口 (当前: %s)\n" "$port"
    printf "  5) 设置/清除安全 Token\n"
    printf "  6) 临时前台测试运行 (Ctrl+C 退出)\n"
    printf "  7) 卸载并禁用 API 服务\n"
    printf "  0) 返回流量菜单\n"
    read -r -p "请输入选择 [0-7，默认: 0]: " choice
    choice=${choice:-0}
    case "$choice" in
      1) install_api_service "$port" "$host" "$token" ;;
      2) stop_api_service ;;
      3) restart_api_service ;;
      4)
        local new_port
        read -r -p "请输入新的 API 监听端口 [1-65535] [默认: ${port}]: " new_port
        new_port=${new_port:-$port}
        validate_port "$new_port" || { warn "端口无效"; continue; }
        install_api_service "$new_port" "$host" "$token"
        ;;
      5)
        local new_token
        read -r -p "请输入安全 Token (留空表示关闭 Token 鉴权，直接公开访问): " new_token
        install_api_service "$port" "$host" "$new_token"
        ;;
      6) run_api_foreground "$port" "$host" ;;
      7) uninstall_api_service ;;
      0|"") return ;;
      *) warn "无效选项。" ;;
    esac
  done
}

view_traffic_logs() {
  echo
  printf "%s=== 流量重置历史记录 ===%s\n" "$C_CYAN" "$C_RESET"
  if [[ -s "$TRAFFIC_LOG" ]]; then
    tail -n 30 "$TRAFFIC_LOG"
  else
    printf "暂无流量重置历史记录。\n"
  fi
  echo
  read -r -p "按回车键返回……" _
}

traffic_menu() {
  local choice nodes
  while true; do
    nodes=$(current_nodes_json)
    print_node_list "$nodes"
    echo
    printf "%s=== 流量管理与监控 ===%s\n" "$C_CYAN" "$C_RESET"
    printf "  1) 查看实时流量与配额状态\n"
    printf "  2) 修改节点流量配额与重置日\n"
    printf "  3) 立即重置指定节点流量\n"
    printf "  4) 立即重置所有节点流量\n"
    printf "  5) 查看流量重置历史记录\n"
    printf "  6) API 接口服务管理 (开放对外流量监控)\n"
    printf "  0) 返回主菜单\n"
    read -r -p "请输入选择 [0-6，默认: 0]: " choice
    choice=${choice:-0}
    case "$choice" in
      1) print_node_list "$nodes"; read -r -p "按回车键继续……" _ ;;
      2)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，请先在节点管理中添加节点。"
        else
          configure_traffic_flow "$nodes"
        fi
        ;;
      3)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，无法重置。"
        else
          immediate_traffic_reset_flow "$nodes"
        fi
        ;;
      4)
        if (( $(node_count "$nodes") == 0 )); then
          warn "当前暂无任何节点配置，无法重置。"
        else
          reset_traffic_all
        fi
        ;;
      5) view_traffic_logs ;;
      6) api_service_menu ;;
      0|"") return ;;
      *) warn "无效选择。" ;;
    esac
  done
}

cert_flow() {
  ensure_certbot_environment
  if ! command -v certbot >/dev/null 2>&1; then
    warn "Certbot 尚未安装，当前无证书管理需求。"
    return 0
  fi
  info "检查并执行 Let's Encrypt 证书续签……"
  if (( DRY_RUN )); then
    certbot renew --dry-run
    ok "证书演练检查完成。"
  else
    certbot renew
    sync_certificate
    if [[ -s "$CONFIG_FILE" ]] && command -v sing-box >/dev/null 2>&1; then
      sing-box check -c "$CONFIG_FILE" && service_reload_or_restart "$SYSTEMD_SERVICE" || true
    fi
    ok "证书续签及同步完成。"
  fi
}


require_managed_install() {
  if ! service_is_installed; then
    warn "尚未安装 sing-box 核心服务，请先在主菜单选择 [1. 安装服务]。"
    return 1
  fi
  return 0
}

start_service() {
  if ! service_is_installed; then
    warn "sing-box 服务尚未安装，请先选择 [1. 安装服务]。"
    return 0
  fi
  if [[ ! -s "$CONFIG_FILE" ]] && ! state_has_nodes; then
    warn "当前尚未配置任何节点，无法启动节点代理服务。请先进入 [3. 节点管理] 新增节点。"
    return 0
  fi
  ensure_service_file
  info "启动 ${SYSTEMD_SERVICE}……"
  service_start "$SYSTEMD_SERVICE"
  sleep 1
  if service_is_running; then
    ok "sing-box 服务已成功启动并正在运行。"
  else
    warn "sing-box 服务启动后未能保持运行，日志摘要："
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$SYSTEMD_SERVICE" --no-pager -n 25 || true
    else
      tail -n 25 /var/log/sing-box.log 2>/dev/null || true
    fi
    warn "sing-box 启动失败，请根据上方日志排查。"
  fi
}

stop_service() {
  info "停止 ${SYSTEMD_SERVICE}……"
  service_stop "$SYSTEMD_SERVICE"
  ok "sing-box 服务已停止。"
}

restart_service() {
  if ! service_is_installed; then
    warn "sing-box 服务尚未安装，请先选择 [1. 安装服务]。"
    return 0
  fi
  if [[ ! -s "$CONFIG_FILE" ]] && ! state_has_nodes; then
    warn "当前尚未配置任何节点，无法重启节点代理服务。请先进入 [3. 节点管理] 新增节点。"
    return 0
  fi
  ensure_service_file
  if [[ -s "$CONFIG_FILE" ]] && command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "$CONFIG_FILE" || { warn "配置校验失败，已放弃重启。"; return 0; }
  fi
  info "重启 ${SYSTEMD_SERVICE}……"
  service_restart "$SYSTEMD_SERVICE"
  sleep 1
  if service_is_running; then
    ok "sing-box 服务已成功重启并正在运行。"
  else
    warn "sing-box 服务重启后未能保持运行，日志摘要："
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$SYSTEMD_SERVICE" --no-pager -n 25 || true
    else
      tail -n 25 /var/log/sing-box.log 2>/dev/null || true
    fi
    warn "sing-box 重启失败，请根据上方日志排查。"
  fi
}

enable_service() {
  info "开启 ${SYSTEMD_SERVICE} 开机自启……"
  service_enable "$SYSTEMD_SERVICE"
  ok "已开启 sing-box 开机自启。"
}

disable_service() {
  info "禁用 ${SYSTEMD_SERVICE} 开机自启……"
  service_disable "$SYSTEMD_SERVICE"
  ok "已禁用 sing-box 开机自启。"
}

bbr_status() {
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  if [[ "$cc" == *"bbr"* ]]; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

bbr_menu() {
  echo
  printf "%s=== BBR 加速控制 ===%s\n" "$C_CYAN" "$C_RESET"
  local current_status
  current_status=$(bbr_status)
  if [[ "$current_status" == "enabled" ]]; then
    printf "当前状态: %s已开启 (bbr)%s\n\n" "$C_GREEN" "$C_RESET"
    printf "  1) 重新应用 BBR 系统参数\n"
    printf "  2) 关闭 BBR 加速 (恢复 cubic)\n"
    printf "  0) 返回上级菜单\n"
    local choice
    read -r -p "请选择操作 [0-2]: " choice
    case "$choice" in
      1)
        install -d -m 0755 /etc/sysctl.d
        cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
        ok "BBR 参数已刷新。"
        ;;
      2)
        rm -f /etc/sysctl.d/99-bbr.conf
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
        ok "已关闭 BBR。"
        ;;
      0|"") return ;;
      *) warn "无效选择。" ;;
    esac
  else
    printf "当前状态: %s未开启%s\n\n" "$C_YELLOW" "$C_RESET"
    printf "  1) 开启 BBR 加速 (fq + bbr)\n"
    printf "  0) 返回上级菜单\n"
    local choice
    read -r -p "请选择操作 [0-1]: " choice
    case "$choice" in
      1)
        modprobe tcp_bbr 2>/dev/null || true
        install -d -m 0755 /etc/sysctl.d
        cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
        if [[ "$(bbr_status)" == "enabled" ]]; then
          ok "BBR 加速开启成功！"
        else
          warn "已写入 BBR 配置，若未立即生效，可能需重启内核生效。"
        fi
        ;;
      0|"") return ;;
      *) warn "无效选择。" ;;
    esac
  fi
}

status_flow() {
  echo
  printf "%s=========================== 系统与服务状态 ===========================%s\n" "$C_CYAN" "$C_RESET"
  local core_ver
  if command -v sing-box >/dev/null 2>&1; then
    core_ver=$(sing-box version 2>/dev/null | head -n1 || echo "未知")
  else
    core_ver="未安装"
  fi
  printf "sing-box 核心版本: %s\n" "$core_ver"
  local active_str enabled_str
  if service_is_running "$SYSTEMD_SERVICE"; then
    active_str="running / 运行中"
  else
    active_str="inactive / 未运行"
  fi
  if service_is_enabled "$SYSTEMD_SERVICE"; then
    enabled_str="enabled / 已开启"
  else
    enabled_str="disabled / 未开启"
  fi
  printf "服务运行状态:      %s\n" "$active_str"
  printf "开机自启状态:      %s\n" "$enabled_str"
  printf "日志记录级别:      %s\n" "$(get_log_level)"
  printf "BBR 拥塞控制:      %s (%s)\n" "$(bbr_status)" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")"
  local nodes
  nodes=$(current_nodes_json)
  print_node_list "$nodes"
}

get_log_level() {
  if [[ -r "$STATE_FILE" ]]; then
    jq -r ' .log_level // "warn" ' "$STATE_FILE" 2>/dev/null || echo "warn"
  else
    echo "warn"
  fi
}

set_log_level() {
  local new_level=$1
  if ! service_is_installed; then
    warn "sing-box 服务尚未安装，请先选择 [1. 安装服务]。"
    return 0
  fi
  if [[ ! -s "$CONFIG_FILE" ]] && ! state_has_nodes; then
    warn "当前尚未配置任何节点。"
    return 0
  fi
  local base_json='{"version":3,"nodes":[]}'
  if [[ -s "$STATE_FILE" ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    base_json=$(cat "$STATE_FILE")
  fi
  local state_tmp candidate
  state_tmp=$(mktemp)
  candidate=$(mktemp)

  jq --arg lvl "$new_level" '.log_level = $lvl' <<<"$base_json" >"$state_tmp"
  generate_config_from_state "$candidate" "$state_tmp"
  apply_config "$candidate"
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  install -m 0600 "$state_tmp" "$STATE_FILE"
  rm -f "$candidate" "$state_tmp"
  ok "日志级别已成功切换为 [${new_level}] 并重新加载生效。"
}

change_log_level_flow() {
  local cur_lvl
  cur_lvl=$(get_log_level)
  echo
  printf "%s=== 设置 sing-box 日志记录级别 ===%s\n" "$C_CYAN" "$C_RESET"
  printf "  当前日志级别: %s%s%s\n\n" "$C_GREEN" "$cur_lvl" "$C_RESET"
  printf "  1) warn  - 仅告警与错误 (默认推荐，日常静默无连接记录，省空间保隐私)\n"
  printf "  2) info  - 详细连接信息 (记录每笔网络请求与路由转发，日志量大)\n"
  printf "  3) error - 仅严重错误 (极简)\n"
  printf "  4) debug - 完整调试信息 (最详细，仅建议排查故障时临时开启)\n"
  printf "  0) 返回上级\n"
  local lvl_choice
  read -r -p "请输入选择 [0-4，默认: 1]: " lvl_choice
  lvl_choice=${lvl_choice:-1}
  case "$lvl_choice" in
    1) set_log_level "warn" ;;
    2) set_log_level "info" ;;
    3) set_log_level "error" ;;
    4) set_log_level "debug" ;;
    0|"") return 0 ;;
    *) warn "无效选项。"; sleep 1; return 0 ;;
  esac
}

clean_system_logs() {
  echo
  if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
    info "正在清理 systemd 历史日志（限制并保留最近 50MB / 3 天）……"
    local before_disk after_disk
    before_disk=$(journalctl --disk-usage 2>/dev/null || echo "")
    journalctl --vacuum-size=50M --vacuum-time=3d >/dev/null 2>&1 || true
    after_disk=$(journalctl --disk-usage 2>/dev/null || echo "")
    ok "历史日志清理完成！"
    [[ -n "$before_disk" ]] && printf "  清理前占用: %s\n" "$before_disk"
    [[ -n "$after_disk" ]] && printf "  清理后占用: %s\n" "$after_disk"
  elif [[ -f /var/log/sing-box.log ]]; then
    info "正在清理 OpenRC 服务日志 (/var/log/sing-box.log)……"
    local before_sz
    before_sz=$(du -h /var/log/sing-box.log 2>/dev/null | awk '{print $1}' || echo "")
    : > /var/log/sing-box.log
    ok "服务日志文件已清空！清理前大小: ${before_sz:-0K}"
  else
    info "未检测到日志文件或无需清理。"
  fi
}

logs_flow() {
  echo
  printf "%s=== sing-box 最近运行日志 ===%s\n" "$C_CYAN" "$C_RESET"
  if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$SYSTEMD_SERVICE" --no-pager -n 50 || true
  else
    tail -n 50 /var/log/sing-box.log 2>/dev/null || warn "暂无日志文件 (/var/log/sing-box.log)。"
  fi
  echo
  read -r -p "是否持续追踪日志？[y/N]: " choice
  if [[ "$choice" =~ ^[yY]$ ]]; then
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$SYSTEMD_SERVICE" -f
    else
      tail -f /var/log/sing-box.log 2>/dev/null || true
    fi
  fi
}

logs_menu() {
  local choice cur_lvl
  while true; do
    cur_lvl=$(get_log_level)
    echo
    printf "%s=== sing-box 日志管理 ===%s\n" "$C_CYAN" "$C_RESET"
    printf "  当前日志级别: %s%s%s\n" "$C_GREEN" "$cur_lvl" "$C_RESET"
    printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
    printf "  1) 查看最近 50 行运行日志\n"
    printf "  2) 持续追踪实时日志 (Ctrl+C 退出)\n"
    printf "  3) 调整日志级别 (当前: %s)\n" "$cur_lvl"
    printf "  4) 清理系统日志 (释放磁盘空间)\n"
    printf "  0) 返回主菜单\n"
    read -r -p "请输入选择 [0-4，默认: 1]: " choice
    choice=${choice:-1}
    case "$choice" in
      1)
        echo
        printf "%s=== sing-box 最近 50 行运行日志 ===%s\n" "$C_CYAN" "$C_RESET"
        if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
          journalctl -u "$SYSTEMD_SERVICE" --no-pager -n 50 || true
        else
          tail -n 50 /var/log/sing-box.log 2>/dev/null || warn "暂无日志文件 (/var/log/sing-box.log)。"
        fi
        echo
        read -r -p "按回车键继续……" _
        ;;
      2)
        echo
        info "正在持续追踪日志，按 Ctrl+C 退出追踪……"
        if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
          journalctl -u "$SYSTEMD_SERVICE" -f || true
        else
          tail -f /var/log/sing-box.log 2>/dev/null || true
        fi
        ;;
      3)
        change_log_level_flow
        read -r -p "按回车键继续……" _
        ;;
      4)
        clean_system_logs
        read -r -p "按回车键继续……" _
        ;;
      0|"") return ;;
      *)
        warn "无效选项。"
        sleep 1
        ;;
    esac
  done
}

confirm_uninstall() {
  local answer
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || die "非交互卸载必须显式传入 --yes。"
  echo
  warn "完全卸载将删除 sing-box 核心、所有节点配置文件、证书与流量监控规则！"
  read -r -p "确认完全卸载？[y/N]: " answer
  [[ "$answer" =~ ^[yY]$ ]] || die "已取消卸载。"
}

remove_managed_repository() {
  rm -f /etc/apt/sources.list.d/sing-box.sources
  rm -f /etc/apt/keyrings/sing-box.asc
}

disable_certbot_timer_if_unused() {
  local -a renewal_files=()
  shopt -s nullglob
  renewal_files=(/etc/letsencrypt/renewal/*.conf)
  shopt -u nullglob
  if ((${#renewal_files[@]} == 0)); then
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
      systemctl disable --now certbot.timer >/dev/null 2>&1 || true
    else
      local cert_cron_tmp
      cert_cron_tmp=$(mktemp)
      (crontab -l 2>/dev/null || true) | awk '$0 !~ /certbot renew/' > "$cert_cron_tmp" || true
      crontab "$cert_cron_tmp" >/dev/null 2>&1 || true
      rm -f "$cert_cron_tmp"
    fi
    info "无其他证书依赖，已停用证书自动续签任务。"
  fi
}

uninstall_flow() {
  preflight
  local domain="" domains="" traffic_cron_tmp
  if command -v jq >/dev/null 2>&1 && [[ -r "$STATE_FILE" ]]; then
    domains=$(jq -r '.nodes[]?.domain // empty' "$STATE_FILE" 2>/dev/null | sort -u || true)
  fi
  confirm_uninstall
  info "正在卸载 sing-box 服务……"
  service_disable "$SYSTEMD_SERVICE"
  service_disable "$API_SYSTEMD_SERVICE"
  rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}" "/etc/init.d/sing-box" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${API_SYSTEMD_SERVICE}" "/etc/init.d/sbox-api" >/dev/null 2>&1 || true
  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W sing-box >/dev/null 2>&1; then
    apt-get purge -y sing-box 2>/dev/null || true
  fi
  rm -f /usr/local/bin/sing-box /usr/bin/sing-box /var/log/sing-box.log /var/log/sbox-api.log >/dev/null 2>&1 || true
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    if certbot certificates 2>/dev/null | grep -q "Certificate Name: ${domain}$"; then
      info "清理证书 ${domain}……"
      certbot delete --cert-name "$domain" --non-interactive || true
    fi
  done <<<"$domains"
  nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  traffic_cron_tmp=$(mktemp)
  (crontab -l 2>/dev/null || true) | awk -v tag="${CRON_TAG}" 'index($0, tag) == 0' >"$traffic_cron_tmp" || true
  crontab "$traffic_cron_tmp" >/dev/null 2>&1 || true
  rm -f "$traffic_cron_tmp"
  rm -rf "$CONFIG_DIR" "$STATE_DIR" /var/lib/sing-box /run/sing-box
  rm -f "$SCRIPT_INSTALL_PATH" "$SCRIPT_SYMLINK_PATH" >/dev/null 2>&1 || true
  disable_certbot_timer_if_unused
  service_daemon_reload
  ok "sing-box 服务与配置已完全卸载。"
  exit 0
}

update_self_script() {
  local mode="${1:-cli}"
  require_root
  echo
  info "正在检查 sbox 脚本更新..."
  local tmp_file ts
  ts=$(date +%s)
  tmp_file=$(mktemp "/tmp/sbox_update_XXXXXX.sh" 2>/dev/null || echo "/tmp/sbox_update_$$.sh")

  # 发送 purge 请求以清理 jsdelivr 边缘缓存
  curl -fsSL -m 3 "https://purge.jsdelivr.net/gh/elunez/sbox@main/sbox.sh" >/dev/null 2>&1 || true

  local raw_urls=(
    "https://raw.githubusercontent.com/elunez/sbox/main/sbox.sh?v=${ts}"
    "https://raw.gitmirror.com/elunez/sbox/main/sbox.sh?v=${ts}"
    "https://ghproxy.net/https://raw.githubusercontent.com/elunez/sbox/main/sbox.sh?v=${ts}"
    "https://fastly.jsdelivr.net/gh/elunez/sbox@main/sbox.sh?v=${ts}"
    "https://cdn.jsdelivr.net/gh/elunez/sbox@main/sbox.sh?v=${ts}"
  )
  local downloaded=0
  for u in "${raw_urls[@]}"; do
    if curl -fsSL -H "Cache-Control: no-cache, no-store, must-revalidate" -H "Pragma: no-cache" --connect-timeout 8 -m 25 "$u" -o "$tmp_file" 2>/dev/null && [[ -s "$tmp_file" ]]; then
      if bash -n "$tmp_file" 2>/dev/null; then
        downloaded=1
        break
      fi
    fi
    rm -f "$tmp_file"
  done

  if [[ $downloaded -ne 1 || ! -s "$tmp_file" ]]; then
    rm -f "$tmp_file"
    warn "检查更新失败：无法从远程服务器下载有效脚本，请检查网络连接。"
    return 1
  fi

  local remote_version
  remote_version=$(grep -m 1 "^readonly SCRIPT_VERSION=" "$tmp_file" | cut -d'"' -f2 || true)
  if [[ -z "$remote_version" ]]; then
    rm -f "$tmp_file"
    warn "检查更新失败：无法解析远程脚本版本号。"
    return 1
  fi

  if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
    ok "当前脚本已是最新版本 (v${SCRIPT_VERSION})。"
    local need_force=0
    if (( FORCE_UPDATE || ASSUME_YES )); then
      need_force=1
    elif [[ -t 0 ]]; then
      local force_update
      read -r -p "是否重新强制拉取并安装当前版本？[y/N]: " force_update
      [[ "$force_update" =~ ^[yY]$ ]] && need_force=1
    fi

    if (( ! need_force )); then
      rm -f "$tmp_file"
      return 0
    fi
    info "正在重新覆盖安装 v${remote_version}..."
  else
    info "发现新版本：v${SCRIPT_VERSION} -> v${remote_version}，正在更新..."
  fi

  install -d -m 0755 /usr/local/bin /usr/bin
  install -m 0755 "$tmp_file" "$SCRIPT_INSTALL_PATH"
  ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_SYMLINK_PATH" 2>/dev/null || true

  local real_self
  real_self=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
  if [[ -n "$real_self" && "$real_self" != "$SCRIPT_INSTALL_PATH" && -w "$real_self" ]]; then
    cp -f "$tmp_file" "$real_self"
    chmod 0755 "$real_self"
  fi

  rm -f "$tmp_file"
  ok "sbox 脚本已成功更新至 v${remote_version}！"
  if [[ "$mode" == "silent" || "$mode" == "quiet" ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    echo
    info "正在自动打开 sbox 管理面板..."
    sleep 1
    if [[ -x "$SCRIPT_INSTALL_PATH" ]]; then
      exec "$SCRIPT_INSTALL_PATH"
    else
      exec "$0"
    fi
  else
    ok "sbox 命令行工具已更新完成。"
    return 0
  fi
}

print_main_menu() {
  local running_str node_cnt
  if service_is_running; then
    running_str="${C_GREEN}运行中${C_RESET}"
  elif service_is_installed; then
    running_str="${C_RED}已停止${C_RESET}"
  else
    running_str="${C_YELLOW}未安装${C_RESET}"
  fi

  local nodes
  nodes=$(current_nodes_json 2>/dev/null || echo "[]")
  node_cnt=$(node_count "$nodes")

  local api_state_str
  if service_is_running "$API_SYSTEMD_SERVICE"; then
    local api_port
    api_port=$(json_get "$API_CONFIG_FILE" '.port' 2>/dev/null || echo "9090")
    api_state_str="${C_GREEN}运行中 (端口: ${api_port})${C_RESET}"
  else
    api_state_str="${C_YELLOW}已停止${C_RESET}"
  fi

  echo
  printf "%s  Sbox · Sing-box 节点管理面板%s\n" "$C_GREEN" "$C_RESET"
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  printf " %2d. 退出脚本\n" 0
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  printf " %2d. 安装服务\n" 1
  printf " %2d. 更新服务\n" 2
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  printf " %2d. 节点管理\n" 3
  printf " %2d. 流量管理\n" 4
  printf " %2d. API 管理\n" 5
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  printf " %2d. 启动服务\n" 6
  printf " %2d. 停止服务\n" 7
  printf " %2d. 重启服务\n" 8
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  printf " %2d. 查看状态\n" 9
  printf " %2d. 日志管理\n" 10
  printf " %2d. 续签证书\n" 11
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  printf " %2d. 更新脚本\n" 12
  printf " %2d. 完全卸载\n" 13
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
  printf "活跃节点: %s\n" "$node_cnt"
  printf "服务状态: %s\n" "$running_str"
  printf "流量 API 服务: %s\n" "$api_state_str"
  printf "%s------------------------------------%s\n" "$C_CYAN" "$C_RESET"
}

menu() {
  preflight
  local choice
  while true; do
    print_main_menu
    read -r -p "请输入选择 [0-13，默认: 0]: " choice
    choice=${choice:-0}
    case "$choice" in
      0|q|Q|exit) echo; exit 0 ;;
      1) install_flow ;;
      2) upgrade_sing_box; read -r -p "按回车键继续……" _ ;;
      3) nodes_menu ;;
      4) traffic_menu ;;
      5) api_service_menu ;;
      6) start_service; read -r -p "按回车键继续……" _ ;;
      7) stop_service; read -r -p "按回车键继续……" _ ;;
      8) restart_service; read -r -p "按回车键继续……" _ ;;
      9) status_flow; read -r -p "按回车键继续……" _ ;;
      10) logs_menu ;;
      11) cert_flow; read -r -p "按回车键继续……" _ ;;
      12) update_self_script "menu"; read -r -p "按回车键继续……" _ ;;
      13) uninstall_flow ;;
      *) warn "无效选项，请输入 0 到 13 之间的数字。"; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
用法：
  sbox                              # 交互式管理菜单（任意目录下直接运行）
  sudo sbox install [选项]          # 首次安装服务与首节点
  sudo sbox update [--force]        # 检查并更新 sbox 管理脚本 (别名: update-script)
  sudo sbox upgrade                 # 升级 sing-box 核心
  sudo sbox nodes                   # 节点管理子菜单
  sudo sbox traffic                 # 流量管理子菜单
  sudo sbox cert [--dry-run]        # 续签 SSL 证书
  sudo sbox status                  # 查看运行状态与流量
  sudo sbox logs                    # 查看运行日志与管理
  sudo sbox start                   # 启动服务
  sudo sbox stop                    # 停止服务
  sudo sbox restart                 # 重启服务
  sudo sbox show                    # 查看客户端配置与分享链接
  sudo sbox uninstall [--yes]       # 完全卸载服务
  sudo sbox --reset-traffic [PORT]  # 重置指定端口流量统计
  sudo sbox --reset-traffic-all     # 重置所有端口流量统计
  sudo sbox api                     # API 接口服务管理子菜单
  sudo sbox api start|stop|restart  # 控制 API 后台服务
  sudo sbox --api-json [PORT]       # 命令行直接输出流量 JSON
  sudo sbox --version               # 显示脚本版本

常用参数：
  --protocol PROTOCOL     协议类型 (anytls / shadowsocks / trojan / hysteria2 / vless-reality / socks5 / http)
  --domain DOMAIN         节点域名或 IP
  --port PORT             监听端口
  --password PASS         密码或预共享密钥
  --cert-mode MODE        证书申请模式 (dnspod / cf / webroot / standalone)
  --email EMAIL           ACME 证书邮箱
  --webroot PATH          Web 根目录
  --outbound TYPE         出口模式 (direct / socks5 / http / shadowsocks / anytls / vless-reality / trojan / hysteria2)
  --dnspod-token TOKEN    DNSPod Token (格式: ID,Token)
  --dnspod-token-id ID    DNSPod Token ID
  --dnspod-token-key KEY  DNSPod Token Key
  --cf-api-token TOKEN    Cloudflare DNS-01 API Token
  --cf-api-key KEY        Cloudflare Global API Key
  --cf-email EMAIL        Cloudflare 账户邮箱
  --traffic-limit LIMIT   月配额 (如 100GB、1TB 或 unlimited)
  --reset-day DAY         每月重置日 (1-31，0 表示不重置)
  --non-interactive       非交互模式
  --dry-run               模拟演练执行
  --yes                   自动确认危险操作
EOF
}

parse_options() {
  while (($#)); do
    case "$1" in
      --protocol) [[ $# -ge 2 ]] || die "--protocol 缺少值"; PROTOCOL=$2; shift 2;;
      --domain) [[ $# -ge 2 ]] || die "--domain 缺少值"; DOMAIN=$2; NODE_DOMAIN=$2; shift 2;;
      --email) [[ $# -ge 2 ]] || die "--email 缺少值"; EMAIL=$2; shift 2;;
      --port) [[ $# -ge 2 ]] || die "--port 缺少值"; PORT=$2; NODE_PORT=$2; shift 2;;
      --password) [[ $# -ge 2 ]] || die "--password 缺少值"; PASSWORD=$2; NODE_PASSWORD=$2; shift 2;;
      --username) [[ $# -ge 2 ]] || die "--username 缺少值"; NODE_USERNAME=$2; shift 2;;
      --http-tls) HTTP_TLS="true"; shift;;
      --no-http-tls) HTTP_TLS="false"; shift;;
      --cert-mode) [[ $# -ge 2 ]] || die "--cert-mode 缺少值"; CERT_MODE=$2; shift 2;;
      --webroot) [[ $# -ge 2 ]] || die "--webroot 缺少值"; WEBROOT=$2; shift 2;;
      --outbound) [[ $# -ge 2 ]] || die "--outbound 缺少值"; OUTBOUND=$2; shift 2;;
      --traffic-limit) [[ $# -ge 2 ]] || die "--traffic-limit 缺少值"; TRAFFIC_LIMIT=$2; shift 2;;
      --reset-day) [[ $# -ge 2 ]] || die "--reset-day 缺少值"; TRAFFIC_RESET_DAY=$2; shift 2;;
      --ss-server) [[ $# -ge 2 ]] || die "--ss-server 缺少值"; SS_SERVER=$2; shift 2;;
      --ss-port) [[ $# -ge 2 ]] || die "--ss-port 缺少值"; SS_PORT=$2; shift 2;;
      --ss-method) [[ $# -ge 2 ]] || die "--ss-method 缺少值"; SS_METHOD=$2; shift 2;;
      --ss-password) [[ $# -ge 2 ]] || die "--ss-password 缺少值"; SS_PASSWORD=$2; shift 2;;
      --dnspod-token) [[ $# -ge 2 ]] || die "--dnspod-token 缺少值";
        if [[ "$2" == *,* ]]; then
          DNSPOD_TOKEN_ID="${2%%,*}"
          DNSPOD_TOKEN_KEY="${2#*,}"
        else
          DNSPOD_TOKEN_KEY=$2
        fi
        shift 2;;
      --dnspod-token-id) [[ $# -ge 2 ]] || die "--dnspod-token-id 缺少值"; DNSPOD_TOKEN_ID=$2; shift 2;;
      --dnspod-token-key) [[ $# -ge 2 ]] || die "--dnspod-token-key 缺少值"; DNSPOD_TOKEN_KEY=$2; shift 2;;
      --dnspod-secret-id) [[ $# -ge 2 ]] || die "--dnspod-secret-id 缺少值"; DNSPOD_TOKEN_ID=$2; shift 2;;
      --dnspod-secret-key) [[ $# -ge 2 ]] || die "--dnspod-secret-key 缺少值"; DNSPOD_TOKEN_KEY=$2; shift 2;;
      --cf-api-token) [[ $# -ge 2 ]] || die "--cf-api-token 缺少值"; CF_API_TOKEN=$2; shift 2;;
      --cf-api-key) [[ $# -ge 2 ]] || die "--cf-api-key 缺少值"; CF_API_KEY=$2; shift 2;;
      --cf-email) [[ $# -ge 2 ]] || die "--cf-email 缺少值"; CF_EMAIL=$2; shift 2;;
      --non-interactive) NON_INTERACTIVE=1; shift;;
      --dry-run) DRY_RUN=1; shift;;
      --force|-f) FORCE_UPDATE=1; shift;;
      --yes) ASSUME_YES=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "未知参数：$1";;
    esac
  done
}

main() {
  local command=${1:-menu}
  [[ $# -eq 0 ]] || shift
  case "$command" in
    menu) parse_options "$@"; menu ;;
    install) parse_options "$@"; install_flow ;;
    upgrade) parse_options "$@"; upgrade_sing_box ;;
    nodes) parse_options "$@"; nodes_menu ;;
    list) print_node_list ;;
    traffic) parse_options "$@"; traffic_menu ;;
    cert) parse_options "$@"; cert_flow ;;
    show) parse_options "$@"; show_client ;;
    status) parse_options "$@"; status_flow ;;
    logs) parse_options "$@"; logs_flow ;;
    start) parse_options "$@"; start_service ;;
    stop) parse_options "$@"; stop_service ;;
    restart) parse_options "$@"; restart_service ;;
    enable) parse_options "$@"; enable_service ;;
    disable) parse_options "$@"; disable_service ;;
    bbr) parse_options "$@"; bbr_menu ;;
    update-script|update|self-update) parse_options "$@"; update_self_script "cli" ;;
    uninstall) parse_options "$@"; uninstall_flow ;;
    api)
      local sub_cmd=${1:-menu}
      [[ $# -eq 0 ]] || shift
      case "$sub_cmd" in
        start) start_api_service ;;
        stop) stop_api_service ;;
        restart) restart_api_service ;;
        run|serve) run_api_foreground "$@" ;;
        uninstall) uninstall_api_service ;;
        menu|*) api_service_menu ;;
      esac
      ;;
    --api-json)
      get_traffic_json "${1:-}"
      exit 0
      ;;
    --version) printf "sbox (sing-box 管理脚本) v%s\n" "$SCRIPT_VERSION" ;;
    --reset-traffic)
      require_root
      [[ -n "${1:-}" && "${1:-}" =~ ^[0-9]+$ ]] || die "--reset-traffic 需要指定端口号。"
      reset_traffic_port "$1" "" 1
      ;;
    --reset-traffic-all)
      require_root
      reset_traffic_all
      ;;
    -h|--help|help) usage ;;
    *) die "未知命令：${command}。使用 --help 查看帮助。" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
