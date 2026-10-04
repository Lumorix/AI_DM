// 游戏状态：所有会变的东西都在这里，随时存成 JSON，断电/关机后可以读档继续。
// JSON 字段名与旧版 Python 存档一致，旧存档可以直接读。
import Foundation

struct Player: Codable, Equatable {
    var charId: String
    var name: String
    var token: String
    var clues: [String] = []      // 自己持有的线索
    var searchLeft = 0            // 当前阶段剩余搜证次数
    var vote: String? = nil
    var claimable = false         // 被管理员释放，等新手机认领

    enum CodingKeys: String, CodingKey {
        case charId = "char_id", name, token, clues, searchLeft = "search_left", vote, claimable
    }

    init(charId: String, name: String, token: String) {
        self.charId = charId; self.name = name; self.token = token
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        charId = try c.decode(String.self, forKey: .charId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        clues = try c.decodeIfPresent([String].self, forKey: .clues) ?? []
        searchLeft = try c.decodeIfPresent(Int.self, forKey: .searchLeft) ?? 0
        vote = try c.decodeIfPresent(String.self, forKey: .vote)
        claimable = try c.decodeIfPresent(Bool.self, forKey: .claimable) ?? false
    }
}

enum LogKind: String, Codable {
    case narration, ask, answer, note, clue, system, search, reveal
}

struct LogEntry: Codable, Equatable, Identifiable {
    var t: Double
    var kind: LogKind
    var who: String               // 显示名，如 "DM"、"周晴"
    var text: String
    var phase = ""

    var id: String { "\(t)-\(who)-\(text.count)" }
}

struct GameState: Codable, Equatable {
    var scriptTitle: String
    var phaseIndex = 0
    var phaseStartedAt = Date().timeIntervalSince1970
    var players: [String: Player] = [:]                 // char_id -> Player
    var publicClues: [String] = []
    var foundBy: [String: String] = [:]                 // clue_id -> char_id
    var locationProgress: [String: Int] = [:]           // "phase:loc" -> 已搜出数量
    var publicLog: [LogEntry] = []
    var privateLog: [String: [LogEntry]] = [:]
    // 记忆：公开事件摘要 + 每个玩家的私聊摘要
    var summary = ""
    var summarizedUpto = 0                              // publicLog 中已并入摘要的条数
    var privateSummary: [String: String] = [:]
    var privateSummarizedUpto: [String: Int] = [:]
    var votesRevealed = false
    var aiPaused = false
    var warnings: [String] = []                         // 给管理员看的拦截/错误记录

    enum CodingKeys: String, CodingKey {
        case scriptTitle = "script_title", phaseIndex = "phase_index", phaseStartedAt = "phase_started_at"
        case players, publicClues = "public_clues", foundBy = "found_by", locationProgress = "location_progress"
        case publicLog = "public_log", privateLog = "private_log", summary, summarizedUpto = "summarized_upto"
        case privateSummary = "private_summary", privateSummarizedUpto = "private_summarized_upto"
        case votesRevealed = "votes_revealed", aiPaused = "ai_paused", warnings
    }

    init(scriptTitle: String) { self.scriptTitle = scriptTitle }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        scriptTitle = try c.decodeIfPresent(String.self, forKey: .scriptTitle) ?? ""
        phaseIndex = try c.decodeIfPresent(Int.self, forKey: .phaseIndex) ?? 0
        phaseStartedAt = try c.decodeIfPresent(Double.self, forKey: .phaseStartedAt) ?? Date().timeIntervalSince1970
        players = try c.decodeIfPresent([String: Player].self, forKey: .players) ?? [:]
        publicClues = try c.decodeIfPresent([String].self, forKey: .publicClues) ?? []
        foundBy = try c.decodeIfPresent([String: String].self, forKey: .foundBy) ?? [:]
        locationProgress = try c.decodeIfPresent([String: Int].self, forKey: .locationProgress) ?? [:]
        publicLog = try c.decodeIfPresent([LogEntry].self, forKey: .publicLog) ?? []
        privateLog = try c.decodeIfPresent([String: [LogEntry]].self, forKey: .privateLog) ?? [:]
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summarizedUpto = try c.decodeIfPresent(Int.self, forKey: .summarizedUpto) ?? 0
        privateSummary = try c.decodeIfPresent([String: String].self, forKey: .privateSummary) ?? [:]
        privateSummarizedUpto = try c.decodeIfPresent([String: Int].self, forKey: .privateSummarizedUpto) ?? [:]
        votesRevealed = try c.decodeIfPresent(Bool.self, forKey: .votesRevealed) ?? false
        aiPaused = try c.decodeIfPresent(Bool.self, forKey: .aiPaused) ?? false
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    // MARK: 存档

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> GameState {
        try JSONDecoder().decode(GameState.self, from: Data(contentsOf: url))
    }

    // MARK: 小工具

    func player(byToken token: String?) -> Player? {
        guard let token, !token.isEmpty else { return nil }
        return players.values.first { $0.token == token && !$0.claimable }
    }

    mutating func logPublic(_ kind: LogKind, _ who: String, _ text: String, phase: String = "") {
        publicLog.append(LogEntry(t: Date().timeIntervalSince1970, kind: kind, who: who, text: text, phase: phase))
    }

    mutating func logPrivate(_ charId: String, _ kind: LogKind, _ who: String, _ text: String, phase: String = "") {
        privateLog[charId, default: []].append(LogEntry(t: Date().timeIntervalSince1970, kind: kind, who: who, text: text, phase: phase))
    }

    mutating func warn(_ msg: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss "
        warnings.append(f.string(from: Date()) + msg)
        if warnings.count > 50 { warnings.removeFirst(warnings.count - 50) }
    }
}

func randomToken(_ bytes: Int = 9) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return Data(b).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
