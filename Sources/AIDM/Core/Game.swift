// 游戏引擎：流程由程序控制（状态机），AI 只负责说话和判断。
// 全部在主线程（MainActor）上运行：同步代码段天然不会被打断，不需要额外加锁。
import Foundation
import Observation

struct GameSettings: Codable, Equatable {
    var narration: NarrationMode = .ai
    var keepRecent = 30          // 最近多少条公开事件原样给AI
    var summarizeBatch = 20      // 超出后每攒多少条压缩一次进摘要
    var privateKeep = 12         // 每个玩家最近多少条私聊原样给AI

    enum NarrationMode: String, Codable { case ai, verbatim }
}

/// 正在流式播出的一段话（大屏上逐字显示）
struct LiveStream: Equatable {
    let id: String
    let kind: LogKind
    var text: String
}

/// 大屏语音朗读的接收方
@MainActor protocol SpeechSink: AnyObject {
    func streamStarted()
    func streamDelta(_ text: String)
    func streamEnded(cancelled: Bool)
    func say(_ text: String)
    func phaseChanged()
    func revealStarted(correct: Bool?)
    func thinking(_ on: Bool)
}

struct ActionResult {
    var ok: Bool
    var msg = ""
    var extra: [String: Any] = [:]

    static let success = ActionResult(ok: true)
    static func fail(_ m: String) -> ActionResult { ActionResult(ok: false, msg: m) }
    var json: [String: Any] {
        var d = extra
        d["ok"] = ok
        if !msg.isEmpty { d["msg"] = msg }
        return d
    }
}

private func norm(_ t: String) -> String {
    t.replacingOccurrences(of: "[\\s，。,.！!？?：:“”\"'‘’、]", with: "", options: .regularExpression)
}

private struct Verbatim: Error {}

@MainActor @Observable
final class Game {
    let script: Script
    var state: GameState
    private(set) var llm: LLM
    private(set) var cheap: LLM                      // 摘要可以交给便宜/本地模型
    var settings: GameSettings
    let savePath: URL

    private(set) var busy: Set<String> = []          // 正在等AI回答的玩家
    private(set) var live: LiveStream?
    private(set) var summarizing = false
    private(set) var online: [String: Int] = [:]     // char_id -> 在线的手机连接数

    @ObservationIgnored let bus = EventBus()
    @ObservationIgnored weak var speech: SpeechSink?
    @ObservationIgnored private var narrTask: Task<Void, Never>?

    init(script: Script, state: GameState, llm: LLM, cheap: LLM?, settings: GameSettings, savePath: URL) {
        self.script = script
        self.state = state
        self.llm = llm
        self.cheap = cheap ?? llm
        self.settings = settings
        self.savePath = savePath
    }

    func updateModels(llm: LLM, cheap: LLM?) {
        self.llm = llm
        self.cheap = cheap ?? llm
        changed()
    }

    // MARK: - 基础

    func connectionChanged(_ charId: String, _ delta: Int) {
        let n = (online[charId] ?? 0) + delta
        online[charId] = n > 0 ? n : nil
    }

    var phase: Phase { script.phases[state.phaseIndex] }

    func changed() {
        do { try state.save(to: savePath) } catch { print("存档失败：\(error)") }
        bus.refresh()
    }

    func nameOf(_ charId: String) -> String {
        script.character(charId)?.name ?? state.players[charId]?.name ?? charId
    }

    /// 复盘前检查是否出现禁用词。私聊给角色本人时，涉及本人名字的禁用词不算（凶手本人知道自己是凶手）。
    func leaks(_ text: String, exemptChar: String? = nil) -> String? {
        let exemptName = script.character(exemptChar)?.name
        let nt = norm(text)
        for (f, until) in script.forbiddenRules() where state.phaseIndex < until {
            if let n = exemptName, f.contains(n) { continue }
            let nf = norm(f)
            if !nf.isEmpty && nt.contains(nf) { return f }
        }
        return nil
    }

    // MARK: - 玩家加入

