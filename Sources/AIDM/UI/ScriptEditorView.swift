import SwiftUI

/// 剧本编辑器：用表单改剧本，不用碰 YAML。保存时写回 script.yaml，右侧随时显示检查结果。
struct ScriptEditorView: View {
    let folder: URL
    @Environment(AppModel.self) private var model
    @State private var script: Script?
    @State private var saved: Script?
    @State private var loadError: String?
    @State private var section: Section? = .overview
    @State private var showIssues = true
    @State private var toast: String?

    enum Section: Hashable {
        case overview, endings
        case character(UUID)
        case clue(UUID)
        case phase(UUID)
    }

    private var readOnly: Bool { folder.standardizedFileURL.path.hasPrefix(Paths.demo.standardizedFileURL.path) }
    private var dirty: Bool { script != saved }

    var body: some View {
        Group {
            if let err = loadError {
                ContentUnavailableView("打不开这个剧本", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if script != nil {
                editor
            } else {
                ProgressView()
            }
        }
        .navigationTitle(script.map { "编辑《\($0.title)》" } ?? "编辑剧本")
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let s = try ScriptIO.load(folder)
            script = s; saved = s
        } catch {
            // 有错误的剧本也要能打开来修：先尽量读出来
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard let s = script else { return }
        do {
            try ScriptIO.save(s, to: folder)
            saved = s
            model.reloadLibrary()
            flash("已保存")
        } catch {
            flash("保存失败：\(error.localizedDescription)")
        }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if toast == s { toast = nil } } }
    }

    private var editor: some View {
        let binding = Binding(get: { script! }, set: { script = $0 })
        let issues = ScriptIO.validate(script!)
        return NavigationSplitView {
            sidebar(binding)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            HStack(spacing: 0) {
                ScrollView {
                    detail(binding)
                        .padding(24)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showIssues {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    IssuesPanel(issues: issues).frame(width: 280)
                }
            }
            .background(Theme.ink)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if readOnly {
                    Text("示例剧本只读，请在剧本库“复制一份来修改”").font(.caption).foregroundStyle(.secondary)
                }
                Button { showIssues.toggle() } label: {
                    Label("检查", systemImage: issues.contains { $0.level == .error } ? "exclamationmark.octagon" : "checkmark.seal")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("script.yaml")]) } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                Button { save() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s").disabled(!dirty || readOnly)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.8), in: Capsule()).padding(20)
            }
        }
    }

    // MARK: 侧栏

    private func sidebar(_ s: Binding<Script>) -> some View {
        List(selection: $section) {
            Label("基本信息与真相", systemImage: "doc.text").tag(Section.overview)
            Label("结局", systemImage: "flag.checkered").tag(Section.endings)
            SwiftUI.Section {
                ForEach(s.wrappedValue.characters, id: \.uid) { c in
                    Label(c.name.isEmpty ? "（未命名）" : c.name, systemImage: "person").tag(Section.character(c.uid))
                }
                .onMove { s.wrappedValue.characters.move(fromOffsets: $0, toOffset: $1) }
                Button { addCharacter(s) } label: { Label("添加角色", systemImage: "plus") }.buttonStyle(.borderless)
            } header: { Text("角色 \(s.wrappedValue.characters.count)") }
            SwiftUI.Section {
                ForEach(Array(s.wrappedValue.phases.enumerated()), id: \.element.uid) { i, p in
                    Label("\(i + 1). \(p.title)", systemImage: p.type.symbol).tag(Section.phase(p.uid))
                }
                .onMove { s.wrappedValue.phases.move(fromOffsets: $0, toOffset: $1) }
                Button { addPhase(s) } label: { Label("添加阶段", systemImage: "plus") }.buttonStyle(.borderless)
            } header: { Text("流程 \(s.wrappedValue.phases.count) 个阶段") }
            SwiftUI.Section {
                ForEach(s.wrappedValue.clues, id: \.uid) { c in
                    Label("\(c.id) \(c.title)", systemImage: "doc.text.magnifyingglass").tag(Section.clue(c.uid))
                }
                .onMove { s.wrappedValue.clues.move(fromOffsets: $0, toOffset: $1) }
                Button { addClue(s) } label: { Label("添加线索", systemImage: "plus") }.buttonStyle(.borderless)
            } header: { Text("线索 \(s.wrappedValue.clues.count)") }
        }
        .listStyle(.sidebar)
    }

    private func nextID(_ prefix: String, _ existing: [String]) -> String {
        var n = existing.count + 1
        while existing.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    private func addCharacter(_ s: Binding<Script>) {
        let c = Character(id: nextID("r", s.wrappedValue.characters.map(\.id)), name: "新角色")
        s.wrappedValue.characters.append(c)
        section = .character(c.uid)
    }

    private func addPhase(_ s: Binding<Script>) {
        let p = Phase(id: nextID("p", s.wrappedValue.phases.map(\.id)), title: "新阶段", type: .discuss)
        s.wrappedValue.phases.append(p)
        section = .phase(p.uid)
    }

    private func addClue(_ s: Binding<Script>) {
        let c = Clue(id: nextID("c", s.wrappedValue.clues.map(\.id)), title: "新线索", text: "")
        s.wrappedValue.clues.append(c)
        section = .clue(c.uid)
    }

    // MARK: 详情

    @ViewBuilder
    private func detail(_ s: Binding<Script>) -> some View {
        switch section {
        case .overview, nil: OverviewForm(script: s)
        case .endings: EndingsForm(script: s)
        case .character(let id):
            if let i = s.wrappedValue.characters.firstIndex(where: { $0.uid == id }) {
                CharacterForm(c: s.characters[i], allActs: s.wrappedValue.allActs) {
                    s.wrappedValue.characters.remove(at: i); section = .overview
                }
            }
        case .clue(let id):
            if let i = s.wrappedValue.clues.firstIndex(where: { $0.uid == id }) {
                ClueForm(c: s.clues[i], folder: folder) { s.wrappedValue.clues.remove(at: i); section = .overview }
            }
        case .phase(let id):
            if let i = s.wrappedValue.phases.firstIndex(where: { $0.uid == id }) {
                PhaseForm(p: s.phases[i], script: s.wrappedValue) { s.wrappedValue.phases.remove(at: i); section = .overview }
            }
        }
    }
}

