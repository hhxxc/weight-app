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
    '这是一张食物或食品包装的照片。请完成三件事：',
    '1) 识别食物名称（包装食品尽量写成「品牌 + 品名」）；',
    '2) 估算这次实际吃的克数（包装食品按净含量或一份的量）；',
    '3) 给出这份食物的能量与蛋白质、脂肪、碳水。',
    '',
    '能量单位必须严格遵守：',
    '- 中国/欧盟营养标签上的能量常常是「千焦 kJ」，1 千卡 kcal = 4.184 千焦。',
    '- 看到的是 kJ 时，必须先除以 4.184 换算成 kcal 再填到 kcal 字段，',
    '  绝对不允许把千焦的数字直接当作千卡（那会高估 4 倍以上）。',
    '- 标签一般是「每 100 克」，要按实际克数折算：kcal = 每100g kcal × 克数 ÷ 100。',
    '- 任何食物能量密度都在 0~900 kcal/100g 之间；若算出的值超过这个范围，',
    '  说明单位换算错了，请重新计算后再输出。',
    '',
    '只输出 JSON，不要任何多余文字，格式：{"food":"","weight_g":0,"kcal":0,"protein_g":0,"fat_g":0,"carbs_g":0}',
  ].join('\n');
  const raw = await chat(FOOD_MODEL, prompt, imageBase64);
  const j = extractJSON(raw);
  if (!j) {
    // 模型没按 JSON 返回：兜底返回完整结构，避免客户端解码失败
    return { food: String(raw || '').trim().slice(0, 100), weight_g: 0, kcal: 0, protein_g: 0, fat_g: 0, carbs_g: 0, converted_from_kj: false };
  }

  const round1 = (v) => Math.round((Number(v) || 0) * 10) / 10;
  const weight = Number(j.weight_g) || 0;
  let kcal = Number(j.kcal) || 0;
  let converted = false;

  // 服务端兜底：任何食物能量密度都不可能超过 9.2 kcal/g（纯油脂约 9）。
  // 超了说明模型把营养标签上的「千焦」当成了「千卡」，这里换回来。
  if (weight > 0) {
    if (kcal / weight > 9.2) {
      let k = kcal / 4.184;                 // 假设模型给的是这份食物的 kJ 总量
      if (k / weight > 9.2) {
        k = (k * weight) / 100;             // 仍不合理 → 原值其实是「每 100g」，按份量折算
      }
      console.log(`[ai] 识图能量单位疑似 kJ：${kcal} → ${Math.round(k)} kcal / ${weight} g`);
      kcal = k;
      converted = true;
    }
  } else if (kcal > 900) {
    // 没有克数（多半是拍的营养成分表）：每 100g 不可能超过 900 kcal
    kcal = kcal / 4.184;
    converted = true;
    console.log(`[ai] 识图能量单位疑似 kJ（无克数）：换算为 ${Math.round(kcal)} kcal/100g`);
  }

  return {
    food: String(j.food || '').trim(),
    weight_g: Math.round(weight),
    kcal: Math.round(kcal),
    protein_g: round1(j.protein_g),
    fat_g: round1(j.fat_g),
    carbs_g: round1(j.carbs_g),
    converted_from_kj: converted,
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
