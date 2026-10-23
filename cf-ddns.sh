#!/usr/bin/env bash
# Cloudflare DDNS：把本机公网 IPv4 / IPv6 同步到 Cloudflare 的 A / AAAA 记录，使用说明见 README.md
set -euo pipefail

BIN=/usr/local/bin/cf-ddns
CONFIG_FILE=${CF_DDNS_CONFIG:-/etc/cf-ddns.conf}
UNIT_DIR=/etc/systemd/system
# 配置行格式：KEY=VALUE，值可加双引号，行尾可加 # 注释；SKIP 为可忽略的空行与注释行
PAIR='^([A-Z0-9_]+)="?([^"#[:space:]]*)"?[[:space:]]*(#.*)?$'
SKIP='^[[:space:]]*(#|$)'

log() { echo "[$(date '+%F %T')] $*" >&2; }
die() { log "$*"; exit 1; }

# 配置模板，每项为「配置项|默认值|说明」；新装与更新都按它生成配置文件
TEMPLATE=(
    'CF_API_TOKEN||Cloudflare API 令牌，用「编辑区域 DNS」模板创建'
    'CF_ZONE_ID||域名概述页右侧 API 区域里的区域 ID（32 位）'
    'CF_RECORDS||域名:是否开启代理，多个用英文逗号分隔，例如 1.example.com:true,2.example.com:false'
    'ENABLE_IPV4|true|是否更新 A 记录：true / false'
    'ENABLE_IPV6|true|是否更新 AAAA 记录：true / false'
    'CF_TTL|1|新建未开代理记录的 TTL（秒），1 表示自动；已有记录不改'
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

# 输出旧版 CF_RECORD_NAME 并入 CF_RECORDS 时的代理状态：记录已存在时沿用 Cloudflare 上的当前设置，不存在时沿用 CF_PROXIED
legacy_proxied() {
    local resp current=''
    # 令牌、区域 ID 或域名无效时旧版本身无法运行，不查询，直接沿用 CF_PROXIED
    if [[ "$CFG_CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,}$ && "$CFG_CF_ZONE_ID" =~ ^[a-f0-9]{32}$ && "$1" =~ ^([a-z0-9_-]{1,63}\.)+[a-z0-9-]{2,63}$ ]]; then
        command -v curl >/dev/null && command -v jq >/dev/null || return 1
        CF_API_TOKEN=$CFG_CF_API_TOKEN
        API="https://api.cloudflare.com/client/v4/zones/${CFG_CF_ZONE_ID}/dns_records"
        resp=$(cf_api GET "?name.exact=$1") || return 1
        current=$(jq -r '[.result[] | select(.type == "A" or .type == "AAAA") | .proxied] | if length > 0 then .[0] else empty end' <<<"$resp")
    fi
    if [[ -n "$current" ]]; then
        echo "$current"
    elif [[ "$CFG_CF_PROXIED" == true ]]; then
        echo true
    else
        echo false
    fi
}

# 按新版模板重写配置文件：保留原有配置值，注释、配置项顺序与旧版配置项全部更新为新版
update_config() {
    local line key entry name proxied tmp keys=, dropped='' n=0
    for entry in "${TEMPLATE[@]}"; do
        keys+="${entry%%|*},"
    done
    CFG_CF_RECORD_NAME='' CFG_CF_PROXIED=''
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ $SKIP ]] && continue
        # 读不出值的行不能丢弃，否则会丢失配置值
        [[ "$line" =~ $PAIR ]] || die "$CONFIG_FILE 第 $n 行格式错误，配置文件未改动；请修正后重新执行 cf-ddns install"
        key=${BASH_REMATCH[1]}
        if [[ "$keys" == *",$key,"* || "$key" == CF_RECORD_NAME || "$key" == CF_PROXIED ]]; then
            printf -v "CFG_$key" '%s' "${BASH_REMATCH[2]}"
        else
            dropped+=" $key"
        fi
    done <"$CONFIG_FILE"
    if [[ -n "$CFG_CF_RECORD_NAME" ]]; then
        [[ -z "$CFG_CF_PROXIED" || "$CFG_CF_PROXIED" =~ ^(true|false)$ ]] || die "CF_PROXIED 只能是 true 或 false，配置文件未改动；请修正后重新执行 cf-ddns install"
        name=$(tr '[:upper:]' '[:lower:]' <<<"$CFG_CF_RECORD_NAME")
        if [[ ",$(tr '[:upper:]' '[:lower:]' <<<"$CFG_CF_RECORDS")," == *",$name:"* ]]; then
            echo "CF_RECORDS 中已有 $name，旧版 CF_RECORD_NAME / CF_PROXIED 已移除"
        else
            proxied=$(legacy_proxied "$name") || die "无法读取 Cloudflare 上 $name 的代理状态，配置文件未改动；请检查网络、令牌及 curl / jq 是否已安装后重新执行 cf-ddns install"
            CFG_CF_RECORDS="${CFG_CF_RECORDS:+$CFG_CF_RECORDS,}$name:$proxied"
            echo "旧版 CF_RECORD_NAME / CF_PROXIED 已并入 CF_RECORDS：$name:$proxied"
        fi
    fi
    [[ -z "$dropped" ]] || echo "已移除新版无法识别的配置项：${dropped# }"
    # 先写临时文件再替换，避免定时任务读到写了一半的配置；内容未变化时不改动文件
    tmp=$(mktemp "$CONFIG_FILE.XXXXXX")
    render_config >"$tmp"
    if cmp -s "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$CONFIG_FILE"
        echo "配置文件已按新版格式更新，原有配置值保持不变"
    fi
}

install_self() {
    [[ $EUID -eq 0 ]] || die "install 需要 root 权限"
    local src entry key default comment
    src=$(realpath "${BASH_SOURCE[0]}")
    [[ "$src" == "$BIN" ]] || install -m 755 -o root -g root "$src" "$BIN"
    for entry in "${TEMPLATE[@]}"; do
        IFS='|' read -r key default comment <<<"$entry"
        printf -v "CFG_$key" '%s' "$default"
    done
    if [[ -e "$CONFIG_FILE" ]]; then
        update_config
    else
        (umask 077 && render_config >"$CONFIG_FILE")
    fi
    chown root:root "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    cat >"$UNIT_DIR/cf-ddns.service" <<EOF
[Unit]
Description=Cloudflare DDNS
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
EOF
    cat >"$UNIT_DIR/cf-ddns.timer" <<'EOF'
[Unit]
Description=Run Cloudflare DDNS every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    echo "已安装。下一步：编辑 $CONFIG_FILE，执行 cf-ddns 试运行，再执行 systemctl enable --now cf-ddns.timer"
}

# 按白名单逐行读取 KEY=VALUE（允许行尾 # 注释），不 source 配置文件，避免执行其中的代码
load_config() {
    local line key item items seen=, n=0 domain='^([a-z0-9_-]{1,63}\.)+[a-z0-9-]{2,63}$'
    CF_API_TOKEN='' CF_ZONE_ID='' CF_RECORDS='' CF_RECORD_NAME='' CF_PROXIED='' ENABLE_IPV4='' ENABLE_IPV6='' CF_TTL='' RECORDS=()
    [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "无法读取 $CONFIG_FILE：请以 root 运行，尚未安装时先执行 install"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ $SKIP ]] && continue
        # 报错只给行号，避免把 Token 打进日志
        [[ "$line" =~ $PAIR ]] || die "$CONFIG_FILE 第 $n 行格式错误"
        key=${BASH_REMATCH[1]}
        case "$key" in
            CF_API_TOKEN | CF_ZONE_ID | CF_RECORDS | CF_RECORD_NAME | CF_PROXIED | ENABLE_IPV4 | ENABLE_IPV6 | CF_TTL) printf -v "$key" '%s' "${BASH_REMATCH[2]}" ;;
            *) die "$CONFIG_FILE 第 $n 行：未知配置项 $key" ;;
        esac
    done <"$CONFIG_FILE"
    [[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,}$ ]] || die "CF_API_TOKEN 未填写或格式不正确"
    [[ "$CF_ZONE_ID" =~ ^[a-f0-9]{32}$ ]] || die "CF_ZONE_ID 未填写或格式不正确"
    # RECORDS 条目格式：域名:是否开启代理:是否同步已有记录的代理状态（1 同步，0 只用于新建）
    # Cloudflare 的域名不区分大小写，统一转小写后再查重
    IFS=, read -ra items <<<"$(tr '[:upper:]' '[:lower:]' <<<"$CF_RECORDS")"
    for item in ${items[@]+"${items[@]}"}; do
        [[ "$item" =~ ^([^:]*):(true|false)$ && "${BASH_REMATCH[1]}" =~ $domain ]] ||
            die "CF_RECORDS 中的「$item」格式不正确，应为 域名:true 或 域名:false"
        [[ "$seen" != *",${item%:*},"* ]] || die "CF_RECORDS 中的 ${item%:*} 重复"
        seen+="${item%:*},"
        RECORDS+=("$item:1")
    done
    # 兼容旧版配置：CF_RECORD_NAME 的代理开关 CF_PROXIED 与旧版相同，只在新建记录时使用
    if [[ -n "$CF_RECORD_NAME" ]]; then
        CF_RECORD_NAME=$(tr '[:upper:]' '[:lower:]' <<<"$CF_RECORD_NAME")
        [[ "$CF_RECORD_NAME" =~ $domain ]] || die "CF_RECORD_NAME 格式不正确"
        [[ "${CF_PROXIED:=false}" =~ ^(true|false)$ ]] || die "CF_PROXIED 只能是 true 或 false"
        [[ "$seen" != *",$CF_RECORD_NAME,"* ]] || die "$CF_RECORD_NAME 同时出现在 CF_RECORDS 与 CF_RECORD_NAME 中"
        RECORDS+=("$CF_RECORD_NAME:$CF_PROXIED:0")
    fi
    ((${#RECORDS[@]})) || die "CF_RECORDS 未填写"
    [[ "$ENABLE_IPV4" =~ ^(true|false)$ && "$ENABLE_IPV6" =~ ^(true|false)$ ]] || die "ENABLE_IPV4、ENABLE_IPV6 只能是 true 或 false"
    [[ "$ENABLE_IPV4" == true || "$ENABLE_IPV6" == true ]] || die "ENABLE_IPV4 与 ENABLE_IPV6 不能同时为 false"
    [[ "$CF_TTL" == 1 || ("$CF_TTL" =~ ^[1-9][0-9]{1,4}$ && "$CF_TTL" -ge 60 && "$CF_TTL" -le 86400) ]] || die "CF_TTL 只能是 1 或 60-86400"
}

# 用法：cf_api 方法 路径后缀 [JSON 请求体]；成功时输出响应 JSON
cf_api() {
    local resp args=(-sS --proto =https --max-time 15 -X "$1" -H "Content-Type: application/json" -K -)
    if [[ -n "${3:-}" ]]; then
        args+=(--data "$3")
    fi
    # Token 经标准输入交给 curl，不出现在进程参数里，其它本机用户用 ps 看不到
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" | curl "${args[@]}" "$API$2") || return 1
    if [[ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != true ]]; then
        log "Cloudflare API 返回失败：$(jq -c '.errors' <<<"$resp" 2>/dev/null || echo '响应不是 JSON')"
        return 1
    fi
    printf '%s' "$resp"
}

# 用法：get_ip 4|6；依次尝试多个查询源，输出通过格式校验的公网 IP
get_ip() {
    local ip url
    for url in https://api64.ipify.org https://icanhazip.com; do
        ip=$(curl -"$1" -sS --proto =https --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        if [[ "$1" == 4 && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" == 6 && "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# 用法：sync_record A|AAAA IP 域名 true|false 1|0；最后一项为 0 时已有记录保留现有代理状态（旧版 CF_RECORD_NAME 行为）
sync_record() {
    local type=$1 ip=$2 name=$3 proxied=$4 sync_proxied=$5 resp count id current current_proxied body change=''
    resp=$(cf_api GET "?type=$type&name.exact=$name") || return 1
    count=$(jq '.result | length' <<<"$resp")
    case "$count" in
        0)
            # 开启代理的记录 TTL 固定为自动
            body=$(jq -nc --arg t "$type" --arg n "$name" --arg c "$ip" --argjson ttl "$CF_TTL" --argjson p "$proxied" \
                '{type: $t, name: $n, content: $c, ttl: (if $p then 1 else $ttl end), proxied: $p}')
            cf_api POST "" "$body" >/dev/null || return 1
            log "$type：$name 已创建（IP $ip，代理 $proxied）"
            ;;
        1)
            id=$(jq -r '.result[0].id' <<<"$resp")
            current=$(jq -r '.result[0].content' <<<"$resp")
            current_proxied=$(jq -r '.result[0].proxied' <<<"$resp")
            [[ "$id" =~ ^[a-f0-9]{32}$ ]] || { log "$type：$name 记录 ID 格式异常"; return 1; }
            [[ "$sync_proxied" == 1 ]] || proxied=$current_proxied
            [[ "$current" == "$ip" ]] || change="IP $current -> $ip"
            [[ "$current_proxied" == "$proxied" ]] || change+="${change:+，}代理 $current_proxied -> $proxied"
            if [[ -z "$change" ]]; then
                log "$type：$name 未变化（IP $ip，代理 $proxied）"
                return 0
            fi
            # 只改 IP 与代理状态，保留记录现有的 TTL
            cf_api PATCH "/$id" "$(jq -nc --arg c "$ip" --argjson p "$proxied" '{content: $c, proxied: $p}')" >/dev/null || return 1
            log "$type：$name 已更新（$change）"
            ;;
        *)
            log "$type：$name 存在 $count 条记录，请在 Cloudflare 只保留一条"
            return 1
            ;;
    esac
}

main() {
    local rc=0 family type version enabled ip item name proxied sync_proxied
    case "${1:-}" in
        install) install_self; return 0 ;;
        "") ;;
        *) die "用法：cf-ddns [install]" ;;
    esac
    command -v curl >/dev/null && command -v jq >/dev/null && command -v flock >/dev/null || die "缺少依赖：需要 curl、jq 与 flock"
    load_config
    # 以配置文件加锁：同一份配置同时只运行一个实例，避免手动运行与定时任务重复创建记录
    exec 9<"$CONFIG_FILE"
    flock -w 120 9 || die "另一个 cf-ddns 运行超过 120 秒仍未结束，本次退出"
    API="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"

    for family in A:4 AAAA:6; do
        type=${family%:*} version=${family#*:}
        enabled=ENABLE_IPV$version
        [[ "${!enabled}" == true ]] || continue
        if ! ip=$(get_ip "$version"); then
            log "$type：获取公网 IPv$version 失败"
            rc=1
            continue
        fi
        for item in "${RECORDS[@]}"; do
            IFS=: read -r name proxied sync_proxied <<<"$item"
            sync_record "$type" "$ip" "$name" "$proxied" "$sync_proxied" || { log "$type：$name 同步失败"; rc=1; }
        done
    done
    return "$rc"
}

# 主流程放在函数内且与 exit 同行：bash 执行前已读完整个流程，运行中脚本文件被更新覆盖也不受影响
main "$@"; exit $?
