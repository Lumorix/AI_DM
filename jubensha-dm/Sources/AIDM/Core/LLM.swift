// AI 接口：统一走 OpenAI 兼容格式。
// 云端（DeepSeek / 通义千问 / Claude 兼容接口等）和本地（Ollama / LM Studio / vLLM）都提供这个格式，
// 所以切换模型只需要改地址和模型名。provider = mock 时完全不调用AI，用来测试流程。
import Foundation

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ChatMessage {
    var role: String
    var content: Any          // String，或视觉模型用的 [[String: Any]]

    static func system(_ s: String) -> ChatMessage { ChatMessage(role: "system", content: s) }
    static func user(_ s: String) -> ChatMessage { ChatMessage(role: "user", content: s) }
    var text: String { content as? String ?? "" }
    var json: [String: Any] { ["role": role, "content": content] }
}

struct LLMConfig: Codable, Equatable {
    var provider: Provider = .mock
    var baseURL = ""
    var model = ""
    var temperature = 0.7
    var timeout = 180.0
    var maxTokens = 1500
    var contextBudget: Int? = nil // nil keeps older saved settings compatible; default 32768
    var extraBody = ""           // 可选：附加到请求里的 JSON，例如 {"enable_thinking": false}

    enum Provider: String, Codable { case mock, openai }

    var isConfigured: Bool { provider == .mock || (!baseURL.isEmpty && !model.isEmpty) }
}

/// 去掉推理模型（Qwen3、DeepSeek-R1 等）输出的 <think>…</think> 部分
func stripThink(_ text: String) -> String {
    var t = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
    if let r = t.range(of: "<think>") { t = String(t[..<r.lowerBound]) }    // 没闭合：思考还没结束，正文为空
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 从模型输出里尽量抠出 JSON；抠不出就把整段当作回复
func parseJSONReply(_ raw: String) -> [String: Any] {
    let text = stripThink(raw)
    var candidates: [String] = []
    if let m = text.range(of: "```(?:json)?\\s*(\\{[\\s\\S]*?\\})\\s*```", options: .regularExpression) {
        var inner = String(text[m])
        inner = inner.replacingOccurrences(of: "^```(?:json)?\\s*", with: "", options: .regularExpression)
        inner = inner.replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        candidates.append(inner)
    }
    if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e {
        candidates.append(String(text[s...e]))
    }
    for c in candidates {
        if let d = c.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return v }
    }
    return ["reply": text]
}

/// 游戏仅依赖此接口；测试可控制回答完成时机，无需访问真实模型。
protocol GameLanguageModel: Sendable {
    var label: String { get }
    func chat(_ messages: [ChatMessage], maxTokens: Int?) async throws -> String
    func stream(_ messages: [ChatMessage], maxTokens: Int?) -> AsyncThrowingStream<String, Error>
}

final class LLM: GameLanguageModel, @unchecked Sendable {
    let config: LLMConfig
    let apiKey: String

    init(_ config: LLMConfig, apiKey: String) throws {
        self.config = config
        let env = ProcessInfo.processInfo.environment["JUBENSHA_API_KEY"] ?? ""
        self.apiKey = apiKey.isEmpty ? (env.isEmpty ? "none" : env) : apiKey
        if config.provider != .mock && (config.baseURL.isEmpty || config.model.isEmpty) {
            throw LLMError(message: "AI 设置里的接口地址和模型名不能为空（或者先用模拟模式测试）")
        }
    }

