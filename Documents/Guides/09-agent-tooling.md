# 09 Agent và công cụ

## Operations list
Closed `AppOperation` examples at top: build/install, toolchain/sdk, git, feedback, transfer, agent, screen/UI, diagnostics, logs/crash, task lifecycle. Each op needs:
- enum + metadata,
- request/response,
- handler,
- caller policy.

## Conversation lifecycle
- `agentOpen`: session/mode.
- `agentPrompt`: task events streaming.
- compact/approve/reply steering.
- model activation/provider credentials.
- project rename/open/deleted rules.

## Consent under Confirm mode
- build digest protect against description changes.
- install packaging digest checks.
- Agent UI action screen each operation approval from app (asks mode per session).
- removal approvals single-use/agent-r Removal requests.

## Tooling architecture
- ApelinAgent has tool registry with Operation contracts, provider API, credential store, context compaction, tasks.
- External tools/assembler/disassembler run separate process and use path mode.
- Project tool checks, transfer, skill tool and screen tools are separate docs/tests.

## Repo tools for the agent
Two scripts in `Scripts/` make the on-device edit → check → CI loop shorter. Neither builds, installs or publishes anything.

- `sh Scripts/quick-check.sh` — runs the local gates that work on the device (checklist, Swift syntax, accessibility, stale strings, format strings, recursive deletes, `git diff --check`) and prints one line per gate with the first error lines from any failure. `sh Scripts/quick-check.sh --full` adds launchd paths, session-host sources and API-floor checks; `-v` or `VERBOSE=1` prints every gate's full output. It deliberately skips `check-translations.py` (the device's `plutil` is not macOS's) and never calls `make check` (the device has no `/bin/bash`). `check-catalog-keys.py` also stays out: it needs `.stringsdata` from a real build.
- `sh Scripts/ci-fail.sh [sha] [--full] [--repo owner/name]` — finds the newest CI run for a commit (default `HEAD`), picks the failing job, downloads its log and prints the job URL plus the first error lines. Exit `2` means no CI / CI still running / the API could not be read; exit `1` means CI is red and the log excerpt names the failing job; exit `0` means no failed run was found. Needs `gh` signed in; `TMPDIR=/tmp` is set for `gh` on the device. `CI_FAIL_LINES=n` changes how many error lines are shown.

## Known and ongoing
- prompt cache / context context.
- DeepSeek compatibility.
- model provider operations from fork, not official maybe.
