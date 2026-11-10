# Kế hoạch tối ưu khởi động (Startup Optimization Plan)

> Trạng thái: kế hoạch, chưa triển khai. Branch `main` tại `ba964c7`.
> Phạm vi: chỉ phân tích và đề xuất; không sửa code, không build/install.

## 1. Mục tiêu

- Giảm thời gian từ khi app xuất hiện đến khi người dùng có thể đọc/gửi chat.
- Giữ nguyên logic: không làm mất dữ liệu, không phá reconciliation, không phá sidebar/project menu.
- Ưu tiên thay đổi nhỏ, có thể rollback.

## 2. Kết quả phân tích (đã làm)

### 2.1 Chi phí khởi động thật sự

- `AppDelegate`: executable watch, migration, journaling, network, conversation notices, console. Chạy một lần, không chặn UI chính.
- `SceneDelegate` → `RootInterfaceController`: tạo window/root. Nhanh.
- `WelcomeFlow`: chỉ chặn người mới (onboarding). Người cũ không bị chặn.
- `ProjectSummary.load`: quét `Projects/`, validate manifest, đọc ngày tạo. Chạy detached, nhẹ. **Không phải bottleneck.**
- `ChatRuntime.load`: **đây là bottleneck chính**. Đọc *mọi* file `Chats/*.json`, mỗi file là `ChatRecord` đầy đủ gồm `events: [TaskEvent]`. Với lịch sử dài, tổng chi phí giải mã JSON lớn.
- Reconciliation: `agentList()` + lặp records. Chạy *sau* `isLoaded = true` và `onChange?()`, nhưng đồng bộ trong cùng hàm `load()`, nên UI chỉ hiện sau khi reconciliation xong trong thực tế (vì `await`).

### 2.2 Điều đã sẵn có (không cần làm lại)

- `ProjectMenuOrder.split`: đã xếp top 5 project theo tương tác chat gần nhất hoặc ngày tạo thư mục, phần còn lại vào "More Projects". → đã có ranking theo recency.
- `ChatRuntime.isLoaded` đặt `true` và gọi `onChange?()` *trước* reconcile. → UI có thể usable sớm nếu reconcile được đẩy nền.
- Provider/account chỉ tải khi mở model picker hoặc retry. → không chặn startup.

### 2.3 Đánh giá đề xuất của người dùng

| Đề xuất | Giá trị | Ghi chú |
|---|---|---|
| Load 5 chat gần nhất trước | Cao | Cần tách events khỏi summary khi lưu/đọc. |
| Load 3 project gần nhất trước | Thấp | Project scan đã nhẹ; ranking đã có. Chỉ hữu ích nếu "project" ngầm bao gồm chat của nó. |
| Theo dõi 3 project gần nhất bằng danh sách cố định | Rủi ro stale | Nên suy ra từ tương tác chat hiện có; chỉ thêm persisted list nếu có nhu cầu cụ thể. |
| Tải tiêu đề trước, nội dung đầy đủ khi mở chat | Cao nhất | Đây là hướng có giá trị thật. |

## 3. Nguyên tắc an toàn (không làm hỏng dự án)

1. **Không đổi định dạng lưu trữ mà không có migration.** Mọi file cũ phải đọc được.
2. **Không làm mất `events`.** Lazy load phải bảo toàn transcript, cursor, replay, sending.
3. **Reconciliation không được bỏ.** Chỉ được đẩy nền, không được bỏ qua.
4. **Không thay đổi semantics `isLoaded`/`isReconciled`.** Các gating hiện có (`RootInterfaceController.restoreChatIfReady`, `SidebarController.hasLoadedProjects`) phải vẫn đúng.
5. **Mỗi phase độc lập, có thể dừng lại.** Không bắt buộc làm hết.
6. **Đo lường trước khi tối ưu sâu.** Phase 0 bắt buộc trước Phase 3.

## 4. Các phase

### Phase 0 — Đo lường (không đổi logic)

**Mục tiêu:** xác định bottleneck thực sự trên máy.

**Việc:**
- Thêm log timing (os_log, subsystem `wiki.qaq.apelin`) quanh:
  - `ChatRuntime.load`: bắt đầu, sau `store.load()`, sau cleanup untouched, sau forget deleted, `isLoaded`, sau reconcile, sau adopt.
  - `ProjectSummary.load`.
- Đọc log bằng `apelin_log_read` sau cold launch.
- Ghi số liệu: số chat, tổng byte, thời gian từng bước.

**Rủi ro:** thấp. Chỉ thêm log.

**Tiêu chí dừng:** có số liệu cho biết `store.load()` hay reconcile chiếm bao nhiêu %.

### Phase 1 — Reconciliation không chặn UI (rủi ro thấp, giá trị cao)

**Mục tiêu:** `isLoaded = true` + `onChange?()` trả về nhanh hơn, reconciliation chạy nền.

