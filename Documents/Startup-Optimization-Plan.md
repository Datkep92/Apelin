# Kế hoạch tối ưu khởi động — Phiên bản thực thi (v2)

> Trạng thái: kế hoạch đầy đủ, sẵn sàng triển khai. Chưa sửa code.
> Branch `main` tại `ba964c7`. Phạm vi: Phase 1 + Phase 3 (+ Phase 0 đo lường). Phase 4 không làm (xem §11).
> Mục tiêu: giảm cold launch → UI usable; giữ nguyên logic; mỗi bước có thể build + test độc lập.

---

## 0. Quyết định chốt (không hỏi lại)

| # | Quyết định | Lý do |
|---|---|---|
| D1 | Làm Phase 1 + Phase 3. | Giá trị cao nhất; Phase 1 rủi ro thấp, Phase 3 rủi ro có kiểm soát. |
| D2 | Phase 0 (đo) gộp vào Phase 1: thêm log timing trước khi sửa, giữ log sau sửa để so sánh. | Một lần đo, không tách PR. |
| D3 | Lazy events: tách file `Chats/<id>.events.json`; summary file `Chats/<id>.json` chứa `ChatRecord` với `events = []`. | Migration rõ ràng; đọc summary không phải giải mã events. |
| D4 | Không unload events khỏi memory sau khi load. | Đơn giản, an toàn; transcript cache đã quản lý hiển thị. |
| D5 | Cờ `eventsLoaded` là thuộc tính runtime (không Codable). | Tránh thay đổi format. |
| D6 | `hasEventsOnDisk` suy ra từ `eventsLoaded || fileEventsExists`. | Để `isUntouched` đúng trước khi load events. |
| D7 | Load events on demand cho chat được chọn/mở; chat đang working khi relaunch load events trước reconcile. | Đảm bảo cursor/replay đúng. |
| D8 | Không làm Phase 4 (persisted 3 project). | Ranking đã có; thêm persisted list tăng stale risk. |
| D9 | Mỗi phase là một commit riêng, build CI sau mỗi phase. | Dễ rollback, dễ bisect. |
| D10 | Không thay đổi `isLoaded`/`isReconciled` semantics. | Gating hiện có không đổi. |

---

## 1. Kiến trúc hiện tại (tóm tắt để đối chiếu)

### 1.1 Dòng chảy startup

```
AppDelegate.didFinishLaunching
  └─ SceneDelegate
       └─ RootInterfaceController.init
            ├─ WelcomeFlow.shouldPresent? → onboarding (chỉ người mới)
            ├─ ProjectSummary.load (detached, nhẹ)
            ├─ ChatRuntime.load(keeping: selected)  ← BOTTLENECK
            │    ├─ store.load() → [ChatRecord] (đọc mọi file, gồm events)
            │    ├─ cleanup untouched
            │    ├─ forget deleted projects
            │    ├─ isLoaded = true; onChange?()   ← UI usable ở đây (lý thuyết)
            │    ├─ await agentList()             ← chặn tiếp
            │    ├─ reconcile loop
            │    ├─ isReconciled = true; onChange?()
            │    └─ adopt live sessions
            └─ restoreChatIfReady (gated: !WelcomeFlow, isLoaded, !isResolvingLink)
```

Sidebar: `hasLoadedProjects` + `onProjectsLoaded` phối hợp project list với chat restore.

### 1.2 Điểm phụ thuộc `records`/`events`

| Nơi dùng | Cần events? | Ghi chú |
|---|---|---|
| `SidebarController.refresh` | Chỉ summary | OK với lazy. |
| `RootInterfaceController.restoreChatIfReady` | summary | OK. |
| `ChatController` (transcript) | events | Load on demand khi mở chat. |
| `isUntouched` | events.isEmpty | Cần `hasEventsOnDisk`. |
| `newChat` (reuse untouched) | events.isEmpty | Cần `hasEventsOnDisk`. |
| `deleteMessage` | events | Load trước. |
| `ChatLinkTarget` | summary + có thể events | Load on demand. |
| `ChatWidgetPublisher` | summary | OK. |
| `CompletedBuilds` (onBuildsCompleted) | events chưa đọc | Load events cho chat đó trước khi đếm. |
| `cursor`/`replay`/`take` | events | Load on demand. |

### 1.3 `ChatStore` hiện tại

