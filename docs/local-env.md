# 本机环境数据（local-env）— 模板

> 本文件是**占位模板（入库）**，集中定义"只对某一台机器成立"的数据应当记录哪些项。
> **本机实际值放在同目录、已 gitignore 的 `docs/local-env.local.md`**（复制本文件后填写）。
> `README.md` 只保留通用方案与命令；需要本机具体值时，查 `local-env.local.md`。
> 换机器 / 迁移时只改 local 文件，不必动方案文档。

## 1. 路径与文件

| 项 | 值 |
|---|---|
| 项目目录 | `<项目目录>`（如 `~/ConfMihomo`） |
| 运行配置目录（`-d` 目标） | `<项目目录>/config` |
| 主配置（含订阅链接，`600`） | `<项目目录>/config/config.yaml` |
| 本机覆盖（可选，gitignore） | `<项目目录>/config/local.conf` |
| mihomo drop-in | `/etc/systemd/system/mihomo@.service.d/10-confdir.conf` |
| GeoIP 软链 | `config/Country.mmdb` → `/etc/clash/Country.mmdb` |
| NTP 源（timesyncd） | `/etc/systemd/timesyncd.conf` |
| 用户态软链 | `~/.local/bin/{proxy,proxy-browser,proxy-watch}` |
| 用户服务软链 | `~/.config/systemd/user/proxy-watch.service` |
| 旧 AUR 构建目录 | `mihomo-aur-build/`（仅留档，gitignore） |

## 2. 用户与服务

| 项 | 值 |
|---|---|
| 登录用户 | `<登录名>` |
| mihomo 系统服务实例 | `mihomo@<登录名>.service`（注意用户名大小写） |
| 网络监视用户服务 | `proxy-watch.service` |
| 被 mask 的版本 | `mihomo.service`（防止抢端口） |

> 服务名与用户由 `bin/env.sh` 自动推导：`mihomo@$(id -un)`，通常无需手填。

## 3. 网络白名单（触发 TUN 的网络）

| UUID | 连接名 | 备注 |
|---|---|---|
| `<UUID>` | `<连接名>` | 例如：手机热点 |
| `<UUID>` | `<连接名>` | 例如：家宽 |

- 校园网等**不加入**白名单的网络：`<网络名>`。
- 数据文件：`config/networks.conf`（本机，gitignore）；模板 `config/networks.conf.example`（占位符）。
- 管理：`proxy net add/rm`（详见 README「网络白名单」一节）。

## 4. 端口 / 地址 / CIDR

| 项 | 值 |
|---|---|
| 混合代理端口 | `<host:port>`（默认 `127.0.0.1:7890`） |
| 控制器 | `<host:port>`（默认 `127.0.0.1:9090`） |
| DNS 监听 | `<host:port>`（默认 `127.0.0.1:1053`） |
| fake-ip 段 | `198.18.0.1/16` |
| TUN 网关 / 路由 | `198.18.0.2 dev mihomo`、`table 2022`、`ip rule 9000–9010` |
| 国内 DoH | `https://223.5.5.5/dns-query`、`https://doh.pub/dns-query` |
| default-nameserver | `223.5.5.5`、`119.29.29.29` |

> 端口 / 控制器由 `bin/env.sh` 从 `config.yaml` 读取（`mixed-port`、`external-controller`、`bind-address`）。

## 5. 平台与版本

| 项 | 值 |
|---|---|
| 系统 | `<发行版 + 桌面 + 会话类型>` |
| mihomo | `<版本>` |
| Python | `<版本>` |
| 订阅 UA | `<UA>`（示例 `clash-verge/v2.0.0`） |
| 机场 | `<机场名>`（provider 名见 `config/airports.conf`） |

## 6. 时点快照（会随时间漂移，勿当恒定事实）

| 项 | 记录值 | 备注 |
|---|---|---|
| provider 节点数 | `<数量>` | 以 `proxy sub show` / API 为准 |
| 规则集条数 | `<cn / google / youtube 条数>` | 会随上游更新 |
| 节点名示例 | `<示例>` | 会随机场变 |
| 出口示例 | `<IP (地区)>` | 随 `自动选择` 漂移 |
| 污染 IP 样本 | `<IP…>` | 见 README 已知坑 |
| 验证日期 | `<YYYY-MM-DD>` | |
| `region.json` 现值 | `<cc / accept-language / TZ>` | 由 `proxy lang` 写入，随节点变 |

## 7. 如何修改

- **本机实际值**：复制本文件为 `docs/local-env.local.md`（已 gitignore）后填写。
- **本机覆盖**（路径/端口/UA/组名/默认国家…）：复制 `config/local.conf.example` → `config/local.conf` 后按注释改。
- **网络白名单**：`proxy net add/rm`（写入 `config/networks.conf`），不要手改代码。
- **服务路径**：`systemd/10-confdir.conf` 用 `%h/ConfMihomo/config`（`%h` = 服务用户主目录）。
