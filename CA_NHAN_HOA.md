# Cá nhân hoá Apelin — quy tắc, quy trình build, nhật ký bản vá

Tài liệu này dành cho **bất kỳ ai** build lại bản Apelin cá nhân hoá của kho
`Datkep92/Apelin`. Đọc hết file là hiểu cấu trúc repo, biết cách build đúng,
và biết mình không được phá cái gì.

> **Quy tắc sống:** mục 6 — *Nhật ký cá nhân hoá & bản vá* — là sổ ghi chép
> sống. Mỗi lần thêm một cá nhân hoá mới hoặc một bản vá (fix), **bắt buộc**
> thêm một dòng vào đó (mục 6.3 ghi cách ghi), không xoá dòng cũ, không ghi đè.
> Ai build sau chỉ cần đối chiếu mục 6 để biết cái gì phải còn nguyên vẹn.

---

## 1. Bản build này là gì

- **Upstream** (gốc, nguồn mở): `owngoal-dev/Apelin`
- **Origin** (fork cá nhân, bản build thật): `Datkep92/Apelin`
- Base luôn là **upstream mới nhất**; cá nhân hoá luôn nằm ở commit riêng của
  fork, ở trên đỉnh base.
- Build bằng **GitHub Actions** (CI) trên kho fork — không cần Mac.
  - `.github/workflows/ci.yml` — chạy mỗi lần push vào `main`: test + đóng gói `.deb`.
  - `.github/workflows/release.yml` — chạy khi tạo tag `v...`, phát hành release.
  - `.github/workflows/sync-upstream.yml` — đồng bộ upstream (chạy thủ công).
- Máy đích hiện tại: iPhone10,6 · iOS 16.6 · bootstrap **rootless**
  → dùng gói **`iphoneos-arm64`** (arm64, **không** phải arm64e).

## 2. Cấu trúc repo

| Đường nơi | Vai trò |
| --- | --- |
| `Apelin/` | App chính (giao diện UIKit): sidebar dự án, chat, ô soạn thảo, cài đặt. `Application/LegacyHome.swift` là màn hình chính. |
| `Apelind/` | Daemon chạy nền với quyền cao: quản lý phiên hội thoại, gọi công cụ, chính sách cho phép (Ai được làm gì). |
| `Packages/ApelinAgent/` | "Bộ não" agent: prompt hệ thống, những gì đưa vào ngữ cảnh, danh sách công cụ, quy tắc hội thoại. |
| `Packages/...` | Các thư viện Swift dùng chung (giao thức app ↔ daemon, tính năng lõi). |
| `Extensions/` | Các công cụ mở rộng của agent (assembler, disassembler…) cài riêng. |
| `Workers/` | Tiến trình phụ chạy nền (agent worker, channel host…). |
| `Shared/`, `Widgets/` | Mã dùng chung; tiện ích màn hình chính. |
| `Configuration/` | Phiên bản (`Version.xcconfig`), cấu hình build. |
| `Scripts/` | Kiểm tra và đóng gói: `check-*.py`, `check-checklist.sh`, `package-deb.sh`… |
| `Packaging/` | Kế hoạch cài đặt gói `.deb`. |
| `Documents/` | Tài liệu: `Compatibility.md`, `Distribution.md`, trang web… |
| `Tests/` | Test của app/daemon. |
| `Makefile` | Lệnh build: `deb`, `check`, `set-version`, `harness`… (xem `make help`). |
| `CHECKLIST.md` | Danh mục kiểm tra bản phát hành; `make check` chạy mục này **đầu tiên**. |
| `AGENTS.md` | Quy tắc dành cho agent đọc repo này. |
| `apelin-project.json` | Mô tả để Apelin nhận biết và build được dự án (kiểu workspace). |

## 3. Quy tắc cá nhân hoá

1. **Base = upstream mới nhất.** Trước khi làm việc lâu, `git fetch upstream main`
   và merge vào `main`. **Không** fetch/push **tag** của upstream
   (tag `v...` sẽ làm `release.yml` của fork phát hành nhầm).
