import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            LLMForm(config: $model.settings.llm, account: "main",
                    intro: "主持和判定需要较强的推理和守秘密能力：模型越强，越不容易剧透、说错。")
                .tabItem { Label("AI 主持", systemImage: "brain") }
            Form {
                Section {
                    Toggle("记忆压缩用单独的（便宜/本地）模型", isOn: $model.settings.cheapEnabled)
                } footer: {
                    Text("游戏进行几个小时后，旧的记录会被压缩成摘要。这种简单活可以交给本地小模型，省钱。关掉就全部用主模型。")
                }
                if model.settings.cheapEnabled {
                    LLMFields(config: $model.settings.cheap, account: "cheap", allowMock: false)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("记忆压缩", systemImage: "archivebox") }
            Form {
                Section {
                    Toggle("读图（OCR 视觉引擎）用单独的视觉模型", isOn: $model.settings.visionEnabled)
                } footer: {
                    Text("导入剧本默认用苹果自带的中文文字识别，免费、离线。版面很乱（表格、竖排、手写）时可以改用视觉大模型逐页转写，例如 Qwen-VL。关掉就用主模型（需要它支持看图）。")
                }
                if model.settings.visionEnabled {
                    LLMFields(config: $model.settings.vision, account: "vision", allowMock: false)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("识别", systemImage: "doc.viewfinder") }
            GameSettingsForm()
                .tabItem { Label("游戏", systemImage: "gamecontroller") }
            AvatarForm()
                .tabItem { Label("DM 形象", systemImage: "person.crop.artframe") }
            VoiceForm()
                .tabItem { Label("语音", systemImage: "speaker.wave.2") }
        }
        .frame(width: 720, height: 640)
    }
}

private struct LLMForm: View {
    @Binding var config: LLMConfig
    let account: String
    let intro: String

    var body: some View {
        Form {
            Section { Text(intro).font(.callout).foregroundStyle(.secondary) }
            LLMFields(config: $config, account: account, allowMock: true)
        }
        .formStyle(.grouped)
    }
}

struct LLMFields: View {
    @Binding var config: LLMConfig
    let account: String
    let allowMock: Bool
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?
    @State private var advanced = false

    private var preset: ProviderPreset { ProviderPreset.match(config) }