- `load()`: đọc `Chats/*.json`, decode `ChatRecord` (gồm events).
- `save(record, revision)`: encode toàn bộ `ChatRecord` (gồm events) vào `Chats/<id>.json`.
- `remove(id)`: xoá file.

---

## 2. Phase 1 — Reconciliation không chặn UI

### 2.1 Mục tiêu

`isLoaded = true; onChange?()` trả về nhanh hơn; reconciliation chạy nền, không chặn restore.

### 2.2 Thay đổi chi tiết

**File:** `Apelin/Interface/Chats/ChatRuntime.swift`

**Vị trí:** hàm `load(keeping:)`, dòng ~89-133.

**Trước:**
```swift
isLoaded = true
onChange?()
let live = await (try? ApelinService.app.agentList().sessions) ?? []
for record in records.values { ... }
isReconciled = true
onChange?()
for session in live { adopt(...) }
```

**Sau:**
```swift
isLoaded = true
onChange?()

// reconciliation nền, không chặn UI
reconciliationTask = Task { @MainActor in
    // Phase 0 timing log
    let t0 = ContinuousClock.now
    let live = await (try? ApelinService.app.agentList().sessions) ?? []
    for record in records.values {
        if let session = live.first(where: { $0.sessionID == record.sessionID }) {
            records[record.summary.id]?.reopen(as: session.task)
            follow(record.summary.id, task: session.task)
        } else if record.summary.isWorking {
            records[record.summary.id]?.summary.isWorking = false
            changed(record.summary.id)
        }
    }
    isReconciled = true
    onChange?()
    for session in live {
        adopt(ChatAdoption.record(session: session, records: Array(records.values)))
    }
    // Phase 0 timing log
    os_log(.info, subsystem: "wiki.qaq.apelin", "reconcile took %{public}@", String(describing: ContinuousClock.now - t0))
}
```

**Thêm property:**
```swift
private var reconciliationTask: Task<Void, Never>?
```

**Guard tránh chạy trùng** (nếu `load` gọi lại):
```swift
guard reconciliationTask == nil else { return }
```
ở đầu `load` sau store.load? Thực ra `load` chỉ gọi một lần. Thêm guard nhẹ:
```swift
if reconciliationTask != nil { return }
```
trước `isLoaded = true`? Không, vì load chưa xong. Thêm ở đầu hàm:
```swift
guard !isLoaded else { return }
```
(đã ngầm; thêm explicit).

### 2.3 Timing log Phase 0

Thêm `os_log` (import os) tại:
- bắt đầu `load`: "load start, chats=%d" (chưa biết số; log sau store.load)
- sau `store.load()`: "store.load done: n=%d, bytes=..." (bytes không dễ; log n và thời gian)
- sau cleanup untouched
- sau forget deleted
- `isLoaded`
- reconcile start/end
- adopt end

Format: `os_log(.info, subsystem: "wiki.qaq.apelin", "startup: %{public}@", msg)`.

### 2.4 Rủi ro & xử lý

- **Race reopen:** chat đang mở trước reconcile → `follow` gọi sau. Nếu user gửi tin trước reconcile, `sending`/cursor có thể lệch. Mitigation: `reopen(as:)` chỉ gọi khi có live session; nếu chat đã follow thì `task` đã set. Kiểm tra `records[id]?.task == nil` trước reopen? Hiện tại `reopen` guard `self.task != task`. OK.
- **`isReconciled` false lâu hơn:** code chờ `isReconciled`? Grep. Nếu có, giữ await? Kiểm tra: `grep -rn isReconciled`. (Sẽ làm khi triển khai.) Nếu có caller blocking, cân nhắc `await reconciliationTask?.value` ở caller đó thay vì block load.
- **adopt live sessions:** chạy sau reconcile trong cùng Task. OK.

### 2.5 Tiêu chí hoàn thành Phase 1

- Cold launch: `isLoaded` + `onChange` sớm hơn (đo bằng log).
- Reconcile hoàn tất trong nền, `isReconciled` true sau.
- Không crash, không mất chat working state.
- CI xanh.

---

## 3. Phase 3 — Lazy-load events

### 3.1 Mục tiêu

Startup chỉ đọc summary (nhẹ). Events tải khi mở chat. Bảo toàn transcript/cursor/replay/sending.

### 3.2 Thay đổi lưu trữ

#### 3.2.1 `ChatStore.load()` (file `ChatStore.swift`)

**Hiện tại:**
```swift
return try FileManager.default.contentsOfDirectory(...)
    .filter { $0.pathExtension == "json" }
    .compactMap { url in
        guard UUID(...) != nil, path canonical else { return nil }
        return try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: url))
    }
```

