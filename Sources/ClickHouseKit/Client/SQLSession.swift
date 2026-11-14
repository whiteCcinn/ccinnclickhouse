import ClickHouseWire
import Foundation

/// A server session for one SQL editor (design D6): one statement at a time, the current database and
/// session `SET`s tracked client-side so they survive expired sessions, restarted servers and proxies
/// that move the session; cancellation aborts the request and kills exactly the running query id.
public actor SQLSession {
    public nonisolated let client: ClickHouseClient
    public nonisolated let sessionID: String
    nonisolated let purpose: String
    public private(set) var database: String?

    /// `SET` statements replayed into a recreated session (bounded).
    private var settingStatements: [String] = []
    /// The same settings as name/value pairs, sent per request when sessions are unavailable.
    private var settingPairs: [(String, String)] = []
    private static let maxSettings = 64

    private var established = false
    public private(set) var sessionsSupported = true
    private var sessionTimeout: Int?

    /// Increases with every run, so a late cancel never touches a newer statement.
    private var runGeneration: UInt64 = 0
    private var cancelledGeneration: UInt64?
    private var runningTask: Task<QueryResult, any Error>?
    public private(set) var runningQueryID: String?
    private var isBusy = false

    init(client: ClickHouseClient, database: String?, purpose: String = "sql") {
        self.client = client
        self.database = database?.isEmpty == true ? nil : database
        self.purpose = purpose
        sessionID = "ccinnch-\(UUID().uuidString.lowercased())"
        sessionTimeout = client.configuration.sessionTimeout > 0 ? client.configuration.sessionTimeout : nil
    }

    /// Runs one statement in the session.
    /// `idempotent` (reads) allows one retry when a stale keep-alive connection drops before any response.
    public func run(_ sql: String, limits: RowLimits = RowLimits(), timeout: Double? = nil, idempotent: Bool = false,
                    onResponse: (@Sendable (ResponseInfo) -> Void)? = nil) async throws -> QueryResult {
        // One statement at a time; a rejected second run must not touch the running one's state.
        guard !isBusy else { throw ClickHouseError(.busy, "This editor is already running a statement") }
        isBusy = true
        defer { isBusy = false }
        runGeneration &+= 1
        let generation = runGeneration
        var recreated = false
        var lockedRetries = 0
        for _ in 0..<16 {
            if Task.isCancelled || cancelledGeneration == generation { throw ClickHouseError.cancelled() }
            let queryID = RequestBuilder.makeQueryID(purpose: purpose)
            let options = QueryOptions(purpose: purpose, queryID: queryID, database: database,
                                       session: sessionsSupported ? SessionParameters(id: sessionID, check: established, timeout: sessionTimeout) : nil,
                                       settings: sessionsSupported ? [] : settingPairs, limits: limits, timeout: timeout, idempotent: idempotent,
                                       onResponse: onResponse)
            let client = client
            let task = Task { try await client.run(sql, options: options) }
            runningTask = task
            runningQueryID = queryID
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                finishRun(generation)
                if sessionsSupported { established = true }
                noteContextChange(sql)
                return recreated ? result.with(sessionRecreated: true) : result
            } catch let error as ClickHouseError {
                finishRun(generation)
                if cancelledGeneration == generation || Task.isCancelled { throw ClickHouseError.cancelled() }
                switch error.code {
                case ClickHouseError.Code.sessionNotFound? where established && !recreated:
                    // Expired, server restarted, or a proxy moved us: recreate, restore settings, retry once.
                    // Safe to retry: the server rejected the statement before running it.
                    established = false
                    recreated = true
                    await replaySettings()
                    continue
                case ClickHouseError.Code.invalidSessionTimeout? where sessionTimeout != nil:
                    sessionTimeout = nil
                    continue
                case ClickHouseError.Code.sessionIsLocked? where lockedRetries < 10:
                    // A just-cancelled statement still holds the session on the server.
                    lockedRetries += 1
                    try await Task.sleep(for: .milliseconds(300))
                    continue
                default:
                    break
                }
                if sessionsSupported, Self.isSessionUnsupported(error) {
                    sessionsSupported = false
                    continue
                }
                // The request reached ClickHouse, so the session now exists.
                if sessionsSupported, error.code != nil, error.code != ClickHouseError.Code.sessionNotFound { established = true }
                throw error
            }
        }
        throw ClickHouseError(.server, "The statement could not be started in a server session")
    }

    private func finishRun(_ generation: UInt64) {
        if runGeneration == generation {
            runningTask = nil
            runningQueryID = nil
        }
    }

    /// Stops the running statement: aborts the request and kills its query id on the server.
    public func cancel() {
        guard let task = runningTask else { return }
        cancelledGeneration = runGeneration
        task.cancel()
    }

    public func close() {
        cancel()
    }

    /// Settings the session carries (for display and tests).
    public var settings: [String] { settingStatements }

    /// A proxy that does not support `session_id` answers with a non-ClickHouse error mentioning sessions.
    static func isSessionUnsupported(_ error: ClickHouseError) -> Bool {
        guard error.kind == .server, error.code == nil else { return false }
        return error.message.lowercased().contains("session")
    }

    private func replaySettings() async {
        for statement in settingStatements {
            let options = QueryOptions(purpose: "meta", database: database,
                                       session: SessionParameters(id: sessionID, check: false, timeout: sessionTimeout),
                                       limits: .metadata, timeout: ClickHouseClient.metadataTimeout, waitEndOfQuery: true)
            if (try? await client.run(statement, options: options)) != nil { established = true }
        }
    }

    /// Tracks `USE db` and session `SET`s so a recreated session restores them.
    private func noteContextChange(_ sql: String) {
        guard let change = SessionContextChange.parse(sql) else { return }
        switch change {
        case let .use(newDatabase):
            database = newDatabase
        case let .settings(statement, pairs):
            settingStatements.append(statement)
            if settingStatements.count > Self.maxSettings { settingStatements.removeFirst(settingStatements.count - Self.maxSettings) }
            for pair in pairs {
                settingPairs.removeAll { $0.0 == pair.name }
                settingPairs.append((pair.name, pair.value))
            }
            if settingPairs.count > Self.maxSettings { settingPairs.removeFirst(settingPairs.count - Self.maxSettings) }
        }
    }
}

