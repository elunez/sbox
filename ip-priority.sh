#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

GAI_FILE=/etc/gai.conf
BEGIN_MARK='# BEGIN ip-priority managed'
END_MARK='# END ip-priority managed'
SAVED_PREFIX='# ip-priority saved: '
TMP_FILE=''

die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：sudo bash ip-priority.sh [ipv4|ipv6|restore|status]
  无参数   打开选择菜单
  ipv4     优先使用 IPv4
  ipv6     优先使用原生 IPv6
  restore  撤销本脚本设置，恢复原有优先级规则
  status   查看当前优先级配置（无需 root）

仅调整 glibc 的地址排序，不禁用 IPv4/IPv6，不修改 DNS 或路由。
应用自身的 DNS、代理或连接策略可能覆盖此设置；长驻进程可能需要重启。
EOF
}

check_config() {
  [[ ! -L "$GAI_FILE" ]] || die "$GAI_FILE 是符号链接，请先人工检查。"
  [[ ! -e "$GAI_FILE" || -f "$GAI_FILE" ]] || die "$GAI_FILE 不是普通文件。"
  [[ ! -e "$GAI_FILE" || -r "$GAI_FILE" ]] || die "无法读取 $GAI_FILE。"
  [[ -e "$GAI_FILE" ]] || return 0
  # 标记损坏时停止，避免误删其他配置。
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v saved="$SAVED_PREFIX" '
    $0 == begin { if (inside || seen++) exit 1; inside = 1; next }
    $0 == end { if (!inside) exit 1; inside = 0; next }
    index($0, saved) == 1 {
      if (inside || substr($0, length(saved) + 1) !~ /^[[:space:]]*precedence[[:space:]]/) exit 1
      suspended = 1
    }
    END { if (inside || (suspended && !seen)) exit 1 }
  ' "$GAI_FILE" || die '脚本管理标记不完整，请先根据备份人工检查 gai.conf。'
}

show_status() {
  check_config
  if [[ ! -e "$GAI_FILE" ]]; then
    printf '未设置优先级，使用 glibc 默认地址排序（通常优先原生 IPv6）。\n'
    return
  fi
  printf '当前配置：%s\n' "$GAI_FILE"
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    inside && /^# mode: / { print "本脚本模式：" substr($0, 9) }
    /^[[:space:]]*precedence[[:space:]]/ { print; found = 1 }
    END { if (!found) print "无自定义 precedence，使用 glibc 默认地址排序（通常优先原生 IPv6）。" }
  ' "$GAI_FILE"
  printf '以上为配置状态，不代表实际网络连通性或应用最终选择。\n'
}

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then rm -f -- "$TMP_FILE"; fi
}

set_priority() {
  local mode=$1 backup input=/dev/null ipv4_value=10
  case "$mode" in ipv4|ipv6|restore) ;; *) die "未知模式：$mode" ;; esac
  check_config
  if [[ "$mode" == restore ]] && { [[ ! -e "$GAI_FILE" ]] || ! grep -Fxq "$BEGIN_MARK" "$GAI_FILE"; }; then
    printf '没有本脚本设置，无需恢复。\n'
    return
  fi

  TMP_FILE=$(mktemp "${GAI_FILE}.tmp.XXXXXXXX")
  if [[ -e "$GAI_FILE" ]]; then
    input=$GAI_FILE
    cp -p -- "$GAI_FILE" "$TMP_FILE"
  else
    chmod 644 "$TMP_FILE"
  fi
  # 先撤销上次设置，再暂存现有 precedence；其余规则和注释保持原样。
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v saved="$SAVED_PREFIX" -v mode="$mode" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    inside { next }
    {
      line = $0
      if (index(line, saved) == 1) line = substr(line, length(saved) + 1)
      if (mode != "restore" && line ~ /^[[:space:]]*precedence[[:space:]]/) line = saved line
      print line
    }
  ' "$input" > "$TMP_FILE"

  if [[ "$mode" != restore ]]; then
    [[ "$mode" != ipv4 ]] || ipv4_value=100
    # 完整采用 glibc gai.conf 的默认表，只在 IPv4 模式提高映射地址的优先级。
    cat >> "$TMP_FILE" <<EOF
$BEGIN_MARK
# mode: $mode
precedence ::1/128       50
precedence ::/0          40
precedence 2002::/16     30
precedence ::/96         20
precedence ::ffff:0:0/96 $ipv4_value
$END_MARK
EOF
  fi

  if [[ -e "$GAI_FILE" ]] && cmp -s -- "$GAI_FILE" "$TMP_FILE"; then
    cleanup
    TMP_FILE=''
    printf '已经是所选配置，无需修改。\n'
    return
  fi
  if [[ -e "$GAI_FILE" ]]; then
    backup=$(mktemp "${GAI_FILE}.bak.XXXXXXXX")
    cp -p -- "$GAI_FILE" "$backup"
    printf '修改前备份：%s\n' "$backup"
  fi
  mv -f -- "$TMP_FILE" "$GAI_FILE"
  TMP_FILE=''
  printf '已完成：%s。长驻应用可能需要重启；无需重启网络或系统。\n' "$mode"
  show_status
}

main() {
  local mode=${1:-} choice os_id
  [[ $# -le 1 ]] || die '参数过多，使用 --help 查看用法。'
  case "$mode" in -h|--help|help) usage; return ;; esac
  [[ -r /etc/os-release ]] || die '无法识别系统，仅支持 Debian 及其衍生系统。'
  os_id=$(. /etc/os-release; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
  [[ " $os_id " == *' debian '* ]] || die '仅支持 Debian 及其衍生系统。'
  case "$mode" in ''|ipv4|ipv6|restore|status) ;; *) die '未知参数，使用 --help 查看用法。' ;; esac
  if [[ -z "$mode" ]]; then
    show_status
    printf '\n1. IPv4 优先\n2. IPv6 优先\n3. 恢复原设置\n0. 退出\n请选择 [0-3]：'
    if [[ -t 0 ]]; then
      read -r choice || return 0
    else
      read -r choice < /dev/tty || die '无法读取终端，请明确指定 ipv4、ipv6 或 restore。'
    fi
    case "$choice" in
      1) mode=ipv4 ;; 2) mode=ipv6 ;; 3) mode=restore ;; 0) return ;;
      *) die '无效选择，未修改配置。' ;;
    esac
  fi
  if [[ "$mode" == status ]]; then show_status; return; fi
  [[ $EUID -eq 0 ]] || die '修改配置需要 root 权限，请使用 sudo bash ip-priority.sh。'
  command -v flock >/dev/null 2>&1 || die '缺少 flock（Debian util-linux），未修改配置。'
  exec 9>/run/lock/ip-priority.lock
  flock -n 9 || die '另一个脚本实例正在修改配置，请稍后再试。'
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  set_priority "$mode"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