**Mới:**
```swift
// đọc summary file; events rỗng; eventsLoaded=false
// migration: nếu file cũ chứa events, tách ra
```

Chi tiết:
- Duyệt `Chats/*.json`.
- Với mỗi file `<id>.json`:
  - Decode `ChatRecord`.
  - Nếu `record.events` không rỗng (file cũ) → ghi `Chats/<id>.events.json` với events (nếu chưa tồn tại), sau đó set `record.events = []`.
  - Đặt `record.eventsLoaded = false` (runtime, không Codable — thêm vào `ChatRecord`? Xem §3.2.3).
  - Trả về record.
- Nếu `Chats/<id>.events.json` tồn tại mà summary file events rỗng → eventsLoaded=false, events=[] (load on demand).
- Nếu summary file events rỗng và không có events file → eventsLoaded=true (thực sự rỗng).

**Vấn đề:** `eventsLoaded` là runtime flag, không nên nằm trong `ChatRecord` Codable? Có thể nằm, với default false và không ảnh hưởng file cũ (absent → default). Nhưng khi save, nếu serialize eventsLoaded=true vào file, file cũ đọc được (default false) — không sao. Tuy nhiên cleaner: thêm vào `ChatRecord` với `var eventsLoaded: Bool = false` (Codable default). Khi save, serialize. Khi load file cũ không có field → false. OK, chấp nhận.

Nhưng `isUntouched` cần biết "thực sự rỗng" vs "chưa load". Dùng `hasEventsOnDisk` = `eventsLoaded || FileManager.exists(eventsFile)`. Nếu chưa load và file events tồn tại → có events → not untouched. Nếu file events không tồn tại → rỗng → untouched có thể.

#### 3.2.2 `ChatStore.save(record, revision)`

**Hiện tại:** encode toàn bộ record vào `<id>.json`.

**Mới:**
- Encode summary-only record (events=[]) vào `<id>.json`.
- Encode `record.events` vào `<id>.events.json` nếu `eventsLoaded` (hoặc luôn ghi nếu events không rỗng).
- Nếu events rỗng và file events tồn tại → xoá file events (dọn).
- Giữ `revision` counter cho summary file. Events file có thể ghi cùng revision hoặc riêng; đơn giản: ghi events file mỗi save (nếu loaded). Race: save đồng bộ qua actor ChatStore, OK.

**Chú ý:** `save` hiện là actor method, đã serialise. Thêm ghi events file trong cùng method.

#### 3.2.3 `ChatStore` thêm method

```swift
func loadEvents(for id: UUID) throws -> [TaskEvent] {
    let url = folder.root.appendingPathComponent("Chats/\(id.uuidString).events.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([TaskEvent].self, from: Data(contentsOf: url))
}

func removeEvents(for id: UUID) throws {
    try? FileManager.default.removeItem(at: folder.root.appendingPathComponent("Chats/\(id.uuidString).events.json"))
}
```

`remove(id)` cũng gọi `removeEvents`.

#### 3.2.4 `ChatRecord` thêm field

```swift
/// Whether this record's `events` have been read from disk. Runtime flag;
/// absent in older files (defaults to false, and `hasEventsOnDisk` checks
/// the events file). Absent from a record created in memory.
var eventsLoaded: Bool = false
```

Thêm vào struct. Codable default OK.

#### 3.2.5 `ChatRuntime` thay đổi

**Thêm:**
```swift
private var loadingEvents: [UUID: Task<Void, Never>] = [:]

func loadEventsIfNeeded(_ id: UUID) async {
    guard let record = records[id], !record.eventsLoaded else { return }
    if let task = loadingEvents[id] { await task.value; return }
    let task = Task { @MainActor in
        do {
            let events = try await store.loadEvents(for: id)  // store là actor; gọi await
            records[id]?.events = events
            records[id]?.eventsLoaded = true
            // rebuild transcript cache? ChatTranscriptCache handles via events
            changed(id)
        } catch {
            onError?(error)
        }
        loadingEvents[id] = nil
    }
    loadingEvents[id] = task
    await task.value
}

var hasEventsOnDisk(_ id: UUID) -> Bool {
    guard let record = records[id] else { return false }
    if record.eventsLoaded { return !record.events.isEmpty }
    // chưa load: kiểm tra file
    return FileManager.default.fileExists(atPath: folder...events.json)
}
```

