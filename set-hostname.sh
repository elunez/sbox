#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HOSTNAME_FILE=/etc/hostname
HOSTS_FILE=/etc/hosts
HOSTNAME_TMP=''
HOSTS_TMP=''
OLD_RUNTIME=''
OLD_HOSTNAME=''
OLD_HOSTS=''
HAD_HOSTNAME=0
HAD_HOSTS=0
TRANSACTION=0

die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：sudo bash set-hostname.sh [新主机名]
      bash set-hostname.sh --status

无参数时显示当前名称并提示输入；直接回车退出。
支持小写字母、数字、连字符和点分隔的域名，总长度不超过 64 字符。
同步修改运行时主机名、/etc/hostname 和 /etc/hosts 的 127.0.1.1 记录。
不生成备份文件，不修改 DNS、云平台配置或重启网络。
EOF
}

validate_hostname() {
  local name=$1 label LC_ALL=C
  local -a labels
  [[ -n "$name" && ${#name} -le 64 ]] || die '主机名长度必须为 1–64 字符。'
  [[ "$name" =~ ^[a-z0-9.-]+$ ]] || die '主机名仅允许小写字母、数字、连字符和点。'
  [[ "$name" != .* && "$name" != *. && "$name" != *..* ]] || die '主机名不能以点开头、结尾或包含连续的点。'
  [[ ! "$name" =~ ^[0-9.]+$ ]] || die '主机名不能是纯数字或 IP 地址。'
  [[ "$name" != localhost && "$name" != localhost.localdomain ]] || die '请勿使用保留名称 localhost。'
  IFS=. read -r -a labels <<< "$name"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die '每段名称仅允许小写字母、数字和中间的连字符，最长 63 字符。'
  done
}

check_file() {
  [[ ! -L "$1" ]] || die "$1 是符号链接，请先人工检查。"
  [[ ! -e "$1" || ( -f "$1" && -r "$1" ) ]] || die "无法读取普通文件 $1。"
}

show_status() {
  printf '当前运行时主机名：%s\n' "$(hostname)"
  if [[ -r "$HOSTNAME_FILE" ]]; then
    printf '持久主机名：'
    cat -- "$HOSTNAME_FILE"
    printf '\n'
  else
    printf '尚无可读取的 %s。\n' "$HOSTNAME_FILE"
  fi
}

render_hosts() {
  local new=$1 old_static=$2 input=/dev/null
  if [[ -e "$HOSTS_FILE" ]]; then input=$HOSTS_FILE; fi
  awk -v name="$new" -v runtime="$OLD_RUNTIME" -v static="$old_static" '
    function short(value, pieces) { split(value, pieces, "."); return pieces[1] }
    function obsolete(value) {
      value = tolower(value)
      if (value == "localhost" || value == "ip6-localhost" || value == "ip6-loopback") return 0
      return value == tolower(runtime) || value == short(tolower(runtime)) ||
             value == tolower(static) || value == short(tolower(static)) ||
             value == name || value == short(name)
    }
    BEGIN { names = name; if (short(name) != name) names = names " " short(name) }
    /^[[:space:]]*127[.]0[.]1[.]1[[:space:]]/ {
      comment = ""; line = $0; pos = index(line, "#")
      if (pos) { comment = substr(line, pos); line = substr(line, 1, pos - 1) }
      sub(/^[[:space:]]+/, "", line)
      count = split(line, fields, /[[:space:]]+/); aliases = ""
      for (i = 2; i <= count; i++)
        if (fields[i] != "" && !obsolete(fields[i])) aliases = aliases " " fields[i]
      if (!found++) print "127.0.1.1\t" names aliases (comment != "" ? " " comment : "")
      else if (aliases != "") print "127.0.1.1\t" substr(aliases, 2) (comment != "" ? " " comment : "")
      else if (comment != "") print comment
      next
    }
    { print }
    END { if (!found) print "127.0.1.1\t" names }
  ' "$input"
}

finish() {
  local code=$1 failed=0
  trap - EXIT INT TERM
  if [[ $TRANSACTION -eq 1 ]]; then
    # 旧内容仅保存在内存中；失败时尽力回滚，不落盘备份。
    if [[ $HAD_HOSTNAME -eq 1 ]]; then
      printf '%s' "$OLD_HOSTNAME" > "$HOSTNAME_FILE" || failed=1
    else
      rm -f -- "$HOSTNAME_FILE" || failed=1
    fi
    if [[ $HAD_HOSTS -eq 1 ]]; then
      printf '%s' "$OLD_HOSTS" > "$HOSTS_FILE" || failed=1
    else
      rm -f -- "$HOSTS_FILE" || failed=1
    fi
    hostname "$OLD_RUNTIME" || failed=1
    if [[ $failed -eq 0 ]]; then
      printf '[错误] 修改失败，已回滚本次修改。\n' >&2
    else
      printf '[错误] 修改失败，回滚未完全成功，请检查 hostname、/etc/hostname 和 /etc/hosts。\n' >&2
    fi
    [[ $code -ne 0 ]] || code=1
  fi
  if [[ -n "$HOSTNAME_TMP" ]]; then rm -f -- "$HOSTNAME_TMP"; fi
  if [[ -n "$HOSTS_TMP" ]]; then rm -f -- "$HOSTS_TMP"; fi
  exit "$code"
}

change_hostname() {
  local new=$1 old_static=''
  validate_hostname "$new"
  check_file "$HOSTNAME_FILE"
  check_file "$HOSTS_FILE"
  OLD_RUNTIME=$(hostname)
  if [[ -e "$HOSTNAME_FILE" ]]; then
    HAD_HOSTNAME=1
    # 用末尾哨兵避免命令替换丢失原文件的换行。
    OLD_HOSTNAME=$(cat -- "$HOSTNAME_FILE" && printf '.')
    OLD_HOSTNAME=${OLD_HOSTNAME%.}
    old_static=$(awk '!/^[[:space:]]*(#|$)/ { print $1; exit }' "$HOSTNAME_FILE")
  fi
  if [[ -e "$HOSTS_FILE" ]]; then
    HAD_HOSTS=1
    OLD_HOSTS=$(cat -- "$HOSTS_FILE" && printf '.')
    OLD_HOSTS=${OLD_HOSTS%.}
  fi
  HOSTNAME_TMP=$(mktemp "${HOSTNAME_FILE}.tmp.XXXXXXXX")
  HOSTS_TMP=$(mktemp "${HOSTS_FILE}.tmp.XXXXXXXX")
  if [[ $HAD_HOSTNAME -eq 1 ]]; then cp -p -- "$HOSTNAME_FILE" "$HOSTNAME_TMP"; else chmod 644 "$HOSTNAME_TMP"; fi
  if [[ $HAD_HOSTS -eq 1 ]]; then cp -p -- "$HOSTS_FILE" "$HOSTS_TMP"; else chmod 644 "$HOSTS_TMP"; fi
  printf '%s\n' "$new" > "$HOSTNAME_TMP"
  if [[ $HAD_HOSTS -eq 0 ]]; then
    printf '127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost ip6-loopback\n' > "$HOSTS_TMP"
    render_hosts "$new" "$old_static" >> "$HOSTS_TMP"
  else
    render_hosts "$new" "$old_static" > "$HOSTS_TMP"
  fi
  if [[ "$OLD_RUNTIME" == "$new" ]] && cmp -s -- "$HOSTNAME_TMP" "$HOSTNAME_FILE" && cmp -s -- "$HOSTS_TMP" "$HOSTS_FILE"; then
    printf '已经是所选主机名，配置无需修改。\n'
    return
  fi

  TRANSACTION=1
  hostname "$new"
  mv -f -- "$HOSTS_TMP" "$HOSTS_FILE"
  HOSTS_TMP=''
  mv -f -- "$HOSTNAME_TMP" "$HOSTNAME_FILE"
  HOSTNAME_TMP=''
  [[ "$(hostname)" == "$new" && "$(cat -- "$HOSTNAME_FILE")" == "$new" ]] || die '主机名校验失败。'
  TRANSACTION=0
  printf '主机名已修改：%s → %s。未生成备份文件。\n' "$OLD_RUNTIME" "$new"
  printf '无需重启；已有终端请重新登录以刷新提示符。\n'
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    printf '检测到 cloud-init 配置目录；若云平台管理主机名或 hosts，后续启动可能覆盖这些设置，请同步核对云平台及 cloud-init 配置。\n'
  fi
}

main() {
  local name=${1:-} os_id
  [[ $# -le 1 ]] || die '参数过多，使用 --help 查看用法。'
  case "$name" in -h|--help) usage; return ;; esac
  [[ -r /etc/os-release ]] || die '无法识别系统，仅支持 Debian 及其衍生系统。'
  os_id=$(. /etc/os-release; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
  [[ " $os_id " == *' debian '* ]] || die '仅支持 Debian 及其衍生系统。'
  command -v hostname >/dev/null 2>&1 || die '缺少 hostname 命令，未修改配置。'
  if [[ "$name" == --status ]]; then show_status; return; fi
  if [[ -z "$name" ]]; then
    show_status
    printf '请输入新主机名（直接回车退出）：'
    if [[ -t 0 ]]; then
      read -r name || return 0
    else
      read -r name < /dev/tty || die '无法读取终端，请通过参数指定新主机名。'
    fi
    [[ -n "$name" ]] || return 0
  fi
  validate_hostname "$name"
  [[ $EUID -eq 0 ]] || die '修改配置需要 root 权限，请使用 sudo bash set-hostname.sh。'
  command -v flock >/dev/null 2>&1 || die '缺少 flock（Debian util-linux），未修改配置。'
  exec 9>/run/lock/set-hostname.lock
  flock -n 9 || die '另一个脚本实例正在修改主机名，请稍后再试。'
  trap 'finish $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  change_hostname "$name"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
