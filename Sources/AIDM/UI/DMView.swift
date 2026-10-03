import SwiftUI

/// 游戏中的主界面（简洁版）：左边是 DM 形象，右边是她说的话和对话框。
/// 流程、玩家、线索这些都在“主持台”窗口里，平时不用看。
struct DMView: View {
    let session: Session
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var narrator: Narrator
    @Environment(\.openWindow) private var openWindow
    @State private var question = ""
    @State private var confirmEnd = false
    @FocusState private var inputFocused: Bool

    private var game: Game { session.game }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.line).frame(height: 1)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    avatar.frame(width: geo.size.width * 0.42)
                    chat
                }
            }
        }
        .background(Theme.backdrop)
        .confirmationDialog("结束这局游戏？", isPresented: $confirmEnd) {
            Button("结束并回到剧本库") { model.endGame() }
        } message: { Text("进度已经自动存档，下次可以继续。") }
    }

    // MARK: 顶栏：剧本、阶段、计时、下一阶段

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("《\(game.script.title)》").font(.system(size: 12, weight: .medium)).tracking(2).foregroundStyle(Theme.brass)
                Text("第 \(game.state.phaseIndex + 1)/\(game.script.phases.count) 阶段 · \(game.phase.title)")
                    .font(Theme.serif(20, .bold)).foregroundStyle(Theme.bright).lineLimit(1)
            }
            Spacer()
            PhaseTimer(game: game, size: 26)
            Button { game.next() } label: { Label("下一阶段", systemImage: "forward.end.fill") }
                .buttonStyle(.ink(.primary, large: true))
                .disabled(game.state.phaseIndex >= game.script.phases.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button {
                if !narrator.enabled && model.settings.voice.engine == .system {
                    model.autoPickVoice()       // 有八千代的声音就用她的
                    if model.settings.voice.engine == .system, let v = LocalTTS.voices().first {
                        model.settings.voice.engine = .local
                        model.settings.voice.localVoice = v
                    }
                }
                narrator.enabled.toggle()
            } label: {
                Image(systemName: narrator.enabled ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .buttonStyle(.ink(.secondary, large: true))
            .help(narrator.enabled ? "关闭语音（现在：\(model.voiceLabel)）" : "让 DM 出声（\(model.voiceLabel)）")
            Menu {
                Button("主持台（流程、玩家、线索）") { openWindow(id: "console") }
                Button("大屏（投到电视）") { openWindow(id: "stage") }
                Divider()
                Button("结束游戏…") { confirmEnd = true }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    // MARK: 左边：DM 形象

    private var avatar: some View {
        ZStack(alignment: .bottom) {
            RadialGradient(colors: [Theme.brass.opacity(0.14), Theme.red.opacity(0.05), .clear],
                           center: UnitPoint(x: 0.5, y: 0.6), startRadius: 0, endRadius: 420)
            if model.avatarModel != nil {
                Live2DView(model: model.avatarModel, config: model.settings.avatar, events: narrator.avatar)
            } else {
                VStack(spacing: 10) {
                    Text("DM").font(Theme.serif(64, .bold)).foregroundStyle(Theme.red.opacity(0.6))
                    Text("在 设置 › DM 形象 里导入 Live2D 模型").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: 右边：她说的话 + 对话框

    private var messages: [LogEntry] {
        game.state.publicLog.filter { [.narration, .reveal, .answer, .ask].contains($0.kind) }.suffix(80)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, e in bubble(e) }
                        if let live = game.live {
                            dmBubble(live.text, live: true)
                        }
                        if game.tableBusy {
                            HStack(spacing: 8) { Spinner(); Text("DM 正在想…").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(22)
                }
                .onAppear { proxy.scrollTo("end") }
                .onChange(of: game.state.publicLog.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                .onChange(of: game.live?.text) { _, _ in proxy.scrollTo("end") }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 10) {
                TextField("问 DM 问题…（回车发送）", text: $question)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .inkField()
                Button(action: send) { Label("发送", systemImage: "paperplane.fill") }
                    .buttonStyle(.ink(.primary, large: true))
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || game.tableBusy)
            }
            .padding(16)
        }
        .background(Theme.ink2.opacity(0.55))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !game.tableBusy else { return }
        question = ""
        Task { _ = await game.askTable(q) }
    }

    @ViewBuilder
    private func bubble(_ e: LogEntry) -> some View {
        if e.kind == .ask {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(e.who).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Text(e.text).font(.system(size: 15)).foregroundStyle(Color(hex: 0xF1DCC0))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(hex: 0x3A2A1F), in: RoundedRectangle(cornerRadius: 14))
                        .textSelection(.enabled)
                }
            }
        } else {
            dmBubble(e.text, live: false)
        }
    }

    private func dmBubble(_ text: String, live: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("DM").font(.system(size: 11, weight: .semibold)).tracking(3).foregroundStyle(Theme.red)
                    if live { Circle().fill(Theme.red).frame(width: 6, height: 6) }
                }
                (Text(text) + Text(live ? " ▍" : "").foregroundColor(Theme.brass))
                    .font(Theme.serif(19))
                    .foregroundStyle(Theme.bright)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Theme.ink3.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(live ? Theme.brass : .clear).frame(width: 3).padding(.vertical, 10)
                    }
            }
            Spacer(minLength: 40)
        }
    }
}
