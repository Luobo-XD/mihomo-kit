#!/usr/bin/env bash
# ============================================================
# install-systemd.sh —— 渲染并安装 mihomo@ 的 drop-in
#
#   读 bin/env.sh 得到 CONF_DIR / MIHOMO_BIN，把模板
#   systemd/10-confdir.conf.in 渲染后安装到
#   /etc/systemd/system/mihomo@.service.d/10-confdir.conf 并 daemon-reload。
#
#   需要 root：未以 root 运行时会用 sudo 自我重入。
#
#   用法：
#     bin/install-systemd.sh             # 安装（会 sudo）
#     bin/install-systemd.sh --dry-run   # 只打印渲染结果，不写系统
#     bin/install-systemd.sh --uninstall # 移除 drop-in + daemon-reload
# ============================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=env.sh
. "$SELF_DIR/env.sh"

TEMPLATE="${MIHOMO_DROPIN_TEMPLATE:-$PROJECT_DIR/systemd/10-confdir.conf.in}"
DROPIN_DIR="/etc/systemd/system/mihomo@.service.d"
TARGET="$DROPIN_DIR/10-confdir.conf"

usage() {
  cat <<EOF
用法：install-systemd.sh [--dry-run|--uninstall|-h]

  无参数        渲染模板并安装 drop-in，然后 systemctl daemon-reload（需 sudo）
  --dry-run,-n  只打印渲染结果与目标路径（不写系统）
  --uninstall   删除已安装的 drop-in 并 daemon-reload（需 sudo）

相关变量（可由 config/local.conf 覆盖）：
  MIHOMO_BIN=${MIHOMO_BIN}
  CONF_DIR=${CONF_DIR}
  模板=${TEMPLATE}
  目标=${TARGET}
EOF
}

render() {
  [ -f "$TEMPLATE" ] || { echo "找不到模板：$TEMPLATE" >&2; return 1; }
  local out
  out="$(<"$TEMPLATE")"
  out="${out//@MIHOMO_BIN@/$MIHOMO_BIN}"
  out="${out//@CONF_DIR@/$CONF_DIR}"
  printf '%s\n' "$out"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -n|--dry-run)
    echo "# 渲染自：$TEMPLATE"
    echo "#   MIHOMO_BIN=$MIHOMO_BIN"
    echo "#   CONF_DIR=$CONF_DIR"
    echo "#   写入：$TARGET"
    echo
    render
    exit 0
    ;;
  --uninstall)
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -- "$0" "$@"; fi
    rm -f "$TARGET"
    systemctl daemon-reload
    echo "已移除 drop-in：$TARGET（mihomo@ 恢复发行版默认 ExecStart）"
    exit 0
    ;;
  "") : ;;
  *) echo "未知参数：$1" >&2; usage; exit 2 ;;
esac

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "需要 root，用 sudo 重新执行…" >&2
  exec sudo -- "$0"
fi

install -d -m 755 "$DROPIN_DIR"
tmp="$(mktemp)"
render > "$tmp"
install -m 644 "$tmp" "$TARGET"
rm -f "$tmp"
systemctl daemon-reload

echo "已安装 drop-in：$TARGET"
echo
echo "--- 内容 ---"
cat "$TARGET"
echo
echo "--- ExecStart（$MIHOMO_SERVICE）---"
systemctl show "$MIHOMO_SERVICE" -p ExecStart 2>/dev/null || true
