# Server Scripts

服务器运维脚本，均以 systemd 定时任务运行，安装、配置与日志方式一致。

| 脚本 | 用途 |
| ---- | ---- |
| [Cloudflare DDNS](#cloudflare-ddns)（`cf-ddns.sh`） | 将服务器公网 IPv4 / IPv6 同步到 Cloudflare 的 A / AAAA 记录 |
| [IP 被墙检测](#ip-被墙检测)（`check-ip.sh`） | 检测服务器能否连通国内，全部不通时调用接口更换 IP |

## Cloudflare DDNS

将服务器当前的公网 IPv4 / IPv6 自动同步到 Cloudflare 的 A / AAAA 记录，支持多个域名，每个域名可单独设置是否开启代理。

### 准备

- 使用 systemd 的 Linux 服务器，以 root 执行命令（sudo 用户先执行 `sudo -i`）
- Cloudflare API 令牌：「我的个人资料 → API 令牌 → 创建令牌 → 编辑区域 DNS」，区域资源只选目标域名，不要设置客户端 IP 筛选
- 区域 ID：域名「概述」页右侧 API 区域

### 安装

```bash
curl -fsSL -o /usr/local/bin/cf-ddns https://raw.githubusercontent.com/ECYCloud/Server-Scripts/main/cf-ddns.sh && chmod 755 /usr/local/bin/cf-ddns && cf-ddns install
```

按提示依次填写：

1. Cloudflare API 令牌
2. 区域 ID
3. 域名：逐个输入，每个域名选择是否开启代理，全部输入完后直接回车
4. 是否更新 IPv4 / IPv6（默认值按本机检测结果给出）
5. 每多少分钟执行一次

填完后自动试运行，成功即启用定时任务。缺少 jq 等依赖时会自动安装；服务器没有 curl 时先执行 `apt-get install -y curl` 或 `dnf install -y curl`。

### 修改配置

```bash
cf-ddns install
```

按提示修改，方括号内为当前值，直接回车保留。修改域名时选择 `y`，现有域名会逐个确认是否保留、是否开启代理，之后可继续输入新增的域名。

### 更新

重新执行「安装」中的命令，已有配置作为默认值，一路回车即可保留。旧版配置中的 `CF_RECORD_NAME` / `CF_PROXIED` 会自动并入新的域名列表，代理状态沿用 Cloudflare 上的当前设置。

### 常用命令

| 操作 | 命令 |
| ---- | ---- |
| 查看最近日志 | `journalctl --namespace=cf-ddns -n 20 --no-pager`（systemd 低于 245 时用 `journalctl -u cf-ddns -n 20 --no-pager`） |
| 查看下次执行时间 | `systemctl list-timers cf-ddns.timer` |
| 立即执行一次 | `systemctl start cf-ddns.service` |

### 卸载

```bash
systemctl disable --now cf-ddns.timer
systemctl stop systemd-journald@cf-ddns.service
rm -f /usr/local/bin/cf-ddns /etc/cf-ddns.conf /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer /etc/systemd/journald@cf-ddns.conf
rm -rf /etc/systemd/system/cf-ddns.timer.d "/var/log/journal/$(cat /etc/machine-id).cf-ddns"
systemctl daemon-reload
```

### 说明

- 配置保存在 `/etc/cf-ddns.conf`（权限 600），也可直接编辑：执行间隔以外的修改在下次运行时生效，修改执行间隔需再执行 `cf-ddns install`。
- 记录不存在时自动新建；已存在时同步 IP 和代理状态，不修改 TTL。
- 开启代理后访问者连接的是 Cloudflare，只能用于网页服务；SSH 等直连服务使用未开代理的域名。
- 同名同类型记录存在多条时，该域名报错跳过，需在 Cloudflare 保留一条。
- 同一份配置同时只运行一个实例，手动运行与定时任务重叠时后者等待前者结束。
- 日志只记录新建、更新记录和出错；记录未变化时不写日志，在终端手动执行 `cf-ddns` 时仍会显示。
- DDNS 日志单独存放，总量约 10MB，超出时自动删除最旧的日志，不影响服务器上其它服务的日志（需 systemd 245 及以上，较低版本写入系统日志）。systemd 自身的运行失败提示可能记在系统日志中，可用 `journalctl -u cf-ddns` 查看。
- 令牌仅保存在配置文件中，不会出现在进程参数或日志中。

## IP 被墙检测

定时从服务器检测国内目标能否连通；所有目标都不通时调用服务商的接口更换 IP，换完重新检测，直到恢复或达到最多更换次数。

### 准备

- 使用 systemd 的 Linux 服务器，以 root 执行命令（sudo 用户先执行 `sudo -i`）
- 服务商提供的更换 IP 接口地址（请求该地址即更换 IP）
- 检测目标：默认为 `223.5.5.5:443` 与 `119.29.29.29:80`，部署前先在未被墙的服务器上确认能 ping 通或连上对应端口；目标填错会一直判定为不通并反复更换 IP

### 安装

```bash
curl -fsSL -o /usr/local/bin/check-ip https://raw.githubusercontent.com/ECYCloud/Server-Scripts/main/check-ip.sh && chmod 755 /usr/local/bin/check-ip && check-ip install
```

按提示依次填写：

1. 检测目标：`IP:TCP 端口`，多个用英文逗号分隔
2. 更换 IP 的接口地址：无默认值，必须填写
3. 所有目标都不通时最多连续更换几次 IP
4. 每多少分钟检测一次

填完后自动试运行，随后启用定时任务，安装完成或服务器开机后过一个执行间隔进行首次定时检测。试运行时如果所有目标都不通，会真实更换 IP，通过该 IP 连接的 SSH 可能断开；试运行结束仍不通时定时任务照常启用，之后按间隔继续检测。缺少 ping、flock 时会自动安装；服务器没有 curl 时先执行 `apt-get install -y curl` 或 `dnf install -y curl`。

### 修改配置

```bash
check-ip install
```

按提示修改，方括号内为当前值，直接回车保留。

### 更新

重新执行「安装」中的命令，已有配置作为默认值，一路回车即可保留。

### 常用命令

| 操作 | 命令 |
| ---- | ---- |
| 查看最近日志 | `journalctl --namespace=check-ip -n 20 --no-pager`（systemd 低于 245 时用 `journalctl -u check-ip -n 20 --no-pager`） |
| 查看下次执行时间 | `systemctl list-timers check-ip.timer` |
| 立即执行一次 | `systemctl start check-ip.service` |
| 在终端查看每个目标的检测结果 | `check-ip` |

### 卸载

```bash
systemctl disable --now check-ip.timer
systemctl stop systemd-journald@check-ip.service
rm -f /usr/local/bin/check-ip /etc/check-ip.conf /etc/systemd/system/check-ip.service /etc/systemd/system/check-ip.timer /etc/systemd/journald@check-ip.conf
rm -rf "/var/log/journal/$(cat /etc/machine-id).check-ip"
systemctl daemon-reload
```

### 说明

- 配置保存在 `/etc/check-ip.conf`（权限 600），也可直接编辑：执行间隔以外的修改在下次运行时生效，修改执行间隔需再执行 `check-ip install`。
- 按顺序检测每个目标：先 ping 10 次，收到任一回包即为连通；不通再尝试连接 TCP 端口（3 秒超时）。任一目标连通即判定正常，全部不通才更换 IP。目标使用固定 IP，不受 DNS 故障影响。
- 调用接口时自动跟随跳转；接口连不上或返回 HTTP 错误时，日志记录失败原因。每次调用后等待 3 秒再重新检测；达到最多更换次数仍不通时记录错误并结束，下次定时再检测。
- 同一份配置同时只运行一个实例，手动运行与定时任务重叠时后者等待前者结束（最长 300 秒）。
- 日志只记录更换 IP 和出错；网络正常时不写日志，在终端手动执行 `check-ip` 时仍会显示。
- 日志单独存放，总量约 10MB，超出时自动删除最旧的日志（需 systemd 245 及以上，较低版本写入系统日志）。systemd 自身的运行失败提示可能记在系统日志中，可用 `journalctl -u check-ip` 查看。
- 接口地址仅保存在配置文件中，脚本不会把它写入进程参数或日志；接口返回的内容会原样记录在日志中。
