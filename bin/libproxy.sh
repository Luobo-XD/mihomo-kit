#!/usr/bin/env bash
# ============================================================
# libproxy.sh —— proxy / proxy-watch 共用库
#   职责：mihomo 控制 API 封装、网络白名单、通知封装
#   用法：. /path/to/libproxy.sh
# ============================================================

CTRL_BASE="http://127.0.0.1:9090"
CONF_DIR="/home/Luo_bo/ConfMihomo/config"
MIHOMO_CONFIG="$CONF_DIR/config.yaml"
PROVIDERS_DIR="$CONF_DIR/providers"
SUBS_FILE="$CONF_DIR/airports.conf"
SUBS_BAK="$CONF_DIR/airports.conf.bak"
SUB_UA="clash-verge/v2.0.0"

# 时间同步脚本（proxy time / 自检共用）
_LIBPROXY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROXYTIME_PY="$_LIBPROXY_DIR/proxytime.py"

# 语言/时区对齐（proxy lang / 自检共用）
PROXYLANG_PY="$_LIBPROXY_DIR/proxylang.py"
REGION_FILE="$CONF_DIR/region.json"

# ---------- 终端配色 ----------
# 仅在交互 TTY 且未禁用颜色时启用；重定向/日志/NO_COLOR/TERM=dumb 下自动降级为纯文本。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_TITLE=$'\033[1;36m'   # 章节标题：粗体青
  C_BOLD=$'\033[1m'       # 命令名：粗体
  C_DIM=$'\033[2m'        # 说明/注释：暗色
  C_OFF=$'\033[0m'        # 复位
else
  C_TITLE= C_BOLD= C_DIM= C_OFF=
fi

# 触发代理的网络白名单（UUID 为主 + 名字兜底，见 README §6）
WHITELIST_UUIDS=(
  "40001434-0abe-4b47-bf3d-1b2bd498a3bf"   # iPhone（手机热点）
  "b4ef6f8b-5677-421d-9bff-2713d2a5da4a"   # iPhone（手机热点）
  "2e6f8000-364b-4ad0-a2ca-e5f365127838"   # TP-LINMZ
)
WHITELIST_NAMES=(
  "iPhone"
  "TP-LINMZ"
)

# ---------- 通知 ----------
_notify() {
  # $1 标题  $2 正文；失败静默（无图形会话时不报错）
  notify-send -a mihomo -i network-wireless "$1" "${2:-}" 2>/dev/null || true
}

# ---------- 控制 API ----------
api_get() {
  curl -fsS -m 5 "$CTRL_BASE$1" 2>/dev/null
}

api_patch() {
  curl -fsS -m 5 -X PATCH "$CTRL_BASE$1" \
    -H 'Content-Type: application/json' -d "$2" 2>/dev/null
}

api_put() {
  curl -fsS -m 30 -X PUT "$CTRL_BASE$1" \
    -H 'Content-Type: application/json' -d "$2" 2>/dev/null
}

controller_up() {
  curl -fsS -m 3 "$CTRL_BASE/version" >/dev/null 2>&1
}

# 输出 true / false / unknown
tun_state() {
  local body
  body="$(api_get /configs)" || { echo unknown; return 0; }
  printf '%s' "$body" | python3 -c '
import sys, json
try:
    print("true" if json.load(sys.stdin)["tun"]["enable"] else "false")
except Exception:
    print("unknown")
' || echo unknown
}

set_tun() {
  # $1 = true | false
  api_patch /configs "{\"tun\":{\"enable\":$1}}" >/dev/null
}

reload_config() {
  # 重载配置必须用 PUT /configs（PATCH 只用于局部改 tun.enable），
  # 且要等 mihomo 完成重建，HTTP 返回 204 才算成功。
  api_put /configs "{\"path\":\"$MIHOMO_CONFIG\"}" >/dev/null
}

