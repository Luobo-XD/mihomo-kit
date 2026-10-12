# mihomo 代理方案

> 状态：**阶段 0–5 已实施；主体验证通过（待补 TP-LINMZ / 重启）；DNS 污染误判已修复（§15）**
> 日期：2026-10-12
> 平台：Arch Linux + KDE Plasma 6 (Wayland)
> 项目目录：`/home/Luo_bo/ConfMihomo/`
> 阶段 3–5 实施计划：`/home/Luo_bo/.opencode/plan/mihomo-stage3-5-plan.md`

---

## 1. 目标

1. 用 **mihomo** 在本机提供代理能力
2. **只使用单个机场：NanoCloud**（月付、直连为主）
3. **校园网完全不碰**：不启用 TUN 时不改路由表、不劫持 DNS
4. **连手机热点 / 指定网络时自动启用代理**
5. **网络切换时桌面通知梯子状态**

---

## 2. 网络策略

| 当前网络 | 代理状态 | 触发 |
|---|---|---|
| `iPhone`（手机热点，UUID ×2） | **TUN 开启，全局代理** | `proxy-watch` 自动 |
| `TP-LINMZ` | **TUN 开启，全局代理** | `proxy-watch` 自动 |
| `HFUT-WiFi`（校园网） | **关闭，网络层零接触** | `proxy-watch` 自动 |
| `萝卜_XD` 及其他未列出的网络 | **关闭**（保守默认） | `proxy-watch` 自动 |
| 任意网络 + 手动 `proxyctl on` | 开启 | 手动 |
| 开机 / 未联网 | 关闭（配置里 `tun.enable: false`） | 默认安全 |

**核心原则**：代理的"开"完全靠**运行时切换**，配置文件里 TUN **永远是 `false`**。
这样重启后默认就是安全的校园网状态，不会因为忘记关闭而把校园网流量卷进代理。

---

## 3. 架构

```
                     +--------------------------------+
   手动 -----------> |  proxyctl on|off|status        | --+
                     |  （切换 + 桌面通知）             |   |
                     +--------------------------------+   |
                                                          |  PATCH /configs
                     +--------------------------------+   |  {"tun":{"enable":...}}
   NetworkManager -->|  proxy-watch（systemd 用户服务）| --+
   （轮询活动连接）   |  （自动切换 + 桌面通知）         |   |
                     +--------------------------------+   |
                                                          v
                     +--------------------------------+
                     |  mihomo@Luo_bo.service          |
                     |  （CAP_NET_ADMIN → 创建 TUN）    |
                     +--------------------------------+
```

**关键点**：TUN 设备由带 `CAP_NET_ADMIN` 的 **mihomo 服务进程**创建；
调用方只是发一个 HTTP 请求到 `127.0.0.1:9090`。
因此**开关代理在用户态完成，不需要 sudo**。

---

## 4. 目录结构

> `ConfMihomo/mihomo-aur-build/` 是历史遗留的 **AUR 构建目录**（PKGBUILD / src / pkg / 包文件），
> 与运行配置无关，仅作留档。

```
/home/Luo_bo/ConfMihomo/
├── README.md                     # 本文档
├── .gitignore                    # 忽略运行时产物与含凭据的文件
├── config/
│   ├── config.yaml               # 真实配置（含订阅链接，chmod 600）
│   ├── config.example.yaml       # 占位符模板
│   ├── Country.mmdb              # 软链 -> /etc/clash/Country.mmdb（只读）
│   └── providers/                # mihomo 运行时写入（含节点凭据，gitignore）
├── bin/
│   ├── libproxy.sh               # 共用库：控制 API / 网络白名单 / 通知封装
│   ├── proxyctl                  # 手动 开/关/查询 + 通知
│   └── proxy-watch               # 网络变化监视 + 自动切换 + 通知
├── systemd/
│   ├── proxy-watch.service       # 用户服务单元（免 sudo）
│   └── 10-confdir.conf           # mihomo@ 的 drop-in（见下）
├── docs/
│   └── troubleshooting.md        # 排障手册（坑与排查记录）
└── mihomo-aur-build/             # 旧的 AUR 构建目录（与运行配置无关，仅留档）
```

> `bin/`、`systemd/`、`docs/` 下的文件均已落地。
> `bin/*` 已软链到 `~/.local/bin/`，`systemd/proxy-watch.service` 已软链到
> `~/.config/systemd/user/`（详见第 11、13 节）。

### 配置如何被 mihomo 读取（已定：方案 D）

service 单元里是 `ExecStart=/usr/bin/mihomo`（**没有 `-d`**），默认会去读 `$HOME/.config/mihomo`。
我们用 drop-in **覆盖 `-d`，直接指向项目目录**，做到「无软链、无复制、无歧义」：

```ini
# /etc/systemd/system/mihomo@.service.d/10-confdir.conf
[Service]
ExecStart=
ExecStart=/usr/bin/mihomo -d /home/Luo_bo/ConfMihomo/config
```

