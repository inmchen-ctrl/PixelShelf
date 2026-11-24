import SwiftUI

/// 界面设计令牌：色板、圆角、阴影与间距，全应用共用。
///
/// 视觉约定：
/// - 背景不是斜线纹理，而是低多边形菱形拼贴（bg-diamante.png，800×800 平铺）
/// - 磁贴是**正方形**，圆角 18pt（手机上 16pt），不是超大圆角
/// - 卡片上只在底部压一条暗渐变，标题常显
enum TT {
    // MARK: 色板（与 CSS 变量一一对应）

    static let navy = Color(hex: 0x002B50)
    static let navySoft = Color(hex: 0x002B50, alpha: 0.62)
    static let navyFaint = Color(hex: 0x002B50, alpha: 0.10)

    /// --blue / --blue-dark / --blue-soft
    static let blue = Color(hex: 0x009CFF)
    static let blueDark = Color(hex: 0x0086D6)
    static let blueSoft = Color(hex: 0xE6F6FF)

    /// --mint
    static let mint = Color(hex: 0x83FFE7)
    static let mintDeep = Color(hex: 0x2FD9BB)
    static let mintDark = Color(hex: 0x0F7F6C)

    static let amber = Color(hex: 0xA4620A)
    static let amberBg = Color(hex: 0xFFF8E8)
    static let amberLine = Color(hex: 0xFFDFA6)

    static let surface = Color.white
    /// 输入框、分类面板里的小格子用的浅灰蓝（CSS 里的 #f2f7fa）
    static let surfaceSoft = Color(hex: 0xF2F7FA)
    /// 顶栏渐隐用的近乎白（CSS 里 rgba(237,255,252,.995)）
    static let chromeTop = Color(hex: 0xEDFFFC)

    // MARK: 尺寸

    /// --tile-r: 18px；手机上 12→16
    static let rTile: CGFloat = 16
    static let rLg: CGFloat = 18
    static let rMd: CGFloat = 14
    static let rSm: CGFloat = 10

    /// 磁贴间距：手机 10
    static let gap: CGFloat = 10

    static let shadowTile = Color(hex: 0x00464F, alpha: 0.16)
    static let shadowLift = Color(hex: 0x00323C, alpha: 0.24)

    // MARK: 封面渐变（没有封面图时的兜底）

    static func gradient(for engine: GameEngine) -> [Color] {
        switch engine {
        case .mv: return [Color(hex: 0x3FCB95), Color(hex: 0x0C6B52)]
        case .mz: return [Color(hex: 0x5BE0AC), Color(hex: 0x12805C)]
        case .web: return [Color(hex: 0x5FAEFF), Color(hex: 0x1A5FA8)]
        case .renpy: return [Color(hex: 0xFF9375), Color(hex: 0xC2410C)]
        case .rgss: return [Color(hex: 0xA98BFA), Color(hex: 0x5B2BC0)]
        case .godot: return [Color(hex: 0x63CBF2), Color(hex: 0x0B6E8C)]
        case .flash: return [Color(hex: 0xFF8A8A), Color(hex: 0xB4232B)]
        case .unity: return [Color(hex: 0x9AA5B1), Color(hex: 0x3F4854)]
        case .native, .unknown: return [Color(hex: 0xA3A8AE), Color(hex: 0x4B5058)]
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// 参考站的 bg-diamante.svg：薄荷底 + 低多边形宝石拼贴。
///
/// SVG 在 iOS 上没法直接当 UIImage，所以我把那 89 个多边形按原坐标栅格化成
/// 800×800 的 PNG 塞进 Resources，这里按 225pt 一个平铺单位重复（参考站是
/// 820px 对 1440px 视口，比例约 0.57，换算到 393pt 宽就是 225）。
struct DiamanteBackground: View {
    /// 平铺单位边长（pt）
    var unit: CGFloat = 320

    var body: some View {
        ZStack {
            TT.mint

            if let pattern = TT.diamondTile(unit: unit) {
                // 平铺：resizable(resizingMode: .tile) 按图片的自然尺寸（pt）重复
                Image(uiImage: pattern)
                    .resizable(resizingMode: .tile)
                    .opacity(0.96)
            }

            // 底部略压暗，让白色浮动胶囊有落点
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [.clear, TT.navy.opacity(0.06)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 220)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

extension TT {
    /// 缩放好的平铺底图。缺图时返回 nil，上层退回纯薄荷色。
    static func diamondTile(unit: CGFloat = 320) -> UIImage? {
        guard let raw = UIImage(named: "bg-diamante") else { return nil }
        return TileCache.shared.scaled(raw, unit: unit)
    }
}

/// 把 800×800 的底图重绘成指定的平铺单位，结果缓存。
private final class TileCache {
    static let shared = TileCache()
    private var storage: [CGFloat: UIImage] = [:]
    private let lock = NSLock()

    func scaled(_ image: UIImage, unit: CGFloat) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = storage[unit] { return hit }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let side = CGSize(width: unit, height: unit)
        let out = UIGraphicsImageRenderer(size: side, format: format).image { ctx in
            UIColor(red: 0x83 / 255, green: 0xFF / 255, blue: 0xE7 / 255, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: side))
            image.draw(in: CGRect(origin: .zero, size: side))
        }
        storage[unit] = out
        return out
    }
}

// MARK: - 通用组件

/// 页头：小字眉题 + 主标题 + 右侧按钮组。
struct TTPageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(TT.navy.opacity(0.42))
                Text(title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(TT.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TT.navySoft)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// 圆角图标按钮（顶栏用）。
struct TTIconButton: View {
    let systemName: String
    var filled: Bool = false
    var size: CGFloat = 42
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(filled ? .white : TT.navy)
                .frame(width: size, height: size)
                .background(filled ? TT.navy : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.36, style: .continuous))
                .shadow(color: TT.shadowTile.opacity(filled ? 1 : 0.7), radius: filled ? 10 : 8, y: 3)
        }
        .buttonStyle(TPressStyle())
    }
}

/// 分类 chip，对应 CSS 的 `.chip`。
struct TTChip: View {
    let title: String
    var count: Int?
    var active: Bool
    var showsGridMark: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if showsGridMark {
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            square; square
                        }
                        HStack(spacing: 3) {
                            square; square
                        }
                    }
                }
                Text(title)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(active ? .white.opacity(0.7) : TT.navy.opacity(0.4))
                }
            }
            .foregroundStyle(active ? .white : TT.navy)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(active ? TT.navy : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: TT.shadowTile.opacity(active ? 0.9 : 0.65), radius: 6, y: 2)
        }
        .buttonStyle(TPressStyle())
    }

    private var square: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(active ? Color.white : TT.blue)
            .frame(width: 5.5, height: 5.5)
    }
}

/// 主按钮：海军蓝，白字。
struct TTPrimaryButton: View {
    let title: String
    var systemImage: String?
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(enabled ? TT.navy : TT.navy.opacity(0.3))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(TPressStyle())
        .disabled(!enabled)
    }
}

/// 按压反馈：参考站是 hover 抬起，触屏上改成按压缩小。
struct TPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// 引擎小徽章。
struct EngineBadge: View {
    let engine: GameEngine
    var light: Bool = true

    var body: some View {
        Text(engine.shortLabel)
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(light ? TT.navy : .white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(light ? Color.white.opacity(0.94) : Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
