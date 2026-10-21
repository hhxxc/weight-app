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
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_weights_user_date ON weights(user_id, date);
CREATE INDEX IF NOT EXISTS idx_meals_user_date ON meals(user_id, date);
`);

export default db;
export { DATA_DIR };
