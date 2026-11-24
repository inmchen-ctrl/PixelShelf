import Foundation

/// APNG 帧裁剪。
///
/// MV/MZ 的 APNG 插件（pixi-apng / UPNG）解析时会先 `toRGBA8()` 把**所有帧**
/// 一次性解成 RGBA 数组，然后才逐帧建画布。1280×720 每帧 3.5MB，
/// 一部 576 帧的动画光这一步就是 2GB —— 而 iOS 的网页进程上限正好是 2GB，
/// 于是解析到一半就被系统按 per-process-limit 杀掉。这一步发生在任何 JS 钩子
/// 之前（PIXI 还没拿到数据），只能在文件送进网页进程之前减少帧数。
///
/// 这里直接改 PNG 的 APNG 块（acTL / fcTL / fdAT），按等间隔抽帧：
/// 帧数降到预算内，总时长不变（把被跳过帧的延迟累加到保留帧上），
/// 因此动画会变「跳」，但仍然从头播到尾，尺寸与循环次数都不变。
///
/// RPGMV 加密只异或了正文前 16 字节，块结构本身是明文，所以不需要解密密钥：
/// 由「PNG 签名 + IHDR 长度/类型」这段固定明文反推异或键，改完再异或回去即可。
enum ApngTrimmer {

    /// 单个动画允许保留的帧内存上限。720p 下约等于 2 帧（2 × 3.5MB）。
    /// 取值依据：标题阶段会同时解析几十个动画，按 8MB/个 计，总量约 0.4GB。
    static var perFileBudget = 8 * 1024 * 1024

    struct Result {
        var data: Data
        var framesBefore: Int
        var framesAfter: Int
    }

    private struct Chunk {
        let type: String
        let start: Int      // 块起始（含长度字段）
        let dataStart: Int
        let dataLen: Int
        let end: Int
    }

