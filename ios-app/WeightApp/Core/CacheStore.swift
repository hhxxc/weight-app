import Foundation

/// 轻量本地缓存：最近一次成功拉取的数据写盘，冷启动先读缓存立即出内容，
/// 再等网络刷新回来覆盖——弱网/无网时 App 也不再是白屏。
/// 数据量很小（每条记录几百字节），直接用 JSON 存 Application Support。
enum CacheStore {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("WeightApp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private static func fileURL(_ name: String) -> URL {
        folder.appendingPathComponent("\(name).json")
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: fileURL(name), options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
    }

    /// 退出登录时清空全部缓存，避免换账号看到上一个人的数据
    static func clearAll() {
        for name in ["weights", "user", "pendingWeights", "stats"] { remove(name) }
        // 饮食按日期分文件缓存（meals-YYYY-MM-DD.json）
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("meals-") {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}

/// 离线待同步的体重记录：断网时先存本地，联网后自动补传，不丢记录
struct PendingWeight: Codable, Identifiable {
    var id: String
    var date: String
    var kg: Double
    var note: String
}

enum PendingSync {
    private static let name = "pendingWeights"

    static func all() -> [PendingWeight] {
        CacheStore.load([PendingWeight].self, name) ?? []
    }

    static func add(date: String, kg: Double, note: String) {
        // 同一天只保留最新一条（后端也是按天覆盖语义）
        var list = all().filter { $0.date != date }
        list.append(PendingWeight(id: UUID().uuidString, date: date, kg: kg, note: note))
        CacheStore.save(list, name)
    }

    static func remove(id: String) {
        CacheStore.save(all().filter { $0.id != id }, name)
    }

    static func count() -> Int { all().count }

    static func clear() { CacheStore.remove(name) }
}
