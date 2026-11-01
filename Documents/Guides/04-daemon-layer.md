# 04 Tầng daemon (Apelind/)

## Entry/process
- `main.swift`: proxy or session mode with `--session`, descriptor 3.
- `System.swift`, `Spawn.swift`: environment, worker spawn.
- `PeerAuthenticator.swift`: authentication order before decoding operation.

## Proxy (`Apelind/Proxy/`)
- `Proxy.swift`: auth + hello + forward unread request.
- `WorkLedger.swift`: idle/exit after work; respawn 1.5s if unfinished.
- SessionLink to host.

## Host session (`Apelind/Session/`)
- `SessionHost.swift` orchestrates all handlers.
- `TaskRegistry.swift` + `TaskResume.swift`: persist/replay/sum tasks/events.
- `CallerPolicy.swift`: rules who can call what.
- `WorkerSupervisor.swift`: spawn workers, role recording, trusted binaries only.
- `Install/`: host is irisind client, staging, conflict detection, installations store.
- `Approval/`: Confirm mode grants/APPROVAL digest rules.
- `Files/`: protected edit scopes.
- `Terminal/`: PTY host/sessions.

## Dispatch (`Dispatch/*Handler.swift`)
- Each handler maps `AppOperation` to implementation/service.
- Domain handlers: Agent, Build, Distribution, Environment, Files, Git, Install, Logs, Project, SDK, Terminal, Toolchain, ToolHost, Transfer.
- Caller policy enum per operation.

## Security & operator rules
- app entitlements required; executable regular, root-owned, not group/world write.
- path canonicalization + NUL reject.
- roothide path prefixed by jbroot.
- Managed package policy + repo conflicts.
- worker can only within policy narrowed rules.
