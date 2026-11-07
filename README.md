# AI Feed Monitor

Mỗi ngày tự động đọc ~24 nguồn (arXiv, blog công ty AI, blog chuyên gia, bản tin, tin bảo mật, CISA KEV, Hacker News, Reddit),
lọc theo từ khóa, rồi gửi **một bản tin** qua Telegram và/hoặc Email. Bản tin cũng được lưu thành file `.md` trong `digests\`
để bạn dùng làm sổ tay nghiên cứu.

Không cần cài thêm gì — chạy bằng PowerShell có sẵn trên Windows.

## Cấu trúc

| File | Vai trò |
|---|---|
| `monitor.ps1` | Chương trình chính |
| `config.json` | Danh sách nguồn, từ khóa, giới hạn — **sửa file này để tùy chỉnh** |
| `secrets.json` | Token Telegram / mật khẩu email (tự tạo từ `secrets.example.json`, **không chia sẻ**) |
| `install-task.ps1` | Đăng ký chạy tự động hằng ngày bằng Task Scheduler |
| `data\seen.json` | Ghi nhớ các bài đã gửi (để không gửi trùng) |
| `digests\` | Lưu bản tin mỗi ngày dạng Markdown |
| `logs\monitor.log` | Nhật ký chạy và lỗi |

## Cài đặt (khoảng 5 phút)

### 1. Tạo bot Telegram
1. Mở Telegram, tìm **@BotFather** → gửi `/newbot` → đặt tên → nhận **token** (dạng `123456:ABC...`).
2. Mở chat với bot vừa tạo, bấm **Start** và gửi một tin bất kỳ.
3. Mở trình duyệt: `https://api.telegram.org/bot<TOKEN>/getUpdates` → tìm `"chat":{"id": ...}` → đó là **chatId**.

### 2. Điền secrets
```powershell
Copy-Item secrets.example.json secrets.json
notepad secrets.json      # dán botToken và chatId
```
(Muốn nhận qua Email thay/kèm Telegram: điền phần `email`. Với Gmail dùng `smtp.gmail.com`, port `587`
và **App Password** — không dùng mật khẩu đăng nhập thường.)

### 3. Thử
```powershell
.\monitor.ps1 -TestSend   # nhận được tin "Kết nối thành công" là OK
.\monitor.ps1 -Check      # xem nguồn nào đọc được / bị lỗi
.\monitor.ps1 -DryRun     # xem trước bản tin, không gửi
```

### 4. Chạy tự động mỗi ngày
```powershell
.\install-task.ps1                      # 07:00 mỗi ngày
.\install-task.ps1 -Times 07:00,19:00   # 2 lần/ngày
.\install-task.ps1 -Remove              # gỡ
```
Nếu máy tắt đúng giờ hẹn, tác vụ sẽ chạy ngay khi máy bật lại.

> Lần đầu chạy thật sẽ gửi bài của ~3 ngày gần nhất. Nếu chỉ muốn nhận bài từ hôm nay trở đi, chạy `.\monitor.ps1 -Init` trước.

## Tùy chỉnh `config.json`

- **Thêm nguồn**: thêm một dòng vào `feeds`:
  ```json
  { "name": "Tên hiển thị", "category": "Nhóm", "url": "https://.../feed", "filter": true, "max": 5 }
  ```
  - `filter: true` — chỉ lấy bài khớp từ khóa (nên bật cho nguồn nhiều bài như arXiv, tin bảo mật).
  - `keywords` (tùy chọn) — từ khóa riêng cho nguồn đó, thay cho danh sách chung.
  - `enabled: false` — tạm tắt nguồn.
- **Từ khóa chung**: sửa mảng `keywords`. Không phân biệt hoa/thường, tự khớp số nhiều (`agent` ↔ `agents`).
- `lookbackDays` — bỏ qua bài cũ hơn N ngày.
- **Số bài nổi bật mỗi mục**: `maxPerCategory` (tối đa, mặc định 5), `minPerCategory` (tối thiểu nếu có, mặc định 2),
  `minScore` (điểm tối thiểu để được coi là nổi bật), `maxPerSourceInCategory` (mỗi nguồn tối đa mấy bài trong một mục).
  Điểm = số từ khóa khớp + 2 × số từ khóa có trong tiêu đề + `weight` của nguồn (tùy chọn, đặt trong từng feed).
- `showSummary` / `summaryMaxChars` — hiện câu đầu tiên của tóm tắt dưới mỗi bài.
- `maxTags` — số từ khóa (#tag) tối đa hiện cạnh mỗi bài.
- `categoryIcons` — biểu tượng cho từng mục; mục mới chưa có biểu tượng sẽ hiện `•`.
- `arxivSkipRevisions` — bỏ các bài arXiv chỉ là bản sửa của bài cũ.

## Cách đọc bản tin

- Tin nhắn đầu là **tổng quan**: số bài nổi bật của từng mục.
- Mỗi mục là một tin nhắn riêng; bài được xếp theo **mức liên quan** (khớp nhiều từ khóa nhất lên đầu).
- Mỗi mục chỉ gửi 2–5 bài điểm cao nhất lên Telegram; phần còn lại ghi "… và N bài khác".
  **Không bài nào bị mất** — tất cả nằm trong `digests\<ngày>_<giờ>.md` (bài đã gửi được đánh dấu ⭐).
- Cùng một bài xuất hiện ở nhiều nguồn (vd. arXiv và Hugging Face) chỉ được gửi một lần.

Tìm RSS của một trang: thử thêm `/feed`, `/rss`, `/feed.xml`, `/atom.xml`, `/index.xml` vào cuối địa chỉ. Bản tin Substack luôn là `https://<tên>.substack.com/feed`.

## Ghi chú về nguồn

- **CISA KEV** lấy từ repo chính thức `cisagov/kev-data` trên GitHub (trang cisa.gov chặn truy cập tự động).
- **Anthropic News** và **Hugging Face Daily Papers** không có RSS chính thức — đang dùng feed do bên thứ ba tạo
  (`Olshansk/rss-feeds`, `papers.takara.ai`); có thể ngừng hoạt động bất cứ lúc nào. Chạy `-Check` để kiểm tra.
- Nguồn nào lỗi sẽ được ghi ở cuối bản tin và trong `logs\monitor.log`, các nguồn còn lại vẫn chạy bình thường.
