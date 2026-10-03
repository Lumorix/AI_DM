// DM 的声音：系统自带语音，或者阿里云百炼 Qwen3-TTS 的克隆音色（比如八千代）。
// 克隆音色要先用 10~20 秒的样本音频在自己的百炼账号里“创建音色”，拿到音色 ID 后才能合成。
// 音色 ID 只在创建它的那个账号里能用，别人项目里的 ID 换成你的 Key 一般用不了。
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

struct VoiceSettings: Codable, Equatable {
    var engine: Engine = .system
    var region: Region = .cn
    var model = "qwen3-tts-vc-2026-01-22"     // 合成模型：必须和创建音色时的 target_model 一致
    var voice = ""                              // 克隆音色 ID
    var language = "Chinese"                    // Chinese / Japanese / English
    var localVoice = ""                         // 本机音色：LocalTTS/voices 下的文件夹（里面有 ref.wav + ref.txt）

    enum Engine: String, Codable { case system, qwen, local }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .system
        region = try c.decodeIfPresent(Region.self, forKey: .region) ?? .cn
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "qwen3-tts-vc-2026-01-22"
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "Chinese"
        localVoice = try c.decodeIfPresent(String.self, forKey: .localVoice) ?? ""
    }
    enum Region: String, Codable { case cn, intl }

    var base: String { region == .cn ? "https://dashscope.aliyuncs.com" : "https://dashscope-intl.aliyuncs.com" }

    /// yachiyo-qwen-voice-reply 项目里写的八千代音色（作者在国际站创建的，多半只限作者的账号使用）
    static let yachiyoProjectVoice = "qwen-tts-vc-yachiyo-voice-20260224022238839-5679"
    var usable: Bool {
        switch engine {
        case .system: false
        case .qwen: !voice.isEmpty && !model.isEmpty
        case .local: LocalTTS.voiceExists(localVoice) && LocalTTS.isInstalled
        }
    }

    /// 缓存用的“音色身份”：换了音色/模型就是另一套录音
    var cacheIdentity: String {
        engine == .local ? "local|\(LocalTTS.modelName)|\(localVoice)" : "\(model)|\(voice)|\(language)"
    }
}

enum QwenTTS {
    struct VoiceInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let model: String
    }

    private static func post(_ url: String, key: String, body: [String: Any], timeout: Double = 60) async throws -> [String: Any] {
        guard !key.isEmpty else { throw LLMError(message: "还没有填阿里云百炼的 API Key") }
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let text = String(decoding: data, as: UTF8.self)
        let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            let msg = (j["message"] as? String) ?? String(text.prefix(300))
            throw LLMError(message: "百炼接口返回 \(h.statusCode)：\(msg)")
        }
        return j
    }

    /// 合成一句话，返回音频数据（wav）
    static func synthesize(_ text: String, cfg: VoiceSettings, key: String) async throws -> Data {
        let j = try await post("\(cfg.base)/api/v1/services/aigc/multimodal-generation/generation", key: key, body: [
            "model": cfg.model,
            "input": ["text": text, "voice": cfg.voice, "language_type": cfg.language],
        ])
        let audio = (j["output"] as? [String: Any])?["audio"] as? [String: Any]
        if let b64 = audio?["data"] as? String, !b64.isEmpty, let d = Data(base64Encoded: b64) { return d }
        guard let s = audio?["url"] as? String, let url = URL(string: s) else {
            throw LLMError(message: "合成失败，没拿到音频：\(String(describing: j).prefix(300))")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard data.count > 1024 else { throw LLMError(message: "下载到的音频不完整") }
        return data
    }

    /// 用样本音频创建克隆音色，返回音色 ID
    static func enroll(audio: URL, name: String, cfg: VoiceSettings, key: String) async throws -> String {
        let data = try Data(contentsOf: audio)
        guard data.count < 10_000_000 else { throw LLMError(message: "样本音频要小于 10MB（建议 10~20 秒）") }
        let mime = switch audio.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "m4a": "audio/mp4"
        default: "audio/mpeg"
        }
        let j = try await post("\(cfg.base)/api/v1/services/audio/tts/customization", key: key, body: [
            "model": "qwen-voice-enrollment",
            "input": ["action": "create", "target_model": cfg.model, "preferred_name": name,
                      "audio": ["data": "data:\(mime);base64,\(data.base64EncodedString())"]],
        ], timeout: 180)
        guard let v = (j["output"] as? [String: Any])?["voice"] as? String, !v.isEmpty else {
            throw LLMError(message: "创建失败：\(String(describing: j).prefix(300))")
        }
        return v
    }

    /// 声音设计：用文字描述生成一个新音色（不需要录音）。返回音色 ID 和试听音频
    static let designModel = "qwen3-tts-vd-2026-01-26"
    static let cloneModel = "qwen3-tts-vc-2026-01-22"

    static func design(prompt: String, preview: String, name: String, cfg: VoiceSettings, key: String) async throws -> (voice: String, preview: Data?) {
        let j = try await post("\(cfg.base)/api/v1/services/audio/tts/customization", key: key, body: [
            "model": "qwen-voice-design",
            "input": ["action": "create", "target_model": designModel, "preferred_name": name,
                      "voice_prompt": prompt, "preview_text": preview],
            "parameters": ["sample_rate": 24000, "response_format": "wav"],
        ], timeout: 120)
        let out = j["output"] as? [String: Any]
        guard let v = out?["voice"] as? String, !v.isEmpty else {
            throw LLMError(message: "设计失败：\(String(describing: j).prefix(300))")
        }
        let b64 = (out?["preview_audio"] as? [String: Any])?["data"] as? String
        return (v, b64.flatMap { Data(base64Encoded: $0) })
    }

    /// 查询账号里已有的克隆音色
    static func list(cfg: VoiceSettings, key: String) async throws -> [VoiceInfo] {
        let j = try await post("\(cfg.base)/api/v1/services/audio/tts/customization", key: key, body: [
            "model": "qwen-voice-enrollment", "input": ["action": "list"],
        ])
        let voices = (j["output"] as? [String: Any])?["voices"] as? [[String: Any]] ?? []
        return voices.compactMap { v in
            guard let id = (v["voice"] ?? v["id"]) as? String else { return nil }
            return VoiceInfo(id: id, name: (v["preferred_name"] ?? v["name"]) as? String ?? "", model: v["target_model"] as? String ?? "")
        }
    }
}