    var isMock: Bool { config.provider == .mock }
    var label: String { isMock ? "模拟模式（未接AI）" : "\(config.model) @ \(base)" }
    private var base: String { config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    // MARK: 底层 HTTP

    private func request(_ messages: [ChatMessage], stream: Bool, maxTokens: Int?) throws -> URLRequest {
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError(message: "接口地址不对：\(base)") }
        var payload: [String: Any] = [
            "model": config.model, "messages": messages.map(\.json), "temperature": config.temperature,
            "max_tokens": maxTokens ?? config.maxTokens, "stream": stream,
        ]
        if !config.extraBody.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let d = config.extraBody.data(using: .utf8),
                  let extra = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw LLMError(message: "附加参数不是合法的 JSON 对象")
            }
            let reserved: Set<String> = ["model", "messages", "max_tokens", "max_completion_tokens", "stream"]
            guard reserved.isDisjoint(with: Set(extra.keys)) else {
                throw LLMError(message: "附加参数不能覆盖模型、消息、输出长度或流式参数")
            }
            let overhead = try JSONSerialization.data(withJSONObject: extra).count
            try Stability.check(messages, outputTokens: maxTokens ?? config.maxTokens,
                                budget: (config.contextBudget ?? Stability.defaultContextBudget) - overhead)
            payload.merge(extra) { _, new in new }
        }
        try Stability.check(messages, outputTokens: maxTokens ?? config.maxTokens,
                            budget: config.contextBudget ?? Stability.defaultContextBudget)
        var r = URLRequest(url: url, timeoutInterval: config.timeout)
        r.httpMethod = "POST"
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return r
    }

    private func connectError(_ e: Error) -> LLMError {
        LLMError(message: "连不上AI接口 \(base)：\(e.localizedDescription)")
    }

    // MARK: 对外接口

    func chat(_ messages: [ChatMessage], maxTokens: Int? = nil) async throws -> String {
        if isMock {
            try Stability.check(messages, outputTokens: maxTokens ?? config.maxTokens, budget: config.contextBudget ?? Stability.defaultContextBudget)
            return mockReply(messages)
        }
        let req = try request(messages, stream: false, maxTokens: maxTokens)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch is CancellationError {
            throw CancellationError()
        } catch { throw connectError(error) }
        let body = String(decoding: data, as: UTF8.self)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw LLMError(message: "AI接口返回 \(h.statusCode)：\(body.prefix(300))")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any] else {
            throw LLMError(message: "AI返回格式看不懂：\(body.prefix(300))")
        }
        return stripThink(msg["content"] as? String ?? "")
    }

    /// 逐段产出文字；自动吞掉 <think> 部分
    func stream(_ messages: [ChatMessage], maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    if isMock {
                        try Stability.check(messages, outputTokens: maxTokens ?? config.maxTokens, budget: config.contextBudget ?? Stability.defaultContextBudget)
                        let text = mockReply(messages)
                        var i = text.startIndex
                        while i < text.endIndex {
                            try await Task.sleep(nanoseconds: 20_000_000)
                            let j = text.index(i, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
                            cont.yield(String(text[i..<j]))
                            i = j
                        }
                        cont.finish()
                        return
                    }
                    let req = try request(messages, stream: true, maxTokens: maxTokens)
                    let bytes: URLSession.AsyncBytes, resp: URLResponse
                    do { (bytes, resp) = try await URLSession.shared.bytes(for: req) } catch is CancellationError {
                        throw CancellationError()
                    } catch { throw connectError(error) }
                    if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 600 { break } }
                        throw LLMError(message: "AI接口返回 \(h.statusCode)：\(String(decoding: body, as: UTF8.self).prefix(300))")
                    }
                    var filter = ThinkFilter()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if data == "[DONE]" { break }
                        guard let d = data.data(using: .utf8),
                              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let choices = j["choices"] as? [[String: Any]],
                              let delta = (choices.first?["delta"] as? [String: Any])?["content"] as? String,
                              !delta.isEmpty else { continue }
                        let out = filter.feed(delta)
                        if !out.isEmpty { cont.yield(out) }
                    }
                    let tail = filter.finish()
                    if !tail.isEmpty { cont.yield(tail) }
                    cont.finish()
                } catch is CancellationError {
                    cont.finish(throwing: CancellationError())
                } catch let e as LLMError {
                    cont.finish(throwing: e)
                } catch {
                    if Task.isCancelled { cont.finish(throwing: CancellationError()) } else { cont.finish(throwing: connectError(error)) }
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// 给视觉模型发一张图（OCR 用）
    func vision(jpeg: Data, prompt: String) async throws -> String {
        if isMock { return "（模拟OCR文字）" }
        let msg = ChatMessage(role: "user", content: [
            ["type": "text", "text": prompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
        ] as [[String: Any]])
        return try await chat([msg], maxTokens: 4000)
    }

    /// 设置页的“测试连接”
    func ping() async throws -> String {
        try await chat([.user("请只回复两个字：收到")], maxTokens: 20)
    }
}

/// 流式过滤 <think>…</think>
struct ThinkFilter {
    private var buf = ""
    private var inThink = false
    private var started = false

    mutating func feed(_ delta: String) -> String {
        buf += delta
        var out = ""
        while !buf.isEmpty {
            if inThink {
                guard let end = buf.range(of: "</think>") else { buf = String(buf.suffix(8)); break }
                buf = String(buf[end.upperBound...]); inThink = false
            } else {
                guard let start = buf.range(of: "<think>") else {
                    // 末尾可能是半个 "<think>"，先留着等下一段
                    var keep = 0
                    for k in stride(from: min(6, buf.count), through: 1, by: -1) where "<think>".hasPrefix(String(buf.suffix(k))) {
                        keep = k; break
                    }
                    out += buf.dropLast(keep); buf = String(buf.suffix(keep))
                    break
                }
                out += buf[..<start.lowerBound]; buf = String(buf[start.upperBound...]); inThink = true
            }
        }
        if !started {
            out = String(out.drop { $0.isWhitespace })
            started = !out.isEmpty
        }
        return out
    }

    mutating func finish() -> String { inThink ? "" : buf }
}

// MARK: - 模拟模式

private func mockReply(_ messages: [ChatMessage]) -> String {
    let sys = messages.first?.text ?? ""
    let last = messages.last?.text ?? ""
    if sys.contains("【任务：问答】") {
        let q = String((last.components(separatedBy: "问题：").last ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let reply = "（模拟回答）关于“\(q)”，剧本中没有更多可以告诉你的。"
        let d = try? JSONSerialization.data(withJSONObject: ["reply": reply, "give_clue": NSNull()])
        return d.map { String(decoding: $0, as: UTF8.self) } ?? reply
    }
    if sys.contains("【任务：摘要】") {
        return "（模拟摘要）" + String(last.suffix(300)).replacingOccurrences(of: "\n", with: " ")
    }
    if sys.contains("【任务：旁白】") || sys.contains("【任务：复盘】") {
        if last.contains("<<<") {
            let body = (last.components(separatedBy: "<<<").last ?? "").components(separatedBy: ">>>").first ?? ""
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "（模拟旁白）" : t
        }
        return last.isEmpty ? "（模拟旁白）" : last
    }
    if messages.count == 1 { return "收到" }
    return "（模拟回复）"
}
