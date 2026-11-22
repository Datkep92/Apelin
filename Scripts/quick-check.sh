#!/bin/sh
# Nhanh: các cổng kiểm chạy được trên iPhone, không cần make/xcodebuild.
# Dùng: Scripts/quick-check.sh [--full] [-v]
#        VERBOSE=1 Scripts/quick-check.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
FULL=0
VERBOSE=${VERBOSE:-0}

for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help)
            printf 'Dùng: %s [--full] [-v]\n' "$0"
            printf '  --full  thêm kiểm launchd, symbol, nguồn dịch vụ nền\n'
            printf '  -v      in toàn bộ output của từng cổng\n'
            exit 0 ;;
        *) printf 'Tuỳ chọn không rõ: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

LOG=$(mktemp "${TMPDIR:-/tmp}/apelin-quick-check.XXXXXX") || exit 2
trap 'rm -f "$LOG"' EXIT HUP INT TERM

ok=0
bad=0
skip=0

run() {
    _name=$1
    shift
    if "$@" >"$LOG" 2>&1; then
        ok=$((ok + 1))
        printf 'ok    %s\n' "$_name"
        if [ "$VERBOSE" = 1 ]; then
            sed 's/^/      /' "$LOG"
        fi
    else
        _rc=$?
        bad=$((bad + 1))
        printf 'LỖI  %s (mã %s)\n' "$_name" "$_rc"
        sed -n '1,40p' "$LOG" | sed 's/^/      /'
        if [ "$VERBOSE" = 1 ]; then
            sed -n '41,240p' "$LOG" | sed 's/^/      /'
        fi
    fi
    return 0
}

printf 'Kiểm nhanh tại %s\n' "$ROOT"

# make check không chạy trên máy (thiếu /bin/bash), nên gọi từng cổng.
run 'danh sách quyết định' sh "$ROOT/Scripts/check-checklist.sh" "$ROOT/CHECKLIST.md"
run 'cú pháp Swift' python3 "$ROOT/Scripts/check-swift-syntax.py" --path "$ROOT"
run 'nhãn điều khiển' python3 "$ROOT/Scripts/check-accessibility.py" "$ROOT/Apelin"
run 'khoá cũ' python3 "$ROOT/Scripts/check-stale-strings.py" "$ROOT/Apelin" "$ROOT/Widgets"
run 'định dạng chuỗi' python3 "$ROOT/Scripts/check-format-strings.py" "$ROOT/Apelin" "$ROOT/Widgets"
run 'xoá đệ quy' python3 "$ROOT/Scripts/check-shell-deletes.py" "$ROOT"
run 'diff git' git -C "$ROOT" diff --check

if [ "$FULL" = 1 ]; then
    run 'đường dẫn launchd' python3 "$ROOT/Scripts/check-launchd-paths.py" \
        "$ROOT/Packaging/wiki.qaq.apelind.plist" \
        --substituted-by "$ROOT/Scripts/package-deb.sh"
    run 'nguồn dịch vụ nền' python3 "$ROOT/Scripts/check-session-host-sources.py"
    FLOOR=$(awk -F= '/^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET[[:space:]]*=/ {
        gsub(/[[:space:]]/, "", $2); print $2; exit
    }' "$ROOT/Configuration/Base.xcconfig")
    if [ -n "$FLOOR" ]; then
        run 'phiên bản API' python3 "$ROOT/Scripts/check-symbol-availability.py" "$FLOOR" \
            "$ROOT/Apelin" "$ROOT/Apelind" "$ROOT/Shared" "$ROOT/Widgets" \
            "$ROOT/Workers" "$ROOT/Packages/ApelinKit/Sources"
    else
        printf 'bỏ qua phiên bản API (không đọc được mức triển khai)\n'
        skip=$((skip + 1))
    fi
fi

# check-translations.py cần plutil của macOS; trên máy này báo lỗi giả.
printf 'bỏ qua bản dịch (plutil trên máy không phải của macOS)\n'
skip=$((skip + 1))

printf 'Xong: %s đạt, %s lỗi, %s bỏ qua\n' "$ok" "$bad" "$skip"
[ "$bad" -eq 0 ] || exit 1
exit 0
