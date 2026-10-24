#!/usr/bin/env bash
# IP 被墙检测：定时检测国内目标的连通性，全部不通时调用接口更换 IP，使用说明见 README.md
set -euo pipefail

BIN=/usr/local/bin/check-ip
CONFIG_FILE=${CHECK_IP_CONFIG:-/etc/check-ip.conf}
UNIT_DIR=/etc/systemd/system
JOURNAL_CONF=/etc/systemd/journald@check-ip.conf
PING_COUNT=10
PING_TIMEOUT=1
TCP_TIMEOUT=3
# 配置行格式：KEY=VALUE，值可加双引号，行尾可加 # 注释；SKIP 为可忽略的空行与注释行
PAIR='^([A-Z0-9_]+)="?([^"#[:space:]]*)"?[[:space:]]*(#.*)?$'
SKIP='^[[:space:]]*(#|$)'
# 检测目标：IP 每段 0-255，端口 1-65535
OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
PORT='([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])'
TARGET="$OCTET(\.$OCTET){3}:$PORT"
TARGETS_RE="^$TARGET(,$TARGET)*$"
# 接口地址经 curl 配置的双引号传递，不允许双引号、反斜杠与 #
API_RE='^https?://[^"#\\]+$'
RETRY_RE='^([1-9]|1[0-9]|20)$'
INTERVAL_RE='^([1-9][0-9]{0,2}|1[0-3][0-9]{2}|14[0-3][0-9]|1440)$'

log() { echo "[$(date '+%F %T')] $*" >&2; }
die() { log "$*"; exit 1; }

# 配置模板，每项为「配置项|默认值|说明」；新装与更新都按它生成配置文件
TEMPLATE=(
    'CHECK_TARGETS|223.5.5.5:443,119.29.29.29:80|检测目标「IP:TCP 端口」，多个用英文逗号分隔；任一目标 ping 通或端口可连接即判定正常'
    'CHANGE_IP_API||更换 IP 的接口地址（服务商提供），请求该地址即更换 IP'
    'MAX_RETRY|5|所有目标都不通时最多连续更换 IP 的次数（1-20）'
    'INTERVAL_MINUTES|1|执行间隔（分钟，1-1440），修改后执行 check-ip install 生效'
)

# 按模板输出配置文件内容，配置值取自 CFG_<配置项>
render_config() {
    local entry key default comment value
    for entry in "${TEMPLATE[@]}"; do
        IFS='|' read -r key default comment <<<"$entry"
        value=CFG_$key
        printf '%-22s # %s\n' "$key=${!value}" "$comment"
    done
}

