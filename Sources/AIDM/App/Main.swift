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
        // --pregen 剧本.yaml [本机音色]：把剧本里 DM 的每句台词都提前用本机音色合成好（存进语音缓存，游戏时直接播放）
        if args.first == "--pregen", args.count > 1, let s = try? ScriptIO.load(URL(fileURLWithPath: args[1])) {
            var cfg = VoiceSettings()
            cfg.engine = .local
            cfg.localVoice = args.count > 2 ? args[2] : "yachiyo/综合"
            let ls = VoicePregen.lines(of: s)
            let todo = ls.filter { !VoiceCache.has($0, cfg) }.count
            print("\(ls.count) 句，还要合成 \(todo) 句（音色：\(cfg.localVoice)）")
            let ok = CLIResult()
            let start = Date()
            CLI.runAsync {
                await VoicePregen.run(ls, cfg: cfg, key: "", concurrency: 2) { n, total, err in
                    if n % 10 == 0 || n == total || err != nil {
                        let el = Date().timeIntervalSince(start)
                        print("\(n)/\(total)  已用 \(Int(el / 60)) 分钟，预计还要 \(Int(el / Double(n) * Double(total - n) / 60)) 分钟\(err.map { "  ✗ \($0)" } ?? "")")
                    }
                }
                let missing = ls.filter { !VoiceCache.has($0, cfg) }.count
                print(missing == 0 ? "全部合成好了" : "还有 \(missing) 句没合成成功，再运行一次会只补这些")
                ok.success = missing == 0
                await MainActor.run { LocalTTS.shared.stop() }
            }
            exit(ok.success ? 0 : 1)
        }
        // --speak-test [音色] [一段话]：模拟 AI 一边写一边念（静音），看第一声多久出来、念完要多久
        if args.first == "--speak-test" {
            let voice = args.count > 1 ? args[1] : "yachiyo/综合"
            let text = args.count > 2 ? args[2] : "各位侦探，欢迎来到六角馆。我是今晚的主持人，八千代。凶手，就在你们之中哦。请大家拿出手机，选择自己的角色吧。"
            CLI.runAsync {
                let n = Narrator()
                var cfg = VoiceSettings()
                cfg.engine = .local
                cfg.localVoice = voice
                n.voiceConfig = cfg
                n.muteForTesting()
                for (label, t) in [("预热", "好的。"), ("正式", text)] {
                    VoiceCache.remove(t, cfg)
                    var first: Double?
                    let t0 = Date()
                    let sub = n.avatar.sink { e in
                        if case .level(let l) = e, l > 0.05, first == nil { first = Date().timeIntervalSince(t0) }
                    }
                    n.streamStarted()
                    var i = t.startIndex
                    while i < t.endIndex {                      // 像 AI 一样每 30 毫秒吐几个字
                        let j = t.index(i, offsetBy: 4, limitedBy: t.endIndex) ?? t.endIndex
                        n.streamDelta(String(t[i..<j]))
                        i = j
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    n.streamEnded(cancelled: false)
                    while n.isBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
                    let total = Date().timeIntervalSince(t0)
                    print("\(label)：第一声 \(first.map { String(format: "%.2f", $0) } ?? "没有") 秒，全部念完 \(String(format: "%.1f", total)) 秒\(n.lastError.map { "（\($0)）" } ?? "")")
                    sub.cancel()
                }
                await MainActor.run { LocalTTS.shared.stop() }
            }
            exit(0)
        }
        // --game-test [剧本文件夹]：静音开一局新游戏（默认示例剧本），看 DM 多久开口
        if args.first == "--game-test" {
            CLI.runAsync {
                let model = AppModel()
                model.narrator.muteForTesting()
                let folder = args.count > 1 ? URL(fileURLWithPath: args[1]) : Paths.demo
                var first: Double?
                let t0 = Date()
                let sub = model.narrator.avatar.sink { e in
                    if case .level(let l) = e, l > 0.05, first == nil { first = Date().timeIntervalSince(t0) }
                }
                await model.start(model.entry(for: folder, builtIn: folder == Paths.demo), newGame: true)
                print("开局：\(model.session == nil ? "失败 \(model.alert?.message ?? "")" : "成功")，语音 \(model.narrator.enabled ? "开" : "关")，音色 \(model.voiceLabel)")
                while first == nil && Date().timeIntervalSince(t0) < 60 { try? await Task.sleep(nanoseconds: 100_000_000) }
                print("DM 第一声：\(first.map { String(format: "%.1f 秒", $0) } ?? "60 秒内没有出声")\(model.narrator.lastError.map { "（\($0)）" } ?? "")")
                sub.cancel()
                model.endGame()
                LocalTTS.shared.stop()
            }
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
            let ok = CLIResult()
            CLI.runAsync {
                do {
                    let t = Date()
                    let d = try await LocalTTS.shared.synthesize(args[2], voice: args[1])
                    try d.write(to: URL(fileURLWithPath: args[3]))
                    print("ok \(d.count) bytes in \(Int(Date().timeIntervalSince(t)))s")
                    let t2 = Date()
                    _ = try await LocalTTS.shared.synthesize("第二句话，服务已经在运行了。", voice: args[1])
                    print("second sentence in \(String(format: "%.1f", Date().timeIntervalSince(t2)))s")
                    ok.success = true
                } catch { print("失败：\(error.localizedDescription)") }
                await MainActor.run { LocalTTS.shared.stop() }
            }
            exit(ok.success ? 0 : 1)
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

/// 命令行模式里异步任务的结果（成功才返回 0，脚本好判断）
final class CLIResult: @unchecked Sendable { var success = false }
