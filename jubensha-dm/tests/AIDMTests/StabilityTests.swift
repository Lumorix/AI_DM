import Foundation
import XCTest
@testable import AIDM

private actor SummaryModel: GameLanguageModel {
    nonisolated let label = "summary-test"
    private var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func chat(_ messages: [ChatMessage], maxTokens: Int?) async throws -> String { replies.removeFirst() }
    nonisolated func stream(_ messages: [ChatMessage], maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class StabilityTests: XCTestCase {
    func testPendingPublicBacklogIsNotDropped() {
        var state = GameState(scriptTitle: "Test")
        for i in 0..<60 { state.logPublic(.note, "玩家", String(format: "事件%03d", i)) }
        state.summarizedUpto = 10
        let context = Prompts.memoryBlock(state, recent: 30)
        XCTAssertFalse(context.contains("事件009"))
        XCTAssertTrue(context.contains("事件010"))
        XCTAssertTrue(context.contains("事件059"))
    }

    func testPendingPrivateBacklogStaysPrivate() {
        var script = Script(folder: URL(fileURLWithPath: "/tmp/unused"), title: "Test")
        script.characters = [Character(id: "p1", name: "甲")]
        script.phases = [Phase(id: "p0", title: "阶段", type: .discuss)]
        var state = GameState(scriptTitle: script.title)
        state.players["p1"] = Player(charId: "p1", name: "玩家", token: "test")
        for i in 0..<30 { state.logPrivate("p1", .ask, "玩家", String(format: "私事%03d", i)) }
        state.privateSummarizedUpto["p1"] = 5
        let privateText = Prompts.ask(script, state, script.phases[0], charId: "p1", question: "问题", isPublic: false, recent: 30, privateKeep: 12).map(\.text).joined()
        let publicText = Prompts.ask(script, state, script.phases[0], charId: "p1", question: "问题", isPublic: true, recent: 30, privateKeep: 12).map(\.text).joined()
        XCTAssertTrue(privateText.contains("私事005"))
        XCTAssertFalse(privateText.contains("私事004"))
        XCTAssertFalse(publicText.contains("私事005"))
    }

    func testBudgetIncludesChineseEmojiAndOutput() throws {
        XCTAssertEqual(try Stability.estimate([.user("中🙂")], outputTokens: 500), 512 + 500 + 16 + 4 + 7)
        XCTAssertThrowsError(try Stability.check([.user(String(repeating: "中", count: 1000))], outputTokens: 100, budget: 2048))
        XCTAssertThrowsError(try Stability.check([.user("短句")], outputTokens: 2000, budget: 2048))
    }

    func testSafeBudgetAndInvalidBudget() throws {
        XCTAssertNoThrow(try Stability.check([.system("规则"), .user("问题")], outputTokens: 100, budget: 2048))
        XCTAssertThrowsError(try Stability.check([], outputTokens: 0, budget: 2048))
    }

    func testLegacyConfigDecodesWithoutBudget() throws {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(LLMConfig())) as! [String: Any]
        object.removeValue(forKey: "contextBudget")
        let old = try JSONDecoder().decode(LLMConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.contextBudget)
    }

    func testSummaryRetriesAndAcceptsValidResult() async throws {
        let model = SummaryModel([String(repeating: "字", count: 601), "有效摘要"])
        let result = try await Stability.summary(model, messages: [.user("历史")], maxTokens: 1200)
        XCTAssertEqual(result, "有效摘要")
    }

    func testSummaryRejectsBothInvalidResults() async {
        let model = SummaryModel([" ", String(repeating: "字", count: 601)])
        do {
            _ = try await Stability.summary(model, messages: [.user("历史")], maxTokens: 1200)
            XCTFail("must reject")
        } catch { XCTAssertTrue(error is LLMError) }
    }

    func testSixHundredCharacterSummaryAccepted() async throws {
        let text = String(repeating: "字", count: 600)
        let result = try await Stability.summary(SummaryModel([text]), messages: [.user("历史")], maxTokens: 1200)
        XCTAssertEqual(result, text)
    }

    func testOCRIdentityIncludesContentAndOptions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("same.pdf")
        try Data("first".utf8).write(to: file)
        let options = OCROptions()
        let original = try OCR.cacheIdentity(file, options: options, llm: nil)
        XCTAssertEqual(original, try OCR.cacheIdentity(file, options: options, llm: nil))
        var changed = options
        changed.dpi = 300
        XCTAssertNotEqual(original, try OCR.cacheIdentity(file, options: changed, llm: nil))
        changed = options; changed.split = true
        XCTAssertNotEqual(original, try OCR.cacheIdentity(file, options: changed, llm: nil))
        try Data("second".utf8).write(to: file)
        XCTAssertNotEqual(original, try OCR.cacheIdentity(file, options: options, llm: nil))
    }

    func testOCRDirectoryPageOrderAndMembership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("one".utf8).write(to: directory.appendingPathComponent("1.png"))
        let before = try OCR.cacheIdentity(directory, options: OCROptions(), llm: nil)
        try Data("two".utf8).write(to: directory.appendingPathComponent("2.png"))
        XCTAssertNotEqual(before, try OCR.cacheIdentity(directory, options: OCROptions(), llm: nil))
    }
}
