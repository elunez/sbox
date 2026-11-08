#!/usr/bin/env bash

# Realm2 极简安装脚本
# 作者：elunez（https://github.com/elunez）
# Realm 核心仅从 zhboner/realm 官方 Releases 获取。

set -uo pipefail

SCRIPT_VERSION="1.0.7"
REALM_VERSION="v2.9.6"
REALM_DIR="${REALM_DIR:-/etc/realm2}"
REALM_BIN="${REALM_BIN:-${REALM_DIR}/realm2}"
REALM_CONFIG_DIR="${REALM_CONFIG_DIR:-${REALM_DIR}/config}"
REALM_RULE_DIR="${REALM_RULE_DIR:-${REALM_CONFIG_DIR}/rules}"
REALM_LEGACY_CONFIG="${REALM_LEGACY_CONFIG:-${REALM_DIR}/config.json}"
REALM_SERVICE_NAME="${REALM_SERVICE_NAME:-realm2}"
REALM_SERVICE="${REALM_SERVICE:-${REALM_SERVICE_NAME}.service}"
REALM_SERVICE_FILE="${REALM_SERVICE_FILE:-}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
RC_SERVICE_BIN="${RC_SERVICE_BIN:-rc-service}"
RC_UPDATE_BIN="${RC_UPDATE_BIN:-rc-update}"
INIT_SYSTEM="${INIT_SYSTEM:-}"
OLD_PF_COMMAND="${OLD_PF_COMMAND:-/usr/local/bin/pf}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GREEN='\033[32m'
    C_RED='\033[31m'
    C_YELLOW='\033[33m'
    C_RESET='\033[0m'
else
    C_GREEN=''
    C_RED=''
    C_YELLOW=''
    C_RESET=''
fi

info() { printf '%b\n' "${C_GREEN}[信息]${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[注意]${C_RESET} $*"; }
error() { printf '%b\n' "${C_RED}[错误]${C_RESET} $*" >&2; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
    if command_exists sudo; then
        exec sudo bash "$0" "$@"
    fi
    error "请使用 root 权限运行。"
    return 1
}

read_input() {
    local variable_name=$1
    local prompt_text=$2
    local default_value=${3-}
    local input_value=''
    IFS= read -r -p "$prompt_text" input_value || return 1
    [[ -n "$input_value" ]] || input_value=$default_value
    printf -v "$variable_name" '%s' "$input_value"
}

