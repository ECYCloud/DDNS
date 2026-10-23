# Cloudflare DDNS

将服务器当前的公网 IPv4 / IPv6 自动同步到 Cloudflare 的 A / AAAA 记录，支持多个域名，每个域名可单独设置是否开启代理。

## 准备

- 使用 systemd 的 Linux 服务器，以 root 执行命令（sudo 用户先执行 `sudo -i`）
- Cloudflare API 令牌：「我的个人资料 → API 令牌 → 创建令牌 → 编辑区域 DNS」，区域资源只选目标域名，不要设置客户端 IP 筛选
- 区域 ID：域名「概述」页右侧 API 区域

## 安装

```bash
curl -fsSL -o /usr/local/bin/cf-ddns https://raw.githubusercontent.com/ECYCloud/DDNS/main/cf-ddns.sh && chmod 755 /usr/local/bin/cf-ddns && cf-ddns install
```

按提示依次填写：

1. Cloudflare API 令牌
2. 区域 ID
3. 域名：逐个输入，每个域名选择是否开启代理，全部输入完后直接回车
4. 是否更新 IPv4 / IPv6（默认值按本机检测结果给出）
5. 每多少分钟执行一次

填完后自动试运行，成功即启用定时任务。缺少 jq 等依赖时会自动安装；服务器没有 curl 时先执行 `apt-get install -y curl` 或 `dnf install -y curl`。

## 修改配置

```bash
cf-ddns install
```

按提示修改，方括号内为当前值，直接回车保留。修改域名时选择 `y`，现有域名会逐个确认是否保留、是否开启代理，之后可继续输入新增的域名。

## 更新

重新执行「安装」中的命令，已有配置作为默认值，一路回车即可保留。旧版配置中的 `CF_RECORD_NAME` / `CF_PROXIED` 会自动并入新的域名列表，代理状态沿用 Cloudflare 上的当前设置。

## 常用命令

| 操作 | 命令 |
| ---- | ---- |
| 查看最近日志 | `journalctl --namespace=cf-ddns -n 20 --no-pager`（systemd 低于 245 时用 `journalctl -u cf-ddns -n 20 --no-pager`） |
| 查看下次执行时间 | `systemctl list-timers cf-ddns.timer` |
| 立即执行一次 | `systemctl start cf-ddns.service` |

## 卸载

```bash
systemctl disable --now cf-ddns.timer
systemctl stop systemd-journald@cf-ddns.service
rm -f /usr/local/bin/cf-ddns /etc/cf-ddns.conf /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer /etc/systemd/journald@cf-ddns.conf
rm -rf /etc/systemd/system/cf-ddns.timer.d "/var/log/journal/$(cat /etc/machine-id).cf-ddns"
systemctl daemon-reload
```

## 说明

- 配置保存在 `/etc/cf-ddns.conf`（权限 600），也可直接编辑：执行间隔以外的修改在下次运行时生效，修改执行间隔需再执行 `cf-ddns install`。
- 记录不存在时自动新建；已存在时同步 IP 和代理状态，不修改 TTL。
- 开启代理后访问者连接的是 Cloudflare，只能用于网页服务；SSH 等直连服务使用未开代理的域名。
- 同名同类型记录存在多条时，该域名报错跳过，需在 Cloudflare 保留一条。
- 同一份配置同时只运行一个实例，手动运行与定时任务重叠时后者等待前者结束。
- 日志只记录新建、更新记录和出错；记录未变化时不写日志，在终端手动执行 `cf-ddns` 时仍会显示。
- DDNS 日志单独存放，总量约 10MB，超出时自动删除最旧的日志，不影响服务器上其它服务的日志（需 systemd 245 及以上，较低版本写入系统日志）。systemd 自身的运行失败提示可能记在系统日志中，可用 `journalctl -u cf-ddns` 查看。
- 令牌仅保存在配置文件中，不会出现在进程参数或日志中。
