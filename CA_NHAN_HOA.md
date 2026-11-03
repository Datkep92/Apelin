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
| 10 | 2026-11-01 | Cá nhân hoá | Subtitle trong menu dự án: hiển thị hội thoại mới nhất của mỗi dự án để dễ nhận biết đang làm việc ở đâu. | `e2305d3` | Giữ `projectActiveChatTitle(for:)` và subtitle `UIAction` trong `SidebarController` (`switchAction`, `general`). |
| 11 | 2026-11-01 | Phát hành | Xoá release cũ 0.3.3 và 0.3.4, set version về 0.3.3, phát hành v0.3.3 theo release workflow; CI pass và release run success. | tag `v0.3.3` tại `e2305d3` | Chỉ giữ phát hành 0.3.3; không dùng package/tag unofficial. |
| 12 | 2026-11-01 | Bản vá (DeepSeek reasoning_content) | DeepSeek/OpenAI-compatible agent requests no longer fail “requires reasoning_content for every earlier assistant message”: `AgentSession` now normalizes prior assistant turns at the stream boundary by adding a sentinel thinking block/signature before KWWKAI streaming. | d347e8d | Giữ `AgentSession.normalizeReasoningContext(for:in:)` và wrapper `NetworkRecovery.stream(..., inner: ...)` trong `Packages/ApelinAgent/Sources/ApelinAgent/Session/AgentSession.swift`. |
| 13 | 2026-11-01 | Bản vá (reasoning_content sentinel) | Sentinel thinking text changed from a single space to `r` so it survives kwwk's whitespace-trimming thinking-block filter; normalization now runs for **every** OpenAI-compatible turn (not only DeepSeek/compat-flag models), so relays serving DeepSeek-style endpoints under unrelated names (e.g. `beam`) also get `reasoning_content` on all earlier assistant messages. |  | Giữ thay đổi trong `AgentSession.normalizeReasoningContext(for:in:)`. |
| 14 | 2026-11-02 | Cá nhân hoá | Sửa bảng gợi ý slash command trong composer có thể tap được; thêm màn Settings ▸ Commands để thêm/sửa/xoá file lệnh Markdown. | `7433bc6` | Giữ override hitTest/point(inside) trong `ComposerView`, `CommandsController`, `CommandEditorController`, và các key catalog mới. |
| 15 | 2026-11-02 | Cá nhân hoá | Vuốt trái ở vùng trống sidebar hoặc tên dự án dưới cùng mở danh sách dự án; giữ nguyên swipe ghim/xóa trên hàng hội thoại. | `bca91d1` | Giữ gesture UISwipeGestureRecognizer và backgroundView trong `SidebarController`. |
| 16 | 2026-11-02 | Bản vá | Chọn model trong phiên chat cập nhật tên model ngay lần đầu thay vì phải chọn lại. | `f500fa0` | Sắp xếp lại `pick(...)` và gọi `updateModelSelection()` trong `ChatController.showModelPicker`. |
| 17 | 2026-11-02 | Cá nhân hoá | Khi phiên chat chạy xong, hàng sidebar hiển thị chấm xanh; mở/xem phiên chat sẽ mất chấm xanh xác nhận đã xem. |  | Giữ `isCompleted` trong `ChatSummary`, logic trong `ChatRuntime`, và chấm xanh trong `SidebarController`. |
| 18 | 2026-11-02 | Cá nhân hoá | Cho **mọi** nhà cung cấp mô hình hỗ trợ nhiều cấu hình (nhiều khoá API/endpoint): mở rộng `AgentProfileID` trong `ApelinKit` cho toàn bộ `AgentProvider` (store id khớp `AgentProvider.storeID`); trước đây chỉ Anthropic và OpenAI-compatible. | 4052a56 | Giữ mapping store id trong `AgentProfileID` (`canonicalID`/`make`/`kind`/`pairs`) khớp `SignInProviders.storeID`; không xoá. |
| 19 | 2026-11-02 | Bản vá | Cloudflare token không có quyền `user/tokens/verify`: bỏ gọi verify, kiểm tra token bằng `listAccounts`. | 548a713 | Bỏ `_ = try await client.validateToken()` trong `ServicesSettingsController.validateCloudflareToken`; giữ `listAccounts()`. |
| 20 | 2026-11-02 | Cá nhân hoá | Gộp danh sách model trong `ChatModelPicker`: khi tìm kiếm, tên model đã được cấu hình trước không lặp lại ở cấu hình sau (một hàng cho mỗi tên model, khoá thêm trước phục vụ). | b823c05 | Giữ `seenModels` trong `regroup()` của `ChatModelPicker.swift`. |
| 21 | 2026-11-03 | Bản vá | Nút `+` trong Model Providers chỉ hiển thị Anthropic và OpenAI-compatible (các nhà cung cấp typed-key) thay vì mọi provider. | d3ef76d | Giữ `AgentProfileID.canonicalID(for:)` chỉ trả store id cho `.anthropic` và `.openAICompatible`. |
| 22 | 2026-11-03 | Cá nhân hoá | Gộp cấu hình trong bộ chọn model theo nhà cung cấp: một nhà cung cấp nhiều khoá hiển thị một hàng; mở ra thấy danh sách model gộp, khử trùng. | a9f0e6c | Giữ grouping trong `ChatModelPickerController`/`ChatModelListController`. |
| 23 | 2026-11-03 | Cá nhân hoá | Gộp provider cùng thương hiệu trong bộ chọn model: Qoder/Qoder CN, WorkBuddy/WorkBuddy AI, Z.ai/BigModel hiển thị một hàng theo family (`modelFamily`), giữ nguyên case enum wire-stable. |  | Giữ `AgentProvider.modelFamily` và grouping theo family trong `ChatModelPickerController`. |
| 24 | 2026-11-03 | Bản vá | Phát hiện 429/rate-limit trong follow() của ChatRuntime: đánh dấu hội thoại `rateLimitedChats` để UI retry với model tiếp theo. |  | (Cập nhật 2026-11-03 — lý do ghi ở dòng 31) Đã thay bằng cơ chế retry thật ở dòng 28–30; `rateLimitedChats`, `isRateLimited(_:)`, `clearRateLimit(_:)` xoá vì không nơi nào dùng. |
| 25 | 2026-11-03 | Bản vá | Khi mở phiên chat cũ, tự cuộn xuống cuối: cho phép lượt layout ban đầu chạy sau khi hoán đổi hội thoại (tắt `isSwitchingChat` trước `setNeedsLayout`). |  | Giữ thay đổi trong `ChatController.use(_:)`. |
| 26 | 2026-11-03 | Bản vá | Khởi động không tự mở HTML playground từ file cũ: baseline `lastHTMLFileModification` khi bắt đầu theo dõi file. |  | Giữ thay đổi trong `ChatController.startHTMLFileWatch()`. |
| 27 | 2026-11-03 | Cá nhân hoá | Di chuyển nút danh sách dự án từ thanh trên xuống footer sidebar (tái dùng projectMenuButton), mở danh sách dự án bằng push từ phải thay vì modal sheet. | `07374c8` | Giữ projectMenuButton trong footer, openProjectPicker dùng pushViewController, ProjectPickerController pop về sidebar. |
| 28 | 2026-11-03 | Cá nhân hoá | **Auto-retry khi hết hạn mức**: model trả lỗi 429/hết quota thì Apelin tự gửi lại **đúng tin nhắn vừa rồi** bằng model kế tiếp trong `ModelCandidates.fallbackList` (cùng provider cấu hình khác → cùng provider model khác → provider khác cùng model → còn lại), tối đa **3 lần tự động**; trạng thái lưu trong `ChatRecord.rateLimitRetry` (Codable, persist) nên mở lại app vẫn biết còn model nào. Lượt sau trả lời được thì tự xoá; gửi tin mới cũng xoá. | `bdbdd4b` | Giữ `ChatRecord.rateLimitRetry`, `ChatRuntime.answerSpentAllowance/sendNextModel/settleSpentAllowance` và thứ tự trong `ModelCandidates.fallbackList`. |
| 29 | 2026-11-03 | Cá nhân hoá | **Nút Retry** trên thanh model (màu cam, cạnh Stop): hiện khi còn model để thử và lượt đang không chạy; tap là gửi lại bằng model kế tiếp ngay, **không** bị giới hạn 3 lần (người đọc chủ động). Ô soạn thảo không bị đụng tới. Chỉ dùng khoá catalog có sẵn "Retry" — không thêm khoá mới. | `bdbdd4b` | Giữ `ComposerModelBar.retryButton/setRetry(_:)`, `onRetry` trong `ChatController`, và khoá "Retry" trong catalogue. |
| 30 | 2026-11-03 | Cá nhân hoá | Nhận diện hết hạn mức gom vào một chỗ: `Apelin/Interface/Chats/RateLimitRetry.swift` (`RateLimitSignal`: 429/rate limit/quota…) + `RateLimitRetryPolicy` (3 lần tự động), kèm test harness `Tests/RateLimitRetry` chạy trong `make harness`. | `bdbdd4b` | Giữ `RateLimitSignal`/`RateLimitRetryPolicy`, `Tests/RateLimitRetry` và bước `rate-limit-retry` trong Makefile. |
| 31 | 2026-11-03 | Sửa dòng cũ | Dòng 24 ghi "giữ `isRateLimited(_:)`/`clearRateLimit(_:)`" — hai hàm đó **không nơi nào dùng** và đã bị thay bằng cơ chế ở dòng 28–30 (`rateLimitedChats`, `isRateLimited`, `clearRateLimit` đã xoá). Sửa lại dòng 24 cho khớp thực tế, lý do ghi ở đây theo mục 6.3. | `bdbdd4b` | Không tìm lại `rateLimitedChats`; việc chống hết hạn mức nằm ở `ChatRecord.rateLimitRetry` + `ChatRuntime`. |
| 32 | 2026-11-03 | Bản vá | **Sửa 4 lỗi của cơ chế auto-retry (dòng 28–30) + nút Retry:** (1) nút Retry có khung trong `ComposerModelBar.layoutSubviews` nên bấm được; (2) lỗi 429 đến khi lượt vẫn chạy thì chờ lượt kết thúc rồi mới gửi model kế (`RateLimitRetryState.awaitingTurn` + móc trong `ChatRuntime.follow`) — trước đó đổi model giữa lượt nên host bỏ qua; (3) gửi lại đúng tin mà lỗi trả lời, đọc từ event (kèm tệp đính kèm) chứ không dùng chuỗi text cũ, và chỉ lấy tin trước lỗi để không gửi trùng tin còn trong hàng đợi; (4) gửi lại thất bại thì trả model và lượt thử về như cũ. | `a4277bd` | Giữ `RateLimitRetryPolicy.step` (`.send`/`.wait`/`.leaveIt`), `awaitingTurn` trong `RateLimitRetryState`, `retryDraft`/`hasContent` trong `ChatRuntime`, và `retryButton` trong vòng layout của `ComposerModelBar`. |
| 33 | 2026-11-03 | Bản vá | **Sửa tiếp 4 lỗi của cơ chế auto-retry + nút Retry (dòng 28–32):** (1) nút Retry đọc `chat.sending`, trường mà `ChatSummary` không có — dòng đó **không biên dịch được**, CI sẽ đỏ; nay đọc `runtime.records[chat.id]?.sending` và ẩn nút khi còn tin của người đọc đang trên đường; (2) hai lỗi của cùng một lượt đọc ở hai gói tin cùng chạy `answerSpentAllowance` nên tra model và ghi trạng thái hai lần — cái chậm hơn trả lại model + lượt thử mà cái nhanh đã tiêu, nay chỉ một lời giải tại một thời điểm (`answeringSpentAllowance`); (3) `sendNextModel` không gửi khi còn tin trong `sending` nên không gửi trùng một prompt host đã nhận; (4) retry đổi model mà thanh model vẫn ghi model cũ — `refreshRuntime` so với `shownModel` rồi vẽ lại qua `barSelection`. | `58cd840` | Giữ `answeringSpentAllowance` (Set) trong `ChatRuntime`, hai guard `sending` (một ở `follow`, một ở `sendNextModel`), `shownModel`/`barSelection`/`updateModelSelection` trong `ChatController`. |
| 34 | 2026-11-03 | Cá nhân hoá | **Vuốt theo cạnh cho hai ngăn kéo + gỡ sheet xếp chồng của Settings ▸ Services (chỉ sửa giao diện, không động vào logic chat/model):** (1) trước đây chỉ có nút ☰ mở danh sách phiên — nay vuốt từ cạnh trái ra mở ngăn kéo, vuốt ngược lại để đóng, và vuốt từ cạnh trái khi ngăn kéo **đang mở** thì vào thẳng Settings (trước đây vuốt cạnh trái chỉ mở ngăn kéo); (2) trong chat, vuốt từ cạnh phải mở danh sách dự án (kèm nút **Dự án mới**, tiêu đề “Projects”), phần chat bị đẩy sang trái và vẫn còn một dải bên trái, chọn một dòng thì tự đóng, vuốt phải để đóng; (3) bấm ra vùng nền mờ (shade) đóng ngăn đang mở — nay dùng chung cho cả hai ngăn và mỗi ngăn đóng về đúng phía nó mở ra; (4) Settings ▸ Services trước đây mở thêm một sheet (bộ chọn dự án) **trên** chính sheet Settings, che mất trang vừa mở — nay đẩy bộ chọn vào chính chồng màn hình của sheet đó, chọn xong thì thay chỗ bằng trang Services, không còn lớp chồng. | `8697abf` | Giữ `RootInterfaceController.projectsEdgePan` + `projectsProgress` + `setProjectsOpen(_:velocity:)` + `closeOpenDrawer()`, `SidebarController.isInDrawer` + `openSettingsByEdgePan` (delegate chỉ cho ngăn kéo), `ProjectPickerController.mark(_:)`/`reloadNow()` (đổi dòng đang chọn không nạp lại cả bảng), và cách Settings ▸ Services `pushViewController` rồi `setViewControllers` thay vì `present` lồng nhau. |

