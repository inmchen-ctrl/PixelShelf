import Foundation

/// Godot 资源包（.pck）头部信息。只读前几十个字节，不碰包内容。
struct PckInfo: Sendable {
    let packVersion: Int
    let major: Int
    let minor: Int
    let patch: Int
    let flags: UInt32

    var versionText: String { "\(major).\(minor).\(patch)" }
    var isDirectoryEncrypted: Bool { flags & 1 != 0 }
    var isSparseBundle: Bool { flags & (1 << 2) != 0 }
}

enum PckProbe {
    private static let magic: UInt32 = 0x4350_4447  // 'GDPC'，小端读出的 u32

    /// head 至少 20 字节；不是 pck 或数据截断时返回 nil
    static func parse(_ head: Data) -> PckInfo? {
        let bytes = [UInt8](head.prefix(64))
        guard bytes.count >= 20 else { return nil }

        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        guard u32(0) == magic else { return nil }
        let packVersion = Int(u32(4))
        guard (1...5).contains(packVersion) else { return nil }

        // pack_version >= 2 才有 flags 字段
        let flags = packVersion >= 2 && bytes.count >= 24 ? u32(20) : 0

        return PckInfo(
            packVersion: packVersion,
            major: Int(u32(8)),
            minor: Int(u32(12)),
            patch: Int(u32(16)),
            flags: flags
        )
    }
}
