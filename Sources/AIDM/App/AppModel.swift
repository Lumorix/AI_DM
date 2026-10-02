import AppKit
import Foundation
import Observation

// MARK: - 设置

struct AppSettings: Codable, Equatable {
    var llm = LLMConfig()
    var cheapEnabled = false            // 记忆压缩交给便宜/本地模型
    var cheap = LLMConfig(provider: .openai, baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b")
    var visionEnabled = false           // OCR 用视觉大模型
    var vision = LLMConfig(provider: .openai, baseURL: "http://localhost:11434/v1", model: "qwen2.5vl:7b", timeout: 300, maxTokens: 4000)
    var game = GameSettings()
    var port = 8000
    var avatar = AvatarSettings()
    var voice = VoiceSettings()

    init() {}

    init(from d: Decoder) throws {       // 新加的字段缺省时用默认值，旧设置照样能读
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        llm = try c.decodeIfPresent(LLMConfig.self, forKey: .llm) ?? def.llm
        cheapEnabled = try c.decodeIfPresent(Bool.self, forKey: .cheapEnabled) ?? def.cheapEnabled
        cheap = try c.decodeIfPresent(LLMConfig.self, forKey: .cheap) ?? def.cheap
        visionEnabled = try c.decodeIfPresent(Bool.self, forKey: .visionEnabled) ?? def.visionEnabled
        vision = try c.decodeIfPresent(LLMConfig.self, forKey: .vision) ?? def.vision
        game = try c.decodeIfPresent(GameSettings.self, forKey: .game) ?? def.game
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? def.port
        avatar = try c.decodeIfPresent(AvatarSettings.self, forKey: .avatar) ?? def.avatar
        voice = try c.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? def.voice
    }

    static func load() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }

    func persist() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "settings") }
    }
}

/// 常用 AI 服务的预设
struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let needsKey: Bool
    let note: String

    static let all: [ProviderPreset] = [
        .init(id: "mock", name: "模拟模式（不接AI）", baseURL: "", model: "", needsKey: false,
              note: "不调用任何AI，用来熟悉流程。旁白原文照念，问答固定回复。"),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", needsKey: true,
              note: "便宜、中文好，相同开头的请求自动缓存，很适合本系统。"),
        .init(id: "qwen", name: "通义千问（阿里云百炼）", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus", needsKey: true,
              note: "阿里云百炼控制台申请 API Key。"),
        .init(id: "claude", name: "Claude（OpenAI 兼容接口）", baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-5-5", needsKey: true,
              note: "守秘密能力强。兼容接口不支持 prompt 缓存。"),
        .init(id: "ollama", name: "本地 Ollama", baseURL: "http://localhost:11434/v1", model: "qwen2.5:14b", needsKey: false,
              note: "先安装 Ollama，再在终端运行 ollama pull qwen2.5:14b。7B~14B 需要 8~16GB 内存/显存。"),
        .init(id: "lmstudio", name: "本地 LM Studio", baseURL: "http://localhost:1234/v1", model: "", needsKey: false,
              note: "在 LM Studio 里加载模型并开启 Local Server，模型名填它显示的名字。"),
        .init(id: "custom", name: "其他（OpenAI 兼容）", baseURL: "", model: "", needsKey: true,
              note: "任何兼容 OpenAI /chat/completions 格式的服务都可以。"),
    ]

    static func match(_ c: LLMConfig) -> ProviderPreset {
        if c.provider == .mock { return all[0] }
        return all.first { $0.id != "mock" && $0.id != "custom" && $0.baseURL == c.baseURL } ?? all.last!
    }
}

// MARK: - 剧本库

struct ScriptEntry: Identifiable, Equatable {
    var id: String { folder.path }
    let folder: URL
    let script: Script?
    let error: String?
    let issues: [Issue]
    let isBuiltIn: Bool
    let save: SaveInfo?

    struct SaveInfo: Equatable {
        let phaseIndex: Int
        let phaseTitle: String
        let players: Int
        let modified: Date
    }

    var title: String { script?.title ?? folder.lastPathComponent }
    var errorCount: Int { issues.filter { $0.level == .error }.count + (error == nil ? 0 : 1) }
    var warningCount: Int { issues.filter { $0.level == .warning }.count }
}

// MARK: - 一局游戏（游戏引擎 + 手机网页服务）

@MainActor @Observable
final class Session {
    let game: Game
    let port: UInt16
    let ip: String
    @ObservationIgnored let server: HTTPServer
    @ObservationIgnored let router: WebRouter

