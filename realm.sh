#!/usr/bin/env bash

# Realm2 管理脚本
# 作者：elunez（https://github.com/elunez）
# 仅从 zhboner/realm 官方 GitHub Releases 获取二进制。

set -uo pipefail

# 管理脚本版本按十进制三段递增：1.0.9 -> 1.1.0，1.9.9 -> 2.0.0。
SCRIPT_VERSION="1.0.2"
REALM_REPOSITORY="${REALM_REPOSITORY:-zhboner/realm}"
REALM_API_URL="${REALM_API_URL:-https://api.github.com/repos/${REALM_REPOSITORY}/releases/latest}"
REALM_DIR="${REALM_DIR:-/etc/realm2}"
REALM_BIN="${REALM_BIN:-${REALM_DIR}/realm2}"
REALM_CONFIG="${REALM_CONFIG:-${REALM_DIR}/config.json}"
REALM_BACKUP_DIR="${REALM_BACKUP_DIR:-${REALM_DIR}/backups}"
REALM_SERVICE="${REALM_SERVICE:-realm2.service}"
REALM_SERVICE_FILE="${REALM_SERVICE_FILE:-/etc/systemd/system/${REALM_SERVICE}}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
REALM_BUILD="${REALM_BUILD:-full}"
PF_COMMAND="${PF_COMMAND:-/usr/local/bin/pf}"
SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-https://raw.githubusercontent.com/elunez/sbox/main/realm.sh}"
SCRIPT_SOURCE="${BASH_SOURCE[0]}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GREEN='\033[32m'
    C_RED='\033[31m'
    C_YELLOW='\033[33m'
    C_CYAN='\033[36m'
    C_RESET='\033[0m'
else
    C_GREEN=''
    C_RED=''
    C_YELLOW=''
    C_CYAN=''
    C_RESET=''
fi

info() { printf '%b\n' "${C_GREEN}[信息]${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[注意]${C_RESET} $*"; }
error() { printf '%b\n' "${C_RED}[错误]${C_RESET} $*" >&2; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "此操作需要 root 权限，请使用 sudo 运行。"
        return 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
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
    local prompt_text=$1
    local default_value=${2:-n}
    local answer=''

    read_input answer "$prompt_text" "$default_value" || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause_menu() {
    local unused=''
    IFS= read -r -p "按回车键继续..." unused || true
}

install_dependencies() {
    local missing=()
    local name

    for name in curl tar python3; do
        command_exists "$name" || missing+=("$name")
    done
    if ! command_exists sha256sum && ! command_exists shasum; then
        missing+=("sha256sum")
    fi
    ((${#missing[@]} == 0)) && return 0

    info "正在安装缺少的依赖：${missing[*]}"
    if command_exists apt-get; then
        apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar python3 coreutils
    elif command_exists dnf; then
        dnf install -y curl ca-certificates tar python3 coreutils
    elif command_exists yum; then
        yum install -y curl ca-certificates tar python3 coreutils
    elif command_exists apk; then
        apk add --no-cache curl ca-certificates tar python3 coreutils
    else
        error "无法识别包管理器，请手动安装 curl、tar、python3 和 sha256sum。"
        return 1
    fi
}

detect_target() {
    local machine=${REALM_MACHINE_OVERRIDE:-$(uname -m)}

    case "$machine" in
        x86_64|amd64)
            printf '%s\n' 'x86_64-unknown-linux-musl'
            ;;
        aarch64|arm64)
            printf '%s\n' 'aarch64-unknown-linux-musl'
            ;;
        armv7l|armv7)
            printf '%s\n' 'armv7-unknown-linux-musleabihf'
            ;;
        armv6l|arm)
            printf '%s\n' 'arm-unknown-linux-musleabihf'
            ;;
        *)
            error "暂不支持当前架构：${machine}"
            return 1
            ;;
    esac
}

release_asset_name() {
    local target=$1
    case "$REALM_BUILD" in
        slim) printf 'realm-slim-%s.tar.gz\n' "$target" ;;
        full) printf 'realm-%s.tar.gz\n' "$target" ;;
        *)
            error "REALM_BUILD 仅支持 full 或 slim：${REALM_BUILD}"
            return 1
            ;;
    esac
}

