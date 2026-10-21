import http from 'http';
import { URL } from 'url';
import bcrypt from 'bcryptjs';
import db from './db.js';
import { sign, verify } from './auth.js';

const PORT = process.env.PORT || 3000;
const BCRYPT_ROUNDS = 10;

// ---- 通用工具 ----
function json(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      if (raw.length > 5 * 1024 * 1024) { req.destroy(); reject(new Error('body too large')); }
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch { reject(new Error('invalid json')); }
    });
    req.on('error', reject);
  });
}

function publicUser(u) {
  return { id: u.id, username: u.username, nickname: u.nickname, height_cm: u.height_cm, target_kg: u.target_kg };
}

// 从请求里取鉴权后的用户；无效 token 返回 null
function authUser(req) {
  const h = req.headers['authorization'] || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : null;
  if (!token) return null;
  const payload = verify(token);
  if (!payload) return null;
  return db.prepare('SELECT * FROM users WHERE id = ?').get(payload.uid) || null;
}

// ---- 路由表 ----
const routes = [];

function route(method, pattern, handler, auth = false) {
  routes.push({ method, pattern, handler, auth });
}

// 用正则把 /xxx/:id 之类的路径参数解析出来
function match(pattern, pathname) {
  const p = pattern.split('/').filter(Boolean);
  const a = pathname.split('/').filter(Boolean);
  if (p.length !== a.length) return null;
  const params = {};
  for (let i = 0; i < p.length; i++) {
    if (p[i].startsWith(':')) params[p[i].slice(1)] = decodeURIComponent(a[i]);
    else if (p[i] !== a[i]) return null;
  }
  return params;
}

function toDate(s) {
  // 校验 YYYY-MM-DD，并允许 YYYY/M/D 自动归一
  const m = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/.exec(s || '');
  if (!m) return null;
  const y = +m[1], mo = +m[2], d = +m[3];
  const dt = new Date(y, mo - 1, d);
  if (dt.getFullYear() !== y || dt.getMonth() !== mo - 1 || dt.getDate() !== d) return null;
  const mm = String(mo).padStart(2, '0');
  const dd = String(d).padStart(2, '0');
  return `${y}-${mm}-${dd}`;
}

// ---- 注册 / 登录 ----
route('POST', '/auth/register', async (req, res) => {
  const { username, password, nickname = '' } = await readBody(req);
  if (!username || !password) return json(res, 400, { error: '用户名和密码不能为空' });
  if (String(username).trim().length < 2) return json(res, 400, { error: '用户名至少 2 个字符' });
  if (String(password).length < 4) return json(res, 400, { error: '密码至少 4 位' });
  const uname = String(username).trim();
  const exists = db.prepare('SELECT id FROM users WHERE username = ?').get(uname);
  if (exists) return json(res, 409, { error: '该用户名已被注册' });
  const hash = bcrypt.hashSync(String(password), BCRYPT_ROUNDS);
  const info = db.prepare('INSERT INTO users (username, password, nickname, created_at) VALUES (?,?,?,?)')
    .run(uname, hash, String(nickname || '').slice(0, 32), Date.now());
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid);
  json(res, 201, { token: sign(u), user: publicUser(u) });
});

route('POST', '/auth/login', async (req, res) => {
  const { username, password } = await readBody(req);
  if (!username || !password) return json(res, 400, { error: '请输入用户名和密码' });
  const u = db.prepare('SELECT * FROM users WHERE username = ?').get(String(username).trim());
  if (!u || !bcrypt.compareSync(String(password), u.password)) {
    return json(res, 401, { error: '用户名或密码错误' });
  }
  json(res, 200, { token: sign(u), user: publicUser(u) });
});

// ---- 个人资料 ----
route('GET', '/me', (req, res) => json(res, 200, { user: publicUser(req.user) }), true);

route('PUT', '/me', async (req, res) => {
  const b = await readBody(req);
  const u = req.user;
  const nickname = b.nickname !== undefined ? String(b.nickname).slice(0, 32) : u.nickname;
  const height_cm = b.height_cm !== undefined ? (b.height_cm === null ? null : +b.height_cm) : u.height_cm;
  const target_kg = b.target_kg !== undefined ? (b.target_kg === null ? null : +b.target_kg) : u.target_kg;
  if (height_cm !== null && (!Number.isFinite(height_cm) || height_cm < 50 || height_cm > 260)) {
    return json(res, 400, { error: '身高需在 50~260cm 之间' });
  }
  if (target_kg !== null && (!Number.isFinite(target_kg) || target_kg < 10 || target_kg > 500)) {
    return json(res, 400, { error: '目标体重需在 10~500kg 之间' });
  }
  db.prepare('UPDATE users SET nickname=?, height_cm=?, target_kg=? WHERE id=?')
    .run(nickname, height_cm, target_kg, u.id);
  const nu = db.prepare('SELECT * FROM users WHERE id = ?').get(u.id);
  json(res, 200, { user: publicUser(nu) });
}, true);

// ---- 体重 ----
route('GET', '/weights', (req, res) => {
  const rows = db.prepare('SELECT id,date,kg,note FROM weights WHERE user_id=? ORDER BY date DESC')
    .all(req.user.id);
  json(res, 200, { items: rows });
}, true);

