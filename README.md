# Cloudflare DDNS

将服务器当前的公网 IPv4 / IPv6 同步到 Cloudflare 的 A / AAAA 记录，由 systemd 定时器每 5 分钟执行一次。

## 准备

- 使用 systemd 的 Linux 服务器，以 root 执行以下命令（sudo 用户先执行 `sudo -i`）
- Cloudflare API 令牌：「我的个人资料 → API 令牌 → 创建令牌 → 编辑区域 DNS」，区域资源只选目标域名，不要设置客户端 IP 筛选
- 区域 ID：域名「概述」页右侧 API 区域

## 安装

安装依赖（Debian / Ubuntu）：

```bash
apt-get update && apt-get install -y curl jq
```

安装依赖（RHEL / Rocky / AlmaLinux）：

```bash
dnf install -y curl jq
```

下载并安装脚本：

```bash
curl -fsSL -o /usr/local/bin/cf-ddns https://raw.githubusercontent.com/ECYCloud/DDNS/main/cf-ddns.sh
chmod 755 /usr/local/bin/cf-ddns
cf-ddns install
```

安装后生成：

| 路径 | 用途 |
| ---- | ---- |
| `/usr/local/bin/cf-ddns` | 脚本 |
| `/etc/cf-ddns.conf` | 配置，权限 600 |
| `/etc/systemd/system/cf-ddns.service`、`cf-ddns.timer` | 定时任务 |

## 配置

```bash
nano /etc/cf-ddns.conf
```

RHEL 系未预装 nano，可改用 `vi`，或先执行 `dnf install -y nano`。

| 配置项 | 说明 |
| ---- | ---- |
| `CF_API_TOKEN` | API 令牌 |
| `CF_ZONE_ID` | 区域 ID |
| `CF_RECORDS` | 要更新的记录，格式 `域名:是否开启代理`，多个用英文逗号分隔 |
| `ENABLE_IPV4` / `ENABLE_IPV6` | 是否更新 A / AAAA 记录，无 IPv6 时设为 `false` |
| `CF_TTL` | 新建未开代理记录的 TTL，`1` 为自动 |

格式为 `KEY=VALUE`，等号两侧和值内都不能有空格（`CF_RECORDS` 的逗号后也不加空格），行尾可加 `# 注释`。

`CF_RECORDS` 示例：`1.example.com` 开启代理，`2.example.com` 仅 DNS。

```ini
CF_RECORDS=1.example.com:true,2.example.com:false
```

## 启用

试运行，确认输出无报错：

```bash
cf-ddns
```

启用定时任务：

```bash
systemctl enable --now cf-ddns.timer
```

## 维护

| 操作 | 命令 |
| ---- | ---- |
| 查看下次执行时间 | `systemctl list-timers cf-ddns.timer` |
| 查看最近日志 | `journalctl -u cf-ddns -n 20 --no-pager` |
| 立即执行一次 | `systemctl start cf-ddns.service` |

修改执行间隔：执行 `systemctl edit cf-ddns.timer`，写入以下内容后保存，再执行 `systemctl restart cf-ddns.timer`。第一行会清除全部原有定时设置，因此需同时写回开机后 1 分钟的首次执行。

```ini
[Timer]
OnUnitActiveSec=
OnBootSec=1min
OnUnitActiveSec=10min
```

更新：重新执行「安装」中的下载与 `install` 命令，已有配置和自定义间隔不会被覆盖。

卸载：

```bash
systemctl disable --now cf-ddns.timer
rm -f /usr/local/bin/cf-ddns /etc/cf-ddns.conf /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
rm -rf /etc/systemd/system/cf-ddns.timer.d
systemctl daemon-reload
```

## 说明

- 记录不存在时自动新建；已存在时同步 IP 和代理状态，不修改 TTL。
- 开启代理后访问者连接的是 Cloudflare，只能用于网页服务；SSH 等直连服务使用未开代理的记录。
- 同名同类型记录存在多条时，该域名报错跳过，需在 Cloudflare 保留一条。
- 同一份配置同时只运行一个实例，手动运行与定时任务重叠时后者等待前者结束。
- 令牌仅保存在 `/etc/cf-ddns.conf`，不会出现在进程参数或日志中。
