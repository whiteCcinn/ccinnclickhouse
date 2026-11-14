import Foundation

/// One HTTP request carrying a ClickHouse statement.
public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data
    /// Idle timeout: seconds without any received bytes before the request fails.
    public var timeout: Double
    /// Use a brand-new TCP connection (kill retries behind load balancers).
    public var freshConnection: Bool

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data = Data(), timeout: Double = 60,
                freshConnection: Bool = false) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.freshConnection = freshConnection
    }
}

/// Status line and headers of a response. Header names are lower-cased.
public struct HTTPResponseHead: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]

    public init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, second in first + ", " + second })
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// A response whose body arrives incrementally. Consumers call ``acknowledge(_:)`` after processing
/// each chunk (back-pressure, design D2) and ``cancel()`` when they stop early.
public final class HTTPStreamingResponse: Sendable {
    public let head: HTTPResponseHead
    public let body: AsyncThrowingStream<Data, any Error>
    private let onAcknowledge: @Sendable (Int) -> Void
    private let onCancel: @Sendable () -> Void

    public init(head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>, onAcknowledge: @escaping @Sendable (Int) -> Void = { _ in },
                onCancel: @escaping @Sendable () -> Void = {}) {
        self.head = head
        self.body = body
        self.onAcknowledge = onAcknowledge
        self.onCancel = onCancel
    }

    public func acknowledge(_ byteCount: Int) { onAcknowledge(byteCount) }
    public func cancel() { onCancel() }

    /// Reads at most `limit` bytes of the body (error bodies, raw text).
    public func collect(limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            acknowledge(chunk.count)
            data.append(chunk.prefix(max(0, limit - data.count)))
            if data.count >= limit {
                cancel()
                break
            }
        }
        return data
    }
}

/// How the client reaches ClickHouse (design D2). URLSession today; a native TCP transport can
/// implement the same protocol later.
public protocol ClickHouseTransport: Sendable {
    /// Sends the request and returns once the response head arrived. Cancelling the calling task
    /// cancels the request.
    func send(_ request: HTTPRequest) async throws -> HTTPStreamingResponse
    /// Stops all requests and releases resources.
    func close()
}

/// Creates a transport for a configuration (tests inject fakes).
public typealias TransportFactory = @Sendable (ConnectionConfiguration) -> any ClickHouseTransport

public enum Transports {
    public static let urlSession: TransportFactory = { configuration in
        URLSessionTransport(tls: configuration.tls, serverName: configuration.tlsServerName)
    }
}