    func join(charId: String, name: String, token: String?) throws -> Player {
        guard script.character(charId) != nil else { throw ScriptError(message: "没有这个角色") }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        if var existing = state.players[charId] {
            let sameDevice = !(token ?? "").isEmpty && existing.token == token
            guard sameDevice || existing.claimable else {
                throw ScriptError(message: "这个角色已经被选了。如果是你本人换了手机，请让主持人在电脑上释放该角色。")
            }
            if existing.claimable {      // 换手机重新认领：继承原来的线索和进度
                existing.token = randomToken()
                existing.claimable = false
                state.logPublic(.system, "系统", "\(trimmed.isEmpty ? existing.name : trimmed) 重新接管了角色【\(nameOf(charId))】")
            }
            if !trimmed.isEmpty { existing.name = trimmed }
            state.players[charId] = existing
            changed()
            return existing
        }
        var p = Player(charId: charId, name: trimmed.isEmpty ? nameOf(charId) : trimmed, token: randomToken())
        if phase.type == .search { p.searchLeft = phase.searchPoints }
        state.players[charId] = p
        state.logPublic(.system, "系统", "\(p.name) 选择了角色【\(nameOf(charId))】")
        changed()
        return p
    }

    func release(_ charId: String) {
        guard var p = state.players[charId] else { return }
        // 不删数据：旧手机失效，新手机选这个角色时继承线索和进度
        p.token = "released-" + randomToken(6)
        p.claimable = true
        state.players[charId] = p
        state.logPublic(.system, "系统", "角色【\(nameOf(charId))】已释放，可以在新手机上重新选择")
        changed()
    }

    // MARK: - 阶段推进

    func goto(_ index: Int, narrate: Bool = true) {
        let index = max(0, min(index, script.phases.count - 1))
        let forward = index > state.phaseIndex
        state.phaseIndex = index
        state.phaseStartedAt = Date().timeIntervalSince1970
        let ph = phase
        for id in state.players.keys { state.players[id]?.searchLeft = ph.type == .search ? ph.searchPoints : 0 }
        state.logPublic(.system, "系统", "—— 进入阶段：\(ph.title) ——", phase: ph.id)
        if !ph.unlock.isEmpty && forward {
            state.logPublic(.system, "系统", "新的剧本内容已解锁，请在手机上查看。", phase: ph.id)
        }
        changed()
        speech?.phaseChanged()
        Task { await maybeSummarize(force: true) }      // 换阶段时把记忆压缩一下
        if narrate { startNarration() }
    }

    func next() { goto(state.phaseIndex + 1) }
    func prev() { goto(state.phaseIndex - 1, narrate: false) }

    func startNarration() {
        narrTask?.cancel()
        let ph = phase
        if ph.type == .reveal {
            narrTask = Task { await reveal() }
        } else if !ph.dmScript.isEmpty {
            narrTask = Task { await narrate(ph.dmScript) }
        }
    }

    func stopNarration() { narrTask?.cancel() }

    /// 把一段话流式推到大屏和所有手机上，结束后写入公开记录
    @discardableResult
    private func streamPublic(_ messages: [ChatMessage]?, fallback: String, kind: LogKind = .narration) async -> String {
        let sid = randomHex()
        bus.send(["type": "stream_start", "id": sid, "who": "DM", "kind": kind.rawValue])
        live = LiveStream(id: sid, kind: kind, text: "")
        speech?.streamStarted()
        var text = ""
        func emit(_ delta: String) {
            text += delta
            bus.send(["type": "stream_delta", "id": sid, "text": delta])
            if live?.id == sid { live?.text += delta }
            speech?.streamDelta(delta)
        }
        do {
            guard let messages, !state.aiPaused else { throw Verbatim() }
            for try await delta in llm.stream(messages, maxTokens: 2500) { emit(delta) }
            try Task.checkCancellation()
        } catch is CancellationError {
            bus.send(["type": "stream_end", "id": sid, "cancelled": true])
            if live?.id == sid { live = nil; speech?.streamEnded(cancelled: true) }
            if !text.isEmpty {
                state.logPublic(kind, "DM", text + "……", phase: phase.id)
                changed()
            }
            return text
        } catch {
            if !(error is Verbatim) { state.warn("AI旁白失败，改为直接念原文：\(error.localizedDescription)") }
            if text.isEmpty { emit(fallback) }
        }
        bus.send(["type": "stream_end", "id": sid])
        if live?.id == sid { live = nil; speech?.streamEnded(cancelled: false) }
        if let leak = leaks(text) {
            state.warn("旁白里出现了禁用词「\(leak)」，请检查剧本或改用原文念白")
        }
        state.logPublic(kind, "DM", text, phase: phase.id)
        changed()
        return text
    }

    private func narrate(_ scriptText: String) async {
        let msgs = settings.narration == .ai ? Prompts.narration(script, state, phase, text: scriptText) : nil
        await streamPublic(msgs, fallback: scriptText)
    }

