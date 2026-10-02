import Foundation

/// 入口：带命令行参数时可以不开界面直接干活，否则启动 Mac 应用。
///   AIDM --ocr 文件.pdf [更多文件] [--split] [--dpi 300] [--vision]
///   AIDM --check 剧本文件夹 [--rewrite]      检查剧本；--rewrite 按标准格式重写 script.yaml
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--ocr" {
            CLI.ocr(Array(args.dropFirst()))
            exit(0)
        }
        if args.first == "--voice-lines", args.count > 1, let s = try? ScriptIO.load(URL(fileURLWithPath: args[1])) {
            let ls = VoicePregen.lines(of: s)
            print("\(ls.count) 句，\(VoicePregen.estimate(ls, VoiceSettings()))")
            ls.prefix(6).forEach { print(" · \($0)") }
            exit(0)
        }
        if args.first == "--check", args.count > 1 {
            exit(CLI.check(URL(fileURLWithPath: args[1]), rewrite: args.contains("--rewrite")))
        }
        AIDMApp.main()
    }
}

enum CLI {
    static func check(_ folder: URL, rewrite: Bool) -> Int32 {
        do {
            let s = try ScriptIO.load(folder)
            print("《\(s.title)》 \(s.characters.count)个角色 · \(s.phases.count)个阶段 · \(s.clues.count)条线索 · 幕：\(s.allActs.joined(separator: "、"))")
            let issues = ScriptIO.validate(s)
            for i in issues { print("[\(i.level.rawValue)] \(i.message)") }
            if issues.isEmpty { print("没有发现问题 ✓") }
            if rewrite { try ScriptIO.save(s, to: s.folder); print("已重写 \(s.folder.appendingPathComponent("script.yaml").path)") }
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }

    static func ocr(_ args: [String]) {
        var opts = OCROptions()
        var files: [URL] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--split": opts.split = true
            case "--vision": opts.engine = .vision
            case "--dpi": i += 1; opts.dpi = CGFloat(Double(args[i]) ?? 220)
            default: files.append(URL(fileURLWithPath: args[i]))
            }
            i += 1
        }
        let sem = DispatchSemaphore(value: 0)
        Task {
            for f in files {
                let total = OCR.pageCount(f)
                print("《\(f.lastPathComponent)》共 \(total) 页")
                do {
                    let llm: LLM? = opts.engine == .vision ? try await MainActor.run { try AppModel().visionLLM() } : nil
                    let out = try await OCR.run(f, options: opts, llm: llm) { p in
                        print("  \(p.done)/\(p.total)  第\(p.page)页 \(p.chars)字" + (p.warning.map { "  ⚠ \($0)" } ?? ""))
                    }
                    print("  完成 → \(out.path)")
                } catch {
                    print("  失败：\(error.localizedDescription)")
                }
            }
            sem.signal()
        }
        sem.wait()
    }
}
