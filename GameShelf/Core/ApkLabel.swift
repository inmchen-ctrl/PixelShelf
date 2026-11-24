import Foundation

/// 从 APK 里读「应用名」（桌面图标下面那个名字）。
///
/// 走的是 Android 自己的两种二进制格式：
/// - `AndroidManifest.xml` 是 AXML（chunk 化的二进制 XML），`<application android:label>` 就是名字；
/// - label 常写成 `@string/app_name` 这种资源引用，得再去 `resources.arsc` 的资源表里查字符串。
///
/// 解析不了就返回 nil，调用方退回文件名 —— 名字取不到不该让导入失败，
/// 所以这里所有读取都是「越界即放弃」，不做任何断言。
enum ApkLabel {

    // MARK: - 对外入口

    /// 从已经打开的 APK 里取应用名
    static func read(from reader: any ArchiveReader) -> String? {
        guard let manifestEntry = reader.entries.first(where: {
            $0.name == "AndroidManifest.xml" || $0.name.hasSuffix("/AndroidManifest.xml")
        }), let manifest = try? reader.read(manifestEntry) else { return nil }

        // 少数工具打出来的 APK 里 manifest 是纯文本，直接正则更快
        if isText(manifest) {
            return fromTextManifest(manifest)
        }

        let value = manifestLabel(manifest)
        switch value {
        case .none:
            return nil
        case .text(let text):
            return clean(text)
        case .reference(let resID):
            guard let arscEntry = reader.entries.first(where: {
                $0.name == "resources.arsc" || $0.name.hasSuffix("/resources.arsc")
            }), let arsc = try? reader.read(arscEntry) else { return nil }
            return clean(resolve(resID, in: arsc))
        }
    }

    /// 解析逻辑本体，独立出来方便单独校验（不依赖 zip）
    static func label(manifest: Data, arsc: @autoclosure () -> Data?) -> String? {
        if isText(manifest) { return fromTextManifest(manifest) }
        switch manifestLabel(manifest) {
        case .none: return nil
        case .text(let text): return clean(text)
        case .reference(let id): return clean(arsc().flatMap { resolve(id, in: $0) })
        }
    }

    // MARK: - Manifest

    private enum LabelValue {
        case text(String)
        case reference(UInt32)
    }

    private static func isText(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first == 0x3C // '<'
    }

    /// 纯文本 manifest：只认 <application ... android:label="...">
    private static func fromTextManifest(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"<application[^>]*?android:label\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[range])
        // 文本 manifest 里也可能写 @string/app_name，此时无从解析，直接放弃
        return raw.hasPrefix("@") ? nil : raw
    }

    private static func manifestLabel(_ data: Data) -> LabelValue? {
        let bytes = [UInt8](data)
        guard bytes.count > 8, u16(bytes, 0) == 0x0003 else { return nil }

        var strings: [String] = []
        var cursor = Int(u16(bytes, 2))
        let end = min(bytes.count, Int(u32(bytes, 4)))

        while cursor + 8 <= end {
            let type = u16(bytes, cursor)
            let size = Int(u32(bytes, cursor + 4))
            guard size >= 8, cursor + size <= end else { break }

            switch type {
            case 0x0001: // 字符串池
                strings = stringPool(bytes, at: cursor)

            case 0x0102: // START_ELEMENT
                let nameIndex = Int(u32(bytes, cursor + 20))
                let element = strings.indices.contains(nameIndex) ? strings[nameIndex] : ""
                guard element == "application" else { break }

                let attrStart = Int(u16(bytes, cursor + 24))
                let attrSize = max(Int(u16(bytes, cursor + 26)), 20)
                let attrCount = Int(u16(bytes, cursor + 28))
                var p = cursor + 16 + attrStart
                for _ in 0..<attrCount {
                    guard p + 20 <= cursor + size else { break }
                    let nameIdx = Int(u32(bytes, p + 4))
                    let rawIdx = u32(bytes, p + 8)
                    let dataType = bytes[p + 15]
                    let dataValue = u32(bytes, p + 16)
                    let attrName = strings.indices.contains(nameIdx) ? strings[nameIdx] : ""

                    if attrName == "label" {
                        if dataType == 0x03 { // 直接是字符串
                            let idx = Int(dataValue)
                            if strings.indices.contains(idx), !strings[idx].isEmpty {
                                return .text(strings[idx])
                            }
                        } else if dataType == 0x01 { // @string/xxx
                            return .reference(dataValue)
                        } else if rawIdx != 0xFFFF_FFFF,
                                  strings.indices.contains(Int(rawIdx)),
                                  !strings[Int(rawIdx)].isEmpty {
                            return .text(strings[Int(rawIdx)])
                        }
                    }
                    p += attrSize
                }
                return nil

            case 0x0103: // END_ELEMENT：application 已结束还没拿到 label
                break

            default:
                break
            }

            cursor += size
            if type == 0x0102 && cursor >= end { break }
        }
        return nil
    }