// MARK: - 表单部件

private struct Field<Content: View>: View {
    let title: String
    var hint: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                if !hint.isEmpty { Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            content
        }
    }
}

private struct FormTitle: View {
    let title: String
    var sub = ""
    var onDelete: (() -> Void)? = nil
    @State private var confirm = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.serif(26, .bold)).foregroundStyle(Theme.bright)
                if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            Spacer()
            if let onDelete {
                Button("删除", role: .destructive) { confirm = true }.buttonStyle(.inkDanger)
                    .confirmationDialog("确定删除？", isPresented: $confirm) { Button("删除", role: .destructive, action: onDelete) }
            }
        }
        .padding(.bottom, 6)
    }
}

/// 逗号/顿号分隔的列表
private func listBinding(_ b: Binding<[String]>) -> Binding<String> {
    Binding(get: { b.wrappedValue.joined(separator: "，") },
            set: { b.wrappedValue = $0.split(whereSeparator: { "，,、 \n".contains($0) }).map(String.init) })
}

private struct OverviewForm: View {
    @Binding var script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormTitle(title: "基本信息与真相", sub: "真相和禁用词只给 AI 看，玩家看不到。")
            HStack(spacing: 16) {
                Field(title: "剧本名") { TextField("", text: $script.title).inkField() }
                Field(title: "人数") { TextField("", value: $script.players, format: .number).inkField().frame(width: 80) }
            }
            Field(title: "一句话简介", hint: "所有人可见，显示在选角色页面和大屏上") {
                InkEditor(text: $script.intro, minHeight: 50)
            }
            Field(title: "完整真相", hint: "AI 回答问题、最后复盘全靠它。复盘前绝不会直接说出来") {
                InkEditor(text: $script.truth, minHeight: 220)
            }
            Field(title: "主持风格") { InkEditor(text: $script.style, minHeight: 70) }
            Field(title: "旁白方式", hint: "原文照念：DM 一字不改地念主持词（文字精心写过的剧本推荐）；AI 润色：AI 改得更口语、有氛围") {
                Picker("", selection: Binding(get: { script.narration?.rawValue ?? "" },
                                             set: { script.narration = GameSettings.NarrationMode(rawValue: $0) })) {
                    Text("跟随设置").tag("")
                    Text("原文照念").tag("verbatim")
                    Text("AI 润色").tag("ai")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            Field(title: "防剧透禁用词", hint: "用逗号分隔。AI 的回复里出现这些说法会被拦截重答。写成“说法@阶段id”表示到那个阶段才解禁") {
                InkEditor(text: listBinding($script.forbidden), minHeight: 50)
            }
            Field(title: "从哪个阶段开始可以说出真相", hint: "默认是第一个“复盘”阶段") {
                Picker("", selection: Binding(get: { script.forbiddenUntil ?? "" }, set: { script.forbiddenUntil = $0.isEmpty ? nil : $0 })) {
                    Text("默认（复盘阶段）").tag("")
                    ForEach(script.phases, id: \.uid) { p in Text("\(p.id) · \(p.title)").tag(p.id) }
                }
                .labelsHidden().frame(width: 320)
            }
        }
    }
}