/// 播放一段音频，等它放完；顺便提供实时音量（给 DM 形象对口型）
@MainActor
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var cont: CheckedContinuation<Void, Never>?

    var level: Float {
        guard let p = player, p.isPlaying else { return 0 }
        p.updateMeters()
        let db = p.averagePower(forChannel: 0)       // -160…0
        return max(0, min(1, (db + 45) / 40))
    }

    func play(_ data: Data) async {
        stop()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.delegate = self
        p.isMeteringEnabled = true
        player = p
        await withCheckedContinuation { c in
            cont = c
            if !p.play() { finish() }
        }
    }

    func stop() {
        player?.stop()
        finish()
    }

    private func finish() {
        player = nil
        let c = cont
        cont = nil
        c?.resume()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finish() }
    }
}

// MARK: - 本机语音缓存：合成过的句子存成文件，下次直接播放（不用联网、不再花钱）



enum VoiceCache {
    static var dir: URL {
        let u = Paths.support.appendingPathComponent("VoiceCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func file(_ text: String, _ cfg: VoiceSettings) -> URL {
        let raw = "\(cfg.cacheIdentity)|\(text)"
        let hex = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hex + ".audio")
    }

    static func get(_ text: String, _ cfg: VoiceSettings) -> Data? { try? Data(contentsOf: file(text, cfg)) }
    static func has(_ text: String, _ cfg: VoiceSettings) -> Bool { FileManager.default.fileExists(atPath: file(text, cfg).path) }
    static func put(_ data: Data, _ text: String, _ cfg: VoiceSettings) { try? data.write(to: file(text, cfg), options: .atomic) }