    var body: some View {
        Section {
            Picker("服务", selection: Binding(get: { preset.id }, set: apply)) {
                ForEach(ProviderPreset.all.filter { allowMock || $0.id != "mock" }) { p in Text(p.name).tag(p.id) }
            }
            if !preset.note.isEmpty {
                Text(preset.note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { key = model.apiKey(account) }
        if config.provider != .mock {
            Section {
                TextField("接口地址", text: $config.baseURL, prompt: Text("https://…/v1"))
                TextField("模型名", text: $config.model, prompt: Text("例如 deepseek-chat"))
                SecureField("API Key", text: $key, prompt: Text(preset.needsKey ? "必填" : "本地模型可以不填"))
                    .onChange(of: key) { old, v in if old != v && v != model.apiKey(account) { model.setAPIKey(account, v) } }
            } footer: {
                Text("API Key 保存在 macOS 钥匙串里。也可以不填，改用环境变量 JUBENSHA_API_KEY。")
            }
            Section {
                HStack {
                    Button(testing ? "测试中…" : "测试连接") { Task { await test() } }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? .green : .red).font(.callout).textSelection(.enabled)
                }
            }
            Section(isExpanded: $advanced) {
                LabeledContent("温度 \(config.temperature, specifier: "%.1f")") {
                    Slider(value: $config.temperature, in: 0...1.5, step: 0.1)
                }
                Stepper("超时：\(Int(config.timeout)) 秒", value: $config.timeout, in: 30...1200, step: 30)
                Stepper("单次最多输出：\(config.maxTokens) tokens", value: $config.maxTokens, in: 200...8000, step: 100)
                TextField("附加参数（JSON）", text: $config.extraBody, prompt: Text("{\"enable_thinking\": false}"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("高级")
            }
        }
    }

    private func apply(_ id: String) {
        guard let p = ProviderPreset.all.first(where: { $0.id == id }) else { return }
        result = nil
        if p.id == "mock" { config.provider = .mock; return }
        config.provider = .openai
        if p.id != "custom" {
            config.baseURL = p.baseURL
            if !p.model.isEmpty || config.model.isEmpty { config.model = p.model }
        }
        if p.id == "ollama" || p.id == "lmstudio" { config.timeout = max(config.timeout, 600) }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let llm = try LLM(config, apiKey: key)
            let reply = try await llm.ping()
            result = (true, "连接成功，AI 回复：\(reply.prefix(40))")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}

private struct GameSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("旁白方式", selection: $model.settings.game.narration) {
                    Text("AI 润色后念").tag(GameSettings.NarrationMode.ai)
                    Text("原文照念（最稳，不会说错）").tag(GameSettings.NarrationMode.verbatim)
                }
            } footer: { Text("新开局时的默认值。游戏中也可以在主持台工具栏随时切换。") }
            Section {
                Stepper("最近 \(model.settings.game.keepRecent) 条公开事件原样给 AI", value: $model.settings.game.keepRecent, in: 10...100, step: 5)
                Stepper("每攒 \(model.settings.game.summarizeBatch) 条压缩一次进摘要", value: $model.settings.game.summarizeBatch, in: 5...60, step: 5)
                Stepper("每人最近 \(model.settings.game.privateKeep) 条私聊原样给 AI", value: $model.settings.game.privateKeep, in: 4...40, step: 2)
            } header: { Text("记忆") } footer: {
                Text("每次调用 AI 都重新拼一份长度固定的上下文：剧本 + 摘要 + 最近事件，所以玩十个小时也不会超出上下文。")
            }
            Section {
                TextField("手机连接端口", value: $model.settings.port, format: .number.grouping(.never))
            } header: { Text("网络") } footer: {
                Text("端口被占用时会自动往后找一个空闲的。第一次开局时 macOS 可能会问是否允许接受传入连接，请点“允许”，否则手机连不上。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoiceForm: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var narrator: Narrator
    @State private var key = ""
    @State private var sample: URL?
    @State private var voiceName = "yachiyo"
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?
    @State private var voices: [QwenTTS.VoiceInfo] = []
    @State private var presetNote: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("大屏语音朗读 DM 的话", isOn: $narrator.enabled)
                Picker("声音", selection: $model.settings.voice.engine) {
                    Text("系统自带语音（离线）").tag(VoiceSettings.Engine.system)
                    Text("本机 Qwen3-TTS 克隆音色（免费、离线）").tag(VoiceSettings.Engine.local)
                    Text("阿里云 Qwen 克隆音色（联网、按字收费）").tag(VoiceSettings.Engine.qwen)
                }
                Button("试听") { narrator.preview("各位好，我是今晚的主持人。台风封岛，凶手就在你们之中。") }
                if let e = narrator.lastError, model.settings.voice.engine == .qwen {
                    Text(e).font(.caption).foregroundStyle(.orange)
                }
            }
            if model.settings.voice.engine == .local {
                LocalVoiceSection()
                PregenSection()
            } else if model.settings.voice.engine == .system {
                Section {
                    Picker("系统声音", selection: $narrator.voiceID) {
                        Text("自动（普通话）").tag("")
                        ForEach(Narrator.chineseVoices, id: \.identifier) { v in
                            Text("\(v.name) · \(v.language)\(v.quality == .enhanced || v.quality == .premium ? " · 高音质" : "")").tag(v.identifier)
                        }
                    }
                    LabeledContent("语速") {
                        Slider(value: $narrator.rate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                    }
                } footer: {
                    Text("想要更自然的声音：系统设置 › 辅助功能 › 朗读内容 › 系统声音 › 管理声音，下载“婷婷（高音质）”等中文声音。")
                }
            } else {
                Section {
                    SecureField("阿里云百炼 API Key", text: $key, prompt: Text("sk-…"))
                        .onChange(of: key) { o, v in if o != v && v != model.apiKey("dashscope") { model.setAPIKey("dashscope", v) } }
                    Picker("地区", selection: $model.settings.voice.region) {
                        Text("中国（北京）").tag(VoiceSettings.Region.cn)
                        Text("国际（新加坡）").tag(VoiceSettings.Region.intl)
                    }
                    TextField("音色 ID", text: $model.settings.voice.voice, prompt: Text("qwen-tts-vc-…"))
                    Button("使用 yachiyo 项目里的八千代音色") {
                        model.settings.voice.voice = VoiceSettings.yachiyoProjectVoice
                        model.settings.voice.model = "qwen3-tts-vc-2026-01-22"
                        model.settings.voice.region = .intl
                        model.settings.voice.language = "Chinese"
                        presetNote = "已填入 yachiyo-qwen-voice-reply 项目里的音色 ID（国际站）。填好百炼 Key 后点上面的“试听”。如果提示音色不存在，说明这个音色只能在作者的账号里用，需要在下面用你自己的录音创建一个。"
                    }
                    Picker("说话语言", selection: $model.settings.voice.language) {
                        Text("中文").tag("Chinese"); Text("日语").tag("Japanese"); Text("英语").tag("English")
                    }
                    TextField("合成模型", text: $model.settings.voice.model)
                    if let n = presetNote {
                        Label(n, systemImage: "info.circle.fill").foregroundStyle(.secondary).font(.callout)
                    }
                } header: { Text("百炼账号") } footer: {
                    Text("在阿里云百炼控制台（bailian.console.aliyun.com）开通服务、创建 API Key。Key 和地区要对应：国内账号选中国，国际站账号选国际。Key 保存在 macOS 钥匙串里。AI 主持如果用的是通义千问，这里可以不填，会自动借用那个 Key。")
                }
                Section {
                    LabeledContent("样本音频") {
                        HStack {
                            Text(sample?.lastPathComponent ?? "未选择").foregroundStyle(.secondary).lineLimit(1)
                            Button("选择…") { pickSample() }
                        }
                    }
                    TextField("音色名字", text: $voiceName)
                    HStack {
                        Button(busy ? "创建中…" : "创建克隆音色") { Task { await enroll() } }
                            .disabled(busy || sample == nil || model.dashscopeKey.isEmpty)
                        Button("查询我的音色") { Task { await listVoices() } }.disabled(busy || model.dashscopeKey.isEmpty)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let m = message {
                        Label(m.text, systemImage: m.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(m.ok ? .green : .red).font(.callout).textSelection(.enabled)
                    }
                    ForEach(voices) { v in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(v.name.isEmpty ? v.id : v.name)
                                Text(v.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("使用") {
                                model.settings.voice.voice = v.id
                                if !v.model.isEmpty { model.settings.voice.model = v.model }
                            }
                        }
                    }
                } header: { Text("创建八千代的音色") } footer: {
                    Text("音色 ID 只在创建它的账号里能用，别人项目里的 ID 换成你的 Key 一般用不了，所以要用你自己的账号创建一次：准备一段 10~20 秒、清晰、没有背景音乐、只有一个人说话的八千代台词录音（wav/mp3/m4a，小于 10MB），选好后点“创建克隆音色”，成功后音色 ID 会自动填好。克隆音色请仅用于个人娱乐。")
                }
                PregenSection()
            }
        }
        .formStyle(.grouped)
        .onAppear { key = model.apiKey("dashscope") }
    }

    private func pickSample() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.message = "选择 10~20 秒的样本录音"
        if p.runModal() == .OK { sample = p.url }
    }

    private func enroll() async {
        guard let sample else { return }
        busy = true; defer { busy = false }
        do {
            let id = try await QwenTTS.enroll(audio: sample, name: voiceName.isEmpty ? "yachiyo" : voiceName,
                                              cfg: model.settings.voice, key: model.dashscopeKey)
            model.settings.voice.voice = id
            message = (true, "创建成功，音色 ID 已填好。点“试听”听听看。")
        } catch {
            message = (false, error.localizedDescription)
        }
    }

    private func listVoices() async {
        busy = true; defer { busy = false }
        do {
            voices = try await QwenTTS.list(cfg: model.settings.voice, key: model.dashscopeKey)
            message = voices.isEmpty ? (false, "这个账号里还没有克隆音色") : nil
        } catch {
            message = (false, error.localizedDescription)
        }
    }
}

// MARK: - DM 形象（Live2D）

private struct AvatarForm: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var narrator: Narrator
    @State private var status: Live2DStatus = .idle
    @State private var dropping = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Form {
                Section {
                    Toggle("在大屏上显示 DM 形象", isOn: $model.settings.avatar.enabled)
                } footer: {
                    Text("导入 Live2D 模型（Cubism 3/4/5，文件夹里有 .model3.json），它会站在大屏字幕旁边，DM 说话时跟着动嘴，换阶段时做个动作。")
                }
                Section("模型") {
                    if model.avatarModels.isEmpty {
                        Text("还没有导入模型").foregroundStyle(.secondary)
                    }
                    ForEach(model.avatarModels) { m in
                        HStack(spacing: 10) {
                            Button { model.settings.avatar.model = m.name } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: model.settings.avatar.model == m.name ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(model.settings.avatar.model == m.name ? Color.accentColor : .secondary)
                                    Text(m.name)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("使用模型 \(m.name)")
                            Button { model.deleteAvatar(m.name) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("移到废纸篓")
                        }
                    }
                    HStack {
                        Button("导入 Live2D 模型…") { pick() }
                        Button("打开模型文件夹") { NSWorkspace.shared.open(Live2D.modelsDir) }
                    }
                }
                Section("位置") {
                    Picker("站在", selection: $model.settings.avatar.side) {
                        Text("字幕左边").tag(AvatarSettings.Side.left)
                        Text("字幕右边").tag(AvatarSettings.Side.right)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("取景") {
                        HStack {
                            Button("全身") { frame(1, 0) }
                            Button("半身") { frame(1.8, 0.42) }
                            Button("特写") { frame(3.4, 1.05) }
                        }
                    }
                    LabeledContent("大小") { Slider(value: $model.settings.avatar.scale, in: 0.4...4) }
                    LabeledContent("左右") { Slider(value: $model.settings.avatar.offsetX, in: -0.5...0.5) }
                    LabeledContent("上下") { Slider(value: $model.settings.avatar.offsetY, in: -0.5...1.5) }
                    Toggle("左右镜像", isOn: $model.settings.avatar.mirror)
                    Button("恢复默认位置") {
                        model.settings.avatar.scale = 1; model.settings.avatar.offsetX = 0
                        model.settings.avatar.offsetY = 0; model.settings.avatar.mirror = false
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)
            preview
        }
        .onAppear { model.reloadAvatars() }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.ink)
                RadialGradient(colors: [Theme.brass.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.62), startRadius: 0, endRadius: 200)
                if model.avatarModel != nil {
                    Live2DView(model: model.avatarModel, config: model.settings.avatar, events: narrator.avatar) { status = $0 }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.artframe").font(.system(size: 40, weight: .light))
                        Text("把模型文件夹拖到这里").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
                VStack {
                    Spacer()
                    switch status {
                    case .downloadingCore: Label("正在下载 Live2D 运行库…", systemImage: "arrow.down.circle").font(.caption)
                    case .loading: ProgressView().controlSize(.small)
                    case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).padding(8)
                    default: EmptyView()
                    }
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropping ? Color.accentColor : Theme.line, lineWidth: dropping ? 2 : 1))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.importAvatar(url) } }
                }
                return true
            }
            HStack {
                Button("试试说话") { narrator.preview("各位好，我是今晚的主持人。台风封岛，凶手就在你们之中。") }
                Button("做个动作") { narrator.avatar.send(.motion) }
            }
            .disabled(model.avatarModel == nil)
            if case .ready(let exprs) = status, !exprs.isEmpty {
                HStack(spacing: 6) {
                    Text("表情").font(.caption).foregroundStyle(.secondary)
                    ForEach(exprs, id: \.self) { e in
                        Button(e) { narrator.avatar.send(.expression(e)) }.controlSize(.small)
                    }
                    Button("还原") { narrator.avatar.send(.mood("neutral")) }.controlSize(.small)
                }
            }
            if model.importingAvatar {
                HStack { ProgressView().controlSize(.small); Text("正在导入（大贴图会缩到 4K）…").font(.caption) }
            }
            Text("Live2D 运行库（Cubism Core）由 Live2D 官方提供，第一次使用时自动下载。模型的版权归原作者，请遵守模型的使用条款。")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
    }

    private func frame(_ scale: Double, _ y: Double) {
        withAnimation {
            model.settings.avatar.scale = scale
            model.settings.avatar.offsetY = y
            model.settings.avatar.offsetX = 0
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.json, .zip, .folder]
        p.message = "选择 Live2D 模型文件夹、.model3.json 文件或 .zip 压缩包"
        p.prompt = "导入"
        if p.runModal() == .OK, let u = p.url { model.importAvatar(u) }
    }
}

