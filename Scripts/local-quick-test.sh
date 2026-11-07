#!/bin/sh
# On-device quick test for C/Obj-C prototypes.
# Usage: sh Scripts/local-quick-test.sh <source.c|source.m>
set -e
SRC="$1"
[ -n "$SRC" ] || { echo "Usage: $0 <source>"; exit 2; }
SDK="/var/mobile/Documents/wiki.qaq.apelin/SDKs/iphoneos16.4-7e4638db"
ENT="/var/mobile/Documents/wiki.qaq.apelin/Projects/Apelin ứng dụng/Packaging/Apelin.entitlements"
OUT=/tmp/quicktest
clang -target arm64-apple-ios16.0 -isysroot "$SDK" -framework Foundation "$SRC" -o "$OUT"
ldid -S"$ENT" "$OUT"
"$OUT"