confirm() {
    local answer=''
    read_input answer "$1" "${2:-n}" || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

install_dependencies() {
    local missing=()
    local name
    for name in curl tar timeout sha256sum install; do
        command_exists "$name" || missing+=("$name")
    done
    if command_exists apk && { ! command_exists "$RC_SERVICE_BIN" || ! command_exists "$RC_UPDATE_BIN"; }; then
        missing+=("openrc")
    fi
    ((${#missing[@]} == 0)) && return 0

    info "正在安装缺少的依赖：${missing[*]}"
    if command_exists apt-get; then
        apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar coreutils
    elif command_exists dnf; then
        dnf install -y curl ca-certificates tar coreutils
    elif command_exists yum; then
        yum install -y curl ca-certificates tar coreutils
    elif command_exists apk; then
        apk add --no-cache bash curl ca-certificates tar coreutils openrc
    else
        error "无法识别包管理器，请手动安装 curl、tar 和 sha256sum。"
        return 1
    fi
}

init_service_runtime() {
    if [[ -z "$INIT_SYSTEM" ]]; then
        if command_exists "$SYSTEMCTL_BIN" && \
            { [[ -d /run/systemd/system ]] || [[ $(cat /proc/1/comm 2>/dev/null) == 'systemd' ]]; }; then
            INIT_SYSTEM='systemd'
        elif command_exists "$RC_SERVICE_BIN" && command_exists "$RC_UPDATE_BIN"; then
            INIT_SYSTEM='openrc'
        elif command_exists "$SYSTEMCTL_BIN"; then
            INIT_SYSTEM='systemd'
        else
            error "未检测到 systemd 或 OpenRC。"
            return 1
        fi
    fi
    case "$INIT_SYSTEM" in
        systemd)
            [[ -n "$REALM_SERVICE_FILE" ]] || REALM_SERVICE_FILE="/etc/systemd/system/${REALM_SERVICE}"
            ;;
        openrc)
            [[ -n "$REALM_SERVICE_FILE" ]] || REALM_SERVICE_FILE="/etc/init.d/${REALM_SERVICE_NAME}"
            ;;
        *)
            error "不支持的服务管理器：${INIT_SYSTEM}"
            return 1
            ;;
    esac
}

service_enable() {
    if [[ "$INIT_SYSTEM" == 'systemd' ]]; then
        "$SYSTEMCTL_BIN" enable "$REALM_SERVICE" >/dev/null
    else
        "$RC_UPDATE_BIN" add "$REALM_SERVICE_NAME" default >/dev/null
    fi
}

service_disable() {
    if [[ "$INIT_SYSTEM" == 'systemd' ]]; then
        "$SYSTEMCTL_BIN" disable --now "$REALM_SERVICE" >/dev/null 2>&1 || true
    else
        "$RC_SERVICE_BIN" "$REALM_SERVICE_NAME" stop >/dev/null 2>&1 || true
        "$RC_UPDATE_BIN" del "$REALM_SERVICE_NAME" default >/dev/null 2>&1 || true
    fi
}

service_is_running() {
    if [[ "$INIT_SYSTEM" == 'systemd' ]]; then
        "$SYSTEMCTL_BIN" is-active --quiet "$REALM_SERVICE"
    else
        "$RC_SERVICE_BIN" "$REALM_SERVICE_NAME" status >/dev/null 2>&1
    fi
}

service_start() {
    if [[ "$INIT_SYSTEM" == 'systemd' ]]; then
        "$SYSTEMCTL_BIN" start "$REALM_SERVICE"
    else
        "$RC_SERVICE_BIN" "$REALM_SERVICE_NAME" start
    fi
}

service_restart() {
    if [[ "$INIT_SYSTEM" == 'systemd' ]]; then
        "$SYSTEMCTL_BIN" restart "$REALM_SERVICE"
    else
        "$RC_SERVICE_BIN" "$REALM_SERVICE_NAME" restart
    fi
}

service_status() {
    if [[ "$INIT_SYSTEM" == 'systemd' ]]; then
        "$SYSTEMCTL_BIN" --no-pager --full status "$REALM_SERVICE"
    else
        "$RC_SERVICE_BIN" "$REALM_SERVICE_NAME" status
    fi
}

detect_release_asset() {
    local machine=${REALM_MACHINE_OVERRIDE:-$(uname -m)}
    case "$machine" in
        x86_64|amd64)
            REALM_ASSET='realm-x86_64-unknown-linux-musl.tar.gz'
            REALM_SHA256='b1cc335547bea8bb2a88178bef12ec7f2363e36200e7ea1d4e1e67627929bf65'
            ;;
        aarch64|arm64)
            REALM_ASSET='realm-aarch64-unknown-linux-musl.tar.gz'
            REALM_SHA256='f4c0318dd86854da483dcb7645b4f39cae2cc3f91c688fef969d53220b949488'
            ;;
        armv7l|armv7)
            REALM_ASSET='realm-armv7-unknown-linux-musleabihf.tar.gz'
            REALM_SHA256='ceedaf367c78f911eac227b2b88b3132f964d05a8b71f7a6a7e429dc78ec1862'
            ;;
        armv6l|arm)
            REALM_ASSET='realm-arm-unknown-linux-musleabihf.tar.gz'
            REALM_SHA256='2e83ca031a96aa171df45f9d929807cd8d2671384698ae2ab54a62d6c347c48c'
            ;;
        *)
            error "暂不支持当前架构：${machine}"
            return 1
            ;;
    esac
    REALM_DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/${REALM_ASSET}"
}

