# Quy trình build bản cá nhân hoá (GitHub Actions)

Áp dụng cho kho `Datkep92/Apelin` (fork cá nhân). Build luôn qua GitHub Actions, không build Swift trên máy.

## 1. Trước khi build
1. Kiểm tra `git status` sạch, không có thay đổi chưa commit.
2. Kiểm tra `main` và các commit mới nhất trên remote:
   - `git fetch origin main`
   - So sánh HEAD local với `origin/main`; nếu lệch, pull/merge trước.
   - Chạy `make check` / `Scripts/check-checklist.sh` nếu có thay đổi code.
3. Ghi lại commit SHA sẽ build (để đối chiếu artifact).

## 2. Build bằng GitHub Actions
1. Push commit lên `main` (không force push).
2. Theo dõi run CI:
   - `TMPDIR=/tmp gh run list -R Datkep92/Apelin`
   - `TMPDIR=/tmp gh run watch <run-id> -R Datkep92/Apelin`
3. Chờ cả 2 job:
   - Host tests
   - Build and verify Debian packages

## 3. Nếu build thành công
1. Xác nhận run status = success và artifact `apelin-<full sha>` đã tạo.
2. Tải artifact về máy:
   - `TMPDIR=/tmp gh run download <run-id> -R Datkep92/Apelin -n apelin-<sha> -D /tmp/apelin-art`
3. Chỉ giữ file `.deb` rootless cho máy này: `wiki.qaq.apelin_<version>_iphoneos-arm64.deb`.
4. Copy vào `~/Downloads/` để lưu trữ.
5. Kiểm tra SHA256 (đối chiếu với artifact).
6. Cài đặt bản deb mới:
   - Chạy root: `icli pkg install /var/mobile/Downloads/<file>.deb`
   - Đảm bảo `scripts_not_run` gồm postinst/postrm/prerm (không chạy maintainer script).
7. Đóng app cũ và mở lại:
   - `icli app kill wiki.qaq.apelin --force`
   - `icli app launch wiki.qaq.apelin`
8. Không restart `apelind` nếu chưa có đồng ý (tránh ngắt phiên).

## 4. Nếu build thất bại
1. Xem toàn bộ log lỗi của run (job Host tests và Build and verify Debian packages).
2. Xác định nguyên nhân gốc (compile, catalog keys, make check, v.v.).
3. Sửa code và kiểm tra toàn bộ:
   - `make check` / `Scripts/check-checklist.sh`
   - `Scripts/check-accessibility.py Apelin`
   - `Scripts/check-stale-strings.py "Apelin Widgets"`
   - `Scripts/check-format-strings.py "Apelin Widgets"` (nếu có)
4. Commit riêng biệt với tiêu đề rõ ràng, push lên `main`.
5. Lặp lại quy trình từ bước 2.

## 5. Ghi chú
- `check-translations.py` không pass trên máy này do thiếu `plutil` macOS — không coi là lỗi.
- Không tự tạo `.deb` bằng tay (dpkg-deb/ar/tar) ngoài CI.
- Không force push, không đổi URL remote.
- Mọi thay đổi cá nhân hoá/fix phải ghi vào `CA_NHAN_HOA.md` mục 6.
