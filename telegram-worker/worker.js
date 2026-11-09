// Cloudflare Worker: cầu nối giữa bot Telegram và GitHub Actions.
//  - Gõ lệnh cho bot (/tin, /guilai, /trangthai) -> Worker gọi GitHub chạy workflow "AI News Digest".
//  - Cron Trigger của Cloudflare (07:00 và 19:00 VN) -> Worker gọi workflow đúng giờ.
//
// Biến môi trường (Settings > Variables and Secrets của Worker):
//   BOT_TOKEN       (Secret)  token bot Telegram, giống trong secrets.json
//   CHAT_ID         (Text)    chat id nhóm/người được phép ra lệnh, giống trong secrets.json
//   GITHUB_TOKEN    (Secret)  fine-grained token, chỉ repo AI-news, quyền Actions: Read and write
//   WEBHOOK_SECRET  (Secret)  chuỗi ngẫu nhiên tự đặt (chỉ chữ, số, _ và -)
//   GITHUB_REPO     (Text)    thanhnld0912/AI-news
//   WORKFLOW_FILE   (Text, tùy chọn) mặc định digest.yml

const COMMANDS = [
  { command: 'nong', description: 'Xem tin nóng ngay bây giờ' },
  { command: 'tin', description: 'Lấy bản tin đầy đủ ngay bây giờ' },
  { command: 'guilai', description: 'Gửi lại cả những bài đã gửi (3 ngày gần nhất)' },
  { command: 'trangthai', description: 'Xem lần chạy gần nhất' },
  { command: 'help', description: 'Danh sách lệnh' },
];

const HELP =
  '🤖 <b>Lệnh của bot bản tin</b>\n' +
  '/nong — xem tin nóng ngay\n' +
  '/tin — lấy bản tin đầy đủ ngay\n' +
  '/guilai — gửi lại cả bài đã gửi (3 ngày gần nhất)\n' +
  '/trangthai — xem lần chạy gần nhất\n\n' +
  'Tin nóng tự kiểm tra mỗi 30 phút; bản tin đầy đủ lúc 07:00 và 19:00.';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Mở 1 lần trên trình duyệt: https://<worker>/setup?key=<WEBHOOK_SECRET>
    if (url.pathname === '/setup') {
      if (url.searchParams.get('key') !== env.WEBHOOK_SECRET) return new Response('Sai key', { status: 403 });
      const hook = await tg(env, 'setWebhook', {
        url: `${url.origin}/telegram`,
        secret_token: env.WEBHOOK_SECRET,
        allowed_updates: ['message'],
        drop_pending_updates: true,
      });
      const cmds = await tg(env, 'setMyCommands', { commands: COMMANDS });
      return new Response(JSON.stringify({ setWebhook: hook, setMyCommands: cmds }, null, 2),
        { headers: { 'content-type': 'application/json; charset=utf-8' } });
    }

    if (url.pathname !== '/telegram' || request.method !== 'POST') return new Response('ok');
    if (request.headers.get('X-Telegram-Bot-Api-Secret-Token') !== env.WEBHOOK_SECRET) {
      return new Response('forbidden', { status: 403 });
    }

    const update = await request.json().catch(() => null);
    const msg = update && update.message;
    if (!msg || !msg.text || !msg.text.startsWith('/')) return new Response('ok');
    // Chỉ nhận lệnh từ đúng nhóm/chat đã cấu hình — người lạ nhắn bot sẽ bị bỏ qua.
    if (String(msg.chat.id) !== String(env.CHAT_ID)) return new Response('ok');

    const cmd = msg.text.trim().split(/[\s@]/)[0].toLowerCase();
    const reply = (text) => tg(env, 'sendMessage', {
      chat_id: msg.chat.id,
      message_thread_id: msg.is_topic_message ? msg.message_thread_id : undefined,
      reply_to_message_id: msg.message_id,
      text,
      parse_mode: 'HTML',
      disable_web_page_preview: true,
    });

    try {
      if (cmd === '/tin' || cmd === '/guilai' || cmd === '/nong') {
        const running = await activeRun(env);
        if (running) {
          await reply('⏳ Đang có một lần chạy chưa xong, tin sẽ tới trong ít phút nữa.');
        } else {
          await dispatch(env, {
            mode: cmd === '/nong' ? 'hot' : 'digest',
            resend: cmd === '/guilai',
            notify_empty: true,
          });
          await reply(cmd === '/guilai' ? '🔁 Đã bắt đầu gửi lại bản tin. Khoảng 2–4 phút nữa tin sẽ tới.'
            : cmd === '/nong' ? '⚡ Đang tìm tin nóng. Khoảng 2–3 phút nữa tin sẽ tới.'
            : '🚀 Đã bắt đầu lấy bản tin. Khoảng 2–4 phút nữa tin sẽ tới.');
        }
      } else if (cmd === '/trangthai') {
        await reply(await statusText(env));
      } else if (cmd === '/help' || cmd === '/start') {
        await reply(HELP);
      }
    } catch (e) {
      await reply(`❌ Lỗi: ${escapeHtml(String(e.message || e))}`);
    }
    return new Response('ok');
  },

  // Cron Triggers (giờ UTC):
  //   "0 0 * * *"    = 07:00 VN -> bản tin đầy đủ
  //   "0 12 * * *"   = 19:00 VN -> bản tin đầy đủ
  //   "*/30 * * * *" = mỗi 30 phút -> tin nóng (bỏ qua đúng lúc 07:00/19:00 vì bản tin đầy đủ đang chạy)
  async scheduled(event, env, ctx) {
    if (event.cron === '*/30 * * * *') {
      const d = new Date(event.scheduledTime);
      if (d.getUTCMinutes() < 5 && (d.getUTCHours() === 0 || d.getUTCHours() === 12)) return;
      ctx.waitUntil(dispatch(env, { mode: 'hot' }));
    } else {
      ctx.waitUntil(dispatch(env, { mode: 'digest', scheduled: true }));
    }
  },
};