/// Recognises statements that change the session's database or settings.
public enum SessionContextChange: Equatable, Sendable {
    case use(String)
    /// A session `SET name = value[, …]`; pairs are empty when a value could not be parsed.
    case settings(statement: String, pairs: [SettingPair])

    public struct SettingPair: Equatable, Sendable {
        public let name: String
        public let value: String
        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public static func parse(_ sql: String) -> SessionContextChange? {
        var tokens = Tokenizer(sql).tokens()
        while tokens.last == .symbol(";") { tokens.removeLast() }
        guard let first = tokens.first, case let .word(verb) = first else { return nil }
        switch verb.uppercased() {
        case "USE":
            guard tokens.count == 2 else { return nil }
            switch tokens[1] {
            case let .word(name), let .quoted(name): return .use(name)
            default: return nil
            }
        case "SET":
            guard tokens.count >= 2, case let .word(second) = tokens[1] else { return nil }
            // Role and transaction statements are not settings and must not be replayed.
            if ["ROLE", "DEFAULT", "TRANSACTION"].contains(second.uppercased()), tokens.count > 2, tokens[2] != .symbol("=") { return nil }
            var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix(";") { trimmed.removeLast() }
            return .settings(statement: trimmed, pairs: settingPairs(Array(tokens.dropFirst())))
        default:
            return nil
        }
    }

    static func settingPairs(_ tokens: [Token]) -> [SettingPair] {
        var pairs: [SettingPair] = []
        var index = 0
        while index < tokens.count {
            guard index + 1 < tokens.count, case let .word(name) = tokens[index], tokens[index + 1] == .symbol("=") else { return [] }
            index += 2
            var valueText: String?
            if index < tokens.count {
                switch tokens[index] {
                case let .word(word): valueText = word
                case let .string(text): valueText = text
                case let .number(number): valueText = number
                default: valueText = nil
                }
            }
            guard let valueText else { return [] }
            pairs.append(SettingPair(name, valueText))
            index += 1
            if index < tokens.count {
                guard tokens[index] == .symbol(",") else { return [] }
                index += 1
            }
        }
        return index == tokens.count ? pairs : []
    }

    enum Token: Equatable {
        case word(String)
        case quoted(String)
        case string(String)
        case number(String)
        case symbol(String)
    }

    /// Minimal tokenizer for USE/SET (comments, strings, quoted identifiers, signed numbers).
    struct Tokenizer {
        let scalars: [Unicode.Scalar]
        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        func tokens() -> [Token] {
            var tokens: [Token] = []
            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar.properties.isWhitespace {
                    index += 1
                } else if scalar == "-", index + 1 < scalars.count, scalars[index + 1] == "-" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                    index += 2
                    var depth = 1
                    while index < scalars.count, depth > 0 {
                        if scalars[index] == "/", index + 1 < scalars.count, scalars[index + 1] == "*" { depth += 1; index += 2; continue }
                        if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "/" { depth -= 1; index += 2; continue }
                        index += 1
                    }
                } else if scalar == "'" || scalar == "`" || scalar == "\"" {
                    var value = String.UnicodeScalarView()
                    index += 1
                    while index < scalars.count, scalars[index] != scalar {
                        if scalars[index] == "\\", index + 1 < scalars.count {
                            index += 1
                            switch scalars[index] {
                            case "n": value.append("\n")
                            case "t": value.append("\t")
                            case "0": value.append("\0")
                            default: value.append(scalars[index])
                            }
                        } else {
                            value.append(scalars[index])
                        }
                        index += 1
                    }
                    index += 1
                    tokens.append(scalar == "'" ? .string(String(value)) : .quoted(String(value)))
                } else if scalar.properties.numericType != nil || ((scalar == "-" || scalar == "+") && index + 1 < scalars.count
                                                                    && scalars[index + 1].properties.numericType != nil) {
                    var value = String.UnicodeScalarView([scalar])
                    index += 1
                    while index < scalars.count, scalars[index].properties.numericType != nil || scalars[index] == "." || scalars[index] == "e"
                        || scalars[index] == "E" || scalars[index] == "_" {
                        value.append(scalars[index])
                        index += 1
                    }
                    tokens.append(.number(String(value)))
                } else if scalar.properties.isAlphabetic || scalar == "_" {
                    var value = String.UnicodeScalarView()
                    while index < scalars.count, scalars[index].properties.isAlphabetic || scalars[index] == "_"
                        || scalars[index].properties.numericType != nil {
                        value.append(scalars[index])
                        index += 1
                    }
                    tokens.append(.word(String(value)))
                } else {
                    tokens.append(.symbol(String(scalar)))
                    index += 1
                }
            }
            return tokens
        }
    }
}
