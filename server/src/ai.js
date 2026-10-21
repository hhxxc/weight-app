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