    init(game: Game, server: HTTPServer, router: WebRouter, port: UInt16, ip: String) {
        self.game = game; self.server = server; self.router = router; self.port = port; self.ip = ip
    }

    var playerURL: String { "http://\(ip):\(port)/player" }

    func shutdown() {
        game.stopNarration()
        router.shutdown()
        server.stop()
    }
}

@MainActor @Observable
final class AppModel {
    var settings = AppSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.persist()
            applySettingsToSession()
            applyVoice()
        }
    }
    private(set) var library: [ScriptEntry] = []
    private(set) var session: Session?
    var alert: AlertInfo?
    var starting = false

    @ObservationIgnored let narrator = Narrator()

    struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        reloadLibrary()
        applyVoice()
    }

    /// 百炼 Key：单独填的优先；没填而 AI 主持用的是通义千问（同一个百炼账号），就借用那个
    var dashscopeKey: String {
        let k = apiKey("dashscope")
        if !k.isEmpty { return k }
        return settings.llm.baseURL.contains("dashscope") ? apiKey("main") : ""
    }

    func applyVoice() {
        narrator.voiceConfig = settings.voice
        narrator.voiceKey = dashscopeKey
    }

    // MARK: DM 形象（Live2D）

    private(set) var avatarModels: [Live2DModelInfo] = Live2D.models()
    var avatarModel: Live2DModelInfo? { avatarModels.first { $0.name == settings.avatar.model } }

    func reloadAvatars() { avatarModels = Live2D.models() }

    var importingAvatar = false

    func importAvatar(_ url: URL) {
        guard !importingAvatar else { return }
        importingAvatar = true
        Task.detached {
            let result = Result { try Live2D.importModel(from: url) }
            await MainActor.run {
                self.importingAvatar = false
                switch result {
                case .success(let name):
                    self.reloadAvatars()
                    self.settings.avatar.model = name
                    self.settings.avatar.enabled = true
                case .failure(let error):
                    self.alert = .init(title: "导入 Live2D 模型失败", message: error.localizedDescription)
                }
            }
        }
    }

    func deleteAvatar(_ name: String) {
        Live2D.delete(name)
        if settings.avatar.model == name { settings.avatar.model = "" }
        reloadAvatars()
    }

    // MARK: API Key（存在钥匙串）

    func apiKey(_ which: String) -> String { Keychain.get(which) }
    func setAPIKey(_ which: String, _ value: String) {
        Keychain.set(which, value)
        applySettingsToSession()
        applyVoice()
    }

    func makeLLM(_ which: String) throws -> LLM {
        switch which {
        case "cheap": try LLM(settings.cheap, apiKey: apiKey("cheap"))
        case "vision": try LLM(settings.vision, apiKey: apiKey("vision"))
        default: try LLM(settings.llm, apiKey: apiKey("main"))
        }
    }

    /// 读图用的模型：没单独配就用主模型
    func visionLLM() throws -> LLM { settings.visionEnabled ? try makeLLM("vision") : try makeLLM("main") }

    private func applySettingsToSession() {
        guard let g = session?.game else { return }
        g.settings.keepRecent = settings.game.keepRecent
        g.settings.summarizeBatch = settings.game.summarizeBatch
        g.settings.privateKeep = settings.game.privateKeep
        if let llm = try? makeLLM("main") {
            g.updateModels(llm: llm, cheap: settings.cheapEnabled ? try? makeLLM("cheap") : nil)
        }
    }

    // MARK: 剧本库

    var extraFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraScriptFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraScriptFolders") }
    }

    func reloadLibrary() {
        var folders: [(URL, Bool)] = [(Paths.demo, true)]
        let fm = FileManager.default
        let user = (try? fm.contentsOfDirectory(at: Paths.scripts, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("script.yaml").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
        folders += user.map { ($0, false) }
        for p in extraFolders where fm.fileExists(atPath: (p as NSString).appendingPathComponent("script.yaml")) {
            let u = URL(fileURLWithPath: p)
            if !folders.contains(where: { $0.0.standardizedFileURL == u.standardizedFileURL }) { folders.append((u, false)) }
        }
        library = folders.map { entry(for: $0.0, builtIn: $0.1) }
    }

    func entry(for folder: URL, builtIn: Bool) -> ScriptEntry {
        var script: Script?, err: String?, issues: [Issue] = []
        do {
            let s = try ScriptIO.load(folder)
            script = s
            issues = ScriptIO.validate(s)
        } catch {
            err = error.localizedDescription
        }
        var save: ScriptEntry.SaveInfo?
        let sp = Paths.save(for: folder)
        if let st = try? GameState.load(from: sp) {
            let mod = (try? FileManager.default.attributesOfItem(atPath: sp.path)[.modificationDate] as? Date) ?? Date()
            let title = script.flatMap { $0.phases.indices.contains(st.phaseIndex) ? $0.phases[st.phaseIndex].title : nil } ?? ""
            save = .init(phaseIndex: st.phaseIndex, phaseTitle: title, players: st.players.count, modified: mod)
        }
        return ScriptEntry(folder: folder, script: script, error: err, issues: issues, isBuiltIn: builtIn, save: save)
    }

    func addFolder(_ url: URL) {
        var dir = url
        if url.lastPathComponent == "script.yaml" { dir = url.deletingLastPathComponent() }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("script.yaml").path) else {
            alert = .init(title: "这个文件夹里没有 script.yaml", message: dir.path)
            return
        }
        if !extraFolders.contains(dir.path) { extraFolders.append(dir.path) }
        reloadLibrary()
    }

    func removeFromLibrary(_ e: ScriptEntry) {
        extraFolders.removeAll { $0 == e.folder.path }
        reloadLibrary()
    }

    /// 复制一份剧本到“我的剧本”，用来修改示例剧本
    @discardableResult
    func duplicate(_ e: ScriptEntry) -> URL? {
        var name = e.title + " 副本"
        var n = 2
        while FileManager.default.fileExists(atPath: Paths.scripts.appendingPathComponent(name).path) {
            name = e.title + " 副本 \(n)"; n += 1
        }
        let dst = Paths.scripts.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: e.folder, to: dst)
            reloadLibrary()
            return dst
        } catch {
            alert = .init(title: "复制失败", message: error.localizedDescription)
            return nil
        }
    }

    func deleteSave(_ e: ScriptEntry) {
        try? FileManager.default.removeItem(at: Paths.save(for: e.folder))
        reloadLibrary()
    }

    func trash(_ e: ScriptEntry) {
        guard !e.isBuiltIn else { return }
        do {
            try FileManager.default.trashItem(at: e.folder, resultingItemURL: nil)
        } catch {
            alert = .init(title: "无法移到废纸篓", message: error.localizedDescription)
        }
        extraFolders.removeAll { $0 == e.folder.path }
        reloadLibrary()
    }

    // MARK: 开局 / 结束

    func start(_ e: ScriptEntry, newGame: Bool) async {
        guard session == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let script = try ScriptIO.load(e.folder)
            let llm = try makeLLM("main")
            let cheap = settings.cheapEnabled ? try makeLLM("cheap") : nil
            let savePath = Paths.save(for: e.folder)
            var state: GameState
            if !newGame, let s = try? GameState.load(from: savePath), script.phases.indices.contains(s.phaseIndex) {
                state = s
            } else {
                if FileManager.default.fileExists(atPath: savePath.path) {
                    let f = DateFormatter()
                    f.dateFormat = "MMdd-HHmmss"
                    let backup = savePath.deletingLastPathComponent()
                        .appendingPathComponent("\(savePath.deletingPathExtension().lastPathComponent)-\(f.string(from: Date())).json")
                    try? FileManager.default.moveItem(at: savePath, to: backup)
                }
                state = GameState(scriptTitle: script.title)
                state.logPublic(.system, "系统", "《\(script.title)》即将开始。请用手机扫码或打开链接选择角色。")
                if let first = script.phases.first, !first.dmScript.isEmpty {   // 第一阶段的主持词先显示在大屏上
                    state.logPublic(.narration, "DM", first.dmScript, phase: first.id)
                }
                try state.save(to: savePath)
            }
            var gs = settings.game
            gs.narration = settings.game.narration
            let game = Game(script: script, state: state, llm: llm, cheap: cheap, settings: gs, savePath: savePath)
            game.speech = narrator
            let router = WebRouter(game: game, webRoot: Paths.web)
            let server = HTTPServer { [weak router] req, conn in
                guard let router else { return .notFound }
                return await router.handle(req, conn)
            }
            let port = try await server.start(preferred: UInt16(clamping: settings.port))
            session = Session(game: game, server: server, router: router, port: port, ip: LAN.address())
        } catch {
            alert = .init(title: "无法开始游戏", message: error.localizedDescription)
        }
    }

    func endGame() {
        session?.shutdown()
        narrator.stop()
        session = nil
        reloadLibrary()
    }
}
