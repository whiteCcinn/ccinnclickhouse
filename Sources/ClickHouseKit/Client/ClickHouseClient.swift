import ClickHouseWire
import Foundation
import os

/// Entry point for one ClickHouse endpoint: server facts, capabilities, statement execution,
/// cancellation and the metadata / insight / operation APIs (see the `ClickHouseClient+*.swift` extensions).
public final class ClickHouseClient: Sendable {
    public let configuration: ConnectionConfiguration
    public let serverInfo: ServerInfo
    public let capabilities: ConnectionCapabilities
    public let systemSchema: SystemSchema
    let builder: RequestBuilder
    let transport: any ClickHouseTransport
    private let tunnel: SSHTunnel?
    /// Display names of the nodes that answered (more than one → load-balanced endpoint).
    private let seenNodes = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Default per-statement budget for metadata queries issued by the app itself.
    public static let metadataTimeout: Double = 30

    init(configuration: ConnectionConfiguration, serverInfo: ServerInfo, capabilities: ConnectionCapabilities, systemSchema: SystemSchema,
         builder: RequestBuilder, transport: any ClickHouseTransport, tunnel: SSHTunnel?, seenNodes: Set<String>) {
        self.configuration = configuration
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.systemSchema = systemSchema
        self.builder = builder
        self.transport = transport
        self.tunnel = tunnel
        self.seenNodes.withLock { $0.formUnion(seenNodes) }
    }

    // MARK: Connect

    /// Probes the server (version, user, settings permissions) and loads the system schema.
    /// The client takes ownership of `tunnel` and closes it in `close()`.
    public static func connect(_ configuration: ConnectionConfiguration, tunnel: SSHTunnel? = nil,
                               transportFactory: TransportFactory = Transports.urlSession) async throws -> ClickHouseClient {
        if Task.isCancelled {
            tunnel?.close()
            throw ClickHouseError.cancelled()
        }
        let effective = tunnel.map { configuration.with(endpoint: $0.localAddress) } ?? configuration
        guard let baseURL = effective.baseURL else {
            tunnel?.close()
            throw ClickHouseError(.invalidArgument, "Enter a valid host and port")
        }
        let transport = transportFactory(effective)
        do {
            var nodes = Set<String>()
            let probeSeconds = ConnectionConfiguration.sanitizedConnectTimeout(configuration.connectTimeout) * 2
            let (probe, capabilities) = try await Deadline.run(seconds: probeSeconds, timeoutError: {
                ClickHouseError(.timeout, "\(configuration.endpoint) did not answer within \(wholeSeconds(probeSeconds)) s")
            }) {
                var learned = ConnectionCapabilities()
                let info = try await Self.probe(effective, baseURL: baseURL, transport: transport, capabilities: &learned)
                return (info, learned)
            }
            if let name = probe.displayName { nodes.insert(name) }
            let builder = RequestBuilder(configuration: effective, baseURL: baseURL, capabilities: capabilities)
            if effective.readOnly {
                try await Self.verifyReadOnly(probe: probe, builder: builder, transport: transport)
            }
            let schemaResult = try await Self.run(SystemSchema.loadQuery, builder: builder, transport: transport,
                                                  options: .metadata(timeout: max(configuration.connectTimeout, 10)))
            if let name = schemaResult.result.serverDisplayName { nodes.insert(name) }
            let client = ClickHouseClient(configuration: configuration, serverInfo: probe, capabilities: capabilities,
                                          systemSchema: SystemSchema(result: schemaResult.result), builder: builder, transport: transport,
                                          tunnel: tunnel, seenNodes: nodes)
            return client
        } catch {
            transport.close()
            tunnel?.close()
            throw error
        }
    }

    static let probeSQL = """
        SELECT version() AS version, timezone() AS timezone, currentUser() AS user, hostName() AS host, \
        uptime() AS uptime, currentDatabase() AS database, getSetting('readonly') AS readonly
        """
    static let minimalProbeSQL = "SELECT version() AS version, timezone() AS timezone, currentUser() AS user, hostName() AS host, currentDatabase() AS database"

