# Apelin — Kiến trúc & luồng xử lý

> Tài liệu chi tiết xem thêm: [Documents/Guides/README.md](Documents/Guides/README.md).  
> Tài liệu này là bản đồ tổng quan và phải cập nhật cùng commit khi thay đổi logic/luồng.

Tài liệu chi tiết của Guides được đặt để ai đọc và hiểu:
- App, daemon, worker, packages, build, runtime flows, agent/tooling, personalization, dev rules.

## 1. Mục tiêu dự án

Apelin là IDE on-device trên iOS/iPadOS 16+ jailbroken (roothide/rootless). Agent có thể:
- viết/chỉnh code trong project,
- setup toolchain/SDK,
- build + package + cài package,
- respring + kiểm tra tweak load,
- đọc log, crash report, screenshot/UI action,
- làm việc với git,
- publish package sang package repo cá nhân,
- import/export environment và project.

## 2. Thành phần chính

### 2.1 App — `Apelin/`
- `main.swift`, `DaemonClient.swift`: kết nối daemon.
- `Application/`: AppDelegate, LegacyHome, project routing, checks.
- `Interface/`: Chats, Projects, Settings, Feedback, Onboarding.
- `Service/ApelinService.swift`: glue layer calling daemon operations.
- `Widgets/`, `Resources/`: widget + assets/localization.

### 2.2 Daemon — `Apelind/`
- `main.swift`, `System.swift`, `Spawn.swift`: entry + spawn.
- `Proxy/`: thin proxy, auth, WorkLedger; daemon host.
- `Session/`: registry tasks/events, approvals, installs, worker supervisor, resume.
- `Dispatch/...Handler.swift`: operation handlers.
- `PeerAuthenticator.swift`: audit token, euid, entitlements, path checks.
- `Vendor/IrisinExternalClient`: irisind external client.

### 2.3 Workers
- `Workers/Agent/main.swift`: per-session agent (`Packages/ApelinAgent`).
- `Workers/Build/main.swift`: build (`Packages/ApelinBuild`, `ApelinProject`, formats).
- `Workers/Environment/main.swift`: toolchain/SDKs/git/transfer.
- `Workers/Diagnostics/main.swift`: icli, crash, screenshots/UI actions.
- `Workers/LogReader/main.swift`: root logs.

### 2.4 Shared kernel
- `Packages/ApelinKit`: protocol, operations.
- `Packages/ApelinProtocol`: wire envelope.
- `Packages/ApelinFormats`, diagnostics/toolchain/runtime pieces.
- `Shared/RoothideRoot.swift`, `XPCShim/`.

## 3. Luồng tổng quát app ↔ daemon

1. App handshake `hello` với apelind → install root + protocol version + capability list.
2. App gọi operation (`buildStart`, `agentPrompt`, `installPackage`, ...) qua XPC dictionary.
3. Daemon dispatch handler → spawn worker nếu cần → task registry records/events.
4. Worker báo `artifact/state/error` qua frame WorkerChannel.
5. Daemon relay events app attach via long-poll `attach-afterSeq`.
6. Task records persisted trước host exit; resumed on relaunch.

## 4. Flow/cache phải biết

### 4.1 Build/install
- Build package artifact from CI only; `apelin_project_build` on-device builds to build folder.
- Artifact digest + packaging digest + package files recorded.
- `installPackage` stages deb in staging, verifies digest, control file parse, ManagedPackagePolicy / conflicts, submits irisind.
- `removePackage` only records that succeeded + currently installed same version no newer record.

### 4.2 Agent session
- `agentOpen` sets permissions/mode.
- Confirm mode uses approvals: build digest protects build; artifact packaging digest protects install; single-use removal approval.
- Ask Before Using Screen: `asksBeforeScreen`, UI tree/action spend one approval per session.
- Normalize DeepSeek/OpenAI-compatible reasoning context at stream boundary (`AgentSession`).

### 4.3 Data home
- App data `~/Documents/wiki.qaq.apelin` (not container path after dfe14b9 fix).
- Import from old container one-time.

### 4.4 Git/publish
- GitOps through daemon handlers/workers.
- Release publish routes into package repository, CI workflow updates site.
- Follow release build digest + checks.

## 5. Build/check workflow

```sh
make harness      # tests on Mac
make check        # project/packaging/string/accessibility checks
make deb-all      # packages roothide/rootless
make install DEVICE_HOST=<addr> FLAVOR=roothide
```

Key scripts: build-package, package-deb structure; `Scripts/apply-version.sh`, `package-deb.sh`, `check-*.py`.

CI:
- `.github/workflows/ci.yml`: compile/package/deb artifact every push/PR.
- release.yml runs on tag, publish CI artifact.
- `pages.yml` watches release.

## 6. Fork/personalization registry
- Personalization history: `CA_NHAN_HOA.md` §6.1.
- Current fork has entries #1–#12, append-only.
- Don't overwrite old entries.

## 7. Bẫy và conventions
- Guard recursive rm `${VAR:?}`.
- roothide path handling by `RoothideRoot`, never bare jbroot.
- Strict/Full modes.
- No SF symbol newer target.
- stale string markers; prune manual only.
- No CLI, app peer only.

## 8. Khi thay đổi cần update ở đây
- Thêm module → section 2/4.
- Thêm op/wire → section 3.
- Thêm package/version → section 6 + CA_NHAN_HOA.
- Thêm hook/runtime behavior → flows sections.
- New guides under `Documents/Guides` if needed.

## 9. Nguồn gốc import repo
- Upstream: own goal-dev/Apelin.
- Fork: Datkep92/Apelin, main base upstream + personalization commits.
- Do not pull/push upstream tags.
- Push command requires `TMPDIR=/tmp`.

## 10. Regression checks
- `Scripts/check-accessibility.py Apelin`
- `Scripts/check-checklist.sh CHECKLIST.md`
- Stale strings check.
- Verify daemon version matching package.
- after changes re-read affected guides and update.
- Keep doc file index links accessible.

---
Last doc update: keep readmo sync on each change.
