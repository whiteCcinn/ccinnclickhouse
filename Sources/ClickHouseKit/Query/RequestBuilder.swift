import ClickHouseWire
import Foundation

/// Session parameters of a request (design D6).
public struct SessionParameters: Sendable, Equatable {
    public var id: String
    /// Fail with SESSION_NOT_FOUND instead of silently creating a fresh session.
    public var check: Bool
    /// Requested timeout in seconds; `nil` uses the server default.
    public var timeout: Int?

    public init(id: String, check: Bool, timeout: Int?) {
        self.id = id
        self.check = check
        self.timeout = timeout
    }
}

/// Per-statement options.
public struct QueryOptions: Sendable {
    /// Prefix of the generated query id (`ccinnch-<purpose>-<uuid>`).
    public var purpose: String
    public var queryID: String?
    public var database: String?
    public var session: SessionParameters?
    /// Extra settings (e.g. replayed session settings when the proxy has no sessions).
    public var settings: [(String, String)]
    public var limits: RowLimits
    /// Overall time limit: enforced by the client and sent as `max_execution_time`.
    public var timeout: Double?
    /// Buffer the whole response on the server so errors arrive as HTTP errors (metadata queries).
    public var waitEndOfQuery: Bool
    /// `nil` follows the configuration.
    public var readOnly: Bool?
    /// Safe to send twice (reads): retried once when a stale keep-alive connection drops before any response.
    public var idempotent: Bool
    /// Called with the response head information before rows are read.
    public var onResponse: (@Sendable (ResponseInfo) -> Void)?

    public init(purpose: String = "sql", queryID: String? = nil, database: String? = nil, session: SessionParameters? = nil,
                settings: [(String, String)] = [], limits: RowLimits = RowLimits(), timeout: Double? = nil, waitEndOfQuery: Bool = false,
                readOnly: Bool? = nil, idempotent: Bool = false, onResponse: (@Sendable (ResponseInfo) -> Void)? = nil) {
        self.purpose = purpose
        self.queryID = queryID
        self.database = database
        self.session = session
        self.settings = settings
        self.limits = limits
        self.timeout = timeout
        self.waitEndOfQuery = waitEndOfQuery
        self.readOnly = readOnly
        self.idempotent = idempotent
        self.onResponse = onResponse
    }

    public static func metadata(timeout: Double?) -> QueryOptions {
        QueryOptions(purpose: "meta", limits: .metadata, timeout: timeout, waitEndOfQuery: true, idempotent: true)
    }
}

/// What the response head says about the running statement.
public struct ResponseInfo: Sendable, Equatable {
    public let queryID: String
    public let serverDisplayName: String?
    public let format: String?
    public let progress: QueryProgress?
}

/// What a connection may send (learned while connecting, design D7).
public struct ConnectionCapabilities: Sendable, Equatable {
    /// The user's server profile forbids changing settings: send none.
    public var settingsLocked: Bool
    /// Settings this server does not know (dropped after `UNKNOWN_SETTING`).
    public var unsupportedSettings: Set<String>

    public init(settingsLocked: Bool = false, unsupportedSettings: Set<String> = []) {
        self.settingsLocked = settingsLocked
        self.unsupportedSettings = unsupportedSettings
    }
}

/// Builds HTTP requests for statements (pure; unit-tested).
public struct RequestBuilder: Sendable {
    public static let resultFormat = "TabSeparatedWithNamesAndTypes"
    public static let compressBodyThreshold = 64 * 1024
    public static let progressIntervalMilliseconds = 10_000
    /// Idle timeout for statements without their own limit.
    public static let defaultIdleTimeout: Double = 3600

    public let configuration: ConnectionConfiguration
    public let baseURL: URL
    public let capabilities: ConnectionCapabilities

    public init(configuration: ConnectionConfiguration, baseURL: URL, capabilities: ConnectionCapabilities) {
        self.configuration = configuration
        self.baseURL = baseURL
        self.capabilities = capabilities
    }

    /// `log_comment` value that identifies a query even when a proxy rewrote its id.
    public static func marker(application: String, queryID: String) -> String { "\(application)/\(queryID)" }

    public static func makeQueryID(purpose: String) -> String {
        "ccinnch-\(purpose)-\(UUID().uuidString.lowercased())"
    }

    /// URL parameters in a stable order.
    public func parameters(queryID: String, options: QueryOptions) -> [(String, String)] {
        var parameters: [(String, String)] = [("query_id", queryID), ("default_format", Self.resultFormat)]
        if let database = options.database, !database.isEmpty { parameters.append(("database", database)) }
        if let session = options.session {
            parameters.append(("session_id", session.id))
            if session.check { parameters.append(("session_check", "1")) }
            if let timeout = session.timeout { parameters.append(("session_timeout", String(timeout))) }
        }
        if options.waitEndOfQuery { parameters.append(("wait_end_of_query", "1")) }
        if options.readOnly ?? configuration.readOnly { parameters.append(("readonly", "1")) }
        guard !capabilities.settingsLocked else { return parameters }
        var settings: [(String, String)] = []
        if let timeout = options.timeout, timeout.isFinite, timeout > 0 {
            settings.append(("max_execution_time", String(Int(min(max(1, timeout.rounded(.up)), 86_400 * 7)))))
        }
        settings.append(("send_progress_in_http_headers", "1"))
        settings.append(("http_headers_progress_interval_ms", String(Self.progressIntervalMilliseconds)))
        settings.append(("cancel_http_readonly_queries_on_client_close", "1"))
        if configuration.compression { settings.append(("enable_http_compression", "1")) }
        settings.append(("format_tsv_null_representation", "\\N"))
        // Tags the query with its id: proxies such as chproxy replace `query_id`, and the kill and
        // progress lookups fall back to this marker (design D5).
        settings.append(("log_comment", Self.marker(application: configuration.applicationName, queryID: queryID)))
        let explicit = Set(options.settings.map(\.0))
        for setting in settings where !capabilities.unsupportedSettings.contains(setting.0) && !explicit.contains(setting.0) {
            parameters.append(setting)
        }
        parameters += options.settings.filter { !capabilities.unsupportedSettings.contains($0.0) }
        return parameters
    }

    public func request(sql: String, queryID: String, options: QueryOptions, freshConnection: Bool = false) throws -> HTTPRequest {
        guard let url = QueryURL.build(base: baseURL, parameters: parameters(queryID: queryID, options: options)) else {
            throw ClickHouseError(.invalidArgument, "Invalid server address")
        }
        var headers: [String: String] = [
            "Authorization": "Basic " + Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString(),
            "User-Agent": "\(configuration.applicationName)/1.0",
            "Content-Type": "text/plain; charset=UTF-8",
        ]
        var body = Data(sql.utf8)
        if configuration.compression, body.count > Self.compressBodyThreshold, let compressed = Gzip.compress(body) {
            body = compressed
            headers["Content-Encoding"] = "gzip"
        }
        let idle = options.timeout.map { $0 + max(10, configuration.connectTimeout) } ?? Self.defaultIdleTimeout
        return HTTPRequest(url: url, headers: headers, body: body, timeout: idle, freshConnection: freshConnection)
    }
}
