#!/usr/bin/env bash
# dns-manager.sh - 跨发行版永久 DNS 管理脚本
# 支持：NetworkManager、systemd-resolved、resolvconf/openresolv、
#       dhcpcd、dhclient、SUSE netconfig，以及静态 /etc/resolv.conf 回退方案。
set -Eeuo pipefail

VERSION="1.1.3"
STATE_DIR="/var/lib/dns-manager"
SNAPSHOT_DIR="${STATE_DIR}/original"
LOCK_DIR="/run/dns-manager.lock"
MARK_BEGIN="# BEGIN DNS-MANAGER"
MARK_END="# END DNS-MANAGER"
RESOLVCONF_STATE_FILE="${STATE_DIR}/resolvconf.nameservers"
RESOLVCONF_HOOK_FILE="/etc/resolvconf/update.d/zz-dns-manager"
RESOLVCONF_LEGACY_HOOK_FILE="/etc/resolvconf/update-libc.d/90-dns-manager"
RESOLV_CONF="/etc/resolv.conf"
DHCPCD_EXIT_HOOK_FILE="/etc/dhcpcd.exit-hook"
BACKEND=""
IFACE=""
ASSUME_YES=0
ACTION=""
DNS_ARGUMENT=""
ORIGINAL_ARGS=("$@")

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

info()  { printf '%s[信息]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()    { printf '%s[成功]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()   { printf '%s[错误]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
用法：
  dns-manager.sh                         打开交互菜单
  dns-manager.sh --set "1.1.1.1 8.8.8.8"
  dns-manager.sh --restore               恢复应用脚本前的 DNS
  dns-manager.sh --status                查看 DNS 状态
  dns-manager.sh --help

选项：
  --set LIST          设置 DNS，多个地址用空格或逗号分隔
  --restore           恢复修改前配置/自动 DHCP DNS
  --status            查看当前后端与 DNS
  --backend NAME      指定后端：nm、resolved、resolvconf、dhcpcd、dhclient、
                      netconfig、static
  --interface IFACE   指定网络接口（默认使用默认路由接口）
  -y, --yes           跳过确认
  -h, --help          显示帮助

示例：
  sudo ./dns-manager.sh --set "1.1.1.1,8.8.8.8"
  sudo ./dns-manager.sh --set "2606:4700:4700::1111 1.1.1.1"
  sudo ./dns-manager.sh --restore
EOF
}

service_active() {
    have systemctl && systemctl is-active --quiet "$1" 2>/dev/null
}

default_iface() {
    if have ip; then
        ip -4 route show default 2>/dev/null |
            awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
    fi
}

detect_backend() {
    if [[ -n "${BACKEND}" ]]; then
        case "${BACKEND}" in
            nm|resolved|resolvconf|dhcpcd|dhclient|netconfig|static) return ;;
            *) die "未知后端：${BACKEND}" ;;
        esac
    fi

    if have nmcli && service_active NetworkManager; then
        BACKEND="nm"
    elif have resolvectl && service_active systemd-resolved; then
        BACKEND="resolved"
    elif have dhcpcd && { service_active dhcpcd || { have pgrep && pgrep -f '^(/[^ ]*/)?dhcpcd([[:space:]:]|$)' >/dev/null 2>&1; }; }; then
        BACKEND="dhcpcd"
    elif have resolvconf && { [[ -d /etc/resolvconf ]] || [[ -f /etc/resolvconf.conf ]]; }; then
        BACKEND="resolvconf"
    elif [[ -f /etc/dhcp/dhclient.conf ]] || [[ -f /etc/dhclient.conf ]] || have dhclient; then
        BACKEND="dhclient"
    elif have netconfig && [[ -f /etc/sysconfig/network/config ]]; then
        BACKEND="netconfig"
    else
        BACKEND="static"
    fi
}

backend_label() {
    case "$1" in
        nm)          printf 'NetworkManager' ;;
        resolved)    printf 'systemd-resolved' ;;
        resolvconf)  printf 'resolvconf/openresolv' ;;
        dhcpcd)      printf 'dhcpcd' ;;
        dhclient)    printf 'dhclient' ;;
        netconfig)   printf 'SUSE netconfig' ;;
        static)      printf '静态 /etc/resolv.conf' ;;
    esac
}

