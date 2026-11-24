import SwiftUI

/// 启动画面。
///
/// 游戏从点击到画出第一帧之间有一段空窗（解 pck、编译 wasm、Ruffle 初始化），
/// 以前是一块纯黑加一个转圈。现在改成：模糊的封面铺底 + 卡片缩略图 + 名字 + 一根细进度条，
/// 第一帧出来后整体淡出，看起来像"这张卡被打开"，而不是"App 卡住了"。
struct GameLaunchOverlay: View {
    let game: GameRecord
    @State private var sweep = false

    var body: some View {
        ZStack {
            Color.black

            GameCoverArt(game: game, scrim: 0.9)
                .opacity(0.55)
                .blur(radius: 26)
                .scaleEffect(1.15)

            LinearGradient(
                colors: [.black.opacity(0.42), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 16) {
                GameCoverArt(game: game, iconFraction: 0.62, scrim: 0)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

                VStack(spacing: 6) {
                    Text(game.title)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 44)
                    Text("\(game.engine.label) · 正在启动")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }

                track.padding(.top, 4)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var track: some View {
        Capsule()
            .fill(Color.white.opacity(0.16))
            .frame(width: 118, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 42, height: 3)
                    .offset(x: sweep ? 76 : 0)
            }
            .clipShape(Capsule())
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    sweep = true
                }
            }
    }
}
