import Foundation

/// 轻量操作日志：记录登录/退出/接口调用/错误，用于排查「点按钮没反应」。
/// 存内存 + UserDefaults（最多 200 条），设置页可查看/复制。
final class AppLogger {
    static let shared = AppLogger()

    private let maxEntries = 200
    private let key = "weight.applog"
    private let lock = NSLock()   // 启动时资料/体重并行请求，日志需串行写入

    private(set) var entries: [String] = []

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)"
        lock.lock()
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        UserDefaults.standard.set(entries, forKey: key)
        lock.unlock()
        print("[WeightLog] \(line)")
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
        lock.unlock()
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
