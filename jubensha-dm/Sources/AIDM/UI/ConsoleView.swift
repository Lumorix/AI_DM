import AppKit
import SwiftUI

/// 主持台：流程控制、记录讨论、玩家、线索、AI 记忆
struct ConsoleView: View {
    let session: Session
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmEnd = false

    private var game: Game { session.game }

    var body: some View {
        HStack(spacing: 0) {
            PhaseSidebar(game: game)
                .frame(width: 256)
            Rectangle().fill(Theme.line).frame(width: 1)
            CenterColumn(game: game)
                .frame(minWidth: 480)
            Rectangle().fill(Theme.line).frame(width: 1)
            Inspector(session: session)
                .frame(width: 340)
        }
        .background(Theme.backdrop)
        .navigationTitle("《\(game.script.title)》")
        .navigationSubtitle(game.llm.label)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    game.setPaused(!game.state.aiPaused)
                } label: {
                    Label(game.state.aiPaused ? "恢复 AI" : "暂停 AI",
                          systemImage: game.state.aiPaused ? "play.circle.fill" : "pause.circle")
                }
                .help(game.state.aiPaused ? "AI 已暂停：旁白原文照念，问答暂停" : "暂停 AI（旁白改为原文照念，暂停回答问题）")

                Picker("旁白", selection: Binding(
                    get: { game.settings.narration },
                    set: { if $0 != game.settings.narration { game.toggleNarrationMode() } }
                )) {
                    Text("AI 润色").tag(GameSettings.NarrationMode.ai)
                    Text("原文照念").tag(GameSettings.NarrationMode.verbatim)
                }
                .pickerStyle(.segmented)
                .help("旁白方式：AI 润色后念，或者原文照念（最稳，不会说错）")

                Button { openWindow(id: "stage") } label: { Label("大屏", systemImage: "tv") }
                    .help("打开大屏窗口（拖到电视上，或用右边菜单直接投屏）")
                Menu {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, screen in
                        Button("全屏显示在：\(screen.localizedName)\(i == 0 ? "（主屏）" : "")") {
                            openWindow(id: "stage")
                            presentStage(on: screen)
                        }
                    }
                } label: { Label("投屏", systemImage: "rectangle.on.rectangle") }
                .help("把大屏全屏放到电视/投影上")

                Button { confirmEnd = true } label: { Label("结束", systemImage: "xmark.circle") }
                    .help("结束这局（进度已自动存档，下次可以继续）")
            }
        }
        .confirmationDialog("结束这局游戏？", isPresented: $confirmEnd) {
            Button("结束并回到剧本库") { model.endGame() }
        } message: {
            Text("进度已经自动存档。下次在剧本库点“继续”就能接着玩。手机会断开连接。")
        }
    }
}

@MainActor
func presentStage(on screen: NSScreen) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("stage") == true }) else { return }
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (w.styleMask.contains(.fullScreen) ? 0.8 : 0)) {
            w.setFrame(screen.visibleFrame, display: true)
            w.makeKeyAndOrderFront(nil)
            w.toggleFullScreen(nil)
        }
    }
}

// MARK: - 左侧：流程

private struct PhaseSidebar: View {
    let game: Game
    @State private var jumpTo: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("流程")
                Spacer()
                Text("\(game.state.phaseIndex + 1) / \(game.script.phases.count)").font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(game.script.phases.enumerated()), id: \.offset) { i, p in
                            row(i, p).id(i)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 16)
                }
                .onChange(of: game.state.phaseIndex) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
        }
        .background(Theme.ink2.opacity(0.6))
        .confirmationDialog("跳到【\(jumpTo.map { game.script.phases[$0].title } ?? "")】？",
                            isPresented: Binding(get: { jumpTo != nil }, set: { if !$0 { jumpTo = nil } })) {
            Button("跳过去并播报主持词") { if let j = jumpTo { game.goto(j, narrate: true) } }
            Button("只跳过去，不播报") { if let j = jumpTo { game.goto(j, narrate: false) } }
        }
    }

    private func row(_ i: Int, _ p: Phase) -> some View {
        let cur = i == game.state.phaseIndex
        let done = i < game.state.phaseIndex
        return Button { if !cur { jumpTo = i } } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(cur ? Theme.red : done ? Theme.ink4 : Theme.ink3).frame(width: 24, height: 24)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                    } else {
                        Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(cur ? .white : Theme.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(Theme.serif(14, cur ? .bold : .regular))
                        .foregroundStyle(cur ? Theme.bright : done ? Theme.muted : Theme.text).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: p.type.symbol)
                        Text(p.type.label + (p.minutes > 0 ? " · \(p.minutes)分钟" : ""))
                    }
                    .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(cur ? Theme.redSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cur ? Theme.red.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cur ? "当前阶段" : "点击跳到这个阶段")
    }
}

