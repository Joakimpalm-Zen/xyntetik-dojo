import Foundation
import Network

/// A parsed HTTP/1.1 request. Only what the bus needs.
public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    /// Header names in lowercase.
    public let headers: [String: String]
    public let body: Data

    public enum Parse: Equatable, Sendable {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length: Int
        if let value = headers["content-length"] {
            guard let n = Int(value), n >= 0, n <= maxBodyBytes else { return .invalid }
            length = n
        } else {
            length = 0
        }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        return .complete(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body)))
    }

    public static func response(status: Int, body: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// The bus's HTTP server on the loopback interface. One request per connection.
@MainActor
public final class BusServer {
    public typealias Handler = @MainActor (_ path: String, _ token: String?, _ body: Data) -> (status: Int, body: Data)

    private let listener: NWListener
    private let handler: Handler

    /// - Parameter port: 0 picks a free port (tests); read `port` after `start`.
    public init(port: UInt16, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: params, on: nwPort)
        self.handler = handler
    }

    public var port: UInt16? { listener.port?.rawValue }

    /// Starts listening; `ready` gets nil once the port is bound, or the error.
    public func start(ready: @escaping @MainActor (Error?) -> Void) {
        var reported = false
        listener.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    if !reported { reported = true; ready(nil) }
                case .failed(let error):
                    if !reported { reported = true; ready(error) }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        // Loopback only, also when the interface restriction is not honoured.
        if case .hostPort(let host, _) = connection.endpoint {
            let h = "\(host)"
            guard h == "127.0.0.1" || h == "::1" || h.hasPrefix("127.") || h == "::ffff:127.0.0.1" else {
                connection.cancel()
                return
            }
        }
        connection.start(queue: .main)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch HTTPRequest.parse(buffer) {
                case .complete(let request):
                    let result = self.handler(request.path, request.headers["x-dojo-token"], request.body)
                    self.reply(connection, result.status, result.body)
                case .invalid:
                    self.reply(connection, 400, Data(#"{"error":"bad request"}"#.utf8))
                case .incomplete:
                    if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        self.receive(connection, buffer)
                    }
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ body: Data) {
        connection.send(content: HTTPRequest.response(status: status, body: body), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
