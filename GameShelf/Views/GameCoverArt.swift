import SwiftUI

/// 统一的封面绘制。
///
/// 优先级：**上次退出的截图 → APK 应用图标 → 引擎渐变 + 首字母**。
/// 三者都只占一层，所以卡片不会因为有没有封面而换一套版式。
struct GameCoverArt: View {
    let game: GameRecord
    /// 图标占短边的比例（列表缩略图可以调大一点）
    var iconFraction: CGFloat = 0.52
    /// 截图上的压暗强度：卡片上要保证白色标题看得清，详情页可以轻一些
    var scrim: Double = 1

    @ObservedObject private var covers = CoverStore.shared

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let short = min(w, h)

            ZStack {
                LinearGradient(
                    colors: TT.gradient(for: game.engine),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let cover = covers.cover(for: game.id) {
                    switch cover.kind {
                    case .shot:
                        Image(uiImage: cover.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w, height: h)
                            .clipped()
                            // fill 模式的图布局尺寸比框大，触摸判定会跟着溢出框外，
                            // 压到旁边磁贴上（点这张卡右边会打开隔壁）——限定回框内
                            .contentShape(Rectangle())

                        LinearGradient(
                            colors: [
                                .black.opacity(0.10 * scrim),
                                .black.opacity(0.02),
                                .black.opacity(0.16 * scrim),
                                .black.opacity(0.62 * scrim)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                    case .icon:
                        // 图标是方的，铺满会把上下切掉，所以居中放，底下留引擎渐变做底
                        Text(game.initial)
                            .font(.system(size: short * 0.86, weight: .black))
                            .foregroundStyle(.white.opacity(0.13))
                            .frame(width: w, height: h)
                            .clipped()

                        Image(uiImage: cover.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: short * iconFraction, height: short * iconFraction)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: short * iconFraction * 0.24,
                                    style: .continuous
                                )
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: short * iconFraction * 0.24,
                                    style: .continuous
                                )
                                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                            }
                            .shadow(color: .black.opacity(0.26), radius: short * 0.07, y: short * 0.03)
                    }
                } else {
                    Text(game.initial)
                        .font(.system(size: short * 0.86, weight: .black))
                        .foregroundStyle(.white.opacity(0.16))
                        .frame(width: w, height: h)
                        .clipped()
                }
            }
            .frame(width: w, height: h)
        }
    }
}

/// 列表行左侧的小缩略图
struct GameCoverThumb: View {
    let game: GameRecord

    var body: some View {
        GameCoverArt(game: game, iconFraction: 0.62, scrim: 0.4)
            .frame(width: 56, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