2. **Cá nhân hoá = commit riêng, dễ tách.** Một ý một commit, tiêu đề nêu đúng
   hành động (kiểu "Keep several configurations of one provider…"). Không trộn
   việc cá nhân hoá vào commit merge.
3. **Không đổi định danh:** package id `wiki.qaq.apelin`, bundle id, `projectID`
   của folder — đổi một lần là thành gói/du án khác.
4. **Không tự làm `.deb` bằng tay** (dpkg-deb/ar/tar ngoài CI): gói phải đi ra
   từ CI để qua được mọi bước kiểm tra.
5. **Không force push**, không đổi URL remote để lách từ chối.
6. **Mọi thay đổi đều ghi vào mục 6.** Không có dòng tại mục 6 = chưa được coi
   là cá nhân hoá chính thức, có thể bị bản merge sau đẩy mất.
7. Khi resolve conflict lúc merge upstream: **giữ phần cá nhân hoá của fork**
   (đặc biệt `ModelProvidersController.swift`, `Localizable.xcstrings` —
   xem dòng "Conflicts resolved" trong commit `0428636` làm mẫu).

## 4. Quy trình build lại từ đầu

### 4.1 Đồng bộ base với upstream
```sh
cd <repo>                       # /var/mobile/Documents/wiki.qaq.apelin/Projects/Apelin
export TMPDIR=/tmp              # mọi lệnh gh trên máy này cần thế
git fetch upstream main
git merge upstream/main          # giữ nguyên commit ở mục 6; xem lại mục 3.7 khi có conflict
```

### 4.2 Build bằng CI
```sh
gh run list -R Datkep92/Apelin                 # 2 run song song, mỗi run ~20–27 phút
gh run watch <run id> -R Datkep92/Apelin       # có thể thoát sớm, poll bằng:
gh api "repos/Datkep92/Apelin/actions/runs/<run id>" --jq .status
```
Artifact có tên **`apelin-<full sha>`**.

### 4.3 Tải bản dựng về máy
```sh
TMPDIR=/tmp gh run download <run id> -R Datkep92/Apelin -n apelin-<sha> -D /tmp/apelin-art
sha256sum -c SHA256SUMS        # trong /tmp/apelin-art, nếu file này có
```
Chỉ giữ `.deb` **`iphoneos-arm64`**, copy vào `Downloads` làm lưu trữ.

### 4.4 Cài lên máy
```sh
# chạy bằng root (shell_run root:true) — nhà cài KHÔNG chạy maintainer script của gói
icli pkg install <đường dẫn .deb>
# sau khi cài xong, để app đọc binary mới:
icli app kill wiki.qaq.apelin --force
icli app launch wiki.qaq.apelin
```
- **Không bao giờ** để `postinst` chạy: nó sẽ `bootout apelind` và giết luôn phiên
  agent đang nói chuyện. Không restart `apelind` khi chưa có đồng ý của người dùng.

### 4.5 Kiểm tra sau build
```sh
python3 Scripts/check-accessibility.py Apelin
sh Scripts/check-checklist.sh CHECKLIST.md
python3 Scripts/check-stale-strings.py "Apelin Widgets"
python3 Scripts/check-format-strings.py "Apelin Widgets"
```
- `check-translations.py` **không bao giờ pass** trên máy này (thiếu `plutil` của
  macOS) — không coi là lỗi.
- Kiểm tra giao diện bằng accessibility tree (`icli ui tree|at|tap`) hoặc công cụ
  màn hình của Apelin. **`icli screen ocr` và `icli screen describe` hỏng** trên máy này.
- Xác nhận daemon đã đúng bản: trong app, so sánh phiên bản với bản vừa cài.

### 4.6 Phát hành (chỉ khi được yêu cầu)
```sh
make set-version VERSION=x.y.z-fork1    # nếu cần tách version với bản chính tắc
gh release create "v<version>-<sha>" <deb> --title "Apelin x.y.z fork1" --notes "..."
```
- Tag của **riêng fork**, không lấy tag của official.
- `release.yml` thấy tag `v...` sẽ tự phát hành.

