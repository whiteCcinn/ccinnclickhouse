import ClickHouseKit
import Foundation
import Network
import os

/// A scriptable HTTP/1.1 server on 127.0.0.1 that stands in for ClickHouse in unit tests: parses
/// requests (query parameters, headers, body), records them, and streams scripted responses with
/// chunked encoding, delays, and deliberately broken chunking.
final class FakeClickHouseServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let parameters: [String: String]
        let parameterOrder: [String]
        let headers: [String: String]
        let body: Data
        var sql: String { String(decoding: body, as: UTF8.self) }
        var queryID: String? { parameters["query_id"] }
    }

    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Delay before each chunk.
        var chunkDelay: Duration = .zero
        /// Delay before the head is sent.
        var headDelay: Duration = .zero
        /// Close the connection without the terminating chunk (as ClickHouse 25.x does after an exception).
        var breakChunking = false
        /// Close the connection without answering (a keep-alive connection the server just closed).
        var dropConnection = false

        static func tsv(_ text: String, headers: [String: String] = [:]) -> Response {
            var all = ["X-ClickHouse-Format": "TabSeparatedWithNamesAndTypes", "X-ClickHouse-Server-Display-Name": "fake-node"]
            all.merge(headers) { $1 }
            return Response(status: 200, headers: all, chunks: [Data(text.utf8)])
        }

        static func empty() -> Response {
            Response(status: 200, headers: ["X-ClickHouse-Format": "TabSeparatedWithNamesAndTypes"], chunks: [])
        }

        static func exception(code: Int, name: String, message: String, status: Int = 500) -> Response {
            Response(status: status, headers: ["X-ClickHouse-Exception-Code": String(code)],
                     chunks: [Data("Code: \(code). DB::Exception: \(message). (\(name)) (version 24.8.14.39 (official build))\n".utf8)])
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-clickhouse")
    private let handler: OSAllocatedUnfairLock<Handler>
    private let recorded = OSAllocatedUnfairLock<[Request]>(initialState: [])
    private let connectionCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    private(set) var port: Int = 0

    init(handler: @escaping Handler) async throws {
        self.handler = OSAllocatedUnfairLock(uncheckedState: handler)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = OSAllocatedUnfairLock<CheckedContinuation<Int, any Error>?>(initialState: nil)
        let boundPort: Int = try await withCheckedThrowingContinuation { continuation in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    let port = Int(listener.port?.rawValue ?? 0)
                    ready.withLock { pending in pending?.resume(returning: port); pending = nil }
                case let .failed(error):
                    ready.withLock { pending in pending?.resume(throwing: error); pending = nil }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        port = boundPort
    }

    func setHandler(_ newHandler: @escaping Handler) { handler.withLockUnchecked { $0 = newHandler } }

    var requests: [Request] { recorded.withLock { $0 } }
    var connections: Int { connectionCount.withLock { $0 } }

    func requests(containing text: String) -> [Request] { requests.filter { $0.sql.contains(text) } }

    func stop() {
        listener.cancel()
    }

    var url: String { "http://127.0.0.1:\(port)" }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connectionCount.withLock { $0 += 1 }
        connection.start(queue: queue)
        Task { await self.serve(connection) }
    }

    private func serve(_ connection: NWConnection) async {
        var buffer = Data()
        while true {
            guard let request = await readRequest(connection, buffer: &buffer) else {
                connection.cancel()
                return
            }
            recorded.withLock { $0.append(request) }
            let current = handler.withLockUnchecked { $0 }
            let response = await current(request)
            let keepAlive = await write(response, to: connection) && request.headers["connection"]?.lowercased() != "close"
            if !keepAlive {
                connection.cancel()
                return
            }
        }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func readRequest(_ connection: NWConnection, buffer: inout Data) async -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard let more = await receive(connection) else { return nil }
            buffer.append(more)
        }
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        while buffer.count - (bodyStart - buffer.startIndex) < length {
            guard let more = await receive(connection) else { return nil }
            buffer.append(more)
        }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        let target = String(requestLine[1])
        var parameters: [String: String] = [:]
        var order: [String] = []
        let path: String
        if let question = target.firstIndex(of: "?") {
            path = String(target[..<question])
            for pair in target[target.index(after: question)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts[0].removingPercentEncoding ?? parts[0]
                parameters[key] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
                order.append(key)
            }
        } else {
            path = target
        }
        var decodedBody = body
        if headers["content-encoding"] == "gzip" { decodedBody = Self.gunzip(body) ?? body }
        return Request(method: String(requestLine[0]), path: path, parameters: parameters, parameterOrder: order, headers: headers, body: decodedBody)
    }

    /// Writes the response; returns false when the connection must be closed.
    private func write(_ response: Response, to connection: NWConnection) async -> Bool {
        if response.dropConnection { return false }
        if response.headDelay > .zero { try? await Task.sleep(for: response.headDelay) }
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        var headers = response.headers
        headers["Transfer-Encoding"] = "chunked"
        headers["Connection"] = "Keep-Alive"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        guard await send(Data(head.utf8), on: connection) else { return false }
        for chunk in response.chunks {
            if response.chunkDelay > .zero { try? await Task.sleep(for: response.chunkDelay) }
            guard !chunk.isEmpty else { continue }
            var framed = Data(String(chunk.count, radix: 16).utf8)
            framed.append(Data("\r\n".utf8))
            framed.append(chunk)
            framed.append(Data("\r\n".utf8))
            guard await send(framed, on: connection) else { return false }
        }
        if response.breakChunking {
            try? await Task.sleep(for: .milliseconds(20))
            return false
        }
        return await send(Data("0\r\n\r\n".utf8), on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    /// Minimal gzip decoder for recorded request bodies.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { return nil }
        let deflate = Array(bytes[10..<(bytes.count - 8)])
        let size = Int(UInt32(bytes[bytes.count - 4]) | UInt32(bytes[bytes.count - 3]) << 8 | UInt32(bytes[bytes.count - 2]) << 16 | UInt32(bytes[bytes.count - 1]) << 24)
        var output = [UInt8](repeating: 0, count: size + 16)
        let decoded = deflate.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Data(output.prefix(decoded))
    }
}

