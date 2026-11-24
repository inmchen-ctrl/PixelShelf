import Foundation

enum GodotRuntimeError: LocalizedError {
    case missingTemplate
    case badTemplate(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTemplate:
            return "App 内缺少 Godot Web 运行时"
        case .badTemplate(let name):
            return "Godot 运行时文件损坏：\(name)"
        case .writeFailed(let name):
            return "写入 \(name) 失败"
        }
    }
}

/// 内置的 Godot Web 导出运行时（单线程 wasm）。
///
/// 官方 web 导出物 = 引擎（godot.js + godot.wasm + 两个 audio worklet）+ 游戏包（.pck）+ 外壳 html。
/// 同一引擎版本下 wasm 对所有游戏都是同一份，所以这里只存引擎，游戏包在导入时解出来当 index.pck。
enum GodotRuntime {
    static let packFileName = "index.pck"
    static let entryFileName = "index.html"
    /// 壳子 HTML 模板版本：改动生成逻辑或运行时补丁（如持久化配置）时 +1
    static let shellVersion = 12
    private static var versionMarker: String { "/*gsshell:v\(shellVersion)*/" }

    /// 老游戏补装新壳子。返回 true 表示重新生成了。
    @discardableResult
    static func ensureShell(in dir: URL, title: String) throws -> Bool {
        let entry = dir.appendingPathComponent(entryFileName)
        guard let html = try? String(contentsOf: entry, encoding: .utf8) else { return false }
        if html.contains(versionMarker) { return false }

        let packURL = dir.appendingPathComponent(packFileName)
        guard let head = try? Data(contentsOf: packURL).prefix(64),
              let info = PckProbe.parse(head) else { return false }
        let packSize = (try? FileManager.default.attributesOfItem(
            atPath: packURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        try install(into: dir, title: title, packSize: packSize, info: info)
        return true
    }

    /// 内置了哪些引擎版本的 Web 运行时。资源名规则：godot-<major>.<minor>-web.zip
    /// 引擎只接受"同 major 且 minor 不大于自己"的资源包，所以按 major.minor 备一份即可。
    static let bundledVersions: [(major: Int, minor: Int)] = [(4, 5), (4, 6)]

    static func resourceName(major: Int, minor: Int) -> String {
        "godot-\(major).\(minor)-web"
    }

    static func bundleURL(major: Int, minor: Int) -> URL? {
        Bundle.main.url(forResource: resourceName(major: major, minor: minor), withExtension: "zip")
    }

    static func supports(_ info: PckInfo) -> Bool {
        bundleURL(major: info.major, minor: info.minor) != nil
    }

    static var availableVersionText: String {
        bundledVersions
            .filter { bundleURL(major: $0.major, minor: $0.minor) != nil }
            .map { "\($0.major).\($0.minor)" }
            .joined(separator: " / ")
    }

    /// 把运行时铺进游戏目录，并生成指向 index.pck 的 index.html
    static func install(into dir: URL, title: String, packSize: Int64, info: PckInfo) throws {
        guard let zipURL = bundleURL(major: info.major, minor: info.minor) else {
            throw GodotRuntimeError.missingTemplate
        }

        let reader = try ZipReader(url: zipURL)
        var shell: String?
        var wasmBytes: Int64 = 0

        for entry in reader.entries where !entry.isDirectory {
            let base = (entry.name as NSString).lastPathComponent
            guard !base.isEmpty else { continue }

            if base == "godot.html" {
                shell = reader.text(entry)
                continue
            }
            // 只保留引擎本体与 worklet，其它（splash png 等）不需要
            guard base == "godot.js" || base == "godot.wasm"
                || base.hasPrefix("godot.audio.") else { continue }

            let data = try reader.read(entry)
            if base == "godot.wasm" { wasmBytes = Int64(data.count) }
            var payload = data
            if base == "godot.js" {
                // 打开每文件自动持久化：官方模板只在显式 FS.syncfs 时把内存 FS
                // 推到 IndexedDB，而游戏通常只在启动时 pull 一次——不开
                // autoPersist，存档永远停在内存里，退出即丢。autoPersist 会在
                // 文件 close 后自动 queuePersist → syncfs(false) → 推到注入的
                // IndexedDB shim → 落 localStorage。
                if let text = String(data: data, encoding: .utf8) {
                    var patched = text.replacingOccurrences(
                        of: "FS.mount(IDBFS,{},",
                        with: "FS.mount(IDBFS,{autoPersist:true},")
                    // 诊断探针：queuePersist / syncfs 的调用计数与错误收集
                    patched = patched.replacingOccurrences(
                        of: "queuePersist:mount=>{",
                        with: "queuePersist:mount=>{try{if(window.__gsIDBStats)window.__gsIDBStats.q=(window.__gsIDBStats.q||0)+1}catch(e){};")
                    patched = patched.replacingOccurrences(
                        of: "syncfs:(mount,populate,callback)=>{",
                        with: "syncfs:(mount,populate,callback)=>{try{if(window.__gsIDBStats){var S=window.__gsIDBStats;S.sync=(S.sync||0)+1;var oc=callback;callback=function(err){if(err){S.syncerr=String((err&&err.message)||err)}return oc(err)}}}catch(e){};")
                    // 暴露 FS：dumpSaves 退出前手动 syncfs(false) 推盘，dump 里枚举文件树。
                    // 同时挂 FS.open / writeFile / write 拦截：Godot 引擎读写文件都必经
                    // open，写文件必经过 writeFile/write；记录每个路径+读写模式+内容长度，
                    // 用于定位"游戏写档到哪、读档从哪读"（此前只拦 readFile 而 Godot
                    // 引擎不走 readFile，导致永远看不到真实读写）。
                    patched = patched.replacingOccurrences(
                        of: "init:function(persistentPaths){",
                        with: "init:function(persistentPaths){try{window.__gsFS=FS}catch(e){};try{if(!window.__gsOpenLog){window.__gsOpenLog=[];var _gsopen=FS.open;FS.open=function(path,flags,mode){try{var L=window.__gsOpenLog;if(L.length<500){var fl='';try{fl=(flags===undefined?'':(flags&64?'W':'')+(flags&1?'R':'')+(flags&2?'R+':''));}catch(e){}if(!fl)fl=String(flags);L.push(fl+' '+path);}}catch(e){}return _gsopen.apply(FS,arguments);}}}catch(e){};try{if(!window.__gsWriteLog){window.__gsWriteLog=[];var _gswf=FS.writeFile;FS.writeFile=function(path,data,opts){try{var L=window.__gsWriteLog;if(L.length<200){var n=-1;try{n=(data&&data.length)!==undefined?data.length:(data&&data.byteLength!==undefined?data.byteLength:-1);}catch(e){}L.push(path+'#'+n);}}catch(e){}return _gswf.apply(FS,arguments);}}}catch(e){};")
                    // 挂载 + populate 完成后置 ready 标志：容器级直写的读回脚本据此
                    // 等挂载点就绪后才往 /userfs 写文件，避免写进未挂载的 MEMFS 被覆盖。
                    patched = patched.replacingOccurrences(
                        of: "GodotFS._idbfs=true}resolve(err)",
                        with: "GodotFS._idbfs=true}try{window.__gsFSReady=true}catch(e){}resolve(err)")
                    if patched != text, let patchedData = patched.data(using: .utf8) {
                        payload = patchedData
                    }
                }
            }
            let destination = dir.appendingPathComponent(base)
            do {
                try payload.write(to: destination, options: .atomic)
            } catch {
                throw GodotRuntimeError.writeFailed(base)
            }
        }

        guard var html = shell else { throw GodotRuntimeError.badTemplate("godot.html") }
        html = versionMarker + "\n" + html

        let config: [String: Any] = [
            "args": [],
            "canvasResizePolicy": 2,
            "executable": "godot",
            "mainPack": packFileName,
            "experimentalVK": false,
            "focusCanvas": true,
            "serviceWorker": false,
            "ensureCrossOriginIsolationHeaders": false,
            // 挂载持久化路径：Godot 4.5+ 的 user:// 在 /userfs/<org>/<项目>/，
            // 老版本在 /home/web_user/.local/share/godot/app_userdata/。
            // 部分游戏还会往根下 /save 写配置，一并挂上。
            // IndexedDB 由注入的 shim 提供（localStorage 后端，随退出快照落盘），
            // 见 GameWebView.bootstrapScript。
            // 完整持久化挂载：Godot 4.5+ 的 user:// 在 /userfs/<org>/<项目>/，
            // 部分游戏还会往根下 /save 写配置，老版本在 /home/web_user/... 一并挂上。
            "persistentPaths": ["/userfs", "/save", "/home/web_user/.local/share/godot/app_userdata"],
            "gdextensionLibs": [],
            "fileSizes": ["index.pck": packSize, "godot.wasm": wasmBytes]
        ]
        let configJSON = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let splash = "data:image/gif;base64,R0lGODlhAQABAAAAACw="
        let replacements: [String: String] = [
            "$GODOT_PROJECT_NAME": escapeHTML(title),
            "$GODOT_SPLASH_COLOR": "#000000",
            "$GODOT_SPLASH_CLASSES": "show-image--false",
            "$GODOT_SPLASH": splash,
            "$GODOT_HEAD_INCLUDE": "",
            "$GODOT_URL": "godot.js",
            "$GODOT_CONFIG": configJSON,
            "$GODOT_THREADS_ENABLED": "false"
        ]
        for (key, value) in replacements {
            html = html.replacingOccurrences(of: key, with: value)
        }

        // 在 godot.js 之后、模板内联脚本之前插桩：把启动阶段记进 window.__gsStages，
        // 卡住时可以直接看出停在 init / preload / callMain 哪一步。
        let anchor = "<script src=\"godot.js\"></script>"
        if html.contains(anchor) {
            html = html.replacingOccurrences(of: anchor, with: anchor + "\n<script>\n\(instrumentScript)\n</script>")
        }

        guard let data = html.data(using: .utf8) else {
            throw GodotRuntimeError.badTemplate("index.html")
        }
        do {
            try data.write(to: dir.appendingPathComponent(entryFileName), options: .atomic)
        } catch {
            throw GodotRuntimeError.writeFailed(entryFileName)
        }
    }

    private static let instrumentScript = """
    (function(){
      var S = window.__gsStages = window.__gsStages || [];
      function mark(t){ try { S.push(t); if (S.length > 60) { S.shift(); } } catch(e){} }
      mark('boot ' + (typeof Engine));
      var log = window.__gsConsole = window.__gsConsole || [];
      ['log','warn','error'].forEach(function(k){
        var orig = console[k];
        console[k] = function(){
          try {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              var a = arguments[i];
              parts.push(typeof a === 'string' ? a : (a && a.message) || String(a));
            }
            log.push(k + ': ' + parts.join(' ').slice(0, 300));
            if (log.length > 40) { log.shift(); }
          } catch(e){}
          return orig.apply(console, arguments);
        };
      });
      try {
        var P = window.Engine && Engine.prototype;
        if (P) {
          ['init','start','startGame','preloadFile','copyToFS','requestQuit'].forEach(function(n){
            var f = P[n];
            if (typeof f !== 'function') { mark('miss:' + n); return; }
            P[n] = function(){
              mark('in:' + n);
              try {
                var r = f.apply(this, arguments);
                if (r && typeof r.then === 'function') {
                  r.then(function(){ mark('ok:' + n); },
                         function(e){ mark('err:' + n + ' ' + ((e && e.message) || e)); });
                } else { mark('sync:' + n); }
                return r;
              } catch(e) {
                mark('throw:' + n + ' ' + ((e && e.message) || e));
                throw e;
              }
            };
          });
        } else { mark('no-engine'); }
      } catch(e) { mark('patchfail:' + e.message); }

      var frames = 0, n = 0;
      (function tick(){ frames++; requestAnimationFrame(tick); })();
      setInterval(function(){
        var c = document.getElementById('canvas');
        mark('t' + (++n) + ' f' + frames + ' c' + (c ? c.width + 'x' + c.height : '-'));
      }, 1000);
      window.addEventListener('error', function(e){ mark('onerror:' + (e.message || '')); });
      window.addEventListener('unhandledrejection', function(e){
        mark('reject:' + ((e.reason && e.reason.message) || e.reason));
      });
    })();
    """

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
