// 剧本：一个文件夹，里面有 script.yaml，可选 assets/ 放线索图片。
import Foundation
import Yams

enum PhaseType: String, CaseIterable, Codable {
    case narration, reading, discuss, search, vote, reveal

    var label: String {
        switch self {
        case .narration: "旁白"
        case .reading: "阅读"
        case .discuss: "讨论"
        case .search: "搜证"
        case .vote: "投票"
        case .reveal: "复盘"
        }
    }

    var symbol: String {
        switch self {
        case .narration: "text.quote"
        case .reading: "book"
        case .discuss: "person.3"
        case .search: "magnifyingglass"
        case .vote: "checkmark.seal"
        case .reveal: "sparkles"
        }
    }
}

struct Clue: Equatable {
    var uid = UUID()
    var id: String
    var title: String
    var text: String
    var isPublic = false          // 搜到后自动公开
    var image: String? = nil      // 相对剧本文件夹的图片路径
    var condition = ""            // 给AI看的发放条件（grantable 线索用）
}

struct Act: Equatable {
    var uid = UUID()
    var id: String                // act1、act2……
    var text: String
}

struct Character: Equatable {
    var uid = UUID()
    var id: String
    var name: String
    var publicInfo = ""           // 所有人可见的简介
    var secretBrief = ""          // 只给AI：该角色的秘密摘要
    var book: [Act] = []          // 按顺序的各幕剧本正文

    func act(_ id: String) -> Act? { book.first { $0.id == id } }
}

struct Location: Equatable {
    var uid = UUID()
    var id: String
    var name: String
    var clues: [String]
}

struct Phase: Equatable {
    var uid = UUID()
    var id: String
    var title: String
    var type: PhaseType
    var minutes = 0
    var dmScript = ""             // 本阶段主持词
    var dmNotes = ""              // 只给AI的提示
    var unlock: [String] = []     // 本阶段解锁的角色本幕
    var searchPoints = 0
    var locations: [Location] = []
    var grantable: [String] = []  // AI可以在问答中发放的线索
    var voteQuestion = "谁是凶手？"
    var voteAnswer: String? = nil
}

struct ScriptError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Issue: Hashable {
    enum Level: String { case error = "错误", warning = "提醒" }
    let level: Level
    let message: String
}

struct Script: Equatable {
    var folder: URL
    var title: String
    var intro = ""
    var players = 0
    var truth = ""
    var style = ""
    var forbidden: [String] = []
    var forbiddenUntil: String? = nil   // 从这个阶段开始不再拦截禁用词（默认是第一个 reveal 阶段）
    var characters: [Character] = []
    var clues: [Clue] = []
    var phases: [Phase] = []
    var endings: [String: String] = [:]

    func character(_ id: String?) -> Character? {
        guard let id else { return nil }
        return characters.first { $0.id == id }
    }

    func clue(_ id: String?) -> Clue? {
        guard let id else { return nil }
        return clues.first { $0.id == id }
    }

    func hasClue(_ id: String) -> Bool { clues.contains { $0.id == id } }

    /// 从第几个阶段开始可以说出真相（禁用词不再拦截）
    var spoilerPhaseIndex: Int {
        if let f = forbiddenUntil, let i = phases.firstIndex(where: { $0.id == f }) { return i }
        return phases.firstIndex { $0.type == .reveal } ?? phases.count
    }

    var hasVote: Bool { phases.contains { $0.type == .vote } }

    /// 禁用词可以写成“文本@阶段id”：到那个阶段才解禁（适合多重解答、真相分几次揭晓的剧本）
    func forbiddenRules() -> [(text: String, until: Int)] {
        forbidden.compactMap { f in
            if let at = f.lastIndex(of: "@") {
                let pid = String(f[f.index(after: at)...])
                if let i = phases.firstIndex(where: { $0.id == pid }) { return (String(f[..<at]), i) }
            }
            return f.isEmpty ? nil : (f, spoilerPhaseIndex)
        }
    }

    func unlockedActs(upTo phaseIndex: Int) -> [String] {
        var acts: [String] = []
        for p in phases.prefix(phaseIndex + 1) {
            for a in p.unlock where !acts.contains(a) { acts.append(a) }
        }
        return acts
    }

    /// 所有角色本里出现过的幕，按 act1、act2…… 排序
    var allActs: [String] {
        var seen: [String] = []
        for c in characters { for a in c.book where !seen.contains(a.id) { seen.append(a.id) } }
        return seen.sorted { actNumber($0) < actNumber($1) }
    }
}

