import SwiftUI

/// 本周小结：体重变化、执行力、摄入情况 + 一句话点评，可一键分享
struct WeeklyReportView: View {
    @Environment(\.dismiss) private var dismiss

    let stats: APIClient.StatsResponse
    let weights: [WeightRecord]
    let user: UserProfile?

    // MARK: - 周计算（周一开头）

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    private var weekStart: Date {
        calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
    }

    private var thisWeekKeys: [String] { weekKeys(offset: 0) }
    private var lastWeekKeys: [String] { weekKeys(offset: -1) }

    private func weekKeys(offset: Int) -> [String] {
        guard let start = calendar.date(byAdding: .weekOfYear, value: offset, to: weekStart) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .map { WeightRecord.dateFormatter.string(from: $0) }
    }

    private var weekRangeText: String {
        guard let start = calendar.date(byAdding: .day, value: 6, to: weekStart) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return "\(f.string(from: weekStart)) – \(f.string(from: start))"
    }

    // MARK: - 指标

    private func avgWeight(_ keys: [String]) -> Double? {
        let set = Set(keys)
        let list = weights.filter { set.contains($0.date) }
        guard !list.isEmpty else { return nil }
        return list.reduce(0.0) { $0 + $1.kg } / Double(list.count)
    }

    private func recordDays(_ keys: [String]) -> Int {
        let set = Set(keys)
        return weights.filter { set.contains($0.date) }.count
    }

    private func kcalDays(_ keys: [String]) -> Int {
        let set = Set(keys)
        return stats.daily.filter { set.contains($0.date) && $0.kcal > 0 }.count
    }

    private func avgKcal(_ keys: [String]) -> Double? {
        let set = Set(keys)
        let list = stats.daily.filter { set.contains($0.date) && $0.kcal > 0 }
        guard !list.isEmpty else { return nil }
        return list.reduce(0.0) { $0 + $1.kcal } / Double(list.count)
    }

    private var thisAvg: Double? { avgWeight(thisWeekKeys) }
    private var lastAvg: Double? { avgWeight(lastWeekKeys) }
    private var delta: Double? {
        guard let a = thisAvg, let b = lastAvg else { return nil }
        return a - b
    }
    private var thisKcal: Double? { avgKcal(thisWeekKeys) }
    private var latestKg: Double? { weights.max(by: { $0.date < $1.date })?.kg }
    private var kcalTarget: Double? { user?.kcalTarget(currentKg: latestKg) }
    private var streak: Int { TrendAnalysis.streak(weights) }

    /// 本周七天的柱状数据（没记录的天补 0）
    private var weekPoints: [APIClient.StatsResponse.DailyPoint] {
        let map = Dictionary(uniqueKeysWithValues: stats.daily.map { ($0.date, $0) })
        return thisWeekKeys.map { key in
            if let p = map[key] { return p }
            return APIClient.StatsResponse.DailyPoint(date: key, kg: nil, kcal: 0,
                                                     protein_g: 0, fat_g: 0, carbs_g: 0)
        }
    }

    // MARK: - 文案

    private var verdict: String {
        var parts: [String] = []
        if let d = delta {
            if d <= -0.2 {
                parts.append("体重在稳步下降")
            } else if d >= 0.2 {
                parts.append("体重略有回升，注意一下这周的饮食")
            } else {
                parts.append("体重基本持平")
            }
        } else if thisAvg != nil {
            parts.append("这周刚开始记录，下周就能看到对比了")
        } else {
            parts.append("这周还没有体重记录，先补一条吧")
        }

        if let k = thisKcal {
            if let t = kcalTarget, t > 0 {
                if k > t + 50 {
                    parts.append(String(format: "日均摄入偏高约 %.0f 千卡", k - t))
                } else {
                    parts.append("摄入控制得不错")
                }
            } else {
                parts.append(String(format: "日均摄入约 %.0f 千卡", k))
            }
        }

        let days = recordDays(thisWeekKeys)
        if days >= 5 {
            parts.append("记录很连贯")
        } else if days > 0 {
            parts.append("记录偏少，建议每天固定时间称重")
        }
        if streak >= 7 {
            parts.append("已连续 \(streak) 天")
        }
        return parts.joined(separator: "，") + "。"
    }

    private var shareText: String {
        var lines: [String] = []
        lines.append("【本周小结】\(weekRangeText)")
        if let a = thisAvg {
            var s = String(format: "体重 %.1f kg", a)
            if let d = delta { s += String(format: "，较上周 %+.1f kg", d) }
            lines.append(s)
        }
        lines.append("本周记录体重 \(recordDays(thisWeekKeys)) 天、饮食 \(kcalDays(thisWeekKeys)) 天，连续记录 \(streak) 天")
        if let k = thisKcal {
            if let t = kcalTarget, t > 0 {
                lines.append(String(format: "日均摄入 %.0f 千卡（目标 %.0f）", k, t))
            } else {
                lines.append(String(format: "日均摄入 %.0f 千卡", k))
            }
        }
        lines.append("—— \(verdict)")
        return lines.joined(separator: "\n")
    }

    // MARK: - 界面

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    metricRow
                    intakeCard
                    verdictCard

                    Button {
                        TextShare.share(shareText)
                        Haptics.success()
                    } label: {
                        Label("分享本周小结", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .background(Theme.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("本周小结")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(weekRangeText)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
            Text(deltaText)
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(deltaCaption)
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Theme.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var deltaText: String {
        guard let d = delta else { return "—" }
        return String(format: "%+.1f kg", d)
    }

    private var deltaCaption: String {
        guard let a = thisAvg, let b = lastAvg else {
            return thisAvg == nil ? "本周还没有体重记录" : "上周记录太少，暂无对比"
        }
        return String(format: "本周均值 %.1f kg · 上周 %.1f kg", a, b)
    }

    private var metricRow: some View {
        HStack(spacing: 0) {
            metric("体重记录", "\(recordDays(thisWeekKeys)) / 7 天")
            metric("饮食记录", "\(kcalDays(thisWeekKeys)) / 7 天")
            metric("连续记录", "\(streak) 天")
        }
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var intakeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("每日摄入")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.brandDeep)
                Spacer()
                if let k = thisKcal {
                    Text(String(format: "日均 %.0f 千卡", k))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let t = kcalTarget, t > 0 {
                Text(String(format: "目标 %.0f 千卡/天", t))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            KcalBarChart(points: weekPoints, height: 100)
            if thisKcal == nil {
                Text("本周还没有饮食记录")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(Theme.brandDeep)
                Text("本周点评")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.brandDeep)
            }
            Text(verdict)
                .font(.subheadline)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Theme.adviceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
