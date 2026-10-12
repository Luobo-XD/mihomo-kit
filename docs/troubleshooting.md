# mihomo 排障手册（troubleshooting）

> 配套：`../README.md`（方案与设计）；`proxyctl -h` / `proxy-watch -h`（命令用法）。
> 排障时**不要**贴出 `config/config.yaml` 的订阅链接与 `config/providers/` 内容（含凭据）。

## 0. 组件速查

| 组件 | 作用 | 查看命令 |
|---|---|---|
| `mihomo@Luo_bo.service` | 系统服务，创建 TUN，监听 7890/9090 | `systemctl status mihomo@Luo_bo.service` |
| `proxy-watch.service` | 用户服务，网络变化时自动开关 TUN | `systemctl --user status proxy-watch.service` |
| `proxyctl` | 手动开关/查询 | `proxyctl status` |
| 控制器 API | `127.0.0.1:9090` | `curl -s 127.0.0.1:9090/version` |

一键体检：
```bash
systemctl is-active mihomo@Luo_bo.service proxy-watch.service
proxyctl status
curl -s 127.0.0.1:9090/configs | python3 -c 'import sys,json;print("tun:",json.load(sys.stdin)["tun"]["enable"])'
ip -brief link show type tun
```

---

## 1. 服务启动失败：`203/EXEC ... Resource temporarily unavailable`

**现象**：`systemctl start mihomo@Luo_bo` 失败，`status=203/EXEC`，日志 `Failed to execute /usr/bin/mihomo`。

**原因**：发行版单元写死 `LimitNPROC=500`，而 Linux 的 `RLIMIT_NPROC` 统计的是**同一 UID 的线程数**。
桌面会话下 `Luo_bo` 的线程数常 >500，于是 `execve` 返回 `EAGAIN`。

**核对**：
```bash
ps -eL -o user= | grep -c '^Luo_bo$'         # 线程(任务)数
systemctl show mihomo@Luo_bo.service -p LimitNPROC
```
**修复**：`systemd/10-confdir.conf` 里加 `LimitNPROC=infinity`（本项目已加）。

---

## 2. TUN 不自动开关 / 通知不弹

**核对 `proxy-watch`**：
```bash
systemctl --user status proxy-watch.service
journalctl --user -u proxy-watch.service -f
```
**关键判定**（当前网络应开的白名单：iPhone、TP-LINMZ）：
```bash
. /home/Luo_bo/ConfMihomo/bin/libproxy.sh
network_key      # 当前网络指纹
desired_state    # on / off
```
- `desired_state=on` 但没开：看日志是否 `控制器暂不可达` → 检查 `mihomo@Luo_bo` 是否在跑。
- UUID 变了（"忘记网络"重连）：靠**名字兜底**；若名字也改了就更新 `libproxy.sh` 的白名单。

**通知不弹**：用户服务需有 D-Bus 会话。核对：
```bash
systemctl --user show-environment | grep DBUS_SESSION_BUS_ADDRESS
notify-send 'test' 'hello'
```

---

## 3. 重复开启 / 重复通知（TUN 反馈回路）

**原因**：TUN 开启后，NetworkManager 会把 `mihomo` 网卡也列为活动连接（`type=tun`）。
若 `proxy-watch` 据此算"网络指纹"，就会因**自己开了 TUN**而误判网络变化。

**修复**：`bin/libproxy.sh: current_network()` 已过滤 `loopback` 与 `tun`。核对：
```bash
. /home/Luo_bo/ConfMihomo/bin/libproxy.sh
nmcli -t -f UUID,NAME,TYPE connection show --active   # 原始
network_key                                            # 过滤后（不含 mihomo）
```

---

## 4. YouTube 封面 / Google 静态资源加载不出

**原因**：国内 DoH 对被墙域名返回**污染 IP**（如 `www.google.com → Facebook 段`）。
fake-ip 下浏览通常无碍，但 **`GEOIP,CN` 只看 IP**：污染 IP 一旦落在 CN 段，境外域名就被判 `DIRECT` 而失败。

**核对污染**：
```bash
curl -s "http://127.0.0.1:9090/dns/query?name=www.google.com&type=A"
curl -x http://127.0.0.1:7890 "https://dns.google/resolve?name=www.google.com&type=A"
```
**修复**：已加 `google` / `youtube` 规则集并前置 `RULE-SET,…,PROXY`（见 README §15）。
核对规则命中：
```bash
# 触发一次请求后看 /connections
curl -x http://127.0.0.1:7890 -s -o /dev/null "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
curl -s 127.0.0.1:9090/connections | python3 -m json.tool | grep -A2 ytimg
```
**注意**：浏览器可能缓存了失败的封面，需 **Ctrl+Shift+R** 强刷。

### 4b. 缩略图/广告正常，但**视频内容加载不出**（QUIC 问题）

**现象**：YouTube 缩略图、广告都出，视频黑屏/转圈。
**原因**：视频默认走 **QUIC(UDP/443)**，而某些节点（如未启用 UDP 的 tuic）**不转发 UDP**。
抓 `/connections` 可见 `*.googlevideo.com` 的 `net=udp` 连接 **`down=0`**（收不到数据），
而 `net=tcp` 的连接 `down` 正常。
**曾尝试**：`rules` 前置 `- AND,((NETWORK,UDP),(DST-PORT,443)),REJECT`，强制回落 TCP
—— 但实测**视频仍持续缓冲**，判断瓶颈在**节点带宽/中转**，该规则**已撤回**（见 README §16）。
**当前建议**：换带宽更好的节点；或让 `自动选择` 只用带 `udp: true` 的 vless 节点（方案 B）。
**核对**：
```bash
curl -s 127.0.0.1:9090/connections | python3 -c 'import sys,json;[print(c["metadata"].get("host"),c["metadata"].get("network"),c.get("download")) for c in json.load(sys.stdin)["connections"] if "googlevideo" in (c["metadata"].get("host") or "")]'
```

