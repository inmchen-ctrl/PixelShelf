import Foundation
import SwiftUI
import UIKit

/// 游戏封面。
///
/// 规则只有一条：**封面 = 上次退出时的最后一帧**。
/// 从没启动过的游戏显示导入时从 APK 里抠出来的应用图标。
/// 所以同一个游戏只会有一个"更好"的封面：退出截图直接覆盖图标，
/// 截图失败（黑屏 / 渲染进程被杀）时不动图标，宁可显示旧图也不要显示一块黑。
final class CoverStore: ObservableObject {
    static let shared = CoverStore()

    /// 封面变化时 +1，让卡片重绘
    @Published private(set) var version = 0

    enum Kind {
        case shot, icon

        var suffix: String {
            switch self {
            case .shot: return "shot"
            case .icon: return "icon"
            }
        }

        /// 截图是横向的游戏画面，存 jpg；图标要保留透明通道叠在渐变上，存 png
        var ext: String {
            switch self {
            case .shot: return "jpg"
            case .icon: return "png"
            }
        }
    }

    struct Cover {
        let kind: Kind
        let image: UIImage
    }

    private let fm = FileManager.default
    /// 解码后的封面是大图，交给 NSCache 管：内存吃紧时系统会自己回收，
    /// 下次渲染再从磁盘读回来（几毫秒）。
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()