- 改项目里的 `config.yaml` 立即生效
- 不存在"编辑器原子保存断链"的问题（那是文件软链方案的坑）
- 代价：运行时产物（`providers/`、`cache.db`）落在项目里 → 用 `.gitignore` 排除
- 手动前台调试时需一致：`mihomo -d /home/Luo_bo/ConfMihomo/config`

---

## 5. 关键决策记录

| 决策 | 选择 | 理由 |
|---|---|---|
| 机场数量 | 单机场（NanoCloud） | 简化；备用出口计划用后续的 Oracle 自建 |
| 配置读取方式 | **方案 D：drop-in 指定 `-d` 指向项目目录** | 无软链、无复制、无断链风险、无同步遗漏 |
| TUN 是否常驻 | **否**，仅指定网络下开启 | 避免路由表改动干扰校园网认证 |
| 自动触发 | **用户级 watcher（轮询）**，不用 NM dispatcher | 通知必须从用户会话发；且免 sudo。代价：~3s 延迟 |
| 网络识别 | **UUID 白名单为主 + 连接名兜底** | 见第 6 节 |
| 通知 | `notify-send`（libnotify 已装） | KDE 原生 |
| DNS | `fake-ip` + DoH，bootstrap 用公共 IP | 不依赖校园 DNS，避免污染 |
| GEOIP 规则 | 只用 `GEOIP,CN`（**不用 `geosite:`**） | 系统只装了 `Country.mmdb`，**没有 GeoSite 数据** |
| Geo 数据维护 | **方案 X**：继续软链 `/etc/clash/Country.mmdb`，不开 `geo-auto-update` | 简单、离线可用；软链目标 root 拥有，开自动更新会因无写权限失败 |
| 嗅探 `sniffer` | **启用**（TLS/HTTP/QUIC） | TUN+`fake-ip` 下，裸 IP 连接会丢失域名，导致域名规则失效 |
| CN 分流 | **`rule-providers`（cn-domain）+ `GEOIP,CN`** | 纯 `GEOIP,CN` 只看 IP，会误判中国域名；规则集实测 11.1 万条 |
| 订阅拉取 | 启用 `etag-support` | 减少订阅流量 |
| `global-client-fingerprint` | **不使用**（该选项已被移除） | 1.19.31 会报错；且机场订阅节点**已自带** `client-fingerprint` |

---

## 6. 网络识别方案

### 为什么不用 SSID / 不用连接 profile 的 user 标签

- **SSID**：NetworkManager dispatcher 的环境变量里**根本没有 SSID**（已核对官方完整变量表）
- **`user.data` 标签**：官方文档说 dispatcher 会传 `CONNECTION_USER_*`，但
  本机 `nmcli` **没有暴露 `user.data` 字段**（`-f user.data` 报"无效字段"，手册页也未安装），语法无法验证 → 放弃

### 采用：UUID 白名单 + 连接名兜底

已实测的 UUID：

```
iPhone     40001434-0abe-4b47-bf3d-1b2bd498a3bf
iPhone     b4ef6f8b-5677-421d-9bff-2713d2a5da4a
TP-LINMZ   2e6f8000-364b-4ad0-a2ca-e5f365127838
```

**UUID 的稳定性**（`uuid=` 与 `id=` 在 profile 里是两个独立字段）：

| 操作 | UUID |
|---|---|
| 改连接名 | 不变 |
| 改 Wi-Fi 密码 / SSID / IP | 不变 |
| 连接、断开、重启、换网卡 | 不变 |
| **"忘记网络"后重连**（profile 删除重建） | **会变** |

因此保留**连接名兜底**：UUID 没命中时再看 `CONNECTION_ID` 是否在名字白名单里
（当前：`iPhone`、`TP-LINMZ`）。两层都不命中 → 关代理。

### 判定逻辑

```
读取所有活动连接的 {UUID, NAME}
  ├─ UUID 命中白名单   → 开代理
  ├─ 名字命中白名单     → 开代理
  └─ 否则              → 关代理
（多连接并存时：只要命中任意一个就开；并加 2-3s 防抖避免切换抖动）
```

---

## 7. 配置要点

> **完整配置以 `config/config.yaml` 为唯一真相来源**（含订阅链接，权限 600）。
> 本节只记录关键项与"为什么这么设"，避免文档与配置两头漂移。

### 基础

| 配置 | 值 | 说明 |
|---|---|---|
| `mixed-port` | 7890 | HTTP + SOCKS 混合端口 |
| `bind-address` | 127.0.0.1 | 仅本机可用 |
| `external-controller` | `127.0.0.1:9090` | **运行时切换 TUN 的入口** |
| `etag-support` | `true` | 订阅拉取使用 ETag 缓存，减少流量 |
| `find-process-mode` | `off` | 不用 `PROCESS-*` 规则，省 CPU |

