import SwiftUI

/// 主界面：四个 Tab —— 体重 / 饮食 / 分析 / 我的
struct MainTabView: View {
    var body: some View {
        TabView {
            WeightListView()
                .tabItem { Label("体重", systemImage: "scalemass") }
            MealListView()
                .tabItem { Label("饮食", systemImage: "fork.knife") }
            StatsView()
                .tabItem { Label("分析", systemImage: "chart.bar.xaxis") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.circle") }
        }
        .accentColor(Theme.brandDeep)
    }
}
