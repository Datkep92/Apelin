#!/usr/bin/env python3
"""Run the independent repository checks in parallel, in one report.

Additive early gate for `make check-parallel` and CI's `static-checks` job.
`make check` stays the authoritative sequential gate: this runner only calls
checks that can run side by side and never writes repository files.

Usage:
    Scripts/check-parallel.py [--root ROOT] [--jobs N] [--translations]
                              [--host-checks] [-v]
    Scripts/check-parallel.py --list

Exit 0 when every active check passes, 1 when any fails, 2 on bad arguments.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Optional, Union

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parent


@dataclass(frozen=True)
class Check:
    name: str
    argv: tuple[Union[str, pathlib.Path], ...]
    skip_reason: Optional[str] = None


@dataclass(frozen=True)
class Result:
    check: Check
    code: int
    output: str
    elapsed: float


def deployment_floor(root: pathlib.Path) -> str:
    config = root / "Configuration" / "Base.xcconfig"
    text = config.read_text(encoding="utf-8")
    match = re.search(r"^\s*IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([0-9.]+)", text, re.M)
    if match is None:
        raise SystemExit(f"{config}: IPHONEOS_DEPLOYMENT_TARGET is missing")
    return match.group(1)


def build_checks(root: pathlib.Path, translations: bool, host_checks: bool) -> list[Check]:
    python = sys.executable or "python3"
    scripts = root / "Scripts"
    app = root / "Apelin"
    widgets = root / "Widgets"
    source_roots = [
        app,
        root / "Apelind",
        root / "Shared",
        widgets,
        root / "Workers",
        root / "Packages" / "ApelinKit" / "Sources",
    ]

    host_only = None if host_checks else "chạy với --host-checks trên CI/macOS"

    checks = [
        Check("danh sách quyết định", (
            "sh", scripts / "check-checklist.sh", root / "CHECKLIST.md",
        )),
        Check("cú pháp Swift", (
            python, scripts / "check-swift-syntax.py", "--path", root,
        )),
        Check("nhãn điều khiển", (
            python, scripts / "check-accessibility.py", app,
        )),
        Check("khoá cũ", (
            python, scripts / "check-stale-strings.py", app, widgets,
        )),
        Check("định dạng chuỗi", (
            python, scripts / "check-format-strings.py", app, widgets,
        )),
        Check("xoá đệ quy", (
            python, scripts / "check-shell-deletes.py", root,
        )),
        Check("đường dẫn launchd", (
            python, scripts / "check-launchd-paths.py",
            root / "Packaging" / "wiki.qaq.apelind.plist",
            "--substituted-by", scripts / "package-deb.sh",
        )),
        Check("nguồn dịch vụ nền", (
            python, scripts / "check-session-host-sources.py",
        )),
        Check("phiên bản API", (
            python, scripts / "check-symbol-availability.py",
            deployment_floor(root), *source_roots,
        )),
        Check("dữ liệu lược đồ", (
            python, root / "Documents" / "Schemas" / "Tools" / "check-fixtures.py",
        ), host_only),
        Check("mẫu dự án", (
            python, root / "Extensions" / "Development" / "check-templates.py", "--no-build",
        ), host_only),
        Check("đăng ký dịch vụ nền", (
            python, scripts / "test-daemon-registration.py",
        ), host_only),
        Check("diff git", ("git", "-C", root, "diff", "--check")),
        Check("bản dịch", (
            python, scripts / "check-translations.py", app, widgets,
        ), None if translations else "chạy với --translations trên CI/macOS"),
    ]
    return checks


def run_check(check: Check, root: pathlib.Path, timeout: int) -> Result:
    argv = [str(part) for part in check.argv]
    started = time.monotonic()
    try:
        completed = subprocess.run(
            argv,
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            check=False,
            timeout=timeout,
        )
        return Result(check, completed.returncode, completed.stdout, time.monotonic() - started)
    except subprocess.TimeoutExpired as expired:
        output = expired.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        return Result(check, 124, output + f"\nquá {timeout}s\n", time.monotonic() - started)
    except OSError as error:
        return Result(check, 127, f"không chạy được: {error}\n", time.monotonic() - started)


def print_detail(result: Result, verbose: bool) -> None:
    lines = result.output.rstrip().splitlines()
    if not lines:
        return
    for line in lines if verbose else lines[:40]:
        print("      " + line)
    if not verbose and len(lines) > 40:
        print(f"      … còn {len(lines) - 40} dòng; dùng -v để đọc hết")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=DEFAULT_ROOT)
    parser.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 2))
    parser.add_argument("--translations", action="store_true")
    parser.add_argument("--host-checks", action="store_true",
                        help="bật các cổng cần /bin/sh và /private/tmp của macOS")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--list", action="store_true", help="in danh sách cổng rồi thoát")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if args.jobs < 1 or args.timeout < 1:
        parser.error("--jobs và --timeout phải lớn hơn 0")

    root = args.root.resolve()
    checks = build_checks(root, args.translations, args.host_checks)
    if args.list:
        for check in checks:
            print(f"{check.name}: {shlex.join([str(part) for part in check.argv])}")
        return 0

    active = [check for check in checks if check.skip_reason is None]
    skipped = [check for check in checks if check.skip_reason is not None]

    print(f"Kiểm song song tại {root} ({len(active)} cổng, {args.jobs} luồng)")
    for check in skipped:
        print(f"bỏ qua {check.name} ({check.skip_reason})")

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(
            lambda check: run_check(check, root, args.timeout), active
        ))

    bad = []
    for result in results:
        status = "ok  " if result.code == 0 else "LỖI"
        print(f"{status} {result.check.name} ({result.elapsed:.1f}s)")
        if args.verbose and result.code == 0 and result.output.strip():
            print_detail(result, True)
        if result.code != 0:
            bad.append(result)
    for result in bad:
        print(f"\n--- {result.check.name} (mã {result.code}) ---")
        print(f"    {shlex.join([str(part) for part in result.check.argv])}")
        print_detail(result, args.verbose)

    print(f"\nXong: {len(results) - len(bad)} đạt, {len(bad)} lỗi, {len(skipped)} bỏ qua")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
