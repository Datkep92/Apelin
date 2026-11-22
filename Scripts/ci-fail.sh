#!/bin/sh
# Đọc CI của một commit: biết job nào đỏ và dòng lỗi đầu tiên, không mở trình duyệt.
# Dùng: Scripts/ci-fail.sh [sha] [--full] [--repo owner/name]
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
REPO=${REPO:-Datkep92/Apelin}
SHA=HEAD
FULL=0
LIMIT=${CI_FAIL_LINES:-24}

while [ $# -gt 0 ]; do
    case "$1" in
        --full) FULL=1; shift ;;
        --repo)
            if [ $# -lt 2 ]; then printf 'Thiếu tên repo sau --repo\n' >&2; exit 2; fi
            REPO=$2; shift 2 ;;
        -h|--help)
            printf 'Dùng: %s [sha] [--full] [--repo owner/name]\n' "$0"
            printf '  mặc định: commit HEAD của repo hiện tại, CI gần nhất cho commit đó\n'
            printf '  --full  in mọi dòng lỗi thay vì %s dòng đầu\n' "$LIMIT"
            exit 0 ;;
        -*) printf 'Tuỳ chọn không rõ: %s\n' "$1" >&2; exit 2 ;;
        *) SHA=$1; shift ;;
    esac
done

# gh trên máy này cần TMPDIR=/tmp; dùng hàm để mọi lời gọi đều được set.
gh() { TMPDIR=/tmp command gh "$@"; }

sha=$(git -C "$ROOT" rev-parse --verify "${SHA}^{commit}" 2>/dev/null) || sha=$SHA
[ -n "$sha" ] || { printf 'Không xác định được commit\n' >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/apelin-ci-fail.XXXXXX") || exit 2
trap 'rm -rf "${tmp:?}"' EXIT HUP INT TERM

if ! gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=10" \
        >"$tmp/runs.json" 2>"$tmp/err"; then
    printf 'Không đọc được CI của %s trên %s:\n' "$sha" "$REPO"
    sed -n '1,20p' "$tmp/err"
    printf 'Nếu cần, đăng nhập: gh auth login\n'
    exit 2
fi

jq -r '.workflow_runs[]? | [.id, .status, (.conclusion // "-"), .name, .html_url] | @tsv' \
    "$tmp/runs.json" >"$tmp/runs.tsv" 2>"$tmp/err" || {
        printf 'Không đọc được danh sách chạy:\n' >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 2
    }

if [ ! -s "$tmp/runs.tsv" ]; then
    printf 'Chưa có CI nào cho commit %s trên %s\n' "$sha" "$REPO"
    exit 2
fi

run_line=$(awk -F'\t' '$3 == "failure" { print; exit }' "$tmp/runs.tsv")
red=1
if [ -z "$run_line" ]; then
    # Một commit có thể có cả chạy CI, Release, Pages; ưu tiên chạy CI đã xong.
    run_line=$(awk -F'\t' '$2 == "completed" && $4 == "CI" { print; exit }' "$tmp/runs.tsv")
    red=0
fi
if [ -z "$run_line" ]; then
    run_line=$(awk -F'\t' '$2 == "completed" { print; exit }' "$tmp/runs.tsv")
fi
if [ -z "$run_line" ]; then
    run_line=$(awk -F'\t' 'NR == 1 { print; exit }' "$tmp/runs.tsv")
    IFS='	' read -r run_id run_status run_conclusion run_name run_url <<EOF
$run_line
EOF
    printf 'CI chưa xong: %s %s (%s)\n%s\n' "$run_id" "$run_status" "$run_name" "$run_url"
    exit 2
fi

IFS='	' read -r run_id run_status run_conclusion run_name run_url <<EOF
$run_line
EOF
printf 'Chạy %s %s — %s\n%s\n' "$run_id" "$run_conclusion" "$run_name" "$run_url"
if [ "$red" -eq 0 ]; then
    printf 'Không có chạy nào đỏ cho commit này.\n'
    exit 0
fi

if ! gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" \
        >"$tmp/jobs.json" 2>"$tmp/err"; then
    printf 'Không đọc được danh sách job:\n' >&2
    sed -n '1,20p' "$tmp/err" >&2
    exit 2
fi

jq -r '.jobs[]? | select(.conclusion == "failure") |
       [.id, .name, (.conclusion // "-"), .html_url] | @tsv' \
    "$tmp/jobs.json" >"$tmp/jobs.tsv" 2>"$tmp/err" || {
        printf 'Không đọc được danh sách job:\n' >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 2
    }

if [ ! -s "$tmp/jobs.tsv" ]; then
    printf 'Chạy này đỏ nhưng không có job nào báo failure; mở liên kết ở trên để xem chi tiết.\n'
    exit 1
fi

count=0
while IFS='	' read -r job_id job_name job_conclusion job_url; do
    [ -n "$job_id" ] || continue
    count=$((count + 1))
    if [ "$FULL" -eq 0 ] && [ "$count" -gt 3 ]; then
        printf '… còn job đỏ khác; dùng --full để xem hết\n'
        break
    fi
    printf '\nJob %s — %s\n%s\n' "$job_id" "$job_name" "$job_url"

    if ! gh api "repos/$REPO/actions/jobs/$job_id/logs" \
            >"$tmp/job.log" 2>"$tmp/err"; then
        printf 'Không tải được log job này:\n'
        sed -n '1,10p' "$tmp/err"
        continue
    fi

    # Ưu tiên dòng có tệp/dòng, rồi đến annotation, rồi mới đến lỗi chung.
    # Nếu không phân tầng, hàng chục warning "No such file" lấn dòng lỗi thật.
    filter_lines() {
        grep -nE "$1" "$tmp/job.log" 2>/dev/null |
            grep -v '##\[warning\]' |
            awk -F: '!seen[$0]++'
    }
    filter_lines '\.swift:[0-9]+:[0-9]+: error:' >"$tmp/hits"
    if [ ! -s "$tmp/hits" ]; then filter_lines '##\[error\]' >"$tmp/hits"; fi
    if [ ! -s "$tmp/hits" ]; then
        filter_lines '(^|[^[:alpha:]])error:|\bFAIL(ED|URE)?\b|\bfatal error:' >"$tmp/hits"
    fi
    if [ ! -s "$tmp/hits" ]; then
        filter_lines '\bcannot\b|\bundefined reference\b|\bNo such file\b|\bnot found\b' >"$tmp/hits"
    fi

    if [ -s "$tmp/hits" ]; then
        if [ "$FULL" -eq 1 ]; then
            sed -n '1,300p' "$tmp/hits"
        else
            sed -n "1,${LIMIT}p" "$tmp/hits"
        fi
    else
        printf 'Không thấy dòng lỗi rõ; 20 dòng cuối của log:\n'
        tail -n 20 "$tmp/job.log"
    fi
done <"$tmp/jobs.tsv"

exit 1
