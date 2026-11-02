# 00 Project Status Log

> Log làm việc để người tiếp theo biết “đang ở đâu”. Cập nhật mỗi buổi làm việc.

## Last update
- Date: 2026-11-02 (UTC+07)
- Branch: `main`
- HEAD: `b0769a3` (green completion dot)
- State: added green completion dot for finished chat sessions; not device-tested yet.

## Current active task
- Cá nhân hoá: chấm xanh khi phiên chat chạy xong; mở/xem phiên chat sẽ mất chấm.
- Affected: `ChatSummary.swift`, `ChatUnread.swift`, `ChatRuntime.swift`, `SidebarController.swift`.
- Commit: `b0769a3`.
- Blocker/tests: chưa build Swift (không có toolchain on-device); cần CI build và kiểm tra trên thiết bị.

## Next likely step
1. Chọn tính năng/fix tiếp theo.
2. Kiểm tra `git status` sạch.
3. Sửa → chạy `make check`/`make harness` hoặc test phù hợp.
4. Commit + push nếu là docs/fork convention (full mode).
5. Cập nhật `CA_NHAN_HOA.md` nếu là cá nhân hoá/fix.

## History index
- Personalization registry: `../../CA_NHAN_HOA.md` §6.
- Project docs: `README.md`.
- Architecture: `../../ARCHITECTURE.md`.
