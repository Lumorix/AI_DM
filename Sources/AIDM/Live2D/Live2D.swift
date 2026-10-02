// DM 形象：用户导入的 Live2D 模型（Cubism 3/4/5，.model3.json），显示在大屏上，跟着 DM 说话动嘴。
// 渲染用 PixiJS + pixi-live2d-display（MIT，随应用打包）跑在 WKWebView 里；
// Live2D 官方的 Cubism Core 运行库第一次用到时从 Live2D 官网下载并缓存。
import AppKit
import Combine
import ImageIO
import SwiftUI
import WebKit

struct AvatarSettings: Codable, Equatable {
    var enabled = true
    var model = ""                  // Live2D/Models 下的文件夹名
    var scale = 1.0
    var offsetX = 0.0               // 相对画面宽度，-0.5…0.5
    var offsetY = 0.0               // 相对画面高度
    var mirror = false
    var side: Side = .left

    enum Side: String, Codable { case left, right }

    var js: String {
        "{scale:\(scale),x:\(offsetX),y:\(offsetY),mirror:\(mirror),side:'\(side.rawValue)'}"
    }
}

enum AvatarEvent {
    case talking(Bool)
    case pulse
    case motion
    case mood(String)            // happy / sad / think / neutral
    case expression(String)      // 直接按名字做表情
    case level(Float)            // 真实音量（云端音色播放时），0…1
}

struct Live2DModelInfo: Identifiable, Equatable {
    let name: String                // 文件夹名
    let modelPath: String           // 相对文件夹的 .model3.json 路径
    let thumbnail: URL?
    let expressions: [String]       // 文件夹里的 .exp3.json（相对 .model3.json 所在目录）
    var id: String { name }
}

enum Live2D {
    static let coreURL = URL(string: "https://cubism.live2d.com/sdk-web/cubismcore/live2dcubismcore.min.js")!

