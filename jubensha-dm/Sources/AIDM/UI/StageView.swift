import AppKit
import SwiftUI

/// 大屏：投到电视上给所有人看
struct StageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.backdrop
            if let s = model.session {
                StageContent(session: s)
            } else {
                VStack(spacing: 16) {
                    Text("杀").font(Theme.serif(64, .bold)).foregroundStyle(Theme.red.opacity(0.7))
                    Text("等待开局").font(Theme.serif(28)).foregroundStyle(Theme.muted)
                    Text("在主窗口选择剧本并开始游戏").font(.system(size: 14)).foregroundStyle(Theme.muted.opacity(0.7))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct StageContent: View {
    let session: Session
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var narrator: Narrator
    @State private var qrHidden = false
    @State private var hover = false

    private var game: Game { session.game }

    var body: some View {
        GeometryReader { geo in
            let k = min(max(geo.size.width / 1280, 0.72), 2.0)
            let sideW = max(310, geo.size.width * 0.29)
            HStack(spacing: 0) {
                main(k, avatarWidth: (geo.size.width - sideW) * 0.4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                side(k)
                    .frame(width: sideW)
            }
        }
        .overlay(alignment: .bottomTrailing) { controls.opacity(hover ? 1 : 0).padding(18) }
        .onHover { h in withAnimation(.easeInOut(duration: 0.2)) { hover = h } }
        .onContinuousHover { _ in if !hover { withAnimation { hover = true } } }
    }

    // MARK: 主区域

    private var avatar: Live2DModelInfo? {
        model.settings.avatar.enabled ? model.avatarModel : nil
    }

    /// DM 形象：站在字幕旁边，像视觉小说
    private func avatarPane(_ k: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RadialGradient(colors: [Theme.brass.opacity(0.13), Theme.red.opacity(0.05), .clear],
                           center: UnitPoint(x: 0.5, y: 0.62), startRadius: 0, endRadius: width * 0.75)
            Ellipse().fill(.black.opacity(0.45)).frame(width: width * 0.6, height: 26 * k).blur(radius: 14).offset(y: 6)
            Live2DView(model: avatar, config: model.settings.avatar, events: narrator.avatar)
        }
        .frame(width: width)
        .padding(.top, 12 * k)
    }

    private func main(_ k: CGFloat, avatarWidth: CGFloat) -> some View {
        let side = model.settings.avatar.side
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 8 * k) {
                    Text("《\(game.script.title)》").font(.system(size: 15 * k, weight: .medium)).tracking(5 * k)
                        .foregroundStyle(Theme.brass)
                    Text(game.phase.title).font(Theme.serif(52 * k, .bold)).foregroundStyle(Theme.bright)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .id(game.state.phaseIndex)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
                Spacer()
                PhaseTimer(game: game, size: 60 * k)
            }
            .animation(.easeOut(duration: 0.5), value: game.state.phaseIndex)
            .padding(.bottom, 16 * k)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            HStack(alignment: .top, spacing: 28 * k) {
                if avatar != nil && side == .left { avatarPane(k, width: avatarWidth) }
                VStack(alignment: .leading, spacing: 0) {
                    stage(k)
                        .padding(.top, 26 * k).padding(.bottom, 18 * k)
                    feed(k)
                }
                if avatar != nil && side == .right { avatarPane(k, width: avatarWidth) }
            }
        }
        .padding(.horizontal, 40 * k).padding(.top, 34 * k).padding(.bottom, avatar == nil ? 20 * k : 0)
    }

    private func stage(_ k: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * k) {
            HStack(spacing: 8) {
                Text("DM").font(.system(size: 14 * k, weight: .semibold)).tracking(5 * k).foregroundStyle(Theme.red)
                if game.live != nil {
                    Circle().fill(Theme.red).frame(width: 7 * k, height: 7 * k)
                        .phaseAnimator([0.3, 1]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.7) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    (Text(game.stageText) + Text(game.live != nil ? "▍" : "").foregroundColor(Theme.brass))
                        .font(Theme.serif(30 * k))
                        .foregroundStyle(Theme.bright)
                        .lineSpacing(14 * k)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Color.clear.frame(height: 1).id("end")
                }
                .scrollIndicators(.never)
                .onChange(of: game.live?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(minHeight: 120 * k, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func feed(_ k: CGFloat) -> some View {
        let entries = game.state.publicLog.filter { $0.kind != .narration && $0.kind != .reveal }.suffix(40)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12 * k) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        LogRow(entry: e, large: k > 1.1)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.top, 16 * k)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                         .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            .onAppear { proxy.scrollTo("bottom") }
            .onChange(of: game.state.publicLog.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1).mask(
                HStack(spacing: 4) { ForEach(0..<200, id: \.self) { _ in Rectangle().frame(width: 4) } }
            )
        }
    }

    // MARK: 侧栏

    private func side(_ k: CGFloat) -> some View {
        let allJoined = game.script.characters.allSatisfy { game.state.players[$0.id].map { !$0.claimable } ?? false }
        let showJoin = !qrHidden && !(allJoined && game.state.phaseIndex > 0)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24 * k) {
                if game.state.aiPaused {
                    Label("AI 主持已暂停", systemImage: "pause.circle.fill").font(.system(size: 14 * k))
                        .foregroundStyle(Theme.rose).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.redSoft, in: RoundedRectangle(cornerRadius: 8))
                }
                if showJoin {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("扫码入座")
                        if let img = QRCode.image(session.playerURL, size: 600) {
                            Image(nsImage: img).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: 220 * k)
                                .padding(12 * k).background(.white, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Text(session.playerURL).font(.system(size: 13 * k, design: .monospaced)).foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                    }
                    .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("角色")
                    ForEach(game.script.characters, id: \.id) { c in seat(c, k) }
                }
                if [.vote, .reveal].contains(game.phase.type) { vote(k) }
                if !game.state.publicClues.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("公开线索")
                        ForEach(game.state.publicClues.reversed(), id: \.self) { cid in
                            if let c = game.script.clue(cid) { ClueCard(clue: c, folder: game.script.folder, compact: k < 1.2) }
                        }
                    }
                }
            }
            .padding(22 * k)
            .animation(.easeInOut, value: showJoin)
        }
        .scrollIndicators(.never)
        .background(Theme.ink2.opacity(0.85))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func seat(_ c: Character, _ k: CGFloat) -> some View {
        let p = game.state.players[c.id]
        let seated = p.map { !$0.claimable } ?? false
        let isVote = [.vote, .reveal].contains(game.phase.type)
        return HStack(spacing: 10) {
            Text(c.name).font(Theme.serif(17 * k, .bold)).foregroundStyle(Theme.text)
            if seated { Text(p!.name).font(.system(size: 13 * k)).foregroundStyle(Theme.muted).lineLimit(1) }
            Spacer(minLength: 4)
            if game.busy.contains(c.id) { Spinner(size: 12 * k) }
            Chip(text: seated ? (isVote ? (p!.vote == nil ? "未投票" : "已投票") : "已入座") : "空位", style: seated ? .ok : .plain)
                .scaleEffect(min(k, 1.4))
        }
        .padding(.horizontal, 12).padding(.vertical, 9 * k)
        .background(Theme.ink3, in: RoundedRectangle(cornerRadius: 9))
    }

    private func vote(_ k: CGFloat) -> some View {
        let voted = game.state.players.values.filter { $0.vote != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("投票")
            Text(game.script.phases.first { $0.type == .vote }?.voteQuestion ?? "谁是凶手？")
                .font(Theme.serif(18 * k, .bold)).foregroundStyle(Theme.bright)
            if game.state.votesRevealed {
                let tally = game.tally()
                let maxN = tally.map(\.voters.count).max() ?? 1
                ForEach(tally) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(t.name).font(Theme.serif(16 * k, .bold))
                            Spacer()
                            Text("\(t.voters.count) 票").font(.system(size: 13 * k).monospacedDigit())
                        }
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 3).fill(Theme.red)
                                .frame(width: g.size.width * CGFloat(t.voters.count) / CGFloat(max(maxN, 1)))
                        }
                        .frame(height: 6)
                        Text(t.voters.joined(separator: "、")).font(.system(size: 11 * k)).foregroundStyle(Theme.muted)
                    }
                }
            } else {
                Text("已投 \(voted) / \(game.state.players.count)").font(.system(size: 18 * k).monospacedDigit())
                    .foregroundStyle(Theme.text)
            }
        }
    }

    // MARK: 控制条（鼠标移上来才显示）

    private var controls: some View {
        HStack(spacing: 8) {
            Button { narrator.enabled.toggle() } label: {
                Label(narrator.enabled ? "语音朗读：开" : "语音朗读：关",
                      systemImage: narrator.enabled ? "speaker.wave.2.fill" : "speaker.slash")
            }
            Button { withAnimation { qrHidden.toggle() } } label: {
                Label(qrHidden ? "显示二维码" : "隐藏二维码", systemImage: "qrcode")
            }
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .buttonStyle(.ink)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
