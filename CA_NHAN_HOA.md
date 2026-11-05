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

| 41 | 2026-11-03 | Cá nhân hoá | **Nhật ký để kiểm tra AI lái iPhone:** trước đây AI bấm/đọc màn hình xong là không còn dấu vết nào — worker chạy công cụ không giữ lịch sử, nên "bấm sai chỗ" hay "bị từ chối" chỉ thấy trong lúc nhìn màn hình, xong là mất, không đối chiếu lại được. Nay app ghi vào nhật ký khởi chạy: mỗi thao tác màn hình (`apelin_screen_interact`, `apelin_screen_read_tree`, `apelin_screen_capture`) hai dòng — dòng lúc gọi (tên công cụ + tham số, đã rút gọn xuống một dòng) và dòng lúc trả lời (`→ ok` hoặc `→ failed` kèm dòng đầu của kết quả); mọi công cụ khác chỉ ghi một dòng khi **lỗi**. Thành công ở mức info, lỗi ở mức warning, nên bật/tắt theo mức được. Đọc ở **Cài đặt ▸ Logs** (lọc mục `Screen` / `Tool`), mỗi lần mở app một file, giữ 100 file gần nhất; mỗi dòng cũng vào unified log nên còn đọc được sau khi file nhật ký bị dọn. Chỉ lấy dòng đầu và cắt ở 240 ký tự, nên một dòng luôn là một dòng. | `83565c85` | Giữ `ScreenActionLog` (danh sách `screenTools`, hai mục `Screen`/`Tool`, `width` 240, `flat`/`firstLine`) tách riêng để test được, `ScreenActionJournal.note` ghi qua `Dog.shared.join`, lời gọi trong `ChatRuntime.follow` cạnh phần đếm build, test `ScreenActionLogCheck` và hai dòng đăng ký trong `Scripts/test-chat-transcript.sh`. |
| 42 | 2026-11-03 | Bản vá | **Sửa 7 bài kiểm thử đỏ của CI sau các đơn hàng trên (không thêm tính năng mới):** (1) câu trên thẻ duyệt cho `press_key` nay đúng như dòng 40 đã ghi — trước đó mã vẫn gắn thêm “trong app đang mở, bất kể app nào” vì chỉ `press_button` và `open_url` được miễn, nên câu sai với thực tế: phím bấm tác động cả máy chứ không riêng app đang mở; (2) `file_backups` liệt kê “3 saved copies of a.txt” thay vì “3 saved copyies of a.txt” (số nhiều bị ghép sai đuôi). Năm chỗ còn lại là **bài kiểm thử tự sai**, mã đúng nên sửa bài kiểm thử: skill `apelin-device-languages` được phép nhắc `dpkg-deb` (nó nói bản build mới tạo gói, không bảo AI tự chạy), `interpreter` để rỗng bị bỏ trước khi công cụ nhìn thấy nên chạy đúng interpreter mặc định `python3` chứ không phải bị từ chối, lượt gửi thứ hai mang cả hội thoại nên ảnh được đưa cho model ba lần chứ không phải hai, bài kiểm thử khoá ảnh được nới giới hạn dung lượng cho kho ảnh (bài đó kiểm khoá, không kiểm sức chứa — bài sức chứa vẫn nguyên), và dòng đầu kết quả `file_edit` được kiểm bằng `contains` vì sau cụm “(1 replacement, +1 -1)” còn sha256 và bản sao đã giữ. | `47e9d38` | Sửa `ApprovalPolicy.screenPhrase` (thêm nhánh `.pressKey` vào cùng nhóm `.pressButton`/`.openURL`), `ProjectFileTools.listBackups` (số nhiều “copy/copies”), và năm bài kiểm thử: `SkillAndPromptTests`, `CodeRunToolTests`, `MessageImageTests` (`store.maximumBytes`), `ChatAttachmentsTests`, `ScriptedSessionTests`. |

