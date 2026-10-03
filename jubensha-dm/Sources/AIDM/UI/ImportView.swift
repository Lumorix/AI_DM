import SwiftUI
import UniformTypeIdentifiers

/// 导入扫描剧本：① 添加文件 → ② 识别文字 → ③ AI 整理 → 打开编辑器检查
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var vm = ImportModel()

    var body: some View {
        HStack(spacing: 0) {
            steps.frame(width: 210)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch vm.step {
                case 0: addFiles
                case 1: recognize
                default: draft
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.backdrop)
        .sheet(item: $vm.editing) { f in TextSheet(file: f) }
    }

    // MARK: 左侧步骤

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("导入扫描剧本").font(Theme.serif(20, .bold)).foregroundStyle(Theme.bright).padding(.bottom, 14)
            stepRow(0, "添加文件", "PDF、图片或图片文件夹")
            stepRow(1, "识别文字", "苹果自带中文 OCR")
            stepRow(2, "AI 整理", "生成剧本初稿")
            Spacer()
            Text("扫描件识别出的文字和缓存保存在\n~/Library/Application Support/AI DM/OCR").font(.system(size: 10.5))
                .foregroundStyle(Theme.muted).lineSpacing(2)
        }
        .padding(20)
        .background(Theme.ink2.opacity(0.6))
    }

    private func stepRow(_ i: Int, _ title: String, _ sub: String) -> some View {
        let cur = vm.step == i, done = vm.step > i
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(cur ? Theme.red : done ? Theme.green.opacity(0.4) : Theme.ink3).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                else { Text("\(i + 1)").font(.system(size: 12, weight: .semibold)) }
            }
            .foregroundStyle(cur || done ? .white : Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: cur ? .semibold : .regular)).foregroundStyle(cur ? Theme.bright : Theme.text)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: ① 添加文件

    private var addFiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("添加剧本文件", "一般一套剧本杀有：DM 手册（组织者手册）、每人一本角色本、线索卡。只有 DM 手册也可以，角色会从手册里提取。")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($vm.files) { $f in fileRow($f) }
                    dropZone
                }
            }
            HStack(spacing: 18) {
                Picker("识别方式", selection: $vm.options.engine) {
                    ForEach(OCREngine.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 330)
                Toggle("每页是左右两页（切开识别）", isOn: $vm.options.split).toggleStyle(.checkbox)
                LabeledContent("清晰度") {
                    Picker("", selection: $vm.options.dpi) {
                        Text("标准").tag(CGFloat(220)); Text("字小用这个").tag(CGFloat(300))
                    }.labelsHidden().frame(width: 110)
                }
            }
            .font(.system(size: 12.5))
            HStack {
                TextField("剧本名称", text: $vm.title).inkField().frame(width: 260)
                Spacer()
                Button {
                    vm.step = 1
                    Task { await vm.runOCR(model: model) }
                } label: { Label("开始识别", systemImage: "text.viewfinder") }
                .buttonStyle(.ink(.primary, large: true))
                .disabled(vm.files.filter { $0.role != .skip }.isEmpty || vm.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(26)
    }

    private func fileRow(_ f: Binding<ImportFile>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: f.wrappedValue.url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "photo.on.rectangle")
                .font(.system(size: 20)).foregroundStyle(Theme.brass).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.wrappedValue.url.lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(f.wrappedValue.pages) 页").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Picker("", selection: f.role) {
                ForEach(ImportFile.Role.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 120)
            if f.wrappedValue.role == .character {
                TextField("角色名", text: f.charName).inkField().frame(width: 110)
            }
            Button { vm.files.removeAll { $0.id == f.wrappedValue.id } } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(Theme.ink2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    @State private var dropping = false

    private var dropZone: some View {
        Button { pickFiles() } label: {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.brass)
                Text("把扫描版 PDF 拖到这里，或点击选择文件").font(.system(size: 13)).foregroundStyle(Theme.text)
                Text("支持 PDF、图片、装满图片的文件夹").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(dropping ? Theme.brass : Theme.line,
                                                                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { vm.add(url) } }
                }
            }
            return true
        }
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf, .image, .folder]
        if p.runModal() == .OK { p.urls.forEach(vm.add) }
    }

    // MARK: ② 识别文字

    private var recognize: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("识别文字", vm.ocrRunning ? "正在识别……识别过的页会缓存，中途关掉下次会接着做。" : "识别完成。建议点“查看/修改”扫一眼，人名、时间识别错的顺手改掉。")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(vm.files.filter { $0.role != .skip }) { f in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(f.url.lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                                Chip(text: f.role == .character ? "角色本·\(f.charName)" : f.role.label, style: .brass)
                                Spacer()
                                if f.textURL != nil {
                                    Button("查看/修改文字") { vm.editing = f }.buttonStyle(.ink)
                                }
                            }
                            ProgressView(value: Double(f.done), total: Double(max(f.pages, 1))).tint(f.failed == nil ? Theme.red : .orange)
                            HStack {
                                Text("\(f.done) / \(f.pages) 页 · \(f.chars) 字").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.muted)
                                if let e = f.failed { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.rose) }
                            }
                        }
                        .inkCard(padding: 14)
                    }
                    if !vm.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(vm.warnings.suffix(30), id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.amber)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                Button("上一步") { vm.cancel(); vm.step = 0 }.buttonStyle(.ink)
                Spacer()
                if vm.ocrRunning { Button("停止") { vm.cancel() }.buttonStyle(.inkDanger) }
                Button { vm.step = 2 } label: { Label("下一步：AI 整理", systemImage: "wand.and.stars") }
                    .buttonStyle(.ink(.primary, large: true)).disabled(vm.ocrRunning || !vm.allRecognized)
            }
        }
        .padding(26)
    }

    // MARK: ③ AI 整理

    private var draft: some View {
        let mock = model.settings.llm.provider == .mock
        return VStack(alignment: .leading, spacing: 16) {
            header("AI 整理成剧本", "角色本按“第X幕”自动分幕、原文照搬；DM 手册和线索卡交给 AI 提取真相、流程、主持词、搜证地点和线索、凶手、结局。生成的是初稿，之后要在编辑器里检查。")
            if mock && vm.result == nil {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber).font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI 整理需要先接上 AI").font(.system(size: 14, weight: .semibold))
                        Text("现在是模拟模式。在设置里选 DeepSeek / 通义千问 / Claude 或本地模型，填好后回来点“开始整理”。也可以跳过 AI，生成一个空白骨架自己在编辑器里填。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("打开设置") { openSettings() }.buttonStyle(.ink)
                }
                .inkCard(padding: 16)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(vm.log.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(l.contains("⚠") ? Theme.amber : Theme.text).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                .onChange(of: vm.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            HStack {
                Button("上一步") { vm.cancel(); vm.step = 1 }.buttonStyle(.ink).disabled(vm.drafting)
                Spacer()
                if let folder = vm.result {
                    Button { openWindow(id: "editor", value: folder) } label: { Label("打开剧本编辑器检查", systemImage: "square.and.pencil") }
                        .buttonStyle(.ink(.primary, large: true))
                } else {
                    Button("跳过 AI，生成空白骨架") { vm.skeleton(model: model) }.buttonStyle(.ink).disabled(vm.drafting)
                    if vm.drafting { Button("停止") { vm.cancel() }.buttonStyle(.inkDanger) }
                    Button { Task { await vm.runDraft(model: model) } } label: {
                        HStack { if vm.drafting { Spinner() }; Text(vm.drafting ? "整理中…" : "开始整理") }
                    }
                    .buttonStyle(.ink(.primary, large: true)).disabled(mock || vm.drafting)
                }
            }
        }
        .padding(26)
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.serif(24, .bold)).foregroundStyle(Theme.bright)
            Text(sub).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
    }
}