    var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Covers", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(_ id: UUID, _ kind: Kind) -> URL {
        root.appendingPathComponent("\(id.uuidString)_\(kind.suffix).\(kind.ext)")
    }

    // MARK: - 读取

    /// 优先截图，没有就退回图标
    func cover(for id: UUID) -> Cover? {
        if let image = cached(id, .shot) { return Cover(kind: .shot, image: image) }
        if let image = cached(id, .icon) { return Cover(kind: .icon, image: image) }
        return nil
    }

    private func cached(_ id: UUID, _ kind: Kind) -> UIImage? {
        let key = "\(id.uuidString)_\(kind.suffix)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        let url = fileURL(id, kind)
        guard fm.fileExists(atPath: url.path),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    // MARK: - 写入

    /// 退出游戏时调用。整屏接近全黑说明这一帧没画出来（WebGL 截不到、进程已被回收），
    /// 直接丢弃，让原来的封面留着。
    ///
    /// 存之前先把上下/左右的纯黑边裁掉：很多游戏不是全屏，截出来是「画面 + 两条黑边」，
    /// 直接用会被卡片按比例放大后中间只剩一条窄画面。裁掉黑边再存，封面才是满的。
    func saveShot(_ image: UIImage, for id: UUID) {
        guard !Self.looksBlank(image) else { return }
        let trimmed = Self.cropLetterbox(image)
        guard let data = Self.encode(trimmed, maxSide: 1600, quality: 0.85, asPNG: false) else { return }
        write(data, id: id, kind: .shot)
    }

    /// 导入时调用，返回是否存下了图标
    @discardableResult
    func saveIcon(_ data: Data, for id: UUID) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        // 图标最大只需 ~512，APK 里的 xxxhdpi 动辄 512-1024，统一压一下省空间
        guard let png = Self.encode(image, maxSide: 512, quality: 1, asPNG: true) else { return false }
        write(png, id: id, kind: .icon)
        return true
    }

    private func write(_ data: Data, id: UUID, kind: Kind) {
        let url = fileURL(id, kind)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        if let image = UIImage(data: data) {
            memory.setObject(image, forKey: "\(id.uuidString)_\(kind.suffix)" as NSString)
        }
        version &+= 1
    }

    // MARK: - 清理

    func remove(for id: UUID) {
        for kind in [Kind.shot, .icon] {
            try? fm.removeItem(at: fileURL(id, kind))
            memory.removeObject(forKey: "\(id.uuidString)_\(kind.suffix)" as NSString)
        }
        version &+= 1
    }

    /// 库里已经没有的封面（删除记录时漏删、或旧版本残留）
    func purge(keeping ids: Set<UUID>) {        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        var removed = false
        for name in names {
            guard let uuidPart = name.split(separator: "_").first,
                  let id = UUID(uuidString: String(uuidPart)) else {
                try? fm.removeItem(at: root.appendingPathComponent(name))
                removed = true
                continue
            }
            if !ids.contains(id) {
                try? fm.removeItem(at: root.appendingPathComponent(name))
                removed = true
            }
        }
        if removed { version &+= 1 }
    }

    /// 一次性回填：旧版本存下的截图还带着黑边，这里统一再裁一遍，
    /// 免得用户得把每个游戏重开一次封面才会变。裁完尺寸没变就不重写文件。
    func migrateCropsIfNeeded() {
        let key = "cover.crop.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let names = (try? self.fm.contentsOfDirectory(atPath: self.root.path)) ?? []
            var changed = false
            for name in names where name.hasSuffix("_shot.jpg") {
                let url = self.root.appendingPathComponent(name)
                guard let image = UIImage(contentsOfFile: url.path) else { continue }
                let trimmed = Self.cropLetterbox(image)
                guard trimmed.size != image.size,
                      let data = Self.encode(trimmed, maxSide: 1600, quality: 0.85, asPNG: false) else { continue }
                guard (try? data.write(to: url, options: .atomic)) != nil else { continue }
                // 内存里缓存的是裁之前那张，清掉让下次渲染从磁盘重新读
                if let uuidPart = name.split(separator: "_").first {
                    self.memory.removeObject(forKey: "\(uuidPart)_shot" as NSString)
                }
                changed = true
            }
            if changed {
                DispatchQueue.main.async { self.version &+= 1 }
            }
        }
    }

    // MARK: - 图像处理

    /// 裁掉纯黑边（上下或左右），让封面只留画面本身。
    ///
    /// 判断方式：把截图缩到 160pt 宽，逐行/逐列看最亮的一个像素，
    /// 整行整列都接近纯黑才算黑边 —— 这样夜空、黑底菜单这类真实画面不会被误裁。
    /// 每边最多裁 40%，其余情况原样返回。
    static func cropLetterbox(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage, cg.width > 16, cg.height > 16 else { return image }
        let probe = letterboxTrim(cg)

        // 只裁掉超过 1% 的边，避免为几个像素去重绘
        guard probe.left > probe.pw / 100 || probe.right < probe.pw - probe.pw / 100
            || probe.top > probe.ph / 100 || probe.bottom < probe.ph - probe.ph / 100 else { return image }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(
            x: (CGFloat(probe.left) / CGFloat(probe.pw) * w).rounded(),
            y: (CGFloat(probe.top) / CGFloat(probe.ph) * h).rounded(),
            width: (CGFloat(probe.right - probe.left + 1) / CGFloat(probe.pw) * w).rounded(),
            height: (CGFloat(probe.bottom - probe.top + 1) / CGFloat(probe.ph) * h).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h))

        guard rect.width >= 16, rect.height >= 16, let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
    }

    /// 四边黑边占全幅的比例（0…1）。
    ///
    /// 和封面裁剪用的是同一套探测：整行整列都接近纯黑才算黑边。
    /// Godot / Flash 的黑边是引擎画在画布里的，量元素的 rect 量不出来，
    /// 只能截一张图当探针用。
    static func letterboxInsets(_ image: UIImage) -> (l: Double, t: Double, r: Double, b: Double) {
        guard let cg = image.cgImage, cg.width > 16, cg.height > 16 else { return (0, 0, 0, 0) }
        let p = letterboxTrim(cg)
        func ratio(_ n: Int, _ total: Int) -> Double {
            let v = Double(n) / Double(total)
            // 1% 以下当没有黑边，免得为几个像素把画面挪来挪去
            return v < 0.01 ? 0 : v
        }
        return (ratio(p.left, p.pw),
                ratio(p.top, p.ph),
                ratio(p.pw - 1 - p.right, p.pw),
                ratio(p.ph - 1 - p.bottom, p.ph))
    }

    /// 探测黑边：返回按 160 宽的探针网格算出来的四边位置
    static func letterboxTrim(_ cg: CGImage) -> (top: Int, bottom: Int, left: Int, right: Int, pw: Int, ph: Int) {
        let probeWidth = 160
        let probeHeight = max(1, Int((Double(probeWidth) * Double(cg.height) / Double(cg.width)).rounded()))
        let count = probeWidth * probeHeight
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        defer { buffer.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: buffer, width: probeWidth, height: probeHeight,
            bitsPerComponent: 8, bytesPerRow: probeWidth * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return (0, probeHeight - 1, 0, probeWidth - 1, probeWidth, probeHeight) }
        // 不做翻转：位图内存第 0 行本来就是画面顶部，和 CGImage.cropping 的左上原点一致。
        // 必须关掉插值，否则缩放时边缘几行会串到画面另一头，导致下边框判不出来。
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: probeWidth, height: probeHeight))

        func luminance(_ x: Int, _ y: Int) -> Int {
            let o = y * probeWidth * 4 + x * 4
            let r = Int(buffer[o]), g = Int(buffer[o+1]), b = Int(buffer[o+2])
            return (r * 54 + g * 183 + b * 19) >> 8
        }

        // 只认接近纯黑（≤14）。到 20 以上就分不清"黑边"和"暗色游戏背景"了，
        // 实测 22 会把 8% 灰的暗色游戏当成黑边裁掉四分之三。
        let dark = 14
        func rowIsDark(_ y: Int) -> Bool {
            for x in 0..<probeWidth where luminance(x, y) > dark { return false }
            return true
        }
        func columnIsDark(_ x: Int) -> Bool {
            for y in 0..<probeHeight where luminance(x, y) > dark { return false }
            return true
        }

        var top = 0
        while top < probeHeight / 2 && rowIsDark(top) { top += 1 }
        var bottom = probeHeight - 1
        while bottom > probeHeight / 2 && rowIsDark(bottom) { bottom -= 1 }
        var left = 0
        while left < probeWidth / 2 && columnIsDark(left) { left += 1 }
        var right = probeWidth - 1
        while right > probeWidth / 2 && columnIsDark(right) { right -= 1 }

        // 每边最多裁 40%。4:3 画面放在 19.5:9 手机上，上下黑边各占三分之一，
        // 这是最典型的情况，所以不能按"裁掉一半就放弃"来判。
        // 反过来，如果真碰到整屏发黑的游戏，上限也能保证至少留下中间那条画面。
        let maxTrimW = Int((Double(probeWidth) * 0.40).rounded())
        let maxTrimH = Int((Double(probeHeight) * 0.40).rounded())
        top = min(top, maxTrimH)
        bottom = max(bottom, probeHeight - 1 - maxTrimH)
        left = min(left, maxTrimW)
        right = max(right, probeWidth - 1 - maxTrimW)

        return (top, bottom, left, right, probeWidth, probeHeight)
    }

    private static func encode(_ image: UIImage, maxSide: CGFloat, quality: CGFloat, asPNG: Bool) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = !asPNG
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return asPNG ? resized.pngData() : resized.jpegData(compressionQuality: quality)
    }

    /// 平均亮度太低且几乎没有亮点 → 认为没画出来
    private static func looksBlank(_ image: UIImage) -> Bool {
        let side: CGFloat = 16
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let small = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cg = small.cgImage, let provider = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(provider) else { return false }

        let bpp = max(3, cg.bitsPerPixel / 8)
        let row = cg.bytesPerRow
        var bright = 0
        let total = Int(side) * Int(side)
        for y in 0..<Int(side) {
            for x in 0..<Int(side) {
                let o = y * row + x * bpp
                let r = Double(ptr[o]) / 255
                let g = Double(ptr[o + 1]) / 255
                let b = Double(ptr[o + 2]) / 255
                if 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.07 { bright += 1 }
            }
        }
        return Double(bright) / Double(total) < 0.06
    }

    // MARK: - 从 APK 里抠图标

    /// Android 的启动图标在 res/mipmap-*（老式）或 mipmap-anydpi-v26 + 前景图（自适应）里。
    /// 自适应图标是 XML，真正能显示的位图叫 ic_launcher_foreground，
    /// 所以按名字打分比按路径猜靠得住。
    nonisolated static func iconData(from reader: any ArchiveReader) -> Data? {
        struct Candidate {
            let index: Int
            let score: Int
            let density: Int
            let bytes: Int
        }

        var candidates: [Candidate] = []
        for (i, entry) in reader.entries.enumerated() {
            let name = entry.name.lowercased()
            guard !entry.isDirectory, name.hasPrefix("res/") else { continue }
            let ext = (name as NSString).pathExtension
            guard ext == "png" || ext == "webp" else { continue }
            guard entry.uncompressedSize > 0, entry.uncompressedSize <= 6 << 20 else { continue }

            let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            let isMipmap = name.contains("/mipmap")

            var score = 0
            if base == "ic_launcher" { score += 100 }
            else if base.contains("ic_launcher") { score += 65 }
            else if base == "icon" || base.hasSuffix("_icon") || base.contains("app_icon") { score += 55 }
            else if base.contains("launcher") { score += 45 }
            else if base.contains("logo") { score += 25 }

            if isMipmap { score += 25 }
            else if name.contains("/drawable") { score += 8 }

            // 没有命中名字的，只保留 mipmap 下的（那里是图标专用目录）
            if score < 20 { guard isMipmap else { continue } }

            candidates.append(Candidate(index: i, score: score,
                                        density: densityRank(name),
                                        bytes: entry.uncompressedSize))
        }

        guard !candidates.isEmpty else { return nil }
        let ranked = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.density != $1.density { return $0.density > $1.density }
            return $0.bytes > $1.bytes
        }
        for candidate in ranked.prefix(6) {
            let entry = reader.entries[candidate.index]
            guard let data = try? reader.read(entry), UIImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }

    private nonisolated static func densityRank(_ name: String) -> Int {
        let table: [(String, Int)] = [
            ("anydpi", 0), ("ldpi", 1), ("mdpi", 2), ("hdpi", 3),
            ("xhdpi", 4), ("xxhdpi", 5), ("xxxhdpi", 6)
        ]
        for (key, rank) in table where name.contains(key) { return rank }
        return 2
    }
}