require_root() {
    (( EUID == 0 )) && return
    if have sudo; then
        info "需要管理员权限，正在通过 sudo 重新运行。"
        exec sudo -- "$0" "${ORIGINAL_ARGS[@]}"
    fi
    die "此操作需要 root 权限，请使用 sudo 运行。"
}

acquire_lock() {
    mkdir -p /run 2>/dev/null || true
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        die "已有另一个 dns-manager 实例在运行。"
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

is_ipv4() {
    local ip=$1 a b c d extra octet
    IFS=. read -r a b c d extra <<< "$ip"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_ipv6() {
    local ip=$1
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    if have python3; then
        python3 - "$ip" >/dev/null 2>&1 <<'PY'
import ipaddress, sys
if ipaddress.ip_address(sys.argv[1]).version != 6:
    raise SystemExit(1)
PY
    elif have perl; then
        perl -MSocket -e 'exit defined(Socket::inet_pton(Socket::AF_INET6(), $ARGV[0])) ? 0 : 1' "$ip" \
            >/dev/null 2>&1
    else
        [[ "$ip" != *:::* ]]
    fi
}

normalize_dns() {
    local raw=$1 token normalized="" seen=" "
    raw=${raw//,/ }
    raw=${raw//;/ }
    for token in $raw; do
        if ! is_ipv4 "$token" && ! is_ipv6 "$token"; then
            die "无效的 IP 地址：${token}（仅接受 DNS 服务器 IP，不接受域名）"
        fi
        if [[ "$seen" != *" $token "* ]]; then
            normalized+="${normalized:+ }$token"
            seen+="$token "
        fi
    done
    [[ -n "$normalized" ]] || die "至少需要输入一个 DNS 地址。"
    printf '%s\n' "$normalized"
}

split_dns() {
    local dns=$1 token
    DNS_V4=""; DNS_V6=""
    for token in $dns; do
        if is_ipv4 "$token"; then
            DNS_V4+="${DNS_V4:+ }$token"
        else
            DNS_V6+="${DNS_V6:+ }$token"
        fi
    done
}

confirm() {
    local prompt=$1 answer
    (( ASSUME_YES == 1 )) && return 0
    read -r -p "$prompt [Y/n] " answer || return 1
    case "${answer,,}" in
        ""|y|yes) return 0 ;;
        *)        return 1 ;;
    esac
}

snapshot_init() {
    mkdir -p "${SNAPSHOT_DIR}/root"
    if [[ ! -e "${SNAPSHOT_DIR}/created_at" ]]; then
        date -u '+%Y-%m-%dT%H:%M:%SZ' > "${SNAPSHOT_DIR}/created_at"
        : > "${SNAPSHOT_DIR}/manifest"
    fi
    printf '%s\n' "${BACKEND}" > "${SNAPSHOT_DIR}/backend"
}

snapshot_file() {
    local path=$1 dest
    mkdir -p "${SNAPSHOT_DIR}/root$(dirname "$path")"
    grep -Fqx "E	$path" "${SNAPSHOT_DIR}/manifest" 2>/dev/null && return
    grep -Fqx "N	$path" "${SNAPSHOT_DIR}/manifest" 2>/dev/null && return

    if [[ -e "$path" || -L "$path" ]]; then
        dest="${SNAPSHOT_DIR}/root$path"
        cp -a -- "$path" "$dest"
        printf 'E\t%s\n' "$path" >> "${SNAPSHOT_DIR}/manifest"
    else
        printf 'N\t%s\n' "$path" >> "${SNAPSHOT_DIR}/manifest"
    fi
}

restore_snapshot_files() {
    local state path source
    [[ -f "${SNAPSHOT_DIR}/manifest" ]] || return 1
    while IFS=$'\t' read -r state path; do
        [[ "$path" == /* && "$path" != "/" ]] || die "备份清单包含不安全路径：$path"
        source="${SNAPSHOT_DIR}/root$path"
        if [[ "$state" == "E" ]]; then
            [[ -e "$source" || -L "$source" ]] || die "备份文件缺失，已停止恢复并保留快照：$path"
            mkdir -p "$(dirname "$path")" || return 1
            rm -f -- "$path" || return 1
            cp -a -- "$source" "$path" || return 1
        elif [[ "$state" == "N" ]]; then
            rm -f -- "$path" || return 1
        else
            die "备份清单包含未知状态：$state"
        fi
    done < "${SNAPSHOT_DIR}/manifest"
}

archive_snapshot() {
    local stamp archive
    [[ -d "${SNAPSHOT_DIR}" ]] || return
    stamp=$(date '+%Y%m%d-%H%M%S')
    archive="${STATE_DIR}/restored-$stamp"
    mv "${SNAPSHOT_DIR}" "$archive"
    info "修改前快照已归档到 $archive"
}

remove_managed_block() {
    local file=$1 tmp
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp)
    awk -v begin="${MARK_BEGIN}" -v end="${MARK_END}" '
        $0 == begin {skip=1; next}
        $0 == end   {skip=0; next}
        !skip {print}
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

write_managed_block() {
    local file=$1 body=$2
    mkdir -p "$(dirname "$file")"
    touch "$file"
    remove_managed_block "$file"
    {
        printf '\n%s\n' "${MARK_BEGIN}"
        printf '%s\n' "$body"
        printf '%s\n' "${MARK_END}"
    } >> "$file"
}

render_resolv_conf() {
    local dns=$1 token
    printf '# Generated by dns-manager.sh; use --restore to revert.\n'
    for token in $dns; do
        printf 'nameserver %s\n' "$token"
    done
    printf 'options timeout:2 attempts:2\n'
}

write_resolv_conf() {
    local dns=$1 tmp
    tmp=$(mktemp)
    render_resolv_conf "$dns" > "$tmp"
    rm -f "$RESOLV_CONF"
    cat "$tmp" > "$RESOLV_CONF"
    chmod 0644 "$RESOLV_CONF"
    rm -f "$tmp"
}

apply_dhcpcd() {
    local dns=$1 body
    IFACE=${IFACE:-$(default_iface)}
    [[ "$IFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "无法识别有效网络接口，请使用 --interface 指定。"
    if [[ -f "$DHCPCD_EXIT_HOOK_FILE" ]]; then
        sh -n "$DHCPCD_EXIT_HOOK_FILE" || die "现有 dhcpcd 退出钩子存在语法错误，已放弃修改。"
    fi
    snapshot_init
    snapshot_file "$DHCPCD_EXIT_HOOK_FILE"
    snapshot_file "$RESOLV_CONF"
    # exit-hook 每次网络事件都会重新加载，无需续租、重启 dhcpcd 或重启网络。
    # 用子 shell 隔离临时变量和清理 trap，保留用户已有的钩子内容。
    body=$(cat <<EOF
if [ "\${interface:-}" = "$IFACE" ]; then
    (
        umask 022
        _dns_manager_tmp=\$(mktemp "$RESOLV_CONF.dns-manager.XXXXXX") || exit 1
        trap 'rm -f "\$_dns_manager_tmp"' EXIT HUP INT TERM
        cat > "\$_dns_manager_tmp" <<'DNS_MANAGER_RESOLV'
$(render_resolv_conf "$dns")
DNS_MANAGER_RESOLV
        chmod 0644 "\$_dns_manager_tmp" && mv -f "\$_dns_manager_tmp" "$RESOLV_CONF"
    )
fi
EOF
)
    write_managed_block "$DHCPCD_EXIT_HOOK_FILE" "$body"
    sh -n "$DHCPCD_EXIT_HOOK_FILE" || die "dhcpcd 退出钩子语法校验失败，请使用 --restore 恢复。"
    write_resolv_conf "$dns"
}

nm_uuid() {
    local iface=$1 uuid
    uuid=$(nmcli -g GENERAL.CON-UUID device show "$iface" 2>/dev/null | head -n1 || true)
    if [[ -z "$uuid" || "$uuid" == "--" ]]; then
        uuid=$(nmcli -g UUID connection show --active 2>/dev/null | head -n1 || true)
    fi
    printf '%s\n' "$uuid"
}

nm_save_original() {
    local uuid=$1 dir="${SNAPSHOT_DIR}/nm/$1"
    [[ -f "$dir/saved" ]] && return
    mkdir -p "$dir"
    nmcli -g ipv4.ignore-auto-dns connection show "$uuid" > "$dir/v4_ignore"
    nmcli -g ipv4.dns connection show "$uuid" > "$dir/v4_dns"
    nmcli -g ipv6.ignore-auto-dns connection show "$uuid" > "$dir/v6_ignore"
    nmcli -g ipv6.dns connection show "$uuid" > "$dir/v6_dns"
    printf '%s\n' "${IFACE}" > "$dir/interface"
    : > "$dir/saved"
}

apply_nm() {
    local dns=$1 uuid
    IFACE=${IFACE:-$(default_iface)}
    [[ -n "$IFACE" ]] || die "无法识别默认网络接口，请使用 --interface 指定。"
    uuid=$(nm_uuid "$IFACE")
    [[ -n "$uuid" ]] || die "无法找到接口 $IFACE 对应的 NetworkManager 连接。"

    snapshot_init
    nm_save_original "$uuid"
    split_dns "$dns"

    nmcli connection modify "$uuid" \
        ipv4.ignore-auto-dns yes ipv4.dns "$DNS_V4" \
        ipv6.ignore-auto-dns yes ipv6.dns "$DNS_V6"

    nmcli general reload >/dev/null 2>&1 || true
    if ! nmcli device reapply "$IFACE" >/dev/null 2>&1; then
        warn "配置已永久保存，但当前连接无法热重载；重连网络或重启后生效。"
    fi
}

restore_nm_settings() {
    local dir uuid iface v4i v4d v6i v6d restored=0
    [[ -d "${SNAPSHOT_DIR}/nm" ]] || return 1
    for dir in "${SNAPSHOT_DIR}"/nm/*; do
        [[ -f "$dir/saved" ]] || continue
        uuid=${dir##*/}
        v4i=$(<"$dir/v4_ignore"); v4d=$(<"$dir/v4_dns")
        v6i=$(<"$dir/v6_ignore"); v6d=$(<"$dir/v6_dns")
        iface=$(<"$dir/interface")
        nmcli connection modify "$uuid" \
            ipv4.ignore-auto-dns "$v4i" ipv4.dns "$v4d" \
            ipv6.ignore-auto-dns "$v6i" ipv6.dns "$v6d" || true
        nmcli device reapply "$iface" >/dev/null 2>&1 || true
        restored=1
    done
    (( restored == 1 ))
}

apply_resolved() {
    local dns=$1 file="/etc/systemd/resolved.conf.d/90-dns-manager.conf"
    snapshot_init
    snapshot_file "$file"
    snapshot_file "$RESOLV_CONF"
    mkdir -p /etc/systemd/resolved.conf.d
    {
        printf '[Resolve]\nDNS=%s\nFallbackDNS=\nDomains=~.\n' "$dns"
    } > "$file"
    systemctl restart systemd-resolved
    if [[ ! -L "$RESOLV_CONF" ]] && ! grep -Eq '^nameserver[[:space:]]+127\.0\.0\.53' "$RESOLV_CONF" 2>/dev/null; then
        warn "/etc/resolv.conf 未使用 systemd-resolved stub，额外写入静态解析器。"
        write_resolv_conf "$dns"
    fi
}

dhclient_conf_path() {
    if [[ -f /etc/dhcp/dhclient.conf || -d /etc/dhcp ]]; then
        printf '/etc/dhcp/dhclient.conf\n'
    else
        printf '/etc/dhclient.conf\n'
    fi
}

apply_dhclient() {
    local dns=$1 file body="" csv4="" csv6=""
    file=$(dhclient_conf_path)
    split_dns "$dns"
    [[ -n "$DNS_V4" ]] && csv4=${DNS_V4// /, }
    [[ -n "$DNS_V6" ]] && csv6=${DNS_V6// /, }

    [[ -n "$csv4" ]] && body+="# 永久覆盖 DHCPv4 下发的 DNS。"$'\n'"supersede domain-name-servers $csv4;"
    [[ -n "$csv6" ]] && body+=${body:+$'\n'}"# 永久覆盖 DHCPv6 下发的 DNS。"$'\n'"supersede dhcp6.name-servers $csv6;"

    snapshot_init
    snapshot_file "$file"
    snapshot_file "$RESOLV_CONF"
    write_managed_block "$file" "$body"
    write_resolv_conf "$dns"
}

resolvconf_head_path() {
    if [[ -d /etc/resolvconf/resolv.conf.d ]]; then
        printf '/etc/resolvconf/resolv.conf.d/head\n'
    else
        printf '/etc/resolvconf.conf\n'
    fi
}

install_resolvconf_hook() {
    # Debian resolvconf 的 update-libc.d 仅在 libc 输出变化后运行；放在
    # update.d 末尾才能保证首次设置和内容未变化时也执行。
    rm -- "$RESOLVCONF_LEGACY_HOOK_FILE" 2>/dev/null || true
    mkdir -p "$(dirname "$RESOLVCONF_HOOK_FILE")"
    cat > "$RESOLVCONF_HOOK_FILE" <<'HOOK'
#!/bin/sh
# 由 dns-manager.sh 管理：保留 search/options 等内容，仅覆盖 nameserver。
set -eu

STATE_FILE="/var/lib/dns-manager/resolvconf.nameservers"
TARGET="/run/resolvconf/resolv.conf"

[ -s "$STATE_FILE" ] || exit 0
[ -f "$TARGET" ] || exit 0

tmp=$(mktemp "${TARGET}.dns-manager.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM

awk -v state="$STATE_FILE" '
    function emit_nameservers(    dns) {
        while ((getline dns < state) > 0) {
            if (dns != "") print "nameserver " dns
        }
        close(state)
    }
    /^[[:space:]]*nameserver[[:space:]]+/ {
        if (!inserted) {
            emit_nameservers()
            inserted=1
        }
        next
    }
    !inserted && /^[[:space:]]*(search|domain|options|sortlist)[[:space:]]+/ {
        emit_nameservers()
        inserted=1
    }
    { print }
    END {
        if (!inserted) emit_nameservers()
    }
' "$TARGET" > "$tmp"

chmod --reference="$TARGET" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
chown --reference="$TARGET" "$tmp" 2>/dev/null || true
mv -f "$tmp" "$TARGET"
trap - EXIT HUP INT TERM
HOOK
    chmod 0755 "$RESOLVCONF_HOOK_FILE"
}

apply_resolvconf() {
    local dns=$1 file token body="" tmp
    file=$(resolvconf_head_path)
    snapshot_init
    snapshot_file "$file"
    snapshot_file "$RESOLV_CONF"

    if [[ "$file" == "/etc/resolvconf.conf" ]]; then
        body="name_servers=\"$dns\""
        write_managed_block "$file" "$body"
    else
        snapshot_file "$RESOLVCONF_STATE_FILE"
        snapshot_file "$RESOLVCONF_HOOK_FILE"
        snapshot_file "$RESOLVCONF_LEGACY_HOOK_FILE"

        # 迁移 1.0.0：head 会绕过去重逻辑，必须清除旧管理块。
        remove_managed_block "$file"

        mkdir -p "$STATE_DIR"
        tmp=$(mktemp "${STATE_DIR}/resolvconf.nameservers.XXXXXX")
        for token in $dns; do printf '%s\n' "$token"; done > "$tmp"
        chmod 0644 "$tmp"
        mv -f "$tmp" "$RESOLVCONF_STATE_FILE"

        install_resolvconf_hook
    fi

    resolvconf -u
}

set_shell_key() {
    local file=$1 key=$2 value=$3 tmp
    tmp=$(mktemp)
    awk -v key="$key" -v value="$value" '
        BEGIN {done=0}
        $0 ~ "^[[:space:]]*" key "=" {
            if (!done) print key "=\"" value "\""
            done=1
            next
        }
        {print}
        END {if (!done) print key "=\"" value "\""}
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

apply_netconfig() {
    local dns=$1 file="/etc/sysconfig/network/config"
    snapshot_init
    snapshot_file "$file"
    snapshot_file "$RESOLV_CONF"
    set_shell_key "$file" NETCONFIG_DNS_STATIC_SERVERS "$dns"
    set_shell_key "$file" NETCONFIG_DNS_POLICY "STATIC"
    netconfig update -f
}

apply_static() {
    local dns=$1
    snapshot_init
    snapshot_file "$RESOLV_CONF"
    warn "未检测到受支持的网络管理器，将直接管理 /etc/resolv.conf。"
    warn "某些 DHCP 客户端仍可能覆盖它；建议使用系统原生网络管理器。"
    write_resolv_conf "$dns"
}

apply_dns() {
    local dns=$1
    detect_backend
    info "使用后端：$(backend_label "$BACKEND")"
    case "$BACKEND" in
        nm)         apply_nm "$dns" ;;
        resolved)   apply_resolved "$dns" ;;
        resolvconf) apply_resolvconf "$dns" ;;
        dhcpcd)     apply_dhcpcd "$dns" ;;
        dhclient)   apply_dhclient "$dns" ;;
        netconfig)  apply_netconfig "$dns" ;;
        static)     apply_static "$dns" ;;
    esac
    verify_dns "$dns"
}