import Compression

/// Standard answers for the connect probe and system-schema load.
enum FakeAnswers {
    static let probe = "version\ttimezone\tuser\thost\tuptime\tdatabase\treadonly\nString\tString\tString\tString\tUInt32\tString\tString\n24.8.14.39\tUTC\tccinn\tnode-1\t1234\tdefault\t0\n"
    static let schema = "table\tname\nString\tString\nprocesses\tquery_id\nprocesses\tread_rows\nprocesses\telapsed\ntables\tname\n"

    /// system.settings rows for `ParserSettings.query`: readonly, and the parser settings as the request sent them (else
    /// their safe defaults, or `profile` overrides).
    static func settings(_ request: FakeClickHouseServer.Request, readonly: String, profile: [String: String] = [:]) -> String {
        var rows = "name\tvalue\nString\tString\nreadonly\t\(readonly)\n"
        for expectation in ParserSettings.verified {
            let value = request.parameters[expectation.name] ?? profile[expectation.name] ?? expectation.value
            rows += "\(expectation.name)\t\(value)\n"
        }
        return rows
    }

    /// Answers probe and schema requests; returns nil for anything else.
    static func standard(_ request: FakeClickHouseServer.Request) -> FakeClickHouseServer.Response? {
        if request.sql.contains("version() AS version") { return .tsv(probe) }
        if request.sql.contains("FROM system.columns WHERE database = 'system'") { return .tsv(schema) }
        if request.sql.hasPrefix("KILL QUERY") { return .tsv("kill_status\tquery_id\nString\tString\n") }
        // The read-only path check (ParserSettings): the readonly level the request asked for, the parser settings as sent.
        if request.sql == ParserSettings.query { return .tsv(settings(request, readonly: request.parameters["readonly"] ?? "0")) }
        return nil
    }
}