| 43 | 2026-11-03 | Bản vá | **Bài kiểm thử “ảnh gửi lại” nay thật sự chạy hai lượt:** dòng 42 đã ghi “lượt gửi thứ hai mang cả hội thoại nên ảnh được đưa cho model ba lần”, nhưng con số CI báo vẫn là 1 ở cả hai lần chạy — nguyên nhân không nằm ở mã mà ở chính bài kiểm thử: nhà cung cấp giả chỉ được xếp **một** câu trả lời, hết hàng đợi thì nó trả lỗi “No more faux responses queued” và **không gọi** phần ghi lại ảnh, nên lượt gửi thứ hai không tới được nhà cung cấp và không đưa ảnh nào cho model. Nay xếp đúng một câu trả lời cho mỗi lượt; lượt gửi thứ hai mang cả hội thoại nên ảnh được đưa cho model ba lần, và cả ba đều đúng bản sao đã chuẩn bị ở lượt đầu (không phải bản gốc, không phải bản chuẩn bị lại). | `8e11987` | Giữ một `reply: FauxResponseStep = .factory {…}` dùng cho cả hai lượt + `faux.setResponses([reply, reply])` trong `ChatAttachmentsTests` (bài “a message's picture is sent as the endpoint takes it, and its file keeps the bytes”); các khẳng định giữ nguyên: `given.count == 1` sau lượt đầu, `images.count == 3` và `allSatisfy { $0.data == first.data }` sau lượt hai. |

| 44 | 2026-11-03 | Bản vá | **Bài kiểm thử của máy chủ session (host) nay biên dịch được trở lại:** sau khi dòng 42 sửa xong bảy bài đỏ, CI còn đỏ ở bước sau — không phải bài kiểm thử nào sai mà là **không biên dịch nổi** bộ kiểm tra host: `Tests/SessionHost/main.swift:1389` gọi `codeRunChecks(scratch:scratchPath:)` nhưng trình biên dịch báo “cannot find `codeRunChecks` in scope”. Nguyên nhân: `Scripts/test-session-host.sh` liệt kê **thủ công** từng file nguồn để biên dịch, và file `Tests/SessionHost/CodeRunChecks.swift` (thêm cùng đợt làm `code_run`) chưa từng được ghi vào danh sách đó — nên lời gọi có mà phần thân hàm không được biên dịch kèm; lỗi chỉ lộ ra khi các bài kiểm thử khác đã chạy xong, nên rất dễ tưởng là lỗi mã. Nay file được thêm vào danh sách, và thêm một phép kiểm tự động để lỗi này không lặp lại: mọi file `.swift` trong `Tests/SessionHost` phải được script biên dịch nhắc tên, ngược lại một dòng trong script trỏ tới file không tồn tại cũng bị từ chối. | `940cfcd` | `Scripts/test-session-host.sh` thêm dòng `"$root/Tests/SessionHost/CodeRunChecks.swift"` (giữa `RootRunChecks.swift` và `ScreenConsentChecks.swift`, đúng thứ tự `main.swift` gọi); thêm `Scripts/check-session-host-sources.py` (so tên file trong thư mục với danh sách script, thoát 65 khi lệch) và cho `make check` chạy nó — biến `SESSION_HOST_SOURCES_CHECK` trong `Makefile`. |

| 45 | 2026-11-03 | Bản vá | **File kiểm `code_run` nay biên dịch được:** dòng 44 đưa `Tests/SessionHost/CodeRunChecks.swift` vào danh sách biên dịch, và lần chạy kế tiếp lộ ra ba lỗi cú pháp trong chính file đó — bằng chứng cho thấy nó chưa từng được biên dịch lần nào kể từ khi viết. Cả ba cùng một kiểu: gọi hàm `ask(...)` với `source:` đứng trước `interpreter:`, trong khi Swift bắt tham số có giá trị mặc định (ở đây `interpreter`) phải đứng trước tham số không có mặc định (`source`). Nay ba lời gọi xếp đúng thứ tự của hàm; nội dung kiểm thử không đổi. | `c62ebae` | Ba dòng trong `Tests/SessionHost/CodeRunChecks.swift` (các bài “the app's approval of this script”, “a script approved in another working directory”, “a card for code_run authorises nothing as root”): `ask(strict, …, interpreter: "python3", source: "print(1)")`. |
| 46 | 2026-11-03 | Bản vá | **Mười một bài kiểm `code_run` đỏ vì đường dẫn thư mục gốc chưa được chuẩn hoá:** sau khi dòng 45 sửa xong lỗi cú pháp, CI chạy tới bước kiểm tra máy chủ session và báo 1367/1378 đạt — 11 bài đỏ đều nằm trong file kiểm `code_run`, tất cả cùng một câu từ chối “thư mục làm việc phải nằm trong dự án”. Nguyên nhân: máy chủ luôn so thư mục làm việc với thư mục gốc dự án ở dạng đường dẫn thật (`AgentProjects` dựng mọi dự án qua `CanonicalPath.resolve`), nhưng bài kiểm lại dựng dự án thử từ thư mục tạm chưa chuẩn hoá — trên máy chủ CI thư mục tạm là `/var/folders/…` mà đường dẫn thật là `/private/var/folders/…`, nên mọi lần chạy thật đều bị từ chối. Đáng chú ý là hai bài “thư mục ngoài dự án bị từ chối” vẫn **đạt**, nhưng đạt vì lý do sai (bị từ chối vì cả đường dẫn gốc cũng sai); sau khi sửa, chúng mới thật sự kiểm điều cần kiểm. | `82a579c` | `Tests/SessionHost/CodeRunChecks.swift`: dựng `projectRoot` từ `scratchPath` (đã chuẩn hoá sẵn ở `Tests/SessionHost/main.swift:81`) thay cho `scratch` thô, kèm chú thích nêu lý do; các bài kiểm giữ nguyên nội dung. |

| 47 | 2026-11-03 | Bản vá | **Sáu bài kiểm `code_run` đỏ vì máy kiểm không phải root mà vẫn bị đòi đổi danh tính:** sau dòng 46, CI còn 6 bài đỏ (1372/1378), tất cả đều là những bài **thật sự chạy** một đoạn mã (`echo hi`, `exit 3`, `pwd -P`, in `$APELIN_PROJECT_ROOT`, hết giờ thì bị giết, quá 256 KiB thì cắt) — trong khi mọi bài từ chối đều đạt, và bài chạy với quyền root cũng đạt. Khác biệt duy nhất giữa bài đạt và bài đỏ là bước đổi danh tính sang mobile (uid/gid 501) đặt sẵn trước khi chạy: việc đó chỉ máy chủ đang là root mới xin được, còn trên máy kiểm tiến trình là người dùng thường nên hạt nhân từ chối và cả sáu bài chết cùng một chỗ. Lỗi ấy lại bị hàm `ran()` nuốt mất nên dòng báo chỉ nói “không chạy”, không nói vì sao. Nay máy chủ chỉ xin đổi danh tính khi chính nó đang là root — đúng như hàm `capture` vốn đã làm cho các công cụ nó tự chạy — nên trên máy thật hành vi không đổi, mà trên máy kiểm thì các bài chạy thật mới kiểm được điều cần kiểm. | `ef50454` | Giữ `let asMobile = !asRoot && geteuid() == 0` trong `AgentRunCode.run` (kèm chú thích nêu lý do), và `ran(...)` trong `Tests/SessionHost/CodeRunChecks.swift` nay trả về `(response, why)` — sáu bài chạy thật cộng bài chạy root in thêm lý do thật khi đỏ, thay vì im lặng. |
| 48 | 2026-11-03 | Cá nhân hoá | **Đọc màn hình tốn ngữ cảnh: AI tốn kém mỗi lần đọc cả trang.** Một trang (Cài đặt, một trang web) là hàng trăm phần tử, mà mỗi lần đọc xong thì **toàn bộ** danh sách đó nằm trong hội thoại và bị tính tiền lại ở mọi lượt gửi sau — chỉ cần tìm một nút cũng phải trả cho cả trang. Nay `apelin_screen_read_tree` nhận thêm ba tham số lọc: `match` (chỉ giữ phần tử có **nhãn, giá trị, mã định danh hoặc vai trò** chứa đoạn chữ này, không phân biệt hoa/thường và dấu — “CAFE” vẫn khớp “Café”), `clickable_only` (chỉ giữ thứ chạm được: nút, ô nhập, công tắc — dùng khi chữ của trang lấn át các nút) và `max_elements` (giữ tối đa bao nhiêu, trần 1000). Kết quả trả về kèm `elementsTotal` (trang có bao nhiêu phần tử) và `elementsMatched` (bao nhiêu khớp), nên lọc quá tay thì đọc lại không lọc thay vì tưởng trang trống; `truncated` bật khi bị cắt bớt (kể cả khi máy đã cắt sẵn). Việc lọc chạy **ngay trong tiến trình của phiên** trên cây đã nhận, không đọc lại lần hai, không xin phép lần hai, không có gì mới trên đường truyền: một lần đọc vẫn là một lần đồng ý. Không truyền tham số nào thì cây trả về y như máy liệt kê. | `d5cae32` | Thêm `UITreeFilter.swift` (tuỳ chọn lọc, `maximumLimit` 1000, đếm phần tử bị bỏ), `ToolRunner.swift` (lọc ngay trên `response.tree`), `ToolRunner+Arguments.swift` (`treeFilter`), mô tả + schema ba tham số trong `ToolCatalog.swift`, và test `UITreeFilterTests` (không lọc, khớp chữ/hoa-thường/dấu, khớp rỗng, chỉ thứ chạm được, trần, cắt bớt, cây sai dạng, ánh xạ tham số). |

| 49 | 2026-11-03 | Cá nhân hoá | **AI không biết mình đang tốn tiền vì đọc cả trang, và dễ kết luận sai “trang không có gì”.** Dòng 48 cho công cụ ba tham số lọc, nhưng công cụ chỉ làm được khi AI **biết** mà dùng — trước đó không có chỗ nào nói cây màn hình nằm lại trong hội thoại và bị tính tiền lại ở mọi lượt sau, cũng không nói lọc quá tay thì trông y như trang trống. Nay có skill dựng sẵn `apelin-screen-reading` (đọc bằng `apelin_skill_read`): đọc màn hình là **ngữ cảnh phải trả tiền lại**, ba tham số lọc chạy ngay trong phiên nên rẻ (không đọc lần hai, không xin phép lần hai), `elementsTotal`/`elementsMatched`/`truncated` là để **phân biệt trang trống với lọc sai** — thấy `elementsTotal` là số mà danh sách rỗng thì phải đọc lại không lọc, không được báo “không có nút đó”; mỗi hành động là một lần rồi **đọc lại xem có gì đổi** chứ kết quả trả về chỉ nói “đã bấm”; chạm theo `id` đọc được chứ không theo toạ độ đã nhớ; mỗi lần đọc và mỗi lần bấm là **một lần đồng ý riêng**, hỏi và chờ là bình thường; làm gì thay đổi vĩnh viễn (xoá, gửi, mua, tắt dịch vụ) thì nói trước; máy khoá/màn tắt thì chỉ có thức dậy, **không đoán mật khẩu**, máy có mật khẩu thì phải nhờ người dùng mở; màn hình của chính Apelin thì người dùng tự làm; và chỉ báo “xong” khi lần đọc sau xác nhận. | `093dcca` | Thêm `Skills/BuiltIn/DeviceScreen.swift` (skill `apelin-screen-reading`) và một dòng `deviceScreen` trong `BuiltInSkills.all`. |
| 50 | 2026-11-03 | Bản vá | **Bản dựng đỏ: dòng 48 đặt chỗ lọc ở nơi không tồn tại.** Dòng 48 viết việc lọc trong `ToolRunner` (phía app) trên một trường `response.tree` mà câu trả lời phía app không có (nó có `root`), nên tệp đó **không biên dịch được**; lọc ở app cũng vô nghĩa vì app không phải nơi nhận cây màn hình. Nay việc lọc **chuyển vào tiến trình phiên** (`apelin-agent`): ba tham số đi kèm yêu cầu, lọc chạy trên cây máy **đã trả lời**, nên một lần đọc vẫn là **một lần hỏi máy và một lần đồng ý**, mà model chỉ trả tiền cho trang đã thu hẹp; câu trả lời mang `elementsTotal`, `elementsMatched`, `truncated` bên cạnh cây. Cả sáu trường **không đi lên đường truyền**, không có lần đọc thứ hai. Không truyền tham số nào thì cây trả về y như máy liệt kê. | `c751358` | `HostDiagnosticsTypes.swift` (`ReadUITreeRequest` thêm 3 tham số, `ReadUITreeResponse` thêm 3 trường, đều có giá trị mặc định nên chỗ gọi cũ không phải sửa), `ToolRunner.swift` (truyền tham số xuống thay vì sửa câu trả lời), `ChannelHostBackend+Diagnostics.swift` (lọc ngay trong worker), test mới trong `ChannelHostBackendTests` (một trang đọc năm kiểu, và đếm đúng 5 lần hỏi máy), mô tả công cụ đổi “kept elements” → “beside the tree”. |
| 51 | 2026-11-04 | Cá nhân hoá | **AI tự lái máy mà không ai biết cái máy thật sự cho làm gì.** Yêu cầu “AI tự lái iPhone + trình duyệt” đòi hỏi trước hết một bản khảo sát, nhưng trước đó chỉ có suy đoán: tài liệu cũ vẫn nói máy không có `node` (thực tế có, v22.19.0), skill `apelin-device-executables` nói ký `ldid -S` là chạy được (thực tế bị `Killed: 9`), và không chỗ nào ghi rằng máy **không có Swift compiler** lẫn **không có XCTest** — nên mọi bài kiểm Swift chỉ chạy được ở CI. Nay có `Documents/Research/Device-Control-Survey.md`: từng dòng kèm lệnh đã đo — công cụ có/không (không `swiftc`, `gcc`, `cmake`, `ninja`, `xcrun`; có `make`, `git`, `ldid`, `dpkg-deb`, `python3`, `perl`, `node`; `/bin/sh` không có, chỉ có sh trong bootstrap), bốn đường dẫn XCTest đều **không tồn tại** nên không có cách nào chạy XCTest trên máy, `WebKit.framework` có nhưng chỉ tiến trình sở hữu `WKWebView` mới chạy được JavaScript trong đó ⇒ muốn điều khiển trang theo DOM thì phải có tweak nhét vào MobileSafari, còn đường đi được là cây trợ năng. Thí nghiệm chương trình tự biên dịch: `clang` + `ldid -S` rồi chạy thì `Killed: 9`; chỉ khi mang `com.apple.private.security.no-sandbox` mới chạy được (một mình `platform-application` hay `get-task-allow` đều chết) — tức công cụ phụ chạy bằng quyền mobile **bắt buộc** có quyền đó. `icli screen info` cho 375×812 điểm, 3x, đang mở khoá. Và một chỗ hổng đã đo được: khi RunningBoard thấy **nhiều hơn một app “focal”**, mọi lần đọc màn hình đều bị từ chối — `icli app frontmost` trả `several_focal_apps`, `icli ui tree` trả “frontmost application could not be verified”, máy chủ trả “not the verified foreground app after 3 s”, trong khi `icli app launch` vẫn báo `frontmost: true`. Vì thế cây trợ năng của Safari **chưa đo được** trong phiên này, và công cụ trình duyệt sau này phải báo đúng câu đó thay vì báo “trang trống”. | `70ea639` | Thêm `Documents/Research/Device-Control-Survey.md` (5 mục: công cụ, không XCTest, quyền chạy chương trình tự biên dịch, `icli` và chỗ hổng xác minh app trước, giới hạn trung thực của tính năng lái trình duyệt). |

| 52 | 2026-11-04 | Cá nhân hoá | **AI đọc được màn hình nhưng lái trang web thì vẫn phải đoán toạ độ.** Dòng 51 đã khảo sát: chữ trong trang web chỉ chạy được bởi chính tiến trình đang sở hữu trang (muốn chọc vào DOM thì phải có tweak nhét vào Safari), nên đường đi được là cây trợ năng mà Safari công bố. Nay có công cụ `apelin_browser`, và **một lần gọi làm đúng một việc**: `open` (đưa địa chỉ http/https cho hệ thống, Safari mở), `read` (trả địa chỉ trang, chữ trên trang và các thứ bấm được, mỗi thứ kèm một `element_id`), `find` (tìm một đoạn chữ trên trang), `click` (bấm theo `element_id` đọc được, nên trang vẽ lại vẫn bấm đúng, không bấm theo toạ độ đã nhớ), `type` (điền vào ô đang chọn), `key` (một phím, như return hay command+a), `scroll` (cuộn quanh một điểm), và `check` (trả **chính câu lỗi trang đang hiện**, trang trắng, và trang có chứa đoạn chữ mong đợi không) — thay vì tự đoán từ một cây rỗng. `element_id` là dạng `text:Đăng nhập` hoặc mã định danh trợ năng, đọc được từ lần `read`/`find` trước; `scope` chọn đọc riêng trang hay đọc cả màn hình; lần đọc vẫn lọc được bằng `match`/`clickable_only`/`max_elements` như dòng 48. Quan trọng: khi máy từ chối đọc (nhiều app cùng là app trước, chưa xác minh được app trước), công cụ **báo đúng lý do máy đưa ra**, không báo “trang trống” — đúng yêu cầu dòng 51 đặt ra. Lái trình duyệt vẫn là việc tác động lên màn hình nên vẫn hỏi theo Ask Before Using the Screen, và thẻ duyệt nói đúng thao tác sẽ làm. | `b4c06058` | `Tools/BrowserTool.swift` (dạng trang, điểm chạm theo phần tử, nhận diện vùng web, giới hạn số phần tử, từ điển câu lỗi), `Tools/ToolRunner+Browser.swift` (một lần gọi một việc), `Tools/ToolRunner+Facts.swift` (thẻ duyệt nêu thao tác trên màn hình), `Tools/ToolCatalog.swift` (mô tả + schema), `AgentToolName.swift` (`apelin_browser`), `Tests/ApelinAgentTests/BrowserToolTests.swift`, chuỗi mới trong `Localizable.xcstrings` và `Apelin/Interface/Chats/ChatTranscript.swift`/`ScreenActionLog.swift`/`AgentScreenRules.swift`. Test Swift chưa từng chạy (máy không biên dịch được) và cây trợ năng của Safari thật vẫn chưa đo được. |

| 53 | 2026-11-04 | Cá nhân hoá | **AI viết được chương trình nhưng không được chạy nó bằng quyền quản trị.** `code_run` (chạy chương trình AI tự viết bằng Python/Perl/Node/shell) chỉ chạy được ở quyền thường, nên khi một bước thật sự cần uid 0 — hỏi `irisin-cli`, cài một gói phụ thuộc — AI phải **viết lại đúng đoạn đó thành văn bản shell** cho `shell_run`: một công cụ khác, một thẻ duyệt khác, và bảng interpreter của `code_run` bị bỏ qua; còn lời gọi viết thẳng `root: true` thì bị từ chối bằng câu “code_run never runs as root”. Nay `code_run` đọc `root` **y như `shell_run`**: thẻ duyệt ghi tên **đúng chương trình đó** và **đúng thư mục đó**, chế độ Confirm hỏi mỗi lần, chế độ Full chạy thẳng không thẻ, và máy chủ session lấy danh tính từ **chính lần duyệt nó đã kiểm** chứ không từ lời gọi — nên một chương trình khác, một thư mục khác, hay một thẻ đã tiêu vẫn không chạy được. Các hình dạng model hay viết cho “đồng ý” (chuỗi `"true"`, số `1`, `null`) vẫn hiểu là quyền thường, đúng như ở `shell_run`. Bảng interpreter vẫn là giới hạn cuối: tên không có trong bảng vẫn bị từ chối dù ở quyền nào. `isRootTool` thay cho phép thử chỉ riêng `shell_run`, nên một thẻ ghi `command` **không** phải là phê duyệt quyền root cho bất kỳ công cụ nào, còn thẻ root của `code_run` được đọc là yêu cầu quyền root — chính vì vậy app mới kiểm tra **chủ máy** trước khi chuyển tiếp lần duyệt. **Điều này sửa lại phần “`code_run` không bao giờ chạy root” của dòng 38** (và câu từ chối root ở dòng 44–47 nay không còn); dòng 38 giữ nguyên theo mục 6.3, thay đổi ghi ở đây. **Chưa xác nhận chạy thật:** máy không có trình biên lẫn XCTest nên toàn bộ phần Swift mới chưa từng qua compiler (CI sẽ là lần biên dịch đầu tiên) và hai bài kiểm chạy thật chỉ chạy được ở CI. | `e89ebbff` | `Apelind/Session/Agent/AgentApprovals.swift` (`isRootTool`), `Apelind/Session/Agent/AgentRunCode.swift` (bỏ chốt “interpreter khác `sh` thì không được root”; bảng interpreter là giới hạn), `Packages/ApelinAgent/.../Approval/CommandClassifier.swift` (bỏ câu từ chối `root`), `.../Approval/ApprovalPolicy.swift` (thẻ root cho cả `shell_run` và `code_run`), `.../Tools/ToolRunner+Facts.swift` (đọc `root` thành thông tin thật), `.../Tools/ToolRunner.swift` (gửi `asRoot` theo thông tin đó), `.../Tools/ToolCatalog.swift` (mô tả + schema `root`), `Tests/ApelinAgentTests/CodeRunToolTests.swift` (bài cũ “bị từ chối mọi chế độ” → nay đòi có thẻ, chạy đúng chương trình, Full không thẻ), `Tests/SessionHost/CodeRunChecks.swift` (chạy thật một `python3` bằng root khi máy có `python3` trong đường dẫn của root, thẻ root chỉ tiêu một lần, thẻ root không duyệt lần chạy quyền thường và ngược lại). |
| 54 | 2026-11-04 | Cá nhân hoá | **AI được yêu cầu đọc một tệp thì bị chính công cụ đọc tệp từ chối.** `file_read` từ chối mọi tệp trên 512 KB (câu “là 524289 byte, quá giới hạn 524288 byte” kèm gợi ý dùng `shell_run`), nên nhật ký dài, tệp JSON lớn, tệp nguồn do máy sinh — đúng những thứ cần đọc — đều nằm ngoài tầm công cụ. Nay tệp được đọc theo **cửa sổ**: tệp vừa thì giữ nguyên như cũ, tệp lớn hơn được đọc từng 64 KB, mỗi câu trả lời hiện tối đa `maxReadBytes` byte và `limit` dòng (mặc định 2000), phần ghi chú nói **vị trí cần đọc tiếp**, và chỉ những dòng được hỏi mới được giữ nên một tệp rất lớn không tốn bộ nhớ bằng cả tệp. **Chụp màn hình quá 4 MB thì ảnh bị bỏ** (`ToolRunner.maxImageBytes`), model chỉ còn con số byte và **mù** trước chính màn hình mình vừa xin xem; nay ảnh được thu nhỏ (tối đa `FileImage.maxPixelSize` px một cạnh) rồi mã hoá lại, trường `note` của `CaptureScreenResponse` nói đã cho xem bản nào, còn ảnh dưới ngưỡng vẫn đi nguyên byte như máy chủ gửi. `FrameworkTools` cũng nói rõ đã bỏ bao nhiêu header khỏi danh sách thay vì im lặng. Toàn bộ giới hạn còn lại được khảo sát trong `Documents/Research/2026-11-04-Tool-Caps.md`: giới hạn do giao thức/nhà cung cấp (`HTTPRequest` 5 MB và 5 lần chuyển hướng, ảnh 1568 px / 3 MB), do máy (`crashRead` 256 KB, tệp đính kèm 32 MB), do chi phí của thứ đang đọc (ảnh nguồn 64 MP), **ngân sách của người gọi nhưng nói ra** (`find` 20000 mục, `grep` tệp 2 MB và trích 300 ký tự, diff 400 dòng, JavaScript 32 KB, thân skill 64/256 KB), và tham số của chính công cụ. Danh sách để xem lại sau: `grep` **im lặng bỏ qua** tệp nó không đọc nổi (quá 2 MB hoặc nhị phân), giới hạn của công cụ trình duyệt, `HTMLText` 4096 byte, `AppRelaunch` 1 MB, `SkillReader` 100 tệp; đầu ra của `shell_run`/`code_run` bị giới hạn ở máy chủ chứ không ở đây nên chưa khảo sát. **Chưa xác nhận chạy thật:** máy không có trình biên nên hai bài kiểm mới (`FileReadWindowTests`, `ScreenCaptureImageTests`) chưa từng qua compiler — CI là lần đầu. | `d5e9576d` | `Packages/ApelinAgent/Sources/ApelinAgent/Tools/ProjectFileTools.swift` (`readFile` đọc theo cửa sổ, `readWindow`, `streamedWindow`, `readAll`, `fill`), `.../Tools/ToolRunner.swift` (chụp màn hình: thu nhỏ thay vì bỏ), `.../Backend/HostDiagnosticsTypes.swift` (`CaptureScreenResponse.note`), `.../Tools/FrameworkTools.swift` (nói rõ số header đã bỏ), `Tests/ApelinAgentTests/FileReadWindowTests.swift` (mới), `.../ScreenCaptureImageTests.swift` (mới), `.../FileReadImageTests.swift`, `.../Support.swift` (`MockBackend` đặt được ảnh chụp), `Documents/Research/2026-11-04-Tool-Caps.md` (mới). |
| 55 | 2026-11-04 | Cá nhân hoá | **Nhiều khoá API thì lẫn nhau, và khi một khoá hỏng thì không ai thay.** Bốn lỗi liên quan cùng một chuỗi: (1) hai khoá khác nhau trên *cùng một tên miền* bị coi là một cấu hình, nên danh sách model, khoá và cấu hình trộn vào nhau — nay mỗi **Base URL trọn vẹn** là một cấu hình riêng (`/v1` khác `/v2` khác `http`/`https`, hai cách viết cùng một địa chỉ vẫn là một), một địa chỉ giữ được nhiều khoá, mỗi khoá giữ giao thức, khoá và cấu hình của chính nó; (2) chọn model **không thấy khoá nào** — model do nhiều khoá phục vụ vẫn hiện **một lần**, mở ra danh sách các khoá phục vụ nó, mỗi khoá ghi **tên như trong Cài đặt** (thêm số khi hai khoá trùng tên), **địa chỉ ở dưới**, tuyệt đối **không hiện khoá bí mật**, và các khoá **không phải** dùng chung một danh sách model; (3) trong chat **không có cách đổi khoá** — hàng model nay có thêm nút **khoá**, chỉ hiện khi có **từ hai khoá trở lên** cùng Base URL và cùng phục vụ model đang dùng, đổi khoá **giữ nguyên model, hội thoại, lịch sử và ngữ cảnh**; (4) **tự chuyển khoá không bao giờ chạy** — lỗi nay được phân loại theo đúng câu nhà cung cấp trả về: *hết hạn mức* (429/quota), *khoá bị từ chối* (401/khoá sai), *máy chủ lỗi* (5xx/quá tải) và *không kết nối được* (mạng, quá hạn, kết nối đứt); ba loại đầu tự gửi lại trên khoá khác **cùng Base URL và cùng model trước tiên**, có **thời gian chờ riêng** cho khoá vừa lỗi (khoá bị từ chối chờ lâu nhất), **tối đa 3 lần**, không hỏi lại khoá đang chờ; riêng lỗi *không kết nối được* thì **không tự gửi lại** vì request đó có thể đã được trả lời — nút **Thử lại** của người dùng mới là thứ tiêu danh sách, và danh sách model khác chỉ gồm những model người dùng đã bật. **Chưa xác nhận chạy thật:** máy không có trình biên nên **toàn bộ phần Swift mới chưa từng qua compiler** (CI là lần biên dịch đầu); bài kiểm `rate-limit-retry` chạy ở máy Mac/CI, ở đây đã kiểm bằng mắt từng câu lỗi mẫu; **chưa build, chưa cài, chưa push**. | `55d22c30`, `14a85f0c`, `9bebc139` | `Apelin/Interface/Settings/Accounts/EnabledModels.swift` (`identity`/`save` theo cả Base URL), `Apelin/Interface/Settings/Accounts/ModelProvidersController.swift` (mỗi Base URL một mục, danh sách model theo địa chỉ), `Packages/ApelinKit/.../Operations/AgentEndpoint.swift` (mới: chuẩn hoá Base URL + tên rút gọn), `.../Operations/AgentSignIn.swift` (`AgentAccount.endpoint`, `profileID`), `Packages/ApelinAgentWorker/SignIn/AccountDesk.swift`, `Packages/ApelinKit/Tests/.../AgentEndpointTests.swift` (mới), `Apelin/Interface/Chats/RateLimitRetry.swift` (`ModelFailureKind`, `kind(of:)`, `automatic`, `cooldown`), `Apelin/Interface/Chats/ChatRuntime.swift` (ghi loại lỗi + thời gian chờ, chặn tự gửi khi lỗi không kết nối được, chờ đúng lượt), `Apelin/Interface/Chats/ChatStore.swift` (`ModelRetryState.kind`/`cooldowns`), `Apelin/Interface/Chats/Composer/ModelCandidates.swift` (`retryKey`, `nextCandidate`, cùng Base URL trước), `Apelin/Interface/Chats/Composer/ChatModelPicker.swift` (dòng model nhiều khoá, trang chọn khoá), `Apelin/Interface/Chats/Composer/Sections/ComposerModelBar.swift` (nút khoá), `Apelin/Interface/Chats/ChatController.swift` (`keyChoices`, `switchKey`), `Tests/RateLimitRetry/main.swift` (bài mới: phân loại, thời gian chờ, không tự gửi khi không kết nối được). |
| 56 | 2026-11-04 | Quy trình | **Mỗi phiên mới (kể cả đổi model) phải đọc lại cả file dài mới biết đang làm gì, mà kho ghi nhớ thì gần đầy.** Nay có ba tầng rõ ràng, không cần Sếp kể lại: (1) **§9 “Trạng thái hiện tại”** ở cuối file này — bảng các việc đang dở kèm HEAD, bước kế tiếp và phần chưa kiểm chứng, luôn được cập nhật ở mỗi mốc, và đọc bằng `file_grep "^## 9\."` rồi `file_read` từ dòng đó nên **không phải đọc cả file**; (2) **§10 “Sổ dọn ghi nhớ”** — một hạn mức chung 64 bản/32 KB, cách đo bằng một lệnh `python3`, ngưỡng dọn 75 %, thứ tự dọn (handoff `done` → bản trùng → handoff cũ đã ghi vào §9 → bản dài đã có trong tài liệu/skill) và danh sách không bao giờ xoá (sở thích giao tiếp, luật chung, quy tắc lưu, §9); quy tắc **riêng của dự án** được đẩy sang `AGENTS.md` vì file đó được nạp tự động mà không tốn kho; (3) khối mở đầu `AGENTS.md` nay trỏ thẳng vào §9 thay vì bắt đọc §6.1/§8 trước. Mục đích: phiên sau đọc một mục là làm tiếp được, không hỏi lại, và kho ghi nhớ tự dọn trước khi đầy. | (commit tài liệu cùng lượt) | Giữ §9 cập nhật ở mỗi mốc (cùng lượt với dòng bảng 6.1 và ghi nhớ handoff), giữ khối mở đầu `AGENTS.md` trỏ vào §9, giữ ngưỡng 75 % và danh sách không-bao-giờ-xoá ở §10, và giữ nguyên tắc quy tắc riêng dự án nằm ở `AGENTS.md`. |
| 57 | 2026-11-04 | Quy trình | **Cùng một bộ luật nằm ở bốn chỗ, sửa một chỗ thì ba chỗ kia lặng lẽ thành bản cũ.** Trước đây luật của Sếp có mặt đồng thời ở: ghi nhớ `5783d40e` (~13 KB — gần nửa kho 32 KB dùng chung mọi dự án), mục “Luật làm việc của Sếp” trong `AGENTS.md`, file `Documents/Personal/Operating-Specification.md`, và một bản ghi riêng cho chữ “bắt buộc”; mỗi phiên mới phải đọc lại cả file dài mà vẫn không biết bản nào đang đúng. Nay mỗi thứ **một chỗ duy nhất**: luật chung của Sếp ở **skill `sep-working-rules`** (skill không tốn kho ghi nhớ và mọi dự án tự đọc), bản **nguyên văn 19 mục** để nguyên trong `Operating-Specification.md` cùng folder skill — file luật của Sếp nằm **ngoài git** (`.gitignore` bỏ qua); `AGENTS.md` và file `Documents/Personal` chỉ còn **một dòng trỏ**; kho ghi nhớ chỉ giữ **một dòng móc** trỏ tới skill. Xoá 4 bản trùng (`5783d40e`, `32a1b006`, `34c0001c`, `cce3bf60`): kho **20 735 → 4 149 byte (63 % → 13 %), 13 → 10 bản**, không mất chữ nào vì bản nguyên văn đã đối chiếu byte-đúng trước khi xoá. Chỗ đặt cho mọi thứ về sau: bảng “Where a rule belongs” ở đầu `AGENTS.md` và §10. | `d3b924a`, `b08c873` | Giữ luật chung **chỉ** ở skill `sep-working-rules`; `AGENTS.md` và file `Documents/Personal/Operating-Specification.md` chỉ trỏ, không chép lại; kho ghi nhớ không chép luật, chỉ một dòng móc; bản nguyên văn 19 mục nằm trong folder skill. |

| 58 | 2026-11-04 | Bản vá | **Nhập file từ "Gần đây" / "iCloud Drive" báo "Unable to Import File"**, file "Trên iPhone" thì vào được. Hai mục kia trả về file reference (`/.file/id=…`) mà `realpath` không thấy, hoặc file iCloud chưa tải về (dataless) — đọc trực tiếp theo path nên lỗi. Nay `readAttachment` giữ nhánh nhanh cho file trên máy, còn chỗ `realpath` không ra hoặc file iCloud chưa có thì qua `NSFileCoordinator` để hệ thống dò địa chỉ thật và tải xuống trước khi đọc. Chưa build/cài để kiểm chứng (máy chưa có toolchain; chờ Sếp). | `01b227b4` | Giữ nhánh `NSFileCoordinator` trong `ComposerAttachmentImport.readAttachment` (tách `readFile`); file trên máy vẫn đi đường cũ. |
| 59 | 2026-11-04 | Cá nhân hoá | **AI làm việc dài mà người dùng không biết đang tới đâu, và chính AI sau khi bị tóm tắt hội thoại cũng quên mất đang ở bước nào.** Trước đây tiến trình chỉ là lời kể trong hội thoại: không có chỗ nào ghi “việc này gồm mấy bước, bước nào xong”, nên khi hội thoại dài bị tóm tắt, khi đổi model, khi đóng rồi mở lại chat, hoặc khi app khởi động lại giữa chừng, người dùng chỉ thấy im lặng còn AI có thể làm lại bước đã xong. Nay AI có công cụ `plan_update`: nó viết **toàn bộ kế hoạch** (tối đa 12 bước, mỗi bước một mã ngắn, một dòng mô tả, một trạng thái — chờ / đang làm / xong / lỗi / bỏ qua, và chỉ **một** bước được “đang làm”), gửi lại cả kế hoạch mỗi lần có gì đổi. Kế hoạch được ghi thành **loại sự kiện riêng của phiên** chứ không phải tin nhắn, nên nó **không mất** khi hội thoại bị tóm tắt, khi đổi model, khi app khởi động lại hay khi mở lại chat — và phiên sau đọc lại là biết đang ở bước nào. Một bước chỉ được chuyển sang **xong** khi có **bằng chứng** nêu đúng công cụ đã thật sự chạy và nó trả lời gì; bỏ qua/lỗi cũng phải kèm lý do. Trên màn hình có **thanh kế hoạch** ngay trên ô soạn tin: đóng lại là một dòng “2/5 bước xong · đang làm gì”, mở ra là danh sách bước kèm dấu và trạng thái (chạm vào một bước để xem đầy đủ bằng chứng), cùng ba nút **Tạm dừng / Tiếp tục**, **Kết thúc kế hoạch**, **Xoá kế hoạch** — người dùng bấm thì lệnh đi thẳng vào phiên nên thanh và AI không bao giờ nói lệch nhau. **Chưa kiểm chứng:** máy này không có trình biên Swift nên toàn bộ phần mã mới **chưa từng qua compiler** (CI là lần biên dịch đầu), và **thanh kế hoạch chưa từng được nhìn thấy trên màn hình**. | `b2cea5d` | `Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentPlan.swift` (mới: `AgentPlan`/`AgentPlanStep`/`AgentPlanRules`/`AgentPlanRequest`/`AgentPlanResponse`), `.../Operations/AppOperation.swift`, `.../Operations/AgentToolName.swift`, `Packages/ApelinAgent/Sources/ApelinAgent/Session/SessionPlan.swift` (mới), `.../Tools/PlanArguments.swift` (mới), `.../Session/AgentSession.swift`, `.../Session/AgentSessionEvent.swift`, `.../Session/SystemState.swift`, `.../Persistence/SessionEventLog.swift`, `.../Approval/ApprovalPolicy.swift` (viết kế hoạch không cần hỏi duyệt), `.../Tools/ToolCatalog.swift`, `.../Tools/ToolRunner.swift`, `Packages/ApelinAgentWorker/AgentWorker.swift`, `Apelind/Dispatch/AgentHandler.swift`, `Apelin/Interface/Chats/ChatPlan.swift` (mới: đọc kế hoạch từ sự kiện phiên), `.../Chats/ChatPlanBar.swift` (mới: thanh kế hoạch), `.../Chats/ChatController.swift`, `.../Chats/ChatRuntime.swift`, `.../Chats/ChatTranscript.swift`, `Apelin/Resources/Localizable.xcstrings` (10 khoá mới + bản dịch), `Packages/ApelinKit/Tests/ApelinProtocolTests/AgentPlanTests.swift` (mới), `Packages/ApelinAgent/Tests/ApelinAgentTests/SessionPlanTests.swift` + `PlanArgumentsTests.swift` (mới), `Tests/ChatPlan/main.swift` (mới), `Scripts/test-chat-plan.sh` (mới), `Makefile` (móc vào `make harness`), `AGENTS.md` (danh sách thao tác). |

| 60 | 2026-11-05 | Bản vá (hiệu năng launch/catalog) | Tối ưu thời gian cold launch và danh sách hội thoại/dự án: `ChatStore.load()` chuyển async và decode song song các tệp `.json`, bỏ qua tệp lỗi cá biệt; `ProjectCatalogMonitor` không còn theo dõi từng thư mục dự án và manifest, chỉ theo dõi thư mục ứng dụng và gốc `Projects`. Bump lên 0.4.9 build 41, release notes `Documents/Releases/0.4.9.md`. | tag `v0.4.9` (commit xuất bản) | Giữ hai thay đổi trong `ChatStore.swift` và `ProjectCatalogMonitor.swift`; `ChatRuntime` đã gọi `try await store.load()`. |

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

## 8. Nhật ký quá trình làm việc (bắt buộc)

Mục 6 ghi *đã đổi cái gì*. Mục này ghi *đang làm gì và tới đâu*, để **phiên sau
— kể cả khi dùng model khác — đọc là hiểu, không cần người dùng kể lại**.

**Khi bắt đầu một việc dài** (nhiều bước, nhiều file, hoặc có rủi ro): mở một
**ghi nhớ handoff** của Apelin (`kind=handoff`, phạm vi dự án) ghi rõ:

- mục tiêu và ràng buộc của việc đang làm;
- file/d thư mục sẽ đụng tới;
- việc đã xong (kèm hash commit nếu đã commit);
- việc kế tiếp, và chỗ nào còn vướng.

**Trong lúc làm:** cập nhật ghi nhớ đó sau mỗi mốc lớn (xong một phần, build
xong, đổi hướng) — không cần ghi mỗi lệnh. **Xong việc:** đổi `status` thành
`done`, giữ lại làm hồ sơ.

**Nếu kế hoạch dài hơn hạn mức ghi nhớ** (khoảng 32 KB): viết file `.md` trong
repo (ví dụ `Documents/Plan/Handoff.md`) và để ghi nhớ chỉ trỏ tới đường dẫn
file đó.

**Cách lưu:** `apelin_memory_list` lấy revision trước → `apelin_memory_save`;
ưu tiên **sửa bản ghi đã có** thay vì tạo bản mới trùng.

**Ba chỗ cần đọc khi tiếp nhận một việc:** khối mở đầu `AGENTS.md` → mục 6.1 và
mục 8 của `CA_NHAN_HOA.md` → các ghi nhớ handoff đang `active`.

### 8.1 Tiếp nhận việc đang dở — làm tiếp luôn, không hỏi lại

Ghi nhớ handoff đang `active` đã ghi mục tiêu, ràng buộc, việc đã xong và việc
kế tiếp thì **phiên sau (kể cả model khác) làm tiếp ngay**: không bắt người dùng
kể lại, không hỏi lại điều đã ghi trong handoff hay trong mục 6.1.

Chỉ hỏi người dùng khi: bước kế tiếp cần một quyền mà **ràng buộc trong handoff
chưa cho** (push lên GitHub, cài lên máy, phát hành gói); hoặc tài liệu mâu thuẫn
nhau, thiếu hẳn thông tin, hay việc đã đổi hướng so với ghi chép.

Một việc chỉ được coi là **xong** khi có bằng chứng đã chạy thật (log build, kết
quả kiểm thử, lần đọc màn hình) — không phải khi code đã viết xong. Phần chưa
thử được thì ghi rõ là chưa thử.

Cách mở lại việc: `apelin_memory_list` xem các handoff `active` → đọc bản ghi của
đơn cần làm → làm theo `nextSteps` trong đó.

---

## 9. Trạng thái hiện tại — đọc mục này là đủ để làm tiếp

> **Đây là mục phải đọc đầu tiên khi vào việc.** Nó nằm ở **cuối** file nên đọc
> được mà không phải đọc cả file dài: `file_grep` với mẫu `^## 9\.` trong
> `CA_NHAN_HOA.md` để biết số dòng, rồi `file_read` từ dòng đó tới hết file.
> **Cập nhật mục này ở mỗi mốc**, cùng lượt với dòng ở bảng 6.1 và ghi nhớ
> handoff. Mục nào đã đóng thì rút thành một dòng ở bảng 6.1 rồi bỏ khỏi đây;
> mục nào cũ hơn một tuần mà không ai đụng thì rút gọn như vậy.

**HEAD khi cập nhật mục này:** `d820f2d` (`main`/`origin/main`; tag `v0.4.13`; commit mới nhất là release `v0.4.13`. Repo đang tinkering Phase 1 local config bundle core, chưa build/cài.)

> Ghi chú đồng bộ 2026-11-06: bảng việc dở bên dưới còn dữ liệu từ giai đoạn 0.4.7/0.4.9. Các mốc Git thực tế mới hơn là `38a9542` (khôi phục background survival), `d67b84e` (`v0.4.11`, animated progress), `d335b96` (`v0.4.12`, UI polish) và `66eb3cf` (nâng task progress). Các đầu mục cũ trong bảng chưa xác nhận là việc còn mở.

| # | Việc đang dở | Bước kế tiếp | Chưa kiểm chứng |
|---|---|---|---|
| 1 | **Base URL / khoá API / model / tự chuyển khoá** (`55d22c3`, `14a85f0`, `9bebc13`) | cài + thử trên máy | mọi hành vi app chưa chạy |
| 2 | **Bỏ chặn công cụ vô lý** (`d5e9576`, `804daba`) | các mục còn lại của đơn `6811e482` | `file_read` tệp lớn; ảnh chụp thu nhỏ |
| 3 | **IDE AI đa ngôn ngữ** (`code_run`, sao lưu/hoàn tác tệp) | thử `file_revert`, `file_backups`, `code_run` sau khi cài | `FileBackupTests` chỉ chạy ở CI |
| 4 | **Tối ưu AI** (`9c55a9e`) | ảnh HEIC/quá lớn, dòng cached, đổi model | nhóm 1–3 đã có trong repo |
| 5 | **Task Progress Panel / Plan bar** (`b2cea5d`, `a4f0b77`, `5ed25ea`, `8c53479`) | manual pass; guard resume đã trích thành `AgentSession.shouldStartResumeRun`, có `PlanResumeRunTests` guard cơ bản | UX chưa từng mắt; chưa integrated `AgentSession.planState`; chưa đo baseline |
| 6 | **Nhập file từ Recents/iCloud Drive** (`01b227b4`) | chọn PDF/XML tay từ máy | chưa build/cài |
| 7 | **Kế hoạch phiên / thanh tiến đồ** (`b2cea5d`, `8c53479`) | manual pass; refactor tách mutation/side-effect nếu giữ ổn định | chưa từng kiểm bằng mắt |
| 8 | **Hiệu năng cold launch / chat list / daemon handshake** (`8c53479`) | đo baseline và đối chiếu hotspot trước khi sửa | chưa có số liệu |
| 9 | **Bản cục bộ `.apelinbak` / ConfigBundle Phase 1** (core hardened tại `ConfigBundle.swift`) | build/CI + tích hợp app export/import UI, rollback, runtime reload | chưa compile; app UI/integration/runtime chưa có; secret/token mapping chưa hoàn tất |

**Ràng buộc chung của các việc trên:** HEAD mới nhất `d820f2d` (tag `v0.4.13`). Build/cài chưa thực hiện trong lượt này; các đầu mục phần lớn còn chờ CI/device. Không cài tự ý nếu Sếp chưa yêu cầu.

**Đã đóng, không cần đọc lại:** tầng tài liệu tiếp nhận (§8 và §8.1) và chính
§9/§10 này — đã viết xong và commit ở `2f05041`; sáu commit sửa lỗi biên dịch sau
`69b004d` (`a140824`, `d8bfbf1`, `a0f9003`, `f45cceb` — browser tool,
`FileReadWindowTests`, provider casing), và `c006bc7` (4 sai lệch Host test), đã lên
`main` local; và **cơ chế luật/ghi nhớ một chỗ** (dòng 57) — luật của Sếp ở skill
`sep-working-rules`, kho ghi nhớ chỉ còn một dòng móc (4 149 byte / 10 bản), đã push.
Ghi chú cũ “cây làm việc có thay đổi treo của phiên Task Progress Panel, **không đụng
vào**” nay **đã đóng**: đó chính là việc kế hoạch, đã vào `b2cea5d` — cây làm việc sạch.

## 10. Sổ dọn ghi nhớ — tự động, không cần Sếp nhắc

Kho ghi nhớ của Apelin (`~/Documents/wiki.qaq.apelin/memories.json`) có **một
hạn mức chung cho mọi chat và mọi dự án: 64 bản / 32 KB**. Đầy là hỏng việc
ngày mai, nên dọn là **một phần của việc đang làm**, không phải việc riêng.

**Đo trước khi lưu** (chạy được, đã dùng nhiều lần):

```sh
python3 -c "import json;d=json.load(open('/var/mobile/Documents/wiki.qaq.apelin/memories.json'));r=d['records'];print(sum(len(x['body'].encode()) for x in r),len(r))"
```

Ra `<số byte> <số bản>`. **Quá 24 KB (75 %) hoặc 48 bản thì dọn trước khi thêm.**

**Thứ tự dọn** — dừng ngay khi xuống dưới 75 %:

1. Handoff `done` → xoá (hồ sơ đã nằm ở bảng 6.1 và §9).
2. Bản trùng nhau → gộp vào bản còn đúng, xoá bản kia.
3. Handoff cũ mà §9 đã ghi đủ → xoá; nhiều đơn đang dở thì gộp thành **một**
   handoff “Bảng việc đang dở”, mỗi đơn hai dòng như bảng ở §9.
4. Bản dài mà phần cốt lõi đã nằm trong `AGENTS.md`, `CA_NHAN_HOA.md` hay một
   skill → bỏ khỏi ghi nhớ, để lại một dòng trỏ tới file. Quy tắc **riêng của
   dự án** nên nằm trong `AGENTS.md`: file này được nạp tự động mà **không tốn**
   kho ghi nhớ.
5. Chỉ khi đó mới rút ngắn bản dài còn lại — **bản Sếp tự viết thì hỏi Sếp
   trước**, không tự cắt. Bản luật 19 mục đã đi đúng đường này ở lượt 3: hỏi trước,
   chuyển **nguyên văn** vào skill rồi mới xoá bản trong kho (nhật ký dưới).

**Không bao giờ xoá:** sở thích giao tiếp (gọi “Sếp”, tiếng Việt, ngắn, ví dụ
đời thường), quy tắc lưu và dọn này, **dòng móc trỏ tới luật chung của Sếp** (bản
luật nằm ở skill `sep-working-rules`, không nằm trong kho — xoá dòng móc là mất
đường tới luật), và §9 ở trên.

**Chỗ lưu — chọn đúng, đừng tạo trùng:**

| Nội dung | Chỗ lưu |
|---|---|
| Luật áp cho **mọi** dự án (cách nói, cách làm việc) — hiện là 10 luật của Sếp | **skill `sep-working-rules`**; ghi nhớ chỉ giữ **một** dòng móc `scope=global` trỏ tới skill |
| Bản **nguyên văn** dài của Sếp | file `.md` trong folder skill (`skills/sep-working-rules/Operating-Specification.md`), **ngoài git** nếu là văn bản của Sếp — không tốn kho |
| Quy tắc **riêng dự án này** | `AGENTS.md`, mục *Fork personalisation* — không tốn kho |
| Việc đang dở tới đâu, kế tiếp là gì | **một** ghi nhớ `kind=handoff` bản ngắn; chi tiết ở §9 |
| Kế hoạch dài hơn hạn mức ghi nhớ | file `.md` trong repo (`Documents/Plan/…`), ghi nhớ chỉ trỏ đường dẫn |
| Cách làm một **loại** việc dùng lại ở nhiều dự án | skill (`apelin_skill_save`), không phải ghi nhớ |

**Nhật ký dọn:**

- **2026-11-04 (lượt 2):** 13 bản / 28 134 byte (86 %). Gộp 4 handoff rời thành
  **một** handoff “Bảng việc đang dở” (xoá 3 bản: `8b955458`, `bb8bd1fe`,
  `acaa821f`), rồi rút gọn 3 bản dài — kỹ năng tự tạo, hai clone Apelin, quy tắc
  lưu trạng thái — xuống 26 159 byte (80 %). **Còn một bản do Sếp tự viết** nặng
  ~13 KB (“Assistant Operating Specification”) chiếm một nửa kho: theo bước 5 nó
  chỉ được rút khi **Sếp gật**, nên vẫn để nguyên và đã hỏi Sếp.

- **2026-11-04 (lượt 3):** 20 735 byte / 13 bản (63 %), trong đó bản 13 KB của Sếp
  chiếm gần một nửa. Sếp cho toàn quyền tái cấu trúc, nên: bản đó chuyển thành
  **skill `sep-working-rules`** — `SKILL.md` 6 402 byte (10 luật L1–L10 + L8b, luật
  lưu/dọn), `Operating-Specification.md` 15 313 byte giữ **nguyên văn** 19 mục (đã
  `diff` với bản trong kho: giống hệt, không mất chữ nào) — rồi xoá **4 bản trùng**:
  `5783d40e` (19 mục), `32a1b006` (luật “bắt buộc”, nay là **L8b** trong skill),
  `34c0001c` (quy tắc lưu/dọn, nay ở skill + §10), `cce3bf60` (danh sách skill, mỗi
  phiên tự hiện nên không cần ghi nhớ); thêm **một** dòng móc `scope=global`.
  Kết quả: **4 149 byte / 10 bản (13 %)**. Từ nay luật chung **chỉ** ở skill,
  `AGENTS.md` và `Documents/Personal/Operating-Specification.md` chỉ trỏ, kho không
  chép lại. Chi tiết ở dòng 57, bảng 6.1.

