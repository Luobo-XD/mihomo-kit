#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""proxy lang —— 让浏览器对外语言/时区与当前出口一致。

- 开梯子：经节点取出口国家码（cloudflare trace 的 loc），映射到语言/时区；
- 关梯子：直连取本机出口国家码，回退到本机 IP 的默认语言/时区；
- 结果写入 config/region.json，供 proxy-browser / proxy status 读取。

复用 bin/proxytime.py 的网络与取时逻辑。仅使用 Python 标准库（CPython 3.14）。
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys

# 避免在 bin/ 产生 __pycache__
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proxytime as pt  # noqa: E402

TRACE_URL = "https://www.cloudflare.com/cdn-cgi/trace"

# 默认配置目录：由本脚本位置推导（bin/ 的上一级 /config），不再硬编码绝对路径
_DEFAULT_CONF_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config"
)
CONF_DIR = os.environ.get("PROXYLANG_CONF_DIR") or _DEFAULT_CONF_DIR
REGION_FILE = os.environ.get("PROXYLANG_REGION_FILE") or os.path.join(CONF_DIR, "region.json")
STATE_FILE = os.environ.get(
    "PROXYLANG_STATE_FILE",
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "mihomo-lang.cc"),
)
HOME_CC = os.environ.get("PROXYLANG_HOME_CC") or "CN"

TIMEOUT = float(os.environ.get("PROXYLANG_TIMEOUT", "8"))

# 国家码 -> (accept_language, ui_lang, timezone)；时区为国家级近似
REGIONS = {
    "CN": ("zh-CN,zh;q=0.9,en;q=0.8", "zh", "Asia/Shanghai"),
    "HK": ("zh-HK,zh;q=0.9,en;q=0.8", "zh", "Asia/Hong_Kong"),
    "TW": ("zh-TW,zh;q=0.9,en;q=0.8", "zh", "Asia/Taipei"),
    "MO": ("zh-MO,zh;q=0.9,en;q=0.8", "zh", "Asia/Macau"),
    "KR": ("ko-KR,ko;q=0.9,en;q=0.8", "ko", "Asia/Seoul"),
    "JP": ("ja-JP,ja;q=0.9,en;q=0.8", "ja", "Asia/Tokyo"),
    "SG": ("en-SG,en;q=0.9", "en", "Asia/Singapore"),
    "MY": ("ms-MY,ms;q=0.9,en;q=0.8", "ms", "Asia/Kuala_Lumpur"),
    "TH": ("th-TH,th;q=0.9,en;q=0.8", "th", "Asia/Bangkok"),
    "VN": ("vi-VN,vi;q=0.9,en;q=0.8", "vi", "Asia/Ho_Chi_Minh"),
    "PH": ("en-PH,en;q=0.9", "en", "Asia/Manila"),
    "ID": ("id-ID,id;q=0.9,en;q=0.8", "id", "Asia/Jakarta"),
    "IN": ("en-IN,en;q=0.9", "en", "Asia/Kolkata"),
    "US": ("en-US,en;q=0.9", "en", "America/New_York"),
    "CA": ("en-CA,en;q=0.9", "en", "America/Toronto"),
    "GB": ("en-GB,en;q=0.9", "en", "Europe/London"),
    "AU": ("en-AU,en;q=0.9", "en", "Australia/Sydney"),
    "DE": ("de-DE,de;q=0.9,en;q=0.8", "de", "Europe/Berlin"),
    "FR": ("fr-FR,fr;q=0.9,en;q=0.8", "fr", "Europe/Paris"),
    "NL": ("nl-NL,nl;q=0.9,en;q=0.8", "nl", "Europe/Amsterdam"),
    "RU": ("ru-RU,ru;q=0.9,en;q=0.8", "ru", "Europe/Moscow"),
    "TR": ("tr-TR,tr;q=0.9,en;q=0.8", "tr", "Europe/Istanbul"),
    "BR": ("pt-BR,pt;q=0.9,en;q=0.8", "pt", "America/Sao_Paulo"),
    "ES": ("es-ES,es;q=0.9,en;q=0.8", "es", "Europe/Madrid"),
    "IT": ("it-IT,it;q=0.9,en;q=0.8", "it", "Europe/Rome"),
    "PL": ("pl-PL,pl;q=0.9,en;q=0.8", "pl", "Europe/Warsaw"),
}