**Lưu ý:** `store` là `ChatStore` actor; `loadEvents` là async. `folder` access: `store` có folder private. Thêm helper `store.eventsFileExists(id)` hoặc expose. Đơn giản: thêm method `store.hasEventsFile(id) -> Bool`.

**`isUntouched`:**
```swift
private func isUntouched(_ record: ChatRecord) -> Bool {
    let hasEvents = record.eventsLoaded ? !record.events.isEmpty : hasEventsOnDisk(record.summary.id)
    return !hasEvents && record.sessionID == nil && record.task == nil && opening[...] == nil
        && record.sending == nil && record.draft.text.isEmpty && record.draft.attachments.isEmpty
        && !record.summary.isPinned && record.summary.isNamedByReader != true
}
```

Nhưng `hasEventsOnDisk` cần store; `isUntouched` hiện là sync private. Đổi thành async? Nó được gọi trong `load` (sync loop) và `newChat`. Để giữ sync, dùng `record.eventsLoaded ? !record.events.isEmpty : FileManager.default.fileExists(atPath: eventsPath)`. Cần path. Thêm computed property trên `ChatRecord`? `ChatRecord` không biết folder. 

Giải pháp: thêm helper static trong `ChatRuntime`:
```swift
private func eventsFileExists(for id: UUID) -> Bool {
    FileManager.default.fileExists(atPath: DataFolder.app.root.appendingPathComponent("Chats/\(id.uuidString).events.json").path)
}
```
Và `isUntouched` thành:
```swift
private func isUntouched(_ record: ChatRecord) -> Bool {
    let hasEvents = record.eventsLoaded ? !record.events.isEmpty : eventsFileExists(for: record.summary.id)
    ...
}
```

**`newChat`:** reuse untouched dùng `isUntouched` → đã đúng.

**`deleteMessage`:** cần events. Thêm `await loadEventsIfNeeded(chatID)` trước khi lọc. `deleteMessage` hiện sync. Đổi thành async? Caller? Kiểm tra callers. Nếu nhiều sync callers, giữ sync và load sync? Store.loadEvents là sync-capable (đọc file). Có thể làm sync version:
```swift
func loadEventsSyncIfNeeded(_ id: UUID) {
    guard let record = records[id], !record.eventsLoaded else { return }
    if let events = try? store.loadEventsSync(for: id) {
        records[id]?.events = events
        records[id]?.eventsLoaded = true
    }
}
```
Và `ChatStore` thêm sync method (non-actor) hoặc gọi `try await` trong async context. `deleteMessage` callers cần kiểm tra. Nếu async OK, đổi async và cập nhật callers. **Khuyến nghị:** kiểm tra callers trước; nếu sync nhiều, dùng sync load. Tôi sẽ ghi rõ trong plan: "kiểm tra callers của deleteMessage; nếu chỉ UI action async, đổi async; nếu sync, dùng loadEventsSyncIfNeeded".

**`ChatController` mở chat:** khi select chat, gọi `await runtime.loadEventsIfNeeded(id)` trước khi rebuild transcript. Cần xác định điểm: `ChatController` có `chat` property; khi set, load events. Thêm trong `syncViewedChat` hoặc `onSelect`. Kiểm tra `RootInterfaceController` flow.

**`CompletedBuilds`:** khi đếm builds từ events, gọi `loadEventsIfNeeded` trước. Tìm nơi gọi `onBuildsCompleted` / `CompletedBuilds`. Grep `onBuildsCompleted`.

**`ChatLinkTarget`:** khi adopt linked chat, load events? Chỉ cần summary để show. Nếu cần events (transcript), load on demand khi mở.

**`reopen(as:)` / `cursor`:** nếu events chưa load, `events.isEmpty` → `cursor = .start` (replay nil). Khi load events sau, cursor đúng. Nhưng `reopen` được gọi trong reconcile (Phase 1, nền) — có thể gọi trước khi events load. Mitigation: trong reconcile, với chat working, gọi `await loadEventsIfNeeded(id)` trước `reopen`. Vì reconcile là async Task, OK.

**`take`/`missedEnd`:** cần events loaded. Nếu events chưa load và batch đến, `cursor=.start` → take all → events += batch (đúng, vì events rỗng). Nhưng events cũ chưa load → mất lịch sử! Nguy hiểm. Mitigation: khi chat đang working và đang follow, phải load events trước khi `take`. Trong `follow`, gọi `loadEventsIfNeeded` trước `take`. Kiểm tra `follow` function.

