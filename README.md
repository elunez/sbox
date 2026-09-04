# sbox - sing-box 通用节点与流量管理面板

**sbox** 是一个基于 **sing-box** 的全能节点管理与内核级流量监控面板，全系统兼容 Debian / Ubuntu、CentOS / RHEL / Rocky / AlmaLinux、Alpine Linux（自动适配 systemd 与 OpenRC）。

## 主要特性

- **多协议入站支持**：支持 AnyTLS、Shadowsocks（含 2022-blake3 与传统 AEAD）、Trojan、Hysteria2、VLESS + REALITY、SOCKS5、HTTP / HTTPS。
- **全能出站路由**：每个节点可独立指定出口方式，支持 Direct、AnyTLS、Shadowsocks、Trojan、Hysteria2、VLESS + REALITY、SOCKS5 / SOCKS5H、HTTP / HTTPS。
- **动态域名与证书联动**：新增或修改节点时支持绑定不同域名。对于需要证书的协议（AnyTLS、Trojan、Hy2），系统会自动检测证书，未申请时可一键通过 Let's Encrypt（首选 DNSPod Token DNS-01 API、次选 Cloudflare DNS-01 API、Web 目录 Webroot 或独立 80 端口 Standalone）免开放端口签发证书；Shadowsocks 与 VLESS REALITY 无需证书，开箱即用。
- **精准流量监控与配额管理**：
  - 基于内核级 **nftables** 进行端口流量双向/单向高精统计；
  - 支持设置月度流量限额（如 100GB、1TB、unlimited），超额后自动阻断端口；
  - 支持指定每月 **1-31 日**为流量重置日，后台通过 cron 自动清零计数器与配额并记录审计日志；
  - 支持手动立即重置单节点或全部节点流量。
- **终端管理面板（模块化分类清晰直观）**：
  - 清晰分区：核心安装（1-2）、节点与流量（3-5）、服务控制（6-8）、监控与证书（9-11）、维护与卸载（12-13）、0 退出；
  - 默认自启：安装及节点应用时默认启用 systemd 开机常驻自启；
  - 底部实时动态状态栏显示当前活跃节点数、服务状态（运行中/已停止/未安装）、流量 API 服务状态等。
- **输入安全保障**：输入密码、密钥与 API 凭据时简洁直观，无冗余提示。

## 控制面板布局

```text
  Sbox · Sing-box 节点管理面板
------------------------------------
  0. 退出脚本
------------------------------------
  1. 安装服务
  2. 更新服务
------------------------------------
  3. 节点管理
  4. 流量管理
  5. API 管理
------------------------------------
  6. 启动服务
  7. 停止服务
  8. 重启服务
------------------------------------
  9. 查看状态
 10. 日志管理
 11. 续签证书
------------------------------------
 12. 更新脚本
 13. 完全卸载
------------------------------------
活跃节点: 0
服务状态: 运行中 / 已停止 / 未安装
流量 API 服务: 运行中 (端口: 9090) / 已停止
------------------------------------
```

## 前置要求

1. 协议需要 SSL 证书时（如 AnyTLS/Trojan/Hysteria2），请确保域名解析（A/AAAA 记录）已指向本服务器；
2. `dnspod` 模式（默认首选）通过 DNSPod Token（Token ID 与 Token Key，格式形如 `12345,7a8b9c...`）进行 DNS-01 验证，无需占用 80 端口且支持通配符；
3. `cf` 模式通过 Cloudflare API（支持 API Token 或 Global Key + 邮箱）自动查询 Zone 并添加 TXT 记录，无需占用 80 端口；
4. `webroot` 模式复用现有 Nginx / Apache 等 Web 根目录；
5. `standalone` 模式临时监听 TCP 80 端口，适合未安装网站环境的机器；
4. VLESS REALITY 协议使用真实知名域名（默认 `www.microsoft.com`）伪装 SNI 握手，无需本地签发证书。

## 快速安装与使用

安装基础下载工具（Debian/Ubuntu 最小化系统）：

```bash
sudo apt-get update && sudo apt-get install -y curl
```