# 重载配置 + 按当前网络重新施加 TUN
# （PUT /configs 会按配置把 TUN 关掉，必须补回）
reload_and_reapply() {
  reload_config
  local want
  want="$(desired_state)"
  if [ "$want" = "on" ]; then set_tun true; else set_tun false; fi
  node_gone_check          # 重载后固定节点可能已消失 → 弹提示（内部对重载中的短列表有保护）
}

# 所有 http 类型的 provider（机场）名字，每行一个
all_providers() {
  api_get /providers/proxies | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["providers"]
except Exception:
    raise SystemExit
for k, v in d.items():
    if v.get("vehicleType") == "HTTP":
        print(k)
' 2>/dev/null
}

# 刷新：带名字刷一个；不带则刷全部机场
provider_refresh() {
  local n
  if [ -n "${1:-}" ]; then
    curl -fsS -m 15 -X PUT "$CTRL_BASE/providers/proxies/$1" >/dev/null 2>&1 || true
  else
    while IFS= read -r n; do
      [ -n "$n" ] && curl -fsS -m 15 -X PUT "$CTRL_BASE/providers/proxies/$n" >/dev/null 2>&1 || true
    done < <(all_providers)
  fi
}

# 健康检查：带名字做一个；不带则全部机场
provider_healthcheck() {
  local n
  if [ -n "${1:-}" ]; then
    curl -fsS -m 15 "$CTRL_BASE/providers/proxies/$1/healthcheck" >/dev/null 2>&1 || true
  else
    while IFS= read -r n; do
      [ -n "$n" ] && curl -fsS -m 15 "$CTRL_BASE/providers/proxies/$n/healthcheck" >/dev/null 2>&1 || true
    done < <(all_providers)
  fi
}

# ---------- 网络识别 ----------
# 每行输出 "uuid|name"，跳过 loopback 与 mihomo 自建的 tun
#   注意：TUN 开启后 NetworkManager 会把 mihomo 网卡也列为活动连接，
#   若不过滤，网络指纹会因"自己开了 TUN"而变化，造成重复施加的死循环。
current_network() {
  nmcli -t -f UUID,NAME,TYPE connection show --active 2>/dev/null \
    | awk -F: '$3 != "loopback" && $3 != "tun" { print $1"|"$2 }'
}

# 网络指纹：排序拼接，用于判断“网络是否变化”
network_key() {
  current_network | sort | paste -sd';' -
}

# 第一个活动连接的名字（供通知显示）
network_name() {
  current_network | head -n1 | cut -d'|' -f2
}

_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# 期望状态：任一活动连接命中 UUID 或名字 -> on，否则 off
desired_state() {
  local uuid name
  while IFS='|' read -r uuid name; do
    [ -z "$uuid" ] && continue
    if _in_list "$uuid" "${WHITELIST_UUIDS[@]}" \
       || _in_list "$name" "${WHITELIST_NAMES[@]}"; then
      echo on
      return 0
    fi
  done < <(current_network)
  echo off
}

# ---------- 订阅用量 ----------
# 供 proxy usage 显示 与 proxy-watch 每日自检
_usage_py='
import sys, json, datetime, os

def human(n):
    try:
        n = float(n)
    except Exception:
        return "未知"
    for u in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if n < 1024:
            return "%.2f%s" % (n, u)
        n /= 1024
    return "%.2fEiB" % n

def load():
    d = json.load(sys.stdin)
    return d.get("subscriptionInfo") or {}

