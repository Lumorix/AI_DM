import AppKit
import Combine
import AVFoundation
import CoreImage.CIFilterBuiltins
import Foundation
import Security

// MARK: - 文件位置

enum Paths {
    /// 应用数据（剧本、存档、语音模型……）放在哪：
    /// 1. 设置里指定的 dataRoot；2. 应用旁边就有 data/（打包给别的电脑时的摆法）；
    /// 3. 应用所在项目文件夹里的 data/（build/AI 剧本杀.app → ../data）；4. 否则 ~/Library/Application Support/AI DM
    static let support: URL = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: "dataRoot"), !custom.isEmpty {
            candidates.append(URL(fileURLWithPath: custom, isDirectory: true))
        }
        let besideApp = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(besideApp.appendingPathComponent("data", isDirectory: true))
        candidates.append(besideApp.deletingLastPathComponent().appendingPathComponent("data", isDirectory: true))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("data", isDirectory: true))       // swift run 开发时
        var isDir: ObjCBool = false
        if let u = candidates.first(where: { fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }) {
            return u
        }
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AI DM", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static var scripts: URL { dir("Scripts") }
    static var saves: URL { dir("Saves") }
    static var ocr: URL { dir("OCR") }

    private static func dir(_ name: String) -> URL {
        let u = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 打包后在 .app/Contents/Resources；开发时（swift run）直接用仓库里的 Resources 目录
    static let resources: URL = {
        if let r = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: r.appendingPathComponent("web").path) {
            return r
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    }()

    static var web: URL { resources.appendingPathComponent("web") }
    static var demo: URL { resources.appendingPathComponent("Demo") }

    static func save(for scriptFolder: URL) -> URL {
        saves.appendingPathComponent(scriptFolder.lastPathComponent + ".json")
    }
}

// MARK: - 局域网地址

enum LAN {
    /// 本机在局域网里的 IPv4 地址（优先 Wi‑Fi / 有线网卡的私有地址）
    static func address() -> String {
        var best: (score: Int, ip: String)?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            var score = 0
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.range(of: "^172\\.(1[6-9]|2\\d|3[01])\\.", options: .regularExpression) != nil { score += 10 }
            if name == "en0" { score += 5 } else if name.hasPrefix("en") { score += 3 }
            if ip.hasPrefix("169.254.") { score -= 20 }
            if best == nil || score > best!.score { best = (score, ip) }
        }
        return best?.ip ?? "127.0.0.1"
    }
}

// MARK: - 二维码