    /// Runs the probe, learning which settings may be sent (design D7).
    static func probe(_ configuration: ConnectionConfiguration, baseURL: URL, transport: any ClickHouseTransport,
                      capabilities: inout ConnectionCapabilities) async throws -> ServerInfo {
        var sql = probeSQL
        for _ in 0..<8 {
            let builder = RequestBuilder(configuration: configuration, baseURL: baseURL, capabilities: capabilities)
            do {
                let outcome = try await run(sql, builder: builder, transport: transport,
                                            options: QueryOptions(purpose: "meta", limits: .metadata, timeout: nil, waitEndOfQuery: true, idempotent: true))
                let record = outcome.result.first
                // At readonly=2 a later per-request readonly=1 (MCP run_query) would be refused.
                if let level = record?.int("readonly"), level >= 2 { capabilities.serverEnforcesReadOnly = true }
                return ServerInfo(versionString: record?.text("version") ?? "unknown", timeZone: record?.text("timezone"),
                                  currentUser: record?.text("user"), hostName: record?.text("host"),
                                  displayName: outcome.result.serverDisplayName ?? record?.text("host"),
                                  uptimeSeconds: record?.int("uptime"), defaultDatabase: record?.text("database"),
                                  readonlyLevel: record?.int("readonly").map { Int(clamping: $0) })
            } catch let error as ClickHouseError where error.kind == .server {
                if error.code == ClickHouseError.Code.readonly, !capabilities.serverEnforcesReadOnly, error.message.contains("Cannot modify 'readonly'") {
                    // A readonly=2 profile: the server is read-only already and refuses the parameter.
                    capabilities.serverEnforcesReadOnly = true
                    continue
                }
                if error.code == ClickHouseError.Code.readonly, !capabilities.settingsLocked, error.message.contains("Cannot modify") {
                    capabilities.settingsLocked = true
                    continue
                }
                if error.code == ClickHouseError.Code.unknownSetting, let name = unknownSettingName(error.message),
                   !capabilities.unsupportedSettings.contains(name) {
                    capabilities.unsupportedSettings.insert(name)
                    continue
                }
                if sql != minimalProbeSQL, error.code != nil, !ClickHouseError.authenticationCodes.contains(error.code ?? 0) {
                    // e.g. getSetting/uptime unavailable on an old or restricted server
                    sql = minimalProbeSQL
                    continue
                }
                throw error
            }
        }
        throw ClickHouseError(.server, "The server rejected every probe query")
    }

    /// Read-only connections must be read-only *on the server*: some proxies (chproxy) drop `readonly=1`
    /// from the URL. Checked on the real request path (same transport, proxy and parameters); fails
    /// closed when the level cannot be confirmed.
    static func verifyReadOnly(probe: ServerInfo, builder: RequestBuilder, transport: any ClickHouseTransport) async throws {
        var level = probe.readonlyLevel
        if level == nil {
            let outcome = try? await run("SELECT getSetting('readonly') AS readonly", builder: builder, transport: transport,
                                         options: QueryOptions(purpose: "meta", limits: .metadata, timeout: 15, waitEndOfQuery: true, idempotent: true))
            level = outcome?.result.first?.int("readonly").map { Int(clamping: $0) }
        }
        guard let level, level >= 1 else {
            throw ClickHouseError(.readOnlyNotEnforced, """
                This endpoint does not apply readonly=1 (a proxy such as chproxy may drop it), so ClickHouse would not enforce \
                read-only access. Connect as a dedicated ClickHouse user whose settings profile is read-only and who has SELECT \
                grants only (recommended, also for AI access), or connect to ClickHouse directly.
                """)
        }
    }

    /// `Unknown setting 'x'` / `Setting x is neither a builtin setting…`.
    static func unknownSettingName(_ message: String) -> String? {
        if let match = message.firstMatch(of: /[Ss]etting '?([A-Za-z0-9_]+)'?/) { return String(match.output.1) }
        return nil
    }

    public func close() async {
        transport.close()
        tunnel?.close()
    }

    public var isTunnelled: Bool { tunnel != nil }

    /// False once the SSH tunnel process this client depends on has exited.
    public var isTunnelAlive: Bool { tunnel?.isRunning ?? true }