reload_after_restore() {
    local backend=$1
    case "$backend" in
        nm)
            restore_nm_settings || true
            nmcli general reload >/dev/null 2>&1 || true
            ;;
        resolved)
            systemctl restart systemd-resolved 2>/dev/null || true
            ;;
        resolvconf)
            resolvconf -u 2>/dev/null || true
            ;;
        netconfig)
            netconfig update -f 2>/dev/null || true
            ;;
        dhcpcd|dhclient|static)
            ;;
    esac
}

restore_dns() {
    local saved_backend=""
    if [[ -f "${SNAPSHOT_DIR}/backend" ]]; then
        saved_backend=$(<"${SNAPSHOT_DIR}/backend")
    fi

    if [[ -f "${SNAPSHOT_DIR}/manifest" || -d "${SNAPSHOT_DIR}/nm" ]]; then
        [[ "$saved_backend" == "nm" ]] && restore_nm_settings || true
        restore_snapshot_files || die "配置恢复失败，已保留快照，请检查权限与备份文件。"
        reload_after_restore "$saved_backend"
        archive_snapshot
        ok "已恢复脚本运行前的 DNS 配置。"
        return
    fi

    detect_backend
    warn "没有找到修改前快照，将仅清理 dns-manager 管理的配置。"
    case "$BACKEND" in
        nm)
            IFACE=${IFACE:-$(default_iface)}
            local uuid
            uuid=$(nm_uuid "$IFACE")
            [[ -n "$uuid" ]] && nmcli connection modify "$uuid" \
                ipv4.ignore-auto-dns no ipv4.dns "" \
                ipv6.ignore-auto-dns no ipv6.dns ""
            nmcli device reapply "$IFACE" >/dev/null 2>&1 || true
            ;;
        resolved)
            rm -f /etc/systemd/resolved.conf.d/90-dns-manager.conf
            systemctl restart systemd-resolved
            ;;
        resolvconf)
            remove_managed_block "$(resolvconf_head_path)"
            rm -- "$RESOLVCONF_HOOK_FILE" "$RESOLVCONF_LEGACY_HOOK_FILE" "$RESOLVCONF_STATE_FILE" 2>/dev/null || true
            resolvconf -u
            ;;
        dhclient)
            remove_managed_block "$(dhclient_conf_path)"
            warn "已恢复 DHCP DNS 策略；重新联网或重启后获取当前 DHCP DNS。"
            ;;
        dhcpcd)
            remove_managed_block "$DHCPCD_EXIT_HOOK_FILE"
            warn "已移除 dhcpcd DNS 钩子；下次 DHCP 续租或重启后获取自动 DNS。"
            ;;
        netconfig)
            warn "SUSE netconfig 无快照时不自动覆盖未知原配置。"
            ;;
        static)
            die "静态模式没有快照，无法安全推断原 DNS。"
            ;;
    esac
    ok "已清理 dns-manager 配置并恢复自动 DNS 策略。"
}