    /// 主持人让DM说一段话
    func narrateCustom(_ text: String, polish: Bool) {
        let msgs = polish ? Prompts.narration(script, state, phase, text: text) : nil
        narrTask?.cancel()
        narrTask = Task { await streamPublic(msgs, fallback: text) }
    }

    // MARK: - 搜证

    func search(charId: String, locationId: String) -> ActionResult {
        let ph = phase
        guard var p = state.players[charId] else { return .fail("请先选择角色") }
        guard ph.type == .search else { return .fail("现在不是搜证阶段") }
        guard let loc = ph.locations.first(where: { $0.id == locationId }) else { return .fail("没有这个地点") }
        guard p.searchLeft > 0 else { return .fail("你本阶段的搜证次数已经用完了") }
        let key = "\(ph.id):\(loc.id)"
        let n = state.locationProgress[key] ?? 0
        guard n < loc.clues.count, let clue = script.clue(loc.clues[n]) else {
            return .fail("\(loc.name)已经搜不出新东西了（没有扣次数）")
        }
        let cid = clue.id
        state.locationProgress[key] = n + 1
        p.searchLeft -= 1
        if !p.clues.contains(cid) { p.clues.append(cid) }
        state.players[charId] = p
        if state.foundBy[cid] == nil { state.foundBy[cid] = charId }
        state.logPrivate(charId, .clue, "搜证", "在\(loc.name)搜到【\(clue.title)】：\(clue.text)", phase: ph.id)
        if clue.isPublic && !state.publicClues.contains(cid) {
            state.publicClues.append(cid)
            state.logPublic(.clue, "线索", "\(nameOf(charId)) 在\(loc.name)搜到【\(clue.title)】（自动公开）：\(clue.text)", phase: ph.id)
        } else {
            state.logPublic(.search, "搜证", "\(nameOf(charId)) 搜查了\(loc.name)", phase: ph.id)
        }
        changed()
        Task { await maybeSummarize() }
        return ActionResult(ok: true, extra: ["clue": cid, "title": clue.title, "text": clue.text])
    }

    func publishClue(charId: String, clueId: String) -> ActionResult {
        guard let p = state.players[charId] else { return .fail("请先选择角色") }
        guard p.clues.contains(clueId), let clue = script.clue(clueId) else { return .fail("你没有这条线索") }
        guard !state.publicClues.contains(clueId) else { return .fail("已经公开过了") }
        state.publicClues.append(clueId)
        state.logPublic(.clue, "线索", "\(nameOf(charId)) 公开了线索【\(clue.title)】：\(clue.text)", phase: phase.id)
        changed()
        return .success
    }

    /// 主持人手动发线索。target 为角色id，或 nil 直接公开。
    func giveClue(_ clueId: String, to target: String?) -> ActionResult {
        guard let clue = script.clue(clueId) else { return .fail("没有这条线索") }
        if let target {
            guard var p = state.players[target] else { return .fail("这个角色还没有玩家") }
            if !p.clues.contains(clueId) { p.clues.append(clueId) }
            state.players[target] = p
            if state.foundBy[clueId] == nil { state.foundBy[clueId] = target }
            state.logPrivate(target, .clue, "DM", "你获得了线索【\(clue.title)】：\(clue.text)", phase: phase.id)
            state.logPublic(.system, "系统", "DM 给了 \(nameOf(target)) 一条线索", phase: phase.id)
        } else {
            if !state.publicClues.contains(clueId) { state.publicClues.append(clueId) }
            state.logPublic(.clue, "线索", "DM 公开了线索【\(clue.title)】：\(clue.text)", phase: phase.id)
        }
        changed()
        return .success
    }

    // MARK: - 问答