route('POST', '/weights', async (req, res) => {
  const b = await readBody(req);
  const date = toDate(b.date);
  if (!date) return json(res, 400, { error: '日期格式应为 YYYY-MM-DD' });
  const kg = +b.kg;
  if (!Number.isFinite(kg) || kg < 10 || kg > 500) return json(res, 400, { error: '体重需在 10~500kg 之间' });
  const note = String(b.note || '').slice(0, 200);
  // 同一天重复记录：覆盖更新（每天一条）
  db.prepare(`INSERT INTO weights (user_id,date,kg,note,created_at) VALUES (?,?,?,?,?)
              ON CONFLICT(user_id,date) DO UPDATE SET kg=excluded.kg, note=excluded.note`)
    .run(req.user.id, date, kg, note, Date.now());
  const row = db.prepare('SELECT id,date,kg,note FROM weights WHERE user_id=? AND date=?').get(req.user.id, date);
  json(res, 201, { item: row });
}, true);

route('DELETE', '/weights/:date', (req, res) => {
  const date = toDate(req.params.date);
  if (!date) return json(res, 400, { error: '日期格式错误' });
  const info = db.prepare('DELETE FROM weights WHERE user_id=? AND date=?').run(req.user.id, date);
  if (info.changes === 0) return json(res, 404, { error: '该日期没有记录' });
  json(res, 200, { ok: true });
}, true);

// ---- 饮食 ----
route('GET', '/meals', (req, res) => {
  const date = req.query.get('date') || null;
  const rows = date
    ? db.prepare('SELECT id,date,type,content FROM meals WHERE user_id=? AND date=? ORDER BY id').all(req.user.id, toDate(date))
    : db.prepare('SELECT id,date,type,content FROM meals WHERE user_id=? ORDER BY date DESC, id DESC').all(req.user.id);
  json(res, 200, { items: rows });
}, true);

route('POST', '/meals', async (req, res) => {
  const b = await readBody(req);
  const date = toDate(b.date);
  if (!date) return json(res, 400, { error: '日期格式应为 YYYY-MM-DD' });
  const type = ['breakfast', 'lunch', 'dinner', 'snack'].includes(b.type) ? b.type : 'snack';
  const content = String(b.content || '').trim();
  if (!content) return json(res, 400, { error: '内容不能为空' });
  const info = db.prepare('INSERT INTO meals (user_id,date,type,content,created_at) VALUES (?,?,?,?,?)')
    .run(req.user.id, date, type, content.slice(0, 500), Date.now());
  const row = db.prepare('SELECT id,date,type,content FROM meals WHERE id=?').get(info.lastInsertRowid);
  json(res, 201, { item: row });
}, true);

route('DELETE', '/meals/:id', (req, res) => {
  const info = db.prepare('DELETE FROM meals WHERE id=? AND user_id=?').run(+req.params.id, req.user.id);
  if (info.changes === 0) return json(res, 404, { error: '记录不存在' });
  json(res, 200, { ok: true });
}, true);

// ---- 批量导入（Excel/CSV 已在客户端解析成 JSON 数组）----
route('POST', '/weights/import', async (req, res) => {
  const b = await readBody(req);
  const rows = Array.isArray(b.items) ? b.items : [];
  if (rows.length === 0) return json(res, 400, { error: '没有可导入的数据' });
  const ins = db.prepare(`INSERT INTO weights (user_id,date,kg,note,created_at) VALUES (?,?,?,?,?)
                          ON CONFLICT(user_id,date) DO UPDATE SET kg=excluded.kg, note=excluded.note`);
  const tx = db.transaction((list) => {
    let n = 0;
    for (const r of list) {
      const date = toDate(r.date);
      const kg = +r.kg;
      if (!date || !Number.isFinite(kg) || kg < 10 || kg > 500) continue;
      ins.run(req.user.id, date, kg, String(r.note || '').slice(0, 200), Date.now());
      n++;
    }
    return n;
  });
  const n = tx(rows);
  json(res, 200, { imported: n });
}, true);

// ---- 请求分发 ----
const server = http.createServer(async (req, res) => {
  // CORS：放开，方便调试（正式 App 走原生 URLSession 不受影响）
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  let url;
  try { url = new URL(req.url, `http://${req.headers.host || 'localhost'}`); }
  catch { return json(res, 400, { error: 'bad url' }); }

  const pathname = url.pathname;
  for (const r of routes) {
    if (r.method !== req.method) continue;
    const params = match(r.pattern, pathname);
    if (!params) continue;
    req.query = url.searchParams;
    if (r.auth) {
      const user = authUser(req);
      if (!user) return json(res, 401, { error: '未登录或登录已过期' });
      req.user = user;
    }
    try {
      await r.handler(req, res, params);
    } catch (e) {
      if (e.message === 'invalid json') return json(res, 400, { error: '请求体不是合法 JSON' });
      if (e.message === 'body too large') return json(res, 413, { error: '请求体过大' });
      console.error('[error]', r.pattern, e);
      json(res, 500, { error: '服务器内部错误' });
    }
    return;
  }
  json(res, 404, { error: 'Not Found' });
});

server.listen(PORT, () => {
  console.log(`✅ weight-server 已启动，监听 ${PORT}`);
  console.log(`   数据目录：${process.env.DATA_DIR || '(默认 server/data)'}`);
});
