import ClickHouseWire
import Foundation

/// Every failure surfaced by ClickHouseKit. Messages are user-facing and never contain secrets.
public struct ClickHouseError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case invalidArgument
        case network
        case timeout
        case tls
        case sshTunnel
        case authentication
        /// ClickHouse rejected or failed the statement (a `Code: N` exception) or a proxy refused it.
        case server
        case protocolViolation
        case cancelled
        /// The editor's session is already running a statement.
        case busy
        /// A read-only connection whose endpoint does not apply `readonly=1` (e.g. a proxy drops it).
        case readOnlyNotEnforced
    }

    public let kind: Kind
    public let message: String
    /// ClickHouse error code (`Code: 60`).
    public let code: Int?
    /// Symbolic ClickHouse error name (`UNKNOWN_TABLE`).
    public let name: String?
    public let httpStatus: Int?
    /// The connection dropped before any response arrived (typically a keep-alive connection the
    /// server closed just as the request was sent): idempotent requests may be retried once.
    public let isConnectionLostBeforeResponse: Bool

    public init(_ kind: Kind, _ message: String, code: Int? = nil, name: String? = nil, httpStatus: Int? = nil,
                isConnectionLostBeforeResponse: Bool = false) {
        self.kind = kind
        self.message = message
        self.code = code
        self.name = name
        self.httpStatus = httpStatus
        self.isConnectionLostBeforeResponse = isConnectionLostBeforeResponse
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    public static func cancelled() -> ClickHouseError { ClickHouseError(.cancelled, "The operation was cancelled") }

    static func server(_ exception: ClickHouseServerException, httpStatus: Int? = nil) -> ClickHouseError {
        let kind: Kind = authenticationCodes.contains(exception.code) ? .authentication : .server
        let message = exception.message.isEmpty ? "Server error \(exception.code)" : exception.message
        return ClickHouseError(kind, message, code: exception.code == 0 ? nil : exception.code, name: exception.name, httpStatus: httpStatus)
    }

    /// AUTHENTICATION_FAILED, UNKNOWN_USER, WRONG_PASSWORD, REQUIRED_PASSWORD, IP_ADDRESS_NOT_ALLOWED.
    static let authenticationCodes: Set<Int> = [192, 193, 194, 195, 516]

    public enum Code {
        public static let unknownSetting = 115
        public static let timeoutExceeded = 159
        public static let readonly = 164
        public static let memoryLimitExceeded = 241
        public static let sessionNotFound = 372
        public static let sessionIsLocked = 373
        public static let invalidSessionTimeout = 374
        public static let queryWasCancelled = 394
        public static let queryWithSameIDIsAlreadyRunning = 216
        public static let accessDenied = 497
    }

    /// The statement names something this server or user does not have (an unknown table, column,
    /// function, database or setting on an older version, a missing privilege, no Keeper). Optional
    /// metadata treats these as "not available"; anything else (timeouts, memory, cancellation,
    /// network, Keeper failures) is a real failure and must surface.
    public var isFeatureUnavailable: Bool {
        guard kind == .server, let code else { return false }
        return Self.featureUnavailableCodes.contains(code)
    }

    /// THERE_IS_NO_COLUMN, NOT_FOUND_COLUMN_IN_BLOCK, NO_SUCH_COLUMN_IN_TABLE, BAD_ARGUMENTS,
    /// ILLEGAL_TYPE_OF_ARGUMENT, UNKNOWN_FUNCTION, UNKNOWN_IDENTIFIER, NOT_IMPLEMENTED, UNKNOWN_TABLE,
    /// SYNTAX_ERROR, UNKNOWN_DATABASE, UNKNOWN_SETTING, NO_ZOOKEEPER, DATABASE_ACCESS_DENIED,
    /// SUPPORT_IS_DISABLED, ACCESS_DENIED.
    static let featureUnavailableCodes: Set<Int> = [8, 10, 16, 36, 43, 46, 47, 48, 60, 62, 81, 115, 225, 291, 344, 497]

    /// The statement was stopped by `KILL QUERY` or a client disconnect.
    public var isQueryCancelled: Bool { kind == .server && code == Code.queryWasCancelled }

    func hasCode(_ value: Int) -> Bool { code == value }
}

extension ClickHouseError {
    /// Maps transport-level failures (URLError and friends) to user-facing errors.
    static func transport(_ error: any Error) -> ClickHouseError {
        if let error = error as? ClickHouseError { return error }
        if error is CancellationError { return .cancelled() }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled()
            case .timedOut: return ClickHouseError(.timeout, "The server did not respond in time")
            case .cannotFindHost, .dnsLookupFailed: return ClickHouseError(.network, "Cannot resolve the host name: \(urlError.localizedDescription)")
            case .cannotConnectToHost: return ClickHouseError(.network, "Cannot connect to the server: \(urlError.localizedDescription)")
            case .networkConnectionLost: return ClickHouseError(.network, "The connection to the server was lost")
            case .notConnectedToInternet: return ClickHouseError(.network, "The network is offline")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
                return ClickHouseError(.tls, "TLS handshake failed: \(urlError.localizedDescription)")
            case .badServerResponse:
                return ClickHouseError(.protocolViolation, "The server sent an invalid HTTP response (is this an HTTP port?)")
            default:
                return ClickHouseError(.network, urlError.localizedDescription)
            }
        }
        return ClickHouseError(.network, error.localizedDescription)
    }
}
