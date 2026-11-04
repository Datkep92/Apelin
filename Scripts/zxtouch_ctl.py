#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ZXTouch local control helper for jailbroken iOS.

Connects to ZXTouch TCP server at 127.0.0.1:6000 and sends one command.
Touch commands do NOT receive a response (avoid socket hang).

Usage examples:
  python3 Scripts/zxtouch_ctl.py size
  python3 Scripts/zxtouch_ctl.py toast "Hello" 2
  python3 Scripts/zxtouch_ctl.py tap 562 1218
  python3 Scripts/zxtouch_ctl.py raw "2530"
"""
import argparse
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 6000
TIMEOUT = 3.0


def send(cmd: str, recv: bool = True, timeout: float = TIMEOUT) -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    time.sleep(0.05)
    s.send((cmd + "\r\n").encode("utf-8"))
    out = ""
    if recv:
        try:
            data = s.recv(4096)
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


def cmd_info(_):
    print(send("2530"))


def cmd_battery(_):
    print(send("2531"))


def cmd_toast(args):
    text = args.text
    dur = args.duration
    pos = args.position
    size = args.font_size
    print(send(f"220;;{text};;{dur};;{pos};;{size}"))


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
    # insert one char at a time
    for ch in args.text:
        print(send(f"241;;{ch}"))


def cmd_kb_delete(args):
    print(send(f"244;;{args.count}"))


def cmd_kb_show(args):
    code = "242;;2" if args.state == "show" else "242;;1"
    print(send(code))


def cmd_shell(args):
    print(send("13" + args.command))


def cmd_usleep(args):
    print(send(f"18{args.ms}"))


def cmd_raw(args):
    recv = not args.no_recv
    print(send(args.cmd, recv=recv))


def main():
    p = argparse.ArgumentParser(description="ZXTouch control helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("size", help="screen size").set_defaults(func=cmd_size)
    sub.add_parser("info", help="device info").set_defaults(func=cmd_info)
    sub.add_parser("battery", help="battery info").set_defaults(func=cmd_battery)

    t = sub.add_parser("toast", help="show toast")
    t.add_argument("text")
    t.add_argument("duration", type=int, nargs="?", default=2)
    t.add_argument("position", type=int, nargs="?", default=0)
    t.add_argument("font_size", type=int, nargs="?", default=0)
    t.set_defaults(func=cmd_toast)

    a = sub.add_parser("alert", help="show alert")
    a.add_argument("title")
    a.add_argument("content")
    a.add_argument("duration", type=int, nargs="?", default=2)
    a.set_defaults(func=cmd_alert)

    sw = sub.add_parser("switch", help="switch foreground app")
    sw.add_argument("bundle")
    sw.set_defaults(func=cmd_switch)

    for name, fn in (("touch-down", cmd_touch_down), ("touch-up", cmd_touch_up), ("touch-move", cmd_touch_move)):
        c = sub.add_parser(name)
        c.add_argument("x", type=int)
        c.add_argument("y", type=int)
        c.add_argument("finger", type=int, nargs="?", default=1)
        c.set_defaults(func=fn)

    tp = sub.add_parser("tap", help="tap at x y")
    tp.add_argument("x", type=int)
    tp.add_argument("y", type=int)
    tp.add_argument("finger", type=int, nargs="?", default=1)
    tp.add_argument("--hold", type=int, default=80, help="hold ms")
    tp.set_defaults(func=cmd_tap)

    ind = sub.add_parser("indicator", help="touch indicator on/off")
    ind.add_argument("state", choices=["on", "off"])
    ind.set_defaults(func=cmd_indicator)

    ki = sub.add_parser("kb-insert", help="insert text")
    ki.add_argument("text")
    ki.set_defaults(func=cmd_kb_insert)

    kd = sub.add_parser("kb-delete", help="delete n chars")
    kd.add_argument("count", type=int, nargs="?", default=1)
    kd.set_defaults(func=cmd_kb_delete)

    ks = sub.add_parser("kb-show", help="show/hide keyboard")
    ks.add_argument("state", choices=["show", "hide"])
    ks.set_defaults(func=cmd_kb_show)

    sh = sub.add_parser("shell", help="run shell as root (dangerous)")
    sh.add_argument("command")
    sh.set_defaults(func=cmd_shell)

    us = sub.add_parser("usleep", help="usleep ms")
    us.add_argument("ms", type=int)
    us.set_defaults(func=cmd_usleep)

    r = sub.add_parser("raw", help="send raw command")
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
