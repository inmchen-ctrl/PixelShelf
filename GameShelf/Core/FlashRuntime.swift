import Foundation

enum FlashRuntimeError: LocalizedError {
    case missingBundle
    case badBundle(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle:
            return "App 内缺少 Ruffle 运行时"
        case .badBundle(let name):
            return "Ruffle 运行时文件损坏：\(name)"
        case .writeFailed(let name):
            return "写入 \(name) 失败"
        }
    }
}

/// 内置的 Ruffle 运行时（WebAssembly 版 Flash Player 兼容层）。
///
/// Ruffle 的 web 自托管包 = ruffle.js + 两份 wasm（常规 / MVP 兜底，启动时按
/// WebAssembly.validate 自动挑）。wasm 文件名带内容哈希，所以这里不做名字过滤，
/// 整包铺开即可，升级 Ruffle 只要换 Resources 里的 zip。
enum FlashRuntime {
    static let resourceName = "ruffle-web"
    static let entryFileName = "index.html"
    /// 壳子 HTML 模板版本：改动生成逻辑时 +1，启动时会为老游戏自动重生成壳子
    static let shellVersion = 2
    private static var versionMarker: String { "/*gsshell:v\(shellVersion)*/" }

    /// 老游戏补装新壳子。返回 true 表示重新生成了。
    @discardableResult
    static func ensureShell(in dir: URL, title: String) throws -> Bool {
        let entry = dir.appendingPathComponent(entryFileName)
        guard let html = try? String(contentsOf: entry, encoding: .utf8) else { return false }
        if html.contains(versionMarker) { return false }

        // 从旧壳子里取 swf 相对路径（可能带老版本的 rpg://game/ 前缀）
        let pattern = #"player\.load\('([^']+)'\);"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return false }
        var swfPath = String(html[range])
        if swfPath.hasPrefix("rpg://game/") {
            swfPath = String(swfPath.dropFirst("rpg://game/".count))
        }
        try install(into: dir, title: title, swfPath: swfPath)
        return true
    }

    static var isAvailable: Bool {
        Bundle.main.url(forResource: resourceName, withExtension: "zip") != nil
    }

    /// 把运行时铺进游戏目录，并生成加载 swfPath 的 index.html
    static func install(into dir: URL, title: String, swfPath: String) throws {
        guard let zipURL = Bundle.main.url(forResource: resourceName, withExtension: "zip") else {
            throw FlashRuntimeError.missingBundle
        }

        let reader = try ZipReader(url: zipURL)
        var foundJS = false
        var foundWasm = false

        for entry in reader.entries where !entry.isDirectory {
            let base = (entry.name as NSString).lastPathComponent
            guard !base.isEmpty, !base.hasSuffix(".map") else { continue }
            guard !base.contains("/") else { continue }

            let data = try reader.read(entry)
            if base == "ruffle.js" { foundJS = true }
            if base.hasSuffix(".wasm") { foundWasm = true }

            do {
                try data.write(to: dir.appendingPathComponent(base), options: .atomic)
            } catch {
                throw FlashRuntimeError.writeFailed(base)
            }
        }

        guard foundJS else { throw FlashRuntimeError.badBundle("ruffle.js") }
        guard foundWasm else { throw FlashRuntimeError.badBundle("ruffle.wasm") }

        let html = shell(title: title, swfPath: swfPath)
        guard let data = html.data(using: .utf8) else {
            throw FlashRuntimeError.badBundle(entryFileName)
        }
        do {
            try data.write(to: dir.appendingPathComponent(entryFileName), options: .atomic)
        } catch {
            throw FlashRuntimeError.writeFailed(entryFileName)
        }

        // 主 SWF 头部里有精确的舞台宽高比，导入时存进 display.json，
        // 画面「铺满 / 对称」直接用它换算，不用进游戏截图量。
        if let aspect = SwfHeader.stageAspect(at: dir.appendingPathComponent(swfPath)) {
            DisplayFit.saveAspect(aspect, folder: dir)
        }
    }