installed_version() {
    local version=''
    [[ -x "$REALM_BIN" ]] || return 1
    version=$("$REALM_BIN" --version 2>/dev/null | awk 'NR == 1 {print $2}')
    [[ "$version" =~ ^[0-9]+([.][0-9]+){1,3}([-+][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

version_is_newer() {
    local candidate=$1
    local baseline=$2
    local candidate_major candidate_minor candidate_patch
    local baseline_major baseline_minor baseline_patch

    [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$baseline" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
    IFS='.' read -r baseline_major baseline_minor baseline_patch <<<"$baseline"
    ((10#$candidate_major > 10#$baseline_major)) && return 0
    ((10#$candidate_major < 10#$baseline_major)) && return 1
    ((10#$candidate_minor > 10#$baseline_minor)) && return 0
    ((10#$candidate_minor < 10#$baseline_minor)) && return 1
    ((10#$candidate_patch > 10#$baseline_patch))
}

active_config_path() {
    if [[ -s "$REALM_LEGACY_CONFIG" ]]; then
        printf '%s\n' "$REALM_LEGACY_CONFIG"
    else
        printf '%s\n' "$REALM_CONFIG_DIR"
    fi
}

has_rules() {
    if [[ -s "$REALM_LEGACY_CONFIG" ]]; then
        grep -Eq '"listen"[[:space:]]*:' "$REALM_LEGACY_CONFIG"
        return
    fi
    find "$REALM_RULE_DIR" -maxdepth 1 -type f -name '*.toml' ! -name '.*' -print -quit 2>/dev/null | grep -q .
}

prepare_config_dir() {
    local global_file example_file temp_file rule_file disabled_global
    mkdir -p "$REALM_RULE_DIR" || return 1
    chmod 755 "$REALM_DIR" "$REALM_CONFIG_DIR" "$REALM_RULE_DIR"

    # v1.0.6 生成的全局文件缺少 endpoints，Realm 会拒绝解析；隐藏后 Realm 会自动忽略。
    global_file="${REALM_CONFIG_DIR}/00-global.toml"
    if [[ -f "$global_file" ]]; then
        disabled_global="${REALM_CONFIG_DIR}/.00-global.toml.v1.0.6.disabled.$(date +%s)"
        mv -f "$global_file" "$disabled_global" || return 1
        warn "已停用不兼容配置：${disabled_global}"
    fi

    # v1.0.6 规则文件只有 endpoints；补充网络设置以继续启用 TCP + UDP。
    while IFS= read -r rule_file; do
        grep -Eq '^\[network\][[:space:]]*$' "$rule_file" && continue
        grep -Eq '^\[\[endpoints\]\][[:space:]]*$' "$rule_file" || continue
        temp_file=$(mktemp "${REALM_RULE_DIR}/.migrate.XXXXXX") || return 1
        cat >"$temp_file" <<'TOML'
[network]
use_udp = true
tcp_timeout = 10
udp_timeout = 30

TOML
        cat "$rule_file" >>"$temp_file" || { rm -f "$temp_file"; return 1; }
        chmod 644 "$temp_file" && mv -f "$temp_file" "$rule_file" || {
            rm -f "$temp_file"
            return 1
        }
    done < <(find "$REALM_RULE_DIR" -maxdepth 1 -type f -name '*.toml' ! -name '.*' -print 2>/dev/null)

    example_file="${REALM_RULE_DIR}/.rule.example.toml"
    cat >"$example_file" <<'TOML'
[network]
use_udp = true
tcp_timeout = 10
udp_timeout = 30

[[endpoints]]
listen = "0.0.0.0:15608"
remote = "sg1.example.com:15606"
TOML
    chmod 644 "$example_file"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_host() {
    [[ -n "$1" && "$1" != *[[:space:]]* && "$1" != *'"'* && "$1" != *'#'* && "$1" != */* ]]
}

format_host_port() {
    local host=$1
    local port=$2
    if [[ "$host" == \[*\] ]]; then
        printf '%s:%s\n' "$host" "$port"
    elif [[ "$host" == *:* ]]; then
        printf '[%s]:%s\n' "$host" "$port"
    else
        printf '%s:%s\n' "$host" "$port"
    fi
}

create_rule_interactive() {
    local listen_port remote_host remote_port remote rule_file temp_file
    [[ -t 0 ]] || return 0
    confirm "当前没有转发规则，是否立即添加一条？[Y/n]：" 'y' || return 0
    read_input listen_port "本地监听端口 [1-65535]：" '' || return 1
    valid_port "$listen_port" || { error "监听端口无效。"; return 1; }
    read_input remote_host "落地域名或 IP：" '' || return 1
    valid_host "$remote_host" || { error "落地域名或 IP 无效。"; return 1; }
    read_input remote_port "落地端口 [默认 ${listen_port}]：" "$listen_port" || return 1
    valid_port "$remote_port" || { error "落地端口无效。"; return 1; }
    rule_file="${REALM_RULE_DIR}/${listen_port}.toml"
    [[ ! -e "$rule_file" ]] || { error "规则文件已存在：${rule_file}"; return 1; }
    remote=$(format_host_port "$remote_host" "$remote_port")
    temp_file=$(mktemp "${REALM_RULE_DIR}/.rule.XXXXXX") || return 1
    cat >"$temp_file" <<EOF
[network]
use_udp = true
tcp_timeout = 10
udp_timeout = 30

[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote}"
EOF
    chmod 644 "$temp_file" && mv -f "$temp_file" "$rule_file" || {
        rm -f "$temp_file"
        return 1
    }
    info "规则已保存：${rule_file}"
}

write_service_file() {
    local config_path temp_file service_mode='644'
    init_service_runtime || return 1
    config_path=$(active_config_path)
    temp_file=$(mktemp) || return 1
    if [[ "$INIT_SYSTEM" == 'systemd' ]]; then
        cat >"$temp_file" <<EOF
[Unit]
Description=Realm2 relay service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
ExecStart=${REALM_BIN} -c ${config_path}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    else
        service_mode='755'
        cat >"$temp_file" <<EOF
#!/sbin/openrc-run
name="Realm2"
description="Realm2 relay service"
command="${REALM_BIN}"
command_args="-c ${config_path}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=5
respawn_period=60
output_log="/var/log/realm2.log"
error_log="/var/log/realm2.log"

depend() {
    need net
    after firewall
}
EOF
    fi
    install -m "$service_mode" "$temp_file" "${REALM_SERVICE_FILE}.new" && \
        mv -f "${REALM_SERVICE_FILE}.new" "$REALM_SERVICE_FILE" || {
        rm -f "$temp_file" "${REALM_SERVICE_FILE}.new"
        return 1
    }
    rm -f "$temp_file"
}

download_core() {
    local temp_dir archive candidate actual_sha
    detect_release_asset || return 1
    temp_dir=$(mktemp -d) || return 1
    archive="${temp_dir}/${REALM_ASSET}"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 600 \
        --speed-limit 1024 --speed-time 30 -o "$archive" "$REALM_DOWNLOAD_URL"; then
        rm -rf "$temp_dir"
        error "Realm 下载失败。"
        return 1
    fi
    actual_sha=$(sha256sum "$archive" | awk '{print $1}')
    if [[ "$actual_sha" != "$REALM_SHA256" ]]; then
        rm -rf "$temp_dir"
        error "Realm SHA-256 校验失败。"
        return 1
    fi
    tar -xzf "$archive" -C "$temp_dir" || { rm -rf "$temp_dir"; return 1; }
    candidate=$(find "$temp_dir" -type f -name realm -print -quit)
    if [[ -z "$candidate" ]] || ! timeout 5 "$candidate" --version 2>/dev/null | grep -q '^Realm '; then
        rm -rf "$temp_dir"
        error "下载的 Realm 二进制无法执行。"
        return 1
    fi
    mkdir -p "$REALM_DIR"
    install -m 755 "$candidate" "${REALM_BIN}.new" && mv -f "${REALM_BIN}.new" "$REALM_BIN" || {
        rm -rf "$temp_dir"
        return 1
    }
    rm -rf "$temp_dir"
}

install_realm() {
    local current_version old_binary='' old_service=''
    require_root install || return 1
    install_dependencies || return 1
    init_service_runtime || return 1
    current_version=$(installed_version 2>/dev/null || true)
    info "已安装核心：${current_version:-未安装}；脚本内置核心：${REALM_VERSION}"

    if [[ -f "$REALM_BIN" ]]; then
        old_binary="${REALM_BIN}.previous"
        cp -p "$REALM_BIN" "$old_binary" || return 1
    fi
    if [[ -f "$REALM_SERVICE_FILE" ]]; then
        old_service="${REALM_SERVICE_FILE}.previous"
        cp -p "$REALM_SERVICE_FILE" "$old_service" || return 1
    fi
    if [[ "v${current_version:-}" == "$REALM_VERSION" ]]; then
        info "Realm 核心已经是脚本内置版本。"
    elif version_is_newer "$current_version" "${REALM_VERSION#v}"; then
        warn "已安装核心 ${current_version} 高于脚本内置版本 ${REALM_VERSION#v}，不执行降级。"
    else
        download_core || return 1
    fi

    mkdir -p "$REALM_DIR"
    prepare_config_dir || return 1
    if [[ -s "$REALM_LEGACY_CONFIG" ]]; then
        warn "检测到旧配置，将继续使用：${REALM_LEGACY_CONFIG}"
    elif ! has_rules; then
        create_rule_interactive || return 1
    fi
    if ! write_service_file; then
        if [[ -n "$old_binary" && -f "$old_binary" ]]; then
            cp -p "$old_binary" "$REALM_BIN"
        else
            rm -f "$REALM_BIN"
        fi
        if [[ -n "$old_service" && -f "$old_service" ]]; then
            cp -p "$old_service" "$REALM_SERVICE_FILE"
        else
            rm -f "$REALM_SERVICE_FILE"
        fi
        [[ "$INIT_SYSTEM" == 'systemd' ]] && "$SYSTEMCTL_BIN" daemon-reload || true
        return 1
    fi
    [[ "$INIT_SYSTEM" == 'systemd' ]] && "$SYSTEMCTL_BIN" daemon-reload

    # 清理由旧版管理脚本安装的快捷命令。
    rm -f "$OLD_PF_COMMAND"

    if has_rules; then
        service_enable || return 1
        if service_is_running; then
            service_restart || return 1
        else
            service_start || return 1
        fi
        sleep 2
        if ! service_is_running; then
            error "Realm2 服务启动失败，正在恢复安装前文件。"
            service_disable
            if [[ -n "$old_binary" && -f "$old_binary" ]]; then
                cp -p "$old_binary" "$REALM_BIN"
            else
                rm -f "$REALM_BIN"
            fi
            if [[ -n "$old_service" && -f "$old_service" ]]; then
                cp -p "$old_service" "$REALM_SERVICE_FILE"
                [[ "$INIT_SYSTEM" == 'systemd' ]] && "$SYSTEMCTL_BIN" daemon-reload || true
                service_enable || true
                service_start || true
            else
                rm -f "$REALM_SERVICE_FILE"
                [[ "$INIT_SYSTEM" == 'systemd' ]] && "$SYSTEMCTL_BIN" daemon-reload || true
            fi
            return 1
        fi
        info "Realm2 ${REALM_VERSION} 已安装并运行。"
    else
        service_disable
        warn "尚未配置规则，服务未启动。"
        warn "复制 ${REALM_RULE_DIR}/.rule.example.toml 为新的 .toml 文件，修改后重启服务。"
    fi
}

uninstall_realm() {
    require_root uninstall || return 1
    init_service_runtime || return 1
    confirm "确认卸载 Realm2 程序和服务？[y/N]：" 'n' || return 0
    service_disable
    rm -f "$REALM_SERVICE_FILE" "$REALM_BIN" "${REALM_BIN}.previous" "$OLD_PF_COMMAND"
    [[ "$INIT_SYSTEM" == 'systemd' ]] && "$SYSTEMCTL_BIN" daemon-reload || true
    warn "配置保留在 ${REALM_DIR}，未自动删除。"
}

show_status() {
    init_service_runtime || return 1
    printf '安装脚本版本：v%s\n' "$SCRIPT_VERSION"
    printf '内置核心版本：%s\n' "$REALM_VERSION"
    printf '已安装核心：%s\n' "$(installed_version 2>/dev/null || printf '未安装')"
    printf '配置路径：%s\n' "$(active_config_path)"
    if [[ -f "$REALM_SERVICE_FILE" ]]; then
        service_status
    else
        printf '服务状态：未安装\n'
    fi
}

usage() {
    cat <<EOF
Realm2 极简安装脚本 v${SCRIPT_VERSION}

用法：
  bash realm.sh install      安装或更新内置 Realm 核心
  bash realm.sh status       查看安装与服务状态
  bash realm.sh uninstall    卸载程序和服务（保留配置）
  bash realm.sh version      查看脚本与内置核心版本

新安装配置目录：${REALM_CONFIG_DIR}
每条规则保存为 ${REALM_RULE_DIR}/端口.toml
EOF
}

main() {
    case "${1:-install}" in
        install|update) install_realm ;;
        status) show_status ;;
        uninstall) uninstall_realm ;;
        version) printf 'script=v%s realm=%s\n' "$SCRIPT_VERSION" "$REALM_VERSION" ;;
        -h|--help|help) usage ;;
        *)
            error "未知命令：$1"
            usage
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
