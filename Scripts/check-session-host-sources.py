#!/usr/bin/env python3
"""Every file in Tests/SessionHost is named by the script that compiles it.

`Scripts/test-session-host.sh` lists the sources it compiles by hand, so a
check file added without an entry there is never compiled: `main.swift` calls
a function nothing defines and the harness fails to build, which the compiler
only says once every other test has already run. This reads the folder and the
script and refuses a file the script leaves out, or an entry with no file.

Answers 0 when the two agree, 65 when they do not.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FOLDER = ROOT / "Tests" / "SessionHost"
SCRIPT = ROOT / "Scripts" / "test-session-host.sh"
# `    "$root/Tests/SessionHost/name.swift"` inside the sources array.
ENTRY = re.compile(r"\$root/Tests/SessionHost/([A-Za-z0-9_]+\.swift)")


def main() -> int:
    try:
        text = SCRIPT.read_text(encoding="utf-8")
    except OSError as error:
        print(f"error: {SCRIPT.name} cannot be read: {error}", file=sys.stderr)
        return 66
    present = sorted(path.name for path in FOLDER.glob("*.swift"))
    listed = sorted(set(ENTRY.findall(text)))

    failed = False
    for name in present:
        if name not in listed:
            print(
                f"error: Tests/SessionHost/{name} is not compiled — "
                "Scripts/test-session-host.sh has no entry for it, so the "
                "harness would not build",
                file=sys.stderr,
            )
            failed = True
    for name in listed:
        if name not in present:
            print(
                f"error: Scripts/test-session-host.sh compiles "
                f"Tests/SessionHost/{name}, which is not there",
                file=sys.stderr,
            )
            failed = True
    if failed:
        return 65
    print(f"ok: all {len(present)} SessionHost sources are compiled by test-session-host.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())