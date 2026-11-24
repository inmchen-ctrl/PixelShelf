//
//  ArchiveReader.swift
//  像素抽屉
//
//  导入流程只关心「包里有那些文件、把某个文件解出来」这一件事，与具体容器格式无关。
//  ZIP（含加密）与 7z 各自实现这套接口，引擎判定、解包落盘、封面提取共用同一条路径。
//

import Foundation

/// 归档条目的统一表示。
///
/// ZIP 的字段是解析出来的真实值；7z 的目录结构里没有这些概念，
/// 由 `SevenZipReader` 填默认值，`isDirectory` 靠名字末尾补 `/` 表达。
struct ArchiveEntry {
    let name: String
    /// 压缩方式：0 存储 / 8 deflate。7z 条目恒为 0（真实算法在 coder 图里，上层用不到）
    let method: UInt16
    /// 压缩后大小。AES 条目包含 salt + 2 字节校验值 + 10 字节 MAC
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    let flags: UInt16
    let crc32: UInt32
    let dosTime: UInt16
    /// 非 nil 表示 WinZip AES，值为密钥位数（128 / 192 / 256）
    let aesKeyBits: Int?

    var isDirectory: Bool { name.hasSuffix("/") }
    var isEncrypted: Bool { flags & 0x0001 != 0 }
    var isAES: Bool { aesKeyBits != nil }

    /// AES 的额外开销：salt + 2 字节密码校验 + 10 字节 HMAC
    var aesOverhead: Int { (aesKeyBits == 256 ? 16 : 8) + 2 + 10 }

    init(name: String,
         method: UInt16,
         compressedSize: Int,
         uncompressedSize: Int,
         localHeaderOffset: Int,
         flags: UInt16,
         crc32: UInt32,
         dosTime: UInt16,
         aesKeyBits: Int?) {
        self.name = name
        self.method = method
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.localHeaderOffset = localHeaderOffset
        self.flags = flags
        self.crc32 = crc32
        self.dosTime = dosTime
        self.aesKeyBits = aesKeyBits
    }

    /// 7z 等「只给名字和大小」的容器用这个
    init(name: String, uncompressedSize: Int, isDirectory: Bool) {
        self.init(
            name: isDirectory && !name.hasSuffix("/") ? name + "/" : name,
            method: 0,
            compressedSize: uncompressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: 0,
            flags: 0,
            crc32: 0,
            dosTime: 0,
            aesKeyBits: nil
        )
    }
}

/// 只读归档的统一接口
protocol ArchiveReader: AnyObject {
    var entries: [ArchiveEntry] { get }
    /// 加密包的口令。7z 暂未支持解密，赋值后遇到加密条目会抛出可读错误
    var password: String? { get set }

    func read(_ entry: ArchiveEntry) throws -> Data
    func readPrefix(_ entry: ArchiveEntry, max: Int) throws -> Data
    func text(_ entry: ArchiveEntry, limit: Int) -> String?

    /// 把单个条目写到指定路径，边解边写，内存占用固定
    func extract(_ entry: ArchiveEntry, to destination: URL, onBytes: ((Int) -> Void)?) throws

    /// 把指定条目解到目录下，prefix 会被剥掉；返回写入文件数
    @discardableResult
    func extract(_ selected: [ArchiveEntry],
                 stripping prefix: String,
                 to directory: URL,
                 progress: ((Int64, Int64) -> Void)?) throws -> Int
}

extension ArchiveReader {
    func text(_ entry: ArchiveEntry, limit: Int = 400_000) -> String? {
        guard entry.uncompressedSize <= limit, let data = try? read(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func readPrefix(_ entry: ArchiveEntry, max: Int = 128) throws -> Data {
        Data(try read(entry).prefix(max))
    }
}

enum ArchivePath {
    /// 去掉公共前缀后的相对路径；不在该前缀下时返回 nil
    static func relative(_ name: String, stripping prefix: String) -> String? {
        guard !prefix.isEmpty else { return name }
        guard name.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(name.dropFirst(prefix.count))
    }
}