    static var usage: (files: Int, bytes: Int) {
        let fs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return (fs.count, fs.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
    }

    static func clear() {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// 合成一句：先查本机缓存，没有再调接口并存下来
    static func synthesize(_ text: String, cfg: VoiceSettings, key: String) async throws -> Data {
        if let d = get(text, cfg) { return d }
        let d = cfg.engine == .local ? try await LocalTTS.shared.synthesize(text, voice: cfg.localVoice)
                                     : try await QwenTTS.synthesize(text, cfg: cfg, key: key)
        put(d, text, cfg)
        return d
    }
}

/// 把一段话切成一句一句（和大屏朗读时的切法完全一致，提前生成的语音才能对上）
enum Sentences {
    static let pattern = "[\\s\\S]*?[。！？!?\\n…]+"

    static func split(_ text: String) -> [String] {
        var buf = text, out: [String] = []
        while let r = buf.range(of: pattern, options: .regularExpression) {
            out.append(String(buf[r]))
            buf.removeSubrange(r)
        }
        out.append(buf)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// 提前把整本剧本的主持词用克隆音色生成好、存到本机
enum VoicePregen {
    static func lines(of script: Script) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in script.phases {
            for s in Sentences.split(p.dmScript) where seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    /// 北京地域 ¥0.115 / 万字符（国际站 $0.115），只是估算
    static func estimate(_ lines: [String], _ cfg: VoiceSettings) -> String {
        let chars = lines.reduce(0) { $0 + $1.count }
        let cost = Double(chars) / 10000 * 0.115
        return "\(chars) 字，约 \(cfg.region == .cn ? "¥" : "$")\(String(format: "%.2f", max(cost, 0.01)))"
    }

    static func run(_ lines: [String], cfg: VoiceSettings, key: String, concurrency: Int = 3,
                    progress: @escaping @Sendable (Int, Int, String?) -> Void) async {
        let todo = lines.filter { !VoiceCache.has($0, cfg) }
        let total = todo.count
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add(_ line: String) {
                group.addTask {
                    var err: String?
                    do { _ = try await VoiceCache.synthesize(line, cfg: cfg, key: key) } catch {
                        err = error.localizedDescription
                    }
                    let n = await counter.increment()
                    progress(n, total, err)
                }
            }
            while next < min(concurrency, total) { add(todo[next]); next += 1 }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if next < total { add(todo[next]); next += 1 }
            }
        }
    }
}


// MARK: - 从视频/音频里截一段样本（克隆音色用）

enum AudioClip {
    static var dir: URL {
        let u = Paths.support.appendingPathComponent("VoiceSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// "75"、"1:15"、"0:01:15" 都可以
    static func parseTime(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// 截取 [start, start+duration) 的声音，转成 24kHz 单声道 16bit WAV
    static func extract(from url: URL, start: Double, duration: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LLMError(message: "这个文件里没有声音")
        }
        let total = try await asset.load(.duration).seconds
        guard start < total else { throw LLMError(message: "开始时间超过了文件长度（\(Int(total)) 秒）") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: min(duration, total - start), preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw LLMError(message: "读不了这个文件：\(reader.error?.localizedDescription ?? "")") }
        var pcm = Data()
        while let sb = output.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = Data(count: len)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            pcm.append(chunk)
        }
        guard pcm.count > 24000 * 2 else { throw LLMError(message: "截到的声音太短") }
        let name = url.deletingPathExtension().lastPathComponent + "-" + String(Int(start)) + "s.wav"
        let dst = dir.appendingPathComponent(name)
        try (wavHeader(dataBytes: pcm.count, rate: 24000) + pcm).write(to: dst, options: .atomic)
        return dst
    }

    private static func wavHeader(dataBytes: Int, rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + dataBytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataBytes)
        return d
    }
}


// MARK: - 本机 Qwen3-TTS（mlx-audio），完全离线、免费

@MainActor
final class LocalTTS {
    static let shared = LocalTTS()
    nonisolated static let modelName = "Qwen3-TTS-12Hz-1.7B-Base-bf16"
    nonisolated static let port = 8771

    nonisolated static var root: URL { Paths.support.appendingPathComponent("LocalTTS", isDirectory: true) }
    nonisolated static var python: URL { root.appendingPathComponent(".venv/bin/python") }
    nonisolated static var model: URL { root.appendingPathComponent("models/\(modelName)") }
    nonisolated static var voicesDir: URL { root.appendingPathComponent("voices", isDirectory: true) }
    nonisolated static var serverScript: URL { Paths.resources.appendingPathComponent("localtts/server.py") }

    nonisolated static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path) && fm.fileExists(atPath: model.appendingPathComponent("config.json").path)
    }

    nonisolated static func voiceExists(_ rel: String) -> Bool {
        !rel.isEmpty && FileManager.default.fileExists(atPath: voicesDir.appendingPathComponent(rel).appendingPathComponent("ref.wav").path)
    }

    /// 所有可用的本机音色（含 ref.wav + ref.txt 的文件夹），返回相对 voices 的路径
    nonisolated static func voices() -> [String] {
        guard let e = FileManager.default.enumerator(at: voicesDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let u as URL in e where u.lastPathComponent == "ref.wav" {
            let dir = u.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("ref.txt").path) {
                out.append(String(dir.path.dropFirst(voicesDir.path.count + 1)))
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var process: Process?
    private var starting: Task<Void, Error>?
    private(set) var log = ""

    var running: Bool { process?.isRunning == true }

    /// 第一次合成时自动启动后台服务（加载模型约 10~20 秒）
    func ensureRunning(voice: String) async throws {
        if running, await healthy() { return }
        if let starting { return try await starting.value }
        let t = Task { try await start(voice: voice) }
        starting = t
        defer { starting = nil }
        try await t.value
    }

    private func start(voice: String) async throws {
        guard Self.isInstalled else { throw LLMError(message: "本机语音还没装好（缺少模型或 Python 环境）") }
        stop()
        let p = Process()
        p.executableURL = Self.python
        p.arguments = [Self.serverScript.path, "--model", Self.model.path,
                       "--voice", Self.voicesDir.appendingPathComponent(voice).path, "--port", "\(Self.port)"]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in self?.log = String(((self?.log ?? "") + s).suffix(4000)) }
        }
        try p.run()
        process = p
        for _ in 0..<180 {                       // 最多等 90 秒
            try await Task.sleep(nanoseconds: 500_000_000)
            if !p.isRunning { throw LLMError(message: "本机语音服务启动失败：\(log.suffix(300))") }
            if await healthy() { return }
        }
        throw LLMError(message: "本机语音服务启动超时")
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func healthy() async -> Bool {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!, timeoutInterval: 2)
        r.httpMethod = "GET"
        return ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    func synthesize(_ text: String, voice: String) async throws -> Data {
        try await ensureRunning(voice: voice)
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/tts")!, timeoutInterval: 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "voice": Self.voicesDir.appendingPathComponent(voice).path])
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else {
            throw LLMError(message: "本机语音合成失败：\(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return data
    }
}
