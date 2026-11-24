import SwiftUI
import UIKit

@main
struct GameShelfApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = GameStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(TT.navy)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // tab bar 配色。iOS 26 起系统用悬浮玻璃条，背景色由系统接管；
        // 这里主要保证旧系统是不透明浅底，以及三种状态下的图标/文字颜色。
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 1, green: 1, blue: 1, alpha: 0.97)
        appearance.shadowColor = UIColor(red: 0, green: 0.169, blue: 0.314, alpha: 0.10)

        let navy = UIColor(red: 0, green: 0.169, blue: 0.314, alpha: 1)
        let idle = UIColor(red: 0, green: 0.169, blue: 0.314, alpha: 0.42)

        let stacked = appearance.stackedLayoutAppearance
        stacked.normal.iconColor = idle
        stacked.normal.titleTextAttributes = [
            .foregroundColor: idle,
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold)
        ]
        stacked.selected.iconColor = navy
        stacked.selected.titleTextAttributes = [
            .foregroundColor: navy,
            .font: UIFont.systemFont(ofSize: 10, weight: .bold)
        ]

        let inline = appearance.inlineLayoutAppearance
        inline.normal.iconColor = idle
        inline.normal.titleTextAttributes = [.foregroundColor: idle]
        inline.selected.iconColor = navy
        inline.selected.titleTextAttributes = [.foregroundColor: navy]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = idle

        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationController.shared.mask
    }
}
