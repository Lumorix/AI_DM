// DM 的声音：系统自带语音，或者阿里云百炼 Qwen3-TTS 的克隆音色（比如八千代）。
// 克隆音色要先用 10~20 秒的样本音频在自己的百炼账号里“创建音色”，拿到音色 ID 后才能合成。
// 音色 ID 只在创建它的那个账号里能用，别人项目里的 ID 换成你的 Key 一般用不了。
import AVFoundation
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
