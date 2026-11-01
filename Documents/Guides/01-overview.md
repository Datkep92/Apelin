# 01 Tổng quan

## 1.1 Apelin làm gì

Apelin là IDE on-device trên iOS/iPadOS 16+ jailbroken, chạy cả rootless và roothide. Agent có thể:
- viết/chỉnh code trong project,
- setup toolchain/SDK,
- build + package + cài package,
- respring + kiểm tra tweak load,
- đọc log, crash report, screenshot/UI action,
- làm việc với git,
- publish package sang package repo cá nhân,
- import/export environment và project.

## 1.2 Mô hình xử lý

- App `Apelin` chạy `mobile`, chỉ là client.
- `apelind` LaunchDaemon chạy root, on-demand, là thin proxy.
- `apelind-session` (cùng executable, `--session`) giữ task registry/workers/approvals.
- Worker processes thực thi dài: Agent, Build, Environment, Diagnostics, LogReader.
- Giao tiếp protocol v2: closed operation list, XPC dictionary app↔daemon, `WorkerChannel` frame socketpair giữa host-worker.

## 1.3 Triết lý quan trọng

- Không command arbitrary execution từ app; chỉ `AppOperation` closed list.
- Determinism/environment: no hardcoded install prefix in app; daemon derives root từ `proc_pidpath`.
- `hello` là authority install root.
- roothide detect bằng process path, never libc `.jbroot`.
- Failures gracefully; daemon absent means retry, not error.
- build/release separates CI build vs release publish.