def report(alert_only):
    si = load()
    up = si.get("Upload", 0) or 0
    dn = si.get("Download", 0) or 0
    total = si.get("Total", 0) or 0
    exp = si.get("Expire", 0) or 0
    used = up + dn
    days = None
    if exp and exp > 0:
        expdt = datetime.datetime.fromtimestamp(exp)
        days = (expdt - datetime.datetime.now()).days
    if alert_only:
        msgs = []
        if days is not None and days <= 3:
            msgs.append("订阅 %s 到期（剩 %d 天）" %
                        (datetime.datetime.fromtimestamp(exp).strftime("%Y-%m-%d"), days))
        if total:
            pct = used / total * 100
            if pct >= 90:
                msgs.append("流量已用 %.0f%%" % pct)
        print("；".join(msgs))
        return
    print("已用: %s / 总量: %s" % (human(used), human(total) if total else "未知"))
    print("上传: %s  下载: %s" % (human(up), human(dn)))
    if total:
        print("剩余: %s（%.1f%% 已用）" % (human(total - used), used / total * 100))
    if days is not None:
        print("到期: %s（剩 %d 天）" %
              (datetime.datetime.fromtimestamp(exp).strftime("%Y-%m-%d"), days))
    else:
        print("到期: 机场未返回")

report(bool(os.environ.get("ALERT_ONLY")))
'

usage_info_for() {
  # $1 = provider 名字
  api_get "/providers/proxies/$1" | python3 -c "$_usage_py" 2>/dev/null
}

# 单机场的提醒文本（无提醒则空）；读取失败返回非零
usage_alert_one() {
  local json
  json="$(api_get "/providers/proxies/$1")" || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | ALERT_ONLY=1 python3 -c "$_usage_py" 2>/dev/null
}

# 遍历所有机场，汇总提醒；全部读取失败返回非零
usage_alert() {
  local n out rc=1
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if out="$(usage_alert_one "$n")"; then
      rc=0
      [ -n "$out" ] && printf '[%s] %s\n' "$n" "$out"
    fi
  done < <(all_providers)
  return $rc
}

# ---------- 时间同步自检（proxy on/reload 与 proxy-watch 共用）----------
TIME_STATE="${XDG_RUNTIME_DIR:-/tmp}/mihomo-watch.time"

# 每个网络会话只自检一次；偏差超阈值才弹通知。失败静默、带超时（不阻塞调用方）。
time_check_auto() {
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$PROXYTIME_PY" ] || return 0
  local key json msg
  key="$(network_key)"
  if [ -f "$TIME_STATE" ] && [ "$(cat "$TIME_STATE" 2>/dev/null)" = "$key" ]; then
    return 0
  fi
  json="$(timeout 25 python3 "$PROXYTIME_PY" --json 2>/dev/null)" || return 0
  [ -n "$json" ] || return 0
  printf '%s' "$key" > "$TIME_STATE" 2>/dev/null || true
  msg="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
if not d.get("ok") or not d.get("exceeded"):
    raise SystemExit
off = d.get("offset", 0.0) or 0.0
print("%s %.2fs（源 %s）" % ("本地落后节点" if off > 0 else "本地超前节点",
                             abs(off), d.get("source", "?")))
' 2>/dev/null)"
  [ -n "$msg" ] && _notify "时间偏差" "$msg，可执行 proxy time --set"
  return 0
}

# ---------- 语言/时区对齐（proxy lang / proxy-watch 共用）----------

# 语言/时区状态两行（供 proxy status），无则提示未设置
region_status_lines() {
  python3 "$PROXYLANG_PY" status 2>/dev/null || printf '语言：未设置\n时区：未设置'
}

# 把 proxylang sync 的 JSON 转成通知；仅 changed 时弹
_region_notify() {
  local msg
  msg="$(printf '%s' "${1:-}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
if not d.get("ok") or not d.get("changed"):
    raise SystemExit
prim = (d.get("accept_language", "?") or "?").split(",")[0].split(";")[0]
tz = d.get("timezone", "?"); cc = d.get("cc", "?")
if d.get("via") == "direct":
    print("梯子已关，语言/时区恢复本机 IP → %s / %s（%s）" % (prim, tz, cc))
else:
    tail = "" if d.get("known", True) else "（未收录，已回退 en-US）"
    print("语言/时区已切换 → %s / %s（节点 %s）%s，重启浏览器生效" % (prim, tz, cc, tail))
' 2>/dev/null)"
  [ -n "$msg" ] && _notify "语言/时区" "$msg"
  return 0
}