# 读取配置到 CFG_<配置项>：先取模板默认值，配置文件存在时按白名单逐行覆盖；不 source 配置文件，避免执行其中的代码
# 无法识别的配置项记入 DROPPED
read_config() {
    local line key default comment entry keys=, n=0
    DROPPED=''
    for entry in "${TEMPLATE[@]}"; do
        IFS='|' read -r key default comment <<<"$entry"
        printf -v "CFG_$key" '%s' "$default"
        keys+="$key,"
    done
    [[ -e "$CONFIG_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ $SKIP ]] && continue
        # 报错只给行号，避免把接口地址打进日志
        [[ "$line" =~ $PAIR ]] || die "$CONFIG_FILE 第 $n 行格式错误，请修正后重新执行 check-ip install"
        key=${BASH_REMATCH[1]}
        if [[ "$keys" == *",$key,"* ]]; then
            printf -v "CFG_$key" '%s' "${BASH_REMATCH[2]}"
        else
            DROPPED+=" $key"
        fi
    done <"$CONFIG_FILE"
}

# 按模板写入配置文件，内容未变化时不改动文件
write_config() {
    local new
    new=$(render_config)
    # 首次创建时先限制权限，再写入接口地址
    [[ -e "$CONFIG_FILE" ]] || (umask 077 && : >"$CONFIG_FILE")
    chown root:root "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    [[ "$new" != "$(<"$CONFIG_FILE")" ]] || return 0
    # 持锁原地写入、不替换文件：运行中与之后启动的实例锁的始终是同一个文件，也不会读到写了一半的配置
    exec 8<"$CONFIG_FILE"
    flock -w 300 8 || die "另一个 check-ip 运行超过 300 秒仍未结束，配置未保存"
    printf '%s\n' "$new" >"$CONFIG_FILE"
    exec 8<&-
    echo "配置已保存到 $CONFIG_FILE"
}

# 缺少依赖时用系统包管理器安装；ping 在 Debian / Ubuntu 的包名为 iputils-ping，在 RHEL 系为 iputils
ensure_deps() {
    local missing=()
    command -v curl >/dev/null || missing+=(curl)
    command -v flock >/dev/null || missing+=(util-linux)
    command -v ping >/dev/null || missing+=(ping)
    ((${#missing[@]})) || return 0
    echo "正在安装依赖：${missing[*]}"
    if command -v apt-get >/dev/null; then
        # 非交互安装，避免 Ubuntu 的 needrestart 弹出对话框等待选择
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq "${missing[@]/#ping/iputils-ping}"
    elif command -v dnf >/dev/null; then
        dnf install -y -q "${missing[@]/#ping/iputils}"
    elif command -v yum >/dev/null; then
        yum install -y -q "${missing[@]/#ping/iputils}"
    else
        die "无法自动安装 ${missing[*]}，请手动安装后重新执行 check-ip install"
    fi
}

# 用法：ask 变量名 提示 校验正则；方括号内显示当前值，直接回车保留
ask() {
    local var=$1 prompt=$2 re=$3 input cur=${!1}
    while true; do
        read -rp "$prompt${cur:+ [$cur]}：" input
        # 复制粘贴常带首尾空格，这些配置值本身不含空白，统一去掉
        input=${input//[[:space:]]/}
        input=${input:-$cur}
        [[ "$input" =~ $re ]] && break
        echo "  格式不正确，请重新输入"
    done
    printf -v "$var" '%s' "$input"
}

# 交互式填写配置
configure() {
    echo "按提示填写配置，方括号内为当前值，直接回车保留"
    ask CFG_CHECK_TARGETS "检测目标（IP:TCP 端口，多个用英文逗号分隔）" "$TARGETS_RE"
    ask CFG_CHANGE_IP_API "更换 IP 的接口地址" "$API_RE"
    ask CFG_MAX_RETRY "所有目标都不通时最多连续更换几次 IP（1-20）" "$RETRY_RE"
    ask CFG_INTERVAL_MINUTES "每多少分钟检测一次（1-1440）" "$INTERVAL_RE"
}

install_self() {
    [[ $EUID -eq 0 ]] || die "install 需要 root 权限"
    local src interactive=false sd_version namespace='' log_cmd='journalctl -u check-ip -n 20 --no-pager'
    [[ -t 0 ]] && interactive=true
    ensure_deps
    src=$(realpath "${BASH_SOURCE[0]}")
    [[ "$src" == "$BIN" ]] || install -m 755 -o root -g root "$src" "$BIN"
    read_config
    [[ -z "$DROPPED" ]] || echo "已移除无法识别的配置项：${DROPPED# }"
    [[ "$interactive" == false ]] || configure
    [[ "$CFG_INTERVAL_MINUTES" =~ $INTERVAL_RE ]] || die "INTERVAL_MINUTES 只能是 1-1440 的整数，请修正 $CONFIG_FILE 后重新执行 check-ip install"
    write_config
    # systemd 245 起支持日志命名空间：日志单独存放并限制总量，不影响服务器上其它服务的日志
    sd_version=$(systemctl --version | awk 'NR == 1 {print $2}')
    if [[ "$sd_version" =~ ^[0-9]+$ ]] && ((sd_version >= 245)); then
        namespace='LogNamespace=check-ip'
        log_cmd='journalctl --namespace=check-ip -n 20 --no-pager'
        printf '[Journal]\nSystemMaxUse=10M\n' >"$JOURNAL_CONF"
    else
        echo "当前 systemd 版本低于 245，无法单独限制日志大小，日志写入系统日志"
    fi
    cat >"$UNIT_DIR/check-ip.service" <<EOF
[Unit]
Description=VPS IP block check
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# 脚本输出记为 notice，并丢弃 systemd 每次启停写的 info 记录；运行失败的 warning 仍保留
SyslogLevel=notice
LogLevelMax=notice
$namespace
EOF
    cat >"$UNIT_DIR/check-ip.timer" <<EOF
[Unit]
Description=Run VPS IP block check every $CFG_INTERVAL_MINUTES minute(s)

[Timer]
# 不用 OnBootSec：开机时间已过时启动定时器会立即触发，安装试运行后会紧接着再检测一轮
OnActiveSec=${CFG_INTERVAL_MINUTES}min
OnUnitActiveSec=${CFG_INTERVAL_MINUTES}min
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    # 日志实例已在运行时重启它，使新的大小限制生效
    [[ -z "$namespace" ]] || systemctl try-restart systemd-journald@check-ip.service
    if [[ "$interactive" == false ]]; then
        # 定时任务已启用时重启它，使新的执行间隔立即生效
        systemctl try-restart check-ip.timer
        echo "已按现有配置安装。在终端中执行 check-ip install 可按提示修改配置并启用定时任务"
        return 0
    fi
    echo "正在试运行……"
    # 依赖与配置均已检查，试运行失败只表示当前网络不通，仍启用定时任务继续检测和更换 IP
    "$BIN" || echo "试运行结束时仍无法连通检测目标，定时任务照常启用，之后会按间隔继续检测"
    systemctl enable --quiet check-ip.timer
    systemctl restart check-ip.timer
    echo "部署完成：每 $CFG_INTERVAL_MINUTES 分钟自动执行一次。查看日志：$log_cmd"
}

load_config() {
    read_config
    [[ -z "$DROPPED" ]] || die "$CONFIG_FILE 中有未知配置项：${DROPPED# }"
    [[ "$CFG_CHECK_TARGETS" =~ $TARGETS_RE ]] || die "CHECK_TARGETS 未填写或格式不正确"
    [[ "$CFG_CHANGE_IP_API" =~ $API_RE ]] || die "CHANGE_IP_API 未填写或格式不正确"
    [[ "$CFG_MAX_RETRY" =~ $RETRY_RE ]] || die "MAX_RETRY 只能是 1-20 的整数"
    IFS=, read -ra TARGETS <<<"$CFG_CHECK_TARGETS"
}

# 任一目标 ping 通或 TCP 端口可连接即返回成功；逐项结果只在终端手动运行时显示
is_reachable() {
    local target host port
    for target in "${TARGETS[@]}"; do
        host=${target%:*} port=${target##*:}
        # 只指定 -c 时，ping 收到任一回包即退出码为 0，不解析丢包率文字
        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1; then
            [[ ! -t 2 ]] || log "${host}：ping 通，网络正常"
            return 0
        fi
        if timeout "$TCP_TIMEOUT" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
            [[ ! -t 2 ]] || log "${host}：ping 不通，TCP $port 端口可连接，网络正常"
            return 0
        fi
        [[ ! -t 2 ]] || log "${host}：ping 不通，TCP $port 端口连接失败"
    done
    return 1
}

current_ip() {
    curl -4 -fs --connect-timeout 5 --max-time 8 ifconfig.me 2>/dev/null || echo "获取失败"
}

change_ip() {
    local resp
    # 接口地址经标准输入交给 curl，不出现在进程参数和日志里（地址中可能带密钥）
    # 跟随跳转（如 http 跳到 https）；连不上或返回 HTTP 错误时 curl 失败，记录其错误信息
    if resp=$(printf 'url = "%s"\n' "$CFG_CHANGE_IP_API" | curl -sSfL --connect-timeout 10 --max-time 15 -K - 2>&1); then
        log "已调用更换 IP 接口，返回：$resp"
    else
        log "调用更换 IP 接口失败：$resp"
    fi
    # 等待新 IP 生效
    sleep 3
}

main() {
    local retry=0
    case "${1:-}" in
        install) install_self; return ;;
        "") ;;
        *) die "用法：check-ip [install]" ;;
    esac
    command -v curl >/dev/null && command -v ping >/dev/null && command -v flock >/dev/null && command -v timeout >/dev/null || die "缺少依赖：需要 curl、ping、flock 与 timeout"
    [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "无法读取 ${CONFIG_FILE}：请以 root 运行，尚未安装时先执行 install"
    # 以配置文件加锁：同一份配置同时只运行一个实例，避免手动运行与定时任务同时更换 IP；先加锁再读取，不会读到 install 写了一半的配置
    exec 9<"$CONFIG_FILE"
    flock -w 300 9 || die "另一个 check-ip 运行超过 300 秒仍未结束，本次退出"
    load_config

    # 每次更换后都重新检测，最后一次换出的 IP 也会被验证
    while ! is_reachable; do
        ((retry < CFG_MAX_RETRY)) || die "当前 IP $(current_ip)：已连续更换 ${CFG_MAX_RETRY} 次仍无法连通任何检测目标，请人工排查"
        retry=$((retry + 1))
        log "当前 IP $(current_ip)：所有检测目标均不通，第 ${retry} 次更换 IP"
        change_ip
    done
    ((retry == 0)) || log "更换后网络恢复，当前 IP $(current_ip)"
}

# 主流程放在函数内且与 exit 同行：bash 执行前已读完整个流程，运行中脚本文件被更新覆盖也不受影响
main "$@"; exit $?
