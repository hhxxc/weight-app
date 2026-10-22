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
    @Published var weights: [WeightRecord] = []
    @Published var meals: [MealRecord] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pendingUpdate: PendingUpdate?

    private init() {
        isLoggedIn = APIClient.shared.token != nil
        // 有 token 但没缓存的 user，启动后 fetchMe 补上
    }

    // MARK: - 登录 / 登出

    func handleAuth(_ resp: AuthResponse) {
        APIClient.shared.setToken(resp.token)
        user = resp.user
        isLoggedIn = true
        AppLogger.shared.log("登录成功：\(resp.user.username)")
    }

    func logout() {
        APIClient.shared.logout()
        isLoggedIn = false
        user = nil
        weights = []
        meals = []
        AppLogger.shared.log("退出登录")
    }

    /// 401 时调用：清 token 踢回登录页
    func forceLogout() {
        APIClient.shared.logout()
        isLoggedIn = false
        user = nil
        AppLogger.shared.log("token 失效，强制登出")
    }

    // MARK: - 数据加载

    @MainActor
    func bootstrap() async {
        guard isLoggedIn else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            user = try await APIClient.shared.fetchMe()
            weights = try await APIClient.shared.fetchWeights()
            AppLogger.shared.log("启动加载：\(weights.count) 条体重记录")
        } catch APIError.unauthorized {
            forceLogout()
        } catch {
            AppLogger.shared.log("启动加载失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    func refreshWeights() async {
        do {
            weights = try await APIClient.shared.fetchWeights()
        } catch APIError.unauthorized {
            forceLogout()
        } catch {
            AppLogger.shared.log("刷新体重失败：\(error.localizedDescription)")
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