async function tg(env, method, body) {
  const r = await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return r.json();
}

function gh(env, path, init = {}) {
  return fetch(`https://api.github.com/repos/${env.GITHUB_REPO}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'ai-news-telegram-worker',
      'X-GitHub-Api-Version': '2022-11-28',
      ...(init.body ? { 'content-type': 'application/json' } : {}),
    },
  });
}

async function dispatch(env, inputs) {
  const wf = env.WORKFLOW_FILE || 'digest.yml';
  const str = Object.fromEntries(Object.entries(inputs).map(([k, v]) => [k, String(v)]));
  const r = await gh(env, `/actions/workflows/${wf}/dispatches`, {
    method: 'POST',
    body: JSON.stringify({ ref: 'main', inputs: str }),
  });
  if (r.status !== 204) throw new Error(`GitHub trả về ${r.status}: ${(await r.text()).slice(0, 200)}`);
}

async function latestRun(env) {
  const wf = env.WORKFLOW_FILE || 'digest.yml';
  const r = await gh(env, `/actions/workflows/${wf}/runs?per_page=1`);
  if (!r.ok) throw new Error(`GitHub trả về ${r.status}`);
  const d = await r.json();
  return d.workflow_runs && d.workflow_runs[0];
}

async function activeRun(env) {
  const run = await latestRun(env);
  return run && run.status !== 'completed' ? run : null;
}

async function statusText(env) {
  const run = await latestRun(env);
  if (!run) return 'Chưa có lần chạy nào.';
  const when = new Date(run.run_started_at || run.created_at)
    .toLocaleString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh', hour12: false });
  const state = run.status !== 'completed' ? '⏳ đang chạy'
    : run.conclusion === 'success' ? '✅ thành công'
    : `❌ ${run.conclusion}`;
  const how = run.event === 'schedule' ? 'lịch GitHub' : 'lệnh / lịch Cloudflare';
  return `Lần chạy gần nhất: ${state}\nBắt đầu: ${when} (${how})\n<a href="${run.html_url}">Xem chi tiết trên GitHub</a>`;
}

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
