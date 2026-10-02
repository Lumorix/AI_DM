import SwiftUI

/// 首页：剧本库
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var detail: ScriptEntry?

    var body: some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    aiStatus
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            SectionLabel("剧本库")
                            Spacer()
                            Button { model.reloadLibrary() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                                .buttonStyle(.inkGhost)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 330, maximum: 460), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                            ForEach(model.library) { e in
                                ScriptCard(entry: e, onDetail: { detail = e })
                            }
                            importCard
                        }
                    }
                    footer
                }
                .padding(.horizontal, 44).padding(.vertical, 36)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $detail) { e in IssuesSheet(entry: e) }
        .onAppear { model.reloadLibrary() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Theme.red)
                Text("杀").font(Theme.serif(34, .bold)).foregroundStyle(Theme.paper)
            }
            .frame(width: 62, height: 62)
            .rotationEffect(.degrees(-4))
            .shadow(color: Theme.red.opacity(0.5), radius: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 剧本杀").font(Theme.serif(38, .bold)).foregroundStyle(Theme.bright)
                Text("让 AI 当主持人 · 大屏投到电视 · 每人用手机扫码入座").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { openWindow(id: "import") } label: { Label("导入扫描剧本", systemImage: "doc.viewfinder") }
                .buttonStyle(.ink(.secondary, large: true))
            Button { pickFolder(model) } label: { Label("打开剧本文件夹", systemImage: "folder") }
                .buttonStyle(.ink(.secondary, large: true))
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.ink(.secondary, large: true)).help("设置")
        }
    }

    private var aiStatus: some View {
        let mock = model.settings.llm.provider == .mock
        return HStack(spacing: 12) {
            Image(systemName: mock ? "exclamationmark.triangle" : "brain")
                .foregroundStyle(mock ? Theme.amber : Theme.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text(mock ? "现在是模拟模式：不接 AI，只能熟悉流程" : "AI 主持：\(model.settings.llm.model)")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(mock ? "在设置里选 DeepSeek / 通义千问 / Claude 或本地 Ollama，填上 Key 就能让 AI 主持。"
                          : model.settings.llm.baseURL + (model.settings.cheapEnabled ? " · 记忆压缩：\(model.settings.cheap.model)" : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(mock ? "接上 AI…" : "AI 设置…") { openSettings() }.buttonStyle(mock ? .inkPrimary : .ink)
        }
        .inkCard(padding: 14)
    }

    private var importCard: some View {
        Button { openWindow(id: "import") } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus.viewfinder").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.brass)
                Text("导入你们的剧本").font(Theme.serif(18, .bold)).foregroundStyle(Theme.text)
                Text("把扫描版 PDF 拖进来：自动识别文字（苹果自带中文 OCR），AI 整理成剧本，你在表单里检查修改。")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(3)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 250)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(Theme.muted)
            Text("我的剧本保存在").foregroundStyle(Theme.muted)
            Button(Paths.scripts.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { NSWorkspace.shared.open(Paths.scripts) }
                .buttonStyle(.link)
        }
        .font(.system(size: 12))
    }
}

struct ScriptCard: View {
    let entry: ScriptEntry
    var onDetail: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var hover = false
    @State private var confirmNew = false
    @State private var confirmTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if entry.isBuiltIn { Chip(text: "示例剧本", style: .brass) }
                    Text("《\(entry.title)》").font(Theme.serif(22, .bold)).foregroundStyle(Theme.bright).lineLimit(2)
                }
                Spacer()
                menu
            }
            if let s = entry.script {
                Text(s.intro.isEmpty ? "（没有简介）" : s.intro)
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).lineSpacing(3).lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                HStack(spacing: 14) {
                    stat("person.2", "\(s.characters.count) 人")
                    stat("list.number", "\(s.phases.count) 个阶段")
                    stat("magnifyingglass", "\(s.clues.count) 条线索")
                    Spacer()
                    if entry.errorCount > 0 || entry.warningCount > 0 {
                        Button(action: onDetail) {
                            Chip(text: entry.errorCount > 0 ? "\(entry.errorCount) 个错误" : "\(entry.warningCount) 个提醒",
                                 style: entry.errorCount > 0 ? .on : .warn, icon: "exclamationmark.triangle")
                        }.buttonStyle(.plain)
                    } else {
                        Chip(text: "检查通过", style: .ok, icon: "checkmark")
                    }
                }
            } else {
                Text(entry.error ?? "").font(.system(size: 12)).foregroundStyle(Theme.rose).lineLimit(5)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            }
            Divider().overlay(Theme.line)
            HStack(spacing: 10) {
                if let save = entry.save {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("存档：第\(save.phaseIndex + 1)阶段 \(save.phaseTitle)").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text).lineLimit(1)
                        Text("\(save.players) 位玩家 · \(save.modified.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("新开一局") { confirmNew = true }.buttonStyle(.ink)
                    Button { Task { await model.start(entry, newGame: false) } } label: { Label("继续", systemImage: "play.fill") }
                        .buttonStyle(.inkPrimary)
                } else {
                    Spacer()
                    Button { Task { await model.start(entry, newGame: true) } } label: { Label("开始游戏", systemImage: "play.fill") }
                        .buttonStyle(.inkPrimary)
                }
            }
            .disabled(entry.script == nil || model.starting)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Theme.ink2, Theme.ink2.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hover ? Theme.brass.opacity(0.5) : Theme.line))
        .shadow(color: .black.opacity(hover ? 0.5 : 0.25), radius: hover ? 18 : 8, y: hover ? 8 : 3)
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.easeOut(duration: 0.18), value: hover)
        .onHover { hover = $0 }
        .confirmationDialog("新开一局？", isPresented: $confirmNew) {
            Button("新开一局（旧存档会备份）") { Task { await model.start(entry, newGame: true) } }
        } message: { Text("当前存档会改名备份在存档文件夹里，不会丢。") }
        .confirmationDialog("把《\(entry.title)》移到废纸篓？", isPresented: $confirmTrash) {
            Button("移到废纸篓", role: .destructive) { model.trash(entry) }
        }
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    private var menu: some View {
        Menu {
            if entry.isBuiltIn {
                Button("复制一份来修改") {
                    if let u = model.duplicate(entry) { openWindow(id: "editor", value: u) }
                }
            } else {
                Button("编辑剧本") { openWindow(id: "editor", value: entry.folder) }
                Button("复制一份") { model.duplicate(entry) }
            }
            Button("检查结果…", action: onDetail)
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder.appendingPathComponent("script.yaml")]) }
            if entry.save != nil {
                Divider()
                Button("删除存档") { model.deleteSave(entry) }
            }
            if !entry.isBuiltIn {
                Divider()
                if model.extraFolders.contains(entry.folder.path) {
                    Button("从剧本库移除（不删文件）") { model.removeFromLibrary(entry) }
                } else {
                    Button("移到废纸篓…", role: .destructive) { confirmTrash = true }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct IssuesSheet: View {
    let entry: ScriptEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("《\(entry.title)》检查结果").font(Theme.serif(20, .bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let e = entry.error {
                        issueRow(.error, e)
                    }
                    ForEach(entry.issues, id: \.self) { i in issueRow(i.level, i.message) }
                    if entry.error == nil && entry.issues.isEmpty {
                        Label("没有发现问题", systemImage: "checkmark.circle").foregroundStyle(Theme.mint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if !entry.isBuiltIn {
                    Button("打开编辑器") { openWindow(id: "editor", value: entry.folder); dismiss() }.buttonStyle(.ink)
                }
                Spacer()
                Button("好") { dismiss() }.buttonStyle(.inkPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
        .background(Theme.ink2)
    }

    private func issueRow(_ level: Issue.Level, _ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(level == .error ? Theme.red : Theme.amber)
            Text(msg).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }
}
