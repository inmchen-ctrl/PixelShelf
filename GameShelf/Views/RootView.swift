import SwiftUI

/// 应用根视图：游戏库 / 设置 / 关于。
///
/// 三个页面各自管自己的导航与背景，这里只负责底部切换。
/// 游戏内页是 `fullScreenCover`，会整页盖住 tab bar。
struct RootView: View {
    private enum Tab: Hashable {
        case library, settings, about
    }

    @State private var tab: Tab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem {
                    Label("游戏库", systemImage: tab == .library
                          ? "square.grid.2x2.fill" : "square.grid.2x2")
                }
                .tag(Tab.library)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                .tag(Tab.settings)

            AboutView()
                .tabItem {
                    Label("关于", systemImage: tab == .about
                          ? "info.circle.fill" : "info.circle")
                }
                .tag(Tab.about)
        }
        .tint(TT.navy)
    }
}
