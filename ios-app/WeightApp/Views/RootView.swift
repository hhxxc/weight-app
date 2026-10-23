import SwiftUI

/// 根视图：未登录 → 登录；已登录 → 主界面（Tab）
struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = false

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
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .onAppear { showOnboarding = state.needsOnboarding }
        .onChange(of: state.isLoggedIn) { loggedIn in
            showOnboarding = loggedIn && state.needsOnboarding
        }
        .accentColor(Theme.brandDeep)   // 全局强调色：品牌深青
        .overlay(alignment: .top) {
            if let t = state.toast {
                Text(t)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.toast)
        .onChange(of: scenePhase) { phase in
            // 回到前台时补传离线记录（守卫在 AppState 内部，重复调用安全）
            if phase == .active, state.isLoggedIn {
                Task {
                    await state.flushPending()
                    await state.refreshTodaySummary()
                }
            }
        }
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
