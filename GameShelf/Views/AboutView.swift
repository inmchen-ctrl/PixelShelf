import SwiftUI
import UIKit

/// 「关于」页：作者、技术栈、第三方组件与许可。
///
/// 这一页的文案是分发声明的一部分，改代码时别顺手删：
/// - 应用层源码用 MIT；
/// - mkxp-z 是 GPL-2.0，分发带引擎的整包时要一并满足它的要求；
/// - 游戏本体不在本应用内，版权归各自权利人。
struct AboutView: View {
    @State private var copiedKey: String?

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ZStack {
            DiamanteBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TTPageHeader(
                        eyebrow: "ABOUT",
                        title: "关于",
                        detail: "像素抽屉 · 本地游戏库"
                    ) { EmptyView() }

                    identityCard
                    authorCard

                    sectionLabel("许可与声明")

                    card {
                        paragraph("本应用的应用层源代码（GameShelf 目录下的 Swift 文件）依 MIT 许可证发布，Copyright © 2026 inmchen。被授权人可自由使用、复制、修改、合并、发布、再许可与销售，条件是在副本或实质性部分中保留版权声明与本许可全文。")

                        divider

                        paragraph("随分发包提供的引擎、运行时与静态库不在上述授权范围内，遵循各自上游项目的许可条款，逐项列于下方「开源组件」。许可证全文以对应上游仓库的发布版本为准。")

                        divider

                        paragraph("分发包内含 mkxp-z 与 OpenAL Soft、FluidSynth 等 LGPL 组件。mkxp-z 以 GPL-2.0-or-later 授权，其构建启用 OpenSSL（Apache-2.0），按上游说明产物整体按 GPLv3 处理。以完整安装包形式对外分发时，须一并履行 GPL 的对应源码提供义务与 LGPL 的重新链接要求；仅分发应用层源代码时不涉及上述义务。")

                        disclosure
                    }

                    sectionLabel("技术栈")
                    card {
                        techRow("语言与界面", "Swift 5 · SwiftUI · UIKit")
                        divider
                        techRow("运行容器", "WebKit / WKWebView · 自定义 URL Scheme")
                        divider
                        techRow("图形与媒体", "CoreGraphics · ImageIO · AVFoundation · Metal（经 ANGLE）")
                        divider
                        techRow("输入与反馈", "GameController · CoreHaptics")
                        divider
                        techRow("格式处理", "APNG / PNG 分块、ZIP、Godot PCK 探测、SWF 头解析")
                        divider
                        techRow("数据与持久化", "沙盒文件 · JSON · UserDefaults")
                    }

                    sectionLabel("开源组件")
                    licenseCard

                    disclaimer
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - 卡片

    private var identityCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [TT.navy, Color(hex: 0x0B4A7A)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 62, height: 62)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .shadow(color: TT.shadowLift.opacity(0.55), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("像素抽屉")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(TT.navy)
                Text("GameShelf · \(version)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TT.navySoft)
                Text("游戏资源仅存于本机，默认不联网、不上传。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(TT.navySoft.opacity(0.9))
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
        .shadow(color: TT.shadowTile.opacity(0.7), radius: 8, y: 3)
    }

    private var authorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(TT.blueSoft)
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(TT.blueDark)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("作者")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(TT.navySoft.opacity(0.8))
                    Text("inmchen")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(TT.navy)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            divider

            contactRow(
                icon: "envelope.fill",
                caption: "邮箱",
                value: "inmchen@gmail.com",
                key: "mail"
            )

            divider

            contactRow(
                icon: "bubble.left.and.bubble.right.fill",
                caption: "开发者反馈群（QQ）",
                value: "1135264591",
                key: "qq"
            )
        }
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
        .shadow(color: TT.shadowTile.opacity(0.7), radius: 8, y: 3)
    }

    /// 联系方式的一行：轻点即复制。`key` 用于区分哪一行刚被点过，
    /// 避免邮箱和群号同时闪「已复制」。
    private func contactRow(
        icon: String,
        caption: String,
        value: String,
        key: String
    ) -> some View {
        Button {
            copy(value, key: key)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(TT.blueDark)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TT.navySoft.opacity(0.85))
                    Text(value)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TT.navy)
                }

