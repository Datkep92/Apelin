#!/bin/bash
# Compile how a conversation's plan is read out of the session's events, and
# the words the plan bar draws and reads for it, against the harness modules.
# Usage: test-chat-plan.sh <ApelinKit modules directory>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
modules="$1"
work="$(mktemp -d -t apelin-chat-plan)"
trap 'rm -rf -- "${work:?}"' EXIT

sources=(
    "$root/Apelin/Interface/Chats/ChatPlan.swift"
    "$root/Tests/ChatPlan/main.swift"
)

# The objects: one per module (the new build system) or one per source file.
objects=()
for module in ApelinCore ApelinProtocol; do
    if [[ -f "$modules/$module.o" ]]; then
        objects+=("$modules/$module.o")
    else
        while IFS= read -r object; do objects+=("$object"); done < <(find "$modules/.." "$modules" -maxdepth 2 -path "*/$module.build/*.o" | sort -u)
    fi
done
[[ ${#objects[@]} -ge 2 ]] || { echo "error: no ApelinCore/ApelinProtocol objects near $modules" >&2; exit 1; }

xcrun --sdk macosx swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -I "$root/Shared/XPCShim" -I "$modules" \
    "${objects[@]}" "${sources[@]}" -o "$work/chat-plan"
"$work/chat-plan"
echo "ok: ChatPlan"
