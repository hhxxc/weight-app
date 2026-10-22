import fs from 'fs';

// 硅基流动（SiliconFlow）OpenAI 兼容客户端。
// 复用巢记的 key：优先环境变量 AI_API_KEY / AI_API_KEY_FILE，
// 否则尝试读 NAS 上巢记的 key 文件（Docker 挂载路径）。
const AI_BASE_URL = process.env.AI_BASE_URL || 'https://api.siliconflow.cn/v1';

function readKey() {
  if (process.env.AI_API_KEY) return process.env.AI_API_KEY.trim();
  const candidates = [
    process.env.AI_API_KEY_FILE,
    '/data/giliconcloude_key.txt',   // Docker 挂载巢记 key 文件
    '/keys/giliconcloude_key.txt',
    '/volume2/docker/giliconcloude_key.txt',
  ].filter(Boolean);
  for (const p of candidates) {
    try {
      const v = fs.readFileSync(p, 'utf8').trim();
      if (v) return v;
    } catch { /* 下一个 */ }
  }
  return '';
}

// 视觉模型：识图主力（巢记实测恒 ~6s），OCR 用专门模型
const FOOD_MODEL = process.env.AI_FOOD_MODEL || 'Qwen/Qwen3-VL-30B-A3B-Instruct';
const OCR_MODEL = process.env.AI_OCR_MODEL || 'PaddlePaddle/PaddleOCR-VL-1.5';
// 文本模型：AI 建议（便宜快速即可）
const TEXT_MODEL = process.env.AI_TEXT_MODEL || 'deepseek-ai/DeepSeek-V4.1-Flash';

async function chat(model, text, imageBase64) {
  const key = readKey();
  if (!key) {
    throw new Error('未配置 AI API key（硅基流动），请设 AI_API_KEY 或挂载 key 文件');
  }
  const content = [{ type: 'text', text }];
  if (imageBase64) {
    content.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${imageBase64}` } });
  }
  const resp = await fetch(`${AI_BASE_URL}/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({ model, messages: [{ role: 'user', content }], temperature: 0.2 }),
  });
  if (!resp.ok) {
    const t = await resp.text().catch(() => '');
    throw new Error(`AI 调用失败 ${resp.status}: ${t.slice(0, 200)}`);
  }
  const data = await resp.json();
  const raw = data?.choices?.[0]?.message?.content || '';
  return raw;
}

// 从模型返回文本里抠出 JSON（模型可能包 ```json ... ``` 或直接裸 JSON）
function extractJSON(text) {
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const candidate = fence ? fence[1] : text;
  const start = candidate.indexOf('{');
  const end = candidate.lastIndexOf('}');
  if (start < 0 || end < 0 || end <= start) return null;
  try {
    return JSON.parse(candidate.slice(start, end + 1));
  } catch {
    return null;
  }
}

// 食物识图：识别食物名 + 估算克数 + 卡路里 + 营养
// 能量单位兜底：任何食物能量密度都在 0~9.2 kcal/g（纯油脂约 9）。
// 超过就说明模型把营养标签上的「千焦 kJ」当成了「千卡」。
export function fixEnergyUnit(kcal, weight) {
  const k = Number(kcal) || 0;
  const w = Number(weight) || 0;
  if (w > 0) {
    if (k / w <= 9.2) return { kcal: k, converted: false };
    let v = k / 4.184;                       // 假设模型给的是这份食物的 kJ 总量
    if (v / w > 9.2) v = (v * w) / 100;      // 仍不合理 → 原值其实是「每 100g」，按份量折算
    return { kcal: v, converted: true };
  }
  if (k > 900) return { kcal: k / 4.184, converted: true };  // 无克数：每 100g 上限
  return { kcal: k, converted: false };
}

const round1 = (v) => Math.round((Number(v) || 0) * 10) / 10;

function normalizeFoodItem(o) {
  const weight = Number(o.weight_g) || 0;
  const fixed = fixEnergyUnit(o.kcal, weight);
  return {
    food: String(o.food || '').trim(),
    weight_g: Math.round(weight),
    kcal: Math.round(fixed.kcal),
    protein_g: round1(o.protein_g),
    fat_g: round1(o.fat_g),
    carbs_g: round1(o.carbs_g),
    converted_from_kj: fixed.converted,
  };
}