    private static func shell(title: String, swfPath: String) -> String {
        let safeTitle = escapeHTML(title)
        let safeSWF = escapeJS(swfPath)

        return """
        \(versionMarker)
        <!DOCTYPE html>
        <html lang="zh">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
        <title>\(safeTitle)</title>
        <style>
          html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden;
            -webkit-user-select:none;user-select:none;-webkit-touch-callout:none;
            -webkit-tap-highlight-color:transparent}
          #stage{position:fixed;inset:0;display:flex;align-items:center;justify-content:center}
          ruffle-player{display:block;width:100%;height:100%}
          #err{position:fixed;inset:0;padding:18px;color:#ff8a8a;
            font:13px/1.5 -apple-system,ui-monospace,monospace;white-space:pre-wrap;
            overflow:auto;background:#000;display:none}
        </style>
        </head>
        <body>
        <div id="stage"></div>
        <div id="err"></div>
        <script src="ruffle.js"></script>
        <script>
        (function(){
          var stages = window.__gsStages = window.__gsStages || [];
          function mark(t){ try { stages.push(t); if (stages.length > 80) stages.shift(); } catch(e){} }
          function fail(msg){
            mark('fail:' + msg);
            var e = document.getElementById('err');
            e.style.display = 'block';
            e.textContent = 'Ruffle 启动失败\\n\\n' + msg;
          }

          window.RufflePlayer = window.RufflePlayer || {};
          window.RufflePlayer.config = {
            autoplay: 'on',
            unmuteOverlay: 'hidden',
            splashScreen: false,
            preloader: true,
            letterbox: 'on',
            scale: 'showAll',
            quality: 'high',
            wmode: 'opaque',
            menu: false,
            contextMenu: 'off',
            allowFullscreen: false,
            openUrlMode: 'deny',
            allowNetworking: 'internal',
            logLevel: 'warn',
            fontSources: [],
            socketProxy: [],
            polyfills: true,
            warnOnUnsupportedContent: false,
            upgradeToHttps: true,
            maxExecutionDuration: 15,
            preferredRenderer: null,
            playerVersion: null
          };

          window.addEventListener('error', function(e){ mark('onerror:' + (e.message || '')); });
          window.addEventListener('unhandledrejection', function(e){
            mark('reject:' + ((e.reason && e.reason.message) || e.reason));
          });

          function boot(){
            try {
              if (!window.RufflePlayer || typeof window.RufflePlayer.newest !== 'function') {
                return fail('ruffle.js 没跑起来（window.RufflePlayer 缺失）');
              }
              mark('ruffle ' + (window.RufflePlayer.version || '?'));
              var ruffle = window.RufflePlayer.newest();
              var player = ruffle.createPlayer();
              player.id = 'player';
              document.getElementById('stage').appendChild(player);
              // 输入注入的落点：Ruffle 的键盘监听挂在播放器元素上，
              // 往 document 上派发没有用
              window.__gsInputTarget = player;
              player.addEventListener('loadedmetadata', function(){ mark('loadedmetadata'); });
              // 必须给绝对 URL：Ruffle 核心会用 Rust 的 URL 解析器处理影片地址来推导
              // SharedObject 的存档路径，相对路径（或依赖页面 rpg:// base）会直接
              // 报 "relative URL without a base"，SharedObject::get_local 失败 =>
              // 读档永远为空（表现为 Flash 游戏不存档）。非特殊 scheme 带 //host
              // 的 URL，Rust url crate 可以正常解析。
              mark('loading ' + 'rpg://game/\(safeSWF)');
              var p = player.load('rpg://game/\(safeSWF)');
              if (p && typeof p.then === 'function') {
                p.then(function(){ mark('loaded'); })
                 .catch(function(e){ fail('加载 SWF 失败：' + ((e && e.message) || e)); });
              }
            } catch (e) {
              fail((e && (e.stack || e.message)) || String(e));
            }
          }

          mark('boot ' + (typeof window.RufflePlayer));
          if (document.readyState === 'complete') { setTimeout(boot, 0); }
          else { window.addEventListener('load', boot); }

          var n = 0;
          setInterval(function(){
            var p = document.getElementById('player');
            var c = p && p.shadowRoot ? p.shadowRoot.querySelector('canvas') : null;
            mark('t' + (++n) + ' canvas' + (c ? c.width + 'x' + c.height : '-'));
          }, 1500);
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeJS(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}