| 35 | 2026-11-03 | Cá nhân hoá | **Tự thử lại không chỉ khi hết hạn mức mà cả khi khoá bị từ chối:** trước đây chỉ hiểu lỗi 429/hết quota; nay lỗi “khoá bị từ chối” cũng vào cùng luồng — gửi lại đúng tin nhắn vừa rồi bằng **cấu hình/khoá khác của cùng nhà cung cấp trước** (`ModelCandidates.fallbackList`), rồi mới sang model khác. Cơ chế đổi tên cho đúng việc: `RateLimitRetryPolicy` → `ModelRetryPolicy` (file `Apelin/Interface/Chats/RateLimitRetry.swift` giữ nguyên tên), trạng thái lưu ở `ChatRecord.retryState` (bản cũ ghi `rateLimitRetry` đọc lên bị bỏ, dữ liệu khác không đổi). | `633f988` | Giữ `ModelRetryPolicy.step` (`.send`/`.wait`/`.leaveIt`) + `maximumRetries = 3`, `ModelRetrySignal` (nhận cả lỗi khoá), `retryState` trong `ChatRecord`, và thứ tự `ModelCandidates.fallbackList` (cùng nhà cung cấp khác cấu hình → cùng nhà cung cấp khác model → nhà cung cấp khác cùng model). |
| 36 | 2026-11-03 | Cá nhân hoá | **Gộp khoá theo Base URL + dùng chung danh sách model (việc #1–#5 của màn nhà cung cấp):** (1) Settings ▸ Model Providers nay mỗi Base URL một mục — mọi khoá trỏ tới cùng một địa chỉ nằm chung dưới tên địa chỉ đó (mục này đứng trên các nhóm “đã đăng nhập / tài khoản / khoá” cũ); một địa chỉ mà hai nhà cung cấp cùng trỏ tới thì tiêu đề ghi thêm tên nhà cung cấp vì khoá và model không dùng chung được; (2) một Base URL giữ được nhiều khoá: mỗi khoá là một cấu hình như cũ; (3) danh sách model bật/tắt nay lưu theo **địa chỉ** chứ không theo từng khoá (`EnabledModels.identity(for:)` = nhà cung cấp + host), nên khoá thứ hai thêm vào cùng địa chỉ thấy sẵn danh sách model mà khoá đầu đã chọn; bản lưu theo từng khoá của bản cũ vẫn đọc được một lần rồi được thay; xoá một khoá **không** xoá danh sách của địa chỉ (khoá khác còn trỏ tới); (4) màn chọn model `ModelActivationController` lấy đúng danh sách theo cấu hình/khoá đang mở (đã đúng từ trước nhờ nạp model theo từng cấu hình — chỉ đổi nơi lưu); (5) lưu khoá **không còn kiểm tra model**: với khoá OpenAI-compatible và khoá API Anthropic, bấm Lưu ghi thẳng danh sách đã chọn (bỏ luôn mục “Save Without Verification” vì không còn gì để bỏ kiểm tra) — catalog của họ và thứ endpoint thật sự trả về vênh nhau quá thường (bản miễn phí, relay, khoá chỉ mở vài model). Nhánh kiểm tra trong apelin-agent vẫn giữ nguyên, chỉ app không gọi nữa; các nhà cung cấp khác vẫn kiểm tra như cũ. | `ac791f5` | Giữ `ModelProvidersController.Endpoint` (provider + host) + `Section.endpoint` + `endpoint(of:)`/`endpointTitle(_:)` (gom mục theo Base URL, tiêu đề thêm tên nhà cung cấp khi trùng host), `EnabledModels.identity(for:)`/`read(_:_:)` (đọc theo địa chỉ → cấu hình → tên nhà cung cấp cũ, ghi theo địa chỉ và xoá bản sao theo khoá), `EnabledModels.remove(for:)` (giữ lại danh sách của địa chỉ), và `ModelActivationController.probesModels` (nơi quyết định nhà cung cấp nào kiểm tra model khi lưu). |
| 37 | 2026-11-03 | Bản vá | **Ảnh của tin nhắn được chuẩn bị theo đúng endpoint + đo cache thật của nhà cung cấp (nhóm 1 và 4 của đơn hàng “ổn định cho AI, tiết kiệm token”):** (1) ảnh đính kèm trước đây gửi nguyên si, to hay nặng hay định dạng nào cũng gửi — nay `MessageImage`/`MessageImagePreparation` chuẩn bị trước: PNG/JPEG đã trong giới hạn thì giữ đúng byte của người dùng, còn lại (HEIC, WebP, TIFF, BMP, ảnh động, hoặc quá giới hạn) thì thu nhỏ và mã hoá lại qua `FileImage.read` (nay nhận giới hạn của người gọi) — ảnh gốc trong workspace **không** bị sửa hay xoá, chỉ bản sao trong bộ nhớ đổi; Anthropic 1568 px một cạnh, endpoint OpenAI-compatible/Copilot 2048 px; (2) `PreparedImageStore` giữ bản đã chuẩn bị theo (byte gốc + giới hạn), nên đổi model giữa hội thoại thì ảnh được chuẩn bị lại cho endpoint mới, còn gửi lại tin (lượt lỗi được thử lại) dùng lại đúng bản cũ **từng byte** — thứ mà khoá cache của nhà cung cấp dựa vào; (3) đo cache thật thay vì đoán: event `usage` {input, output, cacheRead, cacheWrite} đi từ `AgentSession.recordUsage` → `AgentWorker` → app, và dòng tóm tắt lượt đọc “Thought for 3 seconds · 82% cached” (khoá `%@ cached` đã dịch đủ 12 ngôn ngữ trong `Localizable.xcstrings`). | `9c55a9ef` | Giữ `MessageImage`, `MessageImageLimits.for(api:)` (1568/2048), `MessageImagePreparation`, `PreparedImageStore` (16 MB và 8 ảnh), `FileImage.read(_:frame:name:sideLimit:bytesLimit:)`, event `usage` cùng `AgentSession.recordUsage`, `ChatMessage.cacheNote` + `ChatTranscript.cacheNote` và khoá `%@ cached`. |
| 38 | 2026-11-03 | Cá nhân hoá | **Thêm `code_run`: AI tự viết chương trình rồi chạy (đơn hàng “IDE AI đa ngôn ngữ”):** trước đây AI chỉ chạy được lệnh qua `shell_run` (argv hoặc văn bản shell) — nay có thêm `code_run`: AI gửi `source` là chương trình nó tự viết kèm `interpreter` (sh, bash, zsh, python3, perl, node), chạy bằng quyền người dùng thường ngay trong thư mục dự án; mặc định `python3`, mã nguồn tối đa 256 KB, thời gian 1–1800 giây (mặc định 120). `code_run` **không bao giờ chạy root** và không nhận argv/command/script (việc đó là của `shell_run`), luôn chạy mobile kể cả ở chế độ Full; lời gọi xin root bị từ chối kèm lời chỉ sang `shell_run`. Bảng interpreter là **một bảng dùng chung** (`RunCodeSpec`) cho cả mô tả công cụ, phần kiểm tra phía agent và phần tra cứu phía host, nên tên nào được chào thì tên đó chạy được. Ở chế độ Confirm mỗi chương trình hỏi một lần, không có preset và không có “cho cả phiên”; thẻ duyệt hiện mã nguồn dưới mục Command (đúng một chương trình, đúng bản được duyệt). Phía host: `AgentRunCode` nay đọc bảng chung và từ chối root với interpreter của `code_run`; duyệt lại một thẻ cũ chấp nhận cả hai công cụ chạy (`AgentToolName.runCodeTools`), và `AgentScreenRules` nhận thẻ Ask-Before-Screen của cả hai. | `1151feff` | Giữ `RunCodeSpec.interpreters`/`interpreterNames`/`defaultInterpreter` (python3)/`maximumSourceBytes` (256 KB)/`timeoutRange` (1...1800), `RunCodeInterpreter`, `AgentToolName.codeRun` + `runCodeTools`, `CommandClassifier.classifyCode` (từ chối argv/command/script, source+code cùng lúc, chỉ khoảng trắng, NUL, quá 256 KB, interpreter lạ, root), `AgentRunCode` dùng bảng chung + chặn root theo interpreter, và khoá `Run code` trong `Localizable.xcstrings`. |
| 39 | 2026-11-03 | Cá nhân hoá | **Ghi đè file thì giữ bản cũ, và hoàn tác được (mục 5 của đơn hàng “IDE AI đa ngôn ngữ”):** trước đây AI sửa/xoá nội dung một file là mất bản cũ, sai thì không lấy lại được — nay mỗi lần `file_write` hay `file_edit` thay nội dung, bản **trước khi đổi** được chép ra một thư mục riêng ngoài dự án (`<dữ liệu Apelin>/backups/<tên dự án>/`, không bao giờ nằm trong repo của người dùng), tối đa 60 bản trên toàn dự án và mỗi file tối đa 8 MB; cùng nội dung thì không chép trùng. AI có thêm hai công cụ: `file_backups` liệt kê các bản đã giữ của một file (mới nhất trước, kèm giờ và số byte), `file_revert` khôi phục một bản — chỉ định tên, hoặc để trống thì lấy bản mới nhất; chính lần khôi phục cũng giữ lại nội dung đang có nên hoàn tác lại được (quay lại được cả hai chiều). Tên bản đến từ tham số công cụ nên chỉ nhận đúng dạng tên do thư mục đặt (số giờ + 2 mã băm + tên file), không có dấu `/` nên không thể trỏ ra ngoài thư mục; khôi phục file không tồn tại hay file chưa từng có bản thì bị từ chối. Kèm skill `apelin-device-languages` nói rõ máy này chạy được ngôn ngữ nào (python3, perl, make, git, ldid, dpkg-deb có sẵn; không có cmake, ninja, xcrun, node, `/bin/sh`; chưa cài toolchain thì chưa có clang) để AI tự dựng bài kiểm tra từng ngôn ngữ rồi sửa, và **không tự cài** gì khi chưa được cho phép. | `438cd07a` | Giữ `FileBackups` (`limit` 60, `maxBytes` 8 MB, `save`/`copies(of:)`/`newest(of:)`/`find(named:)`/`load`/`prune`, `parts`/`date`/`hash`), `keepBackup` trong `ProjectFileTools.writeFile`/`patchFile`/`revertFile`, `ProjectFileTools.backups` (nil thì không giữ bản nào), hai công cụ `file_backups` (chỉ đọc) / `file_revert` (quyền ghi dự án, hỏi như `file_write`), khoá `Restore a file` / `List saved copies` đủ 12 ngôn ngữ, và test `FileBackupTests`. |

| 40 | 2026-11-03 | Cá nhân hoá | **AI bấm được nhiều kiểu hơn trên màn hình máy (điểm 2 của đơn “tự lái iPhone”):** trước đây `apelin_screen_interact` chỉ có chạm, vuốt hai điểm và ba nút cứng — nên menu giữ-để-hiện, thanh trượt, chọn một chữ và màn chỉ dùng bàn phím thì AI không làm gì được. Nay thêm năm kiểu: `double_tap` (hai lần chạm cách nhau `interval_ms`, một cử chỉ chứ không phải hai lần chạm rời), `long_press` (giữ `duration_ms`, mặc định 700 ms — cái mở menu ngữ cảnh), `drag` (đường đi `points` từ 2 đến 1000 cặp `[x, y]`: nhấn ở điểm đầu, đi qua các điểm còn lại rồi nhả, `hold_ms` là quãng nghỉ trước khi đi, `duration_ms` là thời gian đi), `press_key` (một phím bàn phím ảo không có: `return`, `escape`, `command+a`; phím tắt đứng trước, tên phím đứng cuối) và `open_url` (chỉ `http`/`https`, phải có host). Mọi giới hạn lấy đúng theo icli (double tap tối đa 1 giây, cử chỉ tối đa 60 giây, mỗi toạ độ phải là số thực), nên thứ AI gửi được thì icli nhận được; `key` đi nguyên chữ người gửi viết vì icli tự đổi chữ thường, còn mili-giây đổi sang giây ở phía máy chủ. Câu trên thẻ duyệt gọi tên từng kiểu, và `press_key`/`open_url` không ghi “trong app đang mở” vì chúng tác động cả máy (URL mở ở app nào nhận nó); máy khoá hay màn tắt thì cả năm kiểu bị từ chối như mọi hành động khác. | `c9bb01a` | Giữ năm case mới trong `UIAction` (protocol + `ApelinDiagnosticsCore`) cùng `GesturePoint`, các hàm `doubleTap`/`longPress`/`drag`/`pressKey`/`openURL` trong `IcliSurface` + `IcliKitSurface` + `UnavailableIcli`, các giới hạn `doubleTapIntervalRange`/`gestureSecondsRange`/`dragHoldRange`/`dragPointRange`/`keyModifiers`/`keyNames`/`urlSchemes` cùng `validate()` và `checkGestureSeconds` trong `DiagnosticsTypes.swift`, ánh xạ ở `DiagnosticsService+UI.swift` + `Diagnostics.perform`, `ToolRunner.uiAction` + `gesturePoints`, mô tả/schema trong `ToolCatalog.swift`, câu trên thẻ duyệt ở `ApprovalPolicy.actionPhrase` (`duration`, `gesturePoint`), và bốn test (`ToolArgumentTests`, `ScreenUseConsentTests`, `DiagnosticsTests`, `DiagnosticsWorkerTests`). |

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
