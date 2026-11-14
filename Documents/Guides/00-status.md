# 00 Project Status Log

> Log làm việc để người tiếp theo biết “đang ở đâu”. Cập nhật mỗi buổi làm việc.

## Last update
- Date: 2026-11-14 (UTC+07)
- Branch: `main`
- HEAD: `e601eeb` (0.4.70 / build 93; origin/main cũng ở commit này)
- State: bản vá thêm `import ApelinCore` để sửa lỗi CI `DataFolder`; phiên bản đã bump lên 0.4.71/build 94, ghi chú phát hành đã chuẩn hoá; Sếp đã yêu cầu đẩy CI, đang chạy kiểm tra trước commit/push.

## Current active task
- Khắc phục lỗi biên dịch CI: `WebAPICaptureStore.swift:52` không tìm thấy `DataFolder`.
- Affected: `Apelin/Interface/Components/WebBrowser/WebAPICaptureStore.swift` (một dòng import), `Configuration/Version.xcconfig`, `Documents/Releases/0.4.71.md`, `CA_NHAN_HOA.md`.
- Evidence: `DataFolder` thuộc `ApelinCore`; HEAD `e601eeb` thiếu import này. Phiên bản đích: 0.4.71/build 94.
- Checks: accessibility (19 kiểu), checklist (51 mục), `git diff --check`, chuỗi stale/format, shell-delete, session-host source và device-harness lint đều đạt khi chạy độc lập. `make check` không chạy được vì thiếu `/bin/bash`; schema/template cần `/private/tmp`, kiểm tra dịch bị `plutil` của thiết bị từ chối.
- Blocker: `make check` đầy đủ chưa chạy được; chưa commit/push, chưa có CI mới và chưa xác nhận build.

## Next likely step
1. Chạy các kiểm tra sau cập nhật, gồm `make check`, accessibility, checklist và `git diff --check`.
2. Nếu đạt, commit các thay đổi thuộc bản sửa rồi push `main` (không force-push).
3. Theo dõi CI; nếu đỏ, đọc đầy đủ log job lỗi rồi sửa đúng nguyên nhân.
4. Cập nhật §6.1/§9, status log và handoff theo kết quả thực tế.

## History index
- Personalization registry: `../../CA_NHAN_HOA.md` §6.
- Project docs: `README.md`.
- Architecture: `../../ARCHITECTURE.md`.
