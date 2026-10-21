import Foundation
import SwiftUI

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
}