    static var root: URL {
        let u = Paths.support.appendingPathComponent("Live2D", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var modelsDir: URL {
        let u = root.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var coreFile: URL { root.appendingPathComponent("live2dcubismcore.min.js") }
    static var hasCore: Bool { FileManager.default.fileExists(atPath: coreFile.path) }

    /// 下载 Live2D Cubism Core（官方运行库，只下载一次）
    static func ensureCore() async throws {
        if hasCore { return }
        var req = URLRequest(url: coreURL, timeoutInterval: 30)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              String(decoding: data.prefix(2000), as: UTF8.self).contains("Live2DCubismCore") else {
            throw LLMError(message: "下载 Live2D 运行库失败")
        }
        try data.write(to: coreFile, options: .atomic)
    }

    // MARK: 模型库

    static func models() -> [Live2DModelInfo] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { dir in
                guard let m = findModelFile(in: dir) else { return nil }
                let rel = String(m.path.dropFirst(dir.path.count + 1))
                return Live2DModelInfo(name: dir.lastPathComponent, modelPath: rel, thumbnail: firstTexture(m),
                                       expressions: expressionFiles(near: m))
            }
    }

    static func findModelFile(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var found: [URL] = []
        for case let u as URL in e where u.lastPathComponent.hasSuffix(".model3.json") { found.append(u) }
        return found.min { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// VTube Studio 导出的模型常把表情放在文件夹里却不写进 model3.json，这里找出来
    static func expressionFiles(near modelFile: URL) -> [String] {
        let dir = modelFile.deletingLastPathComponent()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let u as URL in e where u.lastPathComponent.hasSuffix(".exp3.json") {
            out.append(String(u.path.dropFirst(dir.path.count + 1)))
        }
        return out.sorted()
    }

    /// 贴图太大（8K）就缩到 4096：大屏上看不出区别，加载快很多、显存省四分之三。UV 是归一化的，等比缩放不影响模型。
    static func shrinkTextures(in modelFile: URL, max: Int = 4096) {
        guard let d = try? Data(contentsOf: modelFile),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let refs = j["FileReferences"] as? [String: Any], let texs = refs["Textures"] as? [String] else { return }
        for t in texs {
            let u = modelFile.deletingLastPathComponent().appendingPathComponent(t)
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  Swift.max(w, h) > max else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p.arguments = ["-Z", "\(max)", u.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    private static func firstTexture(_ modelFile: URL) -> URL? {
        guard let d = try? Data(contentsOf: modelFile),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let refs = j["FileReferences"] as? [String: Any], let tex = (refs["Textures"] as? [String])?.first else { return nil }
        return modelFile.deletingLastPathComponent().appendingPathComponent(tex)
    }

    /// 导入：可以选模型文件夹、.model3.json 文件，或 .zip 压缩包
    static func importModel(from src: URL) throws -> String {
        let fm = FileManager.default
        var source = src
        var temp: URL?
        defer { if let temp { try? fm.removeItem(at: temp) } }
        if src.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("live2d-\(UUID().uuidString)")
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", src.path, t.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw LLMError(message: "解压失败：\(src.lastPathComponent)") }
            temp = t
            source = t
        } else if src.lastPathComponent.hasSuffix(".model3.json") {
            source = src.deletingLastPathComponent()
        } else if src.lastPathComponent.hasSuffix(".model.json") {
            throw LLMError(message: "这是 Cubism 2 的老模型（.model.json），暂不支持。请使用 Cubism 3 及以上版本导出的模型（.model3.json）。")
        }
        guard let modelFile = findModelFile(in: source) else {
            if let e = fm.enumerator(at: source, includingPropertiesForKeys: nil),
               e.contains(where: { ($0 as? URL)?.lastPathComponent.hasSuffix(".model.json") == true }) {
                throw LLMError(message: "这是 Cubism 2 的老模型（.model.json），暂不支持。请使用 Cubism 3 及以上版本导出的模型（.model3.json）。")
            }
            throw LLMError(message: "没有找到 .model3.json 文件。请选择 Live2D 模型所在的文件夹。")
        }
        // 复制 .model3.json 所在的整个文件夹
        let modelDir = modelFile.deletingLastPathComponent()
        var name = modelFile.lastPathComponent.replacingOccurrences(of: ".model3.json", with: "")
        if name.isEmpty || name == "model" { name = modelDir.lastPathComponent }
        var dst = modelsDir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dst.path) { dst = modelsDir.appendingPathComponent("\(name) \(n)"); n += 1 }
        try fm.copyItem(at: modelDir, to: dst)
        if let copied = findModelFile(in: dst) { shrinkTextures(in: copied) }
        return dst.lastPathComponent
    }

    static func delete(_ name: String) {
        try? FileManager.default.trashItem(at: modelsDir.appendingPathComponent(name), resultingItemURL: nil)
    }
}

func debugLog(_ s: String) {
    guard ProcessInfo.processInfo.environment["AIDM_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - 给 WebView 提供文件：aidm://local/app/…（打包的网页） /model/…（模型） /core/…（运行库）

final class Live2DSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let parts = url.path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let rel = parts[1].removingPercentEncoding else { return fail(task, url) }
        let base: URL
        switch parts[0] {
        case "app": base = Paths.resources.appendingPathComponent("live2d")
        case "model": base = Live2D.modelsDir
        case "core": base = Live2D.root
        default: return fail(task, url)
        }
        let f = base.appendingPathComponent(rel).standardizedFileURL
        debugLog("[live2d] GET \(url.path) -> \(FileManager.default.fileExists(atPath: f.path))")
        guard f.path.hasPrefix(base.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: f) else {
            return fail(task, url)
        }
        let type: String = switch f.pathExtension.lowercased() {
        case "html": "text/html"
        case "js": "application/javascript"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type, "Content-Length": "\(data.count)",
                                                  "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, _ url: URL) {
        task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
        task.didFinish()
    }
}

// MARK: - SwiftUI 视图

enum Live2DStatus: Equatable {
    case idle, downloadingCore, loading, ready(expressions: [String]), failed(String)
}

struct Live2DView: NSViewRepresentable {
    let model: Live2DModelInfo?
    let config: AvatarSettings
    let events: PassthroughSubject<AvatarEvent, Never>
    var onStatus: (Live2DStatus) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(Live2DSchemeHandler(), forURLScheme: "aidm")
        conf.userContentController.add(WeakHandler(c), name: "dm")
        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        // 大屏窗口被别的窗口挡住一部分时也要继续动（WebKit 默认会暂停被遮挡窗口里的动画）
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if wv.responds(to: sel) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(wv.method(for: sel), to: Setter.self)(wv, sel, false)
        }
        wv.underPageBackgroundColor = .clear
        c.webView = wv
        c.onStatus = onStatus
        c.sub = events.receive(on: DispatchQueue.main).sink { [weak c] e in c?.handle(e) }
        c.start()
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        c.onStatus = onStatus
        c.apply(model: model, config: config)
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "dm")
        coordinator.sub = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onStatus: (Live2DStatus) -> Void = { _ in }
        var sub: AnyCancellable?
        private var pageReady = false
        private var loadedModel: String?
        private var wantedModel: Live2DModelInfo?
        private var config = AvatarSettings()

        func start() {
            Task {
                if !Live2D.hasCore {
                    onStatus(.downloadingCore)
                    do { try await Live2D.ensureCore() } catch {
                        onStatus(.failed("需要联网下载一次 Live2D 运行库（Cubism Core），现在下载不了：\(error.localizedDescription)"))
                        return
                    }
                }
                if ProcessInfo.processInfo.environment["AIDM_DEBUG"] != nil { debugLog("[live2d] loading page") }
                webView?.load(URLRequest(url: URL(string: "aidm://local/app/stage.html")!))
            }
        }

        func apply(model: Live2DModelInfo?, config: AvatarSettings) {
            wantedModel = model
            if config != self.config {
                self.config = config
                js("DM.configure(\(config.js))")
            }
            let key = model.map { "\($0.name)/\($0.modelPath)" }
            guard pageReady, key != loadedModel else { return }
            loadedModel = key
            if let model {
                let path = "\(model.name)/\(model.modelPath)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                let exprs = (try? JSONSerialization.data(withJSONObject: model.expressions)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                js("DM.configure(\(config.js)); DM.load('aidm://local/model/\(path)', \(exprs))")
            } else {
                js("DM.load(null)")
                onStatus(.idle)
            }
        }

        func handle(_ e: AvatarEvent) {
            switch e {
            case .talking(let b): js("DM.talking(\(b))")
            case .pulse: js("DM.pulse()")
            case .motion: js("DM.motion()")
            case .mood(let m): js("DM.mood('\(m)')")
            case .level(let v): js("DM.level(\(v))")
            case .expression(let n):
                let q = (try? JSONSerialization.data(withJSONObject: [n])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                js("DM.expression(\(q)[0])")
            }
        }

        private func js(_ s: String) {
            guard pageReady else { return }
            webView?.evaluateJavaScript(s + "; 0") { _, err in
                if let err, ProcessInfo.processInfo.environment["AIDM_DEBUG"] != nil { debugLog("[live2d] js error: \(s.prefix(80)) \(err)") }
            }
        }

        nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            if ProcessInfo.processInfo.environment["AIDM_DEBUG"] != nil { debugLog("[live2d] \(message.body)") }
            MainActor.assumeIsolated {
                switch body["type"] as? String {
                case "ready":
                    pageReady = true
                    loadedModel = nil
                    apply(model: wantedModel, config: config)
                    js("DM.configure(\(config.js))")
                case "loading": onStatus(.loading)
                case "loaded": onStatus(.ready(expressions: body["expressions"] as? [String] ?? []))
                case "error": onStatus(.failed(body["message"] as? String ?? "未知错误"))
                default: break
                }
            }
        }
    }
}

/// 避免 WKUserContentController 强引用造成循环
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(uc, didReceive: message)
    }
}
