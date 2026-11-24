//
//  SevenZipReader.swift
//  像素抽屉
//
//  7z 容器的只读实现。解码全部交给 LZMA SDK 的 C 接口（见 SevenZipBridge），
//  Swift 这层只负责把条目整理成 ArchiveEntry、按需解到文件或内存。
//

import Foundation

enum SevenZipError: LocalizedError {
    case openFailed
    case notArchive
    case encrypted
    case unsupported
    case corrupted
    case blockTooBig
    case outOfMemory
    case readFailed
    case badEntry(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "打不开这个 7z 文件"
        case .notArchive: return "不是有效的 7z 文件"
        case .encrypted: return "这个 7z 设了密码，当前版本无法解开；请先解压成文件夹再导入，或改用 zip 打包"
        case .unsupported: return "包里用了不支持的压缩方法，请解压后重新打包"
        case .corrupted: return "7z 结构损坏或数据校验失败"
        case .blockTooBig: return "包内单个固实块超过内存上限，请用非固实方式重新打包"
        case .outOfMemory: return "内存不足，无法解压这个 7z"
        case .readFailed: return "读取 7z 时出错"
        case .badEntry(let name): return "条目损坏：\(name)"
        }
    }

    init(code: Int32) {
        switch Int(code) {
        case GS7Z_ERR_UNSUPPORTED: self = .unsupported
        case GS7Z_ERR_CRC: self = .corrupted
        case GS7Z_ERR_MEM: self = .outOfMemory
        case GS7Z_ERR_READ: self = .readFailed
        case GS7Z_ERR_BLOCK_TOO_BIG: self = .blockTooBig
        case GS7Z_ERR_NOT_ARCHIVE: self = .notArchive
        default: self = .corrupted
        }
    }
}

final class SevenZipReader: ArchiveReader {
    let entries: [ArchiveEntry]

    private let handle: OpaquePointer
    private let encrypted: Bool
    private let indexByName: [String: Int]

    var password: String?

    init(url: URL) throws {
        guard let h = gs7z_open(url.path) else { throw SevenZipError.openFailed }
        let code = gs7z_error(h)
        guard code == GS7Z_OK else {
            gs7z_close(h)
            // 头部加密时 SDK 只回 UNSUPPORTED，这里换成能指导用户的文案
            throw SevenZipError.encrypted
        }

        handle = h
        encrypted = gs7z_is_encrypted(h) != 0

        var list: [ArchiveEntry] = []
        var map: [String: Int] = [:]
        let count = gs7z_count(h)
        list.reserveCapacity(Int(count))
        for i in 0..<count {
            let name = Self.normalize(String(cString: gs7z_name(h, i)))
            guard !name.isEmpty else { continue }
            let entry = ArchiveEntry(
                name: name,
                uncompressedSize: Int(gs7z_size(h, i)),
                isDirectory: gs7z_is_dir(h, i) != 0
            )
            map[name] = list.count
            list.append(entry)
        }
        entries = list
        indexByName = map
    }

    deinit {
        gs7z_close(handle)
    }

    // MARK: - 读取

    func read(_ entry: ArchiveEntry) throws -> Data {
        try ensureReadable(entry)
        guard let index = indexByName[entry.name] else { throw SevenZipError.badEntry(entry.name) }

        var raw: UnsafeMutablePointer<UInt8>?
        var size: UInt64 = 0
        let code = gs7z_extract_bytes(handle, UInt64(index), &raw, &size)
        guard code == GS7Z_OK else { throw SevenZipError(code: code) }
        guard let raw else { return Data() }
        defer { gs7z_free(raw) }
        return Data(bytes: raw, count: Int(size))
    }

    func readPrefix(_ entry: ArchiveEntry, max: Int = 128) throws -> Data {
        // 7z 的固实块没法只解开头一段，索性整条读出再截断
        Data(try read(entry).prefix(max))
    }

    // MARK: - 落盘

    func extract(_ entry: ArchiveEntry, to destination: URL, onBytes: ((Int) -> Void)? = nil) throws {
        try ensureReadable(entry)
        guard let index = indexByName[entry.name] else { throw SevenZipError.badEntry(entry.name) }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw SevenZipError.badEntry(entry.name) }
        defer { close(fd) }

        var written: UInt64 = 0
        let code = gs7z_extract(handle, UInt64(index), fd, &written)
        guard code == GS7Z_OK else { throw SevenZipError(code: code) }
        onBytes?(Int(written))
    }

    @discardableResult
    func extract(_ selected: [ArchiveEntry],
                 stripping prefix: String,
                 to directory: URL,
                 progress: ((Int64, Int64) -> Void)? = nil) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.standardizedFileURL.path

        let total = selected.reduce(Int64(0)) { $0 + Int64(max($1.uncompressedSize, 0)) }
        var done: Int64 = 0
        var lastReported: Int64 = -1
        let step = max(total / 250, 1)

        func report(force: Bool = false) {
            guard let progress else { return }
            if force || done - lastReported >= step {
                lastReported = done
                progress(done, total)
            }
        }

        var written = 0
        for entry in selected where entry.isDirectory {
            guard let rel = ArchivePath.relative(entry.name, stripping: prefix), !rel.isEmpty else { continue }
            let target = directory.appendingPathComponent(rel).standardizedFileURL
            guard target.path.hasPrefix(base) else { continue }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }

        for entry in selected where !entry.isDirectory {
            guard let rel = ArchivePath.relative(entry.name, stripping: prefix), !rel.isEmpty else { continue }
            let target = directory.appendingPathComponent(rel).standardizedFileURL
            guard target.path.hasPrefix(base) else { continue }
            try extract(entry, to: target)
            done += Int64(max(entry.uncompressedSize, 0))
            written += 1
            report()
        }

        report(force: true)
        return written
    }

    // MARK: - 内部

    /// 7z 的路径分隔符跟着打包时的系统走（Windows 那批就是反斜杠），
    /// 这里统一成 `/` 并去掉开头的 `./`，否则根目录判定与解包路径都会对不上。
    private static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func ensureReadable(_ entry: ArchiveEntry) throws {
        if encrypted { throw SevenZipError.encrypted }
        _ = entry
    }
}
