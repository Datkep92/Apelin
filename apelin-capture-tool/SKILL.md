# Apelin Capture — Mở trang web và bắt API calls

## Khi nào dùng

Dùng **Apelin Capture** thay Safari khi Sếp yêu cầu phân tích API, HTTP, GET/POST, xem headers/token, hoặc gọi lại một request.

## Tại sao tốt hơn Safari

- Bắt **mọi** `fetch`/`XMLHttpRequest` kèm headers (kể cả `Authorization`, cookie…), body request và body response.
- Agent đọc captures qua **file JSON**, không cần mở app thủ công.
- Cookies được lưu bền vững trong WKWebView — đăng nhập web 1 lần, sau đó gọi API.
- Agent hoàn toàn kiểm soát bằng code.

## Vị trí dữ liệu

- **Thư mục app**: `/var/mobile/Documents/`
  - `captures-full.json` — captures đầy đủ (JSON, 7 trường chính)
  - `apelin-bridge/status.txt` — trạng thái (launch / open / web process terminated)
  - `apelin-bridge/captures.ndjson` — định dạng cũ (hiện rỗng, không dùng)

## Cách mở URL

**Bước 1.** Ghi URL vào `url.txt`:

```sh
echo "https://example.com/api/endpoint" > /var/mobile/Documents/apelin-bridge/url.txt
```

Chỉ chấp nhận `http` và `https`. File này nằm cùng thư mục với `status.txt` và `captures.ndjson`.

**Bước 2.** Mở app:

```sh
icli app launch com.apelin.capture
```

**Bước 3.** Đợi trang tải xong (khoảng 3–10 giây tuỳ mạng).

**Bước 4.** Đọc captures.

> **Lưu ý:** App sẽ xóa `captures-full.json` cũ khi mở URL mới. Nếu cần giữ captures cũ, sao chép trước.

## Cách đọc captures

Đọc bằng Python 3 (JSON, không dùng `cat` vì file có thể lớn):

```python
import json
with open('/var/mobile/Documents/captures-full.json') as f:
    data = json.load(f)
captures = data.get('captures', []) if isinstance(data, dict) else data
print(f'Tổng: {len(captures)}')
for c in captures:
    print(f"  {c['method']} {c['url'][:80]}  [{c.get('status',0)}] {c.get('ms',0)}ms")
```

**Cấu trúc mỗi capture (7 trường chính):**

| Trường | Mô tả |
|---|---|
| `url` | URL đầy đủ |
| `method` | GET, POST, PUT… |
| `kind` | `fetch` hoặc `xhr` |
| `status` | Mã HTTP (0 = lỗi) |
| `ms` | Thời gian phản hồi (ms) |
| `reqHeaders` | Dict headers request (kể cả Authorization, Cookie) |
| `resHeaders` | Dict headers response |
| `reqBody` | Body request (string hoặc null) |
| `resBody` | Body response (string hoặc null) |
| `redacted` | false = đầy đủ, true = đã che |
| `replayable` | true = có thể gọi lại |

**Lọc nhanh:**

```python
# API calls (bỏ qua hình ảnh, CSS, JS tĩnh)
api = [c for c in captures if '/api/' in c['url'] or 'json' in c.get('resHeaders',{}).get('content-type','')]
# POST requests
posts = [c for c in captures if c['method'] == 'POST']
# Lỗi
errors = [c for c in captures if c.get('status',0) >= 400 or c.get('status',0) == 0]
```

## Cách gọi lại một request

**Từ captures, xây curl:**

```sh
curl -X POST "https://example.com/api/endpoint" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer TOKEN" \
  -d '{"key":"value"}'
```

Hoặc gọi bằng `apelin_http_request`:

```python
# Ví dụ: gọi lại một capture
c = captures[0]
headers = c.get('reqHeaders', {})
method = c.get('method', 'GET')
url = c.get('url', '')
body = c.get('reqBody')
# Dùng apelin_http_request với method, url, headers, body
```

> **Quan trọng:** Khi gọi lại, không dùng cookie từ trình duyệt — captures đã ghi `Authorization` header rồi. Nếu API cần session cookie, dùng `curl` trong `shell_run` với `--cookie`.

## Giới hạn đã biết

- Web process có thể bị terminate trên môi trường rootless — captures vẫn được ghi.
- Mở URL mới sẽ xóa captures cũ. Sao chép trước nếu cần giữ.
- Không xem được giao diện web (chỉ bắt network calls). Dùng Safari khi cần nhìn giao diện hoặc tương tác tay.
- Không theo dõi redirect chain — captures ghi mỗi request riêng.
- Không capture WebSocket, gRPC hay các giao thức khác HTTP.
- App có thể mở mặc định Google Search nếu `url.txt` rỗng.

## Ví dụ dùng thực tế

**Yêu cầu:** "Phân tích API của trang example.com"

1. Mở trang: `echo "https://example.com" > /var/mobile/Documents/apelin-bridge/url.txt` → `icli app launch com.apelin.capture`
2. Chờ 5 giây
3. Đọc captures, lọc API calls
4. Trình bày: method, URL, headers chính, body → phân tích endpoint nào làm gì
5. Nếu cần: xây curl để test lại