func actNumber(_ act: String) -> Int {
    if act.hasPrefix("act"), let n = Int(act.dropFirst(3)) { return n }
    return 999
}

/// act1 → 第一幕
func actLabel(_ act: String) -> String {
    let n = actNumber(act)
    guard n != 999 else { return act }
    let cn = Array("一二三四五六七八九十")
    return "第" + ((1...10).contains(n) ? String(cn[n - 1]) : String(n)) + "幕"
}

// MARK: - 读取

private extension Node {
    var text: String? { null != nil && scalar?.style != .doubleQuoted && scalar?.style != .singleQuoted ? nil : string }
    func str(_ key: String) -> String { (self[key]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func rawString(_ key: String) -> String? { self[key]?.text }
    func int(_ key: String) -> Int { self[key].flatMap { $0.int ?? Int($0.string ?? "") } ?? 0 }
    func bool(_ key: String) -> Bool { self[key]?.bool ?? false }
    func list(_ key: String) -> [String] {
        guard let n = self[key] else { return [] }
        if let seq = n.sequence { return seq.compactMap { $0.string } }
        if let s = n.text, !s.isEmpty { return [s] }
        return []
    }
    var items: [Node] { sequence.map(Array.init) ?? [] }
}

enum ScriptIO {
    static func load(_ url: URL) throws -> Script {
        var folder = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let file: URL
        if isDir.boolValue {
            file = url.appendingPathComponent("script.yaml")
        } else {
            file = url
            folder = url.deletingLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ScriptError(message: "找不到剧本文件：\(file.path)")
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        let root: Node
        do {
            root = try Yams.compose(yaml: text) ?? Node.mapping(.init([]))
        } catch {
            throw ScriptError(message: "YAML 格式错误（多半是缩进或冒号问题）：\n\(error)")
        }
        let meta = root["meta"] ?? Node.mapping(.init([]))
        let dm = root["dm"] ?? Node.mapping(.init([]))

        var characters: [Character] = []
        for c in root["characters"]?.items ?? [] {
            var book: [Act] = []
            for (k, v) in c["book"]?.mapping ?? .init([]) {
                book.append(Act(id: k.string ?? "", text: (v.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            characters.append(Character(id: c.rawString("id") ?? "", name: c.str("name"), publicInfo: c.str("public"),
                                        secretBrief: c.str("secret_brief"), book: book))
        }

        var clues: [Clue] = []
        for c in root["clues"]?.items ?? [] {
            let image = c.str("image")
            clues.append(Clue(id: c.rawString("id") ?? "", title: c.str("title"), text: c.str("text"),
                              isPublic: c.bool("public"), image: image.isEmpty ? nil : image, condition: c.str("condition")))
        }

        var phases: [Phase] = []
        for p in root["phases"]?.items ?? [] {
            let search = p["search"] ?? Node.mapping(.init([]))
            let vote = p["vote"] ?? Node.mapping(.init([]))
            let locs = search["locations"]?.items.map {
                Location(id: $0.rawString("id") ?? "", name: $0.str("name"), clues: $0.list("clues"))
            } ?? []
            let id = p.rawString("id") ?? ""
            let typeRaw = p.str("type")
            let answer = vote.str("answer")
            phases.append(Phase(
                id: id, title: p.str("title").isEmpty ? id : p.str("title"),
                type: PhaseType(rawValue: typeRaw.isEmpty ? "discuss" : typeRaw) ?? .discuss,
                minutes: p.int("minutes"), dmScript: p.str("dm_script"), dmNotes: p.str("dm_notes"),
                unlock: p.list("unlock"), searchPoints: search.int("points"), locations: locs,
                grantable: p.list("grantable"),
                voteQuestion: vote.str("question").isEmpty ? "谁是凶手？" : vote.str("question"),
                voteAnswer: answer.isEmpty ? nil : answer))
            if PhaseType(rawValue: typeRaw.isEmpty ? "discuss" : typeRaw) == nil {
                throw ScriptError(message: "剧本有以下错误：\n- 阶段 \(id) 的 type '\(typeRaw)' 无效，可选：\(PhaseType.allCases.map(\.rawValue).joined(separator: ", "))")
            }
        }

        var endings: [String: String] = [:]
        for (k, v) in root["endings"]?.mapping ?? .init([]) {
            endings[k.string ?? ""] = (v.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let script = Script(
            folder: folder,
            title: meta.str("title").isEmpty ? folder.lastPathComponent : meta.str("title"),
            intro: meta.str("intro"),
            players: meta.int("players") > 0 ? meta.int("players") : characters.count,
            truth: dm.str("truth"), style: dm.str("style"), forbidden: dm.list("forbidden"),
            forbiddenUntil: dm.str("forbidden_until").isEmpty ? nil : dm.str("forbidden_until"),
            characters: characters, clues: clues, phases: phases, endings: endings)
        let errors = validate(script).filter { $0.level == .error }
        if !errors.isEmpty {
            throw ScriptError(message: "剧本有以下错误：\n- " + errors.map(\.message).joined(separator: "\n- "))
        }
        return script
    }

    // MARK: - 校验

    static func validate(_ s: Script) -> [Issue] {
        var out: [Issue] = []
        func E(_ m: String) { out.append(Issue(level: .error, message: m)) }
        func W(_ m: String) { out.append(Issue(level: .warning, message: m)) }

        if s.characters.isEmpty { E("没有角色（characters）") }
        if s.phases.isEmpty { E("没有阶段（phases）") }
        if s.truth.isEmpty { W("dm.truth 为空：AI不知道真相，问答和复盘会很弱") }

        let ids = s.characters.map(\.id)
        for dup in Set(ids.filter { id in ids.filter { $0 == id }.count > 1 }).sorted() { E("角色id重复：\(dup)") }
        var allActs = Set<String>()
        for c in s.characters {
            if c.id.isEmpty { E("有角色没有 id") }
            if c.name.isEmpty { E("角色 \(c.id) 没有 name") }
            if c.book.isEmpty { W("角色 \(c.name.isEmpty ? c.id : c.name) 没有角色本（book）") }
            allActs.formUnion(c.book.map(\.id))
        }

        let pids = s.phases.map(\.id)
        for dup in Set(pids.filter { id in pids.filter { $0 == id }.count > 1 }).sorted() { E("阶段id重复：\(dup)") }
        let cids = s.clues.map(\.id)
        for dup in Set(cids.filter { id in cids.filter { $0 == id }.count > 1 }).sorted() { E("线索id重复：\(dup)") }

        var unlocked = Set<String>()
        var used = Set<String>()
        for p in s.phases {
            for a in p.unlock {
                unlocked.insert(a)
                if !allActs.contains(a) { W("阶段 \(p.id) 解锁了幕 '\(a)'，但没有任何角色本里有这一幕") }
            }
            if p.type == .search {
                if p.locations.isEmpty { E("搜证阶段 \(p.id) 没有搜证地点（search.locations）") }
                if p.searchPoints <= 0 { W("搜证阶段 \(p.id) 的搜证次数（search.points）为0") }
            }
            for loc in p.locations {
                for cid in loc.clues {
                    used.insert(cid)
                    if !s.hasClue(cid) { E("阶段 \(p.id) 地点 \(loc.name) 引用了不存在的线索 \(cid)") }
                }
            }
            for cid in p.grantable {
                used.insert(cid)
                if !s.hasClue(cid) { E("阶段 \(p.id) 的 grantable 引用了不存在的线索 \(cid)") }
            }
            if p.type == .vote, let a = p.voteAnswer, !ids.contains(a) {
                W("投票阶段 \(p.id) 的答案 '\(a)' 不是角色id（如果答案不是角色，可以忽略）")
            }
        }
        for a in allActs.subtracting(unlocked).sorted() { W("角色本里的幕 '\(a)' 从来没有被任何阶段 unlock，玩家看不到") }
        for c in s.clues where !used.contains(c.id) {
            W("线索 \(c.id)（\(c.title)）没有放在任何地点或 grantable 里，只能由管理员手动发放")
        }
        for c in s.clues {
            if let img = c.image, !FileManager.default.fileExists(atPath: s.folder.appendingPathComponent(img).path) {
                W("线索 \(c.id) 的图片不存在：\(img)")
            }
        }
        if let f = s.forbiddenUntil, !pids.contains(f) { W("dm.forbidden_until 指向的阶段 '\(f)' 不存在") }
        for f in s.forbidden {
            if let at = f.lastIndex(of: "@"), !pids.contains(String(f[f.index(after: at)...])) {
                W("禁用词「\(f)」@ 后面的阶段 id 不存在")
            }
        }
        if !s.phases.contains(where: { $0.type == .reveal }) && s.forbiddenUntil == nil && s.forbidden.contains(where: { !$0.contains("@") }) {
            W("没有 reveal（复盘）阶段，禁用词会一直拦截。可以用 dm.forbidden_until 指定从哪个阶段开始可以说出真相")
        }
        return out
    }

    // MARK: - 写回 YAML

    static func save(_ s: Script, to folder: URL, header: String = "") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let yaml = try serialize(s)
        try (header + yaml).write(to: folder.appendingPathComponent("script.yaml"), atomically: true, encoding: .utf8)
    }

    static func serialize(_ s: Script) throws -> String {
        var root = Node.Mapping([])
        root["meta"] = map([("title", str(s.title)), ("players", Node(String(s.players), Tag(.int))), ("intro", str(s.intro))])
        var dmPairs: [(String, Node)] = [("truth", str(s.truth)), ("style", str(s.style)),
                                         ("forbidden", Node(s.forbidden.map(str)))]
        if let f = s.forbiddenUntil, !f.isEmpty { dmPairs.append(("forbidden_until", str(f))) }
        root["dm"] = map(dmPairs)
        root["characters"] = Node(s.characters.map { c in
            map([("id", str(c.id)), ("name", str(c.name)), ("public", str(c.publicInfo)),
                 ("secret_brief", str(c.secretBrief)),
                 ("book", map(c.book.map { ($0.id, str($0.text)) }))])
        })
        root["clues"] = Node(s.clues.map { c in
            var pairs: [(String, Node)] = [("id", str(c.id)), ("title", str(c.title)), ("text", str(c.text))]
            if c.isPublic { pairs.append(("public", Node("true", Tag(.bool)))) }
            if let img = c.image, !img.isEmpty { pairs.append(("image", str(img))) }
            if !c.condition.isEmpty { pairs.append(("condition", str(c.condition))) }
            return map(pairs)
        })
        root["phases"] = Node(s.phases.map { p in
            var pairs: [(String, Node)] = [("id", str(p.id)), ("title", str(p.title)),
                                           ("type", str(p.type.rawValue)), ("minutes", Node(String(p.minutes), Tag(.int)))]
            if !p.dmScript.isEmpty { pairs.append(("dm_script", str(p.dmScript))) }
            if !p.dmNotes.isEmpty { pairs.append(("dm_notes", str(p.dmNotes))) }
            if !p.unlock.isEmpty {
                pairs.append(("unlock", p.unlock.count == 1 ? str(p.unlock[0]) : Node(p.unlock.map(str))))
            }
            if p.type == .search || !p.locations.isEmpty {
                pairs.append(("search", map([
                    ("points", Node(String(p.searchPoints), Tag(.int))),
                    ("locations", Node(p.locations.map { l in
                        map([("id", str(l.id)), ("name", str(l.name)),
                             ("clues", Node(l.clues.map(str), Tag(.implicit), .flow))])
                    })),
                ])))
            }
            if !p.grantable.isEmpty { pairs.append(("grantable", Node(p.grantable.map(str), Tag(.implicit), .flow))) }
            if p.type == .vote {
                var v: [(String, Node)] = [("question", str(p.voteQuestion))]
                if let a = p.voteAnswer, !a.isEmpty { v.append(("answer", str(a))) }
                pairs.append(("vote", map(v)))
            }
            return map(pairs)
        })
        root["endings"] = map(["correct", "wrong"].compactMap { k in s.endings[k].flatMap { $0.isEmpty ? nil : (k, str($0)) } })
        return try Yams.serialize(node: .mapping(root), width: -1, allowUnicode: true)
    }

    private static func map(_ pairs: [(String, Node)]) -> Node {
        Node(pairs.map { (Node($0.0), $0.1) })
    }

    /// 字符串节点：多行用 | 块，看起来像数字/布尔的加引号，保证读回来还是字符串
    private static func str(_ s: String) -> Node {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("\n") { return Node(t + "\n", Tag(.str), .literal) }
        let looksTyped = ["true", "false", "yes", "no", "null", "~", "on", "off"].contains(t.lowercased())
            || Double(t) != nil || t.isEmpty
        return Node(t, Tag(.str), looksTyped ? .doubleQuoted : .any)
    }
}