### 3.3 Migration

**Lần đầu chạy version mới:**
- `store.load()` phát hiện file cũ có events → ghi `events.json`, set events=[] trong summary file, save summary file (atomic).
- Migration sync trong `load()` (chấp nhận chậm lần đầu, nhưng chỉ một lần).
- Để an toàn: ghi events file trước, rồi summary file. Nếu crash giữa chừng, lần sau: events file tồn tại, summary file vẫn có events → re-migrate (ghi đè events file, set events=[]). Idempotent.

**Backward compat:** version cũ đọc file mới: summary file events=[] → chat rỗng (mất lịch sử hiển thị, nhưng events file bị bỏ qua). Đây là one-way migration; chấp nhận (không support downgrade). Ghi chú trong release notes.

### 3.4 Concurrency safety

- `loadingEvents: [UUID: Task]` đảm bảo một load per chat.
- `ChatStore` actor serialise save/load. `loadEvents` actor method.
- `loadEventsIfNeeded` là async, gọi từ @MainActor context. OK.
- Khi user gửi tin trước khi events load xong: `submit` append sending, `changed` → save. Save ghi events file với events=[] (chưa load) → **mất events cũ!** Nguy hiểm. Mitigation: trong `persist`/`changed`, nếu `!eventsLoaded`, gọi `loadEventsIfNeeded` trước save. Hoặc: `persist` async load events trước khi save. **Bắt buộc:** mọi path dẫn đến save phải đảm bảo events loaded. Thêm guard trong `persist`:
```swift
func persist(_ id: UUID, urgent: Bool = false) {
    Task { @MainActor in
        await loadEventsIfNeeded(id)
        // existing save logic
    }
}
```
Nhưng `persist` hiện sync scheduling. Cần refactor sang async. Xem code `persist` (dòng ~? search). Sẽ xử lý khi triển khai: tìm `func persist`.

### 3.5 Tiêu chí hoàn thành Phase 3

- Cold launch: `store.load()` nhanh hơn (đo bằng log).
- Mở chat cũ: transcript đầy đủ, cursor đúng.
- Gửi tin mới: không trùng, không mất lịch sử.
- Xoá message: load trước, không crash.
- `isUntouched` cleanup không xoá nhầm.
- Migration file cũ → mới thành công.
- Reconciliation nền (Phase 1) vẫn đúng.
- CI xanh.

---

## 4. Thứ tự triển khai (commit nhỏ)

| Bước | Commit | Nội dung | Build |
|---|---|---|---|
| 1 | Phase 0+1 | Timing log + reconcile nền | CI |
| 2 | Phase 3a | `ChatRecord.eventsLoaded` + `ChatStore.loadEvents`/`hasEventsFile` + `removeEvents` | CI |
| 3 | Phase 3b | `ChatStore.load()` migration + summary-only save | CI |
| 4 | Phase 3c | `ChatRuntime.loadEventsIfNeeded` + `hasEventsOnDisk` + `isUntouched` fix | CI |
| 5 | Phase 3d | Load events on chat open + follow/take safety + persist guard | CI |
| 6 | Phase 3e | deleteMessage/CompletedBuilds/ChatLinkTarget safety | CI |
| 7 | Test + cleanup | Tests migration + timing comparison | CI |

Mỗi bước: build CI, nếu đỏ sửa ngay (theo luật CI).

---

## 5. Danh sách file sẽ chạm

**Phase 1:**
- `Apelin/Interface/Chats/ChatRuntime.swift` (load, reconcile, property reconciliationTask, timing log)

**Phase 3:**
- `Apelin/Interface/Chats/ChatStore.swift` (load, save, remove, loadEvents, hasEventsFile, removeEvents)
- `Apelin/Interface/Chats/ChatRuntime.swift` (eventsLoaded usage, loadEventsIfNeeded, hasEventsOnDisk, isUntouched, persist guard, follow/take safety, deleteMessage, newChat)
- `Apelin/Interface/Chats/ChatSummary.swift` (nếu cần metadata; khuyến nghị không đổi)
- `Apelin/Interface/Root/ChatLinkTarget.swift` (load events khi cần)
- `Apelin/Interface/Chats/ChatController.swift` (load events on open)
- `Apelin/Interface/Chats/ChatWidgetPublisher.swift` (kiểm tra, có thể không đổi)
- Tests: `Tests/ChatTranscript/*` + thêm `Tests/ChatTranscript/ChatStoreMigrationCheck.swift` (nếu harness cho phép)

