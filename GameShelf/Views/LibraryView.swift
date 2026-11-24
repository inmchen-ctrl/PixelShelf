import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: GameStore

    @State private var showImporter = false
    @State private var selected: GameRecord?
    @State private var playing: GameRecord?
    @State private var layout: LayoutMode = .grid
    @State private var queue: [URL] = []
    @State private var showError = false
    @State private var renaming: GameRecord?
    @State private var filter: LibFilter = .all
    /// 可导入的容器：zip / apk，以及 7z
    private static let importableTypes: [UTType] = {
        var types: [UTType] = [.zip, .data]
        if let sevenZip = UTType(filenameExtension: "7z") {
            types.insert(sevenZip, at: 0)
        }
        return types
    }()

    @State private var searching = false
    /// 加密包的解压密码输入（不落盘，导入结束即丢弃）
    @State private var passwordInput = ""

    enum LayoutMode: Hashable {
        case grid, list
    }

    /// 分类：全部 / 最近玩过 / 没启动过的 / 按引擎分
    enum LibFilter: Hashable {
        case all
        case recent
        case unopened
        case engine(GameEngine)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DiamanteBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        chipsRow

                        if store.games.isEmpty {
                            emptyState
                        } else if visibleGames.isEmpty {
                            noMatchState
                        } else {
                            if filter != .all { wallHead }
                            if layout == .grid { mosaicWall } else { listWall }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, store.games.isEmpty ? 40 : 96)
                }

                if !store.games.isEmpty {
                    floatingPill
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay {
                if store.phase.isBusy {
                    importingOverlay
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: Self.importableTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    // 和 APK 完全一样的处理：直接入队，由 GameStore 按扩展名挑归档实现。
                    // 不额外拷贝、不经 Inbox、不做文件协调——那条更复杂的路反而会失败。
                    enqueue(urls)
                case .failure(let error):
                    store.lastError = error.localizedDescription
                    showError = true
                }
            }
            .sheet(item: $selected) { game in
                // 从库里取实时记录：改完名字卡片和详情要同时变
                let live = store.games.first { $0.id == game.id } ?? game
                GameDetailView(
                    game: live,
                    folder: store.folderURL(for: live),
                    onPlay: { play(live) },
                    onRename: { store.rename(live, to: $0) },
                    onDelete: {
                        store.delete(live)
                        selected = nil
                    }
                )
            }
            .fullScreenCover(item: $playing) { game in
                GamePlayerView(game: game, root: store.folderURL(for: game))
            }
            .alert("导入失败", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "未知错误")
            }
            .confirmationDialog(
                "选择要导入的网页工程",
                isPresented: Binding(
                    get: { store.pendingRootChoice != nil },
                    set: { if !$0 { store.pendingRootChoice = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let choice = store.pendingRootChoice {
                    ForEach(choice.candidates, id: \.self) { candidate in
                        Button {
                            store.importPackage(at: choice.url, withRoot: candidate)
                        } label: {
                            Text("\(candidate.engineLabel) · \(candidate.summary)")
                        }
                    }
                    Button("取消", role: .cancel) {
                        store.pendingRootChoice = nil
                        // 取消后把源包放回待导入队列提示，避免卡住
                    }
                }
            } message: {
                Text("这个包里有多个网页入口，请选择要导入的那一个")
            }
            .alert("压缩包已加密", isPresented: Binding(
                get: { store.passwordPrompt != nil },
                set: { if !$0 { store.cancelPassword() } }
            )) {
                SecureField("解压密码", text: $passwordInput)
                Button("取消", role: .cancel) {
                    passwordInput = ""
                    store.cancelPassword()
                }
                Button("解包") {
                    let pwd = passwordInput
                    passwordInput = ""
                    store.submitPassword(pwd)
                }
            } message: {
                Text(store.passwordPrompt?.failed == true
                     ? "密码不正确，请重新输入"
                     : "这个包设置了密码，输入后才能解包导入")
            }
            .onAppear {
                CoverStore.shared.migrateCropsIfNeeded()
            }
            .onChange(of: store.phase) { _, phase in
                if !phase.isBusy && phase != .idle {
                    showError = true
                }
                if !phase.isBusy { nextImport() }
            }
        }
        // 挂在外层：和「导入失败」那个 alert 同层会互相抢占
        .renameAlert(target: $renaming) { game, title in
            store.rename(game, to: title)
        }
        // 搜索整层盖住，含顶栏
        .overlay {
            if searching {
                LibrarySearchView(
                    games: store.games,
                    onPick: { game in
                        searching = false
                        selected = game
                    },
                    onClose: { searching = false }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
    }

    // MARK: - 页头

    private var header: some View {
        TTPageHeader(
            eyebrow: "GAMESHELF",
            title: "游戏库",
            detail: store.games.isEmpty
                ? "导入你自己的游戏包"
                : "\(store.games.count) 款游戏 · 全部存在本机"
        ) {
            HStack(spacing: 8) {
                TTIconButton(systemName: "magnifyingglass", size: 40) {
                    searching = true
                }
                .opacity(store.games.isEmpty ? 0.45 : 1)
                .disabled(store.games.isEmpty)
            }
        }
    }

    // MARK: - 分类

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                TTChip(
                    title: "全部",
                    count: store.games.count,
                    active: filter == .all,
                    showsGridMark: true
                ) { select(.all) }

                ForEach(chips, id: \.filter) { chip in
                    TTChip(
                        title: chip.title,
                        count: chip.count,
                        active: filter == chip.filter
                    ) { select(chip.filter) }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        // 右侧渐隐，暗示还能横滑（对应 CSS 的 mask-image）
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.93),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private struct Chip: Hashable {
        let filter: LibFilter
        let title: String
        let count: Int
    }

    private var chips: [Chip] {
        var out: [Chip] = []
        let played = store.games.filter { $0.lastPlayedAt != nil }.count
        let fresh = store.games.count - played
        if played > 0 {
            out.append(Chip(filter: .recent, title: "最近玩过", count: played))
        }
        if fresh > 0 {
            out.append(Chip(filter: .unopened, title: "没启动", count: fresh))
        }
        // 引擎按数量从多到少
        let grouped = Dictionary(grouping: store.games, by: \.engine)
        for (engine, list) in grouped.sorted(by: { $0.value.count > $1.value.count }) {
            out.append(Chip(filter: .engine(engine), title: engine.shortLabel, count: list.count))
        }
        return out
    }

    private var visibleGames: [GameRecord] {
        switch filter {
        case .all:
            return store.games
        case .recent:
            return store.games
                .filter { $0.lastPlayedAt != nil }
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .unopened:
            return store.games.filter { $0.lastPlayedAt == nil }
        case .engine(let engine):
            return store.games.filter { $0.engine == engine }
        }
    }

    private func select(_ next: LibFilter) {
        withAnimation(.easeOut(duration: 0.18)) {
            filter = (filter == next && next != .all) ? .all : next
        }
    }

    /// 选中分类后的说明卡，对应 `.wall-head`
    private var wallHead: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("分类")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(TT.navy.opacity(0.42))
                Text(wallTitle)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(TT.navy)
            }
            Text("\(visibleGames.count)")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(TT.blueDark)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(TT.blue.opacity(0.1))
                .clipShape(Capsule())

            Spacer(minLength: 8)

            Button {
                select(.all)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .bold))
                    Text("重置")
                        .font(.system(size: 12.5, weight: .bold))
                }
                .foregroundStyle(TT.navy)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(TPressStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: TT.shadowTile.opacity(0.8), radius: 10, y: 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var wallTitle: String {
        switch filter {
        case .all: return "全部游戏"
        case .recent: return "最近玩过"
        case .unopened: return "还没启动过"
        case .engine(let engine): return "\(engine.shortLabel) 游戏"
        }
    }

    // MARK: - 马赛克墙

    private var mosaicWall: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: TT.gap), count: 2),
            spacing: TT.gap
        ) {
            ForEach(visibleGames) { game in
                Button {
                    selected = game
                } label: {
                    GameTile(game: game)
                }
                .buttonStyle(TPressStyle())
                .contextMenu { tileMenu(game) }
            }
        }
    }

    @ViewBuilder
    private func tileMenu(_ game: GameRecord) -> some View {
        Button("开始游戏") { play(game) }
        Button("重命名") { renaming = game }
        Button("移除", role: .destructive) { store.delete(game) }
    }

    // MARK: - 列表

    private var listWall: some View {
        LazyVStack(spacing: 10) {
            ForEach(visibleGames) { game in
                Button { selected = game } label: {
                    GameRow(game: game)
                }
                .buttonStyle(TPressStyle())
                .contextMenu { tileMenu(game) }
            }
        }
    }

    // MARK: - 浮动胶囊

    private var floatingPill: some View {
        HStack(spacing: 4) {
            pillButton(
                icon: layout == .grid ? "list.bullet" : "square.grid.2x2",
                label: layout == .grid ? "列表" : "网格"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    layout = layout == .grid ? .list : .grid
                }
            }

            Rectangle()
                .fill(TT.navy.opacity(0.1))
                .frame(width: 1, height: 26)
                .padding(.horizontal, 2)

            Button {
                showImporter = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .heavy))
                    Text("导入游戏")
                        .font(.system(size: 14.5, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 42)
                .background(TT.navy)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(TPressStyle())
            .disabled(store.phase.isBusy)
        }
        .padding(7)
        .background(.white.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TT.navyFaint, lineWidth: 1)
        }
        .shadow(color: TT.shadowLift, radius: 16, y: 8)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func pillButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(.system(size: 13.5, weight: .bold))
            }
            .foregroundStyle(TT.navy.opacity(0.72))
            .padding(.horizontal, 13)
            .frame(height: 42)
        }
        .buttonStyle(TPressStyle())
    }

    // MARK: - 子视图

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 92, height: 92)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(TT.navy.opacity(0.72))
            }
            .padding(.top, 6)

            VStack(spacing: 7) {
                Text("库还是空的")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(TT.navy)
                Text("点下面的按钮选一个 .apk / .zip 导入。游戏只在本机解包运行，不会执行 Android 代码。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(TT.navySoft)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TTPrimaryButton(title: "导入游戏", systemImage: "plus") { showImporter = true }
                .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: TT.shadowTile.opacity(0.8), radius: 12, y: 5)
    }

    private var noMatchState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(TT.navy.opacity(0.4))
            Text("这个分类下还没有游戏")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(TT.navy)
            Button("看全部") { select(.all) }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(TT.blueDark)
        }
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var importingOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(store.phase.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TT.navy)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let f = store.phase.fraction {
                    Text("\(Int(f * 100))%")
                        .font(.system(size: 12.5, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(TT.blueDark)
                }
            }

            if let f = store.phase.fraction {
                ProgressView(value: min(max(f, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(TT.blueDark)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(TT.navy)
            }

            if let detail = store.phase.detail {
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(TT.navySoft)
                    .lineLimit(1)
            }

            Text("解包大包时请保持 App 在前台")
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(TT.navySoft.opacity(0.85))
        }
        .padding(20)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.white.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: TT.navy.opacity(0.14), radius: 26, y: 10)
        .padding(.horizontal, 28)
    }

    // MARK: - 动作

    private func play(_ game: GameRecord) {
        store.markPlayed(game)

        // 所有引擎都走同一个游戏页（GamePlayerView）。RGSS 由页面在 onAppear 里
        // 交给内置 mkxp-z 引擎，不在这里另开一条分支。
        let hadSheet = (selected != nil)
        selected = nil
        if hadSheet {
            // 关 sheet 和弹全屏 cover 不能同帧做：SwiftUI 会把 cover 内容瞬时
            // 拆走再装回（onDisappear 误触发 → haltPlayback 把游戏页卸成
            // about:blank → 黑屏）。等 sheet 收完动画再弹。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { playing = game }
        } else {
            playing = game
        }
    }

    private func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        nextImport()
    }

    private func nextImport() {
        guard !store.phase.isBusy, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        store.importPackage(at: url)
    }
}

