# Bot Telegram ra lệnh + lịch chạy chính xác (Cloudflare Worker)

Worker này chạy miễn phí trên Cloudflare, không cần bật máy:

- Gõ `/nong` → xem tin nóng ngay; `/tin` → bản tin đầy đủ ngay (không có bài mới thì bot báo lại).
- `/guilai` → gửi lại cả bài đã gửi trong 3 ngày gần nhất.
- `/trangthai` → xem lần chạy gần nhất thành công hay lỗi.
- Tự kiểm tra **tin nóng mỗi 30 phút**, và gửi bản tin đầy đủ đúng **07:00** và **19:00** mỗi ngày.

## Bước 1 — Tạo GitHub token

1. Mở https://github.com/settings/personal-access-tokens/new
2. **Token name:** `telegram-worker AI-news` · **Expiration:** chọn lâu nhất.
3. **Repository access:** *Only select repositories* → `AI-news`.
4. **Permissions → Repository permissions → Actions:** **Read and write**.
5. **Generate token**, copy lại (dạng `github_pat_...`).

## Bước 2 — Tạo Worker

1. Đăng ký/đăng nhập https://dash.cloudflare.com (miễn phí).
2. **Workers & Pages → Create → Create Worker** (Hello World) → đặt tên, ví dụ `ai-news-bot` → **Deploy**.
3. Bấm **Edit code**, xóa hết code mẫu, dán toàn bộ nội dung file [worker.js](worker.js) → **Deploy**.

## Bước 3 — Khai báo biến

Vào Worker → **Settings → Variables and Secrets → Add**:

| Tên | Loại | Giá trị |
|---|---|---|
| `BOT_TOKEN` | Secret | token bot (giống `telegram.botToken` trong secrets.json) |
| `CHAT_ID` | Text | chat id (giống `telegram.chatId` trong secrets.json, kể cả dấu `-`) |
| `GITHUB_TOKEN` | Secret | token ở bước 1 |
| `WEBHOOK_SECRET` | Secret | tự đặt một chuỗi ngẫu nhiên dài, chỉ chữ/số/`_`/`-`, ví dụ `tin_ai_8f3k2m9q` |
| `GITHUB_REPO` | Text | `thanhnld0912/AI-news` |

Bấm **Deploy** để lưu.

## Bước 4 — Đặt giờ tự chạy

Worker → **Settings → Trigger Events (Triggers) → Add → Cron Triggers**, thêm **đúng 3 dòng** (giờ UTC), xóa các dòng khác nếu có:

- `0 0 * * *` → 07:00 giờ VN (bản tin đầy đủ)
- `0 12 * * *` → 19:00 giờ VN (bản tin đầy đủ)
- `*/30 * * * *` → mỗi 30 phút kiểm tra tin nóng

## Bước 5 — Nối bot với Worker (1 lần)

Mở trên trình duyệt (thay 2 chỗ trong `<...>`):

```
https://<tên-worker>.<tài-khoản>.workers.dev/setup?key=<WEBHOOK_SECRET>
```

Thấy `"ok": true` ở cả `setWebhook` và `setMyCommands` là xong. Gõ `/` trong nhóm sẽ thấy danh sách lệnh.

## Thử

Gõ `/tin` trong nhóm → bot trả lời "Đã bắt đầu…" → 2–4 phút sau bản tin tới.

**Bot không phản hồi lệnh trong nhóm?** Telegram mặc định chỉ cho bot thấy lệnh gửi đích danh. Cách sửa:
gõ `/tin@tên_bot`, hoặc cho bot làm **quản trị viên** nhóm, hoặc trong @BotFather → `/setprivacy` → **Disable**.

## Lưu ý

- Chỉ nhóm/chat có đúng `CHAT_ID` mới ra lệnh được; người lạ nhắn bot sẽ bị bỏ qua.
- GitHub token hết hạn thì lệnh và lịch đều ngừng — bot sẽ báo lỗi `GitHub trả về 401`. Khi đó tạo token mới và thay `GITHUB_TOKEN`.
- Lịch GitHub vẫn giữ làm dự phòng; nếu cả hai cùng chạy, lần sau tự bỏ qua nên không gửi trùng.
