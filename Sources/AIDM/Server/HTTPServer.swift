// 极简 HTTP/1.1 服务（Network.framework）：普通请求一问一答后关闭连接；/api/events 保持连接做 SSE 推送。
import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// 从缓冲区里解析出一个完整请求；数据还不够就返回 nil
    static func parse(_ buf: Data) -> HTTPRequest? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= length else { return nil }
        let body = buf[bodyStart..<(bodyStart + length)]
        let comps = URLComponents(string: String(first[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(first[0]), path: comps?.percentEncodedPath.removingPercentEncoding ?? "/",
                           query: query, headers: headers, body: Data(body))
    }

    static func headerComplete(_ buf: Data) -> Bool { buf.range(of: Data("\r\n\r\n".utf8)) != nil }
}

enum HTTPResponse {
    case data(status: Int, type: String, body: Data, headers: [String: String] = [:])
    case sse(SSEChannel)

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return .data(status: status, type: "application/json; charset=utf-8", body: data)
    }

    static func error(_ msg: String, status: Int = 400) -> HTTPResponse { json(["ok": false, "msg": msg], status: status) }
    static let notFound = HTTPResponse.data(status: 404, type: "text/plain; charset=utf-8", body: Data("Not Found".utf8))
    static func redirect(_ to: String) -> HTTPResponse { .data(status: 302, type: "text/plain", body: Data(), headers: ["Location": to]) }
}

/// SSE 长连接
final class SSEChannel: @unchecked Sendable {
    private let conn: NWConnection
    private let lock = NSLock()
    private var closed = false
    var onClose: (@MainActor () -> Void)?

    init(_ conn: NWConnection) { self.conn = conn }

    func open() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\nX-Accel-Buffering: no\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        write(head)
        watchForClose()
    }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        write("data: " + String(decoding: d, as: UTF8.self) + "\n\n")
    }

    func ping() { write(": ping\n\n") }

    private func write(_ s: String) {
        lock.lock(); let c = closed; lock.unlock()
        guard !c else { return }
        conn.send(content: Data(s.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.close() }
        })
    }

    /// 手机关掉页面时 TCP 会收到 EOF
    private func watchForClose() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, err in
            if done || err != nil { self?.close() } else { self?.watchForClose() }
        }
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        conn.cancel()
        let cb = onClose
        Task { @MainActor in cb?() }
    }
}

final class HTTPServer: @unchecked Sendable {
    typealias Handler = @MainActor (HTTPRequest, NWConnection) async -> HTTPResponse

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "aidm.http")
    private let handler: Handler
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) { self.handler = handler }

    /// 从 preferred 开始找一个空闲端口
    func start(preferred: UInt16) async throws -> UInt16 {
        var lastError: Error?
        for p in preferred..<(preferred &+ 20) {
            do {
                try await listen(on: p)
                port = p
                return p
            } catch { lastError = error }
        }
        throw lastError ?? LLMError(message: "没有可用的端口")
    }

    private func listen(on p: UInt16) async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: p)!)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: e) }; l.cancel()
                case .cancelled: once.run { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                Task { @MainActor in
                    let resp = await self.handler(req, c)
                    self.respond(c, resp, head: req.method == "HEAD")
                }
            } else if err != nil || done || buf.count > 2_000_000 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ resp: HTTPResponse, head: Bool) {
        guard case let .data(status, type, body, extra) = resp else { return }   // SSE 由 SSEChannel 自己写
        var h = "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\nConnection: close\r\n"
        for (k, v) in extra { h += "\(k): \(v)\r\n" }
        var out = Data((h + "\r\n").utf8)
        if !head { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func reason(_ s: Int) -> String {
        [200: "OK", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
         500: "Internal Server Error"][s] ?? "OK"
    }
}

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; f() }
    }
}