    /// The endpoint is served by more than one node (a load balancer or proxy).
    public var isLoadBalanced: Bool { seenNodes.withLock { $0.count > 1 } }

    public var nodesSeen: Set<String> { seenNodes.withLock { $0 } }

    func noteNode(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        seenNodes.withLock { _ = $0.insert(name) }
    }

    // MARK: Statements

    /// Runs one statement. Cancelling the calling task aborts the request and kills the query on the server.
    ///
    /// Idempotent statements are retried once when the connection drops before any response (a
    /// keep-alive connection the server closed as we sent). A dropped connection does not prove the
    /// server never received the first attempt, so the retry gets its own query id (no
    /// QUERY_WITH_SAME_ID_IS_ALREADY_RUNNING) and the first attempt is killed; a session still held by
    /// it yields SESSION_IS_LOCKED, which `SQLSession` waits out.
    public func run(_ sql: String, options: QueryOptions = QueryOptions()) async throws -> QueryResult {
        let queryID = options.queryID ?? RequestBuilder.makeQueryID(purpose: options.purpose)
        var options = options
        options.queryID = queryID
        let builder = builder
        let transport = transport
        // Every query id sent for this statement, so cancellation and timeouts kill all of them.
        let attempts = OSAllocatedUnfairLock(initialState: [queryID])
        let work: @Sendable () async throws -> ResponseReader.Outcome = { [options, self] in
            do {
                return try await Self.run(sql, builder: builder, transport: transport, options: options)
            } catch let error as ClickHouseError where error.isConnectionLostBeforeResponse && options.idempotent && !Task.isCancelled {
                var retry = options
                let retryID = RequestBuilder.makeQueryID(purpose: options.purpose)
                retry.queryID = retryID
                attempts.withLock { $0.append(retryID) }
                self.killInBackground(queryID: queryID)
                // A fresh connection: with keep_alive_timeout=3 (22.x) several pooled connections can be
                // stale at once, and the pool could hand the retry another one.
                return try await Self.run(sql, builder: builder, transport: transport, options: retry, freshConnection: true)
            }
        }
        func killAll() {
            for id in attempts.withLock({ $0 }) { killInBackground(queryID: id) }
        }
        do {
            let outcome: ResponseReader.Outcome
            if let timeout = options.timeout, timeout.isFinite {
                outcome = try await Deadline.run(seconds: timeout, timeoutError: {
                    ClickHouseError(.timeout, "The statement did not finish within \(wholeSeconds(timeout)) s")
                }, work)
            } else {
                outcome = try await work()
            }
            noteNode(outcome.result.serverDisplayName)
            if outcome.stoppedEarly { killInBackground(queryID: outcome.result.queryID) }
            return outcome.result
        } catch let error as ClickHouseError where error.kind == .cancelled || error.kind == .timeout {
            // The request was abandoned; query ids are unique, so these kills can never hit another statement.
            killAll()
            throw error
        } catch is CancellationError {
            killAll()
            throw ClickHouseError.cancelled()
        }
    }

    static func run(_ sql: String, builder: RequestBuilder, transport: any ClickHouseTransport, options: QueryOptions,
                    freshConnection: Bool = false) async throws -> ResponseReader.Outcome {
        let queryID = options.queryID ?? RequestBuilder.makeQueryID(purpose: options.purpose)
        let request = try builder.request(sql: sql, queryID: queryID, options: options, freshConnection: freshConnection)
        let response = try await transport.send(request)
        return try await withTaskCancellationHandler {
            try await ResponseReader.read(response, queryID: queryID, limits: options.limits, onResponse: options.onResponse)
        } onCancel: {
            response.cancel()
        }
    }

    /// Runs a metadata statement (buffered on the server, metadata limits and timeout).
    public func execute(_ sql: String, timeout: Double? = ClickHouseClient.metadataTimeout) async throws -> QueryResult {
        try await run(sql, options: .metadata(timeout: timeout))
    }