    /// 解密后的标准 PNG 头：签名 + IHDR 长度 + "IHDR"
    private static let plainHead: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52
    ]

    /// 若不是多帧 APNG，或已在预算内，返回 nil（保持原样）。
    static func trim(_ data: Data, budget: Int? = nil) -> Result? {
        let limit = budget ?? perFileBudget
        let raw = [UInt8](data)
        guard raw.count > 64, raw[0] == 0x52, raw[1] == 0x50,
              raw[2] == 0x47, raw[3] == 0x4D, raw[4] == 0x56 else { return nil }

        var body = Array(raw[16...])
        guard body.count > 40 else { return nil }

        // 反推异或键：正文前 16 字节的明文是固定的
        var key = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { key[i] = body[i] ^ plainHead[i] }
        for i in 0..<16 { body[i] ^= key[i] }

        guard let chunks = parseChunks(body), chunks.count > 3 else { return nil }
        guard let ihdr = chunks.first(where: { $0.type == "IHDR" }), ihdr.dataLen >= 8 else { return nil }
        let width = int32(body, ihdr.dataStart)
        let height = int32(body, ihdr.dataStart + 4)
        guard width > 0, height > 0, width < 20000, height < 20000 else { return nil }

        let frameStarts = chunks.enumerated().filter { $0.element.type == "fcTL" }.map { $0.offset }
        guard frameStarts.count > 1 else { return nil }

        let frameBytes = Int(width) * Int(height) * 4
        let maxFrames = max(1, limit / max(frameBytes, 1))
        guard frameStarts.count > maxFrames else { return nil }

        let stride = Int((Double(frameStarts.count) / Double(maxFrames)).rounded(.up))
        var keep: [Int] = []
        var i = 0
        while i < frameStarts.count {
            keep.append(i)
            i += stride
        }
        guard keep.count < frameStarts.count else { return nil }

        // 组装：签名 + 帧前块（acTL 改写帧数）+ 保留帧的 fcTL/fdAT + IEND
        var out: [UInt8] = []
        out.append(contentsOf: body[0..<8])     // PNG 签名
        let firstFrameChunk = frameStarts[0]

        for c in chunks {
            if c.start >= chunks[firstFrameChunk].start { break }
            if c.type == "acTL" {
                var d = Array(body[c.dataStart..<(c.dataStart + c.dataLen)])
                guard d.count >= 8 else { continue }
                putInt32(&d, 0, UInt32(keep.count))
                out.append(contentsOf: makeChunk("acTL", d))
            } else if c.type == "IEND" {
                continue
            } else {
                out.append(contentsOf: body[c.start..<c.end])
            }
        }

        var seq: UInt32 = 0
        for (n, frameIdx) in keep.enumerated() {
            let c = chunks[frameStarts[frameIdx]]
            var d = Array(body[c.dataStart..<(c.dataStart + c.dataLen)])
            guard d.count >= 26 else { return nil }

            // 延迟按跳过的帧数累加，保证总时长不变
            // fcTL: seq(4) w(4) h(4) x(4) y(4) delay_num(2) delay_den(2) dispose(1) blend(1)
            let gap: Int
            if n == 0 {
                gap = keep.count > 1 ? keep[1] : frameStarts.count
            } else {
                gap = keep[n] - keep[n - 1]
            }
            let delayNum = int16(d, 20)
            let delayDen = int16(d, 22)
            let scaled = min(65535, max(1, Int(delayNum) * gap))
            putInt32(&d, 0, seq)
            seq += 1
            putInt16(&d, 20, UInt16(scaled))
            if delayDen == 0 { putInt16(&d, 22, 100) }
            out.append(contentsOf: makeChunk("fcTL", d))

            // 该帧的数据块：第 0 帧是 IDAT，其余是 fdAT
            let nextStart = frameIdx + 1 < frameStarts.count ? chunks[frameStarts[frameIdx + 1]].start
                                                             : (chunks.first(where: { $0.type == "IEND" })?.start ?? body.count)
            for dc in chunks where dc.start >= c.end && dc.start < nextStart {
                if dc.type == "fdAT" {
                    var fd = Array(body[dc.dataStart..<(dc.dataStart + dc.dataLen)])
                    guard fd.count >= 4 else { continue }
                    putInt32(&fd, 0, seq)
                    seq += 1
                    out.append(contentsOf: makeChunk("fdAT", fd))
                } else if dc.type == "IDAT" {
                    out.append(contentsOf: body[dc.start..<dc.end])
                }
            }
        }

        out.append(contentsOf: makeChunk("IEND", []))

        // 重新异或前 16 字节，保持与其它资源一致的加密格式
        guard out.count > 16 else { return nil }
        for i in 0..<16 { out[i] ^= key[i] }

        var result = Data(raw[0..<16])
        result.append(contentsOf: out)
        return Result(data: result, framesBefore: frameStarts.count, framesAfter: keep.count)
    }

    // MARK: - 块解析与构造

    private static func parseChunks(_ b: [UInt8]) -> [Chunk]? {
        var chunks: [Chunk] = []
        var p = 8
        while p + 12 <= b.count {
            let len = Int(be32(b, p))
            let typeStart = p + 4
            guard len >= 0, typeStart + 8 + len <= b.count else { return nil }
            let type = String(bytes: b[typeStart..<(typeStart + 4)], encoding: .ascii) ?? ""
            let dataStart = typeStart + 4
            let end = dataStart + len + 4      // 含 CRC
            chunks.append(Chunk(type: type, start: p, dataStart: dataStart, dataLen: len, end: end))
            if type == "IEND" { break }
            p = end
        }
        return chunks.isEmpty ? nil : chunks
    }

    private static func makeChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        var crc = crc32(typeBytes + data).bigEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        return out
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    private static func int32(_ b: [UInt8], _ i: Int) -> Int {
        Int(be32(b, i))
    }

    private static func int16(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 8) | Int(b[i + 1])
    }

    private static func putInt32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        b[i] = UInt8((v >> 24) & 0xFF)
        b[i + 1] = UInt8((v >> 16) & 0xFF)
        b[i + 2] = UInt8((v >> 8) & 0xFF)
        b[i + 3] = UInt8(v & 0xFF)
    }

    private static func putInt16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) {
        b[i] = UInt8((v >> 8) & 0xFF)
        b[i + 1] = UInt8(v & 0xFF)
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}
