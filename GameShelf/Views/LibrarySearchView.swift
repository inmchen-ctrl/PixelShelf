import SwiftUI

/// 搜索浮层：参考站的 `.search-overlay` + `.search-box`。
///
/// 结构：暗色半透明 + 毛玻璃打底 → 白色大圆角搜索框 → 输入框 → 提示 → 结果网格。
struct LibrarySearchView: View {
    let games: [GameRecord]
    var onPick: (GameRecord) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var appeared = false
    @FocusState private var focused: Bool

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [GameRecord] {
        guard !trimmed.isEmpty else { return recents }
        return games.filter { game in
            game.title.localizedStandardContains(trimmed)
                || game.engine.label.localizedCaseInsensitiveContains(trimmed)
                || game.engine.shortLabel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// 空查询时先给最近玩过的，没有就按库里顺序
    private var recents: [GameRecord] {
        let played = games
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        return played.isEmpty ? Array(games.prefix(12)) : Array(played.prefix(12))
    }

    private var hint: String {
        trimmed.isEmpty
            ? (recents.isEmpty ? "" : (games.contains { $0.lastPlayedAt != nil } ? "最近玩过" : "库里的游戏"))
            : "搜索结果"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: 0x002030, alpha: 0.55)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                searchBox
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 76)
            .padding(.bottom, 24)
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { focused = true }
        }
    }

    // MARK: - 搜索框

    private var searchBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TT.navy.opacity(0.5))

                TextField("", text: $query)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TT.navy)
                    .tint(TT.blue)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(alignment: .leading) {
                        // 系统占位色太淡，这里自己画一条
                        if query.isEmpty {
                            Text("搜索游戏名或引擎")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TT.navy.opacity(0.32))
                                .allowsHitTesting(false)
                        }
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TT.navy.opacity(0.32))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(TT.surfaceSoft)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(TT.navyFaint, lineWidth: 1.5)
            }
            .overlay(alignment: .topTrailing) {
                // 关闭键叠在输入框外层右上，别挤占输入区
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(TT.navy.opacity(0.55))
                        .frame(width: 30, height: 30)
                        .background(TT.surfaceSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(TPressStyle())
                .offset(x: 9, y: -9)
            }

            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(TT.navy.opacity(0.4))
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                    .padding(.leading, 2)
            }

            if results.isEmpty {
                Text(trimmed.isEmpty ? "库里还没有游戏。" : "没有找到「\(trimmed)」。换个词试试，或搜引擎名，比如 godot、flash。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TT.navy.opacity(0.55))
                    .lineSpacing(3)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if results.count > 6 {
                ScrollView(showsIndicators: false) {
                    resultGrid
                        .padding(.bottom, 4)
                }
                .frame(maxHeight: 372)
            } else {
                // 结果不多时不要撑高白框
                resultGrid
            }
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color(hex: 0x001423, alpha: 0.4), radius: 34, y: 16)
    }

    private var resultGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 12
        ) {
            ForEach(results) { game in
                Button {
                    close(then: { onPick(game) })
                } label: {
                    SearchTile(game: game)
                }
                .buttonStyle(TPressStyle())
            }
        }
    }

    // MARK: - 动作

    private func close(then finish: (() -> Void)? = nil) {
        focused = false
        withAnimation(.easeIn(duration: 0.16)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            onClose()
            finish?()
        }
    }
}

/// 搜索结果里的方块（对应 `.search-results .tile`）
private struct SearchTile: View {
    let game: GameRecord

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GameCoverArt(game: game, iconFraction: 0.58)

            LinearGradient(
                colors: [.clear, .black.opacity(0.08), .black.opacity(0.62)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(game.title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 7)
                .padding(.bottom, 6)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: TT.shadowTile.opacity(0.8), radius: 5, y: 2)
    }
}