// MARK: - 数据

struct ImportFile: Identifiable, Equatable {
    enum Role: String, CaseIterable, Identifiable {
        case dm, character, clues, skip
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dm: "DM 手册"
            case .character: "角色本"
            case .clues: "线索卡"
            case .skip: "不用"
            }
        }
    }

    let id = UUID()
    let url: URL
    var role: Role
    var charName: String
    var pages: Int
    var done = 0
    var chars = 0
    var failed: String?
    var textURL: URL?
}

@MainActor @Observable
final class ImportModel {
    var files: [ImportFile] = []
    var options = OCROptions()
    var title = ""
    var step = 0
    var warnings: [String] = []
    var log: [String] = []
    var ocrRunning = false
    var drafting = false
    var result: URL?
    var editing: ImportFile?
    @ObservationIgnored private var task: Task<Void, Never>?

    var allRecognized: Bool { files.filter { $0.role != .skip }.allSatisfy { $0.textURL != nil } }

    func add(_ url: URL) {
        guard !files.contains(where: { $0.url == url }) else { return }
        let name = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let role: ImportFile.Role = name.range(of: "DM|手册|组织者|主持", options: [.regularExpression, .caseInsensitive]) != nil ? .dm
            : name.contains("线索") ? .clues : .character
        files.append(ImportFile(url: url, role: role, charName: role == .character ? name : "", pages: OCR.pageCount(url)))
        if title.isEmpty {
            title = name.replacingOccurrences(of: "(DM|组织者)?(手册|主持人手册|剧本)$", with: "", options: .regularExpression)
            if title.isEmpty { title = name }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func runOCR(model: AppModel) async {
        ocrRunning = true
        warnings = []
        let opts = options
        let llm = opts.engine == .vision ? try? model.visionLLM() : nil
        let t = Task {
            for i in files.indices where files[i].role != .skip {
                let id = files[i].id
                files[i].failed = nil
                do {
                    let out = try await OCR.run(files[i].url, options: opts, llm: llm) { p in
                        Task { @MainActor in
                            guard let k = self.files.firstIndex(where: { $0.id == id }) else { return }
                            self.files[k].done = p.done
                            self.files[k].chars += p.chars
                            if let w = p.warning { self.warnings.append("\(self.files[k].url.lastPathComponent)：\(w)") }
                        }
                    }
                    if let k = files.firstIndex(where: { $0.id == id }) { files[k].textURL = out }
                } catch is CancellationError {
                    break
                } catch {
                    if let k = files.firstIndex(where: { $0.id == id }) { files[k].failed = error.localizedDescription }
                }
            }
        }
        task = t
        await t.value
        ocrRunning = false
    }

    private func text(_ f: ImportFile) -> String {
        f.textURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private var targetFolder: URL {
        var name = title.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "新剧本" }
        var u = Paths.scripts.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: u.appendingPathComponent("script.yaml").path) {
            u = Paths.scripts.appendingPathComponent("\(name) \(n)"); n += 1
        }
        return u
    }

    func runDraft(model: AppModel) async {
        drafting = true
        log = []
        var input = DraftInput(title: title)
        let dm = files.filter { $0.role == .dm }.map(text).joined(separator: "\n\n")
        input.dm = dm.isEmpty ? nil : dm
        input.characters = files.filter { $0.role == .character }.map { ($0.charName.isEmpty ? $0.url.deletingPathExtension().lastPathComponent : $0.charName, text($0)) }
        input.clues = files.filter { $0.role == .clues }.map(text)
        let folder = targetFolder
        let t = Task {
            do {
                let llm = try model.makeLLM("main")
                _ = try await Drafter.draft(input, llm: llm, into: folder) { line in
                    Task { @MainActor in self.log.append(line) }
                }
                result = folder
                model.reloadLibrary()
            } catch is CancellationError {
                log.append("已停止。")
            } catch {
                log.append("⚠ 整理失败：\(error.localizedDescription)")
            }
        }
        task = t
        await t.value
        drafting = false
    }

    /// 不用 AI：角色本照样分幕，其余留空，自己在编辑器里填
    func skeleton(model: AppModel) {
        let folder = targetFolder
        var chars: [Character] = []
        for (n, f) in files.filter({ $0.role == .character }).enumerated() {
            chars.append(Character(id: "r\(n + 1)", name: f.charName, publicInfo: "TODO：公开简介", secretBrief: "TODO：给AI看的秘密摘要",
                                   book: Drafter.splitActs(Drafter.clean(text(f)))))
        }
        if chars.isEmpty { chars = [Character(id: "r1", name: "角色1")] }
        let acts = Set(chars.flatMap { $0.book.map(\.id) }).sorted { actNumber($0) < actNumber($1) }
        var phases = [Phase(id: "p1", title: "开场", type: .narration, dmScript: "TODO：开场主持词")]
        for (i, a) in acts.enumerated() {
            phases.append(Phase(id: "p\(phases.count + 1)", title: "阅读\(actLabel(a))", type: .reading, unlock: [a]))
            phases.append(Phase(id: "p\(phases.count + 1)", title: "第\(i + 1)轮讨论", type: .discuss))
        }
        phases.append(Phase(id: "p\(phases.count + 1)", title: "投票", type: .vote))
        phases.append(Phase(id: "p\(phases.count + 1)", title: "真相复盘", type: .reveal))
        let dm = files.filter { $0.role == .dm }.map { Drafter.clean(text($0)) }.joined(separator: "\n\n")
        let s = Script(folder: folder, title: title, intro: "TODO：一句话简介", players: chars.count,
                       truth: dm.isEmpty ? "TODO：完整真相" : "TODO：从下面的 DM 手册原文里整理出完整真相\n\n" + dm.prefix(20000),
                       characters: chars, phases: phases)
        do {
            try ScriptIO.save(s, to: folder)
            result = folder
            log.append("已生成空白骨架：\(folder.lastPathComponent)。点右下角打开编辑器填写。")
            model.reloadLibrary()
        } catch {
            log.append("⚠ 保存失败：\(error.localizedDescription)")
        }
    }
}

/// 查看/修改识别出的文字
private struct TextSheet: View {
    let file: ImportFile
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.url.lastPathComponent).font(Theme.serif(18, .bold))
            TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(8).background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("\(text.count) 字").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    if let u = file.textURL { try? text.write(to: u, atomically: true, encoding: .utf8) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .background(Theme.ink2)
        .onAppear { text = file.textURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }
    }
}
