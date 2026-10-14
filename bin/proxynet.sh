#!/usr/bin/env bash
# ============================================================
# proxynet.sh —— 网络白名单模块（决定 TUN 在哪些网络下自动开启）
#   被 libproxy.sh source。数据文件：config/networks.conf（唯一真相）
#   匹配语义：UUID 为主 + 连接名兜底（见 README「网络白名单」）
#   管理入口：proxy net（见 bin/proxy）
# ============================================================

NETS_FILE="$CONF_DIR/networks.conf"
NETS_BAK="$CONF_DIR/networks.conf.bak"
NETS_EXAMPLE="$CONF_DIR/networks.conf.example"

# 去首尾空白（供解析用；不改动已带空格的字段中间内容）
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 数据文件头（首次生成时写入）
net_header() {
  cat <<'EOF'
# 触发 TUN 的网络白名单（唯一真相，见 README「网络白名单」）
# 格式：UUID<TAB>连接名<TAB>备注(可选)；二者任一命中即视为该网络
# 用 `proxy net add/rm` 管理；本文件仅本机使用（已 gitignore）
EOF
}

# 内置默认：故意为空。—— 白名单属于本机数据，不随代码分发。
# 首运行为空即“任何网络都不开 TUN”，符合“校园网/未知网络零接触”的保守原则；
# 用户用 `proxy net add <序号|连接名>` 自行添加（数据写入 config/networks.conf）。
net_defaults() {
  :
}

# 确保数据文件存在：优先从模板复制，否则用内置默认生成
net_ensure_file() {
  [ -f "$NETS_FILE" ] && return 0
  if [ -f "$NETS_EXAMPLE" ]; then
    cp -a "$NETS_EXAMPLE" "$NETS_FILE"
  else
    { net_header; net_defaults; } > "$NETS_FILE"
  fi
  chmod 600 "$NETS_FILE" 2>/dev/null || true
  return 0
}

# 列出白名单条目：每行 "uuid<TAB>name<TAB>note"（跳过注释/空行）
net_list() {
  local line uuid name note
  net_ensure_file
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    IFS=$'\t' read -r uuid name note <<< "$line"
    uuid="$(_trim "${uuid:-}")"
    name="$(_trim "${name:-}")"
    note="$(_trim "${note:-}")"
    if [ -n "$uuid" ] || [ -n "$name" ]; then
      printf '%s\t%s\t%s\n' "$uuid" "$name" "$note"
    fi
  done < "$NETS_FILE"
}

# 命中判定：$1=uuid $2=name，任一与某条目匹配则返回 0
net_hit() {
  local want_uuid="$1" want_name="$2" line uuid name note
  net_ensure_file
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    IFS=$'\t' read -r uuid name note <<< "$line"
    uuid="$(_trim "${uuid:-}")"
    name="$(_trim "${name:-}")"
    if [ -n "$want_uuid" ] && [ -n "$uuid" ] && [ "$uuid" = "$want_uuid" ]; then
      return 0
    fi
    if [ -n "$want_name" ] && [ -n "$name" ] && [ "$name" = "$want_name" ]; then
      return 0
    fi
  done < "$NETS_FILE"
  return 1
}

# 期望的 TUN 状态：任一活动连接命中白名单 -> on，否则 off
net_desired_state() {
  local uuid name
  net_ensure_file
  while IFS='|' read -r uuid name; do
    [ -z "$uuid" ] && continue
    if net_hit "$uuid" "$name"; then
      echo on
      return 0
    fi
  done < <(current_network)
  echo off
}

# 把 序号 / UUID / 连接名 解析为 "uuid<TAB>name"（不在活动列表中时按类型存）
net_resolve_arg() {
  local arg="$1" i uuid name
  local uuids=() names=()
  while IFS='|' read -r uuid name; do
    [ -z "$uuid" ] && continue
    uuids+=("$uuid"); names+=("$name")
  done < <(current_network)
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    if [ "$arg" -ge 1 ] && [ "$arg" -le "${#uuids[@]}" ]; then
      printf '%s\t%s' "${uuids[$((arg - 1))]}" "${names[$((arg - 1))]}"
      return 0
    fi
    echo "序号超出范围（1..${#uuids[@]}）" >&2
    return 1
  fi
  for i in "${!uuids[@]}"; do
    if [ "${uuids[$i]}" = "$arg" ] || [ "${names[$i]}" = "$arg" ]; then
      printf '%s\t%s' "${uuids[$i]}" "${names[$i]}"
      return 0
    fi
  done
  if [[ "$arg" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf '%s\t' "$arg"
  else
    printf '\t%s' "$arg"
  fi
  return 0
}

# 新增条目：$1=uuid(可空) $2=name(可空) $3=备注(可空)；已存在返回 1
net_add() {
  local uuid="${1:-}" name="${2:-}" note="${3:-}"
  [ -n "$uuid" ] || [ -n "$name" ] || return 1
  net_ensure_file
  net_hit "$uuid" "$name" && return 1
  cp -a "$NETS_FILE" "$NETS_BAK" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$uuid" "$name" "$note" >> "$NETS_FILE"
  return 0
}

# 删除条目：$1=uuid 或 name（同名多条一并删除）；未命中返回 1
net_rm() {
  local needle="$1" line uuid name note tmp removed=0
  [ -n "$needle" ] || return 1
  net_ensure_file
  tmp="$(mktemp)" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
    esac
    IFS=$'\t' read -r uuid name note <<< "$line"
    uuid="$(_trim "${uuid:-}")"
    name="$(_trim "${name:-}")"
    if [ "$uuid" = "$needle" ] || [ "$name" = "$needle" ]; then
      removed=1
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$NETS_FILE"
  if [ "$removed" -eq 1 ]; then
    cp -a "$NETS_FILE" "$NETS_BAK" 2>/dev/null || true
    mv "$tmp" "$NETS_FILE"
    chmod 600 "$NETS_FILE" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp"
  return 1
}