## 5. Bẫy thường gặp trên máy này

**Push bằng lệnh** (công cụ push của Apelin không với được repo ngoài dự án):
```sh
TOK=$(gh auth token); B64=$(printf "x-access-token:%s" "$TOK" | base64 | tr -d "\n")
git -c "http.extraHeader=Authorization: Basic $B64" push origin main
```
- Mọi lệnh `gh` đều cần `TMPDIR=/tmp`, không thì gh hỏng.
- Shell mặc định là `dash`, không có `/bin/sh` cho git helper của gh → bọc `bash -c`.
- Không có `xcodebuild`/`xcrun`/`cmake`/`ninja` trên máy → CI là con đường build
  Swift duy nhất. Lệnh trong `Makefile` là lệnh macOS, thiếu `xcrun` thì dùng CI.
- Kho repo nằm ngoài root dự án hiện tại → công cụ file/git của Apelin không với
  tới; thao tác qua lệnh `shell_run`.

## 6. Nhật ký cá nhân hoá & bản vá

### 6.1 Bảng hiện có

| # | Ngày | Loại | Tóm tắt | Commit | Yêu cầu giữ lại khi build |
| --- | --- | --- | --- | --- | --- |
| 1 | 2026-10-29 | Cá nhân hoá | Một nhà cung cấp có **nhiều cấu hình**: mỗi cấu hình một khoá API riêng và dải model riêng; chọn model từ sheet cấu hình có tìm kiếm; giữ cấu hình đã đặt tên cho tới khi lưu khoá, xoá bằng cách vuốt. | `c186bec`, `de402d3`, `1709e94`, `0bd7d73`, `14ca882`, `1c49e95` | `ModelProvidersController.swift`, `EnabledModels.swift`, `AccountDesk.swift`, `SessionModelChoice.swift`, khoá catalog mới trong `Localizable.xcstrings` (qua được `check-catalog-keys.py`). |
| 2 | 2026-10-30 | Bản vá đồng bộ | Hấp thụ upstream `v0.1.8..v0.3.0` (152 commit) và thêm workflow `sync-upstream.yml`. | `0428636` (merge) | Base là upstream; giữ cấu hình model của dòng 1 khi resolve conflict. |
| 3 | 2026-10-31 | Bản vá (data-home) | Hai "home" tách nhau: home của container iOS vs home mobile thật → 0.3.0 ra mở app **danh sách dự án trống**. Sửa bằng `DataFolder` đi từ container sang home của mobile, import hộ file một lần. | `dfe14b9`, `ee4fc4a`, `ec2727a` (`AppDelegate.swift`, `LegacyHome.swift`, `ApelinService.swift`) | Bản build mới phải nhận đúng data home `~/Documents/wiki.qaq.apelin`; **không** đặt dữ liệu về lại container. |
| 5 | 2026-10-31 | Bản vá (bỏ xác minh model) | Provider **custom (OpenAI-compatible)** không còn bắt buộc xác minh model khi thêm: endpoint miễn phí/relay thường quảng cáo model nhưng từ chối completion (hết hạn mức `:free`), khiến Apelin chặn thêm model dù model dùng được. Provider chính thức (OpenRouter, Anthropic, Copilot…) vẫn xác minh như cũ. | `260a73d` | Giữ nhánh `request.provider == .openAICompatible` trong `activateModels` (`AccountDesk.swift`); không bật lại `verifyKey` cho custom provider. |
| 4 | 2026-10-31 | Bản vá (danh sách dự án) | Danh sách dự án hiển thị thiếu/lẫn; đã sửa và kiểm chứng trên máy: Home hiện đủ dự án, dự án không có `apelin-project.json` bị loại đúng. | nằm trong nhóm `dfe14b9..ec2727a` | Giữ nguyên; kiểm tra lại sau mỗi lần merge: Home và bộ chọn dự án phải cùng số dự án. |

