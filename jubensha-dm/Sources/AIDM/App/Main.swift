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
        // --clip 视频或音频 开始时间 [秒数]：截一段声音做克隆样本
        if args.first == "--clip", args.count > 2, let start = AudioClip.parseTime(args[2]) {
            let dur = args.count > 3 ? Double(args[3]) ?? 15 : 15
            CLI.runAsync {
                do { print(try await AudioClip.extract(from: URL(fileURLWithPath: args[1]), start: start, duration: dur).path) }
                catch { print("失败：\(error.localizedDescription)") }
            }
            exit(0)
        }
        // --local-tts <音色> <文字> <输出.wav>：测试本机语音服务（会启动后台服务）
        if args.first == "--local-tts", args.count > 3 {
            CLI.runAsync {
                do {
                    let t = Date()
                    let d = try await LocalTTS.shared.synthesize(args[2], voice: args[1])
                    try d.write(to: URL(fileURLWithPath: args[3]))
                    print("ok \(d.count) bytes in \(Int(Date().timeIntervalSince(t)))s")
                    let t2 = Date()
                    _ = try await LocalTTS.shared.synthesize("第二句话，服务已经在运行了。", voice: args[1])
                    print("second sentence in \(String(format: "%.1f", Date().timeIntervalSince(t2)))s")
                } catch { print("失败：\(error.localizedDescription)") }
                await MainActor.run { LocalTTS.shared.stop() }
            }
            exit(0)
        }
        if args.first == "--check", args.count > 1 {
            exit(CLI.check(URL(fileURLWithPath: args[1]), rewrite: args.contains("--rewrite")))
        }
        AIDMApp.main()
    }
}

enum CLI {
    /// 跑一段异步代码并等它结束；主线程保持转动（AVFoundation 之类需要主线程）
    static func runAsync(_ body: @escaping () async -> Void) {
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        Task.detached { await body(); await MainActor.run { flag.done = true } }
        while !flag.done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

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