---

## 5. `proxyctl reload` 不生效

**原因**：`PATCH /configs` 只能局部改（如 `tun.enable`），传 `{"path":…}` **不会重载**。
**修复**：`libproxy.sh` 的 `reload_config()` 已改用 **`PUT /configs`**（返回 204 才算成功）。

手动等价命令：
```bash
curl -X PUT http://127.0.0.1:9090/configs -H 'Content-Type: application/json' \
  -d '{"path":"/home/Luo_bo/ConfMihomo/config/config.yaml"}'
```
> 重载会按配置文件把 TUN 关掉，所以 `proxyctl reload` 会**按当前网络重新施加**。

---

## 6. 配了境外 DoH fallback 反而更慢 / 解析超时

**现象**：加 `fallback: ["https://8.8.8.8/dns-query", ...]` 后，Google 域名经 TUN 卡 ~15s。

**原因**：
- mihomo 的 fallback 查询是**直连**发出的（用 fwmark 绕开 TUN）。
- 热点与校园网都**封 TCP:443 到境外 DNS**。

**实测证据**（TUN 关闭后直连）：
| 测试 | 结果 |
|---|---|
| `ping 1.1.1.1`（ICMP） | ✅ 通（~215ms） |
| `curl https://1.1.1.1/`（TCP:443） | ❌ 超时 |
| `curl https://8.8.8.8/`（TCP:443） | ❌ 超时 |

**结论**：**不要**用境外 DoH fallback；靠 fake-ip + 代理远端解析 + `google/youtube` 域名规则即可。

---

## 7. 校园网下 CN 站点偶发超时

- 部分国内 IP 在校园网**间歇不可达**（不走 mihomo 直连也复现）→ 网络环境问题。
- `qq.com` / `163.com` 需带浏览器 UA，否则返回 501/403：
  `curl -A 'Mozilla/5.0' https://www.qq.com`。

---

## 8. 路由 / TUN 排查要点

- TUN 拦截走**策略路由**：`ip rule`（9000–9010）+ `table 2022`，**主路由表基本不变**。
- 排查看：
```bash
ip rule
ip route show table all | grep mihomo
ip route get 1.1.1.1        # TUN 下会显示 via 198.18.0.2 dev mihomo table 2022
```
- TUN 关闭后，`ip rule` 与 `table 2022` 里 mihomo 条目应消失、主路由表复原。

---

## 9. 订阅过期 / 换链接

```bash
proxyctl usage                 # 各机场 已用/总量/到期
proxyctl sub list              # 列出所有机场
proxyctl sub set nanocloud "新链接"   # 改链接（自动清洗/渲染/拉取/补回 TUN）
proxyctl sub add 备用 "链接"    # 新增机场
proxyctl sub rm 备用            # 移除
proxyctl sub fetch             # 强制刷新（失败自动直连兜底）
```

> 已自动化，一般用 `proxyctl sub` 即可；下列 A/B 是排查原理，供异常时参考。
- 拉取失败会**保留上次缓存**（`config/providers/nanocloud.yaml`）→ 链接失效通常不会立刻断网。
- **不要删 `config/providers/`**。

### 换链接后常见故障（实测 2026-10-12）

**A. URL 引号内多了空格 → 拉取 `EOF` / HTTP 503**
编辑时容易在结尾多出一个空格，例如 `url: "...&sid=nano "`（引号**内**的空格）。
mihomo 会把它当 URL 的一部分，报 `Get "https://…nano ": EOF`。
核对与修正：
```bash
python3 -c 'import re;l=open("config/config.yaml").read().splitlines()[83];print(re.match(r"\s*url:\s*\"(.*)\"$",l).group(1)[-6:])'
```
结尾不应有空格。

**B. "鸡生蛋"：节点全挂时拉不动订阅**
mihomo 拉取 proxy-provider 是**经代理节点**发出的（日志可见
`[TCP] mihomo --> <订阅host>:443 match Match using PROXY[...]`）。
若旧订阅的节点已失效，就拉不到新订阅 → 死锁。
**解法**：趁能直连时把订阅直接下到缓存文件，再重载：
```bash
proxyctl off                       # 关 TUN，走直连
URL=$(python3 -c 'import re;print(re.search(r"url:\s*\"([^\"]+)\"",open("config/config.yaml").read().splitlines()[83]).group(1))')
curl -A 'clash-verge/v2.0.0' -s "$URL" -o config/providers/nanocloud.yaml
proxyctl reload
```
之后新节点可用了，mihomo 经代理的自动更新也会恢复正常。
（验证：`updatedAt` 变新、`proxyctl usage` 显示新套餐）

---

## 10. 回滚

```bash
systemctl --user disable --now proxy-watch.service
sudo rm /etc/systemd/system/mihomo@.service.d/10-confdir.conf
sudo systemctl daemon-reload
sudo systemctl disable --now mihomo@Luo_bo.service
```
