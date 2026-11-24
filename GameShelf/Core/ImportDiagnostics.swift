import Foundation

/// 导入失败时把现场落到 Documents/import-debug.txt，方便真机上没有控制台时也能查原因。
/// 只有 Debug 构建会写，Release 不产生任何文件。
enum ImportDiagnostics {

    /// 留在 Caches 里：不能被"待导入"扫描到（放 Documents 会被当成新包反复重试）
    static var reportURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("GameShelfDiag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("import-debug.txt")
    }

    nonisolated static func record(url: URL, reader: ZipReader, result: Inspection) {
        #if DEBUG
        let names = reader.entries.map { $0.name }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        var lines: [String] = []
        lines.append("file: \(url.lastPathComponent)")
        lines.append("bytes: \(bytes)")
        lines.append("entries: \(names.count)")
        lines.append("engine: \(result.engine.rawValue)  status: \(result.status.rawValue)")
        lines.append("root: '\(result.root)'  entry: '\(result.entryFile)'")
        lines.append("gameEntries: \(result.gameEntries.count)  packEntry: \(result.packEntry.map(String.init) ?? "nil")")

        if let pck = result.packInfo {
            lines.append("pck: v\(pck.packVersion) engine \(pck.versionText) flags 0x\(String(pck.flags, radix: 16))"
                + " encrypted=\(pck.isDirectoryEncrypted) sparse=\(pck.isSparseBundle)")
        } else if let idx = result.packEntry {
            lines.append("pck: \(names[idx]) 头部读不出（可能是 sparse/损坏/非标准）")
        }

        lines.append("notes:")
        for note in result.notes { lines.append("  - \(note)") }

        // 顶层结构
        var tops: Set<String> = []
        for name in names {
            let first = name.split(separator: "/").first.map(String.init) ?? name
            tops.insert(name.contains("/") ? first + "/" : first)
        }
        lines.append("top-level:")
        for t in tops.sorted().prefix(25) { lines.append("  \(t)") }

        // 关键文件
        let keys = [".pck", ".sparsepck", ".html", ".htm", ".so", "export_presets.cfg",
                    "project.godot", ".godot", ".rpyc", ".rgss3a", ".bundle", ".wasm"]
        let interesting = names.filter { n in
            let l = n.lowercased()
            return keys.contains { l.hasSuffix($0) || l.contains($0) }
        }
        lines.append("interesting (\(interesting.count)):")
        for n in interesting.prefix(60) { lines.append("  \(n)") }

        // 扩展名分布
        var histogram: [String: Int] = [:]
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            histogram[ext.isEmpty ? "(none)" : ext, default: 0] += 1
        }
        let top = histogram.sorted { $0.value > $1.value }.prefix(15)
        lines.append("extensions: " + top.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

        let text = lines.joined(separator: "\n") + "\n"
        if let target = reportURL {
            try? text.write(to: target, atomically: true, encoding: .utf8)
        }

        // 小包直接留一份，方便下到电脑上复核
        if bytes > 0, bytes < 200 * 1024 * 1024, let docs = reportURL?.deletingLastPathComponent() {
            let copy = docs.appendingPathComponent("failed-\(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: url, to: copy)
        }
        #endif
    }
}
