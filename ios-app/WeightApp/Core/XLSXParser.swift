import Foundation
import Compression

/// 无第三方依赖的最小 xlsx 解析器。
/// xlsx 本质是 zip 压缩包，内含 XML。这里实现够用的 ZIP 读取（stored + deflate 两种压缩方式，
/// 支持 ZIP64 之外的常规本地文件）与轻量 XML 提取，用于把体重记录表格解析成数据。
enum XLSXParser {

    struct ParsedRow {
        let date: String
        let kg: Double
        let note: String
    }

    /// 解析 xlsx，返回「日期 + 体重(kg)」记录数组（按出现顺序）。
    /// 会遍历所有 worksheet，自动选「有效体重行最多」的一张，兼容封面/说明/图表等非数据表。
    static func parseWeights(_ url: URL) throws -> [ParsedRow] {
        let data = try Data(contentsOf: url)
        let entries = try readZipEntries(data)
        guard let sharedData = entries["xl/sharedStrings.xml"] else {
            throw NSError(domain: "xlsx", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 sharedStrings.xml"])
        }
        let sharedStrings = parseSharedStrings(sharedData)

        let sheetFiles = entries.keys
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        var best: [ParsedRow] = []
        for name in sheetFiles {
            guard let sheetData = entries[name] else { continue }
            let rows = parseSheet(sheetData, sharedStrings: sharedStrings)
            if rows.count > best.count { best = rows }
        }
        return best
    }

    // MARK: - ZIP 读取

    /// 返回 [路径: 解压后的 Data]
    private static func readZipEntries(_ data: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var offset = 0
        let count = data.count
        let reader = DataReader(data)

        func u16(_ o: Int) -> Int { reader.u16(o) }
        func u32(_ o: Int) -> Int { reader.u32(o) }

        while offset + 30 <= count {
            guard reader.u32(offset) == 0x04034b50 else { break } // local file header signature
            let method = u16(offset + 8)
            let compSize = u32(offset + 18)
            let nameLen = u16(offset + 26)
            let extraLen = u16(offset + 28)
            let nameStart = offset + 30
            guard nameStart + nameLen <= count else { break }
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) else {
                offset = nameStart + nameLen + extraLen + compSize
                continue
            }
            let dataStart = nameStart + nameLen + extraLen
            let dataEnd = dataStart + compSize
            guard dataEnd <= count else { break }

            let raw = data.subdata(in: dataStart..<dataEnd)
            let decompressed: Data
            switch method {
            case 0: // stored
                decompressed = raw
            case 8: // deflate
                if let d = inflate(raw) { decompressed = d } else { decompressed = raw }
            default:
                offset = dataEnd
                continue
            }
            if !name.hasSuffix("/") {
                result[name] = decompressed
            }
            offset = dataEnd
        }
        return result
    }

