import Foundation

enum ZipError: LocalizedError {
    case notZip
    case truncated
    case badEntry(String)
    case unsupportedMethod(UInt16)
    case inflateFailed(String)
    case passwordRequired
    case wrongPassword
    case unsupportedCipher

    var errorDescription: String? {
        switch self {
        case .notZip: return "不是有效的 zip / apk 文件"
        case .truncated: return "压缩包结构不完整"
        case .badEntry(let name): return "条目损坏：\(name)"
        case .unsupportedMethod(let m): return "不支持的压缩方式（method \(m)）"
        case .inflateFailed(let name): return "解压失败：\(name)"
        case .passwordRequired: return "压缩包已加密，需要输入密码"
        case .wrongPassword: return "密码不正确"
        case .unsupportedCipher: return "不是有效的 zip / apk 文件（不支持的加密方式）"
        }
    }
}

/// 极简 zip 读取器：支持 stored / deflate（含 zip64）。
///
/// 全程走 `FileHandle` 随机读 + zlib 流式解压，**不把整包读进内存**——
/// 2~3 GB 的游戏包用 `Data(contentsOf:)` 会直接把进程顶到 jetsam，
/// 或者让文件的页缓存和写入互相挤。
final class ZipReader: ArchiveReader {
    private let handle: FileHandle
    private let fileSize: Int
    private(set) var entries: [ArchiveEntry] = []

    /// 加密包的密码。导入前由调用方设进来；为 nil 时读到加密条目会抛 `.passwordRequired`。
    var password: String?

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    init(url: URL) throws {
        let h: FileHandle
        do {
            h = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipError.notZip
        }
        self.handle = h
        let size = (try? h.seekToEnd()).map { Int($0) } ?? 0
        self.fileSize = size
        try parse()
    }

    deinit {
        try? handle.close()
    }

    // MARK: - 底层读

