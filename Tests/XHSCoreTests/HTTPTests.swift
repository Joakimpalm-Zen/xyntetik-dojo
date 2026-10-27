import Foundation
import Testing
@testable import XHSCore

@Suite struct HTTPParseTests {
    @Test func parsesARequestWithBody() {
        let raw = Data("POST /send HTTP/1.1\r\nHost: x\r\nX-XHS-Token: abc\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .complete(let r) = HTTPRequest.parse(raw) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST")
        #expect(r.path == "/send")
        #expect(r.headers["x-xhs-token"] == "abc")
        #expect(r.body == Data("{}".utf8))
    }

    @Test func waitsForTheWholeBody() {
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Le".utf8)) == .incomplete)
    }

    @Test func rejectsGarbage() {
        #expect(HTTPRequest.parse(Data("hello\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data(repeating: 65, count: HTTPRequest.maxHeaderBytes + 1)) == .invalid)
    }

    @Test func responseHasLengthAndClose() {
        let text = String(decoding: HTTPRequest.response(status: 401, body: Data("{}".utf8)), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}

@MainActor
@Suite struct BusServerTests {
    @Test func servesTheBusOverLoopbackHTTP() async throws {
        let bus = Bus()
        bus.submitDelay = 0
        let io = MockIO()
        let token = bus.add(name: "claude-1", kind: .claude, io: io)
        let server = try BusServer(port: 0) { path, token, body in bus.handle(path: path, token: token, body: body) }
        let started: Error? = await withCheckedContinuation { continuation in
            server.start { continuation.resume(returning: $0) }
        }
        #expect(started == nil)
        defer { server.stop() }
        let port = try #require(server.port)

        func post(_ op: String, _ args: [String: Any], token: String?) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(op)")!)
            request.httpMethod = "POST"
            request.httpBody = body(args)
            if let token { request.setValue(token, forHTTPHeaderField: "X-XHS-Token") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, json(data))
        }

        let (status, panes) = try await post("panes", [:], token: token)
        #expect(status == 200)
        #expect(panes["you"] as? String == "claude-1")
        #expect(try await post("panes", [:], token: nil).0 == 401)

        let hookStatus = try await post("hook", ["hook_event_name": "SessionStart"], token: token).0
        #expect(hookStatus == 200)
        #expect(bus.info("claude-1")?.state == .idle)

        let (sendStatus, sent) = try await post("send", ["pane": "claude-1", "text": "note to self"], token: token)
        #expect(sendStatus == 200)
        #expect(sent["delivered"] as? Bool == true)
        #expect(io.typed == "[from: claude-1] note to self\r")
    }
}