> 注：`global-client-fingerprint` 在 mihomo 1.19.31 **已被移除**（启动会报错）。
> 实测本机场订阅里节点**自带 `client-fingerprint`**，无需全局设置。

### 嗅探 `sniffer`（已启用）

**为什么开**：TUN + `fake-ip` 下，若某连接是**裸 IP**（不带域名），域名类规则会直接失效；
嗅探能从 TLS SNI / HTTP Host / QUIC 里还原出域名，让规则重新命中。

| 协议 | 端口 | 备注 |
|---|---|---|
| `TLS` | 443, 8443 | |
| `QUIC` | 443, 8443 | |
| `HTTP` | 80, 8080-8880 | `override-destination: true` |

`skip-domain`：Apple 推送（`+.push.apple.com`）、米家/小米智能家居（`+.mijia.com`、`+.miio.com`），避免误伤。
（原配置里的 `"Mijia Cloud"` 含空格、不是合法域名，实际匹配不到任何东西，已修正。）

### DNS

| 项 | 说明 |
|---|---|
| `enhanced-mode: fake-ip` | 配合 TUN 使用 |
| `cache-algorithm: arc` | DNS 缓存算法 |
| `default-nameserver` | 仅用于解析 DoH 服务器域名 |
| `nameserver` | 国内 DoH（223.5.5.5 / doh.pub） |
| **`proxy-server-nameserver`** | **专门解析"节点自己的域名"，避免被 fake-ip 污染** |
| `fallback` / `fallback-filter` | **未启用**（实测**校园网与手机热点都直连不了 8.8.8.8 / 1.1.1.1**，而 mihomo 的 fallback 是**直连**发出的 → 每次解析都等超时，Google 域名经 TUN 会卡 15s，反而更糟。fake-ip 下境外域名由代理远端解析，本地不需"干净 DNS"。污染 IP 的 `GEOIP,CN` 误判另由 §15 方案 A 解决） |

### 订阅与策略组

- `proxy-providers.nanocloud`：UA 用 `clash-verge/v2.0.0`（UA 不对机场会返回 base64）
- **已实测**：机场返回的是**完整配置**，但 mihomo 的 provider **只提取 `proxies` 字段**，
  其余（`rules`/`proxy-groups`/`dns`）全部忽略（源码 `ProxySchema`）→ 可直接使用，无需另找 provider 链接
- 策略组：`自动选择`(url-test) → `PROXY`(select，默认走自动选择，可手选节点或 `DIRECT`)

### TUN

`enable: false` **永远保持**（由 `proxyctl` / `proxy-watch` 在运行时切换）；
`stack: mixed`；`auto-route: true`；`auto-redirect: false`（需要 nftables，暂不开）。

### 规则

内网 / 校园网 / 多播 / 广播 → `DIRECT`；`google`/`youtube` → `PROXY`；`GEOIP,CN` → `DIRECT`；其余 → `PROXY`。

- `RULE-SET,google,PROXY`、`RULE-SET,youtube,PROXY`：**按域名**把 Google/YouTube 直接送代理，
  规避国内 DoH 污染 IP 被 `GEOIP,CN` 误判（见 §10 坑 22、§15）
- `RULE-SET,cn-domain,DIRECT`：**精准 CN 分流**（比 `GEOIP,CN` 更准，见下）
- `224.0.0.0/4`、`255.255.255.255/32`：避免 TUN 吞掉多播/广播流量
- Geo 数据方案：**方案 X** —— 继续软链 `/etc/clash/Country.mmdb`，只用 `GEOIP`（不用 `GEOSITE`）

### 规则集 `rule-providers`（已启用）

从外部拉取域名清单并缓存到 `config/rules/*.mrs`：

| 名称 | 来源（geosite） | 格式 | 实测条数 |
|---|---|---|---|
| `cn-domain` | `cn.mrs` | `mrs`(zstd), `behavior: domain` | 111,595 |
| `google` | `google.mrs` | 同上 | 1,075 |
| `youtube` | `youtube.mrs` | 同上 | 178 |

来源均为 `MetaCubeX/meta-rules-dat`（jsdelivr 镜像）；更新间隔 24h。

**为什么需要**：`GEOIP,CN` **只看目标 IP**。中国域名若解析到海外 IP 会被误走代理、白耗流量；
反过来某些境外域名解析到国内 IP（**污染**）又会被误直连。`google`/`youtube` 规则即为此类域名兜底。

**代价**：首次启动需能访问这些 URL；下载失败时规则集为空，退化为只有 `GEOIP,CN`（不会致命）。

---

## 8. 实施步骤

### 阶段 0：项目骨架（用户态）
1. 建 `config/`、`bin/`、`systemd/`、`docs/`、`config/providers/`
2. 写 `config/config.yaml`（占位符）与 `config/config.example.yaml`
3. `ln -s /etc/clash/Country.mmdb /home/Luo_bo/ConfMihomo/config/Country.mmdb`
4. `chmod 600 config/config.yaml`
5. 写 `.gitignore`（排除 `config/providers/`、`config/cache.db`、`config/config.yaml`）