verify_dns() {
    local requested=$1 current="" unique=""
    if [[ -r "$RESOLV_CONF" ]]; then
        current=$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' "$RESOLV_CONF" |
            paste -sd' ' - 2>/dev/null || true)
        unique=$(awk '
            /^[[:space:]]*nameserver[[:space:]]+/ && !seen[$2]++ {
                list = list (list ? " " : "") $2
            }
            END {print list}
        ' "$RESOLV_CONF")
    fi
    printf '\n'
    info "请求的 DNS：$requested"
    info "/etc/resolv.conf：${current:-未直接列出（可能由本地 stub 管理）}"

    if [[ -n "$current" && "$current" != "$unique" ]]; then
        warn "/etc/resolv.conf 中存在重复的 nameserver。"
    fi
    if [[ "$BACKEND" == "resolvconf" && "$current" != "$requested" ]]; then
        die "resolvconf 最终结果与请求不一致，设置未成功。"
    fi

    if have getent && getent ahostsv4 example.com >/dev/null 2>&1; then
        ok "DNS 解析测试通过。"
    else
        warn "DNS 配置已写入，但解析测试未通过；请检查网络、防火墙或 DNS 可达性。"
    fi
    ok "DNS 修改完成，当前 DNS：${current:-未直接列出（可能由本地 stub 管理）}"
}

