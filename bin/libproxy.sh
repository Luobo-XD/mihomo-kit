#!/usr/bin/env bash
# ============================================================
# libproxy.sh —— proxyctl / proxy-watch 共用库
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
PROVIDER="nanocloud"   # 兼容旧引用；新逻辑用 all_providers()

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
}

provider_refresh() {
  curl -fsS -m 15 -X PUT "$CTRL_BASE/providers/proxies/${1:-$PROVIDER}" >/dev/null 2>&1 || true
}

provider_healthcheck() {
  curl -fsS -m 15 "$CTRL_BASE/providers/proxies/${1:-$PROVIDER}/healthcheck" >/dev/null 2>&1 || true
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
# 供 proxyctl usage 显示 与 proxy-watch 每日自检
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

usage_info() {
  usage_info_for "${1:-$PROVIDER}"
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

# ============================================================
# 机场清单（proxyctl sub）—— 清单是唯一真相，渲染进 config.yaml 标记块
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
block = ["# >>> proxyctl:providers (自动生成，请用 proxyctl sub 管理，勿手改) >>>",
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
block.append("# <<< proxyctl:providers <<<")

lines = open(cfg, encoding="utf-8").read().splitlines()
try:
    s = next(i for i, l in enumerate(lines) if l.startswith("# >>> proxyctl:providers"))
    e = next(i for i in range(s + 1, len(lines)) if lines[i].startswith("# <<< proxyctl:providers"))
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
