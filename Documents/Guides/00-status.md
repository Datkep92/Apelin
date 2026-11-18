# 00 Project Status Log

> Log làm việc để người tiếp theo biết “đang ở đâu”. Cập nhật mỗi buổi làm việc.

## Last update
- Date: 2026-11-14 (UTC+07)
- Branch: `main`
- HEAD: `3556a6dc04a2d44a5e7c58d1b34369578a20688e` (0.4.71 / build 94; `origin/main` cùng HEAD)
- State: 0.4.71 đã phát hành và cài thành công; gói rootless khớp `SHA256SUMS`, Apelin 0.4.71 đang chạy trên thiết bị.

## Current active task
- Bản sửa `DataFolder` cho 0.4.71/build 94 đã hoàn tất: commit `3556a6dc04a2d44a5e7c58d1b34369578a20688e` đã push.
- CI run `43619811239` thành công: Host tests và Build and verify Debian packages đều đạt. Artifact 132 MB, SHA-256 `f698034982c188361b23c16598685197de08f372d71b92bf3facb29a561a4481`.
- Release run `43622935044` thành công cho tag `v0.4.71`; gói rootless `iphoneos-arm64` khớp `SHA256SUMS`, cài nâng cấp từ 0.4.59 lên 0.4.71 thành công. Mở lại app và `icli app running` xác nhận Apelin 0.4.71 đang chạy; app build 236 (khác build gói 94).
- Kiểm tra độc lập trước push đạt: accessibility (19 kiểu), checklist (51 mục), `git diff --check`, stale/format strings, shell-delete, session-host source, device-harness lint và GPU entitlements.
- Giới hạn môi trường của các kiểm tra trước push: `make check` không chạy được vì thiếu `/bin/bash`; schema/template cần `/private/tmp`; kiểm tra dịch bị `plutil` trên thiết bị từ chối.
- Hai handoff retry provenance và app thử WKWebView vẫn là việc riêng, chưa gộp vào bản phát hành này.

## Next likely step
- Tiếp tục các mục kiểm bằng mắt còn thiếu và hai handoff riêng (retry provenance, app thử WKWebView); xem `CA_NHAN_HOA.md` §9 và handoff tương ứng.

## History index
- Personalization registry: `../../CA_NHAN_HOA.md` §6.
- Project docs: `README.md`.
- Architecture: `../../ARCHITECTURE.md`.
