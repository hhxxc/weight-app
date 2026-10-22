import SwiftUI

/// 根视图：未登录 → 登录；已登录 → 主界面（Tab）
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.isLoggedIn {
                MainTabView()
                    .task { await state.bootstrap() }
                    .task { await state.autoCheckUpdate() }
            } else {
                LoginView()
            }
        }
        .accentColor(Theme.brandDeep)   // 全局强调色：品牌深青
        .alert("发现新版本 v\(state.pendingUpdate?.version ?? "")",
               isPresented: Binding(
                   get: { state.pendingUpdate != nil },
                   set: { if !$0 { state.pendingUpdate = nil } }
               )) {
            Button("立即更新") { state.installPendingUpdate() }
            Button("稍后", role: .cancel) { state.pendingUpdate = nil }
        } message: {
            Text("新版本已自动下载完成，点击「立即更新」选 TrollStore 覆盖安装，数据保留。")
        }
    }
}