// MARK: - 中间：当前阶段 + 主持操作 + 记录

private struct CenterColumn: View {
    let game: Game
    @State private var note = ""
    @State private var say = ""
    @State private var polish = false
    @State private var showNotes = true
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            hero.padding(22)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    liveCard
                    hostNotes
                    HStack(alignment: .top, spacing: 14) {
                        noteComposer
                        sayComposer
                    }
                    feed
                }
                .padding(22)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.8), in: Capsule()).padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { withAnimation { if toast == s { toast = nil } } }
    }

    private var hero: some View {
        let ph = game.phase
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("第 \(game.state.phaseIndex + 1) / \(game.script.phases.count) 阶段").font(.system(size: 12, weight: .semibold))
                        .tracking(2).foregroundStyle(Theme.brass)
                    Chip(text: ph.type.label, style: .brass, icon: ph.type.symbol)
                    if game.state.aiPaused { Chip(text: "AI 已暂停", style: .on, icon: "pause.fill") }
                }
                Text(ph.title).font(Theme.serif(34, .bold)).foregroundStyle(Theme.bright).lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                PhaseTimer(game: game, size: 40)
                if ph.minutes > 0 { Text("建议 \(ph.minutes) 分钟").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            VStack(spacing: 8) {
                Button { game.next() } label: {
                    Label("下一阶段", systemImage: "forward.end.fill").frame(minWidth: 120)
                }
                .buttonStyle(.ink(.primary, large: true))
                .disabled(game.state.phaseIndex >= game.script.phases.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                HStack(spacing: 6) {
                    Button { game.prev() } label: { Image(systemName: "backward.end.fill") }
                        .buttonStyle(.ink).help("上一阶段（不播报）").disabled(game.state.phaseIndex == 0)
                    Button { game.startNarration() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.ink).help("重播本阶段主持词")
                    Button { game.stopNarration() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.ink).help("停止播报").disabled(game.live == nil)
                }
            }
        }
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if game.live != nil {
                    Circle().fill(Theme.red).frame(width: 8, height: 8)
                    SectionLabel("DM 正在说", color: Theme.rose)
                } else {
                    SectionLabel("大屏上显示的内容")
                }
                Spacer()
            }
            (Text(game.stageText) + Text(game.live != nil ? " ▍" : "").foregroundColor(Theme.brass))
                .font(Theme.serif(18))
                .foregroundStyle(game.live != nil ? Theme.bright : Theme.text.opacity(0.85))
                .lineSpacing(7)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Theme.ink2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(game.live != nil ? Theme.brass : Theme.line).frame(width: 3).padding(.vertical, 14)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line.opacity(0.7)))
    }

    @ViewBuilder
    private var hostNotes: some View {
        let ph = game.phase
        if !ph.dmScript.isEmpty || !ph.dmNotes.isEmpty || ph.type == .search || !ph.grantable.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showNotes.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showNotes ? 90 : 0))
                        SectionLabel("本阶段主持词与提示 · 只有你看得到", color: Theme.brass)
                        Spacer()
                    }
                    .foregroundStyle(Theme.brass)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showNotes {
                    VStack(alignment: .leading, spacing: 12) {
                        if !ph.dmScript.isEmpty {
                            labeled("主持词（原文）", ph.dmScript)
                        }
                        if !ph.dmNotes.isEmpty {
                            labeled("主持提示（只给 AI 和你看）", ph.dmNotes)
                        }
                        if ph.type == .search {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("搜证地点 · 每人 \(ph.searchPoints) 次").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
                                FlowRow(ph.locations.map { l in
                                    let n = game.state.locationProgress["\(ph.id):\(l.id)"] ?? 0
                                    return (l.name, max(0, l.clues.count - n))
                                })
                            }
                        }
                        if !ph.grantable.isEmpty {
                            Text("AI 可在问答中视情况发放：" + ph.grantable.compactMap { game.script.clue($0)?.title }.joined(separator: "、"))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.top, 12)
                    .transition(.opacity)
                }
            }
            .inkCard(padding: 14)
        }
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text).lineSpacing(4).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("记录讨论要点", color: Theme.brass)
                Spacer()
                Image(systemName: "info.circle").foregroundStyle(Theme.muted)
                    .help("大家面对面说的话 AI 听不到。把关键内容（谁指控谁、谁承认了什么、新的时间线说法）简单记一句，AI 主持和最后复盘都会用到。")
            }
            InkEditor(text: $note, placeholder: "例：A 承认案发前去过现场；B 开始怀疑 C", minHeight: 70)
            Button {
                let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                game.addNote(t); note = ""; flash("已记录")
            } label: { Label("记下来", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                .buttonStyle(.ink)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .inkCard(padding: 14)
    }

    private var sayComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("让 DM 说一段话", color: Theme.brass)
            InkEditor(text: $say, placeholder: "例：还有五分钟，请大家抓紧时间", minHeight: 70)
            HStack {
                Toggle("让 AI 润色", isOn: $polish).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Button {
                    let t = say.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    game.narrateCustom(t, polish: polish); say = ""
                } label: { Label("在大屏播出", systemImage: "megaphone") }
                    .buttonStyle(.inkPrimary)
                    .disabled(say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .inkCard(padding: 14)
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("公开记录")
                Spacer()
                Text("共 \(game.state.publicLog.count) 条").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(game.state.publicLog.suffix(150).reversed().enumerated()), id: \.offset) { _, e in
                    LogRow(entry: e)
                }
            }
        }
    }
}

