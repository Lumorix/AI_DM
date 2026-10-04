// 手机网页的接口。主持人和大屏是 Mac 原生界面，不走网页。
import Foundation
import Network

@MainActor
final class WebRouter {
    private weak var game: Game?
    private let webRoot: URL
    private var channels: [UUID: SSEChannel] = [:]
    private var pingTimer: Timer?

    init(game: Game, webRoot: URL) {
        self.game = game
        self.webRoot = webRoot
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.channels.values.forEach { $0.ping() } }
        }
    }

    func shutdown() {
        pingTimer?.invalidate()
        channels.values.forEach { $0.close() }
        channels.removeAll()
    }

    var connectionCount: Int { channels.count }

    func handle(_ req: HTTPRequest, _ conn: NWConnection) async -> HTTPResponse {
        guard let game else { return .error("游戏已结束", status: 404) }
        let path = req.path
        switch (req.method, path) {
        case ("GET", "/"), ("HEAD", "/"):
            return .redirect("/player")
        case ("GET", "/player"), ("HEAD", "/player"):
            return file(webRoot.appendingPathComponent("player.html"))
        case (_, _) where path.hasPrefix("/static/"):
            let name = String(path.dropFirst("/static/".count))
            let f = webRoot.appendingPathComponent(name).standardizedFileURL
            guard f.path.hasPrefix(webRoot.standardizedFileURL.path + "/") else { return .notFound }
            return file(f)
        case ("GET", "/api/events"):
            return events(req, conn, game)
        case ("GET", "/api/lobby"):
            return .json(game.lobbyView())
        case ("POST", "/api/join"):
            let d = req.json
            do {
                let p = try game.join(charId: str(d["char_id"]), name: str(d["name"]), token: d["token"] as? String)
                return .json(["ok": true, "token": p.token, "char_id": p.charId])
            } catch {
                return .error(error.localizedDescription)
            }
        case ("POST", "/api/me"):
            guard let p = game.state.player(byToken: req.json["token"] as? String) else { return .json(["ok": false, "code": 401]) }
            return .json(["ok": true, "char_id": p.charId])
        case ("POST", "/api/search"), ("POST", "/api/ask"), ("POST", "/api/publish"), ("POST", "/api/vote"):
            let d = req.json
            guard let p = game.state.player(byToken: d["token"] as? String) else { return .error("请先选择角色", status: 401) }
            let r: ActionResult
            switch path {
            case "/api/search": r = game.search(charId: p.charId, locationId: str(d["location"]))
            case "/api/ask": r = await game.ask(charId: p.charId, question: str(d["text"]), isPublic: d["public"] as? Bool ?? false)
            case "/api/publish": r = game.publishClue(charId: p.charId, clueId: str(d["clue"]))
            default: r = game.vote(charId: p.charId, option: str(d["option"]))
            }
            return .json(r.json)
        case ("GET", _) where path.hasPrefix("/api/clue-image/"):
            return clueImage(String(path.dropFirst("/api/clue-image/".count)), token: req.query["token"], game)
        default:
            return .notFound
        }
    }

    private func str(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    private func file(_ url: URL) -> HTTPResponse {
        guard let data = try? Data(contentsOf: url) else { return .notFound }
        return .data(status: 200, type: mime(url.pathExtension), body: data)
    }

    private func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js": "application/javascript; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "json": "application/json"
        default: "image/jpeg"
        }
    }

    private func clueImage(_ cid: String, token: String?, _ game: Game) -> HTTPResponse {
        guard let clue = game.script.clue(cid), let img = clue.image else { return .notFound }
        let p = game.state.player(byToken: token)
        guard game.state.publicClues.contains(cid) || (p?.clues.contains(cid) ?? false) else {
            return .data(status: 403, type: "text/plain", body: Data())
        }
        let folder = game.script.folder.standardizedFileURL
        let f = folder.appendingPathComponent(img).standardizedFileURL
        guard f.path.hasPrefix(folder.path + "/") else { return .notFound }
        return file(f)
    }

    // MARK: SSE

    private func events(_ req: HTTPRequest, _ conn: NWConnection, _ game: Game) -> HTTPResponse {
        guard let p = game.state.player(byToken: req.query["token"]) else { return .error("请先选择角色", status: 401) }
        let charId = p.charId
        let sessionToken = p.token
        let ch = SSEChannel(conn)
        let chId = UUID()
        channels[chId] = ch
        ch.open()
        ch.send(["type": "view", "data": game.viewPlayer(charId), "lan_url": ""])

        // 合并连续的刷新，避免刷屏
        final class Pending { var refresh = false }
        let pending = Pending()
        let subId = game.bus.subscribe(audience: "player:\(charId)") { [weak game, weak ch] ev in
            guard let game, let ch else { return }
            guard game.state.player(byToken: sessionToken)?.charId == charId else {
                ch.send(["type": "kicked"])
                ch.close()
                return
            }
            switch ev {
            case .event(let e):
                ch.send(e)
            case .refresh:
                guard !pending.refresh else { return }
                pending.refresh = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        pending.refresh = false
                        guard game.state.player(byToken: sessionToken)?.charId == charId else {
                            ch.send(["type": "kicked"])
                            ch.close()
                            return
                        }
                        ch.send(["type": "view", "data": game.viewPlayer(charId), "lan_url": ""])
                    }
                }
            }
        }
        ch.onClose = { [weak self, weak game] in
            game?.bus.unsubscribe(subId)
            game?.connectionChanged(charId, -1)
            self?.channels[chId] = nil
        }
        game.connectionChanged(charId, +1)      // 主持台显示谁的手机在线
        return .sse(ch)
    }
}
