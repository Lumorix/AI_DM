// 用 AI 把 OCR 出来的文字整理成剧本初稿。
// 一般一套剧本杀是：DM 手册 + 每人一本角色本 + 线索卡。角色本按“第X幕”切分、原文照搬，不经过 AI 改写；
// DM 手册和线索卡交给 AI 提取：真相、阶段流程、主持词、搜证地点和线索、凶手、结局。
// 只有 DM 手册（没有角色本）也行：角色从手册里提取。
// 生成的是初稿！一定要在编辑器里人工检查：阶段顺序、每个搜证地点的线索、真相、凶手。
import Foundation

struct DraftInput {
    var title = ""
    var dm: String?                         // DM 手册全文
    var characters: [(name: String, text: String)] = []
    var clues: [String] = []                // 线索卡全文
}

enum Drafter {
    static let chunkSize = 6000
    static let cnNum = Array("一二三四五六七八九十")

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^=== 第\\d+页 ===$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func chunks(_ text: String, size: Int = chunkSize) -> [String] {
        var out: [String] = [], cur = ""
        for p in text.components(separatedBy: "\n") {
            if cur.count + p.count > size && !cur.isEmpty { out.append(cur); cur = "" }
            cur += p + "\n"
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out
    }

    static func cn2int(_ s: String) -> Int {
        if let n = Int(s) { return n }
        let c = Array(s)
        func idx(_ ch: Swift.Character) -> Int { (cnNum.firstIndex(of: ch) ?? 0) + 1 }
        if s == "十" { return 10 }
        if c.first == "十" { return 10 + (c.count > 1 ? idx(c[1]) : 0) }
        if let t = c.firstIndex(of: "十") { return idx(c[0]) * 10 + (t + 1 < c.count ? idx(c[t + 1]) : 0) }
        return c.first.map(idx) ?? 1
    }

    /// 按“第X幕”切分角色本；没有标题就整本当作 act1
    static func splitActs(_ text: String) -> [Act] {
        let re = try! NSRegularExpression(pattern: "^\\s*[【\\[（(]?\\s*第\\s*([一二三四五六七八九十\\d]+)\\s*[幕章卷部]\\s*[】\\]）)]?.{0,20}$",
                                          options: [.anchorsMatchLines])
        let ns = text as NSString
        let marks = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ($0.range.location, cn2int(ns.substring(with: $0.range(at: 1)))) }
        guard !marks.isEmpty else { return [Act(id: "act1", text: text.trimmingCharacters(in: .whitespacesAndNewlines))] }
        var acts: [Act] = []
        let pre = ns.substring(to: marks[0].0).trimmingCharacters(in: .whitespacesAndNewlines)
        for (i, (pos, n)) in marks.enumerated() {
            let end = i + 1 < marks.count ? marks[i + 1].0 : ns.length
            let body = ns.substring(with: NSRange(location: pos, length: end - pos)).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "act\(n)"
            if let k = acts.firstIndex(where: { $0.id == key }) { acts[k].text += "\n\n" + body } else { acts.append(Act(id: key, text: body)) }
        }
        if !pre.isEmpty { acts[0].text = pre + "\n\n" + acts[0].text }   // 第一幕之前的内容（人物介绍等）并进第一幕
        return acts
    }

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "[\\s【】\\[\\]（）()《》“”\"'：:，,。.]", with: "", options: .regularExpression)
    }

    // MARK: 提示词

    static func dmPrompt(_ i: Int, _ n: Int, _ text: String, needCharacters: Bool) -> String {
        """
        你在帮人把剧本杀的DM手册整理成结构化数据。下面是DM手册的第\(i)/\(n)段（OCR识别，可能有错字，请按上下文纠正）。
        请提取本段中出现的信息，输出JSON（本段没有的字段给空字符串/空数组）：
        {
          "truth": "本段涉及的案件真相、作案经过、完整时间线（尽量完整保留细节）",
          "murderer": "凶手的角色名（本段没提到就空）",
          "style": "对主持风格的要求",
          "phases": [
            {"title": "阶段名", "type": "narration/reading/discuss/search/vote/reveal 之一",
              "minutes": 建议时长数字或0,
              "dm_script": "主持人需要对玩家念的原话（尽量保留原文）",
              "dm_notes": "只给主持人看的提示、注意事项",
              "unlock": "这个阶段让玩家阅读第几幕，如'第一幕'，没有就空",
              "points": 每人搜证次数或0,
              "locations": [{"name": "搜证地点", "clues": ["该地点可搜到的线索标题"]}]
            }
          ],
          "clues": [{"title": "线索标题", "text": "线索内容原文", "location": "所在地点", "round": 第几轮搜证或0}],
          \(needCharacters ? "\"characters\": [{\"name\": \"玩家扮演的角色名\", \"public\": \"50字以内公开简介，不含秘密\", \"secret_brief\": \"150字以内只给AI看的秘密：隐瞒了什么、真实行踪、是否凶手\"}],\n  " : "")"endings": {"correct": "投对凶手的结局", "wrong": "投错的结局"}
        }
        type 判断：念开场/背景=narration，读剧本/演小剧场=reading，自我介绍/讨论=discuss，搜证=search，投票=vote，复盘/揭晓真相=reveal。
        只输出JSON。

        \(text)
        """
    }

    static func cluePrompt(_ i: Int, _ n: Int, _ text: String) -> String {
        """
        下面是剧本杀线索卡的OCR文字（第\(i)/\(n)段，可能有错字，请纠正）。提取每一张线索卡，输出JSON：
        {"clues": [{"title": "线索标题", "text": "线索内容原文", "location": "搜到的地点（卡上有写的话）", "round": 第几轮或0}]}
        只输出JSON。

        \(text)
        """
    }

    static func charPrompt(_ name: String, _ text: String) -> String {
        """
        下面是剧本杀角色「\(name)」的角色本（OCR文字，可能有错字）。输出JSON：
        {"public": "50字以内的公开简介：身份、和死者关系。不能包含任何秘密",
          "secret_brief": "150字以内，只给AI主持人看：这个角色隐瞒了什么、案发时的真实行踪、是否是凶手、有什么需要守住的秘密"}
        只输出JSON。

        \(text)
        """
    }

    // MARK: 主流程

    static func askJSON(_ llm: LLM, _ prompt: String, _ label: String, log: (String) -> Void) async -> [String: Any] {
        do {
            let raw = try await llm.chat([.user(prompt)], maxTokens: 4000)
            let d = parseJSONReply(raw)
            if d.count == 1 && d["reply"] != nil {
                log("⚠ \(label)：AI没有按JSON格式输出，这部分需要手动整理")
                return [:]
            }
            return d
        } catch {
            log("⚠ \(label) 失败：\(error.localizedDescription)")
            return [:]
        }
    }

    private static func s(_ v: Any?) -> String {
        switch v {
        case let x as String: x
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    private static func i(_ v: Any?) -> Int {
        switch v {
        case let n as NSNumber: n.intValue
        case let x as String: Int(x) ?? 0
        default: 0
        }
    }

    static func draft(_ input: DraftInput, llm: LLM, into folder: URL, log: @escaping (String) -> Void) async throws -> Script {
        log("使用模型：\(llm.label)")

        // ---- 角色本：原文分幕 ----
        var characters: [Character] = []
        var allActs: [String] = []
        for (n, c) in input.characters.enumerated() {
            let text = clean(c.text)
            let acts = splitActs(text)
            for a in acts where !allActs.contains(a.id) { allActs.append(a.id) }
            log("角色本《\(c.name)》：\(text.count)字，分成 \(acts.count) 幕（\(acts.map(\.id).joined(separator: ", "))）")
            let sample = text.count > 9500 ? String(text.prefix(7000)) + "\n……\n" + String(text.suffix(2500)) : text
            let info = await askJSON(llm, charPrompt(c.name, sample), "角色《\(c.name)》简介", log: log)
            characters.append(Character(id: "r\(n + 1)", name: c.name.trimmingCharacters(in: .whitespaces),
                                        publicInfo: s(info["public"]).isEmpty ? "TODO：公开简介" : s(info["public"]),
                                        secretBrief: s(info["secret_brief"]).isEmpty ? "TODO：给AI看的秘密摘要" : s(info["secret_brief"]),
                                        book: acts))
        }
        allActs.sort { actNumber($0) < actNumber($1) }
        let needCharacters = characters.isEmpty

        // ---- DM 手册 ----
        var truthParts: [String] = [], phases: [[String: Any]] = [], cluesRaw: [[String: Any]] = []
        var murderer = "", style = "", endings = ["correct": "", "wrong": ""]
        var dmChars: [[String: Any]] = []
        if let dm = input.dm {
            let text = clean(dm)
            let cs = chunks(text)
            log("DM手册：\(text.count)字，分 \(cs.count) 段交给AI")
            for (k, c) in cs.enumerated() {
                try Task.checkCancellation()
                let d = await askJSON(llm, dmPrompt(k + 1, cs.count, c, needCharacters: needCharacters), "DM手册第\(k + 1)段", log: log)
                let ps = d["phases"] as? [[String: Any]] ?? []
                let cl = d["clues"] as? [[String: Any]] ?? []
                log("  第\(k + 1)/\(cs.count)段：\(ps.count)个阶段，\(cl.count)条线索")
                if !s(d["truth"]).isEmpty { truthParts.append(s(d["truth"])) }
                if murderer.isEmpty { murderer = s(d["murderer"]) }
                if style.isEmpty { style = s(d["style"]) }
                for key in ["correct", "wrong"] {
                    let v = s((d["endings"] as? [String: Any])?[key])
                    if v.count > (endings[key] ?? "").count { endings[key] = v }
                }
                for p in ps where !s(p["title"]).isEmpty {
                    if let j = phases.firstIndex(where: { norm(s($0["title"])) == norm(s(p["title"])) }) {
                        for (kk, v) in p {     // 合并同名阶段：字符串取更长的，数字取非零的，数组拼接
                            if let str = v as? String, str.count > s(phases[j][kk]).count { phases[j][kk] = str }
                            else if let n = v as? NSNumber, n.intValue != 0, i(phases[j][kk]) == 0 { phases[j][kk] = n }
                            else if let arr = v as? [Any], !arr.isEmpty { phases[j][kk] = (phases[j][kk] as? [Any] ?? []) + arr }
                        }
                    } else {
                        phases.append(p)
                    }
                }
                cluesRaw += cl.filter { !s($0["title"]).isEmpty }
                for ch in d["characters"] as? [[String: Any]] ?? [] where !s(ch["name"]).isEmpty {
                    if let j = dmChars.firstIndex(where: { norm(s($0["name"])) == norm(s(ch["name"])) }) {
                        for kk in ["public", "secret_brief"] where s(ch[kk]).count > s(dmChars[j][kk]).count { dmChars[j][kk] = ch[kk] }
                    } else {
                        dmChars.append(ch)
                    }
                }
            }
        }
        if needCharacters {
            characters = dmChars.enumerated().map { n, ch in
                Character(id: "r\(n + 1)", name: s(ch["name"]),
                          publicInfo: s(ch["public"]).isEmpty ? "TODO：公开简介" : s(ch["public"]),
                          secretBrief: s(ch["secret_brief"]).isEmpty ? "TODO：给AI看的秘密摘要" : s(ch["secret_brief"]))
            }
            log("从DM手册里找到 \(characters.count) 个角色：\(characters.map(\.name).joined(separator: "、"))")
        }

        // ---- 线索卡 ----
        for (n, t) in input.clues.enumerated() {
            let text = clean(t)
            let cs = chunks(text)
            log("线索卡 \(n + 1)：\(text.count)字，分 \(cs.count) 段")
            for (k, c) in cs.enumerated() {
                try Task.checkCancellation()
                let d = await askJSON(llm, cluePrompt(k + 1, cs.count, c), "线索卡第\(k + 1)段", log: log)
                cluesRaw += (d["clues"] as? [[String: Any]] ?? []).filter { !s($0["title"]).isEmpty }
            }
        }

        // ---- 合并线索 ----
        struct RawClue { var id, title, text, location: String; var round: Int }
        var clues: [RawClue] = []
        for c in cluesRaw {
            if let j = clues.firstIndex(where: { norm($0.title) == norm(s(c["title"])) }) {
                if s(c["text"]).count > clues[j].text.count { clues[j].text = s(c["text"]) }
                if clues[j].location.isEmpty { clues[j].location = s(c["location"]) }
                if clues[j].round == 0 { clues[j].round = i(c["round"]) }
            } else {
                clues.append(RawClue(id: "c\(clues.count + 1)", title: s(c["title"]).trimmingCharacters(in: .whitespaces),
                                     text: s(c["text"]), location: s(c["location"]), round: i(c["round"])))
            }
        }
        func findClue(_ title: String) -> RawClue? {
            let t = norm(title)
            return clues.first { norm($0.title) == t }
                ?? clues.first { !t.isEmpty && (norm($0.title).contains(t) || t.contains(norm($0.title))) }
        }

        // ---- 组装阶段 ----
        if phases.isEmpty {
            phases = [["title": "开场", "type": "narration", "dm_script": "TODO"],
                      ["title": "阅读第一幕", "type": "reading", "unlock": "第一幕"],
                      ["title": "搜证", "type": "search", "points": 2, "locations": [] as [Any]],
                      ["title": "讨论", "type": "discuss"], ["title": "投票", "type": "vote"], ["title": "复盘", "type": "reveal"]]
        }
        var outPhases: [Phase] = []
        var used = Set<String>()
        var searchN = 0, readingN = 0
        let mm = characters.first { !murderer.isEmpty && ($0.name.contains(murderer) || murderer.contains($0.name)) }
        for (k, p) in phases.enumerated() {
            let type = PhaseType(rawValue: s(p["type"])) ?? .discuss
            var ph = Phase(id: "p\(k + 1)", title: s(p["title"]), type: type, minutes: i(p["minutes"]),
                           dmScript: s(p["dm_script"]), dmNotes: s(p["dm_notes"]))
            let unlock = s(p["unlock"])
            if let r = unlock.range(of: "第\\s*([一二三四五六七八九十\\d]+)\\s*[幕章]", options: .regularExpression) {
                let num = unlock[r].replacingOccurrences(of: "[第幕章\\s]", with: "", options: .regularExpression)
                ph.unlock = ["act\(cn2int(num))"]
            } else if type == .reading && readingN < allActs.count {
                ph.unlock = [allActs[readingN]]
            }
            if type == .reading { readingN += 1 }
            if type == .search {
                searchN += 1
                var locs: [(name: String, clues: [String])] = []
                for l in p["locations"] as? [[String: Any]] ?? [] {
                    var ids: [String] = []
                    for t in l["clues"] as? [Any] ?? [] {
                        if let c = findClue(s(t)), !used.contains(c.id) { ids.append(c.id); used.insert(c.id) }
                    }
                    locs.append((s(l["name"]).isEmpty ? "未命名地点" : s(l["name"]), ids))
                }
                // 线索卡上写了轮次/地点、但DM手册没列出的，补进去
                for c in clues where !used.contains(c.id) {
                    if c.round != 0 && c.round != searchN { continue }
                    if c.round == 0 && (c.location.isEmpty || searchN > 1) { continue }
                    if let j = locs.firstIndex(where: { !c.location.isEmpty && norm(c.location) == norm($0.name) }) {
                        locs[j].clues.append(c.id)
                    } else {
                        locs.append((c.location.isEmpty ? "其他" : c.location, [c.id]))
                    }
                    used.insert(c.id)
                }
                ph.searchPoints = i(p["points"]) > 0 ? i(p["points"]) : 2
                ph.locations = locs.enumerated().map { j, l in Location(id: "l\(searchN)_\(j + 1)", name: l.name, clues: l.clues) }
            }
            if type == .vote { ph.voteAnswer = mm?.id }
            outPhases.append(ph)
        }
        if !outPhases.contains(where: { $0.type == .reveal }) {
            outPhases.append(Phase(id: "p\(outPhases.count + 1)", title: "真相复盘", type: .reveal))
        }

        let mname = mm?.name ?? murderer
        let forbidden = mname.isEmpty ? [] : ["凶手是\(mname)", "\(mname)是凶手", "\(mname)就是凶手", "是\(mname)杀的", "\(mname)杀了"]
        let script = Script(
            folder: folder, title: input.title.isEmpty ? folder.lastPathComponent : input.title,
            intro: "TODO：一句话简介（所有人可见）", players: characters.count,
            truth: truthParts.isEmpty ? "TODO：完整真相" : truthParts.joined(separator: "\n\n"),
            style: style.isEmpty ? "语气沉稳，有悬念感。不抢玩家的推理。" : style, forbidden: forbidden,
            characters: characters, clues: clues.map { Clue(id: $0.id, title: $0.title, text: $0.text) },
            phases: outPhases, endings: endings.filter { !$0.value.isEmpty })

        try ScriptIO.save(script, to: folder, header: "# AI 整理的初稿，请在剧本编辑器里人工检查！\n"
            + "# 重点：阶段顺序 / 每个搜证地点的线索 / 真相是否完整 / 凶手(vote.answer) / forbidden 防剧透词\n\n")
        let unused = clues.filter { !used.contains($0.id) }
        log("写入 \(folder.lastPathComponent)/script.yaml")
        log("  \(characters.count)个角色 · \(outPhases.count)个阶段 · \(clues.count)条线索 · 凶手：\(mname.isEmpty ? "未识别" : mname)")
        if !unused.isEmpty {
            log("  ⚠ \(unused.count)条线索没分配到搜证地点：\(unused.prefix(8).map(\.title).joined(separator: "、"))（可以放进某阶段的搜证地点或 AI 可发放线索，或留给主持人手动发）")
        }
        return script
    }
}