private struct EndingsForm: View {
    @Binding var script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormTitle(title: "结局", sub: "复盘时 AI 会念出结局。")
            Field(title: "投对凶手（或没有投票时）的结局") {
                InkEditor(text: Binding(get: { script.endings["correct"] ?? "" }, set: { script.endings["correct"] = $0 }), minHeight: 120)
            }
            Field(title: "投错凶手的结局") {
                InkEditor(text: Binding(get: { script.endings["wrong"] ?? "" }, set: { script.endings["wrong"] = $0 }), minHeight: 120)
            }
        }
    }
}

private struct CharacterForm: View {
    @Binding var c: Character
    let allActs: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormTitle(title: c.name.isEmpty ? "角色" : c.name, sub: "角色本按幕分开，阶段里“解锁”某一幕后玩家手机上才看得到。", onDelete: onDelete)
            HStack(spacing: 16) {
                Field(title: "名字") { TextField("", text: $c.name).inkField() }
                Field(title: "id", hint: "英文/拼音，投票答案等处引用") { TextField("", text: $c.id).inkField().frame(width: 160) }
            }
            Field(title: "公开简介", hint: "所有人可见") { InkEditor(text: $c.publicInfo, minHeight: 60) }
            Field(title: "秘密摘要", hint: "只给 AI：隐瞒了什么、真实行踪、是否凶手") { InkEditor(text: $c.secretBrief, minHeight: 90) }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("角色本").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button { c.book.append(Act(id: "act\((c.book.map { actNumber($0.id) }.filter { $0 < 999 }.max() ?? 0) + 1)", text: "")) } label: {
                        Label("添加一幕", systemImage: "plus")
                    }.buttonStyle(.ink)
                }
                ForEach($c.book, id: \.uid) { $a in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("幕 id", text: $a.id).inkField().frame(width: 140)
                            Text(actLabel(a.id)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button { c.book.removeAll { $0.uid == a.uid } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        InkEditor(text: $a.text, minHeight: 160, font: Theme.serif(14))
                    }
                    .inkCard(padding: 12)
                }
            }
        }
    }
}

private struct ClueForm: View {
    @Binding var c: Clue
    let folder: URL
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormTitle(title: c.title.isEmpty ? "线索" : c.title, onDelete: onDelete)
            HStack(spacing: 16) {
                Field(title: "标题") { TextField("", text: $c.title).inkField() }
                Field(title: "id") { TextField("", text: $c.id).inkField().frame(width: 120) }
            }
            Field(title: "内容") { InkEditor(text: $c.text, minHeight: 120) }
            Toggle("搜到后自动公开给所有人", isOn: $c.isPublic).toggleStyle(.switch)
            Field(title: "AI 发放条件", hint: "放在阶段的“AI 可发放线索”里时，AI 满足这个条件才给") {
                InkEditor(text: $c.condition, minHeight: 50)
            }
            Field(title: "图片", hint: "相对剧本文件夹的路径，例如 assets/c1.jpg") {
                TextField("", text: Binding(get: { c.image ?? "" }, set: { c.image = $0.isEmpty ? nil : $0 })).inkField()
            }
            ClueCard(clue: c, folder: folder).frame(maxWidth: 420)
        }
    }
}