show_status() {
    local detected="" iface nameservers
    detect_backend
    detected=$(backend_label "$BACKEND")
    iface=${IFACE:-$(default_iface)}
    nameservers=$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' "$RESOLV_CONF" \
        2>/dev/null | paste -sd' ' - || true)

    printf '%sDNS Manager %s%s\n' "$C_BOLD" "$VERSION" "$C_RESET"
    printf '检测后端：%s\n' "$detected"
    printf '默认接口：%s\n' "${iface:-未知}"
    printf 'resolv.conf：%s\n' "${nameservers:-未直接列出}"
    printf '文件类型：'
    if [[ -L "$RESOLV_CONF" ]]; then
        printf '符号链接 -> %s\n' "$(readlink "$RESOLV_CONF")"
    else
        printf '普通文件\n'
    fi

    if [[ -f "${SNAPSHOT_DIR}/created_at" ]]; then
        printf '修改快照：%s（可恢复）\n' "$(<"${SNAPSHOT_DIR}/created_at")"
    else
        printf '修改快照：无\n'
    fi

    if have resolvectl && service_active systemd-resolved; then
        printf '\n'
        resolvectl dns 2>/dev/null || true
    fi
}

interactive_menu() {
    local choice raw dns
    while true; do
        detect_backend
        printf '\n%sDNS Manager %s%s\n' "$C_BOLD" "$VERSION" "$C_RESET"
        printf '检测到：%s\n\n' "$(backend_label "$BACKEND")"
        cat <<'EOF'
  1) 输入自定义 DNS
  2) Cloudflare   1.1.1.1 / 1.0.0.1
  3) Google       8.8.8.8 / 8.8.4.4
  4) CF + Google  1.1.1.1 / 8.8.8.8
  5) 国内公共 DNS 223.5.5.5 / 119.29.29.29
  6) 查看当前状态
  7) 恢复默认/自动 DNS
  0) 退出