**Không chạm:** `ProjectSummary`, `SidebarController` (chỉ đọc summaries, OK), `WelcomeFlow`.

---

## 6. Kiểm thử regression (chi tiết)

### 6.1 Startup
- Cold launch 0 chat, 1 chat, 10+ chat (lịch sử dài).
- Log: `store.load` thời gian trước/sau.
- UI usable sau `isLoaded` (Phase 1): reconcile chạy nền.

### 6.2 Lazy events
- Mở chat cũ → transcript đầy đủ.
- Cursor đúng: gửi tin mới không trùng lặp, không mất lịch sử.
- Chat đang working khi relaunch → reconcile reopen, events load trước follow, transcript đúng.
- Xoá message trong chat chưa load events → load trước, không crash, transcript rebuild.
- `isUntouched` cleanup: chat có events (chưa load) không bị xoá.
- `newChat` reuse untouched: không reuse chat có events.

### 6.3 Migration
- File cũ (events trong summary) → đọc được, tách events, lưu mới.
- Chạy lại lần 2 → không re-migrate (idempotent).
- File mới → đọc bình thường.

### 6.4 Concurrency
- User gửi tin trước khi events load xong → persist guard load events trước save → không mất lịch sử.
- Hai chat load events đồng thời → `loadingEvents` dedup.
- Reconcile nền + user mở chat → load events trong reconcile trước reopen.

### 6.5 Khác
- `ChatLinkTarget` / widget vẫn hoạt động.
- `CompletedBuilds` đếm đúng.
- `deleteProject` xoá events file.
- `forgetDeletedProjects` OK.

### 6.6 Build/CI
- `make check` (nếu chạy được) hoặc CI.
- Swift compile, tests.

---

## 7. Rollback

- Mỗi phase là commit riêng → revert commit.
- Nếu Phase 3 gây vấn đề, revert về sau Phase 1; dữ liệu đã migrate (events file) vẫn đọc được bởi version mới; version cũ không đọc events file (chấp nhận mất hiển thị, không mất file).
- Backup trước migration: không cần (idempotent, file cũ giữ nguyên cho đến khi migrate).

---

## 8. Rủi ro còn lại & giảm thiểu

| Rủi ro | Giảm thiểu |
|---|---|
| Persist guard async làm `persist` phức tạp | Kiểm tra callers persist; nếu sync nhiều, dùng loadEventsSyncIfNeeded. |
| `follow`/`take` trước khi events load | Load events trong follow trước take. |
| Migration crash giữa chừng | Idempotent: re-migrate. |
| Version cũ không đọc events file | Documented; không support downgrade. |
| `isUntouched` sai trước load | `hasEventsOnDisk` check file. |

---

## 9. Quyết định đã chốt theo khuyến nghị (không còn câu hỏi)

| # | Quyết định | Giá trị chốt |
|---|---|---|
| Q1 | Giữ timing log trong bản release? | **Giữ** — os_log `.info`, không ảnh hưởng perf. |
| Q2 | Ngưỡng "recent" load đầy đủ lúc startup? | **0** — load on demand hoàn toàn; chỉ load events cho chat đang working khi relaunch. |
| Q3 | Làm Phase 0 đo lường? | **Làm** — gộp vào Phase 1, để có số liệu so sánh trước/sau. |

→ Kế hoạch sẵn sàng triển khai. Không còn câu hỏi mở.

---

## 10. Phase 4 — Persisted 3 project (KHÔNG làm)

**Lý do không làm:**
- `ProjectMenuOrder.split` đã xếp top 5 theo `lastInteraction` hoặc ngày tạo.
- Persisted list tăng stale risk (xoá project, đổi tên).
- Giá trị thấp so với complexity.

**Nếu sau này cần:** lưu `recentProjects: [String]` trong UserDefaults, cập nhật khi switchProject, fallback derived ranking. Hook deleteProject + forgetDeletedProjects.

---

## 11. Ghi chú cho người thực thi

- Đọc `AGENTS.md` §9 trước khi bắt đầu.
- Mỗi bước commit riêng, push CI, theo luật CI (đỏ → sửa ngay → push lại).
- Không build/install trừ khi người dùng yêu cầu.
- Sau mỗi phase: cập nhật §9 bảng trạng thái + §8 log.
- Nếu gặp lỗi compile/runtime: báo cáo, không đoán.