### 阶段 1：填订阅 + 校验格式
1. 用户把 NanoCloud 链接填入 `config/config.yaml`
2. **只检查结构，不打印链接内容**：
   - 含 `proxies:` → 可直接给 `proxy-providers`
   - 是完整配置（含 `rules:`）→ 需去面板找 provider 链接
   - base64 → UA 不对

### 阶段 2：前台试跑（用户态，无 sudo）
```bash
mihomo -d /home/Luo_bo/ConfMihomo/config
```
另开终端验证：
```bash
curl -x http://127.0.0.1:7890 -I https://www.google.com
curl -s http://127.0.0.1:9090/proxies | head -c 300
```

### 阶段 3：安装常驻服务（一次 sudo）
1. 写 drop-in：`/etc/systemd/system/mihomo@.service.d/10-confdir.conf`
2. 应用并启动：
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mihomo@Luo_bo.service
systemctl status mihomo@Luo_bo.service
journalctl -u mihomo@Luo_bo -n 30        # 确认读到项目目录的配置
```
3. 可选加固：
```bash
sudo systemctl mask mihomo.service       # 防止误启跑 /etc/mihomo 的版本抢端口
```

### 阶段 4：脚本与自动切换（用户态）
1. 写 `bin/proxyctl`（子命令见第 11 节）、`bin/proxy-watch`，`chmod +x`
2. 到 `~/.local/bin` 建软链
3. 装 systemd **用户**服务：
```bash
systemctl --user enable --now proxy-watch.service
```
4. 自检：`proxyctl status`、`proxyctl usage`

### 阶段 5：验证 → 见第 9 节

---

## 9. 验证清单

### 阶段 2 已验证（2026-10-12 校园网 + iPhone 热点各一轮；同日热点复验）

- [x] `mihomo -d /home/Luo_bo/ConfMihomo/config` 前台启动无报错（无 error / 无 warning）
- [x] provider 加载 **42 个节点**（约 1–2 秒）
- [x] 规则集 `cn-domain` 加载 **111,595 条域名规则**
- [x] `curl -x http://127.0.0.1:7890 https://www.google.com` → 可达（HTTP 200）
- [x] `curl http://127.0.0.1:9090/proxies` 能看到 NanoCloud 节点列表
- [x] 出口 IP 可达公网（**不由本方案固定地区**：实测自动选择会落在不同地区，如 Japan/Tokyo 或 Malaysia/Kuala Lumpur；以节点与 `url-test` 结果为准）
- [x] 校园网下：`ip route` 无 TUN 设备、路由表零改动
- [x] 热点下：CLI 可访问被墙站点（google / youtube / github / wikipedia）
- [x] 热点下 CN 站点直连与经代理均 **5/5**（baidu / jd / bilibili；注意 `qq.com`、`163.com` 需带浏览器 UA，否则返回 501/403，属站点反爬，非网络问题）
- [x] 控制器确认 `tun.enable=false`；DNS 为 **fake-ip**（域名解析到 `198.18.x.x`）
- [x] 规则分流实际命中正确：CN 域名（qq / aliyun 镜像）→ `RuleSet,cn-domain → DIRECT`；境外域名 → `Match → PROXY`

### 阶段 5 已验证（2026-10-12 热点 ↔ 校园网切换一轮）

- [x] 切到 iPhone 热点：~3s 内通知"梯子：已开启"，`ip link` 出现 `mihomo`
- [x] 全局代理（CLI + 非 curl 应用）：无 `-x` 直连被墙站点 200；python urllib 同样可达
- [x] DNS 劫持：`getent hosts www.google.com` → `198.18.0.4`（fake-ip）
- [x] 热点下**浏览器**可访问被墙站点、视频可播放
- [x] 切回校园网：通知"梯子：已关闭"，TUN 消失，主路由表与 `ip rule` 复原
- [x] 手动 `proxyctl on/off/status/toggle/usage/reload` 均正常并有通知
- [ ] 切到 TP-LINMZ（未实测，机制同 iPhone）
- [ ] 重启系统后：默认无 TUN、校园网正常

> 遗留问题：热点下 **YouTube 视频封面偶发加载不出**（视频本身正常）。
> 已定位为**国内 DoH 污染 + `GEOIP,CN` 误判**，并**已用 §15 方案 A 修复并验证**
> （真实封面图 `i.ytimg.com/vi/*/hqdefault.jpg` 经 TUN 正常返回 JPEG）。

---

## 10. 已知坑

