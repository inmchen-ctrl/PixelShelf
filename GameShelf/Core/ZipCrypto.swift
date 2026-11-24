import Foundation
import CommonCrypto

/// 带密码 zip 的两种加密方式的底层实现。
///
/// 都是**流式、等长**的：密文进、明文出，字节一一对应，所以可以直接套在
/// 现有的「读一块 → inflate 一块」管线上，不需要为加密包单独写一套解压器。
///
/// - `ZipCryptoStream`：PKWARE 传统加密，弱，但十几年前的包几乎都是它。
/// - `AESCTRStream` + `ZipAES`：WinZip AE-1/AE-2（method 99），AES-CTR + HMAC-SHA1。

// MARK: - PKWARE 传统加密（ZipCrypto）

/// 密钥流每字节推进一次，核心是 CRC32 表上的三次更新。
final class ZipCryptoStream {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    init(password: String) {
        for b in Array(password.utf8) { update(b) }
    }

    private func update(_ b: UInt8) {
        k0 = Self.table[Int((k0 ^ UInt32(b)) & 0xFF)] ^ (k0 >> 8)
        k1 = (k1 &+ (k0 & 0xFF)) &* 134_775_813 &+ 1
        // key2 吃的是 key1 的**最高字节**，写成最低字节会让整条密钥流错位
        k2 = Self.table[Int((k2 ^ ((k1 >> 24) & 0xFF)) & 0xFF)] ^ (k2 >> 8)
    }

    /// 传统加密的密钥流字节：取 key2 低 16 位、强制置位 bit1，再自乘一次取中间字节。
    private func byte() -> UInt8 {
        let temp = UInt32((k2 | 2) & 0xFFFF)
        return UInt8(((temp &* (temp ^ 1)) >> 8) & 0xFF)
    }

    func decrypt(_ buf: inout [UInt8], _ n: Int) {
        for i in 0..<n {
            let plain = buf[i] ^ byte()
            // 密钥推进必须用**明文**，用密文会让下一条目之后的流全错位
            update(plain)
            buf[i] = plain
        }
    }

    /// 12 字节加密头解出来的第 12 字节是校验位：普通情况取 CRC 高字节，
    /// 置了「数据描述符」标志（bit3）时取时间戳高字节。
    static func checkByte(crc: UInt32, dosTime: UInt16, usesDescriptor: Bool) -> UInt8 {
        usesDescriptor ? UInt8((dosTime >> 8) & 0xFF) : UInt8((crc >> 24) & 0xFF)
    }
}

// MARK: - AES-CTR

/// WinZip 的计数器是「前 4 字节小端、从 1 开始、其余 12 字节为 0」。
/// CommonCrypto 的 CTR 是整块大端自增，语义对不上，所以这里用 ECB 自己拼计数器块。
final class AESCTRStream {
    private var ref: CCCryptorRef?
    private var counter: UInt32 = 1
    private var keystream = [UInt8](repeating: 0, count: 16)
    private var used = 16

    init?(key: [UInt8]) {
        guard key.count == 16 || key.count == 24 || key.count == 32 else { return nil }
        var cryptor: CCCryptorRef?
        let st = key.withUnsafeBytes { kb -> CCCryptorStatus in
            CCCryptorCreate(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                kb.baseAddress, key.count, nil, &cryptor
            )
        }
        guard st == kCCSuccess, let cryptor else { return nil }
        ref = cryptor
    }

    deinit {
        if let ref { CCCryptorRelease(ref) }
    }

    func decrypt(_ buf: inout [UInt8], _ n: Int) {
        var i = 0
        while i < n {
            if used == 16 { refill() }
            let take = min(16 - used, n - i)
            for k in 0..<take { buf[i + k] ^= keystream[used + k] }
            used += take
            i += take
        }
    }

    private func refill() {
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = UInt8(counter & 0xFF)
        block[1] = UInt8((counter >> 8) & 0xFF)
        block[2] = UInt8((counter >> 16) & 0xFF)
        block[3] = UInt8((counter >> 24) & 0xFF)
        counter &+= 1

        var outLen = 0
        block.withUnsafeBufferPointer { p in
            keystream.withUnsafeMutableBufferPointer { o in
                _ = CCCryptorUpdate(ref, p.baseAddress, 16, o.baseAddress, 16, &outLen)
            }
        }
        used = 0
    }
}

// MARK: - WinZip AES 密钥派生与校验

enum ZipAES {
    struct Keys {
        let encKey: [UInt8]
        let authKey: [UInt8]
        let verifier: [UInt8]
    }

    /// PBKDF2-HMAC-SHA1，1000 轮，产出「加密密钥 + 认证密钥 + 2 字节校验值」。
    static func derive(password: String, salt: [UInt8], keyBits: Int) -> Keys? {
        let keyLen = keyBits / 8
        guard keyLen == 16 || keyLen == 24 || keyLen == 32 else { return nil }
        var out = [UInt8](repeating: 0, count: keyLen * 2 + 2)
        let pw = Array(password.utf8)
        let outLen = out.count

        let st = out.withUnsafeMutableBytes { ob -> Int32 in
            pw.withUnsafeBufferPointer { pb -> Int32 in
                salt.withUnsafeBufferPointer { sb -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pb.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                        pw.count,
                        sb.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1000,
                        ob.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        outLen
                    )
                }
            }
        }
        guard st == kCCSuccess else { return nil }
        return Keys(
            encKey: Array(out[0..<keyLen]),
            authKey: Array(out[keyLen..<(keyLen * 2)]),
            verifier: Array(out[(keyLen * 2)..<out.count])
        )
    }
}

/// HMAC-SHA1，用来校验 AES 条目的 10 字节尾部校验值。
final class SHA1HMAC {
    private var ctx = CCHmacContext()

    init(key: [UInt8]) {
        key.withUnsafeBufferPointer { p in
            CCHmacInit(&ctx, CCHmacAlgorithm(kCCHmacAlgSHA1), p.baseAddress, key.count)
        }
    }

    func update(_ buf: [UInt8], _ n: Int) {
        buf.withUnsafeBufferPointer { p in
            CCHmacUpdate(&ctx, p.baseAddress, n)
        }
    }

    func finalize() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 20)
        CCHmacFinal(&ctx, &out)
        return out
    }
}