private struct PhaseForm: View {
    @Binding var p: Phase
    let script: Script
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormTitle(title: p.title.isEmpty ? "阶段" : p.title, onDelete: onDelete)
            HStack(spacing: 16) {
                Field(title: "名字") { TextField("", text: $p.title).inkField() }
                Field(title: "id") { TextField("", text: $p.id).inkField().frame(width: 110) }
                Field(title: "建议时长（分钟）") { TextField("", value: $p.minutes, format: .number).inkField().frame(width: 90) }
            }
            Field(title: "类型") {
                Picker("", selection: $p.type) {
                    ForEach(PhaseType.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Field(title: "主持词", hint: "进入这个阶段时 DM 念给大家听（AI 润色或原文照念）") {
                InkEditor(text: $p.dmScript, minHeight: 110, font: Theme.serif(14))
            }
            Field(title: "主持提示", hint: "只给 AI 和主持人看：答案、扶车方向、注意事项") { InkEditor(text: $p.dmNotes, minHeight: 90) }
            if !script.allActs.isEmpty {
                Field(title: "解锁角色本的幕", hint: "进入这个阶段时玩家手机上出现") {
                    HStack {
                        ForEach(script.allActs, id: \.self) { a in
                            Toggle(actLabel(a), isOn: Binding(get: { p.unlock.contains(a) }, set: { on in
                                if on { p.unlock.append(a) } else { p.unlock.removeAll { $0 == a } }
                            }))
                            .toggleStyle(.button)
                        }
                    }
                }
            }
            if p.type == .search { searchEditor }
            if p.type == .vote {
                HStack(spacing: 16) {
                    Field(title: "投票问题") { TextField("", text: $p.voteQuestion).inkField() }
                    Field(title: "正确答案（凶手）") {
                        Picker("", selection: Binding(get: { p.voteAnswer ?? "" }, set: { p.voteAnswer = $0.isEmpty ? nil : $0 })) {
                            Text("不设").tag("")
                            ForEach(script.characters, id: \.uid) { c in Text(c.name).tag(c.id) }
                        }
                        .labelsHidden().frame(width: 180)
                    }
                }
            }
            Field(title: "AI 可以在问答中发放的线索", hint: "满足线索的发放条件时，AI 会把它给提问的玩家") {
                ClueChooser(selected: $p.grantable, clues: script.clues)
            }
        }
    }

    private var searchEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜证").font(.system(size: 12.5, weight: .semibold))
                Stepper("每人 \(p.searchPoints) 次", value: $p.searchPoints, in: 0...20).font(.system(size: 12))
                Spacer()
                Button {
                    p.locations.append(Location(id: "l\(p.locations.count + 1)", name: "新地点", clues: []))
                } label: { Label("添加地点", systemImage: "plus") }.buttonStyle(.ink)
            }
            ForEach($p.locations, id: \.uid) { $l in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("地点", text: $l.name).inkField()
                        TextField("id", text: $l.id).inkField().frame(width: 90)
                        Button { p.locations.removeAll { $0.uid == l.uid } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    Text("按顺序抽线索卡：").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    ClueChooser(selected: $l.clues, clues: script.clues)
                }
                .inkCard(padding: 12)
            }
        }
    }
}

/// 选线索：已选的按顺序显示成标签，点 + 加，点 × 去掉
private struct ClueChooser: View {
    @Binding var selected: [String]
    let clues: [Clue]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(selected.enumerated()), id: \.offset) { i, id in
                HStack(spacing: 4) {
                    Text("\(id) \(clues.first { $0.id == id }?.title ?? "（不存在）")").font(.system(size: 11.5))
                    Button { selected.remove(at: i) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.brass.opacity(0.15), in: Capsule())
                .foregroundStyle(clues.contains { $0.id == id } ? Theme.brass : Theme.rose)
            }
            Menu {
                ForEach(clues.filter { !selected.contains($0.id) }, id: \.uid) { c in
                    Button("\(c.id) · \(c.title)") { selected.append(c.id) }
                }
            } label: { Image(systemName: "plus.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(clues.allSatisfy { selected.contains($0.id) })
        }
    }
}

private struct IssuesPanel: View {
    let issues: [Issue]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("检查结果")
                if issues.isEmpty {
                    Label("没有发现问题", systemImage: "checkmark.circle").foregroundStyle(Theme.mint).font(.system(size: 12.5))
                }
                ForEach(issues, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: i.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(i.level == .error ? Theme.red : Theme.amber)
                        Text(i.message).font(.system(size: 12)).foregroundStyle(Theme.text).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.ink2.opacity(0.6))
    }
}
