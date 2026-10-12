#!/usr/bin/env bash
# ============================================================
# libproxy.sh —— proxyctl / proxy-watch 共用库
#   职责：mihomo 控制 API 封装、网络白名单、通知封装
#   用法：. /path/to/libproxy.sh
# ============================================================

CTRL_BASE="http://127.0.0.1:9090"
MIHOMO_CONFIG="/home/Luo_bo/ConfMihomo/config/config.yaml"
PROVIDER="nanocloud"

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

provider_refresh() {
  curl -fsS -m 15 -X PUT "$CTRL_BASE/providers/proxies/$PROVIDER" >/dev/null 2>&1 || true
}

provider_healthcheck() {
  curl -fsS -m 15 "$CTRL_BASE/providers/proxies/$PROVIDER/healthcheck" >/dev/null 2>&1 || true
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

usage_info() {
  api_get "/providers/proxies/$PROVIDER" | python3 -c "$_usage_py" 2>/dev/null
}

# 仅输出需要提醒的内容（无提醒则空）；读取失败返回非零
usage_alert() {
  local json
  json="$(api_get "/providers/proxies/$PROVIDER")" || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | ALERT_ONLY=1 python3 -c "$_usage_py" 2>/dev/null
}
