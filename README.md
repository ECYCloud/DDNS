# Cloudflare DDNS

将服务器当前的公网 IPv4 / IPv6 同步到 Cloudflare 的 A / AAAA 记录，由 systemd 定时器每 5 分钟执行一次。

## 准备

- 使用 systemd 的 Linux 服务器，root 权限
- Cloudflare API 令牌：「我的个人资料 → API 令牌 → 创建令牌 → 编辑区域 DNS」，区域资源只选目标域名，不要设置客户端 IP 筛选
- 区域 ID：域名「概述」页右侧 API 区域

## 安装

```bash
apt-get install -y curl jq                     # RHEL 系使用 dnf install -y curl jq
curl -fsSL -o /root/cf-ddns.sh https://raw.githubusercontent.com/ECYCloud/DDNS/main/cf-ddns.sh
bash /root/cf-ddns.sh install && rm -f /root/cf-ddns.sh
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

| 配置项 | 说明 |
| ---- | ---- |
| `CF_API_TOKEN` | API 令牌 |
| `CF_ZONE_ID` | 区域 ID |
| `CF_RECORD_NAME` | 完整记录名，如 `ddns.example.com` |
| `ENABLE_IPV4` / `ENABLE_IPV6` | 是否更新 A / AAAA 记录，无 IPv6 时设为 `false` |
| `CF_TTL` | 新建记录的 TTL，`1` 为自动 |
| `CF_PROXIED` | 新建记录是否开启代理，保持 `false` |

格式为 `KEY=VALUE`，等号两侧不留空格，行尾可加 `# 注释`。

## 启用

```bash
cf-ddns                                        # 试运行，确认输出无报错
systemctl enable --now cf-ddns.timer           # 启用定时任务
```

## 维护

```bash
systemctl list-timers cf-ddns.timer            # 查看下次执行时间
journalctl -u cf-ddns -n 20 --no-pager         # 查看最近日志
systemctl start cf-ddns.service                # 立即执行一次
```

修改执行间隔：执行 `systemctl edit cf-ddns.timer`，写入以下内容后保存，再执行 `systemctl restart cf-ddns.timer`。第一行用于清除默认的 5 分钟。

```ini
[Timer]
OnUnitActiveSec=
OnUnitActiveSec=10min
```

更新：重新执行「安装」中的下载与 `install` 命令，已有配置和自定义间隔不会被覆盖。

卸载：

```bash
systemctl disable --now cf-ddns.timer
rm -f /usr/local/bin/cf-ddns /etc/cf-ddns.conf /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
systemctl daemon-reload
```

## 说明

- 记录不存在时按配置新建；已存在时只更新 IP，不修改 TTL 和代理状态。
- 同名同类型记录存在多条时报错退出，需在 Cloudflare 保留一条。
- 令牌仅保存在 `/etc/cf-ddns.conf`，不会出现在进程参数或日志中。