    func ask(charId: String, question raw: String, isPublic: Bool) async -> ActionResult {
        let question = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !question.isEmpty else { return .fail("问题是空的") }
        guard !busy.contains(charId) else { return .fail("DM还在回答你上一个问题") }
        guard state.players[charId] != nil else { return .fail("请先选择角色") }
        let who = nameOf(charId)
        if isPublic {
            state.logPublic(.ask, who, question, phase: phase.id)
        } else {
            state.logPrivate(charId, .ask, who, question, phase: phase.id)
        }
        changed()

        if state.aiPaused {
            return postAnswer(charId, reply: "DM暂时离开了，请稍后再问，或直接问在场的主持人。", give: nil, isPublic: isPublic)
        }

        busy.insert(charId)
        bus.refresh()
        if isPublic { speech?.thinking(true) }
        defer {
            busy.remove(charId); bus.refresh()
            if isPublic { speech?.thinking(false) }
        }

        var reply = "", give: String? = nil
        for attempt in 0..<2 {
            guard state.players[charId] != nil else { return .fail("请先选择角色") }
            let msgs = Prompts.ask(script, state, phase, charId: charId, question: question, isPublic: isPublic,
                                   recent: settings.keepRecent, privateKeep: settings.privateKeep, strict: attempt > 0)
            let raw: String
            do {
                raw = try await llm.chat(msgs, maxTokens: 800)
            } catch {
                state.warn("AI回答失败：\(error.localizedDescription)")
                reply = "（DM这边网络有点问题，请稍后再问一次）"; give = nil
                break
            }
            let data = parseJSONReply(raw)
            let r = data["reply"].map { $0 is NSNull ? "" : (($0 as? String) ?? "\($0)") } ?? ""
            reply = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply.isEmpty { reply = "……" }
            give = data["give_clue"] as? String
            guard let leak = leaks(reply, exemptChar: isPublic ? nil : charId) else { break }
            state.warn("拦截了一次可能的剧透（\(who)问：\(question.prefix(30))；命中「\(leak)」）")
            reply = "这个问题现在还不能回答。继续推理吧。"; give = nil
        }
        // 线索发放由程序把关：只能给本阶段 grantable 里、对方还没有的
        if let g = give?.trimmingCharacters(in: .whitespaces) {
            let ok = phase.grantable.contains(g) && script.hasClue(g)
                && !(state.players[charId]?.clues.contains(g) ?? true) && !state.publicClues.contains(g)
            give = ok ? g : nil
        }
        return postAnswer(charId, reply: reply, give: give, isPublic: isPublic)
    }

    private func postAnswer(_ charId: String, reply: String, give: String?, isPublic: Bool) -> ActionResult {
        let ph = phase.id
        if isPublic {
            state.logPublic(.answer, "DM", "（回答\(nameOf(charId))）\(reply)", phase: ph)
            speech?.say(reply)
        } else {
            state.logPrivate(charId, .answer, "DM", reply, phase: ph)
        }
        var result = ActionResult(ok: true, extra: ["reply": reply])
        if let give, let clue = script.clue(give), state.players[charId] != nil {
            state.players[charId]?.clues.append(give)
            if state.foundBy[give] == nil { state.foundBy[give] = charId }
            state.logPrivate(charId, .clue, "DM", "你获得了线索【\(clue.title)】：\(clue.text)", phase: ph)
            state.logPublic(.system, "系统", "\(nameOf(charId)) 从DM那里获得了一条线索", phase: ph)
            result.extra["clue"] = ["id": give, "title": clue.title, "text": clue.text]
        }
        changed()
        Task { await maybeSummarize(charId: isPublic ? nil : charId) }
        return result
    }

    // MARK: - 主持人操作