select_release_info() {
    local metadata_file=$1
    local asset_name=$2

    python3 - "$metadata_file" "$asset_name" <<'PY'
import json
import re
import sys

metadata_file, asset_name = sys.argv[1:]
with open(metadata_file, encoding="utf-8") as stream:
    release = json.load(stream)

tag = release.get("tag_name", "")
if not re.fullmatch(r"v[0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?", tag):
    raise SystemExit("GitHub API 返回了无效版本号")

for asset in release.get("assets", []):
    if asset.get("name") != asset_name:
        continue
    url = asset.get("browser_download_url", "")
    digest = asset.get("digest", "")
    expected_prefix = "https://github.com/zhboner/realm/releases/download/"
    if not url.startswith(expected_prefix):
        raise SystemExit("下载地址不是 zhboner/realm 官方 Release")
    if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
        raise SystemExit("官方 Release 未提供有效 SHA-256")
    print("|".join((tag, url, digest.split(":", 1)[1].lower())))
    break
else:
    raise SystemExit(f"最新 Release 中没有资产：{asset_name}")
PY
}

sha256_file() {
    local file=$1
    if command_exists sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

installed_version() {
    local version=''
    [[ -x "$REALM_BIN" ]] || return 1
    version=$("$REALM_BIN" --version 2>/dev/null | awk 'NR == 1 {print $2}')
    [[ "$version" =~ ^[0-9]+([.][0-9]+){1,3}([-+][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

manager_version_is_newer() {
    local candidate=$1
    local current=$2

    python3 - "$candidate" "$current" <<'PY'
import re
import sys

candidate, current = sys.argv[1:]
pattern = re.compile(r"^[0-9]+(?:\.[0-9]+){2}$")
if not pattern.fullmatch(candidate) or not pattern.fullmatch(current):
    raise SystemExit(2)
candidate_parts = tuple(map(int, candidate.split(".")))
current_parts = tuple(map(int, current.split(".")))
raise SystemExit(0 if candidate_parts > current_parts else 1)
PY
}

install_manager_command() {
    local source_file=${1:-$SCRIPT_SOURCE}
    local target_dir temp_target

    [[ -r "$source_file" ]] || {
        error "无法读取管理脚本：${source_file}"
        return 1
    }
    target_dir=$(dirname "$PF_COMMAND")
    mkdir -p "$target_dir" || return 1
    temp_target="${PF_COMMAND}.new.$$"
    if ! install -m 755 "$source_file" "$temp_target"; then
        rm -f "$temp_target"
        return 1
    fi
    if ! bash -n "$temp_target" || ! mv -f "$temp_target" "$PF_COMMAND"; then
        rm -f "$temp_target"
        return 1
    fi
}

update_manager_script() {
    local temp_file remote_version

    require_root || return 1
    command_exists curl || install_dependencies || return 1
    command_exists python3 || install_dependencies || return 1
    temp_file=$(mktemp) || return 1

    info "正在检查管理脚本更新..."
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 600 \
        --speed-limit 1024 --speed-time 30 -o "$temp_file" "$SCRIPT_UPDATE_URL"; then
        error "管理脚本下载失败。"
        rm -f "$temp_file"
        return 1
    fi
    if ! grep -q '^# Realm2 管理脚本$' "$temp_file" || ! bash -n "$temp_file"; then
        error "下载内容不是有效的 Realm2 管理脚本。"
        rm -f "$temp_file"
        return 1
    fi
    remote_version=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$temp_file" | head -n 1)
    if [[ -z "$remote_version" ]]; then
        error "无法识别远端脚本版本。"
        rm -f "$temp_file"
        return 1
    fi
    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        rm -f "$temp_file"
        info "管理脚本已经是最新版本 v${SCRIPT_VERSION}。"
        return 0
    fi
    if ! manager_version_is_newer "$remote_version" "$SCRIPT_VERSION"; then
        error "远端版本 v${remote_version} 不高于当前版本 v${SCRIPT_VERSION}，已拒绝降级。"
        rm -f "$temp_file"
        return 1
    fi
    if ! install_manager_command "$temp_file"; then
        error "管理脚本替换失败。"
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
    info "管理脚本已升级：v${SCRIPT_VERSION} -> v${remote_version}。"
}

config_action() {
    local action=$1
    shift

    command_exists python3 || {
        error "缺少 python3，请先执行安装/更新。"
        return 1
    }

    python3 - "$REALM_CONFIG" "$action" "$@" <<'PY'
import json
import os
import re
import sys
import tempfile

path, action, *args = sys.argv[1:]


def default_config():
    return {
        "log": {"level": "warn", "output": "stdout"},
        "dns": {
            "mode": "ipv4_and_ipv6",
            "protocol": "tcp_and_udp",
            "min_ttl": 0,
            "max_ttl": 60,
            "cache_size": 32,
        },
        "network": {
            "use_udp": True,
            "tcp_timeout": 300,
            "udp_timeout": 30,
        },
        "endpoints": [],
    }


def load():
    if not os.path.exists(path):
        return default_config()
    with open(path, encoding="utf-8") as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise SystemExit("配置根节点必须是 JSON 对象")
    endpoints = data.setdefault("endpoints", [])
    if not isinstance(endpoints, list):
        raise SystemExit("endpoints 必须是数组")
    for index, endpoint in enumerate(endpoints, 1):
        if not isinstance(endpoint, dict):
            raise SystemExit(f"第 {index} 条 endpoint 不是对象")
        if not isinstance(endpoint.get("listen"), str) or not isinstance(endpoint.get("remote"), str):
            raise SystemExit(f"第 {index} 条 endpoint 缺少 listen 或 remote")
    return data


def atomic_write(data):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o755, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=".config.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_path, 0o644)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


data = load()
endpoints = data["endpoints"]

if action == "init":
    if not os.path.exists(path):
        atomic_write(data)
elif action == "validate":
    print(len(endpoints))
elif action == "count":
    print(len(endpoints))
elif action == "list":
    for index, endpoint in enumerate(endpoints, 1):
        print(f"{index}\t{endpoint['listen']}\t{endpoint['remote']}")
elif action == "add":
    listen, remote = args
    if any(item.get("listen") == listen for item in endpoints):
        raise SystemExit(f"监听地址已存在：{listen}")
    endpoints.append({"listen": listen, "remote": remote})
    atomic_write(data)
    print(len(endpoints))
elif action == "delete":
    if not args or not re.fullmatch(r"[1-9][0-9]*", args[0]):
        raise SystemExit("规则编号无效")
    index = int(args[0])
    if index > len(endpoints):
        raise SystemExit("规则编号超出范围")
    removed = endpoints.pop(index - 1)
    atomic_write(data)
    print(f"{removed['listen']} -> {removed['remote']}")
else:
    raise SystemExit(f"未知配置操作：{action}")
PY
}

config_count() {
    config_action count
}

create_default_config() {
    mkdir -p "$REALM_DIR"
    chmod 755 "$REALM_DIR"
    config_action init
    config_action validate >/dev/null
}

create_config_backup() {
    local reason=${1:-manual}
    local timestamp

    [[ -f "$REALM_CONFIG" ]] || {
        error "配置文件不存在：${REALM_CONFIG}"
        return 1
    }
    timestamp=$(date '+%Y%m%d-%H%M%S')
    mkdir -p "$REALM_BACKUP_DIR"
    LAST_CONFIG_BACKUP="${REALM_BACKUP_DIR}/config-${timestamp}-${reason}-$$.json"
    cp -p "$REALM_CONFIG" "$LAST_CONFIG_BACKUP"
    info "配置已备份：${LAST_CONFIG_BACKUP}"
}

write_service_unit() {
    local temp_file
    temp_file=$(mktemp) || return 1
    cat >"$temp_file" <<EOF
[Unit]
Description=Realm2 relay service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${REALM_BIN} -c ${REALM_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    if ! install -m 644 "$temp_file" "${REALM_SERVICE_FILE}.new"; then
        rm -f "$temp_file" "${REALM_SERVICE_FILE}.new"
        return 1
    fi
    if ! mv -f "${REALM_SERVICE_FILE}.new" "$REALM_SERVICE_FILE"; then
        rm -f "$temp_file" "${REALM_SERVICE_FILE}.new"
        return 1
    fi
    rm -f "$temp_file"
}

rollback_install_files() {
    local old_binary=$1
    local old_service=$2

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
    "$SYSTEMCTL_BIN" daemon-reload || true
    if service_has_rules && [[ -x "$REALM_BIN" && -f "$REALM_SERVICE_FILE" ]]; then
        "$SYSTEMCTL_BIN" restart "$REALM_SERVICE" || true
    fi
}

service_has_rules() {
    local count
    count=$(config_count) || return 1
    [[ "$count" -gt 0 ]]
}

restart_for_config() {
    "$SYSTEMCTL_BIN" daemon-reload || return 1
    "$SYSTEMCTL_BIN" enable "$REALM_SERVICE" >/dev/null || return 1
    if service_has_rules; then
        "$SYSTEMCTL_BIN" restart "$REALM_SERVICE" || return 1
        "$SYSTEMCTL_BIN" is-active --quiet "$REALM_SERVICE"
    else
        "$SYSTEMCTL_BIN" stop "$REALM_SERVICE" >/dev/null 2>&1 || true
        warn "当前没有转发规则，服务已停止；添加第一条规则后会自动启动。"
    fi
}

install_latest() {
    local target asset metadata_file release_info latest_tag download_url expected_sha
    local archive extract_dir candidate actual_sha current_version old_binary old_service

    require_root || return 1
    install_dependencies || return 1
    command_exists "$SYSTEMCTL_BIN" || {
        error "当前系统没有 systemd，暂不支持自动安装服务。"
        return 1
    }

    target=$(detect_target) || return 1
    asset=$(release_asset_name "$target") || return 1
    metadata_file=$(mktemp) || return 1
    archive=$(mktemp) || {
        rm -f "$metadata_file"
        return 1
    }
    extract_dir=$(mktemp -d) || {
        rm -f "$metadata_file" "$archive"
        return 1
    }

    if ! curl -fL --retry 3 --connect-timeout 15 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: realm2-manager' \
        -o "$metadata_file" "$REALM_API_URL"; then
        error "无法获取 Realm 最新 Release 信息。"
        rm -f "$metadata_file" "$archive"
        rm -rf "$extract_dir"
        return 1
    fi

    release_info=$(select_release_info "$metadata_file" "$asset") || {
        error "无法解析 Realm 最新 Release。"
        rm -f "$metadata_file" "$archive"
        rm -rf "$extract_dir"
        return 1
    }
    IFS='|' read -r latest_tag download_url expected_sha <<<"$release_info"
    current_version=$(installed_version 2>/dev/null || true)
    info "已安装版本：${current_version:-未安装}；官方最新版本：${latest_tag}"

    if [[ "v${current_version:-}" != "$latest_tag" ]]; then
        info "正在下载官方资产：${asset}"
        if ! curl -fL --retry 3 --connect-timeout 15 -o "$archive" "$download_url"; then
            error "Realm 下载失败。"
            rm -f "$metadata_file" "$archive"
            rm -rf "$extract_dir"
            return 1
        fi
        actual_sha=$(sha256_file "$archive") || actual_sha=''
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            error "SHA-256 校验失败，已停止安装。"
            rm -f "$metadata_file" "$archive"
            rm -rf "$extract_dir"
            return 1
        fi
        tar -xzf "$archive" -C "$extract_dir" || {
            error "Realm 压缩包解压失败。"
            rm -f "$metadata_file" "$archive"
            rm -rf "$extract_dir"
            return 1
        }
        candidate=$(find "$extract_dir" -type f -name realm -print -quit)
        if [[ -z "$candidate" || ! -f "$candidate" ]]; then
            error "压缩包中未找到 realm 二进制。"
            rm -f "$metadata_file" "$archive"
            rm -rf "$extract_dir"
            return 1
        fi
        chmod 755 "$candidate"
        if ! timeout 5 "$candidate" --version 2>/dev/null | grep -q '^Realm '; then
            error "下载的 Realm 二进制无法执行。"
            rm -f "$metadata_file" "$archive"
            rm -rf "$extract_dir"
            return 1
        fi
    else
        candidate=''
        info "Realm 核心已经是最新版本。"
    fi

    mkdir -p "$REALM_DIR"
    chmod 755 "$REALM_DIR"
    create_default_config || return 1

    old_binary=''
    old_service=''
    if [[ -f "$REALM_BIN" ]]; then
        old_binary="${REALM_BIN}.previous"
        cp -p "$REALM_BIN" "$old_binary"
    fi
    if [[ -f "$REALM_SERVICE_FILE" ]]; then
        old_service="${REALM_SERVICE_FILE}.previous"
        cp -p "$REALM_SERVICE_FILE" "$old_service"
    fi

    if [[ -n "$candidate" ]]; then
        if ! install -m 755 "$candidate" "${REALM_BIN}.new" || ! mv -f "${REALM_BIN}.new" "$REALM_BIN"; then
            error "替换 Realm 二进制失败，正在回滚。"
            rm -f "${REALM_BIN}.new"
            rollback_install_files "$old_binary" "$old_service"
            rm -f "$metadata_file" "$archive"
            rm -rf "$extract_dir"
            return 1
        fi
    fi
    if ! write_service_unit; then
        error "写入 systemd 服务失败，正在回滚。"
        rollback_install_files "$old_binary" "$old_service"
        rm -f "$metadata_file" "$archive"
        rm -rf "$extract_dir"
        return 1
    fi

    if ! restart_for_config; then
        error "新版本启动失败，正在回滚。"
        rollback_install_files "$old_binary" "$old_service"
        rm -f "$metadata_file" "$archive"
        rm -rf "$extract_dir"
        return 1
    fi

    rm -f "$metadata_file" "$archive"
    rm -rf "$extract_dir"
    if ! install_manager_command "$SCRIPT_SOURCE"; then
        error "Realm2 核心已安装，但 pf 命令安装失败。"
        return 1
    fi
    info "Realm2 ${latest_tag} 安装/更新完成。"
    info "后续可使用 pf 打开菜单，使用 pf update 更新管理脚本。"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_host() {
    [[ -n "$1" && "$1" != *[[:space:]]* && "$1" != */* && "$1" != *'#'* ]]
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

add_rule() {
    local listen_port remote_host remote_port listen remote backup

    require_root || return 1
    [[ -x "$REALM_BIN" ]] || {
        error "Realm2 尚未安装，请先执行安装/更新。"
        return 1
    }
    create_default_config || return 1

    read_input listen_port "本地监听端口 [1-65535]：" '' || return 1
    valid_port "$listen_port" || {
        error "监听端口无效。"
        return 1
    }
    read_input remote_host "落地域名或 IP：" '' || return 1
    valid_host "$remote_host" || {
        error "落地域名或 IP 无效。"
        return 1
    }
    read_input remote_port "落地端口 [默认 ${listen_port}]：" "$listen_port" || return 1
    valid_port "$remote_port" || {
        error "落地端口无效。"
        return 1
    }

    listen="0.0.0.0:${listen_port}"
    remote=$(format_host_port "$remote_host" "$remote_port")
    printf '即将添加：%s -> %s（TCP + UDP）\n' "$listen" "$remote"
    confirm "确认添加？[Y/n]：" 'y' || {
        warn "已取消。"
        return 0
    }

    create_config_backup add || return 1
    backup=$LAST_CONFIG_BACKUP
    if ! config_action add "$listen" "$remote" >/dev/null; then
        error "规则写入失败。"
        return 1
    fi
    if ! restart_for_config; then
        error "新配置启动失败，正在恢复修改前配置。"
        cp -p "$backup" "$REALM_CONFIG"
        restart_for_config || true
        return 1
    fi
    info "规则添加成功。"
}

list_rules() {
    local rows
    [[ -f "$REALM_CONFIG" ]] || {
        warn "尚未生成 Realm2 配置。"
        return 0
    }
    rows=$(config_action list) || return 1
    if [[ -z "$rows" ]]; then
        warn "当前没有转发规则。"
        return 0
    fi
    printf '%-6s %-24s %s\n' '序号' '监听地址' '落地地址'
    printf '%s\n' '------------------------------------------------------------'
    while IFS=$'\t' read -r index listen remote; do
        printf '%-6s %-24s %s\n' "$index" "$listen" "$remote"
    done <<<"$rows"
}

delete_rule() {
    local index backup

    require_root || return 1
    list_rules || return 1
    [[ $(config_count) -gt 0 ]] || return 0
    read_input index "请输入要删除的规则编号：" '' || return 1
    [[ "$index" =~ ^[1-9][0-9]*$ ]] || {
        error "规则编号无效。"
        return 1
    }
    confirm "确认删除第 ${index} 条规则？[y/N]：" 'n' || {
        warn "已取消。"
        return 0
    }

    create_config_backup delete || return 1
    backup=$LAST_CONFIG_BACKUP
    if ! config_action delete "$index"; then
        error "规则删除失败。"
        return 1
    fi
    if ! restart_for_config; then
        error "删除后的配置启动失败，正在恢复修改前配置。"
        cp -p "$backup" "$REALM_CONFIG"
        restart_for_config || true
        return 1
    fi
    info "规则删除成功。"
}

backup_config() {
    require_root || return 1
    create_config_backup manual
}

restore_config() {
    local latest current_backup

    require_root || return 1
    latest=$(find "$REALM_BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -print 2>/dev/null | sort | tail -n 1)
    [[ -n "$latest" ]] || {
        error "没有可恢复的配置备份。"
        return 1
    }
    info "即将恢复：${latest}"
    confirm "确认恢复最近备份？[y/N]：" 'n' || return 0
    create_config_backup before-restore || return 1
    current_backup=$LAST_CONFIG_BACKUP
    cp -p "$latest" "$REALM_CONFIG"
    if ! config_action validate >/dev/null || ! restart_for_config; then
        error "备份恢复失败，正在还原当前配置。"
        cp -p "$current_backup" "$REALM_CONFIG"
        restart_for_config || true
        return 1
    fi
    info "配置恢复成功。"
}

service_action() {
    local action=$1
    require_root || return 1
    [[ -f "$REALM_SERVICE_FILE" ]] || {
        error "Realm2 服务尚未安装。"
        return 1
    }
    case "$action" in
        start)
            service_has_rules || {
                error "没有转发规则，拒绝启动空服务。"
                return 1
            }
            "$SYSTEMCTL_BIN" enable --now "$REALM_SERVICE"
            ;;
        stop)
            "$SYSTEMCTL_BIN" stop "$REALM_SERVICE"
            ;;
        restart)
            service_has_rules || {
                error "没有转发规则，拒绝重启空服务。"
                return 1
            }
            "$SYSTEMCTL_BIN" restart "$REALM_SERVICE"
            ;;
        status)
            "$SYSTEMCTL_BIN" --no-pager --full status "$REALM_SERVICE"
            ;;
        *)
            error "未知服务操作：${action}"
            return 1
            ;;
    esac
}

uninstall_realm() {
    local purge='n'

    require_root || return 1
    confirm "确认卸载 Realm2 程序和服务？[y/N]：" 'n' || return 0
    "$SYSTEMCTL_BIN" disable --now "$REALM_SERVICE" >/dev/null 2>&1 || true
    rm -f "$REALM_SERVICE_FILE" "$REALM_BIN" "${REALM_BIN}.previous" "$PF_COMMAND"
    "$SYSTEMCTL_BIN" daemon-reload || true
    read_input purge "同时删除配置和备份？[y/N]：" 'n' || true
    if [[ "$purge" =~ ^[Yy]$ ]]; then
        rm -f "$REALM_CONFIG"
        if [[ -d "$REALM_BACKUP_DIR" ]]; then
            find "$REALM_BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -delete
            rmdir "$REALM_BACKUP_DIR" 2>/dev/null || true
        fi
        rmdir "$REALM_DIR" 2>/dev/null || true
    fi
    info "Realm2 已卸载。"
}

show_menu() {
    local version status count choice

    while true; do
        [[ -t 1 ]] && clear
        version=$(installed_version 2>/dev/null || printf '未安装')
        if "$SYSTEMCTL_BIN" is-active --quiet "$REALM_SERVICE" 2>/dev/null; then
            status='运行中'
        elif [[ -f "$REALM_SERVICE_FILE" ]]; then
            status='已停止'
        else
            status='未安装'
        fi
        count=$(config_count 2>/dev/null || printf '0')

        printf '%b\n' "${C_CYAN}Realm2 中转管理 v${SCRIPT_VERSION} · elunez${C_RESET}"
        printf '%s\n' '------------------------------------'
        printf '%s\n' ' 0. 退出脚本'
        printf '%s\n' ' 1. 安装/更新 Realm2'
        printf '%s\n' '------------------------------------'
        printf '%s\n' ' 2. 添加转发规则'
        printf '%s\n' ' 3. 查看转发规则'
        printf '%s\n' ' 4. 删除转发规则'
        printf '%s\n' '------------------------------------'
        printf '%s\n' ' 5. 启动服务'
        printf '%s\n' ' 6. 停止服务'
        printf '%s\n' ' 7. 重启服务'
        printf '%s\n' ' 8. 查看状态'
        printf '%s\n' '------------------------------------'
        printf '%s\n' ' 9. 备份配置'
        printf '%s\n' '10. 恢复最近备份'
        printf '%s\n' '11. 卸载 Realm2'
        printf '%s\n' '12. 更新管理脚本'
        printf '%s\n' '------------------------------------'
        printf '核心版本：%s | 服务：%s | 规则：%s\n' "$version" "$status" "$count"
        printf '%s\n' '------------------------------------'
        read_input choice "请选择 [0-12]：" '' || return 0

        case "$choice" in
            0) return 0 ;;
            1) install_latest ;;
            2) add_rule ;;
            3) list_rules ;;
            4) delete_rule ;;
            5) service_action start ;;
            6) service_action stop ;;
            7) service_action restart ;;
            8) service_action status ;;
            9) backup_config ;;
            10) restore_config ;;
            11) uninstall_realm ;;
            12) update_manager_script ;;
            *) error "请输入 0-12。" ;;
        esac
        pause_menu
    done
}

usage() {
    cat <<EOF
用法：
  pf                       打开交互菜单
  pf update                更新管理脚本
  pf install               安装或更新 Realm2 官方核心
  pf add                   添加转发规则
  pf list                  查看转发规则
  pf delete                删除转发规则
  pf start|stop|restart|status
  pf backup|restore
  pf uninstall
  pf version               查看已安装核心版本
EOF
}

maybe_reexec_as_root() {
    local command=$1
    shift

    [[ ${EUID:-$(id -u)} -eq 0 || -n "${REALM_SKIP_SUDO:-}" ]] && return 0
    case "$command" in
        list|version|-h|--help|help) return 0 ;;
    esac
    if command_exists sudo; then
        exec sudo bash "$SCRIPT_SOURCE" "$command" "$@"
    fi
    error "此操作需要 root 权限，且系统没有 sudo。"
    return 1
}

main() {
    local command=${1:-menu}
    shift $(( $# > 0 ? 1 : 0 ))
    maybe_reexec_as_root "$command" "$@" || return 1
    case "$command" in
        menu) show_menu ;;
        install|core-update|update-core) install_latest ;;
        update) update_manager_script ;;
        add) add_rule ;;
        list) list_rules ;;
        delete) delete_rule ;;
        start|stop|restart|status) service_action "$command" ;;
        backup) backup_config ;;
        restore) restore_config ;;
        uninstall) uninstall_realm ;;
        version) installed_version || printf '未安装\n' ;;
        -h|--help|help) usage ;;
        *)
            error "未知命令：${command}"
            usage
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