/// 一排自动换行的小标签
private struct FlowRow: View {
    let items: [(String, Int)]
    init(_ items: [(String, Int)]) { self.items = items }
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Chip(text: "\(it.0) · \(it.1 > 0 ? "剩\(it.1)" : "已搜空")", style: it.1 > 0 ? .plain : .on)
            }
        }
    }
}

// MARK: - 右侧：玩家 / 线索 / 记忆 / 提醒

private struct Inspector: View {
    let session: Session
    @State private var tab = Tab.players
    @State private var showClues = false
    @State private var releaseTarget: String?

    enum Tab: Hashable { case players, clues, memory, warnings }
    private var game: Game { session.game }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("玩家").tag(Tab.players)
                Text("线索").tag(Tab.clues)
                Text("记忆").tag(Tab.memory)
                Text(game.state.warnings.isEmpty ? "提醒" : "提醒 \(game.state.warnings.count)").tag(Tab.warnings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .players: players
                    case .clues: clues
                    case .memory: memory
                    case .warnings: warnings
                    }
                }
                .padding(14)
            }
        }
        .background(Theme.ink2.opacity(0.6))
        .confirmationDialog("释放【\(releaseTarget.map(game.nameOf) ?? "")】？", isPresented: Binding(
            get: { releaseTarget != nil }, set: { if !$0 { releaseTarget = nil } })) {
            Button("释放") { if let r = releaseTarget { game.release(r) } }
        } message: {
            Text("原来的手机会掉线。新手机选这个角色时，线索和进度都会继承。")
        }
    }

    // 玩家

    @ViewBuilder
    private var players: some View {
        JoinCard(session: session)
        if [.vote, .reveal].contains(game.phase.type) { VoteCard(game: game) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("角色")
                Spacer()
                Text("入座 \(game.seatedCount)/\(game.script.characters.count)").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            ForEach(game.script.characters, id: \.id) { c in seat(c) }
        }
    }

    private func seat(_ c: Character) -> some View {
        let p = game.state.players[c.id]
        let online = game.online[c.id] != nil
        return HStack(spacing: 10) {
            Circle().fill(p == nil ? Theme.ink4 : online ? Theme.green : Theme.amber.opacity(0.8)).frame(width: 8, height: 8)
                .help(p == nil ? "空位" : online ? "手机在线" : "手机不在线（可能锁屏了，回到页面会自动重连）")
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(Theme.serif(15, .bold)).foregroundStyle(Theme.text)
                Text(p.map { $0.claimable ? "\($0.name) · 已释放，等待新手机" : $0.name } ?? "空位")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if game.busy.contains(c.id) { Spinner().help("正在问 DM") }
            if let p, !p.claimable {
                if game.phase.type == .vote { Chip(text: p.vote == nil ? "未投" : "已投", style: p.vote == nil ? .plain : .ok) }
                if game.phase.type == .search { Chip(text: "搜证剩\(p.searchLeft)", style: p.searchLeft > 0 ? .brass : .plain) }
                Chip(text: "\(p.clues.count) 线索", icon: "doc.text.magnifyingglass")
                Menu {
                    Button("释放这个角色（换手机用）") { releaseTarget = c.id }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.ink3.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }

    // 线索

    @ViewBuilder
    private var clues: some View {
        Toggle(isOn: $showClues) {
            VStack(alignment: .leading, spacing: 2) {
                Text("显示线索标题").font(.system(size: 13, weight: .medium))
                Text("会看到线索内容，参与游戏的人慎点").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .toggleStyle(.switch)
        if showClues {
            ForEach(game.script.clues, id: \.id) { c in clueRow(c) }
        } else {
            Text("已发现 \(game.state.foundBy.count + game.state.publicClues.filter { game.state.foundBy[$0] == nil }.count) / \(game.script.clues.count) 条，公开 \(game.state.publicClues.count) 条")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private func clueRow(_ c: Clue) -> some View {
        let isPublic = game.state.publicClues.contains(c.id)
        let holder = game.state.foundBy[c.id].map(game.nameOf)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.id).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
                    Text(c.title).font(Theme.serif(14, .bold)).foregroundStyle(Theme.text)
                }
                Text(c.text).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(2)
                HStack(spacing: 6) {
                    if isPublic { Chip(text: "公开", style: .on) }
                    Chip(text: holder.map { "\($0) 持有" } ?? "未发现", style: holder == nil ? .plain : .brass)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("直接公开给所有人") { _ = game.giveClue(c.id, to: nil) }
                Divider()
                ForEach(game.script.characters.filter { game.state.players[$0.id] != nil }, id: \.id) { ch in
                    Button("给 \(ch.name)") { _ = game.giveClue(c.id, to: ch.id) }
                }
            } label: { Text("发放") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10)
        .background(Theme.ink3.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    // 记忆

    @ViewBuilder
    private var memory: some View {
        let st = game.state
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("AI 的记忆")
            Text("公开记录共 \(st.publicLog.count) 条，其中 \(st.summarizedUpto) 条已压缩进摘要，最近 \(st.publicLog.count - st.summarizedUpto) 条原样给 AI。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(3)
            Text("不是让 AI 记住十个小时的对话，而是每次重新拼一份长度固定的上下文：剧本 + 摘要 + 最近事件。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted.opacity(0.8)).lineSpacing(3)
            Button {
                Task { await game.maybeSummarize(force: true) }
            } label: {
                HStack { if game.summarizing { Spinner() }; Text(game.summarizing ? "正在压缩…" : "立即压缩记忆") }
            }
            .buttonStyle(.ink).disabled(game.summarizing)
            DisclosureGroup("查看当前摘要（含剧情信息）") {
                Text(st.summary.isEmpty ? "（还没有摘要）" : st.summary)
                    .font(.system(size: 12)).foregroundStyle(Theme.text).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            .font(.system(size: 12)).tint(Theme.muted)
            Divider().overlay(Theme.line)
            LabeledContent("AI 模型") { Text(game.llm.label).font(.system(size: 11)).lineLimit(2) }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if game.cheap !== game.llm {
                LabeledContent("摘要模型") { Text(game.cheap.label).font(.system(size: 11)).lineLimit(2) }
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    // 提醒

    @ViewBuilder
    private var warnings: some View {
        HStack {
            SectionLabel("提醒 / 拦截记录")
            Spacer()
            Button("清空") { game.clearWarnings() }.buttonStyle(.inkGhost).disabled(game.state.warnings.isEmpty)
        }
        if game.state.warnings.isEmpty {
            Label("暂无。AI 说漏嘴被拦截、接口出错时会记在这里。", systemImage: "checkmark.shield")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        ForEach(Array(game.state.warnings.reversed().enumerated()), id: \.offset) { _, w in
            Text(w).font(.system(size: 12)).foregroundStyle(Theme.rose).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Theme.redSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct JoinCard: View {
    let session: Session
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let img = QRCode.image(session.playerURL, size: 240) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 96, height: 96)
                    .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("扫码入座", color: Theme.brass)
                Text(session.playerURL).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                    .textSelection(.enabled).lineLimit(2)
                HStack(spacing: 6) {
                    Button(copied ? "已复制" : "复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.playerURL, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }.buttonStyle(.ink)
                    Button("在浏览器试试") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(session.port)/player")!) }
                        .buttonStyle(.ink)
                }
                Text("手机和电脑要连同一个 Wi‑Fi").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            }
        }
        .inkCard(padding: 12)
    }
}

private struct VoteCard: View {
    let game: Game

    var body: some View {
        let voted = game.state.players.values.filter { $0.vote != nil }.count
        let total = game.state.players.count
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("投票", color: Theme.brass)
            Text(game.script.phases.first { $0.type == .vote }?.voteQuestion ?? "谁是凶手？")
                .font(Theme.serif(15, .bold)).foregroundStyle(Theme.text)
            ProgressView(value: Double(voted), total: Double(max(total, 1))).tint(Theme.red)
            Text("已投 \(voted) / \(total)").font(.system(size: 12)).foregroundStyle(Theme.muted)
            if game.state.votesRevealed {
                ForEach(game.tally()) { t in
                    HStack {
                        Text(t.name).font(Theme.serif(14, .bold))
                        if t.charId == game.voteAnswer { Chip(text: "真凶", style: .on) }
                        Spacer()
                        Text("\(t.voters.count) 票").font(.system(size: 12).monospacedDigit())
                    }
                    Text(t.voters.joined(separator: "、")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            } else {
                Button("公布投票结果") { game.revealVotes() }.buttonStyle(.ink).disabled(voted == 0)
            }
        }
        .inkCard(padding: 14)
    }
}
