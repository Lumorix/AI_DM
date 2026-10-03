// 事件推送：手机通过 SSE 订阅，游戏状态一变就推送新画面；DM 说话时逐字推送。
import Foundation

enum BusEvent {
    case refresh
    case event([String: Any])
}

@MainActor
final class EventBus {
    private struct Sub {
        let audience: String          // "player:<char_id>"
        let deliver: (BusEvent) -> Void
    }

    private var subs: [UUID: Sub] = [:]

    func subscribe(audience: String, deliver: @escaping (BusEvent) -> Void) -> UUID {
        let id = UUID()
        subs[id] = Sub(audience: audience, deliver: deliver)
        return id
    }

    func unsubscribe(_ id: UUID) { subs[id] = nil }

    var connectedAudiences: [String] { subs.values.map(\.audience) }

    func refresh() {
        for s in subs.values { s.deliver(.refresh) }
    }

    func send(_ event: [String: Any], audiences: Set<String>? = nil) {
        for s in subs.values where audiences == nil || audiences!.contains(s.audience) {
            s.deliver(.event(event))
        }
    }
}

// MARK: - 手机端看到的数据（字段与旧版网页一致）

extension Game {
    func phaseView() -> [String: Any] {
        let ph = phase
        return ["index": state.phaseIndex, "total": script.phases.count, "id": ph.id, "title": ph.title,
                "type": ph.type.rawValue, "minutes": ph.minutes, "started_at": state.phaseStartedAt]
    }

    func clueView(_ c: Clue) -> [String: Any] {
        ["id": c.id, "title": c.title, "text": c.text, "has_image": c.image != nil, "public": state.publicClues.contains(c.id)]
    }

    func logView<S: Collection>(_ entries: S, last n: Int) -> [[String: Any]] where S.Element == LogEntry {
        entries.suffix(n).map { ["t": $0.t, "kind": $0.kind.rawValue, "who": $0.who, "text": $0.text] }
    }

    func playersView() -> [[String: Any]] {
        script.characters.map { c in
            let p = state.players[c.id]
            return ["char_id": c.id, "char_name": c.name, "public": c.publicInfo,
                    "player": p.map { $0.name as Any } ?? NSNull(), "voted": p?.vote != nil,
                    "claimable": p?.claimable ?? false, "busy": busy.contains(c.id)]
        }
    }

    func voteView() -> Any {
        guard [.vote, .reveal].contains(phase.type) else { return NSNull() }
        var v: [String: Any] = [
            "question": script.phases.first { $0.type == .vote }?.voteQuestion ?? "谁是凶手？",
            "revealed": state.votesRevealed,
            "voted": state.players.values.filter { $0.vote != nil }.count,
            "total": state.players.count,
        ]
        if state.votesRevealed { v["result"] = voteSummary().lines }
        return v
    }

    func viewPublic() -> [String: Any] {
        ["title": script.title, "intro": script.intro, "phase": phaseView(), "players": playersView(),
         "public_clues": state.publicClues.compactMap { script.clue($0) }.map(clueView),
         "log": logView(state.publicLog, last: 80), "vote": voteView(),
         "ai_paused": state.aiPaused, "now": Date().timeIntervalSince1970]
    }

    func viewPlayer(_ charId: String) -> [String: Any] {
        var v = viewPublic()
        guard let p = state.players[charId], let c = script.character(charId) else { return v }
        let ph = phase
        let locations: [[String: Any]] = ph.type == .search ? ph.locations.map { l in
            let n = state.locationProgress["\(ph.id):\(l.id)"] ?? 0
            return ["id": l.id, "name": l.name, "left": max(0, l.clues.count - n)]
        } : []
        v["me"] = [
            "char_id": charId, "char_name": c.name, "name": p.name, "public": c.publicInfo,
            "book": script.unlockedActs(upTo: state.phaseIndex).compactMap { a in
                c.act(a).map { ["act": actLabel(a), "text": $0.text] }
            },
            "clues": p.clues.compactMap { script.clue($0) }.map(clueView),
            "search_left": p.searchLeft, "locations": locations, "vote": p.vote as Any? ?? NSNull(),
            "private_log": logView(state.privateLog[charId] ?? [], last: 60),
            "busy": busy.contains(charId),
        ] as [String: Any]
        return v
    }

    func lobbyView() -> [String: Any] {
        ["title": script.title, "intro": script.intro, "players": playersView(), "phase": phaseView()]
    }
}
