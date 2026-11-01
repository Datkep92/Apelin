# 05 Worker processes (Workers/)

Thin entries only delegate to package libraries; logic and tests happen at package level.

| Worker | Role | Package/libraries |
|---|---|---|
| Agent | per-session agent via host proxy | `Packages/ApelinAgent` + worker backend |
| Build | extensions/projects/builds | `ApelinProject`, `ApelinBuild`, `ApelinFormats` |
| Environment | toolchain/sdk/git/import | `ApelinToolchain`, `ApelinFormats`, project/git |
| Diagnostics | icli, crashes, screenshot/UI | `Packages/ApelinDiagnostics` |
| LogReader | reads root logs | `ApelinLogReaderWorker` only (root) |

## Spawn model
- Workers from `<prefix>/usr/libexec/apelin/<name>` only if root-owned + writable root only.
- `POSIX_SPAWN_CLOEXEC_DEFAULT`, channel descriptor 3.
- Mobile roles set uid/gid/groups 501 via posix_spawn attrs before exec.
- Worker self-drops if still root and assignment mismatch.
- Host records role at spawn; untrusted worker claims ignored.

## Environment propagation
- Worker host tasks starts with operation, payload and session pinned at `startTask(...resumable)`.
- On host restart: resume or interruption, and open rebuild state.

## Cancel rules
- Host channel closes => apelin-build kills tools.
- Terminal tasks may resume where applicable.
- Certain tasks cannot resume by security/state reasons (e.g. import creates duplicate, toolchain removal resumes itself).