/// 提前生成整本剧本的语音，存到本机
private struct PregenSection: View {
    @Environment(AppModel.self) private var model
    @State private var scriptID = ""
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var errors: [String] = []
    @State private var task: Task<Void, Never>?
    @State private var refresh = 0

    private var entries: [ScriptEntry] { model.library.filter { $0.script != nil } }
    private var script: Script? { (entries.first { $0.id == scriptID } ?? entries.first)?.script }
    private var lines: [String] { script.map(VoicePregen.lines) ?? [] }

    var body: some View {
        let cfg = model.settings.voice
        let cached = lines.filter { VoiceCache.has($0, cfg) }.count
        let usage = VoiceCache.usage
        Section {
            Picker("剧本", selection: Binding(get: { scriptID.isEmpty ? (entries.first?.id ?? "") : scriptID }, set: { scriptID = $0 })) {
                ForEach(entries) { e in Text(e.title).tag(e.id) }
            }
            LabeledContent("主持词") {
                Text("\(lines.count) 句 · \(VoicePregen.estimate(lines, cfg)) · 已保存 \(cached) 句").foregroundStyle(.secondary)
            }
            .id(refresh)
            HStack {
                if running {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
                    Text("\(done)/\(total)").font(.caption.monospacedDigit())
                    Button("停止") { task?.cancel() }
                } else {
                    Button(cached == lines.count && !lines.isEmpty ? "已全部保存" : "生成并保存到本机") { start() }
                        .disabled(!cfg.usable || (cfg.engine == .qwen && model.dashscopeKey.isEmpty) || lines.isEmpty || cached == lines.count)
                }
                Spacer()
                Button("打开语音文件夹") { NSWorkspace.shared.open(VoiceCache.dir) }
            }
            if !errors.isEmpty {
                Text("有 \(errors.count) 句失败（下次再点会重试）：\(errors.last ?? "")").font(.caption).foregroundStyle(.red)
            }
            LabeledContent("本机已保存") {
                HStack {
                    Text("\(usage.files) 句 · \(ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file))").foregroundStyle(.secondary)
                    Button("清空") { VoiceCache.clear(); refresh += 1 }.disabled(usage.files == 0 || running)
                }
            }
        } header: { Text("提前生成并保存到本机") } footer: {
            Text("把整本剧本的主持词用上面的音色一次性生成好，存成音频文件放在本机。之后开局直接播放本机文件：不用等网络、也不会重复花钱。剧本用“原文照念”时最合适（AI 临场回答的话还是实时合成）。换了音色 ID 需要重新生成。")
        }
    }