enum QRCode {
    static func image(_ text: String, size: CGFloat = 512) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = (size / out.extent.width).rounded(.down)
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - 钥匙串（保存 API Key）

enum Keychain {
    private static let service = "AI DM"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - 语音朗读（大屏）+ 驱动 DM 形象的嘴型

@MainActor
final class Narrator: NSObject, SpeechSink, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { say("语音已开启") } else { stop() }
            UserDefaults.standard.set(enabled, forKey: "ttsEnabled")
        }
    }
    @Published var rate: Float = 0.5 { didSet { UserDefaults.standard.set(rate, forKey: "ttsRate") } }
    @Published var voiceID: String = "" { didSet { UserDefaults.standard.set(voiceID, forKey: "ttsVoice") } }

    /// DM 形象订阅：开始/停止说话、每个字一下嘴型、换阶段做个动作
    let avatar = PassthroughSubject<AvatarEvent, Never>()

    private let synth = AVSpeechSynthesizer()
    private var buf = ""
    private var pending = 0
    private var fakeTalk: DispatchWorkItem?

    // 阿里云 Qwen 克隆音色（比如八千代）
    var voiceConfig = VoiceSettings()
    var voiceKey = ""
    @Published var lastError: String?
    private let clip = ClipPlayer()
    private let streamer = StreamPlayer()
    private var queue: [String] = []
    private var pipeline: Task<Void, Never>?
    private var pipelineID = UUID()
    private var meter: Timer?
    private var useCloud: Bool { voiceConfig.usable }

    override init() {
        super.init()
        synth.delegate = self
        rate = UserDefaults.standard.object(forKey: "ttsRate") as? Float ?? 0.5
        voiceID = UserDefaults.standard.string(forKey: "ttsVoice") ?? ""
        enabled = UserDefaults.standard.object(forKey: "ttsEnabled") as? Bool ?? true     // 默认开着：DM 每句话都念出来
    }

    static var chineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
            .sorted { ($0.quality.rawValue, $0.language == "zh-CN" ? 1 : 0) > ($1.quality.rawValue, $1.language == "zh-CN" ? 1 : 0) }
    }

    private var voice: AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        return Self.chineseVoices.first { $0.language == "zh-CN" } ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    private func speak(_ text: String) {
        if useCloud { enqueueCloud(text) } else { speakSystem(text) }
    }

    private func speakSystem(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        pending += 1
        synth.speak(u)
    }

    // 云端音色：一句一句合成，边放边合成下一句；嘴型跟着真实音量动
    private func enqueueCloud(_ text: String) {
        queue.append(text)
        if pipeline == nil { startPipeline() }
    }

    private func synthTask(_ text: String) -> Task<(String, Data?), Never> {
        let cfg = voiceConfig, key = voiceKey
        return Task {
            // 偶尔失败（比如后台语音服务刚好重启）就再试两次，尽量都用八千代的声音；实在不行才临时用系统声音，保证这句一定念出来
            var last: Error?
            for attempt in 0..<3 {
                if Task.isCancelled { break }
                do {
                    return (text, try await VoiceCache.synthesize(text, cfg: cfg, key: key))
                } catch {
                    last = error
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                }
            }
            let msg = last?.localizedDescription ?? ""
            await MainActor.run { self.lastError = "八千代音色合成失败，这句临时用了系统声音：\(msg)" }
            return (text, nil)
        }
    }

    private func startMeter() {
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.avatar.send(.level(max(self.clip.level, self.streamer.level))) } }
        }
    }

    private func startPipeline() {
        if voiceConfig.engine == .local { startLocalPipeline(); return }
        let id = UUID()
        pipelineID = id
        avatar.send(.talking(true))
        startMeter()
        pipeline = Task { [weak self] in
            var next: Task<(String, Data?), Never>?
            while let self, !Task.isCancelled {
                let current: Task<(String, Data?), Never>
                if let n = next { current = n; next = nil }
                else if !self.queue.isEmpty { current = self.synthTask(self.queue.removeFirst()) }
                else { break }
                if !self.queue.isEmpty { next = self.synthTask(self.queue.removeFirst()) }     // 预先合成下一句
                let (text, data) = await current.value
                if Task.isCancelled { break }
                if let data {
                    self.lastError = nil
                    await self.clip.play(data)
                } else {
                    self.speakSystem(text)
                    while self.synth.isSpeaking && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
            }
            guard let self, self.pipelineID == id else { return }
            self.meter?.invalidate()
            self.meter = nil
            self.pipeline = nil
            self.avatar.send(.talking(false))
        }
    }

    /// 本机音色：一句一句边合成边播放。上一句还在放的时候就开始合成下一句，排在它后面，衔接不断
    private func startLocalPipeline() {
        let id = UUID()
        pipelineID = id
        avatar.send(.talking(true))
        startMeter()
        pipeline = Task { [weak self] in
            while let self, !Task.isCancelled {
                if !self.queue.isEmpty {
                    await self.speakLocal(self.queue.removeFirst())
                } else if !self.streamer.isIdle || self.synth.isSpeaking {
                    try? await Task.sleep(nanoseconds: 50_000_000)       // 等这段放完，期间可能又来新句子
                } else {
                    break
                }
            }
            guard let self, self.pipelineID == id else { return }
            self.meter?.invalidate()
            self.meter = nil
            self.pipeline = nil
            self.avatar.send(.talking(false))
        }
    }

    private func speakLocal(_ text: String) async {
        let cfg = voiceConfig
        if let d = VoiceCache.get(text, cfg), streamer.enqueue(wav: d) { return }
        var failure: Error?
        for attempt in 0..<3 {          // 偶尔失败（比如服务刚好重启）就再试，尽量都用八千代的声音
            if Task.isCancelled { return }
            var pcm = Data()
            do {
                let (rate, chunks) = try await LocalTTS.shared.stream(text, voice: cfg.localVoice)
                for try await c in chunks {
                    if Task.isCancelled { return }
                    streamer.enqueue(pcm16: c, sampleRate: rate)
                    pcm.append(c)
                }
                if Task.isCancelled { return }
                VoiceCache.put(WAV.wrap(pcm16: pcm, sampleRate: Int(rate)), text, cfg)
                lastError = nil
                return
            } catch {
                if Task.isCancelled { return }
                failure = error
                if !pcm.isEmpty { return }      // 念到一半断了：念出来的部分就算了，不重复
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            }
        }
        // 实在不行才临时用系统声音，保证这句一定念出来
        lastError = "八千代音色合成失败，这句临时用了系统声音：\(failure?.localizedDescription ?? "")"
        while !streamer.isIdle && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        if Task.isCancelled { return }
        speakSystem(text)
        while synth.isSpeaking && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// 正在念（或者还有句子排着）
    var isBusy: Bool { pipeline != nil || synth.isSpeaking }

    /// 命令行测试用：照常合成和播放，但不出声
    func muteForTesting() { streamer.muted = true }

    func preview(_ text: String) {
        stop()
        speak(text)
    }

    func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if enabled { Sentences.split(t).forEach(speak) } else { talkSilently(seconds: min(8, Double(t.count) * 0.16)) }
    }

    /// 没开语音时，形象按字数“说”一会儿
    private func talkSilently(seconds: Double) {
        fakeTalk?.cancel()
        avatar.send(.talking(true))
        let w = DispatchWorkItem { [weak self] in self?.avatar.send(.talking(false)) }
        fakeTalk = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func stop() {
        buf = ""
        pending = 0
        pipelineID = UUID()
        pipeline?.cancel()
        pipeline = nil
        queue.removeAll()
        clip.stop()
        streamer.stop()
        meter?.invalidate()
        meter = nil
        synth.stopSpeaking(at: .immediate)
        fakeTalk?.cancel()
        avatar.send(.talking(false))
    }

    // 流式文字：攒够一句就念；没开语音就让形象跟着文字动嘴
    func streamStarted() {
        stop()
        if !enabled { avatar.send(.talking(true)) }
    }

    func streamDelta(_ text: String) {
        guard enabled else { avatar.send(.pulse); return }
        buf += text
        while let r = buf.range(of: Sentences.pattern, options: .regularExpression) {
            say(String(buf[r]))
            buf.removeSubrange(r)
        }
        // 一长串没有句号的话（“第一，……；第二，……”）：攒够一截就先从逗号/分号处开口，不等整句写完
        if buf.count > Sentences.maxChars {
            let pieces = Sentences.split(buf)
            if pieces.count > 1 {
                pieces.dropLast().forEach(say)
                buf = pieces.last ?? ""
            }
        }
    }

    func streamEnded(cancelled: Bool) {
        if cancelled { stop(); return }
        if enabled { say(buf); buf = "" } else { avatar.send(.talking(false)) }
    }

    func phaseChanged() {
        avatar.send(.mood("neutral"))
        avatar.send(.motion)
    }

    /// 复盘：投对了笑，投错了哭
    func revealStarted(correct: Bool?) {
        avatar.send(.mood(correct == false ? "sad" : "happy"))
    }

    /// AI 在想公开问题的答案
    func thinking(_ on: Bool) { avatar.send(.mood(on ? "think" : "neutral")) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.avatar.send(.talking(true)) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        Task { @MainActor in self.avatar.send(.pulse) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceDone() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceDone() }
    }

    private func utteranceDone() {
        pending = max(0, pending - 1)
        if pending == 0 { avatar.send(.talking(false)) }
    }
}
