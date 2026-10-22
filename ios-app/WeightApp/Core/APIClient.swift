import Foundation

/// 后端 REST API 客户端。
/// - 主备地址自动互换：主地址连不上就试备用地址，成功一次后记住当前可用地址
/// - 业务 401 → 清 token 并广播登出（token 随服务端重启失效）
enum APIError: Error, LocalizedError {
    case badURL
    case noToken
    case network(String)
    case server(String)
    case unauthorized
    case decode

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效"
        case .noToken: return "未登录"
        case .network(let m): return m
        case .server(let m): return m
        case .unauthorized: return "登录已过期，请重新登录"
        case .decode: return "数据解析失败"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    /// 当前生效的服务器地址（不含结尾斜杠）
    private(set) var activeServer: String

    /// 登录后缓存的 token（内存，配合 Keychain 持久化）
    private(set) var token: String?

    private let session: URLSession

    private let serverKey = "weight.server"
    private let tokenKey = "weight.token.fallback"

    private init() {
        // 图片走 URLCache 磁盘缓存：食物照片二次浏览不再重复下载
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "weightapp-images")

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15   // 普通接口快速失败（AI 接口单独放宽）
        cfg.timeoutIntervalForResource = 90
        cfg.urlCache = URLCache.shared
        cfg.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: cfg)

        activeServer = UserDefaults.standard.string(forKey: serverKey) ?? AppConfig.defaultServer
        // token 优先从 Keychain 读，失败回退 UserDefaults
        token = Keychain.get() ?? UserDefaults.standard.string(forKey: tokenKey)
    }

    // MARK: - 地址管理

    func setServer(_ s: String) {
        activeServer = s
        UserDefaults.standard.set(s, forKey: serverKey)
    }

    /// 把后端返回的相对图片路径（如 /uploads/xxx.jpg）拼成完整 URL
    func imageURL(for path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("http://") || p.hasPrefix("https://") { return URL(string: p) }
        return URL(string: activeServer + p)
    }

    /// 主备地址列表：当前生效地址优先，另一个兜底
    private var candidateServers: [String] {
        var list = [activeServer]
        if activeServer != AppConfig.defaultServer { list.append(AppConfig.defaultServer) }
        if activeServer != AppConfig.defaultBackupServer { list.append(AppConfig.defaultBackupServer) }
        return list
    }

    // MARK: - Token 管理

    func setToken(_ t: String?) {
        token = t
        if let t, !t.isEmpty {
            if !Keychain.set(t) { UserDefaults.standard.set(t, forKey: tokenKey) }
        } else {
            Keychain.clear()
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
    }

    func logout() {
        setToken(nil)
    }

    // MARK: - 请求核心

    private func request<T: Decodable>(_ method: String, _ path: String,
                                       body: Encodable? = nil,
                                       auth: Bool = true) async throws -> T {
        // 依次尝试主备地址；网络抖动时同一地址先快速重试一次
        var lastError: APIError = .badURL
        for server in candidateServers {
            for attempt in 0..<2 {
                do {
                    let r: T = try await requestOnce(method, server, path, body: body, auth: auth)
                    // 成功：记住这个地址（主备自动切换生效）
                    if server != activeServer {
                        activeServer = server
                        UserDefaults.standard.set(server, forKey: serverKey)
                        AppLogger.shared.log("服务器切换为：\(server)")
                    }
                    return r
                } catch APIError.unauthorized {
                    // 401 是业务层错误，不该换地址重试，直接抛
                    throw APIError.unauthorized
                } catch let e as APIError {
                    lastError = e
                    AppLogger.shared.log("请求失败 \(server)\(path) 第\(attempt + 1)次: \(e.errorDescription ?? "未知")")
                    var retryable = false
                    if case .network = e { retryable = true }
                    if retryable && attempt == 0 {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        continue
                    }
                    break
                }
            }
        }
        throw lastError
    }

    /// 按接口类型分配超时：AI 识图/上传/生成建议慢，普通 CRUD 快速失败
    private func timeoutSeconds(for path: String) -> TimeInterval {
        if path.hasPrefix("/foods") || path.hasPrefix("/upload") || path.hasPrefix("/advice") { return 60 }
        return 15
    }

    private func requestOnce<T: Decodable>(_ method: String, _ server: String, _ path: String,
                                           body: Encodable?, auth: Bool) async throws -> T {
        guard let url = URL(string: server + AppConfig.apiPrefix + path) else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeoutSeconds(for: path)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth {
            guard let t = token else { throw APIError.noToken }
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.network("网络连接失败，请检查网络")
        }

        guard let http = resp as? HTTPURLResponse else {
            throw APIError.network("响应异常")
        }

        if http.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200..<300).contains(http.statusCode) else {
            var msg = "服务器错误（\(http.statusCode)）"
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                msg = err.error
            }
            throw APIError.server(msg)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decode
        }
    }

    // MARK: - 业务接口

    struct RegisterBody: Encodable { let username: String; let password: String; let nickname: String }
    struct LoginBody: Encodable { let username: String; let password: String }

    func register(username: String, password: String, nickname: String) async throws -> AuthResponse {
        try await request("POST", "/auth/register", body: RegisterBody(username: username, password: password, nickname: nickname), auth: false)
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        try await request("POST", "/auth/login", body: LoginBody(username: username, password: password), auth: false)
    }

    func fetchMe() async throws -> UserProfile {
        let r: [String: UserProfile] = try await request("GET", "/me")
        guard let u = r["user"] else { throw APIError.decode }
        return u
    }

    struct UpdateMeBody: Encodable { let nickname: String; let height_cm: Double?; let target_kg: Double? }
    func updateMe(nickname: String, heightCm: Double?, targetKg: Double?) async throws -> UserProfile {
        let r: [String: UserProfile] = try await request("PUT", "/me", body: UpdateMeBody(nickname: nickname, height_cm: heightCm, target_kg: targetKg))
        guard let u = r["user"] else { throw APIError.decode }
        return u
    }

    func fetchWeights() async throws -> [WeightRecord] {
        let r: WeightListResponse = try await request("GET", "/weights")
        return r.items
    }

    struct WeightBody: Encodable { let date: String; let kg: Double; let note: String }
    func saveWeight(date: String, kg: Double, note: String) async throws -> WeightRecord {
        let r: WeightItemResponse = try await request("POST", "/weights", body: WeightBody(date: date, kg: kg, note: note))
        return r.item
    }

    func deleteWeight(date: String) async throws {
        let _: [String: Bool] = try await request("DELETE", "/weights/\(date)")
    }

    struct ImportItem: Encodable { let date: String; let kg: Double; let note: String }
    struct ImportBody: Encodable { let items: [ImportItem] }
    func importWeights(_ items: [ImportItem]) async throws -> Int {
        let r: [String: Int] = try await request("POST", "/weights/import", body: ImportBody(items: items))
        return r["imported"] ?? 0
    }

    func fetchMeals(date: String? = nil) async throws -> [MealRecord] {
        let path = date.map { "/meals?date=\($0)" } ?? "/meals"
        let r: MealListResponse = try await request("GET", path)
        return r.items
    }

    struct MealBody: Encodable {
        let date: String; let type: String; let content: String
        let kcal: Double?; let protein_g: Double?; let fat_g: Double?; let carbs_g: Double?; let image_url: String?
    }
    func saveMeal(date: String, type: String, content: String,
                  kcal: Double? = nil, protein_g: Double? = nil, fat_g: Double? = nil,
                  carbs_g: Double? = nil, image_url: String? = nil) async throws -> MealRecord {
        let r: MealItemResponse = try await request("POST", "/meals", body: MealBody(
            date: date, type: type, content: content,
            kcal: kcal, protein_g: protein_g, fat_g: fat_g, carbs_g: carbs_g, image_url: image_url))
        return r.item
    }

    func deleteMeal(id: Int) async throws {
        let _: [String: Bool] = try await request("DELETE", "/meals/\(id)")
    }

    func updateMeal(id: Int, date: String, type: String, content: String,
                    kcal: Double? = nil, protein_g: Double? = nil, fat_g: Double? = nil,
                    carbs_g: Double? = nil, image_url: String? = nil) async throws -> MealRecord {
        let r: MealItemResponse = try await request("PUT", "/meals/\(id)", body: MealBody(
            date: date, type: type, content: content,
            kcal: kcal, protein_g: protein_g, fat_g: fat_g, carbs_g: carbs_g, image_url: image_url))
        return r.item
    }

    // MARK: - 食物识图 / 配料表 OCR / 图片上传

    struct FoodRecognition: Decodable {
        let food: String; let weight_g: Double
        let kcal: Double; let protein_g: Double; let fat_g: Double; let carbs_g: Double
    }
    struct NutritionInfo: Decodable {
        let name: String; let energy_kj: Double; let energy_kcal: Double
        let protein_g: Double; let fat_g: Double; let carbs_g: Double
    }
    struct FoodEstimation: Decodable {
        let food: String
        let kcal: Double; let protein_g: Double; let fat_g: Double; let carbs_g: Double
    }
    struct ImageBody: Encodable { let image_base64: String; let ext: String }
    struct TextBody: Encodable { let text: String }

    func recognizeFood(imageBase64: String) async throws -> FoodRecognition {
        try await request("POST", "/foods/recognize", body: ImageBody(image_base64: imageBase64, ext: "jpg"))
    }

    func ocrNutrition(imageBase64: String) async throws -> NutritionInfo {
        try await request("POST", "/foods/ocr", body: ImageBody(image_base64: imageBase64, ext: "jpg"))
    }

    /// 文字描述估卡路里（语音记录 / 手动描述）
    func estimateFood(text: String) async throws -> FoodEstimation {
        try await request("POST", "/foods/estimate", body: TextBody(text: text))
    }

    func uploadImage(imageBase64: String, ext: String) async throws -> String {
        let r: [String: String] = try await request("POST", "/upload", body: ImageBody(image_base64: imageBase64, ext: ext))
        return r["url"] ?? ""
    }

    // MARK: - 统计 + AI 建议

    struct StatsResponse: Decodable {
        struct WeightStats: Decodable {
            let start_kg: Double?; let current_kg: Double?; let target_kg: Double?
            let lost_kg: Double?; let height_cm: Double?; let bmi: Double?; let bmi_category: String?
            let record_count: Int
        }
        struct CaloriesStats: Decodable {
            let today_kcal: Double; let avg7_kcal: Double; let avg30_kcal: Double
        }
        struct NutritionStats: Decodable {
            let avg7_protein_g: Double; let avg7_fat_g: Double; let avg7_carbs_g: Double
        }
        struct DailyPoint: Decodable, Identifiable {
            var id: String { date }
            let date: String; let kg: Double?; let kcal: Double
            let protein_g: Double; let fat_g: Double; let carbs_g: Double
        }
        let weight: WeightStats
        let calories: CaloriesStats
        let nutrition: NutritionStats
        let daily: [DailyPoint]
    }

    func fetchStats() async throws -> StatsResponse {
        try await request("GET", "/stats")
    }

    func fetchAdvice() async throws -> String {
        let r: [String: String] = try await request("GET", "/advice")
        return r["advice"] ?? ""
    }
}