    private func start() {
        let ls = lines, cfg = model.settings.voice, key = model.dashscopeKey
        running = true; done = 0; total = ls.filter { !VoiceCache.has($0, cfg) }.count; errors = []
        task = Task {
            await VoicePregen.run(ls, cfg: cfg, key: key) { n, _, err in
                Task { @MainActor in
                    done = n
                    if let err { errors.append(err) }
                }
            }
            running = false
            refresh += 1
        }
    }
}

/// 本机 Qwen3-TTS：选音色、试听
private struct LocalVoiceSection: View {
    @Environment(AppModel.self) private var model
    @State private var voices: [String] = []
    @State private var busy: String?
    @State private var error: String?
    @State private var player = ClipPlayer()

    static let sample = "各位侦探，欢迎来到六角馆。我是今晚的主持人，八千代。"

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent("状态") {
                Text(LocalTTS.isInstalled ? "已安装 \(LocalTTS.modelName)" : "还没安装（需要 Python 环境和模型）")
                    .foregroundStyle(LocalTTS.isInstalled ? Color.green : .orange)
            }
            if voices.isEmpty {
                Text("还没有本机音色。").foregroundStyle(.secondary)
            }
            ForEach(voices, id: \.self) { v in
                HStack {
                    Button {
                        model.settings.voice.localVoice = v
                    } label: {
                        HStack {
                            Image(systemName: model.settings.voice.localVoice == v ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.settings.voice.localVoice == v ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(v)
                                    if LocalTTS.isTuned(v) {
                                        Text("已调校").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                                    }
                                }
                                Text(refText(v)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("使用本机音色 \(v)")
                    if busy == v { ProgressView().controlSize(.small) }
                    Button("原声") { play(LocalTTS.voicesDir.appendingPathComponent(v).appendingPathComponent("ref.wav")) }
                    Button("试听中文") { Task { await preview(v) } }.disabled(busy != nil || !LocalTTS.isUsable(v))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("刷新") { voices = LocalTTS.voices() }
                Button("打开本机语音文件夹") { NSWorkspace.shared.open(LocalTTS.root) }
            }
        } header: { Text("本机音色") } footer: {
            Text("用 Qwen3-TTS 在这台 Mac 上合成（Apple 芯片），不联网、不花钱。音色是从一段 10 秒左右的原声克隆的：“原声”可以听参考录音，“试听中文”让她用这个音色说一句中文（第一次要加载模型，十几秒）。克隆音色请仅用于个人娱乐。")
        }
        .onAppear {
            voices = LocalTTS.voices()
            if model.settings.voice.localVoice.isEmpty,
               let v = voices.first(where: LocalTTS.isTuned) ?? voices.first(where: { $0.hasSuffix("综合") }) ?? voices.first {
                model.settings.voice.localVoice = v
            }
        }
    }

    private func refText(_ v: String) -> String {
        (try? String(contentsOf: LocalTTS.voicesDir.appendingPathComponent(v).appendingPathComponent("ref.txt"), encoding: .utf8)) ?? ""
    }

    private func play(_ url: URL) {
        guard let d = try? Data(contentsOf: url) else { return }
        Task { await player.play(d) }
    }

    private func preview(_ v: String) async {
        busy = v; error = nil
        defer { busy = nil }
        var cfg = model.settings.voice
        cfg.engine = .local
        cfg.localVoice = v
        do {
            let d = try await VoiceCache.synthesize(Self.sample, cfg: cfg, key: "")
            await player.play(d)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