    // MARK: - 资源表

    /// 把一个 0x7fxxxxxx 的资源 id 解析成字符串
    private static func resolve(_ resID: UInt32, in data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, u16(bytes, 0) == 0x0002 else { return nil }

        let targetPackage = UInt8((resID >> 24) & 0xFF)
        let targetType = UInt8((resID >> 16) & 0xFF)
        let targetEntry = Int(resID & 0xFFFF)

        var globalStrings: [String] = []
        var cursor = Int(u16(bytes, 2))
        let end = min(bytes.count, Int(u32(bytes, 4)))

        while cursor + 8 <= end {
            let type = u16(bytes, cursor)
            let headerSize = Int(u16(bytes, cursor + 2))
            let size = Int(u32(bytes, cursor + 4))
            guard size >= 8, cursor + size <= end else { break }

            if type == 0x0001, globalStrings.isEmpty {
                globalStrings = stringPool(bytes, at: cursor)
            } else if type == 0x0200 {
                let pkgID = UInt8((u32(bytes, cursor + 8)) & 0xFF)
                if pkgID == targetPackage || targetPackage == 0 {
                    if let hit = findString(
                        bytes, packageStart: cursor, packageEnd: cursor + size,
                        headerSize: headerSize, type: targetType, entry: targetEntry,
                        strings: globalStrings
                    ) {
                        return hit
                    }
                }
            }
            cursor += size
        }
        return nil
    }

    private static func findString(
        _ bytes: [UInt8],
        packageStart: Int, packageEnd: Int, headerSize: Int,
        type targetType: UInt8, entry targetEntry: Int,
        strings: [String]
    ) -> String? {
        var cursor = packageStart + headerSize
        var fallback: String?

        while cursor + 8 <= packageEnd {
            let type = u16(bytes, cursor)
            let size = Int(u32(bytes, cursor + 4))
            guard size >= 8, cursor + size <= packageEnd else { break }

            if type == 0x0201 {
                let typeID = bytes[cursor + 8]
                if typeID == targetType {
                    let value = entryValue(bytes, typeChunk: cursor, size: size,
                                           entry: targetEntry, strings: strings)
                    if let value {
                        // 默认配置（无语言/密度限定）优先；拿不到就用第一个能解析出来的
                        if isDefaultConfig(bytes, typeChunk: cursor) { return value }
                        if fallback == nil { fallback = value }
                    }
                }
            }
            cursor += size
        }
        return fallback
    }

    private static func isDefaultConfig(_ bytes: [UInt8], typeChunk: Int) -> Bool {
        let configStart = typeChunk + 20
        guard configStart + 16 <= bytes.count else { return true }
        let language = bytes[configStart + 8], language2 = bytes[configStart + 9]
        let country = bytes[configStart + 10], country2 = bytes[configStart + 11]
        let density = u16(bytes, configStart + 14)
        return language == 0 && language2 == 0 && country == 0 && country2 == 0 && density == 0
    }

