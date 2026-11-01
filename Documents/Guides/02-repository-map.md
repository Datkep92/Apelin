# 02 Bản đồ repo

## Root level

| Path | Role |
|---|---|
| `Apelin/` | App UIKit chính |
| `Apelind/` | Daemon root/session/proxy/dispatch |
| `Workers/` | Thin entry points worker (`main.swift`) |
| `Packages/` | Shared Swift packages |
| `Shared/` | Cross target helpers/RoothideRoot/XPC shim |
| `Widgets/` | Extension widget target |
| `Extensions/` | `_agent tools` (assembler/disassembler) |
| `Configuration/` | `.xcconfig` versions/deployment |
| `Packaging/` | DEBIAN + entitlements + scripts for .deb |
| `Scripts/` | checks/packaging/install/device |
| `Tests/` | project tests |
| `Documents/` | docs, site, releases, research |
| `Licenses/` | third-party notices |
| `CA_NHAN_HOA.md` | fork changes log (must maintain) |

## Key files

- `AGENTS.md`: repo agent rules/checklist.
- `CHECKLIST.md`: release decisions, `make check` first gate.
- `Makefile`: harness/check/deb targets.
- `apelin-project.json`: Apelin IDE metadata (workspace external build).

## Dependency boundary

`make harness` validates system code boundaries. Apelind links only system code (packages explicitly listed), for example ApelinToolHost/ToolCore/CodeSign vendor.
