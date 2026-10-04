import Foundation
import XCTest
@testable import AIDM

private actor DeferredModel: GameLanguageModel {
    nonisolated let label = "test"
    let requested: XCTestExpectation
    private var pending: CheckedContinuation<String, Error>?

    init(requested: XCTestExpectation) { self.requested = requested }

    func chat(_ messages: [ChatMessage], maxTokens: Int?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            requested.fulfill()
        }
    }

    func complete(fail: Bool = false) {
        let continuation = pending
        pending = nil
        if fail {
            continuation?.resume(throwing: LLMError(message: "test failure"))
        } else {
            continuation?.resume(returning: #"{"reply":"测试回答","give_clue":"c1"}"#)
        }
    }

    nonisolated func stream(_ messages: [ChatMessage], maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class SpeechRecorder: SpeechSink {
    var spoken: [String] = []
    func streamStarted() {}
    func streamDelta(_ text: String) { spoken.append(text) }
    func streamEnded(cancelled: Bool) {}
    func say(_ text: String) { spoken.append(text) }
    func phaseChanged() {}
    func revealStarted(correct: Bool?) {}
    func thinking(_ on: Bool) {}
}

@MainActor
final class AnswerConsistencyTests: XCTestCase {
    private func fixture() -> (Game, DeferredModel, XCTestExpectation, SpeechRecorder) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var script = Script(folder: directory, title: "Test")
        script.characters = [Character(id: "p1", name: "甲")]
        script.clues = [Clue(id: "c1", title: "线索", text: "线索内容")]
        var first = Phase(id: "first", title: "第一阶段", type: .discuss)
        first.grantable = ["c1"]
        script.phases = [first, Phase(id: "next", title: "第二阶段", type: .discuss)]
        var state = GameState(scriptTitle: script.title)
        state.players["p1"] = Player(charId: "p1", name: "玩家", token: "original")
        let requested = expectation(description: "model request started")
        let model = DeferredModel(requested: requested)
        let game = Game(script: script, state: state, llm: model, cheap: nil,
                        settings: GameSettings(), savePath: directory.appendingPathComponent("save.json"))
        let speech = SpeechRecorder()
        game.speech = speech
        return (game, model, requested, speech)
    }

    private func assertNoAnswer(_ game: Game, _ speech: SpeechRecorder, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(game.state.publicLog.contains { $0.kind == .answer }, file: file, line: line)
        XCTAssertFalse((game.state.privateLog["p1"] ?? []).contains { $0.kind == .answer }, file: file, line: line)
        XCTAssertEqual(game.state.players["p1"]?.clues, [], file: file, line: line)
        XCTAssertTrue(speech.spoken.isEmpty, file: file, line: line)
        XCTAssertFalse(game.busy.contains("p1"), file: file, line: line)
    }

    func testPhaseChangeDiscardsPublicReplyAndClue() async {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: true) }
        await fulfillment(of: [requested], timeout: 2)
        game.goto(1, narrate: false)
        await model.complete()
        let result = await task.value
        XCTAssertFalse(result.ok)
        assertNoAnswer(game, speech)
    }

    func testReenterSamePhaseDiscardsReply() async {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: false) }
        await fulfillment(of: [requested], timeout: 2)
        game.state.phaseStartedAt += 1
        await model.complete()
        let result = await task.value
        XCTAssertFalse(result.ok)
        assertNoAnswer(game, speech)
    }

    func testReplacementDeviceCannotReceiveOldAnswer() async throws {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: false) }
        await fulfillment(of: [requested], timeout: 2)
        game.release("p1")
        _ = try game.join(charId: "p1", name: "新设备", token: nil)
        await model.complete()
        let result = await task.value
        XCTAssertFalse(result.ok)
        assertNoAnswer(game, speech)
    }

    func testReleasedRoleDiscardsReply() async {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: false) }
        await fulfillment(of: [requested], timeout: 2)
        game.release("p1")
        await model.complete()
        let result = await task.value
        XCTAssertFalse(result.ok)
        assertNoAnswer(game, speech)
    }

    func testCancelledRequestDoesNotPublishEvenIfModelReturns() async {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: true) }
        await fulfillment(of: [requested], timeout: 2)
        task.cancel()
        await model.complete()
        let result = await task.value
        XCTAssertFalse(result.ok)
        assertNoAnswer(game, speech)
    }

    func testModelErrorAfterPhaseChangeDoesNotPublishFallback() async {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: true) }
        await fulfillment(of: [requested], timeout: 2)
        game.goto(1, narrate: false)
        await model.complete(fail: true)
        let result = await task.value
        XCTAssertFalse(result.ok)
        assertNoAnswer(game, speech)
    }

    func testTableAnswerIsDiscardedAfterPhaseChange() async {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.askTable("问题") }
        await fulfillment(of: [requested], timeout: 2)
        game.goto(1, narrate: false)
        await model.complete()
        let result = await task.value
        XCTAssertFalse(result.ok)
        XCTAssertFalse(game.tableBusy)
        assertNoAnswer(game, speech)
    }

    func testAlreadyPublishedClueIsNotGranted() async {
        let (game, model, requested, _) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: false) }
        await fulfillment(of: [requested], timeout: 2)
        game.state.publicClues.append("c1")
        await model.complete()
        let result = await task.value
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.extra["clue"])
        XCTAssertEqual(game.state.players["p1"]?.clues, [])
    }

    func testAlreadyHeldClueIsNotDuplicated() async {
        let (game, model, requested, _) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: false) }
        await fulfillment(of: [requested], timeout: 2)
        game.state.players["p1"]?.clues.append("c1")
        await model.complete()
        let result = await task.value
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.extra["clue"])
        XCTAssertEqual(game.state.players["p1"]?.clues, ["c1"])
    }

    func testUnchangedContextAcceptsAnswerAndGrant() async {
        let (game, model, requested, speech) = fixture()
        let task = Task { await game.ask(charId: "p1", question: "问题", isPublic: true) }
        await fulfillment(of: [requested], timeout: 2)
        await model.complete()
        let result = await task.value
        XCTAssertTrue(result.ok)
        XCTAssertEqual(game.state.players["p1"]?.clues, ["c1"])
        XCTAssertEqual(speech.spoken, ["测试回答"])
        XCTAssertFalse(game.busy.contains("p1"))
    }
}
