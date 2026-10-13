#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""proxy time —— 比对（并可选写入）本地时间与节点时间。

时间源：经 mihomo 混合端口(默认 127.0.0.1:7890)请求 HTTPS，读取远端时间：
    主源  https://www.cloudflare.com/cdn-cgi/trace   -> ts=<浮点 Unix 时间>（毫秒级）
    备源  https://www.gstatic.com/generate_204        -> Date 响应头（秒级）

默认只报告偏差；加 --set 才写本机时钟（timedatectl，经 pkexec/sudo 提权）。

仅使用 Python 标准库（适用于 CPython 3.14，更早版本亦兼容）。
"""

from __future__ import annotations

import argparse
import datetime as _dt
import email.utils
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

# 走 mihomo 的混合端口；TUN 关闭时该端口依然可用
PROXY_URL = os.environ.get("PROXY_MIXED_URL", "http://127.0.0.1:7890")
USER_AGENT = "clash-verge/v2.0.0"

# 依次尝试；第一个可用者胜出。
SOURCES = (
    {
        "name": "cloudflare",
        "url": "https://www.cloudflare.com/cdn-cgi/trace",
        "kind": "trace",   # 响应体里带 ts= 浮点时间戳 + ip=/loc= 出口信息
    },
    {
        "name": "gstatic",
        "url": "https://www.gstatic.com/generate_204",
        "kind": "date",    # 只有 Date 响应头，秒级精度
    },
)


# ---------- 取时 ----------
def _make_opener(use_proxy: bool) -> urllib.request.OpenerDirector:
    if use_proxy:
        handlers = [urllib.request.ProxyHandler({"http": PROXY_URL, "https": PROXY_URL})]
    else:
        # 空字典 = 显式禁用（含环境变量里的 *_proxy）
        handlers = [urllib.request.ProxyHandler({})]
    return urllib.request.build_opener(*handlers)


def _fetch_once(url: str, timeout: float, use_proxy: bool):
    """返回 (t0, t1, body, headers)：t0/t1 为请求发出/响应读完的本地时刻。"""
    opener = _make_opener(use_proxy)
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )
    t0 = time.time()
    with opener.open(req, timeout=timeout) as resp:
        body = resp.read(4096).decode("utf-8", "replace")
        headers = resp.headers
        t1 = time.time()
    return t0, t1, body, headers


def _parse_trace(body: str):
    info = {}
    for line in body.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            info[key.strip()] = value.strip()
    ts = info.get("ts")
    if not ts:
        raise ValueError("响应缺少 ts 字段")
    return float(ts), {"ip": info.get("ip"), "loc": info.get("loc")}


def _parse_date(headers):
    raw = headers.get("Date")
    if not raw:
        raise ValueError("响应缺少 Date 头")
    parsed = email.utils.parsedate_to_datetime(raw)
    if parsed is None:
        raise ValueError("Date 头无法解析")
    return parsed.timestamp(), {}


def _measure_source(source, timeout: float, use_proxy: bool, samples: int):
    """对单个源采样，返回 (最优样本 | None, 最后一次错误 | None)。"""
    best = None
    last_err = None
    for _ in range(samples):
        try:
            t0, t1, body, headers = _fetch_once(source["url"], timeout, use_proxy)
            if source["kind"] == "trace":
                remote, meta = _parse_trace(body)
                subsecond = True
            else:
                remote, meta = _parse_date(headers)
                subsecond = False
        except Exception as exc:  # 网络或解析失败 → 换下一个样本
            last_err = exc
            continue

        local_mid = (t0 + t1) / 2
        if subsecond:
            offset = remote - local_mid
        else:
            # Date 只有秒级精度：与本地同一秒对齐，避免 ~0.5s 系统误差
            offset = remote - round(local_mid)
        rtt = t1 - t0
        if best is None or rtt < best["rtt"]:
            best = {
                "name": source["name"],
                "offset": offset,
                "rtt": rtt,
                "subsecond": subsecond,
                "meta": meta,
            }
    return best, last_err


def measure(timeout: float, use_proxy: bool, samples: int) -> dict:
    errors = []
    for source in SOURCES:
        best, err = _measure_source(source, timeout, use_proxy, samples)
        if best is not None:
            return best
        if err is not None:
            errors.append("%s: %s" % (source["name"], err))
    raise RuntimeError("所有时间源均不可用：" + ("；".join(errors) if errors else "未知错误"))


# ---------- 输出 ----------
def _fmt(epoch: float):
    dt = _dt.datetime.fromtimestamp(epoch).astimezone()
    return dt.strftime("%Y-%m-%d %H:%M:%S %Z"), dt.strftime("%z")


def _human_offset(offset: float) -> str:
    if abs(offset) < 0.005:
        return "本地与节点时间一致"
    who = "本地落后节点" if offset > 0 else "本地超前节点"
    return "%s %.2fs" % (who, abs(offset))


def report(res: dict, threshold: float) -> None:
    local_epoch = time.time()
    remote_epoch = local_epoch + res["offset"]
    local_str, local_zone = _fmt(local_epoch)
    remote_str, remote_zone = _fmt(remote_epoch)
    meta = res["meta"] or {}
    egress = meta.get("ip") or "未知"
    if meta.get("loc"):
        egress += " (%s)" % meta["loc"]
    print("本地时间：%s %s" % (local_str, local_zone))
    print("节点时间：%s %s  源=%s 出口=%s RTT=%.0fms" % (
        remote_str, remote_zone, res["name"], egress, res["rtt"] * 1000))
    print("时钟偏差：%s" % _human_offset(res["offset"]))
    if abs(res["offset"]) >= threshold:
        print("判定    ：超过阈值 %.2fs → 可执行 `proxy time --set` 写入" % threshold)
    else:
        print("判定    ：在阈值 %.2fs 之内，无需写入" % threshold)


def result_json(res: dict, threshold: float) -> dict:
    local_epoch = time.time()
    remote_epoch = local_epoch + res["offset"]
    meta = res["meta"] or {}
    return {
        "ok": True,
        "offset": round(res["offset"], 3),
        "rtt": round(res["rtt"], 4),
        "source": res["name"],
        "egress_ip": meta.get("ip"),
        "egress_loc": meta.get("loc"),
        "threshold": threshold,
        "exceeded": abs(res["offset"]) >= threshold,
        "local": round(local_epoch, 3),
        "remote": round(remote_epoch, 3),
        "resolution": "ms" if res["subsecond"] else "s",
    }


# ---------- 写入系统时间 ----------
def _privileged_runner():
    if (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) and shutil.which("pkexec"):
        return ["pkexec"]
    if shutil.which("sudo"):
        return ["sudo"]
    if shutil.which("pkexec"):
        return ["pkexec"]
    return None


def _run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()


def apply_set(res: dict, threshold: float, keep_ntp_off: bool) -> int:
    offset = res["offset"]
    if abs(offset) < threshold:
        print("偏差 %.2fs 在阈值 %.2fs 之内，跳过写入。" % (abs(offset), threshold))
        return 0
    if not shutil.which("timedatectl"):
        print("未找到 timedatectl，无法写入系统时间。", file=sys.stderr)
        return 1
    priv = _privileged_runner()
    if priv is None:
        print("未找到 pkexec/sudo，无法提权写入系统时间。", file=sys.stderr)
        return 1

    target = time.time() + offset
    stamp = _dt.datetime.fromtimestamp(target).strftime("%Y-%m-%d %H:%M:%S")
    steps = [
        [*priv, "timedatectl", "set-ntp", "false"],
        [*priv, "timedatectl", "set-time", stamp],
    ]
    if not keep_ntp_off:
        steps.append([*priv, "timedatectl", "set-ntp", "true"])

    for cmd in steps:
        rc, out, err = _run(cmd)
        if rc != 0:
            print("执行 `%s` 失败：%s" % (
                " ".join(cmd[1:]), err or out or "退出码 %d" % rc), file=sys.stderr)
            return rc

    now = _dt.datetime.now().astimezone()
    print("已写入系统时间：%s %s（目标 %s，修正 %s）" % (
        now.strftime("%Y-%m-%d %H:%M:%S"), now.strftime("%z"),
        stamp, _human_offset(offset)))
    if not keep_ntp_off:
        print("提示：已重新打开 NTP（systemd-timesyncd 会再次校准）；"
              "想以节点为准可加 --keep-ntp-off。")
    return 0


# ---------- 入口 ----------
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="proxy time",
        description="比对（并可选写入）本地时间与节点时间；默认只报告，--set 才写系统时钟",
    )
    parser.add_argument("--set", action="store_true",
                        help="偏差超过阈值时写入系统时间（经 pkexec/sudo 提权）")
    parser.add_argument("--threshold", type=float, default=1.0, metavar="SEC",
                        help="判定/写入阈值秒数（默认 1.0）")
    parser.add_argument("--json", action="store_true",
                        help="以 JSON 输出（供脚本/通知使用）")
    parser.add_argument("--direct", action="store_true",
                        help="不经 7890 代理直连时间源（TUN 开着时仍会经 TUN）")
    parser.add_argument("--samples", type=int, default=3, metavar="N",
                        help="每个时间源的采样次数（默认 3）")
    parser.add_argument("--timeout", type=float, default=8.0, metavar="SEC",
                        help="单次请求超时秒数（默认 8）")
    parser.add_argument("--keep-ntp-off", action="store_true",
                        help="写入后不重新打开 NTP（默认会重新打开）")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    use_proxy = not args.direct
    try:
        res = measure(args.timeout, use_proxy, max(1, args.samples))
    except Exception as exc:
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print("取时失败：%s" % exc, file=sys.stderr)
        return 3

    if args.json:
        print(json.dumps(result_json(res, args.threshold), ensure_ascii=False))
    else:
        report(res, args.threshold)

    if args.set:
        if not args.json:
            print()
        return apply_set(res, args.threshold, args.keep_ntp_off)
    return 0


if __name__ == "__main__":
    sys.exit(main())
