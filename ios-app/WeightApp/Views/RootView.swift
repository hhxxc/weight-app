import SwiftUI

/// 根视图：未登录 → 登录；已登录 → 主界面（Tab）
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.isLoggedIn {
                MainTabView()
                    .task { await state.bootstrap() }
            } else {
                LoginView()
            }
        }
        .accentColor(Theme.brandDeep)   // 全局强调色：品牌深青
    }
}