    /// 读某张 type 表里第 n 个条目的值，只处理能拿到字符串的情况
    private static func entryValue(
        _ bytes: [UInt8], typeChunk: Int, size: Int,
        entry: Int, strings: [String]
    ) -> String? {
        let flags = bytes[typeChunk + 9]
        let entryCount = Int(u32(bytes, typeChunk + 12))
        let entriesStart = Int(u32(bytes, typeChunk + 16))
        let headerSize = Int(u16(bytes, typeChunk + 2))
        guard entry >= 0, entry < entryCount else { return nil }

        var offset = -1
        if flags & 0x01 != 0 {
            // 稀疏编码：每条 4 字节（idx u16 + offset/4 u16）
            var p = typeChunk + headerSize
            let limit = typeChunk + size
            while p + 4 <= limit {
                let idx = Int(u16(bytes, p))
                if idx == entry {
                    offset = Int(u16(bytes, p + 2)) * 4
                    break
                }
                if idx > entry { break }
                p += 4
            }
        } else {
            let p = typeChunk + headerSize + entry * 4
            guard p + 4 <= typeChunk + size else { return nil }
            let raw = u32(bytes, p)
            if raw != 0xFFFF_FFFF { offset = Int(raw) }
        }
        guard offset >= 0 else { return nil }

        let entryStart = typeChunk + entriesStart + offset
        guard entryStart + 8 <= typeChunk + size else { return nil }

        // AAPT2 的 compact 条目：4 字节里塞了 dataType 和 data
        if u16(bytes, entryStart + 2) & 0x0008 != 0 {
            let packed = u32(bytes, entryStart)
            let dataType = UInt8((packed >> 24) & 0xFF)
            let data = packed & 0x00FF_FFFF
            guard dataType == 0x03 else { return nil }
            let idx = Int(data)
            return strings.indices.contains(idx) ? strings[idx] : nil
        }

        let entryFlags = u16(bytes, entryStart + 2)
        guard entryFlags & 0x0001 == 0 else { return nil } // 复杂条目（bag），不是字符串
        let valueStart = entryStart + 8
        guard valueStart + 8 <= typeChunk + size else { return nil }
        let dataType = bytes[valueStart + 3]
        let data = u32(bytes, valueStart + 4)
        guard dataType == 0x03 else { return nil }
        let idx = Int(data)
        return strings.indices.contains(idx) ? strings[idx] : nil
    }

    // MARK: - 字符串池

    private static func stringPool(_ bytes: [UInt8], at start: Int) -> [String] {
        guard start + 28 <= bytes.count else { return [] }
        let headerSize = Int(u16(bytes, start + 2))
        let count = Int(u32(bytes, start + 8))
        let flags = u32(bytes, start + 16)
        let stringsStart = Int(u32(bytes, start + 20))
        guard count > 0, count < 200_000 else { return [] }
        let offsets = start + headerSize
        guard offsets + count * 4 <= bytes.count else { return [] }

        let utf8 = flags & 0x1 != 0
        let base = start + stringsStart
        var out: [String] = []
        out.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(u32(bytes, offsets + i * 4))
            let p = base + offset
            guard p >= 0, p < bytes.count else { out.append(""); continue }
            out.append(utf8 ? utf8String(bytes, at: p) : utf16String(bytes, at: p))
        }
        return out
    }

    private static func utf8String(_ bytes: [UInt8], at p: Int) -> String {
        var i = p
        guard i < bytes.count else { return "" }
        var length = Int(bytes[i])
        i += 1
        if length & 0x80 != 0 {
            guard i < bytes.count else { return "" }
            length = ((length & 0x7F) << 8) | Int(bytes[i])
            i += 1
        }
        guard length >= 0, i + length <= bytes.count else { return "" }
        return String(decoding: bytes[i..<(i + length)], as: UTF8.self)
    }

    private static func utf16String(_ bytes: [UInt8], at p: Int) -> String {
        var i = p
        guard i + 2 <= bytes.count else { return "" }
        var length = Int(u16(bytes, i))
        i += 2
        if length & 0x8000 != 0 {
            guard i + 2 <= bytes.count else { return "" }
            length = ((length & 0x7FFF) << 16) | Int(u16(bytes, i))
            i += 2
        }
        guard length >= 0, i + length * 2 <= bytes.count else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for k in 0..<length { units.append(u16(bytes, i + k * 2)) }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - 工具

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= b.count else { return 0 }
        return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return UInt32(b[o])
            | (UInt32(b[o + 1]) << 8)
            | (UInt32(b[o + 2]) << 16)
            | (UInt32(b[o + 3]) << 24)
    }

    /// 去掉换行、控制字符和首尾空白；太长的（多半是错误文案）不要
    private static func clean(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        text = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 60 else { return nil }
        guard !text.hasPrefix("@"), !text.hasPrefix("res/") else { return nil }
        // 少数包把 label 直接写成包名（com.xxx.yyy），对用户没意义，当没有
        if text.contains("."), !text.contains(" ") {
            let parts = text.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }) {
                return nil
            }
        }
        return text
    }
}