一键下载并启动管理菜单：

```bash
curl -fsSLO https://raw.githubusercontent.com/elunez/sbox/main/sbox.sh && chmod +x sbox.sh && sudo ./sbox.sh
```

安装完成后，脚本会自动安装至系统 PATH，后续随时在任意终端输入快捷命令即可唤出管理面板：

```bash
sbox
```
（支持直接输入 `sbox` 快速调出面板，普通用户运行时会自动调起 sudo）


## 节点管理与多协议

进入 **3. 节点管理**，支持：
1. **新增节点**：
   - 选择入站协议：AnyTLS、Shadowsocks、Trojan、Hysteria2、VLESS + REALITY、SOCKS5、HTTP / HTTPS；
   - 设定节点域名或公网 IP、端口、认证信息；
   - 若所填域名无本地证书，脚本自动提示并调用 Let's Encrypt 快速签发；
   - 配置流量计费模式（单向/双向）、月度限额（如 100GB）以及每月重置日（如 1日）；
   - 配置节点出口分流（Direct，或转至外部 AnyTLS / Shadowsocks / Trojan / Hysteria2 / VLESS REALITY / SOCKS5 / HTTP 出口）。
2. **修改节点**：随时调整现有节点的监听端口、认证密钥、伪装域名、出口路由或流量策略；
3. **单独修改出口**：为指定节点无缝切换转发出口或恢复直连；
4. **删除节点**：删除指定节点并自动清理其关联的 nftables 流量监控规则与定时重置任务；
5. **客户端配置与分享链接**：一键生成各节点的客户端连接链接（如 `anytls://`, `ss://`, `trojan://`, `hy2://`, `vless://`, `socks5://`, `http://`）以及 sing-box 客户端 `outbounds` 配置段落。

## 流量监控与重置日管理

进入 **4. 流量管理**：
- **实时流量列表**：查看所有节点的入站、出站、总流量、月配额、已使用百分比、重置日期与运行状态（正常 / 已超额阻断）；
- **配置月配额与重置日**：
  - 计费方式：单向（仅统计出站/下行）或双向（统计入站+出站）；
  - 月流量上限：支持 `unlimited`、`500MB`、`100GB`、`2TB` 等格式，输入 0 为不限制；
  - 每月重置日：支持 **1-31 日**，定时任务在重置日凌晨 00:05 自动执行；输入 0 或留空则不自动重置；
- **手动立即重置**：可单独重置某一端口的流量，或一键重置所有节点流量；重置后自动解除超额阻断；
- **流量日志追踪**：每次重置（无论是自动还是手动）都会详细记录时间戳、端口、节点名与已用流量至 `/etc/sbox/traffic_reset.log`。
- **精简静默日志**：sing-box 默认采用 `warn` 日志级别，仅记录异常与告警，免除海量连接日志刷盘，节省空间并保护隐私；可在面板菜单中一键清理系统日志或按需切换为 `info` / `debug` / `error`。

## 开放 API 接口服务 (Traffic API)

**sbox** 内置了轻量级、并发安全的 HTTP API 接口服务，基于系统自带 Python3 标准库运行，内存占用仅约 10MB，无需额外安装任何第三方包。方便外部监控系统、自建 Web 仪表盘或哪吒探针等监控程序实时获取 VPS 流量。

### 特性与能力
- **跨域友好**：默认开启 CORS 头（`Access-Control-Allow-Origin: *`），前端页面可直接 Ajax / Fetch 调用；
- **端口自定义**：默认监听 `0.0.0.0:6666`，可随时在交互菜单中调整；
- **可选 Token 鉴权**：支持配置访问密钥，请求时通过 Header `Authorization: Bearer <Token>` 或 URL 参数 `?token=<Token>` 验证，留空则完全公开访问；
- **常驻后台**：注册为 `sbox-api.service`，支持开机自启与异常自动重启。

### API 端点列表

| 请求方式 | 接口端点 | 说明 |
| :--- | :--- | :--- |
| `GET` | `/api/traffic` 或 `/api/traffic/all` | 获取全部节点的实时流量、配额、重置日以及全机汇总 |
| `GET` | `/api/traffic/{port}` | 获取指定监听端口节点的实时流量详情 |
| `GET` | `/api/status` | 获取服务运行状态与在线节点数 |

