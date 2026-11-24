import Foundation

/// Godot 4.5+ 的 "sparse bundle" 打包：`.sparsepck` 里只有头部 + 资源目录，
/// 每个资源的字节则以散文件的形式摊在它旁边（路径与目录项一致）。
///
/// 这里做的是把它拼回一份标准 .pck —— 引擎（Web 运行时）只认标准包，
/// 而目录项里已经带好了 size 和 md5，所以重打包是纯机械拼接，不需要解析资源内容。
enum PckBuilder {

    struct Entry {
        var path: String
        var size: UInt64
        var md5: Data
        var flags: UInt32
    }

    enum BuildError: LocalizedError {
        case badHeader(String)
        case badDirectory(String)
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .badHeader(let detail): return "散装资源包头无法解析：\(detail)"
            case .badDirectory(let detail): return "散装资源包目录无法解析：\(detail)"
            case .missingFile(let name): return "散装资源包缺少文件：\(name)"
            }
        }
    }

    private static let headerSize = 104
    private static let alignment = 16

    /// 读 sparsepck 的头部与目录
    static func parse(_ blob: Data) throws -> (header: Data, entries: [Entry]) {
        let bytes = [UInt8](blob)
        guard bytes.count >= headerSize, String(bytes: bytes[0..<4], encoding: .ascii) == "GDPC" else {
            throw BuildError.badHeader("缺少 GDPC 标识")
        }
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
                | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        }
        func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | (UInt64(u32(at + 4)) << 32) }

        let packVersion = u32(4)
        guard (1...5).contains(packVersion) else { throw BuildError.badHeader("pack 版本 \(packVersion)") }

        // v3 起头部多了 dir_offset
        var dirOffset = 0
        if packVersion >= 3, bytes.count >= 40 { dirOffset = Int(u64(32)) }
        guard dirOffset > 0, dirOffset < bytes.count else { throw BuildError.badHeader("目录偏移 \(dirOffset)") }

        var pos = dirOffset
        guard pos + 4 <= bytes.count else { throw BuildError.badDirectory("截断") }
        let count = Int(u32(pos)); pos += 4
        guard count > 0, count < 5_000_000 else { throw BuildError.badDirectory("条目数 \(count)") }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard pos + 4 <= bytes.count else { throw BuildError.badDirectory("路径长度越界") }
            let pathLength = Int(u32(pos)); pos += 4
            guard pathLength > 0, pos + pathLength <= bytes.count else { throw BuildError.badDirectory("路径越界") }
            var pathBytes = Array(bytes[pos..<(pos + pathLength)])
            pos += pathLength
            while let last = pathBytes.last, last == 0 { pathBytes.removeLast() }
            guard let path = String(bytes: pathBytes, encoding: .utf8), !path.isEmpty else {
                throw BuildError.badDirectory("路径解码失败")
            }
            guard pos + 36 <= bytes.count else { throw BuildError.badDirectory("条目字段越界") }
            pos += 8                                    // offset：散装包里没有意义
            let size = u64(pos); pos += 8
            let md5 = Data(bytes[pos..<(pos + 16)]); pos += 16
            let flags = u32(pos); pos += 4
            entries.append(Entry(path: path, size: size, md5: md5, flags: flags))
        }
        return (Data(bytes[0..<headerSize]), entries)
    }

    /// 用 ZIP 里的散文件重建标准 pck
    /// - Parameters:
    ///   - blob: sparsepck 的内容
    ///   - reader: APK
    ///   - loosePrefix: 散文件相对 APK 根的前缀（sparsepck 所在目录，例如 "assets/"）
    ///   - target: 输出的 .pck
    static func rebuild(
        sparse blob: Data,
        reader: ZipReader,
        loosePrefix: String,
        to target: URL,
        progress: (Double) -> Void = { _ in }
    ) throws {
        let parsed = try parse(blob)
        let header = parsed.header
        let entries = parsed.entries

        // 散文件索引
        var index: [String: Int] = [:]
        for (i, entry) in reader.entries.enumerated() where !entry.isDirectory {
            index[entry.name] = i
        }

        let fm = FileManager.default
        try? fm.removeItem(at: target)
        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw BuildError.badHeader("无法创建 \(target.lastPathComponent)")
        }
        guard let handle = try? FileHandle(forWritingTo: target) else {
            throw BuildError.badHeader("无法写入 \(target.lastPathComponent)")
        }
        defer { try? handle.close() }

        let fileBase = (headerSize + alignment - 1) / alignment * alignment
        try handle.write(contentsOf: Data(count: fileBase))

        var written: [(entry: Entry, offset: UInt64)] = []
        written.reserveCapacity(entries.count)
        var cursor = fileBase

        for (i, entry) in entries.enumerated() {
            let zipName = loosePrefix + entry.path
            guard let zi = index[zipName] ?? index[entry.path] else {
                throw BuildError.missingFile(zipName)
            }
            let data = try reader.read(reader.entries[zi])
            if UInt64(data.count) != entry.size {
                throw BuildError.badDirectory("\(entry.path) 大小不符（目录 \(entry.size)，实际 \(data.count)）")
            }
            try handle.write(contentsOf: data)
            written.append((entry, UInt64(cursor - fileBase)))
            cursor += data.count
            let padding = (alignment - cursor % alignment) % alignment
            if padding > 0 {
                try handle.write(contentsOf: Data(count: padding))
                cursor += padding
            }
            if i % 64 == 0 { progress(Double(i) / Double(entries.count)) }
        }

        // 目录
        let dirPadding = (alignment - cursor % alignment) % alignment
        if dirPadding > 0 {
            try handle.write(contentsOf: Data(count: dirPadding))
            cursor += dirPadding
        }
        let dirOffset = cursor

        var dir = Data()
        dir.append(contentsOf: le32(UInt32(entries.count)))
        for item in written {
            let pathBytes = Array(item.entry.path.utf8)
            let padded = (pathBytes.count + 3) / 4 * 4
            dir.append(contentsOf: le32(UInt32(padded)))
            dir.append(contentsOf: pathBytes)
            dir.append(contentsOf: Data(count: padded - pathBytes.count))
            dir.append(contentsOf: le64(item.offset))
            dir.append(contentsOf: le64(item.entry.size))
            dir.append(contentsOf: item.entry.md5)
            dir.append(contentsOf: le32(item.entry.flags))
        }
        try handle.write(contentsOf: dir)
        let end = cursor + dir.count

        // 回填头部：保留原 engine 版本，清掉 sparse 标志，写入 file_base / dir_offset
        var head = header
        func store32(_ value: UInt32, at offset: Int) {
            let b = le32(value)
            for i in 0..<4 { head[offset + i] = b[b.startIndex + i] }
        }
        func store64(_ value: UInt64, at offset: Int) {
            let b = le64(value)
            for i in 0..<8 { head[offset + i] = b[b.startIndex + i] }
        }
        let originalFlags = UInt32(header[20]) | (UInt32(header[21]) << 8)
            | (UInt32(header[22]) << 16) | (UInt32(header[23]) << 24)
        store32(originalFlags & ~0x4 | 0x2, at: 20)   // 去掉 SPARSE，保留 REL_FILEBASE
        store64(UInt64(fileBase), at: 24)
        store64(UInt64(dirOffset), at: 32)

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: head)
        try handle.truncate(atOffset: UInt64(end))
        progress(1.0)
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
              UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }

    private static func le64(_ value: UInt64) -> Data {
        var data = Data()
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
        return data
    }
}