# 开梯子后：跟随节点国家（仅变化时写入 + 通知）
region_sync_auto() {
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$PROXYLANG_PY" ] || return 0
  local json
  json="$(timeout 25 python3 "$PROXYLANG_PY" sync 2>/dev/null)" || return 0
  _region_notify "$json"
}

# 关梯子后：回退到本机直连 IP 的默认语言/时区
region_sync_off() {
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$PROXYLANG_PY" ] || return 0
  local json
  json="$(timeout 25 python3 "$PROXYLANG_PY" sync --direct 2>/dev/null)" || return 0
  _region_notify "$json"
}

# ---------- 节点选择/固定（proxy node）----------
NODE_GROUP="PROXY"
NODE_PIN_STATE="${XDG_RUNTIME_DIR:-/tmp}/mihomo-node.pinned"
DELAY_TEST_URL="https://www.gstatic.com/generate_204"
DELAY_TIMEOUT_MS="5000"

# PROXY 组全部可选节点名（按顺序，每行一个）
group_nodes() {
  api_get "/proxies/$NODE_GROUP" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for n in (d.get("all") or []):
    print(n)
' 2>/dev/null
}

# PROXY 组当前选择（now）
group_now() {
  api_get "/proxies/$NODE_GROUP" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("now") or "")
except Exception:
    pass
' 2>/dev/null
}

# 供 proxy status：整行「节点：<叶子>（固定/自动/直连，经 …）」
node_status_line() {
  api_get /proxies | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin).get("proxies") or {}
except Exception:
    print("节点：-（控制器不可达）"); raise SystemExit
g = d.get("PROXY") or {}
now = g.get("now") or ""
if not now:
    print("节点：-"); raise SystemExit
name, path, seen = now, ["PROXY"], set()
for _ in range(8):
    e = d.get(name)
    if not e:
        break
    nxt = e.get("now") or ""
    if not nxt or nxt in seen:
        break
    path.append(name); seen.add(name); name = nxt
if now == "自动选择":
    kind = "自动"
elif now == "DIRECT":
    kind = "直连"
else:
    kind = "固定"
if len(path) > 1:
    print("节点：%s（%s，经 %s）" % (name, kind, " → ".join(path)))
else:
    print("节点：%s（%s）" % (name, kind))
' 2>/dev/null || echo "节点：-"
}

# 组内全部节点延迟：输出 JSON {节点名: 延迟ms}
group_delay_map() {
  local enc
  enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DELAY_TEST_URL" 2>/dev/null)"
  curl -fsS -m 30 "$CTRL_BASE/group/$NODE_GROUP/delay?url=$enc&timeout=$DELAY_TIMEOUT_MS" 2>/dev/null
}

# 选定并持久化（store-selected: true 会写入 cache.db）
select_node() {
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}, ensure_ascii=False))' "$1" 2>/dev/null)" || return 1
  curl -fsS -m 5 -X PUT "$CTRL_BASE/proxies/$NODE_GROUP" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1
}

# 把 序号 / 完整名字 / 唯一子串 解析为节点名；不唯一或无匹配则报错返回非零
resolve_node() {
  local arg="$1" names=() n i
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(group_nodes)
  if [ "${#names[@]}" -eq 0 ]; then
    echo "无法读取节点列表（控制器不可达）" >&2
    return 1
  fi
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    if [ "$arg" -ge 1 ] && [ "$arg" -le "${#names[@]}" ]; then
      printf '%s' "${names[$((arg - 1))]}"
      return 0
    fi
    echo "序号超出范围（1..${#names[@]}）" >&2
    return 1
  fi
  for n in "${names[@]}"; do
    if [ "$n" = "$arg" ]; then printf '%s' "$n"; return 0; fi
  done
  local hits=()
  for n in "${names[@]}"; do
    case "${n,,}" in *"${arg,,}"*) hits+=("$n");; esac
  done
  case "${#hits[@]}" in
    1) printf '%s' "${hits[0]}"; return 0 ;;
    0) echo "没有匹配「$arg」的节点" >&2; return 1 ;;
    *)
      echo "「$arg」匹配到多个节点，请用序号或更完整的名字：" >&2
      for i in "${!hits[@]}"; do printf '  - %s\n' "${hits[$i]}" >&2; done
      return 1
      ;;
  esac
}

