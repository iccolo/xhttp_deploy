# xhttp_deploy

VLESS + XHTTP + REALITY 一键部署与管理脚本（纯 Bash，无需其它依赖管理工具）。

安装后得到一个全局命令 `xhttp`，交互式菜单完成部署、换密钥、换域名、出二维码等日常运维。

## 特性

- 自动安装最新版 Xray-core，生成完整可用的服务端配置
- 写入配置后双重校验：`jq` 校验 JSON 语法 + `xray -test` 校验配置合法性，不合法直接终止，不会留下坏配置
- 部署前检测端口占用（443 被 nginx/caddy 占用会提前提示）
- REALITY 密钥解析兼容不同 Xray 版本的输出（标准 base64 与 base64url 均可），解析失败会提示手动填入而不是静默写空值
- 输出 `vless://` 导入链接与终端二维码（v2rayNG 可直接扫码）
- 支持自更新：`xhttp update` 从本仓库拉取最新版本

## 一键安装

在 VPS（root 用户，systemd 系统）上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/iccolo/xhttp_deploy/main/xhttp-manager.sh | bash -s -- install && xhttp
```

若 `raw.githubusercontent.com` 访问不通，改用 jsDelivr CDN 启动（脚本内部仍会依次尝试多个源）：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/iccolo/xhttp_deploy@main/xhttp-manager.sh | bash -s -- install && xhttp
```

安装完成后脚本位于 `/usr/local/bin/xhttp`，之后在任意目录直接运行 `xhttp` 即可。

## 命令

| 命令 | 说明 |
| --- | --- |
| `xhttp` | 进入交互式管理菜单 |
| `xhttp install` | 安装/重装为全局命令 `/usr/local/bin/xhttp` |
| `xhttp update` | 从本仓库拉取最新版本并覆盖自身 |
| `xhttp -h` | 显示用法 |

自更新会先下载到临时文件并做 `bash -n` 语法校验，校验失败则放弃更新（当前版本不受影响）；已是最新版时提示无需更新。

## 菜单功能

```
1. 一键部署 / 重置 XHTTPS 服务器
2. 查看节点一键导入链接 & 二维码
3. 修改伪装域名 (SNI)
4. 修改 UUID
5. 检查 Xray 运行状态与日志
6. 重启 Xray 服务
7. 重新生成 REALITY 密钥对（修复空私钥）
8. 更新脚本到最新版（从 Git 拉取）
0. 退出脚本
```

注意：菜单 1 是**重置**而非续跑——会重新下载 Xray、重新生成 UUID 与密钥对（旧客户端链接全部失效）、覆盖配置文件。仅想修配置时用 7 或改完配置后用 6 重启。

## 涉及的文件

| 路径 | 说明 |
| --- | --- |
| `/usr/local/bin/xhttp` | 脚本本体 |
| `/usr/local/etc/xray/config.json` | Xray 服务端配置 |
| `/usr/local/etc/xray/env_info.env` | 记录 REALITY 公钥（`PUBKEY`），用于生成客户端链接 |

## 常见问题

**Xray 启动失败，日志提示私钥相关错误**

配置中 `privateKey` 为空会导致 Xray 拒绝启动。执行 `xhttp` 选 **7** 重新生成密钥对即可（会自动校验并重启）。

配置合法性可直接手动确认：

```bash
xray -test -c /usr/local/etc/xray/config.json
journalctl -u xray -n 20 --no-pager
```

**服务起不来，日志显示 `status=23`**

先判断是配置问题还是运行时问题：

```bash
xray -test -c /usr/local/etc/xray/config.json
```

- 报错 → 配置本身有问题，按报错修
- 输出 `Configuration OK` → 配置没问题，是**运行时**失败，最常见的是运行用户无权绑定特权端口

端口 < 1024（如 443）时，若 `/etc/systemd/system/xray.service` 里是 `User=nobody` 且缺少 `AmbientCapabilities=CAP_NET_BIND_SERVICE`（或 systemd 版本 < 229 不支持该特性），Xray 会因绑定端口失败而退出。修复：

```bash
sed -i 's/^User=.*/User=root/' /etc/systemd/system/xray.service
systemctl daemon-reload && systemctl restart xray
systemctl is-active xray
```

更安全的方式是保留 `nobody` 并加上 capabilities（需 systemd ≥ 229）：

```ini
[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
```

脚本菜单 5 在服务未运行时会自动打印这类诊断（service 的 User/Capabilities、systemd 版本、端口是否特权、端口占用、残留进程）。

**端口被占用**

```bash
ss -tlnp 'sport = :443'
```

换一个端口，或停掉占用 443 的 nginx/caddy。防火墙需放行对应端口：

```bash
ufw allow 443/tcp
```

**伪装域名（SNI）连不通**

REALITY 的目标站点必须支持 TLS1.3 + X25519。脚本会用 `xray tls ping` 预检，握手超时建议换域名。

**客户端连不上**

依次检查：

- 服务器 IP/端口可达、防火墙已放行
- SNI 域名可用（支持 TLS 1.3 + X25519，且服务器能访问到它）
- 客户端与服务端时间偏差不超过 90 秒（REALITY 会校验时间戳）
- 导入链接里的 `pbk`（公钥）与服务端当前私钥配对、`sni` 与服务端 `serverNames` 一致

**换过密钥（菜单 7）或改过域名（菜单 3）后，必须重新导入链接**，否则客户端会因 SNI/公钥不匹配而握手失败，典型表现就是 `EOF`。

## 维护

脚本改动后推送到 `main` 分支，用户侧执行 `xhttp update` 即可同步。

```bash
git add xhttp-manager.sh
git commit -m "..."
git push origin main
```

仓库内的文件名必须为 `xhttp-manager.sh`，分支必须为 `main`，否则自更新链接会 404。jsDelivr 有缓存，一般几分钟后生效，实时生效走 raw 源。

## 环境要求

- root 权限
- systemd（用于 `systemctl` 管理 xray 服务）
- 会自动安装：`jq`、`curl`、`qrencode`、`openssl`