    /// Runs an optional metadata statement: `nil` when the feature is unavailable (unknown table on an
    /// older version, missing privilege, no Keeper). Timeouts, memory limits, cancellations and network
    /// errors propagate, including those the server reports as exceptions, so a slow cluster never
    /// yields silently incomplete metadata.
    public func tolerant(_ sql: String, timeout: Double? = ClickHouseClient.metadataTimeout) async throws -> QueryResult? {
        do {
            return try await execute(sql, timeout: timeout)
        } catch let error as ClickHouseError where error.isFeatureUnavailable {
            return nil
        }
    }

    /// Opens an editor session (keeps `USE`/`SET` state across statements and reconnects).
    public func openSession(database: String? = nil) -> SQLSession {
        SQLSession(client: self, database: database ?? configuration.database)
    }

    // MARK: Kill

    public enum KillOutcome: Sendable, Equatable {
        /// The server found the query; `status` is `finished`, `waiting` or `pending`.
        case killed(status: String?)
        /// No node reached knows this query (it may already have finished).
        case notFound
    }

    /// `KILL QUERY WHERE query_id = …` (design D5). `host` (the `hostName()` that listed the query)
    /// restricts the kill to that node, so a query with the same id elsewhere is never hit. When the
    /// query may run on another node (the caller says so, or the endpoint is — or turns out during the
    /// kill to be — load-balanced) the kill is retried on fresh connections and finally sent
    /// `ON CLUSTER` when a cluster is known.
    @discardableResult
    public func killQuery(queryID: String, cluster: String? = nil, onAnotherNode: Bool = false, host: String? = nil,
                          sync: Bool = false) async throws -> KillOutcome {
        let condition = processCondition(queryID: queryID)
            + (host.flatMap { $0.isEmpty ? nil : " AND hostName() = \(SQLText.literal($0))" } ?? "")
        let sql = "KILL QUERY WHERE \(condition) \(sync ? "SYNC" : "ASYNC")"
        let builder = builder
        let transport = transport
        return try await Deadline.run(seconds: 30, timeoutError: { ClickHouseError(.timeout, "The server did not answer KILL QUERY in time") }) {
            for attempt in 0..<8 {
                try Task.checkCancellation()
                let outcome = try await Self.run(sql, builder: builder, transport: transport,
                                                 options: QueryOptions(purpose: "kill", limits: .metadata, timeout: 10, waitEndOfQuery: true,
                                                                       readOnly: false, idempotent: true),
                                                 freshConnection: attempt > 0)
                // A different node answering reveals a load balancer even if the probe did not.
                self.noteNode(outcome.result.serverDisplayName)
                if let row = outcome.result.first {
                    return KillOutcome.killed(status: row.text("kill_status"))
                }
                if !(onAnotherNode || self.isLoadBalanced) { break }
            }
            guard onAnotherNode || self.isLoadBalanced, let cluster = cluster ?? self.configuration.defaultCluster, !cluster.isEmpty else {
                return KillOutcome.notFound
            }
            do {
                let onCluster = "KILL QUERY ON CLUSTER \(SQLText.quoteIdentifier(cluster)) WHERE \(condition) ASYNC"
                let outcome = try await Self.run(onCluster, builder: builder, transport: transport,
                                                 options: QueryOptions(purpose: "kill", limits: .metadata, timeout: 15, waitEndOfQuery: true,
                                                                       readOnly: false))
                return outcome.result.rows.isEmpty ? KillOutcome.notFound : KillOutcome.killed(status: nil)
            } catch let error as ClickHouseError where error.kind == .server {
                return KillOutcome.notFound
            }
        }
    }

    /// Matches a query in `system.processes` by id, or by the `log_comment` marker the app sends when a
    /// proxy (chproxy) replaced the id.
    func processCondition(queryID: String) -> String {
        let byID = "query_id = \(SQLText.literal(queryID))"
        guard !capabilities.settingsLocked, !capabilities.unsupportedSettings.contains("log_comment"),
              systemSchema.has("processes", column: "Settings") else { return byID }
        let marker = RequestBuilder.marker(application: configuration.applicationName, queryID: queryID)
        return "(\(byID) OR Settings['log_comment'] = \(SQLText.literal(marker)))"
    }

    func killInBackground(queryID: String) {
        Task.detached { [self] in _ = try? await killQuery(queryID: queryID) }
    }
}