**Thay đổi:**
- Trong `ChatRuntime.load`, sau `isLoaded = true; onChange?()`, thay vì `await agentList()` đồng bộ, spawn `Task { @MainActor in ... }` thực hiện:
  - `let live = await (try? ApelinService.app.agentList().sessions) ?? []`
  - lặp records reopen/follow hoặc set isWorking=false
  - `isReconciled = true`
  - `onChange?()`
  - adopt sessions live.
- Giữ thứ tự: reconciliation chỉ chạy sau khi `isLoaded`.
- Thêm cờ `reconciliationTask` để tránh chạy trùng nếu `load` gọi lại (hiện tại `load` chỉ gọi một lần; nhưng thêm guard an toàn).

**Phụ thuộc:**
- `restoreChatIfReady` không phụ thuộc `isReconciled` (đã kiểm). OK.
- Sidebar `refresh()` dùng `runtime.summaries` — reconciliation có thể thay đổi `isWorking` → sẽ gọi `changed` → `onChange` → refresh. OK.

**Rủi ro:**
- Nếu reconciliation chạy nền, `isReconciled` false lâu hơn. Code nào chờ `isReconciled`? Kiểm tra grep. Nếu có, cần xem xét.
- Race: người dùng mở chat trước khi reconcile xong → `reopen(as:)` có thể bị gọi muộn. Nhưng reopen chỉ xảy ra khi có live session; nếu chat đã mở, follow sẽ bắt đầu từ cursor hiện tại. Cần đảm bảo `follow` được gọi khi reconcile xong cho chat đang mở. Hiện tại `follow(record.summary.id, task:)` được gọi trong reconcile loop; nếu chat đang mở, follow sẽ chạy. OK.

**Tiêu chí dừng:** cold launch đến UI usable nhanh hơn; reconcile hoàn tất trong nền không gây crash.

### Phase 2 — Dọn dẹp nhẹ (tuỳ chọn)

**Mục tiêu:** giảm công việc đồng bộ trong `load`.

**Thay đổi:**
- `forget(DeletedProjects.gone(...))` hiện chạy trước `isLoaded`. Có thể giữ, vì cần summaries. Nhưng có thể chuyển sau `isLoaded` nếu UI chấp nhận hiển thị chat của project đã xoá trong thời gian ngắn. **Khuyến nghị giữ nguyên** để tránh nháy.
- Cleanup untouched: giữ nguyên (nhanh, và cần trước isLoaded để không hiện row rác).

**Rủi ro:** thấp. Khuyến nghị không làm Phase 2 nếu Phase 1 đủ.

### Phase 3 — Lazy load events (rủi ro trung bình-cao, giá trị cao)

**Mục tiêu:** startup chỉ đọc summary (nhẹ), events tải khi mở chat.

**Thiết kế:**
1. **Tách lưu trữ:**
   - File `Chats/<id>.json` hiện chứa toàn bộ `ChatRecord`.
   - Chuyển sang hai file:
     - `Chats/<id>.json`: `ChatRecord` nhưng `events` rỗng khi lưu? Không — cần events để save.
     - Thay vào đó: lưu `events` vào `Chats/<id>.events.json` (hoặc giữ trong cùng file nhưng đọc lazy không thể).
   - Hoặc: giữ một file, nhưng `ChatRuntime.load` giải mã chỉ phần summary bằng cách đọc JSON và bỏ events. Swift không hỗ trợ partial decode native; có thể dùng `JSONSerialization` để lấy summary, nhưng mất type safety. **Không khuyến nghị.**
   - **Khuyến nghị:** tách file events. Migration: khi load, nếu `events.json` chưa tồn tại nhưng `chat.json` có events → tách ra (một lần, đồng bộ trong load, hoặc background).

2. **Trạng thái trong memory:**
   - `ChatRecord.events` hiện luôn đầy. Thêm cờ `eventsLoaded: Bool` (không Codable, runtime only) hoặc suy ra từ `events.isEmpty && fileEventsExists`.
   - Khi `load`, đọc summary file (không events), đặt `events = []`, `eventsLoaded = false`.
   - Khi mở chat (`select`/`restoreChat`), gọi `loadEventsIfNeeded(id)` async, điền `events`, rebuild transcript.
   - `ChatTranscriptCache` rebuild sau khi events sẵn sàng.

3. **Các điểm phụ thuộc events:**
   - `isUntouched`: kiểm `events.isEmpty`. Với lazy, events rỗng không có nghĩa là untouched. Cần thêm cờ `hasEventsOnDisk` hoặc kiểm file tồn tại. **Quan trọng:** không xoá nhầm chat có events chưa load.
   - `cursor`, `replay`, `take`: cần events. Nếu chưa load, cursor = .start. Khi load events xong, cursor đúng.
   - `deleteMessage`: lọc events. Nếu events chưa load, phải load trước.
   - `newChat` reuse untouched: cần biết events rỗng thực sự. Dùng metadata `hasEvents`.
   - `ChatLinkTarget`, `ChatWidgetPublisher`: dùng `records`/`summaries`. Nếu chỉ cần summary, OK. Nếu cần events, load on demand.
   - `CompletedBuilds`: đếm builds từ events chưa đọc. Cần events. → load events cho chat đó trước khi đếm, hoặc đếm từ summary metadata. **Rủi ro:** có thể bỏ sót. Khuyến nghị: load events on demand khi cần CompletedBuilds.