| 6 | 2026-10-31 | Cá nhân hoá | Long-press menu on user message bubbles: copy the message into clipboard then delete it. | `f7b2f878804424d90b3f163276a3f4934bc1c1df` | Giữ nguyên `ChatMessageRow` long-press `bubble`, `ChatController.confirmAndDelete`, `ChatRuntime.deleteMessage` |
| 7 | 2026-11-01 | Cá nhân hoá | **Xoá nhà cung cấp mô hình** trong Settings ▸ Model Providers: cấu hình đã lưu có mục `Delete` trong menu `...` và vuốt để xoá (hỏi lại trước). Xoá khoá khỏi keychain qua `agentSignOut`, bỏ model đã bật của cấu hình và tên đang chờ, hàng biến mất. Hàng của chính nhà cung cấp vẫn chỉ có `Sign Out` vì apelin-agent luôn liệt kê nó. | `77adeec` | Giữ `delete`/`confirmDelete` trong `ModelProvidersController.swift` (không gộp vào `signOut`), và ba khoá catalog `Delete %@?`, câu xác nhận, `Unable to Delete` đủ 12 ngôn ngữ. |
| 8 | 2026-11-01 | Cá nhân hoá | Sắp xếp và thao tác provider/sidebar: Delete/Rename/C context menu cho các cấu hình waiting & Signed-in trong “API Keys”, sửa tên cấu hình (rename) qua re-sign in; sidebar top row: Settings bên trái trước tên dự án, project switcher, +(dự án mới), New Chat, bỏ thanh dưới. | `57d24f1c89c5788f989920d72fc78f30dc177558` | Giữ `accountActions`, `renameWaiting`/`renameSigned`, `promptForName`, `projectTitleButton`, navigation layout; key catalog đủ 12. |
| 9 | 2026-11-01 | Cá nhân hoá | Default keyboard Return để xuống dòng mới, gửi bằng nút Send icon. | `a6a5727e63244330a5f4dfded49dd8a9dce2847a` | `ComposerBehavior.useConfirmationOnSend` default true. |
### 6.2 Cách thêm dòng mới (bắt buộc làm khi thêm cá nhân hoá/fix)
1. Sửa code + commit riêng biệt (tiêu đề nêu rõ hành động, tiếng Anh).
2. Bổ sung **1 dòng** vào bảng 6.1: `Số | Ngày (YYYY-MM-DD) | Cá nhân hoá/Bản vá | Tóm tắt | Hash commit | Yêu cầu giữ lại`.
3. Commit thay đổi file `CA_NHAN_HOA.md` này trong cùng push.

### 6.3 Violation sẽ bị coi là phá bản cá nhân hoá
- Xoá/đổi dòng trong bảng 6.1 mà không có lý do được ghi lại.
- Merge upstream rồi resolve mất phần cá nhân hoá của dòng 1.
- Build `.deb` không qua CI, hoặc phát hành tag lấy từ official.

## 7. Bài học: mất bản repo trên máy (sự kiện 2026-10-31 06:16)

Sáng 31/10 06:16, folder `Projects/Apelin` cùng ~25 dự án khác và phần lớn file
chat biến mất khỏi máy (không vào thùng rác). Mã nguồn **không mất** vì đã push
lên GitHub. Khôi phục:
```sh
git clone https://github.com/Datkep92/Apelin.git \
  /var/mobile/Documents/wiki.qaq.apelin/Projects/Apelin
git remote add upstream https://github.com/owngoal-dev/Apelin.git
```
Nguồn sao lưu phụ trên máy (bản cũ hơn 30/10 22:51–22:53):
- `/var/mobile/Library/Filza/.Trash/wiki.qaq.apelin/Projects/Apelin`
- `/var/mobile/Library/Filza/.Trash/wiki.qaq.30-thg 10-2026-22-53-45.apelin/Projects/Apelin`
- container iOS cũ `.../Containers/Data/Application/EA842577-.../Documents/wiki.qaq.apelin/`

**Quy tắc rút ra:** commit + push ngay sau mỗi thay đổi; bản `.deb` quan trọng
lưu vào `Downloads`; đừng để repo chỉ tồn tại một nơi.