                Spacer(minLength: 8)

                Text(copiedKey == key ? "已复制" : "轻点复制")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copiedKey == key ? TT.mintDark : TT.navySoft.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy(_ text: String, key: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.18)) { copiedKey = key }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copiedKey == key else { return }
            withAnimation(.easeOut(duration: 0.18)) { copiedKey = nil }
        }
    }

    private var licenseCard: some View {
        card {
            licenseGroup("引擎与运行时", [
                ("mkxp-z 24（RGSS 引擎）", "GPL-2.0+"),
                ("Godot Engine 4.5 / 4.6（Web）", "MIT"),
                ("Ruffle（Flash，WebAssembly）", "MIT / Apache-2.0"),
                ("Ruby 1.8 / 1.9 / 3.1（随 mkxp-z 内嵌）", "Ruby / GPL-2.0")
            ])

            divider

            licenseGroup("图形与多媒体", [
                ("ANGLE（EGL / GLES）", "BSD-3-Clause"),
                ("SDL2 · SDL2_image · SDL2_ttf · SDL2_sound", "zlib"),
                ("FreeType", "FTL / GPL-2.0"),
                ("pixman", "MIT"),
                ("libogg · libvorbis · libtheora", "BSD-3-Clause"),
                ("OpenAL Soft", "LGPL-2.0"),
                ("FluidSynth", "LGPL-2.1"),
                ("PhysFS", "zlib"),
                ("uchardet", "MPL-1.1 / GPL-2.0 / LGPL-2.1"),
                ("OpenSSL", "Apache-2.0"),
                ("zlib · bzip2", "zlib / BSD 类")
            ])

            divider

            Text("系统框架：SwiftUI、UIKit、WebKit、AVFoundation、CoreGraphics、GameController、CoreHaptics 等由 iOS 提供，不随本应用分发源码。")
                .font(.system(size: 11))
                .foregroundStyle(TT.navySoft)
                .lineSpacing(3)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            HStack(spacing: 14) {
                Text("上游仓库")
                    .font(.system(size: 11))
                    .foregroundStyle(TT.navySoft)
                Link("mkxp-z", destination: URL(string: "https://github.com/mkxp-z/mkxp-z")!)
                Link("Godot", destination: URL(string: "https://github.com/godotengine/godot")!)
                Link("Ruffle", destination: URL(string: "https://github.com/ruffle-rs/ruffle")!)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .tint(TT.blueDark)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 13)
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TT.amber)
                Text("免责声明")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(TT.amber)
            }
            Text("本应用不提供、不下载、不分发任何游戏内容，仅提供本地运行环境。用户导入的游戏及其素材版权归各自权利人，应在持有合法授权的前提下使用。第三方组件的许可证全文以对应上游仓库发布版本为准。")
                .font(.system(size: 11.5))
                .foregroundStyle(TT.navy.opacity(0.78))
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TT.amberBg.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TT.rMd, style: .continuous)
                .stroke(TT.amberLine, lineWidth: 1)
        }
    }

    private var disclosure: some View {
        DisclosureGroup {
            Text(Self.mitText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(TT.navy.opacity(0.72))
                .lineSpacing(2)
                .padding(.top, 8)
        } label: {
            Text("MIT 许可证全文")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TT.blueDark)
        }
        .tint(TT.blueDark)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 小部件

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(TT.navy.opacity(0.86))
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(TT.navySoft)
            .padding(.leading, 4)
            .padding(.top, 2)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
        .shadow(color: TT.shadowTile.opacity(0.7), radius: 8, y: 3)
    }

    private var divider: some View {
        Rectangle()
            .fill(TT.navyFaint)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    private func techRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TT.navy)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(TT.navySoft)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func licenseGroup(_ title: String, _ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(TT.navySoft.opacity(0.85))

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.0)
                        .font(.system(size: 11.5))
                        .foregroundStyle(TT.navy.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(item.1)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TT.blueDark)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(TT.blueSoft, in: Capsule())
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private static let mitText = """
    MIT License

    Copyright © 2026 inmchen

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