FALLBACK = ("en-US,en;q=0.9", "en", "America/New_York")

VIA_LABEL = {"proxy": "节点", "direct": "本机 IP", "manual": "手动"}


def region_from_cc(cc: str, ip: str | None, via: str) -> dict:
    cc = (cc or "").upper()
    entry = REGIONS.get(cc)
    known = entry is not None
    accept, ui, tz = entry if entry else FALLBACK
    return {
        "cc": cc or FALLBACK[0].split(",")[0].split("-")[-1],
        "accept_language": accept,
        "ui_lang": ui,
        "timezone": tz,
        "egress_ip": ip,
        "via": via,
        "source": "cloudflare",
        "known": known,
        "updated": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
    }


def detect(via: str):
    """经代理或直连取出口 (ip, cc)。失败抛异常。"""
    use_proxy = via == "proxy"
    last = None
    for _ in range(3):
        try:
            _, _, body, _ = pt._fetch_once(TRACE_URL, TIMEOUT, use_proxy)
            _, meta = pt._parse_trace(body)
            return meta.get("ip"), (meta.get("loc") or "").upper()
        except Exception as exc:
            last = exc
    raise RuntimeError(str(last) if last else "取区失败")


def region_for(via: str):
    """检测并返回 region dict；direct 失败时回退本机默认国家码。"""
    try:
        ip, cc = detect(via)
    except Exception:
        if via == "direct":
            return region_from_cc(HOME_CC, None, via)
        raise
    return region_from_cc(cc, ip, via)


