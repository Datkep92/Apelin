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

## Known and ongoing
- prompt cache / context context.
- DeepSeek compatibility.
- model provider operations from fork, not official maybe.