    /// 线下讨论记录：大家面对面说的话AI听不见，主持人简单记一句
    func addNote(_ text: String, who: String = "记录") {
        state.logPublic(.note, who, String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)), phase: phase.id)
        changed()
        Task { await maybeSummarize() }
    }

    func setPaused(_ paused: Bool) {
        state.aiPaused = paused
        changed()
    }

    func toggleNarrationMode() {
        settings.narration = settings.narration == .ai ? .verbatim : .ai
        changed()
    }

    func clearWarnings() {
        state.warnings.removeAll()
        changed()
    }

    func revealVotes() {
        state.votesRevealed = true
        state.logPublic(.system, "投票", "投票结果：\n" + voteSummary().lines, phase: phase.id)
        changed()
    }

    // MARK: - 投票

    func vote(charId: String, option: String) -> ActionResult {
        guard phase.type == .vote else { return .fail("现在不是投票阶段") }
        guard script.character(option) != nil else { return .fail("无效选项") }
        guard var p = state.players[charId] else { return .fail("请先选择角色") }
        guard p.vote == nil else { return .fail("你已经投过票了") }
        p.vote = option
        state.players[charId] = p
        state.logPublic(.system, "投票", "\(nameOf(charId)) 已投票", phase: phase.id)
        if state.players.values.allSatisfy({ $0.vote != nil }) {
            state.votesRevealed = true
            state.logPublic(.system, "投票", "所有人都已投票。\n" + voteSummary().lines, phase: phase.id)
        }
        changed()
        return .success
    }

    struct Tally: Identifiable {
        let charId: String
        let name: String
        let voters: [String]
        var id: String { charId }
    }

    func tally() -> [Tally] {
        var t: [String: [String]] = [:]
        for c in script.characters {
            if let v = state.players[c.id]?.vote { t[v, default: []].append(nameOf(c.id)) }
        }
        let order = script.characters.map(\.id)
        return t.map { Tally(charId: $0.key, name: nameOf($0.key), voters: $0.value) }
            .sorted { a, b in
                a.voters.count != b.voters.count ? a.voters.count > b.voters.count
                    : (order.firstIndex(of: a.charId) ?? 0) < (order.firstIndex(of: b.charId) ?? 0)
            }
    }

    var voteAnswer: String? { script.phases.first { $0.type == .vote }?.voteAnswer }

    func voteSummary() -> (lines: String, correct: Bool?) {
        let t = tally()
        let lines = t.map { "\($0.name)：\($0.voters.count)票（\($0.voters.joined(separator: "、"))）" }.joined(separator: "\n")
        var correct: Bool? = nil
        if let answer = voteAnswer, !t.isEmpty {
            let top = t.map(\.voters.count).max() ?? 0
            let leaders = t.filter { $0.voters.count == top }.map(\.charId)
            correct = leaders == [answer]
        }
        return (lines.isEmpty ? "没有人投票" : lines, correct)
    }

    private func reveal() async {
        state.votesRevealed = true
        let (lines, correct) = voteSummary()
        let msgs = Prompts.reveal(script, state, voteLines: lines, correct: correct)
        let ending = correct.map { script.endings[$0 ? "correct" : "wrong"] ?? "" } ?? (script.endings["correct"] ?? "")
        let fallback = script.hasVote ? "投票结果：\n\(lines)\n\n真相：\n\(script.truth)\n\n\(ending)"
                                      : "真相：\n\(script.truth)\n\n\(ending)"
        speech?.revealStarted(correct: correct)
        await streamPublic(msgs, fallback: fallback, kind: .reveal)
    }

    // MARK: - 记忆压缩

    /// 公开记录超过阈值，就把最早的一批折叠进摘要；私聊同理。保证每次给AI的上下文长度恒定。
    func maybeSummarize(force: Bool = false, charId: String? = nil) async {
        guard !summarizing else { return }
        summarizing = true
        defer { summarizing = false }
        let pending = state.publicLog.count - state.summarizedUpto
        let threshold = settings.keepRecent + settings.summarizeBatch
        if pending > threshold || (force && pending > settings.keepRecent) {
            let upto = state.publicLog.count - settings.keepRecent
            let batch = Array(state.publicLog[state.summarizedUpto..<upto])
            do {
                let new = try await cheap.chat(Prompts.summary(old: state.summary, entries: batch), maxTokens: 1200)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !new.isEmpty {
                    state.summary = new
                    state.summarizedUpto = upto
                    changed()
                }
            } catch {
                state.warn("记忆压缩失败（不影响游戏，下次再试）：\(error.localizedDescription)")
            }
        }
        if let charId {
            let log = state.privateLog[charId] ?? []
            let done = state.privateSummarizedUpto[charId] ?? 0
            if log.count - done > settings.privateKeep * 2 {
                let upto = log.count - settings.privateKeep
                do {
                    let new = try await cheap.chat(Prompts.summary(old: state.privateSummary[charId] ?? "",
                                                                   entries: Array(log[done..<upto]), privateOf: nameOf(charId)),
                                                   maxTokens: 800).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !new.isEmpty {
                        state.privateSummary[charId] = new
                        state.privateSummarizedUpto[charId] = upto
                        changed()
                    }
                } catch {
                    state.warn("私聊记忆压缩失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 给大屏/主持台用的便捷属性

    /// 大屏中央显示的最近一段 DM 的话
    var stageText: String {
        if let live { return live.text }
        let last = state.publicLog.last { [.narration, .reveal, .answer].contains($0.kind) }
        return last?.text ?? script.intro
    }

    func remaining(at now: Date = Date()) -> Int? {
        guard phase.minutes > 0 else { return nil }
        return Int((state.phaseStartedAt + Double(phase.minutes * 60) - now.timeIntervalSince1970).rounded())
    }

    var seatedCount: Int { state.players.values.filter { !$0.claimable }.count }
}

func randomHex() -> String {
    String(format: "%08x", UInt32.random(in: 0...UInt32.max))
}

func fmtSeconds(_ s: Int) -> String {
    let a = abs(s)
    return (s < 0 ? "-" : "") + String(format: "%02d:%02d", a / 60, a % 60)
}