### 调用示例与返回数据

获取指定端口（如 443 端口）流量：

```bash
curl -fsSL http://<VPS_IP>:6666/api/traffic/443
```

若配置了 Token 鉴权：

```bash
curl -fsSL -H "Authorization: Bearer 你的Token" http://<VPS_IP>:6666/api/traffic/443
# 或
curl -fsSL "http://<VPS_IP>:6666/api/traffic/443?token=你的Token"
```

返回 JSON 结构示例：

```json
{
  "name": "节点1",
  "protocol": "anytls",
  "domain": "node.example.com",
  "port": 443,
  "input_bytes": 104857600,
  "output_bytes": 524288000,
  "total_bytes": 524288000,
  "input_formatted": "100.00 MB",
  "output_formatted": "500.00 MB",
  "total_formatted": "500.00 MB",
  "billing_mode": "single",
  "quota": {
    "enabled": true,
    "monthly_limit": "100GB",
    "monthly_limit_bytes": 107374182400,
    "reset_day": 1,
    "used_percent": 0.49
  },
  "is_blocked": false,
  "instance_id": "c1f7b8e2-...",
  "timestamp": "2026-09-03T15:30:00+08:00"
}
```

### API 管理指令

```bash
sudo sbox api                    # 进入 API 管理子菜单
sudo sbox api start              # 启动 API 服务
sudo sbox api stop               # 停止 API 服务
sudo sbox api restart            # 重启 API 服务
sudo sbox api serve [PORT]       # 临时前台启动测试 (按 Ctrl+C 停止)
sudo sbox --api-json [PORT]      # 命令行直接输出流量 JSON 数据
```

## CLI 快捷指令

除了图形化交互菜单外，本脚本完全支持命令行直接调用，便于自动化运维脚本接入：

```bash
# 核心操作
sudo sbox install          # 首次安装引导
sudo sbox upgrade          # 更新 sing-box 核心
sudo sbox update           # 检查并更新 sbox 管理脚本 (支持 --force 强制覆盖)
sudo sbox status           # 查看服务状态与各节点流量
sudo sbox logs             # 查看 sing-box 运行日志
sudo sbox show             # 查看客户端连接信息与分享链接
sudo sbox cert [--dry-run] # 续签证书或模拟演练
sudo sbox uninstall        # 完全卸载服务

# 服务控制
sudo sbox start            # 启动服务
sudo sbox stop             # 停止服务
sudo sbox restart          # 重启服务
sudo sbox enable           # 开启开机自启
sudo sbox disable          # 关闭开机自启

# 流量重置
sudo sbox --reset-traffic 443   # 立即重置 443 端口流量
sudo sbox --reset-traffic-all   # 立即重置所有节点流量

# 流量 API 接口
sudo sbox api                   # API 服务管理交互菜单
sudo sbox api start|stop        # 启停 API 服务
sudo sbox --api-json [PORT]     # 命令行直接输出流量 JSON
```

## 关键目录与文件位置

- sing-box 主配置文件：`/etc/sing-box/config.json`
- 域名证书存放目录：`/etc/sing-box/certs/<域名>/`
- sbox 管理配置与状态：`/etc/sbox/state.json`
- sbox 流量 API 配置：`/etc/sbox/api.json`
- Certbot 证书管理路径：`/etc/letsencrypt/live/<域名>/`
- Certbot 自动续签钩子：`/etc/letsencrypt/renewal-hooks/deploy/sing-box`
- DNSPod Token 凭据文件：`/etc/sbox/dnspod.json`
- Cloudflare API 密钥文件：`/etc/sbox/cf.json`
- 流量重置历史审计日志：`/etc/sbox/traffic_reset.log`
- 配置备份归档目录：`/etc/sbox/backups/`
- 系统服务单元：`/etc/systemd/system/sing-box.service`（Systemd）或 `/etc/init.d/sing-box`（OpenRC）
