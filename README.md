# mihomo-kit

*mihomo 代理控制台 —— 网络感知自动开关 TUN、多机场订阅管理、节点固定、时间同步、浏览器语言/时区对齐；全程用户态，免 sudo。*

> **状态**：阶段 0–5 已实施，主体验证通过。DNS 污染误判已修复；时间同步、语言/时区对齐、节点固定、网络白名单均已落地；手机 LAN 共享已落地（`proxy lan`，含认证与网络自适应）。（未完成的验证/待办记录在本机未入库文件 `docs/todo.local.md`。）
> **本机数据**（路径 / 网络 UUID / 端口 / 版本 / 快照计数）：模板见 [docs/local-env.md](docs/local-env.md)；本机实际值在未入库的 `docs/local-env.local.md`。
> **排障手册**：见 [docs/troubleshooting.md](docs/troubleshooting.md)。

---

## 目录

- [一、快速开始](#一快速开始)
- [二、设计](#二设计)
- [三、功能模块](#三功能模块)
- [四、运维](#四运维)
- [五、参考](#五参考)

---

## 一、快速开始

### 1.1 前置依赖

| 依赖 | 用途 |
|---|---|
| `mihomo`（MetaCubeX） | 代理核心，创建 TUN（CAP_NET_ADMIN） |
| `python3` + 标准库 | `proxy time` / `proxy lang` |
| NetworkManager（`nmcli`） | 网络识别 |
| `libnotify`（`notify-send`） | 桌面通知 |
| systemd（system + user） | 常驻服务 |

### 1.2 安装

1. 建目录：`config/`、`bin/`、`systemd/`、`docs/`、`config/providers/`。
2. 写 `config/config.yaml`（可从 `config/config.example.yaml` 复制），订阅链接用 `proxy sub` 管理。
3. GeoIP 软链：`ln -s /etc/clash/Country.mmdb config/Country.mmdb`。
4. 权限：`chmod 600 config/config.yaml`。
5. 系统服务 drop-in（**一次 sudo**）：仓库里是**模板** `systemd/10-confdir.conf.in`
   （不含本机路径），由安装脚本渲染并写入 `/etc/systemd/system/mihomo@.service.d/`：

   ```bash
   bin/install-systemd.sh --dry-run   # 先看渲染结果（不写系统）
   bin/install-systemd.sh             # 渲染 + 安装 + daemon-reload（会 sudo）
   ```
6. 启用服务：

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now mihomo@$(id -un).service   # 实例名 = mihomo@<登录名>
   sudo systemctl mask mihomo.service                  # 防误启 /etc/mihomo 版本抢端口
   ```

7. 用户态：`bin/*` 软链到 `~/.local/bin/`，`systemd/proxy-watch.service` 软链到 `~/.config/systemd/user/`：

   ```bash
   ln -s "$PWD/bin/proxy" "$PWD/bin/proxy-watch" "$PWD/bin/proxy-browser" ~/.local/bin/
   ln -s "$PWD/systemd/proxy-watch.service" ~/.config/systemd/user/
   systemctl --user enable --now proxy-watch.service
   ```

8. 自检：`proxy status`、`proxy usage`。

### 1.3 命令速查

```bash
proxy on | off | toggle      # 开/关/切换 TUN（全局代理）+ 通知
proxy status                 # 状态总览
proxy reload                 # 重载配置 + 刷新机场 + 按当前网络重新施加 TUN
proxy net add --current      # 把当前网络加入白名单（自动开关 TUN）
proxy sub set <机场名> URL   # 换机场订阅链接
proxy node                   # 列出/固定节点
```

完整命令见 [五、参考](#51-proxy-子命令总表)。

---

## 二、设计

### 2.1 目标与原则

1. 用 **mihomo** 在本机提供代理能力。
2. **只使用单个机场**（月付、直连为主；具体机场见本机 `docs/local-env.local.md`）。
3. **校园网完全不碰**：不启用 TUN 时不改路由表、不劫持 DNS。
4. **连手机热点 / 指定网络时自动启用代理**。
5. 网络切换时桌面通知梯子状态。

**核心原则**：代理的"开"完全靠**运行时切换**，配置文件里 `tun.enable` **永远是 `false`**。
重启后默认即安全的校园网状态，不会因忘记关闭而把校园网流量卷进代理。

**网络策略**（具体网络名与 UUID 见本机 `docs/local-env.local.md`）：

| 当前网络 | 代理状态 | 触发 |
|---|---|---|
| 白名单内网络（手机热点 / 家宽） | **TUN 开启，全局代理** | `proxy-watch` 自动 |
| 校园网 | **关闭，网络层零接触** | `proxy-watch` 自动 |
| 其他未列出网络 | **关闭**（保守默认） | `proxy-watch` 自动 |
| 任意网络 + 手动 `proxy on` | 开启 | 手动 |
| 开机 / 未联网 | 关闭（配置 `tun.enable: false`） | 默认安全 |

白名单：上表"开/关"由**网络白名单**决定，已抽为独立模块——数据 `config/networks.conf`、
逻辑 `bin/proxynet.sh`、命令 `proxy net`（见 [3.1](#31-网络白名单proxy-net)）。加/删网络不再需要改脚本。

### 2.2 架构

```
                     +--------------------------------+
   手动 -----------> |  proxy on|off|status        | --+
                     |  （切换 + 桌面通知）             |   |
                     +--------------------------------+   |
                                                          |  PATCH /configs
                     +--------------------------------+   |  {"tun":{"enable":...}}
   NetworkManager -->|  proxy-watch（systemd 用户服务）| --+
   （轮询活动连接）   |  （自动切换 + 桌面通知）         |   |
                     +--------------------------------+   |
                                                          v
                     +--------------------------------+
                     |  mihomo@<user>.service          |
                     |  （CAP_NET_ADMIN → 创建 TUN）    |
                     +--------------------------------+
```

**关键点**：TUN 设备由带 `CAP_NET_ADMIN` 的 **mihomo 服务进程**创建；调用方只发一个 HTTP 请求到控制器。
因此**开关代理在用户态完成，不需要 sudo**。

### 2.3 关键决策记录

| 决策 | 选择 | 理由 |
|---|---|---|
| 机场数量 | 单机场 | 简化；备用出口计划用后续自建 |
| 配置读取方式 | **drop-in 指定 `-d` 指向项目 config** | 无软链、无复制、无断链风险 |
| TUN 是否常驻 | **否**，仅指定网络下开启 | 避免路由表改动干扰校园网认证 |
| 自动触发 | **用户级 watcher（轮询）**，不用 NM dispatcher | 通知须从用户会话发；免 sudo。代价：~3s 延迟 |
| 网络识别 | **UUID 白名单为主 + 连接名兜底** | 见 [3.1](#31-网络白名单proxy-net) |
| 通知 | `notify-send` | KDE 原生 |
| DNS | `fake-ip` + DoH，bootstrap 用公共 IP | 不依赖校园 DNS，避免污染 |
| GEOIP 规则 | 只用 `GEOIP,CN`（**不用 `geosite:`**） | 系统只有 `Country.mmdb`，无 GeoSite 数据 |
| Geo 数据维护 | 继续软链 `/etc/clash/Country.mmdb`，不开 `geo-auto-update` | 软链目标 root 拥有，自动更新会因无写权限失败 |
| 嗅探 `sniffer` | **启用**（TLS/HTTP/QUIC） | TUN+`fake-ip` 下裸 IP 会丢域名，致域名规则失效 |
| CN 分流 | **`rule-providers`（cn-domain）+ `GEOIP,CN`** | 纯 `GEOIP,CN` 只看 IP 会误判中国域名 |
| 订阅拉取 | 启用 `etag-support` | 减少订阅流量 |
| `global-client-fingerprint` | **不使用**（已被移除） | 1.19.31 会报错；订阅节点**已自带** `client-fingerprint` |

### 2.4 目录结构

```
ConfMihomo/
├── README.md                     # 本文档（方案 + 命令）
├── LICENSE
├── .gitignore
├── config/
│   ├── config.yaml               # 真实配置（含订阅链接，600，gitignore）
│   ├── config.example.yaml       # 占位符模板
│   ├── local.conf.example        # 本机覆盖模板（复制为 local.conf 使用）
│   ├── airports.conf             # 机场清单（名字<TAB>链接，600，gitignore）
│   ├── networks.conf             # 网络白名单（本机，600，gitignore）
│   ├── networks.conf.example     # 白名单模板（脱敏占位，入库）
│   ├── Country.mmdb              # 软链 -> /etc/clash/Country.mmdb
│   └── providers/                # mihomo 运行时写入（含节点凭据，gitignore）
├── bin/
│   ├── env.sh                    # 环境/用户输入模块（目录/控制器/UA/组名/端口收口）
│   ├── libproxy.sh               # 共用库：控制 API / 通知封装
│   ├── proxynet.sh               # 网络白名单模块：读写 networks.conf + 命中判定
│   ├── proxytime.py              # 时间同步：经节点取时、比对、可选写入
│   ├── proxylang.py              # 语言/时区对齐：节点国家 → 浏览器语言/时区
│   ├── proxy                     # 手动 开/关/查询 + net/sub/time/lang/node
│   ├── proxy-browser             # 按当前 region 启动浏览器
│   ├── proxy-watch               # 网络变化监视 + 自动切换 + 通知
│   └── install-systemd.sh        # 渲染并安装 mihomo@ 的 drop-in（需 sudo）
├── systemd/
│   ├── proxy-watch.service       # 用户服务单元（免 sudo）
│   └── 10-confdir.conf.in        # mihomo@ 的 drop-in 模板（由 install-systemd.sh 渲染）
├── docs/
│   ├── local-env.md              # 本机数据模板（实际值在未入库 local-env.local.md）
│   └── troubleshooting.md        # 排障手册
└── mihomo-aur-build/             # 旧 AUR 构建目录（与运行配置无关，仅留档）
```

### 2.5 配置如何被 mihomo 读取

service 单元是 `ExecStart=/usr/bin/mihomo`（**没有 `-d`**），默认读 `$HOME/.config/mihomo`。
用 drop-in **覆盖 `-d`，直接指向项目 config**，做到"无软链、无复制、无歧义"。

仓库保存的是**模板**（不含本机路径），由安装脚本渲染出绝对路径：

```ini
# 模板 systemd/10-confdir.conf.in
[Service]
ExecStart=
ExecStart=@MIHOMO_BIN@ -d @CONF_DIR@
```

```bash
bin/install-systemd.sh            # 渲染 -> /etc/systemd/system/mihomo@.service.d/10-confdir.conf + daemon-reload
# 渲染结果示例（本机）：
#   ExecStart=/usr/bin/mihomo -d /home/<user>/ConfMihomo/config
```

- 改项目里的 `config.yaml` 立即生效；
- 不存在"编辑器原子保存断链"的问题；
- 代价：运行时产物（`providers/`、`cache.db`）落在项目里 → 用 `.gitignore` 排除；
- 手动前台调试需一致：`mihomo -d <项目>/config`。

> ⚠️ 两个坑：
> ① drop-in 覆盖 `ExecStart` 必须先写一行空的 `ExecStart=` 再写新的，否则不生效；
> ② **不要**在**系统**单元里用 `%h` / `%u` 指代服务用户——实测 systemd 会把 `%h` 解析成 **root** 的家目录（`/root`），必须用脚本渲染出绝对路径。

---

## 三、功能模块

### 3.1 网络白名单（`proxy net`）

**为什么不用 SSID / 不用 profile 的 user 标签**：

- **SSID**：NetworkManager dispatcher 环境变量里**没有 SSID**。
- **`user.data` 标签**：本机 `nmcli` 未暴露 `user.data` 字段，语法无法验证 → 放弃。

**三层结构**：

| 层 | 位置 | 作用 |
|---|---|---|
| 数据 | `config/networks.conf`（唯一真相，600，gitignore） | 一行一个网络：`UUID<TAB>连接名<TAB>备注` |
| 逻辑 | `bin/proxynet.sh`（由 `libproxy.sh` source） | 读写数据 + 命中判定 `net_desired_state` |
| 命令 | `proxy net` | `list` / `scan` / `add` / `rm` / `status` |

加/删网络**不用改代码**：

```bash
proxy net scan                    # 列出当前活动连接（序号/UUID/名字/类型/是否命中）
proxy net add --current 手机热点    # 把当前网络整条加入
proxy net add <序号|UUID|连接名> [备注]
proxy net rm <UUID|连接名>
```

- 首次运行会从 `config/networks.conf.example` 生成数据文件；**模板默认空白名单**，即任何网络都不自动开 TUN。
- 具体 UUID / 连接名见本机 `docs/local-env.local.md`（结构见模板 `docs/local-env.md`）。

**判定逻辑**：

```
读取所有活动连接的 {UUID, NAME}（已过滤 loopback 与 mihomo 自建 tun）
  ├─ UUID 命中白名单   → 开代理
  ├─ 名字命中白名单     → 开代理
  └─ 否则              → 关代理
（多连接并存：任一命中即开；加 2–3s 防抖避免切换抖动）
```

`proxy net add/rm` 后会**按当前网络立即重新施加一次 TUN**（等价 `proxy reload` 的效果）。

> UUID 稳定性：改连接名 / 改 Wi-Fi 密码 / 换网卡 / 重启都**不变**；"忘记网络"后重连（profile 重建）**会变** → 保留**连接名兜底**。两层都失效时用 `proxy net add <连接名>` 更新。

### 3.2 机场订阅（`proxy sub`）

清单 `config/airports.conf`（含 token，600，gitignore）是唯一真相；`proxy sub` 渲染进 `config.yaml`
的 `# >>> proxy:providers >>>` 标记块并同步策略组 `use`，自动用 `mihomo -t` 校验，失败回滚。

```bash
proxy sub list              # 名字 / 节点数 / 更新时间 / 链接掩码
proxy sub show <机场名>      # 单个机场详情（用量/到期）
proxy sub set <机场名> "https://...新链接..."
proxy sub add 备用机场 "https://...链接..."
proxy sub rm 备用机场
proxy sub fetch [名字]      # 强制刷新（先 API，失败自动直连兜底）
```

> ⚠️ 不要手改 `config.yaml` 的 provider 区块（由 `proxy sub` 自动生成）。

**过期分三种**：

| 情况 | 本质 | 现象 | 后果 |
|---|---|---|---|
| A. 链接失效 | 重置 token / 换域名 | 拉取 401/403/404 | 有缓存，**不会立刻断** |
| B. 套餐到期 / 流量用尽 | 账号层面失效 | 能拉取，节点全不可用 | **断网** |
| C. 机场跑路 / 被封 | 服务消失 | 全部失败 | **断网** |

mihomo 拉取失败时**保留上次成功的缓存** `config/providers/<名字>.yaml`，所以 A 通常还能撑一阵。
**不要删除 `config/providers/`**（含节点凭据，已 gitignore）。

流量 / 到期监控：mihomo 解析订阅响应头 `subscription-userinfo` 并经 API 暴露；
`proxy usage` 显示 已用 / 总量 / 剩余 / 到期；`proxy-watch` 每日自检，**到期前 3 天**或**流量 ≥90%** 时弹通知。

**重载配置的副作用**：`PUT /configs` 会按配置**重建监听**，而 `tun.enable` 恒为 `false` →
**正在生效的 TUN 会被关掉**。因此 **`proxy reload` = 重载配置 + 按当前网络重新施加 TUN**。

### 3.3 时间同步（`proxy time` + 内置 ntp）

**动机**：vmess / reality / shadowsocks-2022 等握手对时间敏感；校园网/热点常封 UDP，直连公共 NTP 不一定可达 → **经节点**取时更可靠。

| 层 | 实现 | 作用 | 需要 root |
|---|---|---|---|
| 协议层 | `config.yaml` 的 `ntp:` 块 | 修正 mihomo 内部 `ntp.Now()`（仅握手） | ❌ |
| 系统层 | `proxy time`（`bin/proxytime.py`） | 比对/写入**本机系统时钟** | 仅 `--set` 走 polkit |

```bash
proxy time               # 默认只报告
proxy time --set         # 偏差超阈值(默认 1.0s)时写系统时钟（polkit 弹窗）
proxy time --direct      # 不经 7890 直连取时（对照用）
proxy time --json        # JSON 输出
```

- 采样 3 次取**最小 RTT** 样本，`offset = remote − (t0+t1)/2`（包夹补偿单向延迟）。
- 时间源：`https://www.cloudflare.com/cdn-cgi/trace`（`ts=` 毫秒级，附带 `ip=`/`loc=` 证明走节点），备源 `https://www.gstatic.com/generate_204`（`Date` 头秒级）。
- **NTP 直连**：`fake-ip-filter` 例外 `+.pool.ntp.org` / `+.ntp.org`，`rules` 前置 `DOMAIN-SUFFIX,...,DIRECT`；`systemd-timesyncd` 源改为国内 NTP。原因：TUN 开着时 NTP 会被 fake-ip 接管、经代理转发，且选到不支持 UDP 的节点会同步失败。
- 自动触发：`proxy on` / `proxy reload` / `proxy-watch` 开 TUN 后**后台**自检，每个网络会话一次，超阈值才弹通知（**绝不自动写时钟**）。
- 精度：经高延迟节点时 HTTP-Date 受往返不对称影响，抖动约 ±0.7s，故默认阈值 1.0s。

### 3.4 语言 / 时区对齐（`proxy lang` / `proxy-browser`）

**动机**：网站看到的是**节点出口国家**；若浏览器仍发 `zh-CN` 且时区为 `Asia/Shanghai`，二者不一致会形成**指纹异常**。

> mihomo **不能**改写 `Accept-Language`、也没有 MITM；此功能在**浏览器层**落地，代理侧只负责判定节点国家。**不动系统 locale / 系统时区**。

```
开梯子:  节点出口 IP --(cloudflare trace loc)--> cc --> {Accept-Language, UI lang, TZ}
关梯子:  直连出口 IP --(同上, 不走代理)--------> cc --> {同上}
                                      │
                          config/region.json（唯一真相）
                                      │
              proxy-browser（Chromium flags / Firefox 专用 profile）
```

```bash
proxy lang              # 检测节点国家 → 预览
proxy lang apply        # 写入 config/region.json + 通知（重启浏览器生效）
proxy lang reset        # 回退本机直连 IP 的默认语言/时区
proxy lang set US       # 手动指定国家码
proxy lang show         # 查看已设置项并与当前节点比对

proxy-browser chromium  # 按当前 region 启动 Chromium
proxy-browser firefox   # 按当前 region 启动 Firefox（专用 profile）
```

- 自动跟随：`proxy on`/`reload` → 跟节点国家（变化才写+通知）；`proxy off`/`proxy-watch` 关 TUN → 回本机 IP；`proxy-watch` 另按间隔（默认 300s，仅 TUN=on）轮询跟随 auto-select 换国。
- 落地：Chromium 用 `TZ` + `--accept-lang` / `--lang`；Firefox 用 `TZ` + 专用 profile 的 `user.js`。
- 已知限制：需**重启浏览器**生效；仅经 `proxy-browser` 启动的浏览器生效；时区为国家级近似；`loc` 是 Cloudflare 对出口 IP 的 GeoIP。

### 3.5 节点选择 / 固定（`proxy node`）

**动机**：`PROXY` 组默认是 `自动选择`(url-test)，节点会随测速漂移；有时想**手动锁定**某节点。

```bash
proxy node                 # 列出可选节点（序号 / 当前 / 延迟；默认不测速）
proxy node list --ping     # 列出并测速
proxy node use 3           # 按序号固定
proxy node use <节点名>     # 按名字精确 / 唯一子串模糊
proxy node auto            # 切回「自动选择」（取消固定）
proxy node ping [序号|名字] # 测速；不带参数=全组
proxy node current         # 当前节点 + 固定/自动
```

- 输入解析：**纯数字=序号（1 起）** → **完整名字精确** → **唯一子串模糊**（忽略大小写）。
- 持久化：`PUT /proxies/PROXY {"name":...}`；`profile.store-selected: true` 写进 `config/cache.db`，重启由 `selector.ForceSet` 恢复 → **重启仍固定**。
- 固定节点"消失"：`Selector.Now()` 在所选节点不存在时**静默回退组内第一个代理**；项目自行记忆（`$XDG_RUNTIME_DIR/mihomo-node.pinned`）并在 `proxy sub fetch|reload` 与 `proxy-watch` 定时（默认 60s）比对，消失则弹一次「固定节点已失效」通知。
- `proxy node use` 成功后自动触发语言/时区跟随新节点国家。
- 仅管理 `PROXY` 组；节点名含 emoji/空格时用序号或子串最省事。

### 3.6 配置要点

> **完整配置以 `config/config.yaml` 为唯一真相来源**（含订阅链接，权限 600）。本节只记关键项与"为什么"。

**基础**

| 配置 | 值 | 说明 |
|---|---|---|
| `mixed-port` | 7890 | HTTP + SOCKS 混合端口 |
| `bind-address` | 127.0.0.1 | 静态仅本机；开 LAN 共享时运行时改 `*`（见 §3.7） |
| `allow-lan` | `false` | 静态关闭；由 `proxy lan` / `proxy-watch` 运行时切换（见 §3.7） |
| `authentication` | `proxy:<见 config.yaml>` | 局域网客户端的 Basic 认证；本机回环豁免 |
| `skip-auth-prefixes` | `127.0.0.1/32`、`::1/128` | 本机免认证；**API 重载会丢该字段，脚本自动补回**（见 §3.7） |
| `external-controller` | `127.0.0.1:9090` | **运行时切换 TUN 的入口** |
| `etag-support` | `true` | 订阅拉取用 ETag 缓存 |
| `find-process-mode` | `off` | 不用 `PROCESS-*` 规则，省 CPU |

> `global-client-fingerprint` 在 1.19.31 **已被移除**（启动报错）；订阅节点**已自带** `client-fingerprint`。

**嗅探 `sniffer`（启用）**：TUN + `fake-ip` 下裸 IP 连接会丢域名 → 从 TLS SNI / HTTP Host / QUIC 还原域名。
`skip-domain` 例：Apple 推送（`+.push.apple.com`）、米家/小米（`+.mijia.com`、`+.miio.com`）。

**DNS**

| 项 | 说明 |
|---|---|
| `enhanced-mode: fake-ip` | 配合 TUN |
| `default-nameserver` / `nameserver` | 仅解析 DoH 域名 / 国内 DoH |
| `proxy-server-nameserver` | **专解析节点自己的域名**，避免被 fake-ip 污染 |
| `fallback` / `fallback-filter` | **未启用**（实测热点与校园网都直连不了 8.8.8.8/1.1.1.1，fallback 是**直连**发出 → 每次等超时反而更糟） |

**订阅与策略组**：`proxy-providers.<名字>`（UA 不对机场会返回 base64）；机场返回**完整配置**也没关系（provider **只提取 `proxies` 字段**）；策略组 `自动选择`(url-test) → `PROXY`(select，默认走自动选择，可手选节点或 `DIRECT`)。

**TUN**：`enable: false` **永远保持**（由 `proxy` / `proxy-watch` 运行时切换）；`stack: mixed`；`auto-route: true`；`auto-redirect: false`（需 nftables）。

**规则**：内网/多播/广播 → `DIRECT`；`google`/`youtube` → `PROXY`（按域名短路，规避污染 IP 被 `GEOIP,CN` 误判）；`cn-domain` → `DIRECT`；`GEOIP,CN` → `DIRECT`；其余 → `PROXY`。

**规则集 `rule-providers`**：从 `MetaCubeX/meta-rules-dat` 拉取并缓存到 `config/rules/*.mrs`（`behavior: domain`，间隔 24h）：

| 名称 | 来源 | 说明 |
|---|---|---|
| `cn-domain` | `cn.mrs` | 精准 CN 分流（比 `GEOIP,CN` 准） |
| `google` | `google.mrs` | 污染 IP 兜底 → PROXY |
| `youtube` | `youtube.mrs` | 同上 |

> 首次启动需能访问这些 URL；下载失败时规则集为空，退化为只有 `GEOIP,CN`（不致命）。

### 3.7 LAN 共享（`proxy lan`，已实施）

**动机**：手机（iOS / 安卓）临时翻墙（如注册 Google 账号扫二维码），直接借用电脑上已跑通的
mihomo，手机不装任何 App、也不用外区账号。

**拓扑**：手机与电脑连**同一网段**（家用路由器 Wi-Fi，或手机热点下的其它设备），
电脑 `mixed-port` 监听 LAN，手机 `Wi-Fi → 配置代理 → 手动 → 电脑IP:7890`。

**与 TUN 一致：运行时切换**。`config.yaml` 静态值恒为关闭
（`bind-address: 127.0.0.1` / `allow-lan: false`），由脚本运行时改 `allow-lan` + `bind-address`。

```bash
proxy lan              # = status：共享状态 / 本机局域网 IP / 认证账号
proxy lan on           # 开（allow-lan=true，监听 0.0.0.0）
proxy lan off          # 关（恢复仅本机 127.0.0.1）
proxy lan auth         # 查看当前账号 / 密码 / 来源
proxy lan auth rotate  # 重新随机生成（账号 + 密码）
proxy lan auth set <账号> <密码>   # 手动指定（或 user / pass 单独改）
```

**认证（默认开启，默认随机）**：所有**非本机**客户端必须 Basic 认证；本机回环经
`skip-auth-prefixes`（`127.0.0.1/32`、`::1/128`）豁免，故 `127.0.0.1:7890` 的原有用法
（`curl`、`proxy time`、`proxy-browser`）**不受影响**。手机端在 Wi-Fi 代理里填
`主机名=电脑IP`、`端口=7890`、`用户名/密码 = proxy lan auth 显示的账号`。

- **唯一真相**：`config/lan-auth.conf`（一行 `user:pass`，权限 600，已 gitignore；模板 `lan-auth.conf.example`）。
- **默认随机**：文件缺失或不含合法凭证行时，首次运行自动随机生成（账号 `u+9位`、密码 16 位）。
- **落盘与生效**：`proxy lan auth` 把凭证渲染进 `config.yaml` 的 `proxy:lan-auth` 标记块，并重载生效。
- 约束：账号 `A-Za-z0-9_-`、密码 `A-Za-z0-9`（8..64），均不含冒号。

> **两个 mihomo 1.19.31 实测坑**：
> 1. `PATCH /configs` **不支持**改 `authentication`（返回 204 但静默忽略）→ 改凭证必须 `PUT /configs` 重载
>    （由 `lan_auth_commit` → `reload_and_reapply` 完成，并顺带按网络恢复 TUN / LAN）。
> 2. `skip-auth-prefixes` 在部分重载路径下会丢失 → `set_lan()` 每次施加 LAN 配置时一并 `PATCH` 补回，
>    保证本机（回环）始终免认证。

**手动开、自动关**：`proxy lan on` 才开启共享；`proxy-watch` 在网络变化时**只做自动关**——
离开白名单网络（含校园网）立即关掉 `allow-lan`，避免被同网段他人白用。
**切回白名单不会自动开**（需再执行 `proxy lan on`）；`proxy reload` 这类会复位运行时状态的操作，
按"手动意图"恢复（曾手动开则为开）。认证始终由 `config.yaml` 强制。

**前提 / 风险**：

- 手机与电脑须同一网段；**手机不能是热点主机**（iOS 不给蜂窝 / 热点接口设代理）。
- 校园网常开 AP / 客户端隔离 → 手机可能连不到电脑；用家用路由器最稳。
  两部手机时，可让"另一部手机"与电脑同连一个热点，但**是否被隔离因机型而异，需实测**。
- 手机走代理会消耗机场流量，用完建议 `proxy lan off`。
- 防火墙需允许 `7890/tcp`（本项目防火墙默认 inactive）。

**手机端自足方案**（不依赖电脑）：安卓侧载 APK（Karing / ClashMetaForAndroid / v2rayNG / NekoBox，
导入 `airports.conf` 的订阅）；iOS 大陆区无此类 App，需非中国区 Apple ID → 现实里优先安卓侧载或本节 LAN 共享。

---

## 四、运维

### 4.1 权限与回滚

| 操作 | 需要 sudo |
|---|---|
| 写 mihomo@ 的 drop-in（`bin/install-systemd.sh`）+ `daemon-reload` | ✅ 一次 |
| 安装/启用 mihomo 服务 | ✅ 一次 |
| `systemctl --user` 用户服务 | ❌ |
| `proxy` 切换 TUN | ❌ |
| 改 `config/config.yaml` / 白名单 / `local.conf` | ❌ |
| 写系统时钟（`proxy time --set`） | ✅ pkexec 现场授权（无图形会话回退 sudo） |

**回滚**：

```bash
systemctl --user disable --now proxy-watch.service
bin/install-systemd.sh --uninstall         # 移除 drop-in + daemon-reload（会 sudo）
sudo systemctl disable --now mihomo@$(id -un).service
```

### 4.2 验证清单（快照）

**阶段 2（前台试跑）**：

- [x] `mihomo -d <项目>/config` 前台启动无报错
- [x] provider 正常加载节点；`cn-domain` 规则集加载成功
- [x] `curl -x http://127.0.0.1:7890 https://www.google.com` → 200
- [x] 校园网下 `ip route` 无 TUN、路由表零改动
- [x] 热点下 CLI 可访问被墙站点；CN 站点直连/经代理均通（`qq.com`/`163.com` 需带浏览器 UA）
- [x] 控制器确认 `tun.enable=false`；DNS 为 fake-ip（`198.18.x.x`）

**阶段 5（自动切换）**：

- [x] 切到热点：~3s 内通知"梯子：已开启"，`ip link` 出现 `mihomo`
- [x] 全局代理（CLI + 非 curl 应用）可用；`getent hosts www.google.com` → fake-ip
- [x] 切回校园网：通知"梯子：已关闭"，TUN 消失，`ip rule` 复原
- [x] 手动 `proxy on/off/status/toggle/usage/reload` 正常并有通知

> 未完成的验证项与后续待办记录在本机未入库文件 `docs/todo.local.md`。
> 历史遗留：热点下 YouTube 封面偶发加载不出 → 已定位为国内 DoH 污染 + `GEOIP,CN` 误判，已用域名规则修复。

### 4.3 已知坑（索引）

细节与排查命令见 [docs/troubleshooting.md](docs/troubleshooting.md)。

1. **订阅 UA**：机场按 UA 返回不同格式；配置预置 `clash-verge/v2.0.0`。
2. **订阅返回完整配置也没问题**：provider **只提取 `proxies` 字段**。
3. **无 GeoSite**：只能用 `GEOIP,CN`，不能用 `GEOSITE` 或 `nameserver-policy: geosite:cn`。
4. **校园网认证门户**：不开 TUN 风险很低；门户打不开时把域名加 `DIRECT`。
5. **`auto-redirect` 需要 nftables**：先关。
6. **服务实例名** = `mihomo@<登录名>`，注意用户名大小写须与服务一致（本机具体名见 `docs/local-env.local.md`）。
7. **TUN 与 Docker / 虚拟机**：TUN 开启期间可能互相影响；不开就没事。
8. **切换抖动**：网络切换时活动连接可能短暂为空 → 需 2–3s 防抖。
9. **"忘记网络"会让 UUID 变化** → 名字兜底可覆盖；两层都失效用 `proxy net add <连接名>`。
10. **drop-in 覆盖 `ExecStart`**：必须先写一行空的 `ExecStart=`。
11. **`global-client-fingerprint` 已被移除**：1.19.31 启动报 error；订阅节点已自带。
12. **订阅端点较慢、偶发超时**：provider 有 `interval` 重试，缓存保留上次成功结果。
13. **`geo-auto-update` 与软链冲突**：软链目标 root 拥有，自动更新会因无写权限失败。
14. **`sniffer` 会改变少量流量的目标判定**：遇站点异常先把域名加 `sniffer.skip-domain`。
15. **规则集首次启动需联网下载**：失败时规则集为空（退化为 `GEOIP,CN`），缓存后不再依赖网络。
16. **校园网对部分国内 IP 可达性间歇抖动**：不走 mihomo 也复现 → 网络环境问题。
17. **部分国内站点要求浏览器 UA**：`www.qq.com` 无 UA 返回 501、`www.163.com` 返回 403。用 curl 复验 CN 站点**务必加 `-A 'Mozilla/5.0'`**。
18. **出口地区不固定**：`自动选择`(url-test) 会落到不同地区；需固定出口应在 `PROXY` 组手选。
19. **`LimitNPROC=500` 导致启动失败**：`RLIMIT_NPROC` 统计**同一 UID 的线程数**；桌面会话常 >500 → `203/EXEC`。drop-in 里已用 `LimitNPROC=infinity` 覆盖。
20. **TUN 开启后会被 NM 列为活动连接**（`type=tun`）：`current_network()` 已过滤 `tun`，否则网络指纹会因自己开 TUN 而抖动。
21. **TUN 走"策略路由"**：写 `ip rule`（9000–9010）与 `table 2022`，**主路由表基本不变**；排查看 `ip rule` 与 `ip route show table all`。
22. **国内 DoH 返回污染 IP 且被 `GEOIP,CN` 误判**：fake-ip 下正常浏览不受影响，但污染 IP 落在 CN 段会造成部分境外资源时好时坏 → 已用 `google`/`youtube` 域名规则修复。
23. **重载配置必须用 `PUT /configs`，不能用 `PATCH`**：`PATCH` 传 `{"path":…}` 不生效。
24. **换订阅链接的两个坑**：URL 引号内多空格会 `EOF`/503；节点全挂时拉不动新订阅（"鸡生蛋"）。已由 `proxy sub set` 自动化（自动清洗/拉取/直连兜底）。
25. **YouTube 视频内容加载不出（缩略图正常）**：视频走 QUIC(UDP/443)，某些节点不转发 UDP。曾用规则封禁 QUIC，实测**视频仍缓冲**（瓶颈在带宽），**已撤回**。

### 4.4 可选项（未启用，已验证可行）

| 项 | 说明 |
|---|---|
| Geo 数据自管 + `GEOSITE` | 换项目内真实 `geoip.metadb` + `geosite.dat`，开 `geo-auto-update`（分流更准，文件变大） |
| 图形面板 `external-ui` | `metacubexd`，访问 `http://127.0.0.1:9090/ui` 点选节点 |
| `secret` / `external-controller-unix` | 控制器加密（本机单用户收益低） |
| `IN-TYPE` / `SUB-RULE` / `override` | 高级规则与节点字段批量改写 |

#### 4.4.1 LAN 共享

**已实施**，见 [§3.7 LAN 共享](#37-lan-共享proxy-lan已实施)。

---

## 五、参考

### 5.1 `proxy` 子命令总表

| 命令 | 作用 |
|---|---|
| `proxy on` / `off` / `toggle` | 开/关/切换 TUN + 通知 |
| `proxy status` | 状态总览：梯子 / TUN / 当前网络 / 节点 / 语言 / 时区 |
| `proxy usage` | 所有机场的流量与到期 |
| `proxy reload` | 重载配置 + 刷新机场 + 按当前网络重新施加 TUN / LAN 共享 |
| `proxy time [--set]` | 比对本地↔节点时间；`--set` 才写系统时钟 |
| `proxy lang [apply\|reset\|set\|show]` | 浏览器语言/时区跟随节点 |
| `proxy-browser [chromium\|firefox]` | 按当前 region 启动浏览器 |
| `proxy node [list\|use\|auto\|ping\|current]` | 手动选择/固定节点 |
| `proxy net [list\|scan\|add\|rm\|status]` | 网络白名单 |
| `proxy lan [status\|on\|off\|auth]` | LAN 共享（手动开、离开白名单自动关；`auth` 管理随机账号密码） |
| `proxy sub [list\|show\|add\|set\|rm\|fetch]` | 机场订阅管理 |
| `proxy net -h` / `proxy lan -h` / `proxy sub -h` / `proxy time -h` / `proxy lang -h` / `proxy node -h` | 主题详情 |
| `proxy-watch -h` | 网络变化自动开关 TUN，并自动关 LAN 共享（systemd 用户服务） |

### 5.2 环境与用户输入（`config/local.conf`）

脚本的环境相关值统一收口在 `bin/env.sh`，优先级：**环境变量 > `config/local.conf` > `config.yaml` 读取 > 自动推导 > 内置默认**。

可覆盖项（复制 `config/local.conf.example` 为 `config/local.conf`）：`MIHOMO_PROJECT_DIR`、`MIHOMO_CONF_DIR`、
`MIHOMO_USER`、`MIHOMO_SERVICE`、`MIHOMO_BIN`、`MIHOMO_CTRL`、`MIHOMO_MIXED_URL`、`SUB_UA`、
`NODE_GROUP`、`HEALTHCHECK_URL`、`DELAY_TIMEOUT_MS`、`PROXYLANG_HOME_CC`、
`MIHOMO_LAN_BIND_CLOSED`、`MIHOMO_LAN_BIND_OPEN`、`MIHOMO_LAN_SKIP_AUTH_JSON`、
`MIHOMO_LAN_STATE_FILE`、`MIHOMO_LAN_AUTH_FILE`。

`proxy-watch` 另有运行时可调参数（环境变量）：`PROXY_WATCH_POLL`(3)、`PROXY_WATCH_DEBOUNCE`(3)、
`PROXY_WATCH_LANG_INTERVAL`(300)、`PROXY_WATCH_NODE_INTERVAL`(60)。

---

## License

本项目采用 [MIT License](LICENSE) © 2026 Luobo-XD。