1. **订阅 UA**：机场按 UA 返回不同格式；配置里预置 `clash-verge/v2.0.0`
2. **订阅返回完整配置也没问题**（已实测）：mihomo 的 provider **只提取 `proxies` 字段**，`rules`/`dns` 等一律忽略 → 无需另找 provider 链接
3. **无 GeoSite**：方案 X 下只能用 `GEOIP,CN`，不能用 `GEOSITE` 规则或 `nameserver-policy: geosite:cn`
4. **校园网认证门户**：不开 TUN 时风险很低；若某门户页打不开，把域名加 `DIRECT`
5. **`auto-redirect` 需要 nftables**：先关闭，基础可用后再试
6. **服务实例名大小写**：`mihomo@Luo_bo`（大写 L）
7. **TUN 与 Docker / 虚拟机**：TUN 开启期间可能互相影响；不开就没事
8. **切换抖动**：网络切换时活动连接可能短暂为空 → `proxy-watch` 需 2-3s 防抖
9. **"忘记网络"会让 UUID 变化** → 名字兜底可覆盖；两层都失效时需更新白名单
10. **drop-in 覆盖 ExecStart** 时，必须先写一行空的 `ExecStart=` 再写新的，否则不生效
11. **`global-client-fingerprint` 已被移除**：1.19.31 启动会报 error。应改用节点级 `client-fingerprint`（本机场订阅**已自带**，无需处理）
12. **订阅端点较慢、偶发超时**：实测首次拉取约 8s，偶尔超时。属端点抖动；provider 有 `interval` 会重试，且**缓存会保留上次成功结果**
13. **`geo-auto-update` 与软链冲突**：`Country.mmdb` 软链到 root 拥有的 `/etc/clash`，若开自动更新会因无写权限而失败（方案 X 不启用该功能；要走方案 Y 需换成项目内真实文件）
14. **`sniffer` 会改变少量流量的目标判定**：`override-destination` 默认关闭，仅 HTTP 开启；若遇到某站点访问异常，先把该域名加 `sniffer.skip-domain`
15. **规则集首次启动需联网下载**：`config/rules/cn-domain.mrs` 下载失败时规则集为空，退化为只有 `GEOIP,CN`；下载成功后会缓存，后续启动不再依赖网络
16. **校园网对部分国内 IP 的可达性会间歇抖动**（实测同一 IP 数秒内在"不通/可连"之间跳变，**不走 mihomo 直连也复现**）→ 表现为 CN 站点偶发超时。属网络环境问题，非配置问题；换网络（如手机热点）可复验
17. **部分国内站点要求浏览器 UA**：`www.qq.com` 无 UA 返回 501、`www.163.com` 返回 403，带 `Mozilla/5.0` 即 200。用 curl 复验 CN 站点时**务必加 `-A 'Mozilla/5.0'`**，否则会误判为网络故障
18. **出口地区不固定**：`自动选择`（url-test）会随节点可用性落到不同地区（实测出现过 Japan/Tokyo、Malaysia/Kuala Lumpur）。需要固定出口时应在 `PROXY` 组**手选**具体节点
19. **`mihomo@.service` 的 `LimitNPROC=500` 会导致启动失败**：Linux 的 `RLIMIT_NPROC` 统计的是**同一 UID 的线程数**（非进程数）。桌面会话下 `Luo_bo` 的线程数常超过 500，systemd 在 `execve` 阶段报 `203/EXEC ... Resource temporarily unavailable`。**已在 drop-in 里用 `LimitNPROC=infinity` 覆盖**（见 `systemd/10-confdir.conf`）
20. **TUN 开启后会被 NetworkManager 列为活动连接**（`type=tun`、名字 `mihomo`）。`proxy-watch` 若据此计算"网络指纹"会因**自己开了 TUN**而误判网络变化，导致重复施加/通知。**已在 `libproxy.sh: current_network()` 里过滤 `tun` 类型**
21. **TUN 的流量拦截走"策略路由"而非默认路由**：`auto-route` 会写入 `ip rule`（优先级 9000–9010）与 `table 2022`（`default via 198.18.0.2 dev mihomo`），**主路由表基本不变**（仅多一条 `198.18.0.0/30 dev mihomo`）。排查时看 `ip rule` 与 `ip route show table all`，别只看 `ip route`
22. **国内 DoH 会返回污染 IP，且会被 `GEOIP,CN` 误判**（实测 2026-10-12）：`nameserver: 223.5.5.5 / doh.pub` 对被墙域名返回的是污染结果（例：`www.google.com → 31.13.92.37`、`www.youtube.com → 69.171.235.22` 均为 Facebook 段；`i.ytimg.com → 104.244.42.197` 为 Twitter 段；`fonts.gstatic.com → 120.253.255.162` 落在**国内网段**）。
   - fake-ip 下正常浏览不受影响（连接带域名，远端解析），但 **`GEOIP,CN` 只看 IP**：一旦污染 IP 落在 CN 段，境外域名就会被判 `DIRECT` 而失败 → 表现为**部分 Google/YouTube 资源（如封面）时好时坏**。
   - 核对方法：`curl -s "http://127.0.0.1:9090/dns/query?name=www.google.com&type=A"` 对比 `curl -x http://127.0.0.1:7890 "https://dns.google/resolve?name=www.google.com&type=A"`。
   - 修复见 §15（方案 A 已实施并验证）。
