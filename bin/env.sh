#!/usr/bin/env bash
# ============================================================
# env.sh —— 统一的环境 / 用户输入模块（被 libproxy.sh source）
#
#   优先级（高 → 低）：
#     1. 已导出的环境变量（可用于临时覆盖 / CI）
#     2. config/local.conf（本机用户输入，gitignore）
#     3. 从 config.yaml 读取（端口 / 控制器 / 绑定地址）
#     4. 自动推导（脚本位置、当前用户名）
#     5. 内置默认
#
#   本模块只做“变量收口”，不含业务逻辑。
# ============================================================

# 本文件所在目录（bin/），不依赖调用方的 cwd
_ENV_SH_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---------- 1) 载入 config/local.conf（若存在）----------
# 只在“对应变量尚未由环境提供”时应用；空白/引号会被清洗。
_PROJECT_DIR="${MIHOMO_PROJECT_DIR:-$(cd "$_ENV_SH_DIR/.." && pwd)}"
_CONF_DIR="${MIHOMO_CONF_DIR:-$_PROJECT_DIR/config}"
_LOCAL_CONF="${MIHOMO_LOCAL_CONF:-$_CONF_DIR/local.conf}"

if [ -f "$_LOCAL_CONF" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    _key="${_line%%=*}"
    _val="${_line#*=}"
    # 清洗 key（去空白）与校验
    _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
    case "$_key" in
      [A-Za-z_][A-Za-z0-9_]*) ;;
      *) continue ;;
    esac
    # 清洗 value（去首尾空白与包裹引号）
    _val="${_val#"${_val%%[![:space:]]*}"}"; _val="${_val%"${_val##*[![:space:]]}"}"
    _val="${_val%\"}"; _val="${_val#\"}"; _val="${_val%\'}"; _val="${_val#\'}"
    # 环境变量优先：已设置的非空值不覆盖
    if [ -z "${!_key:-}" ]; then
      export "$_key=$_val"
    fi
  done < "$_LOCAL_CONF"
  unset _line _key _val
fi

# ---------- 2) 自动推导 ----------
_ENV_USER="${MIHOMO_USER:-$(id -un 2>/dev/null || printf '%s' "${USER:-user}")}"

# ---------- 3) 目录 / 文件 ----------
export PROJECT_DIR="${MIHOMO_PROJECT_DIR:-$_PROJECT_DIR}"
export CONF_DIR="${MIHOMO_CONF_DIR:-$_CONF_DIR}"
export MIHOMO_CONFIG="${MIHOMO_CONFIG:-$CONF_DIR/config.yaml}"
export PROVIDERS_DIR="${MIHOMO_PROVIDERS_DIR:-$CONF_DIR/providers}"
export SUBS_FILE="${MIHOMO_SUBS_FILE:-$CONF_DIR/airports.conf}"
export SUBS_BAK="${MIHOMO_SUBS_BAK:-$SUBS_FILE.bak}"
export REGION_FILE="${MIHOMO_REGION_FILE:-$CONF_DIR/region.json}"

# ---------- 4) 从 config.yaml 读取运行时参数（轻量解析，无需 PyYAML）----------
# 读取形如 `key: value` 的顶层标量；找不到返回空。
_conf_scalar() {
  [ -f "$MIHOMO_CONFIG" ] || return 0
  awk -v key="$1" '
    index($0, key ":") == 1 {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", line)
      print line
      exit
    }
  ' "$MIHOMO_CONFIG" 2>/dev/null
}

_CTRL_ADDR="$(_conf_scalar external-controller)"
[ -n "$_CTRL_ADDR" ] || _CTRL_ADDR="127.0.0.1:9090"

_MIXED_PORT="$(_conf_scalar mixed-port)"
[ -n "$_MIXED_PORT" ] || _MIXED_PORT="7890"

_BIND_ADDR="$(_conf_scalar bind-address)"
case "$_BIND_ADDR" in ''|'*') _BIND_ADDR="127.0.0.1" ;; esac

export CTRL_BASE="${MIHOMO_CTRL:-http://$_CTRL_ADDR}"
export PROXY_MIXED_URL="${MIHOMO_MIXED_URL:-http://$_BIND_ADDR:$_MIXED_PORT}"

# ---------- 5) 其余可覆盖项 ----------
export MIHOMO_SERVICE="${MIHOMO_SERVICE:-mihomo@$_ENV_USER}"
export MIHOMO_BIN="${MIHOMO_BIN:-/usr/bin/mihomo}"
export SUB_UA="${SUB_UA:-clash-verge/v2.0.0}"
export NODE_GROUP="${NODE_GROUP:-PROXY}"
export HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://www.gstatic.com/generate_204}"
export DELAY_TEST_URL="${DELAY_TEST_URL:-$HEALTHCHECK_URL}"
export DELAY_TIMEOUT_MS="${DELAY_TIMEOUT_MS:-5000}"

# Python 侧（proxylang.py / proxytime.py）复用同一批变量
export PROXYLANG_CONF_DIR="${PROXYLANG_CONF_DIR:-$CONF_DIR}"
export PROXYLANG_REGION_FILE="${PROXYLANG_REGION_FILE:-$REGION_FILE}"
export PROXYLANG_HOME_CC="${PROXYLANG_HOME_CC:-CN}"

unset _ENV_SH_DIR _PROJECT_DIR _CONF_DIR _LOCAL_CONF _ENV_USER
unset _CTRL_ADDR _MIXED_PORT _BIND_ADDR
