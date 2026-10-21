import db from './db.js';

// 中国日期 YYYY-MM-DD（用户在国内，避免容器 UTC 时区导致"今日"错一天）
function chinaDate(d = new Date()) {
  const t = new Date(d.getTime() + 8 * 3600 * 1000); // UTC+8
  const y = t.getUTCFullYear();
  const m = String(t.getUTCMonth() + 1).padStart(2, '0');
  const day = String(t.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function bmiCategory(bmi) {
  if (bmi == null || bmi <= 0) return '';
  if (bmi < 18.5) return '偏瘦';
  if (bmi < 24) return '正常';
  if (bmi < 28) return '超重';
  return '肥胖';
}

function avg(list) {
  if (!list.length) return 0;
  return list.reduce((a, b) => a + b, 0) / list.length;
}

/// 统计汇总：体重 + 卡路里 + 营养 + 每日趋势数据
export function computeStats(userId) {
  const u = db.prepare('SELECT height_cm, target_kg FROM users WHERE id=?').get(userId) || {};

  const first = db.prepare('SELECT kg FROM weights WHERE user_id=? ORDER BY date ASC LIMIT 1').get(userId);
  const last = db.prepare('SELECT kg FROM weights WHERE user_id=? ORDER BY date DESC LIMIT 1').get(userId);

  // 每日卡路里/营养（有饮食记录的天）
  const dailyMeals = db.prepare(`
    SELECT date, SUM(kcal) AS kcal, SUM(protein_g) AS protein, SUM(fat_g) AS fat, SUM(carbs_g) AS carbs
    FROM meals WHERE user_id=? GROUP BY date ORDER BY date
  `).all(userId);

  // 每日体重
  const weights = db.prepare('SELECT date, kg FROM weights WHERE user_id=? ORDER BY date').all(userId);

  // 合并每日数据（体重 + 卡路里/营养），日期去重升序
  const weightMap = new Map(weights.map((w) => [w.date, w.kg]));
  const mealMap = new Map(dailyMeals.map((m) => [m.date, m]));
  const allDates = new Set([...weightMap.keys(), ...mealMap.keys()]);
  const daily = [...allDates].sort().map((d) => ({
    date: d,
    kg: weightMap.has(d) ? weightMap.get(d) : null,
    kcal: mealMap.has(d) ? mealMap.get(d).kcal || 0 : 0,
    protein_g: mealMap.has(d) ? mealMap.get(d).protein || 0 : 0,
    fat_g: mealMap.has(d) ? mealMap.get(d).fat || 0 : 0,
    carbs_g: mealMap.has(d) ? mealMap.get(d).carbs || 0 : 0,
  }));

  const today = chinaDate();

  // 体重统计
  const start_kg = first?.kg ?? null;
  const current_kg = last?.kg ?? null;
  const target_kg = u.target_kg ?? null;
  const height_cm = u.height_cm ?? null;
  const lost_kg = start_kg != null && current_kg != null ? start_kg - current_kg : null;
  const bmi = height_cm && current_kg != null ? current_kg / ((height_cm / 100) ** 2) : null;

  // 卡路里
  const mealDays = dailyMeals.map((m) => m.kcal || 0);
  const recent7 = dailyMeals.filter((m) => m.date >= chinaDate(new Date(Date.now() - 6 * 86400 * 1000)));
  const recent30 = dailyMeals.filter((m) => m.date >= chinaDate(new Date(Date.now() - 29 * 86400 * 1000)));
  const today_kcal = dailyMeals.find((m) => m.date === today)?.kcal || 0;
  const avg7_kcal = avg(recent7.map((m) => m.kcal || 0));
  const avg30_kcal = avg(recent30.map((m) => m.kcal || 0));

  // 营养（近7天日均，仅统计有记录的天）
  const avg7_protein_g = avg(recent7.map((m) => m.protein || 0));
  const avg7_fat_g = avg(recent7.map((m) => m.fat || 0));
  const avg7_carbs_g = avg(recent7.map((m) => m.carbs || 0));

  return {
    weight: {
      start_kg, current_kg, target_kg, lost_kg,
      height_cm, bmi: bmi == null ? null : Math.round(bmi * 10) / 10,
      bmi_category: bmiCategory(bmi),
      record_count: weights.length,
    },
    calories: {
      today_kcal: Math.round(today_kcal),
      avg7_kcal: Math.round(avg7_kcal),
      avg30_kcal: Math.round(avg30_kcal),
    },
    nutrition: {
      avg7_protein_g: Math.round(avg7_protein_g),
      avg7_fat_g: Math.round(avg7_fat_g),
      avg7_carbs_g: Math.round(avg7_carbs_g),
    },
    daily,
  };
}
