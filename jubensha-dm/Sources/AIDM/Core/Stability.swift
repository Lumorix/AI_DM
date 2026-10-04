import Foundation

enum Stability {
    static let defaultContextBudget = 32768

    // Conservative text estimate, not a vendor-specific tokenizer.
    static func estimate(_ messages: [ChatMessage], outputTokens: Int) throws -> Int {
        var cost = 512 + outputTokens
        for message in messages {
            cost += 16 + message.role.utf8.count
            if let text = message.content as? String {
                cost += text.utf8.count
            } else if let parts = message.content as? [[String: Any]] {
                for part in parts {
                    if part["type"] as? String == "text", let text = part["text"] as? String {
                        cost += text.utf8.count
                    } else if part["type"] as? String == "image_url" {
                        cost += 4096 // Provisional reserve; actual image token usage varies by provider.
                    } else { throw LLMError(message: "不支持的多模态内容，无法估算上下文") }
                }
            } else { throw LLMError(message: "不支持的消息内容，无法估算上下文") }
        }
        return cost
    }

    static func check(_ messages: [ChatMessage], outputTokens: Int, budget: Int) throws {
        guard outputTokens > 0, budget >= 1024 else { throw LLMError(message: "上下文预算或输出长度无效") }
        let cost = try estimate(messages, outputTokens: outputTokens)
        guard cost <= budget else {
            throw LLMError(message: "上下文估算 \(cost) 超过预算 \(budget)，请求未发送。请缩小剧本/历史，或按模型容量调整预算。")
        }
    }

    static func summary(_ model: any GameLanguageModel, messages: [ChatMessage], maxTokens: Int) async throws -> String {
        for attempt in 0..<2 {
            let request = attempt == 0 ? messages : messages + [.user("上次摘要为空或超过600字。请重新压缩为非空、600字以内的完整摘要；保留关键事实，只输出摘要。")]
            let text = try await model.chat(request, maxTokens: maxTokens).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && text.unicodeScalars.count <= 600 { return text }
        }
        throw LLMError(message: "摘要两次未满足非空且600字以内要求，保留旧摘要及未压缩记录")
    }
}
