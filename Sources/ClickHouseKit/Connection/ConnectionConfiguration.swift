import Foundation

/// Host and port (used for SSH tunnels and display).
public struct Endpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var isIPv6: Bool { host.contains(":") }
    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// TLS options for HTTPS connections.
public struct TLSOptions: Sendable, Hashable, Codable {
    /// PEM (or base64 DER) of an extra trusted CA certificate (e.g. a private CA).
    public var customCACertificate: String?
    /// Accept any certificate. Only for test environments; the UI warns about it.
    public var skipVerification: Bool

    public init(customCACertificate: String? = nil, skipVerification: Bool = false) {
        self.customCACertificate = customCACertificate
        self.skipVerification = skipVerification
    }
}

/// Everything needed to talk to one ClickHouse HTTP(S) endpoint.
public struct ConnectionConfiguration: Sendable, Equatable {
    public var endpoint: Endpoint
    public var secure: Bool
    /// Path prefix for servers behind a reverse proxy (`/clickhouse/`); empty for direct connections.
    public var pathPrefix: String
    public var username: String
    public var password: String
    /// Default database for editors (sent as the `database` parameter).
    public var database: String?
    /// Cluster used for cluster-wide views (`clusterAllReplicas`) and `ON CLUSTER` kills.
    public var defaultCluster: String?
    /// Seconds to wait when establishing a connection and for metadata queries.
    public var connectTimeout: Double
    /// Server-enforced read-only (`readonly=1` on every request).
    public var readOnly: Bool
    /// Ask for compressed responses and compress large request bodies.
    public var compression: Bool
    public var tls: TLSOptions
    /// Host name certificates are verified against (set when tunnelling HTTPS through SSH).
    public var tlsServerName: String?
    /// Requested `session_timeout` for editor sessions, in seconds.
    public var sessionTimeout: Int
    public var applicationName: String

    public init(endpoint: Endpoint, secure: Bool = false, pathPrefix: String = "", username: String = "default", password: String = "",
                database: String? = nil, defaultCluster: String? = nil, connectTimeout: Double = 10, readOnly: Bool = false,
                compression: Bool = true, tls: TLSOptions = TLSOptions(), tlsServerName: String? = nil, sessionTimeout: Int = 1800,
                applicationName: String = "CcinnClickHouse") {
        self.endpoint = endpoint
        self.secure = secure
        self.pathPrefix = pathPrefix
        self.username = username
        self.password = password
        self.database = database
        self.defaultCluster = defaultCluster
        self.connectTimeout = Self.sanitizedConnectTimeout(connectTimeout)
        self.readOnly = readOnly
        self.compression = compression
        self.tls = tls
        self.tlsServerName = tlsServerName
        self.sessionTimeout = sessionTimeout
        self.applicationName = applicationName
    }

    /// A usable connect timeout: finite, 1…300 s (non-finite values such as `nan` fall back to 10 s).
    public static func sanitizedConnectTimeout(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 1), 300) : 10
    }

    /// `http(s)://host:port/prefix/`.
    public var baseURL: URL? {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = endpoint.host.trimmingCharacters(in: .whitespaces)
        components.port = endpoint.port
        let trimmed = pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        components.path = trimmed.isEmpty ? "/" : "/" + trimmed + "/"
        guard (1...65_535).contains(endpoint.port), !(components.host ?? "").isEmpty else { return nil }
        return components.url
    }

    /// Same configuration pointed at a local tunnel port; certificates are still checked against the original host.
    public func with(endpoint newEndpoint: Endpoint) -> ConnectionConfiguration {
        var copy = self
        copy.tlsServerName = tlsServerName ?? endpoint.host
        copy.endpoint = newEndpoint
        return copy
    }

    public static func == (lhs: ConnectionConfiguration, rhs: ConnectionConfiguration) -> Bool {
        lhs.endpoint == rhs.endpoint && lhs.secure == rhs.secure && lhs.pathPrefix == rhs.pathPrefix && lhs.username == rhs.username
            && lhs.password == rhs.password && lhs.database == rhs.database && lhs.defaultCluster == rhs.defaultCluster
            && lhs.connectTimeout == rhs.connectTimeout && lhs.readOnly == rhs.readOnly && lhs.compression == rhs.compression
            && lhs.tls == rhs.tls && lhs.tlsServerName == rhs.tlsServerName && lhs.sessionTimeout == rhs.sessionTimeout
            && lhs.applicationName == rhs.applicationName
    }
}
