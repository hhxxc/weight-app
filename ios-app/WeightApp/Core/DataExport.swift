import Foundation

/// 数据导出：体重记录导成 Excel 可直接打开的 CSV（带 BOM，中文不乱码）
enum DataExport {
    static func weightsCSV(_ weights: [WeightRecord], heightCm: Double?) -> URL? {
        guard !weights.isEmpty else { return nil }
        var lines = ["日期,体重(kg),体重(斤),BMI,备注"]
        for w in weights.sorted(by: { $0.date < $1.date }) {
            let kg = String(format: "%.1f", w.kg)
            let jin = String(format: "%.1f", w.kg * 2)
            var bmi = ""
            if let h = heightCm, h > 0 {
                bmi = String(format: "%.1f", w.kg / ((h / 100) * (h / 100)))
            }
            lines.append("\(w.date),\(kg),\(jin),\(bmi),\(escape(w.note))")
        }
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n")
        let name = "体重记录-\(WeightRecord.dateFormatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