# 固定节点消失检测：mihomo 会静默回退到 proxies[0]，需自行记忆比对并弹提示
node_gone_check() {
  controller_up || return 0
  local now prev all cnt
  all="$(group_nodes)"
  # 列表为空/过短视为正在重载或不可用，本轮不判定（避免误报）
  cnt="$(printf '%s\n' "$all" | grep -c . || true)"
  [ "${cnt:-0}" -ge 3 ] || return 0
  now="$(group_now)"
  [ -n "$now" ] || return 0
  prev="$(cat "$NODE_PIN_STATE" 2>/dev/null || true)"
  if [ -n "$prev" ] && ! printf '%s\n' "$all" | grep -qxF -- "$prev"; then
    _notify "固定节点已失效" "「$prev」已不在列表（已回退），请执行 proxy node list 重选"
    rm -f "$NODE_PIN_STATE" 2>/dev/null || true
    return 0
  fi
  case "$now" in
    ""|"自动选择"|"DIRECT") rm -f "$NODE_PIN_STATE" 2>/dev/null || true ;;
    *) printf '%s' "$now" > "$NODE_PIN_STATE" 2>/dev/null || true ;;
  esac
  return 0
}

# ============================================================
# 机场清单（proxy sub）—— 清单是唯一真相，渲染进 config.yaml 标记块
# ============================================================

subs_list() {
  # 输出 "name<TAB>url"
  [ -f "$SUBS_FILE" ] || return 0
  python3 -c '
import sys, re
for line in open(sys.argv[1], encoding="utf-8"):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    parts = line.rstrip("\n").split("\t", 1)
    if len(parts) != 2:
        parts = re.split(r"\s+", s, 1)
    if len(parts) != 2:
        continue
    name = parts[0].strip()
    url = parts[1].strip().strip("\"").strip("\x27").strip()
    if name and url:
        print("%s\t%s" % (name, url))
' "$SUBS_FILE"
}

subs_names() { subs_list | cut -f1; }

subs_get() { subs_list | awk -F'\t' -v n="$1" '$1==n {print $2; exit}'; }

subs_has() { subs_names | grep -qxF -- "$1"; }

subs_count() { subs_names | grep -c . ; }

# 去首尾空白与包裹的引号（治"URL 引号内多空格"坑）
clean_url() {
  local u="$1"
  u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
  u="${u%\"}"; u="${u#\"}"; u="${u%\'}"; u="${u#\'}"
  u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
  printf '%s' "$u"
}

mask_url() {
  printf '%s' "$1" | sed -E 's#((token|password|passwd|sid)=)[^&"/ >]*#\1<redacted>#g'
}