// MARK: - 磁贴

/// 正方形磁贴，对应参考站的 `.tile`：封面铺满、底部压暗、标题常显。
/// 参考站的标题是 hover 才出现，触屏上我改成常显——否则手机上看不到游戏名。
struct GameTile: View {
    let game: GameRecord

    private var playable: Bool { game.engine.isPlayable && game.status != .unsupported }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GameCoverArt(game: game)

            // 底部压暗，保证白字可读
            LinearGradient(
                colors: [.clear, .black.opacity(0.04), .black.opacity(0.52)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    EngineBadge(engine: game.engine)
                    Spacer(minLength: 0)
                    if !playable {
                        Text("不支持")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.32))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: 8) {
                    Text(game.title)
                        .font(.system(size: 13.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)

                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 28, height: 28)
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(TT.navy)
                            .offset(x: 1)
                    }
                    .opacity(playable ? 1 : 0.4)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                }
            }
            .padding(10)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: TT.rTile, style: .continuous))
        // 整个磁贴的触摸判定锁定在正方形框内：内部任何溢出的子视图
        // （横版封面图、出框的阴影）都不再抢占旁边磁贴的点击
        .contentShape(Rectangle())
        .shadow(color: TT.shadowTile, radius: 6, y: 3)
    }
}

struct GameRow: View {
    let game: GameRecord

    var body: some View {
        HStack(spacing: 13) {
            GameCoverThumb(game: game)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(TT.navy)
                    .lineLimit(1)
                Text(game.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TT.navySoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            EngineBadge(engine: game.engine)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: TT.shadowTile.opacity(0.75), radius: 8, y: 3)
    }
}
