// 扫描版 PDF / 图片 → 文字。默认用苹果自带的文字识别（Vision，离线、免费、中文好），
// 版面很乱时可以改用视觉大模型逐页转写。识别过的页会缓存，中途断了重新开始会接着做。
import AppKit
import Foundation
import PDFKit
import Vision
import CryptoKit

enum OCREngine: String, CaseIterable, Identifiable, Codable {
    case apple, vision
    var id: String { rawValue }
    var label: String { self == .apple ? "苹果文字识别（离线，免费）" : "AI 视觉模型（版面复杂时更准）" }
}

struct OCROptions: Equatable {
    var engine: OCREngine = .apple
    var dpi: CGFloat = 220
    var split = false               // 扫描件一页是摊开的左右两页时，切成两半再识别
}

enum OCR {
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff", "heic"]

    static func pageCount(_ url: URL) -> Int {
        if url.hasDirectoryPath {
            return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { imageExts.contains($0.pathExtension.lowercased()) }.count
        }
        if url.pathExtension.lowercased() == "pdf" { return PDFDocument(url: url)?.pageCount ?? 0 }
        return 1
    }

    /// 第 i 页（从 0 开始）渲染成图片
    static func render(_ url: URL, page i: Int, dpi: CGFloat) -> CGImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: i) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let scale = dpi / 72
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            return ctx.makeImage()
        }
        let file: URL
        if url.hasDirectoryPath {
            let files = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { imageExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard files.indices.contains(i) else { return nil }
            file = files[i]
        } else {
            file = url
        }
        return NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func halves(_ img: CGImage) -> [CGImage] {
        let w = img.width / 2
        return [CGRect(x: 0, y: 0, width: w, height: img.height), CGRect(x: w, y: 0, width: img.width - w, height: img.height)]
            .compactMap { img.cropping(to: $0) }
    }

    // MARK: 苹果 Vision

    static func recognize(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = false
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let boxes: [TextBox] = (req.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let r = o.boundingBox      // 归一化，原点在左下
            return TextBox(x0: r.minX * W, x1: r.maxX * W, y0: (1 - r.maxY) * H, y1: (1 - r.minY) * H, text: t)
        }
        return layout(boxes)
    }

    // MARK: 视觉大模型

    static let visionPrompt = "这是一页剧本杀剧本的扫描图。请逐字转写图中所有文字，保持原有的段落和顺序，"
        + "标题单独成行，表格用 | 分隔。看不清的字用□代替。不要总结、不要解释、不要加任何额外内容，只输出转写的文字。"

    static func recognize(_ img: CGImage, with llm: LLM) async throws -> String {
        var cg = img
        let maxSide = 2000
        if max(img.width, img.height) > maxSide {     // 太大的图缩一下，省流量
            let s = CGFloat(maxSide) / CGFloat(max(img.width, img.height))
            let w = Int(CGFloat(img.width) * s), h = Int(CGFloat(img.height) * s)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                cg = ctx.makeImage() ?? img
            }
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw LLMError(message: "图片编码失败")
        }
        return try await llm.vision(jpeg: jpeg, prompt: visionPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 版面整理：把文字框按阅读顺序排好，再把被换行切断的句子接回段落

    struct TextBox {
        var x0, x1, y0, y1: CGFloat
        var text: String
        var yc: CGFloat { (y0 + y1) / 2 }
        var h: CGFloat { y1 - y0 }
    }

    static let endPunct: Set<Swift.Character> = Set("。！？!?…」』”\"：:）)")

    static func layout(_ input: [TextBox]) -> String {
        guard !input.isEmpty else { return "" }
        let boxes = input.sorted { ($0.yc, $0.x0) < ($1.yc, $1.x0) }
        var lines: [[TextBox]] = []
        for b in boxes {
            if let last = lines.last?.last, abs(last.yc - b.yc) < 0.5 * max(b.h, last.h) {
                lines[lines.count - 1].append(b)
            } else {
                lines.append([b])
            }
        }
        struct Row { var t: String; var x0, x1, y0, y1, h: CGFloat }
        let rows: [Row] = lines.map { ln in
            let s = ln.sorted { $0.x0 < $1.x0 }
            return Row(t: s.map(\.text).joined(), x0: s[0].x0, x1: s.last!.x1, y0: s.map(\.y0).min()!, y1: s.map(\.y1).max()!,
                       h: s.map(\.h).reduce(0, +) / CGFloat(s.count))
        }
        let left = rows.map(\.x0).min()!, right = rows.map(\.x1).max()!
        var out: [String] = [], para = ""
        for (i, r) in rows.enumerated() {
            let prev = i > 0 ? rows[i - 1] : nil
            let newPara = para.isEmpty
                || para.last.map { endPunct.contains($0) } == true
                || (prev.map { r.y0 - $0.y1 > 1.0 * r.h } ?? false)       // 行距明显变大
                || r.x0 - left > 1.5 * r.h                                 // 首行缩进
                || (prev.map { $0.x1 < right - 3 * r.h } ?? false)         // 上一行没写满
            if newPara && !para.isEmpty { out.append(para); para = "" }
            para += r.t
        }
        if !para.isEmpty { out.append(para) }
        return out.joined(separator: "\n")
    }

    static func cacheIdentity(_ url: URL, options: OCROptions, llm: LLM?) throws -> String {
        let files: [URL]
        if url.hasDirectoryPath {
            files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { imageExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else { files = [url] }
        var sources: [[String: String]] = []
        for file in files {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            sources.append(["name": file.lastPathComponent, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()])
        }
        var identity: [String: Any] = ["version": 1, "source": sources, "engine": options.engine.rawValue,
                                       "dpi": Double(options.dpi), "split": options.split,
                                       "os": ProcessInfo.processInfo.operatingSystemVersionString]
        if options.engine == .vision, let llm {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            identity["modelConfig"] = String(decoding: try encoder.encode(llm.config), as: UTF8.self)
            identity["prompt"] = visionPrompt
        }
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func cachedPage(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: 整本识别（带缓存）

    struct Progress {
        var done: Int
        var total: Int
        var page: Int
        var chars: Int
        var warning: String?
    }

    /// 返回整本文字（带 === 第N页 === 标记），并写到 Paths.ocr/<名字>-<指纹>.txt，旧结果保留
    static func run(_ url: URL, options: OCROptions, llm: LLM?, concurrency: Int = 4,
                    progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let stem = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let identity = try cacheIdentity(url, options: options, llm: llm)
        let outputName = stem + "-" + identity
        let pageDir = Paths.ocr.appendingPathComponent(outputName, isDirectory: true)
        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        let total = pageCount(url)
        guard total > 0 else { throw LLMError(message: "打不开或没有页面：\(url.lastPathComponent)") }
        if options.engine == .vision && llm == nil { throw LLMError(message: "AI 视觉引擎需要先在设置里配置模型") }

        let suffixes = options.split ? ["a", "b"] : [""]
        func cacheFile(_ i: Int, _ s: String) -> URL { pageDir.appendingPathComponent(String(format: "p%04d%@.txt", i + 1, s)) }

        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func addTask(_ i: Int) {
                group.addTask {
                    try Task.checkCancellation()
                    var chars = 0
                    var failed = false
                    let missing = suffixes.filter { cachedPage(cacheFile(i, $0)) == nil }
                    if !missing.isEmpty {
                        if let img = render(url, page: i, dpi: options.dpi) {
                            let parts = options.split ? halves(img) : [img]
                            for (j, part) in parts.enumerated() where missing.contains(suffixes[j]) {
                                do {
                                    let t = options.engine == .vision ? try await recognize(part, with: llm!) : try recognize(part)
                                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        try t.write(to: cacheFile(i, suffixes[j]), atomically: true, encoding: .utf8)
                                    }
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    failed = true
                                }
                            }
                        } else {
                            failed = true
                        }
                    }
                    for s in suffixes { chars += (try? String(contentsOf: cacheFile(i, s), encoding: .utf8))?.count ?? 0 }
                    let done = await counter.increment()
                    progress(Progress(done: done, total: total, page: i + 1, chars: chars,
                                      warning: failed ? "第\(i + 1)页识别失败（重新开始会重试这一页）"
                                          : chars < 20 ? "第\(i + 1)页几乎没识别出字，检查一下这页" : nil))
                }
            }
            while next < min(concurrency, total) { addTask(next); next += 1 }
            while try await group.next() != nil {
                if next < total { addTask(next); next += 1 }
            }
        }

        var parts: [String] = []
        for i in 0..<total {
            let t = suffixes.compactMap { try? String(contentsOf: cacheFile(i, $0), encoding: .utf8) }.joined(separator: "\n")
            parts.append("=== 第\(i + 1)页 ===\n\(t)")
        }
        let full = Paths.ocr.appendingPathComponent(outputName + ".txt")
        try parts.joined(separator: "\n\n").write(to: full, atomically: true, encoding: .utf8)
        return full
    }
}

actor Counter {
    private var n = 0
    func increment() -> Int { n += 1; return n }
}
