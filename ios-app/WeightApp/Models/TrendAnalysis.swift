import Foundation

/// 体重趋势分析：7 日移动平均、线性回归速率、目标达成预测。
/// 纯本地计算，不依赖后端，离线也能给出建议。
enum TrendAnalysis {

    struct Forecast {
        let weeklyChangeKg: Double   // 每周变化，负数为下降
        let remainingKg: Double?     // 距目标还差多少 kg
        let daysToTarget: Int?       // 预计还需多少天（0 = 已达成）
        let targetDate: Date?
        let confidence: Double       // 0~1，样本量 × 拟合优度
        let sampleCount: Int
    }

    // MARK: - 移动平均

    /// 逐点 7 日移动平均，用于平滑日常称重噪声（水分/进食波动）。
    static func movingAverage(_ weights: [WeightRecord], window: Int = 7) -> [WeightRecord] {
        guard window > 1, weights.count > 1 else { return weights }
        var out: [WeightRecord] = []
        out.reserveCapacity(weights.count)
        var queue: [Double] = []
        var sum = 0.0
        for w in weights {
            queue.append(w.kg)
            sum += w.kg
            if queue.count > window {
                sum -= queue.removeFirst()
            }
            out.append(WeightRecord(id: w.id, date: w.date, kg: sum / Double(queue.count), note: w.note))
        }
        return out
    }

    // MARK: - 线性回归

    /// 最近 windowDays 天的日均变化（kg/天）+ 拟合优度 R²
    private static func regression(_ weights: [WeightRecord], windowDays: Int) -> (slope: Double, r2: Double, count: Int)? {
        let asc = weights.sorted { $0.date < $1.date }
        guard let lastDate = asc.last?.dateObj,
              let firstDate = asc.first?.dateObj else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: lastDate) ?? lastDate
        let recent = asc.filter { ($0.dateObj ?? firstDate) >= cutoff }
        guard recent.count >= 3 else { return nil }

        let xs = recent.map { ($0.dateObj ?? firstDate).timeIntervalSince(firstDate) / 86400.0 }
        let ys = recent.map { $0.kg }
        let n = Double(recent.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var num = 0.0
        var den = 0.0
        for i in 0..<recent.count {
            let dx = xs[i] - meanX
            num += dx * (ys[i] - meanY)
            den += dx * dx
        }
        guard den > 0 else { return nil }
        let slope = num / den

        var ssRes = 0.0
        var ssTot = 0.0
        for i in 0..<recent.count {
            let predicted = meanY + slope * (xs[i] - meanX)
            ssRes += pow(ys[i] - predicted, 2)
            ssTot += pow(ys[i] - meanY, 2)
        }
        let r2 = ssTot > 0 ? max(0, min(1, 1 - ssRes / ssTot)) : 0
        return (slope, r2, recent.count)
    }

    /// 目标预测：用最近 3 周线性趋势外推达标日期
    static func forecast(_ weights: [WeightRecord], targetKg: Double?, windowDays: Int = 21) -> Forecast? {
        guard let tg = targetKg, weights.count >= 3,
              let last = weights.max(by: { $0.date < $1.date }),
              let reg = regression(weights, windowDays: windowDays) else { return nil }

        let weekly = reg.slope * 7
        let remaining = last.kg - tg
        var days: Int?
        var date: Date?

        if remaining <= 0 {
            days = 0
            date = Date()
        } else if reg.slope < -0.001 {
            let d = remaining / -reg.slope
            if d.isFinite, d < 3650 {
                let rounded = Int(d.rounded())
                days = rounded
                date = Calendar.current.date(byAdding: .day, value: rounded, to: Date())
            }
        }

        let confidence = min(1, reg.r2 * min(1, Double(reg.count) / 10.0))
        return Forecast(weeklyChangeKg: weekly,
                        remainingKg: remaining,
                        daysToTarget: days,
                        targetDate: date,
                        confidence: confidence,
                        sampleCount: reg.count)
    }

    /// 最近 7 天实际变化（首尾差，负数为下降）；样本不足返回 nil
    static func weekDelta(_ weights: [WeightRecord]) -> Double? {
        let asc = weights.sorted { $0.date < $1.date }
        guard let last = asc.last, let lastDate = last.dateObj else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: lastDate) ?? lastDate
        let recent = asc.filter { ($0.dateObj ?? lastDate) >= cutoff }
        guard let first = recent.first, recent.count >= 2 else { return nil }
        return last.kg - first.kg
    }

    /// 目标完成度 0~1（起始 → 目标）
    static func progress(_ weights: [WeightRecord], targetKg: Double?) -> Double? {
        guard let tg = targetKg,
              let first = weights.min(by: { $0.date < $1.date }),
              let last = weights.max(by: { $0.date < $1.date }) else { return nil }
        let total = first.kg - tg
        guard total > 0.1 else { return last.kg <= tg ? 1 : nil }
        let done = first.kg - last.kg
        return max(0, min(1, done / total))
    }

    /// 置信度文案（低/中/高）
    static func confidenceText(_ c: Double) -> String {
        if c >= 0.6 { return "趋势置信 高" }
        if c >= 0.3 { return "趋势置信 中" }
        return "趋势置信 低"
    }

    /// 预计达标文案（日期 / 已达成 / 暂无法推算）
    static func targetText(_ f: Forecast) -> String {
        guard let d = f.daysToTarget else { return "暂无法推算" }
        if d == 0 { return "已达成" }
        if let dt = f.targetDate { return shortDate(dt) }
        return "\(d) 天后"
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    static func shortDate(_ d: Date) -> String {
        shortDateFormatter.string(from: d)
    }
}
