import Database from 'better-sqlite3';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import fs from 'fs';

const __dirname = dirname(fileURLToPath(import.meta.url));
// 数据目录：默认 server/data，可用环境变量覆盖（Docker 挂载卷指向这里）
const DATA_DIR = process.env.DATA_DIR || join(__dirname, '..', 'data');
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new Database(join(DATA_DIR, 'weight.db'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  username    TEXT    NOT NULL UNIQUE,
  password    TEXT    NOT NULL,          -- bcrypt 哈希
  nickname    TEXT    NOT NULL DEFAULT '',
  height_cm   REAL,                      -- 身高，用于 BMI
  target_kg   REAL,                      -- 目标体重
  is_admin    INTEGER NOT NULL DEFAULT 0, -- 1=管理员（可分配账号）
  created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS weights (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date       TEXT    NOT NULL,           -- YYYY-MM-DD（本地日期）
  kg         REAL    NOT NULL,
  note       TEXT    NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  UNIQUE(user_id, date)
);

CREATE TABLE IF NOT EXISTS meals (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date       TEXT    NOT NULL,           -- YYYY-MM-DD
  type       TEXT    NOT NULL,           -- breakfast/lunch/dinner/snack
  content    TEXT    NOT NULL,
  kcal       REAL,                       -- 卡路里（千卡），拍照识别时填
  protein_g  REAL,
  fat_g      REAL,
  carbs_g    REAL,
  image_url  TEXT,                       -- 食物图片 URL（可选）
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_weights_user_date ON weights(user_id, date);
CREATE INDEX IF NOT EXISTS idx_meals_user_date ON meals(user_id, date);
`);

// 迁移：老库 meals 表补营养/图片字段（列已存在时跳过）
function ensureColumn(table, column, ddl) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!cols.includes(column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${ddl}`);
  }
}
for (const [col, ddl] of [
  ['kcal', 'REAL'],
  ['protein_g', 'REAL'],
  ['fat_g', 'REAL'],
  ['carbs_g', 'REAL'],
  ['image_url', 'TEXT'],
]) {
  ensureColumn('meals', col, ddl);
}
// 迁移：users 表补 is_admin 列（管理员分配账号机制）
ensureColumn('users', 'is_admin', 'INTEGER NOT NULL DEFAULT 0');

export default db;
export { DATA_DIR };
