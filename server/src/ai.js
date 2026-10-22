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
export async function recognizeFood(imageBase64) {
  const prompt = [
    '这是一张食物照片。识别里面的食物名称、估算大概克数，并给出卡路里(千卡)、蛋白质(g)、脂肪(g)、碳水(g)。',
    '只输出 JSON，不要任何多余文字，格式：{"food":"","weight_g":0,"kcal":0,"protein_g":0,"fat_g":0,"carbs_g":0}',
  ].join('\n');
  const raw = await chat(FOOD_MODEL, prompt, imageBase64);
  const j = extractJSON(raw);
  if (!j) {
    // 模型没按 JSON 返回：兜底返回完整结构，避免客户端解码失败
    return { food: String(raw || '').trim().slice(0, 100), weight_g: 0, kcal: 0, protein_g: 0, fat_g: 0, carbs_g: 0 };
  }
  return {
    food: String(j.food || '').trim(),
    weight_g: Number(j.weight_g) || 0,
    kcal: Number(j.kcal) || 0,
    protein_g: Number(j.protein_g) || 0,
    fat_g: Number(j.fat_g) || 0,
    carbs_g: Number(j.carbs_g) || 0,
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
  return {
    name: String(j.name || '').trim(),
    energy_kj: Number(j.energy_kj) || 0,
    energy_kcal: Number(j.energy_kcal) || 0,
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
