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
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pendingUpdate: PendingUpdate?
    /// 轻提示（保存成功、离线待同步等），2.4 秒后自动消失
    @Published var toast: String?

    /// 排序结果缓存：避免每次 body 重新排序（列表滚动更顺）
    private(set) var sortedAsc: [WeightRecord] = []
    private(set) var sortedDesc: [WeightRecord] = []
    private var isSyncingPending = false

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
        PendingSync.clear()
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
            cacheSnapshot()
            AppLogger.shared.log("启动加载：\(w.count) 条体重记录")
            await flushPendingWeights()
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
        do {
            meals = try await APIClient.shared.fetchMeals(date: date)
        } catch APIError.unauthorized {
            forceLogout()
        } catch {
            AppLogger.shared.log("刷新饮食失败：\(error.localizedDescription)")
        }
    }

    /// 把离线期间的记录补传到服务器（失败则保留，下次启动再试）
    @MainActor
    func flushPendingWeights() async {
        guard !isSyncingPending else { return }
        let items = PendingSync.all()
        guard !items.isEmpty else { return }
        isSyncingPending = true
        defer { isSyncingPending = false }

        var uploaded = 0
        for item in items {
            do {
                _ = try await APIClient.shared.saveWeight(date: item.date, kg: item.kg, note: item.note)
                PendingSync.remove(id: item.id)
                uploaded += 1
            } catch {
                break   // 网络仍不通，保留队列下次再试
            }
        }
        if uploaded > 0 {
            await refreshWeights()
            showToast("已同步 \(uploaded) 条离线记录")
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