23. **重载配置必须用 `PUT /configs`，不能用 `PATCH`**：`PATCH /configs` 只用于局部改（如 `tun.enable`），拿它传 `{"path":…}` **不会生效**（HTTP 可能仍返回成功）。`bin/libproxy.sh` 早期误用 PATCH 导致 `proxyctl reload` 无效，已修正为 `PUT /configs`（会自动重建 rule-providers，返回 204）
24. **换订阅链接的两个坑**（实测 2026-10-12）：
   - **URL 引号内多空格**：会报 `Get "…nano ": EOF` / HTTP 503。修正见 `docs/troubleshooting.md` §9-A。
   - **"鸡生蛋"**：mihomo 拉取 proxy-provider 是**经代理节点**发出的；旧节点全挂时会拉不动新订阅。需趁能直连时把订阅下到 `config/providers/nanocloud.yaml` 再 reload（见 `docs/troubleshooting.md` §9-B）。
25. **YouTube 视频内容加载不出（缩略图/广告却正常）**：视频走 **QUIC(UDP/443)**，而选中的 tuic 节点未启用 UDP → QUIC 下行恒 0（详见 §16）。曾用 `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` 强制回落 TCP，但实测**视频仍持续缓冲**（瓶颈在节点带宽/中转），**该规则已撤回**。日后若换到带宽更好的节点可再评估。

---

## 11. 订阅过期与应急处理

### 三种"过期"要分清

| 情况 | 本质 | 现象 | 后果 |
|---|---|---|---|
| **A. 链接失效** | 机场重置 token / 换订阅域名 | provider 拉取 401/403/404 | 有缓存，**不会立刻断** |
| **B. 套餐到期 / 流量用尽** | 账号层面失效 | 链接能拉取，节点全部不可用 | **断网** |
| **C. 机场跑路 / 被封** | 服务消失 | 全部失败 | **断网** |

### mihomo 的实际行为（已核对源码）

- 拉取失败时**保留上次成功的缓存** `config/providers/nanocloud.yaml`
- 所以 **A 通常还能撑一阵**，真正断网的是 **B / C**
- ⚠️ **不要删除 `config/providers/`**（含节点凭据，已在 `.gitignore` 中排除）

### 更换订阅链接（已核对 API，无需重启服务）

```bash
# 1) 机场面板取新链接
# 2) 编辑配置
$EDITOR /home/Luo_bo/ConfMihomo/config/config.yaml

# 3) 重载配置（源码要求必须是【绝对路径】）
curl -X PUT http://127.0.0.1:9090/configs \
  -H 'Content-Type: application/json' \
  -d '{"path":"/home/Luo_bo/ConfMihomo/config/config.yaml"}'

# 4) 立即刷新 provider（重新拉取新链接）
curl -X PUT http://127.0.0.1:9090/providers/proxies/nanocloud

# 5) 触发一次健康检查
curl http://127.0.0.1:9090/providers/proxies/nanocloud/healthcheck
```

或者一步到位：**`proxyctl reload`**（见下）。

> **注意**：`PUT /providers/proxies/:name` 只负责"重新拉取"，**不能传新 URL**
> （源码 `updateProvider` 仅调用 `provider.Update()`）。改 URL 必须走"改配置 + 重载配置"。

### ⚠️ 重载配置的副作用（必须知道）

`PUT /configs` 会按配置文件**重建监听**，而配置里 `tun.enable` 恒为 `false`
→ **正在生效的 TUN 会被关掉**。

而 `proxy-watch` 只在"网络变化"时触发，连接没变就不会自动重开
→ 容易出现"以为还开着，其实已经关了"。

**因此 `proxyctl reload` = 重载配置 + 按当前网络重新施加 TUN 状态。**

### 流量 / 到期监控（源码确认可行）

mihomo 会解析订阅响应头 `subscription-userinfo`，并通过 API 暴露：

```bash
curl -s http://127.0.0.1:9090/providers/proxies/nanocloud
# → {"subscriptionInfo":{"Upload":…,"Download":…,"Total":…,"Expire":…}, …}
```

- `Expire` 是 Unix 时间戳（前提：机场返回该响应头）
- `proxyctl usage` 显示 已用 / 总量 / 剩余 / 到期日期
- `proxy-watch` 每日自检：**到期前 3 天** 或 **流量用掉 90%** 时弹通知

### proxyctl 子命令一览

| 命令 | 作用 |
|---|---|
| `proxyctl on` | 开启 TUN（全局代理）+ 通知 |
| `proxyctl off` | 关闭 TUN + 通知 |
| `proxyctl status` | 显示当前状态 + 通知 |
| `proxyctl toggle` | 切换开/关 |
| `proxyctl usage` | 显示订阅流量与到期时间 + 通知 |
| `proxyctl reload` | 重载配置并重新施加 TUN 状态 |
| `proxyctl -h` | 操作手册（见第 14 节待办） |