EOF
        read -r -p "请选择 [0-7]：" choice
        case "$choice" in
            1)
                read -r -p "输入 DNS IP（多个用空格或逗号分隔）：" raw
                dns=$(normalize_dns "$raw")
                if confirm "确认永久设置为：${dns}？"; then
                    require_root "$@"; acquire_lock; apply_dns "$dns"
                    return
                fi
                ;;
            2) dns="1.1.1.1 1.0.0.1" ;;
            3) dns="8.8.8.8 8.8.4.4" ;;
            4) dns="1.1.1.1 8.8.8.8" ;;
            5) dns="223.5.5.5 119.29.29.29" ;;
            6) show_status; continue ;;
            7)
                if confirm "确认恢复脚本修改前的 DNS/自动 DHCP DNS？"; then
                    require_root "$@"; acquire_lock; restore_dns
                    return
                fi
                continue
                ;;
            0) exit 0 ;;
            *) warn "无效选项：$choice"; continue ;;
        esac

        if [[ "$choice" =~ ^[2-5]$ ]] && confirm "确认永久设置为：${dns}？"; then
            require_root "$@"; acquire_lock; apply_dns "$dns"
            return
        fi
    done
}

main() {
    while (($#)); do
        case "$1" in
            --set)
                (($# >= 2)) || die "--set 缺少 DNS 参数"
                ACTION="set"; DNS_ARGUMENT=$2; shift 2 ;;
            --restore)
                ACTION="restore"; shift ;;
            --status)
                ACTION="status"; shift ;;
            --backend)
                (($# >= 2)) || die "--backend 缺少参数"
                BACKEND=$2; shift 2 ;;
            --interface)
                (($# >= 2)) || die "--interface 缺少参数"
                IFACE=$2; shift 2 ;;
            -y|--yes)
                ASSUME_YES=1; shift ;;
            -h|--help)
                usage; exit 0 ;;
            --version)
                printf '%s\n' "$VERSION"; exit 0 ;;
            *)
                die "未知参数：$1（使用 --help 查看帮助）" ;;
        esac
    done

    case "$ACTION" in
        set)
            DNS_ARGUMENT=$(normalize_dns "$DNS_ARGUMENT")
            require_root "$@"
            acquire_lock
            apply_dns "$DNS_ARGUMENT"
            ;;
        restore)
            require_root "$@"
            acquire_lock
            restore_dns
            ;;
        status)
            show_status
            ;;
        "")
            interactive_menu
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
