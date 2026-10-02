// DM 的声音：系统自带语音，或者阿里云百炼 Qwen3-TTS 的克隆音色（比如八千代）。
// 克隆音色要先用 10~20 秒的样本音频在自己的百炼账号里“创建音色”，拿到音色 ID 后才能合成。
// 音色 ID 只在创建它的那个账号里能用，别人项目里的 ID 换成你的 Key 一般用不了。
import AVFoundation
import CryptoKit
import Foundation

struct VoiceSettings: Codable, Equatable {
    var engine: Engine = .system
    var region: Region = .cn
    var model = "qwen3-tts-vc-2026-01-22"     // 合成模型：必须和创建音色时的 target_model 一致
    var voice = ""                              // 克隆音色 ID
    var language = "Chinese"                    // Chinese / Japanese / English

    enum Engine: String, Codable { case system, qwen }
    enum Region: String, Codable { case cn, intl }

    var base: String { region == .cn ? "https://dashscope.aliyuncs.com" : "https://dashscope-intl.aliyuncs.com" }

    /// yachiyo-qwen-voice-reply 项目里写的八千代音色（作者在国际站创建的，多半只限作者的账号使用）
    static let yachiyoProjectVoice = "qwen-tts-vc-yachiyo-voice-20260224022238839-5679"
    var usable: Bool { engine == .qwen && !voice.isEmpty && !model.isEmpty }
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
        let raw = "\(cfg.model)|\(cfg.voice)|\(cfg.language)|\(text)"
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
        let d = try await QwenTTS.synthesize(text, cfg: cfg, key: key)
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