### 单机场的根本风险

B / C 是**单点全断**，没有任何兜底。缓解手段：

1. **保持月付**，把跑路损失压到一个月
2. **推进 Oracle 自建**作为第二出口（自建不会"过期"）
3. 把 `PROXY` 由 `select` 改为 `fallback`，实现自动切换

---

## 12. 可选项（未启用）

以下能力**已验证可行**，但按"保守优先"暂时不开；需要时再启用。

### A. Geo 数据自管 + 启用 `GEOSITE`

把软链换成项目内的真实 `geoip.metadb` + `geosite.dat`，并开启：

```yaml
geodata-mode: true
geo-auto-update: true
geo-update-interval: 24
geox-url:
  mmdb:    "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"
  geosite: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
```

好处：可用 `GEOSITE` 规则（分流更准）+ 自动更新；代价：文件变大、首次需下载。

### B. 图形面板 `external-ui`

```yaml
external-ui: ui
external-ui-url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
```

之后可访问 `http://127.0.0.1:9090/ui` 点选节点。

### C. 其他

| 项 | 说明 |
|---|---|
| `ntp` | 时间同步（某些协议对时间敏感） |
| `secret` | 给控制器加密钥（本机单用户，收益低） |
| `keep-alive-idle` / `disable-keep-alive` | TCP keepalive 调优 |
| `IN-TYPE` 规则 | 区分 TUN 与 7890 端口的流量 |
| `SUB-RULE` | 规则分组，提升可读性 |
| `override.override-expr` | 批量改写 provider 节点字段（如统一注入 `client-fingerprint`、`udp: true`） |
| `authentication` / `external-controller-unix` | 提升控制器安全性（本机场景收益低） |

---

## 13. 权限与回滚

| 操作 | 需要 sudo |
|---|---|
| 写 mihomo@ 的 drop-in + `daemon-reload` | ✅ 一次 |
| 安装/启用 mihomo 服务 | ✅ 一次 |
| `systemctl --user` 用户服务 | ❌ |
| `proxyctl` 切换 TUN | ❌ |
| 改 `config/config.yaml` | ❌ |

**回滚**：
```bash
systemctl --user disable --now proxy-watch.service
sudo rm /etc/systemd/system/mihomo@.service.d/10-confdir.conf
sudo systemctl daemon-reload
sudo systemctl disable --now mihomo@Luo_bo.service
```

---

## 14. 待办

- [x] `ConfMihomo/mihomo/` 已改名为 `mihomo-aur-build/`
- [x] 订阅链接填入（`config/config.yaml` 已含真实 NanoCloud 链接）
- [x] **实施阶段 3–4**（计划见 `/home/Luo_bo/.opencode/plan/mihomo-stage3-5-plan.md`）
  - [x] 阶段 3：安装 `mihomo@Luo_bo.service`（drop-in 指定 `-d`）
  - [x] 阶段 4：`libproxy.sh` / `proxyctl` / `proxy-watch` + 用户服务
- [x] **阶段 5：验证**（见第 9 节；仅剩 TP-LINMZ 与重启两项未测）
- [x] **操作手册**：已由 `proxyctl -h`、`proxy-watch -h` 提供（含命令用法、订阅链接替换、常见故障）
- [x] `docs/troubleshooting.md` 已编写（坑与排查记录汇总）
- [x] 修正 `sniffer.skip-domain`：`"Mijia Cloud"` → `+.mijia.com` / `+.miio.com`
- [~] 封禁 QUIC(UDP/443) 尝试修复 YouTube 视频加载 → **已撤回**（瓶颈在带宽，见 §16）
- [x] 已 `git init` 并首次提交（凭据 `config.yaml`/`providers/`/`rules/`/`cache.db` 与 222MB 构建目录已忽略）
- [ ] 待测：切到 TP-LINMZ 的自动开启
- [ ] 待测：重启系统后默认无 TUN、校园网正常
- [ ] Oracle 自建节点接入后，把 `PROXY` 由 `select` 改为 `fallback` 组
- [ ] 是否启用 `auto-redirect` 提升 TUN 兼容性
- [ ] 是否给 `萝卜_XD` 等更多网络加入白名单
- [x] **修复 DNS 污染导致的 `GEOIP,CN` 误判**（§15 方案 A，已验证；方案 B 已否决）

---

## 15. DNS 污染 / `GEOIP,CN` 误判的修复（已实施）

**现象**：热点下 YouTube 视频正常，但**部分封面/Google 静态资源加载不出**。
**根因**：见 §10 坑 22 —— 国内 DoH 返回污染 IP，`GEOIP,CN` 只看 IP 会误判成直连。

### 已采用：方案 A（域名规则前置）✅ 已验证

