#!/bin/bash
# Compile the app's event-to-transcript reducer, how it adopts the
# conversations agents open and how far it follows a turn, against the
# harness modules.
# Usage: test-chat-transcript.sh <ApelinKit modules directory>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
modules="$1"
work="$(mktemp -d -t apelin-chat-transcript)"
trap 'rm -rf "$work"' EXIT

sources=(
    "$root/Apelin/Interface/Chats/ChatSummary.swift"
    "$root/Apelin/Interface/Chats/Composer/ComposerDraft.swift"
    "$root/Apelin/Interface/Chats/Messages/ChatMessage.swift"
    "$root/Apelin/Interface/Chats/Messages/RootApprovalText.swift"
    "$root/Apelin/Interface/Chats/Messages/ToolCallBanner.swift"
    "$root/Apelin/Interface/Chats/Messages/ToolCallDetail.swift"
    "$root/Apelin/Interface/Chats/ChatTranscript.swift"
    "$root/Apelin/Interface/Chats/ChatTranscriptCache.swift"
    "$root/Apelin/Interface/Chats/ChatStore.swift"
    "$root/Apelin/Interface/Chats/ChatAdoption.swift"
    "$root/Apelin/Interface/Chats/TurnFollowing.swift"
    "$root/Tests/ChatTranscript/TranscriptFold.swift"
    "$root/Tests/ChatTranscript/ToolCallDetailCheck.swift"
    "$root/Tests/ChatTranscript/main.swift"
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
    "${objects[@]}" "${sources[@]}" -o "$work/chat-transcript"
"$work/chat-transcript"
