import Foundation
import Compression

/// SWF 文件头部解析。
///
/// Flash 舞台的宽高写在文件最前面的 Rect 字段里（单位 twips，1/20 像素）。
/// 这个值是游戏的固有属性，比"进游戏截图量黑边"稳定得多——
/// 截图会被过场、动态画面干扰，量出来的比例每次都可能不一样。
///
/// 头部结构：3 字节签名（FWS 未压缩 / CWS zlib / ZWS lzma）+ 版本 + 文件长度。
/// **FWS** 的 Rect 在第 9 字节起明文；**CWS** 第 9 字节起是整段 zlib 流，
/// Rect 是解压后的头几个字节（注意 Apple 的 COMPRESSION_ZLIB 吃的是裸 deflate，
/// 要先跳过 zlib 流自己的 2 字节头 0x78 0x9C）。ZWS（LZMA）的容器头比较特殊，暂不支持。
enum SwfHeader {
    static func stageAspect(at url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 1 << 20), head.count >= 16 else { return nil }
        let bytes = [UInt8](head)
        let signature = String(bytes: bytes[0..<3], encoding: .ascii)
        guard signature == "FWS" || signature == "CWS" else { return nil }

        let rectBytes: [UInt8]
        if signature == "FWS" {
            rectBytes = Array(bytes[8...])
        } else {
            // CWS：跳过 zlib 包装头 2 字节，裸 deflate 解压
            let src = Array(bytes[10...])
            guard src.count > 8 else { return nil }
            let dstCount = 4096
            var dst = [UInt8](repeating: 0, count: dstCount)
            let decoded: Int = dst.withUnsafeMutableBytes { dstPtr in
                src.withUnsafeBufferPointer { srcPtr in
                    compression_decode_buffer(
                        dstPtr.baseAddress!, dstCount,
                        srcPtr.baseAddress! + 2, src.count - 2,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard decoded >= 8 else { return nil }
            rectBytes = Array(dst[0..<decoded])
        }

        return rectAspect(rectBytes)
    }

    /// Rect 字段：5 bit 的 NBits，跟 4 个 NBits 宽的有符号数（xmin/xmax/ymin/ymax，twips）
    private static func rectAspect(_ bytes: [UInt8]) -> Double? {
        guard !bytes.isEmpty else { return nil }
        let nBits = Int(bytes[0] >> 3)
        guard nBits > 0, nBits <= 31, 5 + 4 * nBits <= bytes.count * 8 else { return nil }

        var bitIndex = 5
        var values = [Int]()
        for _ in 0..<4 {
            var value = 0
            for _ in 0..<nBits {
                let byte = bytes[bitIndex / 8]
                let bit = (byte >> (7 - bitIndex % 8)) & 1
                value = (value << 1) | Int(bit)
                bitIndex += 1
            }
            if value >= 1 << (nBits - 1) { value -= 1 << nBits } // 符号位扩展
            values.append(value)
        }

        let width = Double(values[1] - values[0])
        let height = Double(values[3] - values[2])
        guard width > 0, height > 0 else { return nil }
        return width / height
    }

    /// 目录里最大的 SWF 通常是主影片（其余是子加载的资源片）。
    static func stageAspectInFolder(_ folder: URL) -> Double? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let swfs = files.filter { $0.pathExtension.lowercased() == "swf" }
            .sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        for swf in swfs {
            if let aspect = stageAspect(at: swf) { return aspect }
        }
        return nil
    }
}

private extension URL {
    var fileSize: Int64? {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}