    /// DEFLATE 解压（raw deflate 流 —— xlsx 里的压缩就是 raw deflate，无 zlib 头）
    private static func inflate(_ data: Data) -> Data? {
        // 用 Apple 的 Compression 框架，algorithm .zlib 处理 raw deflate
        return data.withUnsafeBytes { srcBuf -> Data? in
            guard let src = srcBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dstCapacity = max(data.count * 4, 1024)
            var out = Data(count: dstCapacity)
            let written = out.withUnsafeMutableBytes { dstBuf -> Int in
                guard let dst = dstBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, dstCapacity, src, data.count, nil, COMPRESSION_ZLIB)
            }
            guard written > 0 else { return nil }
            return out.prefix(written)
        }
    }

    // MARK: - XML 解析（sharedStrings + sheet）

    private static func parseSharedStrings(_ data: Data) -> [String] {
        let xml = String(data: data, encoding: .utf8) ?? ""
        var result: [String] = []
        // 提取所有 <si>...</si>，内部取所有 <t> 文本拼接（含富文本 <r> 多段）
        let sis = matches(xml, between: "<si>", and: "</si>")
        for si in sis {
            let ts = matches(si, between: "<t", and: "</t>")
            let text = ts.map { t -> String in
                if let gt = t.range(of: ">") {
                    return String(t[gt.upperBound...])
                }
                return t
            }.joined()
            result.append(unescape(text))
        }
        return result
    }

    private static func parseSheet(_ data: Data, sharedStrings: [String]) -> [ParsedRow] {
        let xml = String(data: data, encoding: .utf8) ?? ""
        let rows = matches(xml, between: "<row", and: "</row>")

        var dateCol = -1, kgCol = -1, noteCol = -1
        var factor = 1.0          // 单位换算系数：斤→kg 为 0.5
        var headerIndex = -1

        // 在前若干行里找表头（同时命中「日期」「体重」），按单元格 ref 字母定位列，识别单位
        let scanCount = min(rows.count, 10)
        for i in 0..<scanCount {
            let cells = parseCells(rows[i])
            var d = -1, k = -1, n = -1
            var isJin = false
            for cell in cells {
                let v = cell.text(sharedStrings).trimmingCharacters(in: .whitespaces)
                if v.isEmpty { continue }
                let ci = columnIndex(cell.ref)
                if ci < 0 { continue }
                if v.contains("日期") || v.lowercased() == "date" { d = ci }
                if v.contains("体重") || v.lowercased() == "weight" || v.lowercased() == "kg" {
                    k = ci
                    if v.contains("斤") { isJin = true }
                }
                if v.contains("备注") || v.lowercased() == "note" || v.contains("说明") { n = ci }
            }
            if d >= 0 && k >= 0 {
                dateCol = d
                kgCol = k
                noteCol = n
                factor = isJin ? 0.5 : 1.0
                headerIndex = i
                break
            }
        }

        // 没识别出表头：兜底按 A 列日期、B 列体重
        if dateCol < 0 || kgCol < 0 {
            dateCol = 0
            kgCol = 1
            noteCol = -1
            headerIndex = -1
        }

        var out: [ParsedRow] = []
        for (idx, row) in rows.enumerated() {
            if headerIndex >= 0 && idx <= headerIndex { continue } // 跳过表头及之前的行
            var dateRaw = "", kgRaw = "", noteRaw = ""
            for cell in parseCells(row) {
                let ci = columnIndex(cell.ref)
                if ci == dateCol { dateRaw = cell.text(sharedStrings) }
                else if ci == kgCol { kgRaw = cell.text(sharedStrings) }
                else if noteCol >= 0 && ci == noteCol { noteRaw = cell.text(sharedStrings) }
            }
            guard let date = normalizeDate(dateRaw), let raw = Double(kgRaw), raw > 0 else { continue }
            let kg = raw * factor
            out.append(ParsedRow(date: date, kg: kg, note: noteRaw.trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    /// 解析一行里的所有 <c> 单元格（兼容 <c ...>...</c> 与自闭合 <c .../>）
    private struct Cell {
        let ref: String
        let type: String
        let value: String
        let sharedIndex: Int?

        func text(_ shared: [String]) -> String {
            if type == "s", let idx = sharedIndex, idx < shared.count {
                return shared[idx]
            }
            return value
        }
    }

    private static func parseCells(_ rowXml: String) -> [Cell] {
        var cells: [Cell] = []
        // <c ...>...</c> 或自闭合 <c .../>；<c\b 避免误匹配 <col>
        let pattern = "<c\\b[^>]*?(?:/>|>.*?</c>)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return cells
        }
        let ns = rowXml as NSString
        let results = regex.matches(in: rowXml, range: NSRange(location: 0, length: ns.length))
        for m in results {
            cells.append(parseCell(ns.substring(with: m.range)))
        }
        return cells
    }

    private static func parseCell(_ block: String) -> Cell {
        // 只从 <c ...> 开标签上取 r / t 属性，避免误读 <f>/<v> 内部属性（如 <f t="shared">）
        let openTag: String
        if let gt = block.range(of: ">") {
            openTag = String(block[..<gt.upperBound])
        } else {
            openTag = block
        }
        let ref = attr(openTag, "r") ?? ""
        let type = attr(openTag, "t") ?? ""
        var value = ""
        var sharedIndex: Int? = nil
        if let vr = match(block, between: "<v>", and: "</v>") {
            value = vr
        } else if let istr = match(block, between: "<t>", and: "</t>") {
            // t="inlineStr" 行内字符串
            value = istr
        }
        if type == "s", let vi = Int(value) {
            sharedIndex = vi
        }
        return Cell(ref: ref, type: type, value: value, sharedIndex: sharedIndex)
    }

    /// 把单元格引用（如 "B5"、"AA12"）转成 0 基列号；空/非法返回 -1
    private static func columnIndex(_ ref: String) -> Int {
        var idx = 0
        var seenLetter = false
        for scalar in ref.unicodeScalars {
            let v = scalar.value
            if v >= 65 && v <= 90 { // A-Z
                idx = idx * 26 + Int(v - 64)
                seenLetter = true
            } else {
                break
            }
        }
        return seenLetter ? idx - 1 : -1
    }

    // MARK: - 日期归一化

    static func normalizeDate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        // Excel 日期序列号（1900 系统）
        if let serial = Double(t), serial > 10000, serial < 60000 {
            let epoch = Date(timeIntervalSince1970: 0)
            let days = serial - 25569
            let d = epoch.addingTimeInterval(days * 86400)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: d)
        }
        // YYYY-MM-DD / YYYY/M/D / YYYY.M.D
        let parts = t.components(separatedBy: CharacterSet(charactersIn: "-/."))
        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
           (1900...2100).contains(y), (1...12).contains(m), (1...31).contains(d) {
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        return nil
    }

    // MARK: - 轻量字符串工具

    private static func matches(_ s: String, between start: String, and end: String) -> [String] {
        var result: [String] = []
        var searchRange = s.startIndex..<s.endIndex
        while let r = s.range(of: start, range: searchRange) {
            let contentStart = r.upperBound
            guard let e = s.range(of: end, range: contentStart..<s.endIndex) else { break }
            result.append(String(s[contentStart..<e.lowerBound]))
            searchRange = e.upperBound..<s.endIndex
        }
        return result
    }

    private static func match(_ s: String, between start: String, and end: String) -> String? {
        matches(s, between: start, and: end).first
    }

    private static func attr(_ block: String, _ name: String) -> String? {
        let pattern = name + "=\""
        guard let r = block.range(of: pattern) else { return nil }
        let valStart = r.upperBound
        guard let end = block.range(of: "\"", range: valStart..<block.endIndex) else { return nil }
        return String(block[valStart..<end.lowerBound])
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#10;", with: "\n")
    }
}

/// 大端/小端读取辅助
private struct DataReader {
    let data: Data
    init(_ d: Data) { data = d }

    func u16(_ o: Int) -> Int {
        guard o + 2 <= data.count else { return 0 }
        return Int(data[o]) | (Int(data[o + 1]) << 8)
    }

    func u32(_ o: Int) -> Int {
        guard o + 4 <= data.count else { return 0 }
        return Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
    }
}
