#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ZXTouch local control helper for jailbroken iOS.

Connects to ZXTouch TCP server at 127.0.0.1:6000 and sends one command.
Touch commands do NOT receive a response (avoid socket hang).

Usage examples:
  python3 Scripts/zxtouch_ctl.py size
  python3 Scripts/zxtouch_ctl.py toast "Hello" 2
  python3 Scripts/zxtouch_ctl.py tap 562 1218
  python3 Scripts/zxtouch_ctl.py ocr 0 0 1125 100
  python3 Scripts/zxtouch_ctl.py raw "2530"
"""
import argparse
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 6000
TIMEOUT = 5.0


def send(cmd: str, recv: bool = True, timeout: float = TIMEOUT) -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    time.sleep(0.05)
    s.send((cmd + "\r\n").encode("utf-8"))
    out = ""
    if recv:
        try:
            data = s.recv(8192)
            out = data.decode("utf-8", errors="replace").strip()
        except socket.timeout:
            out = "<timeout: no response>"
    s.close()
    return out


def touch(type_code: int, x: int, y: int, finger: int = 1) -> str:
    payload = f"{type_code}{finger:02d}{x * 10:05d}{y * 10:05d}"
    cmd = "10" + payload
    return send(cmd, recv=False)


def cmd_size(_):
    print(send("251"))


def cmd_orientation(_):
    print(send("252"))


def cmd_scale(_):
    print(send("253"))


def cmd_info(_):
    print(send("2530"))


def cmd_battery(_):
    print(send("2531"))


def cmd_toast(args):
    print(send(f"22{args.type};;{args.text};;{args.duration};;{args.position};;{args.font_size}"))


def cmd_alert(args):
    print(send(f"12{args.title};;{args.content};;{args.duration}"))


def cmd_switch(args):
    print(send(f"11{args.bundle}"))


def cmd_touch_down(args):
    print(touch(1, args.x, args.y, args.finger))


def cmd_touch_up(args):
    print(touch(0, args.x, args.y, args.finger))


def cmd_touch_move(args):
    print(touch(2, args.x, args.y, args.finger))


def cmd_tap(args):
    touch(1, args.x, args.y, args.finger)
    time.sleep(args.hold / 1000.0)
    touch(0, args.x, args.y, args.finger)
    print("ok")


def cmd_indicator(args):
    code = "261" if args.state == "on" else "260"
    print(send(code))


def cmd_kb_insert(args):
    for ch in args.text:
        print(send(f"241;;{ch}"))


def cmd_kb_delete(args):
    print(send(f"244;;{args.count}"))


def cmd_kb_show(args):
    code = "242;;2" if args.state == "show" else "242;;1"
    print(send(code))


def cmd_kb_paste(_):
    print(send("245"))


def cmd_kb_get_clip(_):
    print(send("246"))


def cmd_kb_set_clip(args):
    print(send(f"247;;{args.text}"))


def cmd_kb_move(args):
    print(send(f"243;;{args.offset}"))


def cmd_color(args):
    print(send(f"23{args.x};;{args.y}"))


def cmd_color_search(args):
    print(send(f"281;;{args.x};;{args.y};;{args.w};;{args.h};;{args.rmin};;{args.rmax};;{args.gmin};;{args.gmax};;{args.bmin};;{args.bmax};;{args.skip}"))


def cmd_ocr(args):
    rect = f"{args.x},,{args.y},,{args.w},,{args.h}"
    print(send(f"271;;{rect};;{args.custom};;{args.minh};;{args.level};;{args.langs};;{args.correct};;{args.debug}"))


def cmd_image_match(args):
    print(send(f"21{args.path};;{args.maxtry};;{args.accept};;{args.scale}"))


def cmd_usleep(args):
    print(send(f"18{args.ms}"))


def cmd_record_start(_):
    print(send("14"))


def cmd_record_stop(_):
    print(send("15"))


def cmd_play_script(args):
    print(send(f"19{args.path}"))


def cmd_stop_script(_):
    print(send("20"))


def cmd_shell(args):
    print(send("13" + args.command))


def cmd_raw(args):
    recv = not args.no_recv
    print(send(args.cmd, recv=recv))


def main():
    p = argparse.ArgumentParser(description="ZXTouch control helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("size").set_defaults(func=cmd_size)
    sub.add_parser("orientation").set_defaults(func=cmd_orientation)
    sub.add_parser("scale").set_defaults(func=cmd_scale)
    sub.add_parser("info").set_defaults(func=cmd_info)
    sub.add_parser("battery").set_defaults(func=cmd_battery)

    t = sub.add_parser("toast")
    t.add_argument("text")
    t.add_argument("duration", type=int, nargs="?", default=2)
    t.add_argument("position", type=int, nargs="?", default=0)
    t.add_argument("font_size", type=int, nargs="?", default=0)
    t.add_argument("--type", dest="type", type=int, default=3)
    t.set_defaults(func=cmd_toast)

    a = sub.add_parser("alert")
    a.add_argument("title")
    a.add_argument("content")
    a.add_argument("duration", type=int, nargs="?", default=2)
    a.set_defaults(func=cmd_alert)

    sw = sub.add_parser("switch")
    sw.add_argument("bundle")
    sw.set_defaults(func=cmd_switch)

    for name, fn in (("touch-down", cmd_touch_down), ("touch-up", cmd_touch_up), ("touch-move", cmd_touch_move)):
        c = sub.add_parser(name)
        c.add_argument("x", type=int)
        c.add_argument("y", type=int)
        c.add_argument("finger", type=int, nargs="?", default=1)
        c.set_defaults(func=fn)

    tp = sub.add_parser("tap")
    tp.add_argument("x", type=int)
    tp.add_argument("y", type=int)
    tp.add_argument("finger", type=int, nargs="?", default=1)
    tp.add_argument("--hold", type=int, default=80)
    tp.set_defaults(func=cmd_tap)

    ind = sub.add_parser("indicator")
    ind.add_argument("state", choices=["on", "off"])
    ind.set_defaults(func=cmd_indicator)

    ki = sub.add_parser("kb-insert")
    ki.add_argument("text")
    ki.set_defaults(func=cmd_kb_insert)

    kd = sub.add_parser("kb-delete")
    kd.add_argument("count", type=int, nargs="?", default=1)
    kd.set_defaults(func=cmd_kb_delete)

    ks = sub.add_parser("kb-show")
    ks.add_argument("state", choices=["show", "hide"])
    ks.set_defaults(func=cmd_kb_show)

    sub.add_parser("kb-paste").set_defaults(func=cmd_kb_paste)
    sub.add_parser("kb-get-clip").set_defaults(func=cmd_kb_get_clip)

    ksc = sub.add_parser("kb-set-clip")
    ksc.add_argument("text")
    ksc.set_defaults(func=cmd_kb_set_clip)

    km = sub.add_parser("kb-move")
    km.add_argument("offset", type=int)
    km.set_defaults(func=cmd_kb_move)

    col = sub.add_parser("color")
    col.add_argument("x", type=int)
    col.add_argument("y", type=int)
    col.set_defaults(func=cmd_color)

    cs = sub.add_parser("color-search")
    cs.add_argument("x", type=int)
    cs.add_argument("y", type=int)
    cs.add_argument("w", type=int)
    cs.add_argument("h", type=int)
    cs.add_argument("rmin", type=int, nargs="?", default=0)
    cs.add_argument("rmax", type=int, nargs="?", default=255)
    cs.add_argument("gmin", type=int, nargs="?", default=0)
    cs.add_argument("gmax", type=int, nargs="?", default=255)
    cs.add_argument("bmin", type=int, nargs="?", default=0)
    cs.add_argument("bmax", type=int, nargs="?", default=255)
    cs.add_argument("skip", type=int, nargs="?", default=0)
    cs.set_defaults(func=cmd_color_search)

    ocr = sub.add_parser("ocr")
    ocr.add_argument("x", type=int)
    ocr.add_argument("y", type=int)
    ocr.add_argument("w", type=int)
    ocr.add_argument("h", type=int)
    ocr.add_argument("--custom", default="")
    ocr.add_argument("--minh", default="")
    ocr.add_argument("--level", type=int, default=0)
    ocr.add_argument("--langs", default="")
    ocr.add_argument("--correct", type=int, default=0)
    ocr.add_argument("--debug", default="")
    ocr.set_defaults(func=cmd_ocr)

    im = sub.add_parser("image-match")
    im.add_argument("path")
    im.add_argument("maxtry", type=int, nargs="?", default=4)
    im.add_argument("accept", type=float, nargs="?", default=0.8)
    im.add_argument("scale", type=float, nargs="?", default=0.8)
    im.set_defaults(func=cmd_image_match)

    us = sub.add_parser("usleep")
    us.add_argument("ms", type=int)
    us.set_defaults(func=cmd_usleep)

    sub.add_parser("record-start").set_defaults(func=cmd_record_start)
    sub.add_parser("record-stop").set_defaults(func=cmd_record_stop)

    ps = sub.add_parser("play-script")
    ps.add_argument("path")
    ps.set_defaults(func=cmd_play_script)

    sub.add_parser("stop-script").set_defaults(func=cmd_stop_script)

    sh = sub.add_parser("shell")
    sh.add_argument("command")
    sh.set_defaults(func=cmd_shell)

    r = sub.add_parser("raw")
    r.add_argument("cmd")
    r.add_argument("--no-recv", action="store_true")
    r.set_defaults(func=cmd_raw)

    args = p.parse_args()
    try:
        args.func(args)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