def write_region(reg: dict) -> None:
    os.makedirs(os.path.dirname(REGION_FILE), exist_ok=True)
    with open(REGION_FILE, "w", encoding="utf-8") as fh:
        json.dump(reg, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def read_region():
    try:
        with open(REGION_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def read_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as fh:
            return fh.read().strip()
    except Exception:
        return None


def write_state(cc: str) -> None:
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as fh:
            fh.write(cc or "")
    except Exception:
        pass


def _label(reg: dict) -> str:
    via = reg.get("via", "proxy")
    return "%s %s" % (VIA_LABEL.get(via, via), reg.get("cc", "?"))


def describe(reg: dict) -> str:
    lines = [
        "国家/地区：%s（%s%s）" % (
            reg.get("cc", "?"), _label(reg),
            "" if reg.get("known", True) else "，未收录→已回退 en-US"),
        "Accept-Language：%s" % reg.get("accept_language", "?"),
        "界面语言：%s" % reg.get("ui_lang", "?"),
        "时区：%s" % reg.get("timezone", "?"),
    ]
    if reg.get("egress_ip"):
        lines.append("出口 IP：%s" % reg["egress_ip"])
    return "\n".join(lines)


def status_lines(reg) -> str:
    if not reg:
        return "语言：未设置\n时区：未设置"
    accept = reg.get("accept_language", "?")
    primary = accept.split(",")[0].split(";")[0]
    return "语言：%s（%s）\n时区：%s（%s）" % (
        primary, _label(reg), reg.get("timezone", "?"), _label(reg))


def _print_json(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False))


# ---------- 子命令 ----------
def cmd_detect(args) -> int:
    via = "direct" if args.direct else "proxy"
    try:
        reg = region_for(via)
    except Exception as exc:
        print("检测失败：%s" % exc, file=sys.stderr)
        return 3
    if args.json:
        _print_json({"ok": True, **reg})
    else:
        print(describe(reg))
        print("（仅预览；执行 `proxy lang apply` 写入）")
    return 0


def cmd_apply(args) -> int:
    via = "direct" if args.direct else "proxy"
    try:
        reg = region_for(via)
    except Exception as exc:
        print("检测失败：%s" % exc, file=sys.stderr)
        return 3
    write_region(reg)
    write_state(reg["cc"])
    if args.json:
        _print_json({"ok": True, **reg})
    else:
        print(describe(reg))
        print("已写入 %s；重启浏览器后生效。" % REGION_FILE)
    return 0


def cmd_reset(args) -> int:
    args.direct = True
    return cmd_apply(args)


def cmd_set(args) -> int:
    cc = args.cc.strip().upper()
    if not cc:
        print("用法：proxy lang set <国家码，如 US>", file=sys.stderr)
        return 2
    reg = region_from_cc(cc, None, "manual")
    write_region(reg)
    write_state(reg["cc"])
    if args.json:
        _print_json({"ok": True, **reg})
    else:
        print(describe(reg))
        print("已写入 %s（手动指定）。" % REGION_FILE)
    return 0


def cmd_show(args) -> int:
    reg = read_region()
    if not reg:
        print("尚未设置（先跑 `proxy lang apply` 或 `proxy lang`）。")
        return 1
    print("已设置：")
    print(describe(reg))
    if args.json:
        _print_json({"ok": True, "stored": reg})
    try:
        cur = region_for("proxy")
    except Exception as exc:
        print("（无法检测当前节点：%s）" % exc)
        return 0
    if cur["cc"] == reg.get("cc"):
        print("与当前节点一致（%s）" % cur["cc"])
    else:
        print("与当前节点不一致：节点 %s，已设置 %s" % (cur["cc"], reg.get("cc")))
    return 0


def cmd_region(args) -> int:
    _print_json(read_region() or {})
    return 0


def cmd_status(args) -> int:
    print(status_lines(read_region()))
    return 0


def cmd_sync(args) -> int:
    via = "direct" if args.direct else "proxy"
    try:
        reg = region_for(via)
    except Exception as exc:
        _print_json({"ok": False, "error": str(exc), "via": via})
        return 1
    changed = read_state() != reg["cc"]
    if changed:
        write_region(reg)
        write_state(reg["cc"])
    elif not read_region():
        write_region(reg)
    _print_json({
        "ok": True,
        "changed": changed,
        "cc": reg["cc"],
        "accept_language": reg["accept_language"],
        "ui_lang": reg["ui_lang"],
        "timezone": reg["timezone"],
        "egress_ip": reg.get("egress_ip"),
        "via": via,
        "known": reg.get("known", True),
    })
    return 0


# ---------- CLI ----------
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="proxy lang",
        description="让浏览器对外语言/时区与当前出口（节点）一致",
    )
    sub = parser.add_subparsers(dest="mode")

    def add(name, help_text):
        sp = sub.add_parser(name, help=help_text)
        sp.add_argument("--direct", action="store_true",
                        help="不走 7890 代理，直连取本机 IP 的区域")
        sp.add_argument("--json", action="store_true", help="JSON 输出")
        return sp

    add("detect", "检测并打印（不写入）")
    add("apply", "检测并写入 region.json")
    add("reset", "回退到本机直连 IP 的默认语言/时区")
    add("show", "显示已设置项，并与当前节点比对")
    add("region", "输出 region.json")
    add("status", "输出「语言/时区」两行状态")
    add("sync", "自动钩子：节点国家变化时才写入")
    sp = sub.add_parser("set", help="手动指定国家码")
    sp.add_argument("cc")
    sp.add_argument("--json", action="store_true", help="JSON 输出")
    return parser


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in ("-h", "--help", "help"):
        build_parser().print_help()
        return 0
    if not argv:
        argv = ["detect"]
    elif argv[0].startswith("-"):
        argv = ["detect"] + argv
    args = build_parser().parse_args(argv)
    func = {
        "detect": cmd_detect,
        "apply": cmd_apply,
        "reset": cmd_reset,
        "set": cmd_set,
        "show": cmd_show,
        "region": cmd_region,
        "status": cmd_status,
        "sync": cmd_sync,
    }.get(args.mode)
    if func is None:
        build_parser().print_help()
        return 2
    return func(args)


if __name__ == "__main__":
    sys.exit(main())