# 渲染清单进 config.yaml 的标记块，并同步策略组 use 列表
subs_render_config() {
  local cfg="${1:-$MIHOMO_CONFIG}"
  python3 - "$cfg" "$SUBS_FILE" <<'PY'
import sys, re
cfg, manifest = sys.argv[1], sys.argv[2]
UA = "clash-verge/v2.0.0"
HC = "https://www.gstatic.com/generate_204"
entries = []
for line in open(manifest, encoding="utf-8"):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    parts = line.rstrip("\n").split("\t", 1)
    if len(parts) != 2:
        parts = re.split(r"\s+", s, 1)
    if len(parts) != 2:
        continue
    name = parts[0].strip()
    url = parts[1].strip().strip('"').strip("'").strip()
    if name and url:
        entries.append((name, url))
block = ["# >>> proxy:providers (自动生成，请用 proxy sub 管理，勿手改) >>>",
         "proxy-providers:"]
for name, url in entries:
    block += [
        "  %s:" % name,
        "    type: http",
        '    url: "%s"' % url,
        "    interval: 3600",
        "    path: ./providers/%s.yaml" % name,
        "    header:",
        "      User-Agent:",
        '        - "%s"' % UA,
    ]
    if len(entries) > 1:                      # 仅多机场时加前缀，避免重名
        block += ["    override:",
                  '      additional-prefix: "[%s] "' % name]
    block += [
        "    health-check:",
        "      enable: true",
        "      url: %s" % HC,
        "      interval: 300",
    ]
block.append("# <<< proxy:providers <<<")

lines = open(cfg, encoding="utf-8").read().splitlines()
try:
    s = next(i for i, l in enumerate(lines) if l.startswith("# >>> proxy:providers"))
    e = next(i for i in range(s + 1, len(lines)) if lines[i].startswith("# <<< proxy:providers"))
except StopIteration:
    s = next(i for i, l in enumerate(lines) if l.startswith("proxy-providers:"))
    e = next(i for i in range(s + 1, len(lines)) if lines[i].startswith("# ---"))
    while e - 1 > s and lines[e - 1].strip() == "":
        e -= 1
    e -= 1
new = lines[:s] + block + lines[e + 1:]
txt = "\n".join(new)
names = ", ".join(n for n, _ in entries)
txt = re.sub(r"(^\s*use:\s*)\[[^\]]*\]", lambda m: m.group(1) + "[" + names + "]", txt, flags=re.M)
open(cfg, "w", encoding="utf-8").write(txt + "\n")
PY
}

# 渲染 + mihomo -t 校验，失败回滚
subs_apply() {
  local tmp rc
  tmp="$(mktemp)"
  cp "$MIHOMO_CONFIG" "$tmp"
  subs_render_config "$MIHOMO_CONFIG"
  if mihomo -t -d "$CONF_DIR" >/dev/null 2>&1; then
    rm -f "$tmp"; return 0
  fi
  cp "$tmp" "$MIHOMO_CONFIG"; rm -f "$tmp"
  echo "配置校验失败，已回滚 config.yaml" >&2
  return 1
}

# 直连下载某机场订阅到 provider 缓存（绕过 TUN，治"鸡生蛋"）
direct_fetch() {
  local url="$1" out="$2" was_on
  was_on="$(tun_state)"
  [ "$was_on" = "true" ] && { set_tun false; sleep 2; }
  curl -fsS -A "$SUB_UA" --connect-timeout 15 --max-time 60 "$url" -o "$out"
  local rc=$?
  [ "$was_on" = "true" ] && { set_tun true; sleep 1; }
  return $rc
}

# 刷新单个机场：先 API，失败则直连下载兜底
subs_fetch_one() {
  local name="$1" url out cnt
  url="$(subs_get "$name")"
  [ -n "$url" ] || { echo "清单里没有机场：$name" >&2; return 1; }
  out="$PROVIDERS_DIR/$name.yaml"
  curl -fsS -m 20 -X PUT "$CTRL_BASE/providers/proxies/$name" >/dev/null 2>&1 || true
  sleep 1
  cnt="$(api_get "/providers/proxies/$name" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("proxies") or []))' 2>/dev/null)"
  if [ "${cnt:-0}" -ge 1 ] 2>/dev/null; then
    echo "API 刷新成功（$cnt 节点）"
    return 0
  fi
  echo "API 刷新失败，改用直连下载…"
  if direct_fetch "$url" "$out"; then
    reload_and_reapply
    echo "直连下载完成并已重载"
    return 0
  fi
  echo "直连下载失败" >&2
  return 1
}
