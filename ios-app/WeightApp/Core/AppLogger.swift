import Foundation

/// 轻量操作日志：记录登录/退出/接口调用/错误，用于排查「点按钮没反应」。
/// 存内存 + UserDefaults（最多 200 条），设置页可查看/复制。
final class AppLogger {
    static let shared = AppLogger()

    private let maxEntries = 200
    private let key = "weight.applog"

    private(set) var entries: [String] = []

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)"
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        UserDefaults.standard.set(entries, forKey: key)
        print("[WeightLog] \(line)")
    }

    func clear() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
