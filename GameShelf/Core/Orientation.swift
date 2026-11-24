import UIKit

/// 只在播放页锁横屏，其余时候不干预。
final class OrientationController {
    static let shared = OrientationController()

    var mask: UIInterfaceOrientationMask = .allButUpsideDown

    func lockLandscape() {
        mask = .landscape
        request(.landscapeRight)
    }

    func unlock() {
        mask = .allButUpsideDown
        request(.portrait)
    }

    private func request(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }

        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