// 食物识图：识别照片里所有食物（一盘多样也能分开），估算克数 + 营养
export async function recognizeFood(imageBase64) {
  const prompt = [
    '这是一张食物或食品包装的照片。请识别照片里所有能吃的东西：',
    '- 如果是一盘/一桌有多样食物，请分开列出，每样单独估算克数和营养（最多 6 样）；',
    '- 如果只有一个包装食品，就只列一项（按标签每 100g 数据乘以实际克数）。',
    '',
    '能量单位必须严格遵守：',
    '- 营养标签上的能量常常是「千焦 kJ」，1 千卡 kcal = 4.184 千焦；',
    '- 看到 kJ 必须先除以 4.184 换算成 kcal 再填，绝对不允许把千焦数字当千卡（会高估 4 倍以上）；',
    '- 任何食物能量密度都在 0~900 kcal/100g 之间，若算出的值超出范围，说明单位错了，请重算。',
    '',
    '只输出 JSON，不要任何多余文字，格式：',
    '{"items":[{"food":"","weight_g":0,"kcal":0,"protein_g":0,"fat_g":0,"carbs_g":0}]}',
  ].join('\n');
  const raw = await chat(FOOD_MODEL, prompt, imageBase64);
  const j = extractJSON(raw);
  if (!j) {
    return {
      items: [], food: String(raw || '').trim().slice(0, 100),
      weight_g: 0, kcal: 0, protein_g: 0, fat_g: 0, carbs_g: 0, converted_from_kj: false,
    };
  }

  // 新格式 {items:[...]}；模型若仍返回旧的单对象，也兼容
  const list = Array.isArray(j.items) && j.items.length ? j.items.slice(0, 6) : [j];
  const cleaned = list.map(normalizeFoodItem)
    .filter((x) => x.food && (x.kcal > 0 || x.weight_g > 0));

  // 合并同名项（模型偶尔把同一道菜拆成两行）
  const items = [];
  const index = new Map();
  for (const it of cleaned) {
    const key = it.food.replace(/\s+/g, '');
    if (index.has(key)) {
      const t = items[index.get(key)];
      t.weight_g += it.weight_g;
      t.kcal += it.kcal;
      t.protein_g = round1(t.protein_g + it.protein_g);
      t.fat_g = round1(t.fat_g + it.fat_g);
      t.carbs_g = round1(t.carbs_g + it.carbs_g);
      t.converted_from_kj = t.converted_from_kj || it.converted_from_kj;
    } else {
      index.set(key, items.length);
      items.push({ ...it });
    }
  }
  const anyConverted = items.some((x) => x.converted_from_kj);
  if (anyConverted) console.log('[ai] 识图能量单位疑似 kJ，已自动换算');

  const sum = (key) => items.reduce((a, b) => a + (Number(b[key]) || 0), 0);
  return {
    items,
    // 兼容旧客户端：整体视为一条
    food: items.map((x) => x.food).join('、').slice(0, 100),
    weight_g: Math.round(sum('weight_g')),
    kcal: Math.round(sum('kcal')),
    protein_g: round1(sum('protein_g')),
    fat_g: round1(sum('fat_g')),
    carbs_g: round1(sum('carbs_g')),
    converted_from_kj: anyConverted,
  };
}

// 配料表/营养成分表 OCR：读每100g的能量、蛋白、脂肪、碳水
export async function ocrNutrition(imageBase64) {
  const prompt = [
    '这是食品包装上的营养成分表照片。识别「每 100 克」的能量(kJ 和 kcal)、蛋白质、脂肪、碳水化合物。',
    '只输出 JSON，不要任何多余文字，格式：{"name":"","energy_kj":0,"energy_kcal":0,"protein_g":0,"fat_g":0,"carbs_g":0}',
  ].join('\n');
  const raw = await chat(OCR_MODEL, prompt, imageBase64);
  const j = extractJSON(raw);
  if (!j) {
    return { name: String(raw || '').trim().slice(0, 100), energy_kj: 0, energy_kcal: 0, protein_g: 0, fat_g: 0, carbs_g: 0 };
  }
  let kj = Number(j.energy_kj) || 0;
  let kcal = Number(j.energy_kcal) || 0;
  // 每 100g 不可能超过 900 kcal；超出说明模型把 kJ 填进了 kcal
  if (kcal > 900) {
    kcal = kj > 0 ? kj / 4.184 : kcal / 4.184;
    if (kj <= 0) kj = Math.round(kcal * 4.184);
    console.log(`[ai] 配料表能量单位疑似 kJ，已换算：${Math.round(kcal)} kcal/100g`);
  }
  return {
    name: String(j.name || '').trim(),
    energy_kj: Math.round(kj),
    energy_kcal: Math.round(kcal),
    protein_g: Number(j.protein_g) || 0,
    fat_g: Number(j.fat_g) || 0,
    carbs_g: Number(j.carbs_g) || 0,
  };
}

// AI 建议：根据统计摘要生成减重/营养建议（纯文本模型）
export async function generateAdvice(summaryText) {
  const prompt = [
    '你是专业的减重与营养顾问。根据下面这份个人数据，给出 3~5 条简洁、具体、可执行的建议。',
    '要求：用中文；语气友好直接，不要客套话和免责声明；每条建议要落到具体行动（吃多少、做什么）。',
    '如果数据不足（记录很少），先提醒用户坚持每天记录，再给通用建议。',
    '',
    summaryText,
  ].join('\n');
  const raw = await chat(TEXT_MODEL, prompt, null);
  return raw.trim();
}

// 文字描述估卡路里：根据饮食描述（如"两个包子一碗粥"）估算总卡路里+营养
export async function estimateFood(text) {
  const prompt = [
    '根据这段饮食描述，估算这一餐的总卡路里和营养成分。',
    '描述可能包含食物名称和数量（如"两个包子一碗粥""一个汉堡一份薯条"）。',
    '只输出 JSON，不要任何多余文字，格式：{"food":"","kcal":0,"protein_g":0,"fat_g":0,"carbs_g":0}',
    '',
    `描述：${text}`,
  ].join('\n');
  const raw = await chat(TEXT_MODEL, prompt, null);
  const j = extractJSON(raw);
  if (!j) {
    return { food: String(text).trim().slice(0, 200), kcal: 0, protein_g: 0, fat_g: 0, carbs_g: 0 };
  }
  return {
    food: String(j.food || text).trim(),
    kcal: Number(j.kcal) || 0,
    protein_g: Number(j.protein_g) || 0,
    fat_g: Number(j.fat_g) || 0,
    carbs_g: Number(j.carbs_g) || 0,
  };
}
