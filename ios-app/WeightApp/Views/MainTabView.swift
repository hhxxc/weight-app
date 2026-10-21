import SwiftUI

/// 主界面：三个 Tab —— 体重 / 饮食 / 我的
struct MainTabView: View {
    var body: some View {
        TabView {
            WeightListView()
                .tabItem { Label("体重", systemImage: "scalemass") }
            MealListView()
                .tabItem { Label("饮食", systemImage: "fork.knife") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.circle") }
        }
    }
}