    private func readBytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= fileSize else { throw ZipError.truncated }
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        guard let d = try handle.read(upToCount: count), d.count == count else {
            throw ZipError.truncated
        }
        return d
    }

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8)
    }

    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[d.startIndex + i])
            | (UInt32(d[d.startIndex + i + 1]) << 8)
            | (UInt32(d[d.startIndex + i + 2]) << 16)
            | (UInt32(d[d.startIndex + i + 3]) << 24)
    }

    private static func u64(_ d: Data, _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in (0..<8).reversed() {
            v = (v << 8) | UInt64(d[d.startIndex + i + k])
        }
        return v
    }

    // MARK: - 中央目录

    private func parse() throws {
        guard fileSize > 22 else { throw ZipError.notZip }

        // 1) 先在尾部 66 KB 里找 EOCD
        let tailLen = min(fileSize, 66_000 + 22)
        let tailStart = fileSize - tailLen
        let tail = try readBytes(at: tailStart, count: tailLen)

        var eocdLocal = -1
        var i = tailLen - 22
        while i >= 0 {
            if tail[tail.startIndex + i] == 0x50, tail[tail.startIndex + i + 1] == 0x4B,
               tail[tail.startIndex + i + 2] == 0x05, tail[tail.startIndex + i + 3] == 0x06 {
                eocdLocal = i
                break
            }
            i -= 1
        }
        guard eocdLocal >= 0 else { throw ZipError.notZip }

        let eocd = tail.subdata(in: (tail.startIndex + eocdLocal)..<(tail.startIndex + eocdLocal + 22))
        var count = Int(Self.u16(eocd, 10))
        var cdOffset = Int(Self.u32(eocd, 16))
        var cdSize = Int(Self.u32(eocd, 12))

        // 2) zip64：字段溢出时读 zip64 EOCD
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF {
            let eocdAbs = tailStart + eocdLocal
            if eocdAbs >= 20 {
                if let locator = try? readBytes(at: eocdAbs - 20, count: 20),
                   Self.u32(locator, 0) == 0x0706_4B50 {
                    let z64Off = Int(Self.u64(locator, 8))
                    if let z64 = try? readBytes(at: z64Off, count: 56),
                       Self.u32(z64, 0) == 0x0606_4B50 {
                        count = Int(Self.u64(z64, 32))
                        cdSize = Int(Self.u64(z64, 40))
                        cdOffset = Int(Self.u64(z64, 48))
                        if count == 0 || cdOffset == 0 { throw ZipError.truncated }
                    }
                }
            }
        }

        guard count >= 0, cdOffset > 0, cdOffset < fileSize else { throw ZipError.truncated }
        _ = cdSize

        var cursor = cdOffset
        entries.reserveCapacity(min(count, 20_000))

        for _ in 0..<count {
            guard cursor + 46 <= fileSize else { throw ZipError.truncated }
            let header = try readBytes(at: cursor, count: 46)
            guard Self.u32(header, 0) == 0x0201_4B50 else { throw ZipError.truncated }

            let recordedMethod = Self.u16(header, 10)
            let dosTime = Self.u16(header, 12)
            let crc = Self.u32(header, 16)
            let flags = Self.u16(header, 8)
            var compSize = Int(Self.u32(header, 20))
            var uncompSize = Int(Self.u32(header, 24))
            let nameLen = Int(Self.u16(header, 28))
            let extraLen = Int(Self.u16(header, 30))
            let commentLen = Int(Self.u16(header, 32))
            var localOff = Int(Self.u32(header, 42))

            guard cursor + 46 + nameLen + extraLen + commentLen <= fileSize else { throw ZipError.truncated }
            // 名字与扩展字段一次读出来：一万多个条目时省掉一半随机读
            let variableLen = nameLen + extraLen
            let variable = try readBytes(at: cursor + 46, count: variableLen)
            let name = decodeName(Data(variable.prefix(nameLen)))
            let extra = extraLen > 0
                ? variable.subdata(in: nameLen..<(nameLen + extraLen))
                : Data()

            var method = recordedMethod
            var aesKeyBits: Int?

            if extraLen > 0 {
                let needsZip64 = compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF || localOff == 0xFFFF_FFFF
                var e = 0
                while e + 4 <= extraLen {
                    let tag = Self.u16(extra, e)
                    let size = Int(Self.u16(extra, e + 2))
                    guard e + 4 + size <= extraLen else { break }
                    if tag == 0x0001, needsZip64 {
                        var p = e + 4
                        if uncompSize == 0xFFFF_FFFF, p + 8 <= e + 4 + size {
                            uncompSize = Int(Self.u64(extra, p)); p += 8
                        }
                        if compSize == 0xFFFF_FFFF, p + 8 <= e + 4 + size {
                            compSize = Int(Self.u64(extra, p)); p += 8
                        }
                        if localOff == 0xFFFF_FFFF, p + 8 <= e + 4 + size {
                            localOff = Int(Self.u64(extra, p)); p += 8
                        }
                    } else if tag == 0x9901, size >= 7 {
                        // WinZip AES：版本(2) "AE"(2) 强度(1) 真实压缩方式(2)
                        let strength = extra[extra.startIndex + e + 8]
                        method = Self.u16(extra, e + 9)
                        aesKeyBits = strength == 3 ? 256 : (strength == 2 ? 192 : 128)
                    }
                    e += 4 + size
                }
            }

            entries.append(
                ArchiveEntry(
                    name: name,
                    method: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOff,
                    flags: flags,
                    crc32: crc,
                    dosTime: dosTime,
                    aesKeyBits: aesKeyBits
                )
            )
            cursor += 46 + nameLen + extraLen + commentLen
        }
    }

    private func decodeName(_ bytes: Data) -> String {
        if let s = String(data: bytes, encoding: .utf8) { return s }
        if let s = String(data: bytes, encoding: Self.gb18030) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 条目定位

    /// 返回压缩数据在文件里的起点
    private func dataStart(of entry: ArchiveEntry) throws -> Int {
        let off = entry.localHeaderOffset
        guard off >= 0, off + 30 <= fileSize else { throw ZipError.badEntry(entry.name) }
        let header = try readBytes(at: off, count: 30)
        guard Self.u32(header, 0) == 0x0403_4B50 else { throw ZipError.badEntry(entry.name) }
        let nameLen = Int(Self.u16(header, 26))
        let extraLen = Int(Self.u16(header, 28))
        let start = off + 30 + nameLen + extraLen
        guard start >= 0, start + entry.compressedSize <= fileSize else { throw ZipError.truncated }
        return start
    }

    /// 解出「真实载荷」的范围，加密条目顺带建好解密器。
    ///
    /// 加密包的前置开销（ZipCrypto 的 12 字节头、AES 的 salt + 校验值）和尾部 MAC
    /// 都在这里剥掉，后面的解压/落盘代码看到的就是一段纯密文。
    private func payload(_ entry: ArchiveEntry) throws
        -> (start: Int, length: Int, decryptor: ZipDecryptor?) {
        let start = try dataStart(of: entry)
        guard entry.isEncrypted else { return (start, entry.compressedSize, nil) }
        guard let password, !password.isEmpty else { throw ZipError.passwordRequired }

        if let bits = entry.aesKeyBits {
            let saltLen = bits == 256 ? 16 : 8
            let overhead = saltLen + 2 + 10
            guard entry.compressedSize >= overhead else { throw ZipError.badEntry(entry.name) }

            let head = try readBytes(at: start, count: saltLen + 2)
            let salt = Array(head.prefix(saltLen))
            let verifier = Array(head.suffix(2))
            guard let keys = ZipAES.derive(password: password, salt: salt, keyBits: bits) else {
                throw ZipError.unsupportedCipher
            }
            // 2 字节校验值：密码错了这里就拦住，不用等 inflate 失败
            guard keys.verifier == verifier else { throw ZipError.wrongPassword }
            guard let aes = AESCTRStream(key: keys.encKey) else { throw ZipError.unsupportedCipher }

            let payloadLen = entry.compressedSize - overhead
            let mac = Array(try readBytes(at: start + saltLen + 2 + payloadLen, count: 10))
            return (start + saltLen + 2, payloadLen,
                    ZipDecryptor(aes: aes, hmac: SHA1HMAC(key: keys.authKey), mac: mac))
        }

        guard entry.compressedSize > 12 else { throw ZipError.badEntry(entry.name) }
        let stream = ZipCryptoStream(password: password)
        var probe = Array(try readBytes(at: start, count: 12))
        stream.decrypt(&probe, 12)
        let expected = ZipCryptoStream.checkByte(
            crc: entry.crc32,
            dosTime: entry.dosTime,
            usesDescriptor: entry.flags & 0x0008 != 0
        )
        guard probe[11] == expected else { throw ZipError.wrongPassword }
        return (start + 12, entry.compressedSize - 12, ZipDecryptor(zip: stream))
    }

    // MARK: - 读取

    func read(_ entry: ArchiveEntry) throws -> Data {
        let info = try payload(entry)
        let size = entry.uncompressedSize
        // 兜底上限：单个条目超过 512 MB 就不整块进内存了（游戏里不会有这种文件）
        guard size <= 512 << 20 else { throw ZipError.inflateFailed(entry.name) }

        switch entry.method {
        case 0:
            var bytes = Array(try readBytes(at: info.start, count: info.length))
            if let d = info.decryptor {
                d.consume(&bytes)
                try d.verifyMAC()
            }
            return Data(bytes)
        case 8:
            return try inflateFully(start: info.start, length: info.length, decryptor: info.decryptor,
                                    expected: size, name: entry.name)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    func text(_ entry: ArchiveEntry, limit: Int = 400_000) -> String? {
        guard entry.uncompressedSize <= limit, let d = try? read(entry) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 只取条目前若干字节（读 pck 头这类场景），不解压整个条目。
    /// 前缀读不校验 AES 的尾部 MAC —— 没有读完整个载荷，校验值天然对不上。
    func readPrefix(_ entry: ArchiveEntry, max: Int = 128) throws -> Data {
        let info = try payload(entry)
        switch entry.method {
        case 0:
            var bytes = Array(try readBytes(at: info.start, count: min(max, info.length)))
            info.decryptor?.consume(&bytes)
            return Data(bytes)
        case 8:
            let want = min(max, entry.uncompressedSize)
            guard want > 0 else { return Data() }
            return try inflatePrefix(start: info.start, length: info.length, decryptor: info.decryptor,
                                     want: want, name: entry.name)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    private func inflateFully(start: Int, length: Int, decryptor: ZipDecryptor?,
                              expected: Int, name: String) throws -> Data {
        guard expected > 0 else { return Data() }
        var output = Data(capacity: expected)
        try inflateStream(start: start, length: length, decryptor: decryptor, name: name,
                          outCapacity: 512 << 10) { buf, n in
            guard output.count + n <= expected else { throw ZipError.inflateFailed(name) }
            output.append(Data(bytes: buf, count: n))
        }
        try decryptor?.verifyMAC()
        guard output.count == expected else { throw ZipError.inflateFailed(name) }
        return output
    }

    private func inflatePrefix(start: Int, length: Int, decryptor: ZipDecryptor?,
                               want: Int, name: String) throws -> Data {
        var output = Data()
        try inflateStream(start: start, length: length, decryptor: decryptor, name: name,
                          outCapacity: min(max(want, 4096), 256 << 10), stopAfter: want) { buf, n in
            output.append(Data(bytes: buf, count: n))
        }
        guard !output.isEmpty else { throw ZipError.inflateFailed(name) }
        if output.count > want { output = output.prefix(want) }
        return output
    }

    /// 流式解压：每解出一块就回调，回调返回后继续。
    /// 加密条目先在原地解密（HMAC 按密文累计），再喂给 inflater。
    private func inflateStream(start: Int,
                               length: Int,
                               decryptor: ZipDecryptor?,
                               name: String,
                               outCapacity: Int,
                               stopAfter: Int? = nil,
                               onChunk: (UnsafePointer<UInt8>, Int) throws -> Void) throws {
        guard let inflater = gs_inflater_new() else { throw ZipError.inflateFailed(name) }
        defer { gs_inflater_free(inflater) }

        let inChunk = 256 << 10
        var readCursor = start
        let end = start + length
        var outBuffer = [UInt8](repeating: 0, count: outCapacity)
        var produced = 0
        var finished = false

        while readCursor < end, !finished {
            let n = min(inChunk, end - readCursor)
            var chunk = Array(try readBytes(at: readCursor, count: n))
            readCursor += n
            decryptor?.consume(&chunk)

            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var fed = 0
                while fed < n, !finished {
                    var inUsed = 0
                    var outUsed = 0
                    let rc = gs_inflater_push(inflater, base + fed, n - fed, &inUsed,
                                              &outBuffer, outCapacity, &outUsed)
                    fed += inUsed

                    if outUsed > 0 {
                        try outBuffer.withUnsafeBufferPointer { p in
                            try onChunk(p.baseAddress!, outUsed)
                        }
                        produced += outUsed
                    }
                    if rc == 0 { finished = true; break }
                    if rc < 0 { throw ZipError.inflateFailed(name) }
                    if inUsed == 0, outUsed == 0 { break }
                    if let limit = stopAfter, produced >= limit { finished = true; break }
                }
            }
        }

        if !finished, let limit = stopAfter, produced >= limit { finished = true }
        if !finished, length > 0 { throw ZipError.inflateFailed(name) }
    }

    // MARK: - 落盘

    /// 把单个条目写到指定路径；边解边写，内存占用固定。
    func extract(_ entry: ArchiveEntry, to destination: URL, onBytes: ((Int) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ZipError.badEntry(entry.name)
        }

        let info = try payload(entry)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let fd = handle.fileDescriptor

        switch entry.method {
        case 0:
            let chunk = 4 << 20
            var cursor = info.start
            let end = info.start + info.length
            while cursor < end {
                let stop = min(cursor + chunk, end)
                // 每块一个 autorelease 池：FileHandle/Data 的临时对象不能
                // 攒到整个包解完才释放（3 GB 包会直接顶到 jetsam）。
                try autoreleasepool {
                    var data = Array(try readBytes(at: cursor, count: stop - cursor))
                    info.decryptor?.consume(&data)
                    try data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        try Self.writeAll(fd: fd, base, data.count)
                    }
                    onBytes?(data.count)
                }
                cursor = stop
            }
            try info.decryptor?.verifyMAC()
        case 8:
            try inflateStream(start: info.start, length: info.length, decryptor: info.decryptor,
                              name: entry.name, outCapacity: 512 << 10) { buf, n in
                try Self.writeAll(fd: fd, buf, n)
                onBytes?(n)
            }
            try info.decryptor?.verifyMAC()
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    /// 直接写 fd：不产生临时 Data，顺带避开 autorelease 堆积。
    private static func writeAll(fd: Int32, _ buf: UnsafePointer<UInt8>, _ count: Int) throws {
        var off = 0
        while off < count {
            let w = write(fd, buf + off, count - off)
            if w < 0 {
                if errno == EINTR { continue }
                throw ZipError.badEntry("写入失败（errno \(errno)）")
            }
            if w == 0 { throw ZipError.badEntry("写入返回 0") }
            off += w
        }
    }

    /// 把指定条目解到目录下，prefix 会被剥掉。返回写入文件数。
    /// progress 回调：(已写字节, 总字节)，在后台线程调用；内部按 0.4% 节流。
    @discardableResult
    func extract(_ selected: [ArchiveEntry],
                 stripping prefix: String,
                 to directory: URL,
                 progress: ((Int64, Int64) -> Void)? = nil) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let total = selected.reduce(Int64(0)) { $0 + Int64(max($1.uncompressedSize, 0)) }
        var done: Int64 = 0
        var lastReported: Int64 = -1
        let step = max(total / 250, 1)   // 约 0.4% 一次

        func report(force: Bool = false) {
            guard let progress else { return }
            if force || done - lastReported >= step {
                lastReported = done
                progress(done, total)
            }
        }

        report(force: true)

        var written = 0
        var createdDirs = Set<String>()

        for entry in selected where !entry.isDirectory {
            // 一个文件一个 autorelease 池：一万五千个文件如果共用线程池，
            // Foundation 的临时对象会一路堆到导入结束（真机上就是闪退）。
            try autoreleasepool {
                guard let relative = ArchivePath.relative(entry.name, stripping: prefix) else { return }
                if relative.isEmpty { return }
                if relative.contains("..") { return }
                if relative.hasPrefix("__MACOSX") { return }
                if relative.hasSuffix(".DS_Store") { return }

                let destination = directory.appendingPathComponent(relative)
                let parent = destination.deletingLastPathComponent().path
                if !createdDirs.contains(parent) {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    createdDirs.insert(parent)
                }

                try extract(entry, to: destination) { n in
                    done += Int64(n)
                    report()
                }
                written += 1
            }
        }

        report(force: true)
        return written
    }

}

/// 一个加密条目的解密状态机：要么 ZipCrypto、要么 AES-CTR，两者都是等长流。
final class ZipDecryptor {
    private let zipStream: ZipCryptoStream?
    private let aesStream: AESCTRStream?
    private let hmac: SHA1HMAC?
    private let expectedMAC: [UInt8]?

    init(zip: ZipCryptoStream? = nil, aes: AESCTRStream? = nil,
         hmac: SHA1HMAC? = nil, mac: [UInt8]? = nil) {
        self.zipStream = zip
        self.aesStream = aes
        self.hmac = hmac
        self.expectedMAC = mac
    }

    /// 密文原地解密。HMAC 必须喂**密文**，所以顺序不能反。
    func consume(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        hmac?.update(bytes, bytes.count)
        if let zipStream {
            zipStream.decrypt(&bytes, bytes.count)
        } else if let aesStream {
            aesStream.decrypt(&bytes, bytes.count)
        }
    }

    /// 整个载荷读完后校验 AES 的 10 字节 HMAC；ZipCrypto 没有完整性校验，直接过。
    func verifyMAC() throws {
        guard let hmac else { return }
        guard let expectedMAC else { return }
        let digest = hmac.finalize()
        if Array(digest.prefix(expectedMAC.count)) != expectedMAC {
            throw ZipError.wrongPassword
        }
    }
}