4. **Migration & tương thích ngược:**
   - `ChatStore.load` phải đọc cả format cũ (single file với events) và mới (summary + events).
   - Phiên bản mới lưu summary-only + events file. Khi đọc file cũ, tách events ra file riêng và xoá khỏi summary file (atomic).
   - Giữ `revision` counter để tránh race save.

5. **Rủi ro chính:**
   - Race giữa load events nền và user thao tác (gửi tin, xoá message). Cần serialise per-chat: dùng Task per chat, await trước khi mutate.
   - Memory: giữ events trong memory sau khi load (không unload) để đơn giản. Nếu muốn tiết kiệm RAM, unload khi chat không mở — nhưng transcript cache đã làm điều này. Khuyến nghị: chỉ load on demand, giữ trong memory cho đến khi app thoát (đơn giản, an toàn).

**Tiêu chí dừng:** cold launch nhanh hơn rõ rệt; mở chat cũ hiển thị đúng transcript; gửi/xoá hoạt động; không mất events.

### Phase 4 — Theo dõi 3 project gần nhất (tuỳ chọn)

**Mục tiêu:** nếu người dùng muốn truy cập nhanh 3 project gần nhất.

**Đánh giá:** `ProjectMenuOrder` đã làm ranking. Thêm persisted list chỉ tăng phức tạp và rủi ro stale.

**Khuyến nghị:** **không làm**. Nếu vẫn muốn:
- Lưu `recentProjects: [String]` (tối đa 3) trong UserDefaults, cập nhật khi `switchProject`/mở chat.
- Khi load, nếu danh sách cũ (project đã xoá/đổi tên), fallback về derived ranking.
- Luôn ưu tiên derived ranking nếu persisted list không khớp.

**Rủi ro:** stale, đồng bộ khi xoá project. Cần hook vào `deleteProject` và `forgetDeletedProjects`.

## 5. Thứ tự thực hiện khuyến nghị

1. Phase 0 (đo) — bắt buộc trước.
2. Phase 1 (reconcile nền) — làm ngay, rủi ro thấp.
3. Đánh giá lại số liệu sau Phase 1.
4. Nếu vẫn chậm → Phase 3 (lazy events), bắt đầu từ migration + cờ `hasEvents`, làm từng bước nhỏ, test mỗi bước.
5. Phase 4 — chỉ nếu người dùng thực sự cần.

## 6. Danh sách file sẽ chạm (dự kiến)

**Phase 1:**
- `Apelin/Interface/Chats/ChatRuntime.swift` (load, reconcile)

**Phase 3:**
- `Apelin/Interface/Chats/ChatStore.swift` (load/save/remove, migration)
- `Apelin/Interface/Chats/ChatRuntime.swift` (load, isUntouched, loadEventsIfNeeded, deleteMessage, newChat)
- `Apelin/Interface/Chats/ChatSummary.swift` (metadata hasEvents nếu cần)
- `Apelin/Interface/Root/ChatLinkTarget.swift` (đảm bảo events load khi cần)
- `Apelin/Interface/Chats/ChatWidgetPublisher.swift` (nếu dùng events)
- `Apelin/Interface/Chats/ChatTranscriptCache.swift` (rebuild sau lazy load)
- Tests: `Tests/ChatTranscript/*` (nếu có) + thêm test migration.

**Phase 4:**
- `Apelin/Interface/Root/SidebarController.swift` (recent list)
- `Apelin/Interface/Chats/ChatRuntime.swift` (hook open/delete)

## 7. Kiểm thử (regression)

- Cold launch với 0 chat, 1 chat, nhiều chat (lịch sử dài).
- Mở chat cũ → transcript đầy đủ, cursor đúng, gửi tin mới không trùng.
- Chat đang working khi relaunch → reconcile đặt isWorking đúng.
- Xoá message trong chat chưa load events → phải load trước, không crash.
- `isUntouched` cleanup không xoá nhầm chat có events.
- Migration: file cũ (single) → đọc được, tách events, lưu mới.
- `ChatLinkTarget`/widget vẫn hoạt động.
- `CompletedBuilds` vẫn đếm đúng.
- Reconciliation nền không race với user mở chat.

## 8. Những gì KHÔNG làm

- Không thay đổi `WelcomeFlow` (chỉ onboarding).
- Không lazy-load project scan (đã nhẹ).
- Không thêm persisted list 3 project trừ khi có nhu cầu cụ thể.
- Không đổi `isLoaded`/`isReconciled` semantics.
- Không build/install/push trừ khi người dùng yêu cầu.

## 9. Câu hỏi cần người dùng quyết định

1. Có đo lường (Phase 0) trước không, hay làm luôn Phase 1?
2. Phase 3 (lazy events) có làm không, hay Phase 1 đủ?
3. Có muốn persisted list 3 project (Phase 4) không?
4. Ngưỡng "recent" cho Phase 3: bao nhiêu chat load đầy đủ lúc startup (khuyến nghị 5)?