`config.yaml` 新增两个规则集并**前置** PROXY 规则：

```yaml
rule-providers:
  google:
    type: http
    behavior: domain
    format: mrs
    url: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/google.mrs"
    path: ./rules/google.mrs
    interval: 86400
  youtube:
    type: http
    behavior: domain
    format: mrs
    url: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/youtube.mrs"
    path: ./rules/youtube.mrs
    interval: 86400

rules:
  # ... 内网直连规则之后、cn-domain 之前 ...
  - RULE-SET,google,PROXY
  - RULE-SET,youtube,PROXY
  - RULE-SET,cn-domain,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
```

**验证结果（2026-10-12 热点）**：
- 规则集：`google` 1075 条、`youtube` 178 条、`cn-domain` 111595 条
- `i.ytimg.com` → `RuleSet,google → PROXY`（不再受污染 IP 影响）
- 真实封面图 `i.ytimg.com/vi/<id>/hqdefault.jpg` 经 TUN 返回 `200 image/jpeg`（480×360 / 1280×720）

### 已尝试并否决：方案 B（境外 DoH fallback）❌

曾加 `fallback: ["https://8.8.8.8/dns-query","https://1.1.1.1/dns-query"]` + `fallback-filter`。
**实测反而更糟**：mihomo 的 fallback 查询是**直连**发出的（fwmark 绕开 TUN），
而热点与校园网都**封 TCP:443 到境外 DNS** → 每次解析等超时，Google 域名经 TUN 卡 **15s**（`HTTP 000`）。
**已回退**，配置里保留说明注释。

**关键区分（实测，TUN 关闭后直连）**：

| 测试 | 结果 | 说明 |
|---|---|---|
| `ping 1.1.1.1`（ICMP） | ✅ 通（~215ms） | ICMP 未被封，但**证明不了 DoH 可用** |
| `curl https://1.1.1.1/`（**TCP:443**） | ❌ 超时 | DoH 依赖 TCP:443，被封 |
| `curl https://8.8.8.8/`（**TCP:443**） | ❌ 超时 | 同上 |

> TUN 开着时 `ping 1.1.1.1` 也通，但那是「TUN→节点→境外」的代理路径（`ttl=53`、~230ms），
> 不是直连。要让 B 生效必须让 DNS 也**经代理**发出，而 mihomo 的 DNS 客户端不支持简单地 "DoH over proxy"。

### 备注
- `proxyctl reload` 曾用错 `PATCH /configs` 导致不生效，已修正为 `PUT /configs`（见 `bin/libproxy.sh`）。
- 若日后接入可直连境外 DoH 的网络，可再评估 B。

---

## 16. 封禁 QUIC（UDP/443）—— 已尝试，已撤回

> ⚠️ **状态：已撤回（2026-10-12）**。
> 撤回原因：封禁后视频虽改走 TCP，但**仍持续缓冲**，判断瓶颈在**节点带宽/中转质量**而非 QUIC；
> 且全站禁用 HTTP/3 有副作用，故回退。`config.yaml` 中**已恢复为不含该规则**。
> §15 的两条（google/youtube 规则集、疑似 DNS 污染修复）不受影响，仍然保留。

以下是当初的排查与措施记录（供日后参考）：

**措施（已移除）**：在 `rules` 中前置一条逻辑规则：

```yaml
rules:
  # ... 内网/多播 DIRECT 规则之后 ...
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  - RULE-SET,google,PROXY
  # ...
```

**实施原因（2026-10-12，实测）**：

- 换新机场后，YouTube **缩略图 / 广告正常，但视频内容加载不出**。
- 抓 `127.0.0.1:9090/connections` 发现 `*.googlevideo.com` 的
  **UDP(QUIC) 连接"上行有、下行恒为 0"**；同批 **TCP 连接下行正常**（数 MB）。
- 根因：`自动选择` 选中 **tuic 节点**，而新机场订阅里**只有 vless 节点带 `udp: true`**，
  tuic 节点未声明 UDP → mihomo 对其**不转发 UDP** → QUIC 发出去收不回。
- YouTube 视频默认走 **QUIC(HTTP/3, UDP 443)**，故卡死；缩略图/广告走 TCP，故正常。

**效果**：拒绝 UDP/443 后，浏览器自动回落 **TCP/HTTP2**，实测视频改走 TCP 且下行正常。
**代价**：全站禁用 HTTP/3（浏览器自动回落，基本无感）。

**验证**：
```bash
# 规则已加载
curl -s 127.0.0.1:9090/rules | python3 -c 'import sys,json;[print(r) for r in json.load(sys.stdin)["rules"] if r["type"]=="AND"]'
# 放视频时，googlevideo 连接应全部为 net=tcp（不再出现 udp）
```

**替代方案**（若日后想保留 QUIC）：把 provider 限制为 vless 节点（`filter`），
或给节点 `override` 注入 `udp: true`——但都取决于**机场服务端是否真支持 UDP**。
