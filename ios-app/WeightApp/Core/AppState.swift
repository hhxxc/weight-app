import Foundation
import SwiftUI

/// 自动下载完成的新版本（用于弹提示让用户点击安装）
struct PendingUpdate {
    let version: String
    let fileURL: URL
}

/// 全 App 唯一会话状态：登录态、用户资料、体重/饮食数据缓存。
/// 通过 environmentObject 注入，所有视图共享。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isLoggedIn: Bool
    @Published var user: UserProfile?
    @Published var weights: [WeightRecord] = [] {
        didSet { rebuildSorted() }
    }
    @Published var meals: [MealRecord] = []
    /// meals 当前对应的日期（用于切日期时判断是否可直接使用）
    @Published private(set) var mealsDate: String?
    /// 饮食请求进行中（切到未缓存的日期时显示加载态）
    @Published private(set) var isLoadingMeals = false
    /// 今日已摄入（首页卡片用，来自 /meals/summary 或当天 meals）
    @Published private(set) var todayKcal: Double = 0
    @Published private(set) var todayMealCount: Int = 0
    @Published private(set) var todayKcalLoaded = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pendingUpdate: PendingUpdate?
    /// 轻提示（保存成功、离线待同步等），2.4 秒后自动消失
    @Published var toast: String?

    /// 排序结果缓存：避免每次 body 重新排序（列表滚动更顺）
    private(set) var sortedAsc: [WeightRecord] = []
    private(set) var sortedDesc: [WeightRecord] = []
    private var isSyncingPending = false

    // 饮食：按日期的内存缓存 + 当前请求日期（防快速切日期时结果串台）
    private var mealCache: [String: [MealRecord]] = [:]
    private var mealCacheOrder: [String] = []
    private var mealRequestDate: String?

    private init() {
        isLoggedIn = APIClient.shared.token != nil
        // 冷启动先读磁盘缓存，第一帧就有内容，再等网络刷新
        if isLoggedIn { loadCache() }
        rebuildSorted()
    }

    // MARK: - 本地缓存

    private func loadCache() {
        if let u = CacheStore.load(UserProfile.self, "user") { user = u }
        if let w = CacheStore.load([WeightRecord].self, "weights") { weights = w }
    }

    private func cacheSnapshot() {
        if let u = user { CacheStore.save(u, "user") }
        CacheStore.save(weights, "weights")
    }

    private func rebuildSorted() {
        sortedAsc = weights.sorted { $0.date < $1.date }
        sortedDesc = Array(sortedAsc.reversed())
    }

    /// 本地立即生效（乐观更新）：不等网络，先把这条记录插进列表
    func applyLocalWeight(date: String, kg: Double, note: String) {
        var list = weights.filter { $0.date != date }
        list.append(WeightRecord(id: Int(-Date().timeIntervalSince1970 * 1000), date: date, kg: kg, note: note))
        weights = list
        cacheSnapshot()
    }

    /// 本地先移除（删除乐观更新），失败后由调用方 refresh 回滚
    func removeLocalWeights(dates: [String]) {
        let set = Set(dates)
        weights = weights.filter { !set.contains($0.date) }
        cacheSnapshot()
    }

    /// 更新资料并同步本地缓存（改身高/目标后，BMI 与预测立即生效）
    func updateUser(_ u: UserProfile) {
        user = u
        CacheStore.save(u, "user")
    }

    // MARK: - 登录 / 登出

    func handleAuth(_ resp: AuthResponse) {
        APIClient.shared.setToken(resp.token)
        user = resp.user
        isLoggedIn = true
        cacheSnapshot()
        AppLogger.shared.log("登录成功：\(resp.user.username)")
    }

    func logout() {
        APIClient.shared.logout()
        isLoggedIn = false
        user = nil
        weights = []
        meals = []
        mealsDate = nil
        mealCache.removeAll()
        mealCacheOrder.removeAll()
        mealRequestDate = nil
        PendingSync.clear()
        PendingMealSync.clear()
        CacheStore.clearAll()
        AppLogger.shared.log("退出登录")
    }

    /// 401 时调用：清 token 踢回登录页
    func forceLogout() {
        APIClient.shared.logout()
        isLoggedIn = false
        user = nil
        weights = []
        meals = []
        mealsDate = nil
        mealCache.removeAll()
        mealCacheOrder.removeAll()
        mealRequestDate = nil
        PendingMealSync.clear()
        CacheStore.clearAll()
        AppLogger.shared.log("token 失效，强制登出")
    }

    // MARK: - 轻提示

    func showToast(_ text: String) {
        toast = text
        let expected = text
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            await MainActor.run {
                if self.toast == expected { self.toast = nil }
            }
        }
    }

    // MARK: - 数据加载

    @MainActor
    func bootstrap() async {
        guard isLoggedIn else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // 资料和体重并行拉取：省一个 RTT，启动更快
            async let meRequest = APIClient.shared.fetchMe()
            async let weightsRequest = APIClient.shared.fetchWeights()
            let (u, w) = try await (meRequest, weightsRequest)
            user = u
            weights = w
            errorMessage = nil
            cacheSnapshot()
            AppLogger.shared.log("启动加载：\(w.count) 条体重记录")
            await flushPending()
            await refreshTodaySummary()
        } catch APIError.unauthorized {
            forceLogout()
        } catch {
            // 有缓存时不打扰用户，静默失败继续用缓存
            if weights.isEmpty {
                errorMessage = error.localizedDescription
                showToast("加载失败，下拉重试")
            }
            AppLogger.shared.log("启动加载失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    func refreshWeights() async {
        do {
            weights = try await APIClient.shared.fetchWeights()
            cacheSnapshot()
        } catch APIError.unauthorized {
            forceLogout()
        } catch {
            AppLogger.shared.log("刷新体重失败：\(error.localizedDescription)")
            if weights.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    @MainActor
    func refreshMeals(date: String? = nil) async {
        guard let d = date else {
            // 不传日期 = 全量（导出/统计等场景）
            do {
                meals = try await APIClient.shared.fetchMeals(date: nil)
                mealsDate = nil
            } catch APIError.unauthorized {
                forceLogout()
            } catch {
                AppLogger.shared.log("刷新饮食失败：\(error.localizedDescription)")
            }
            return
        }

        // 1) 先用缓存秒出内容：内存 → 磁盘（离线也能看历史）
        if let cached = mealCache[d] {
            meals = cached
            mealsDate = d
            syncToday(from: cached, date: d)
        } else if let disk = CacheStore.load([MealRecord].self, "meals-\(d)") {
            rememberMeals(d, disk)
            meals = disk
            mealsDate = d
            syncToday(from: disk, date: d)
        }

        // 2) 再拉最新；期间用户切了日期就丢弃这次结果，避免串台
        mealRequestDate = d
        isLoadingMeals = true
        defer { if mealRequestDate == d { isLoadingMeals = false } }
        do {
            let fresh = try await APIClient.shared.fetchMeals(date: d)
            guard mealRequestDate == d else { return }
            meals = fresh
            mealsDate = d
            syncToday(from: fresh, date: d)
            rememberMeals(d, fresh)
            CacheStore.save(fresh, "meals-\(d)")
        } catch APIError.unauthorized {
            forceLogout()
        } catch {
            AppLogger.shared.log("刷新饮食失败(\(d))：\(error.localizedDescription)")
        }
    }

    /// 把某天的饮食汇总同步到「今日」指标（首页卡片）
    private func syncToday(from list: [MealRecord], date: String) {
        guard date == WeightRecord.dateFormatter.string(from: Date()) else { return }
        todayKcal = list.reduce(0.0) { $0 + ($1.kcal ?? 0) }
        todayMealCount = list.count
        todayKcalLoaded = true
    }

    /// 拉今日汇总（首页未打开饮食页时也能显示预算）
    @MainActor
    func refreshTodaySummary() async {
        let today = WeightRecord.dateFormatter.string(from: Date())
        if mealsDate == today {
            syncToday(from: meals, date: today)
            return
        }
        do {
            let items = try await APIClient.shared.fetchMealSummary(from: today, to: today)
            if let first = items.first {
                todayKcal = first.kcal ?? 0
                todayMealCount = first.count
            } else {
                todayKcal = 0
                todayMealCount = 0
            }
            todayKcalLoaded = true
        } catch {
            // 拉不到就退回本地缓存；再没有就显示 0，避免一直卡在「读取中」
            let cached = cachedMeals(for: today)
            if !cached.isEmpty {
                syncToday(from: cached, date: today)
            } else {
                todayKcalLoaded = true
            }
        }
    }

    /// 同步取某天的缓存（内存优先，其次磁盘），用于切日期时零等待展示
    func cachedMeals(for date: String) -> [MealRecord] {
        if let m = mealCache[date] { return m }
        if let disk = CacheStore.load([MealRecord].self, "meals-\(date)") {
            mealCache[date] = disk
            mealCacheOrder.removeAll { $0 == date }
            mealCacheOrder.append(date)
            return disk
        }
        return []
    }

    /// 预热相邻日期（不改动当前 meals），让前后翻页也瞬间出内容
    @MainActor
    func prefetchMeals(date: String) async {
        if mealCache[date] != nil { return }
        do {
            let fresh = try await APIClient.shared.fetchMeals(date: date)
            rememberMeals(date, fresh)
            CacheStore.save(fresh, "meals-\(date)")
        } catch {
            // 预热失败无所谓，用户真正切过去时会再拉
        }
    }

    /// 内存 LRU：只留最近 14 天，淘汰时连磁盘一起清，避免缓存无限增长
    private func rememberMeals(_ date: String, _ list: [MealRecord]) {
        mealCache[date] = list
        mealCacheOrder.removeAll { $0 == date }
        mealCacheOrder.append(date)
        while mealCacheOrder.count > 14 {
            let old = mealCacheOrder.removeFirst()
            mealCache.removeValue(forKey: old)
            CacheStore.remove("meals-\(old)")
        }
    }

    /// 把离线期间的记录（体重 + 饮食）补传到服务器，失败则保留，下次启动/回前台再试
    @MainActor
    func flushPending() async {
        guard !isSyncingPending else { return }
        let weightItems = PendingSync.all()
        let mealItems = PendingMealSync.all()
        guard !weightItems.isEmpty || !mealItems.isEmpty else { return }
        isSyncingPending = true
        defer { isSyncingPending = false }

        var wUploaded = 0
        for item in weightItems {
            do {
                _ = try await APIClient.shared.saveWeight(date: item.date, kg: item.kg, note: item.note)
                PendingSync.remove(id: item.id)
                wUploaded += 1
            } catch {
                break   // 网络仍不通，保留队列下次再试
            }
        }

        var mUploaded = 0
        for item in mealItems {
            do {
                _ = try await APIClient.shared.saveMeal(date: item.date, type: item.type,
                                                        content: item.content, kcal: item.kcal,
                                                        protein_g: item.protein_g, fat_g: item.fat_g,
                                                        carbs_g: item.carbs_g, image_url: item.image_url,
                                                        clientId: item.client_id)
                PendingMealSync.remove(id: item.id)
                mUploaded += 1
            } catch {
                break
            }
        }

        if wUploaded > 0 { await refreshWeights() }
        if mUploaded > 0, let d = mealsDate { await refreshMeals(date: d) }
        if wUploaded + mUploaded > 0 {
            showToast("已同步 \(wUploaded + mUploaded) 条离线记录")
        }
    }

    // MARK: - 饮食保存（离线兜底）

    enum MealSaveOutcome {
        case synced
        case queued
        case failed(String)
    }

    /// 保存一条饮食记录：成功即刷新；网络失败转入离线队列（不丢记录）
    /// clientId 保证「接口重试 + 离线补传」都不会产生重复记录
    @MainActor
    func saveMealResilient(date: String, type: String, content: String,
                           kcal: Double?, protein_g: Double?, fat_g: Double?,
                           carbs_g: Double?, image_url: String?) async -> MealSaveOutcome {
        let clientId = UUID().uuidString
        do {
            _ = try await APIClient.shared.saveMeal(date: date, type: type, content: content,
                                                    kcal: kcal, protein_g: protein_g, fat_g: fat_g,
                                                    carbs_g: carbs_g, image_url: image_url,
                                                    clientId: clientId)
            await refreshMeals(date: date)
            return .synced
        } catch APIError.unauthorized {
            forceLogout()
            return .failed("登录已过期，请重新登录")
        } catch APIError.noToken {
            return .failed("未登录")
        } catch APIError.server(let msg) {
            return .failed(msg)
        } catch {
            PendingMealSync.add(date: date, type: type, content: content, kcal: kcal,
                                protein_g: protein_g, fat_g: fat_g, carbs_g: carbs_g,
                                image_url: image_url, clientId: clientId)
            AppLogger.shared.log("饮食保存失败，已入离线队列：\(content)")
            return .queued
        }
    }

    // MARK: - 自动更新

    /// 自动检测更新并后台下载；下载完成设置 pendingUpdate，由界面弹提示。
    func autoCheckUpdate() async {
        guard isLoggedIn else { return }
        let result = await UpdateChecker.checkAppUpdate()
        guard case .updateAvailable(_, let latest, _, let ipaURL) = result, let url = ipaURL else {
            return
        }
        do {
            let file = try await UpdateChecker.download(ipaURL: url, version: latest)
            pendingUpdate = PendingUpdate(version: latest, fileURL: file)
            AppLogger.shared.log("自动更新：v\(latest) 已下载完成")
        } catch {
            AppLogger.shared.log("自动更新下载失败：\(error.localizedDescription)")
        }
    }

    /// 用户点击「立即更新」：调起系统分享面板，选 TrollStore 安装
    func installPendingUpdate() {
        guard let u = pendingUpdate else { return }
        IPAShare.share(fileURL: u.fileURL, title: "体重记录 v\(u.version)")
        pendingUpdate = nil
    }
}
