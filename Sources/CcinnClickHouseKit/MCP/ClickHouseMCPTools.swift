import ClickHouseKit
import ClickHouseWire
import Foundation
import os

/// Caches one resource per profile id. It re-opens the resource when its key changes (the profile was
/// edited or its AI access downgraded), when it is no longer healthy (a dead SSH tunnel), or after it was
/// evicted following a connectivity failure. A cancelled caller cancels an open nobody else waits for.
public actor KeyedResourceCache<Key: Hashable & Sendable, Value: Sendable> {
    public typealias Opener = @Sendable (Key) async throws -> Value

    private struct Entry {
        let key: Key
        let value: Value
    }

    /// One open in flight, shared by every caller asking for the same key.
    private final class PendingOpen: Sendable {
        let key: Key
        let task: Task<Value, any Error>
        private let waiters = OSAllocatedUnfairLock(initialState: 0)

        init(key: Key, task: Task<Value, any Error>) {
            self.key = key
            self.task = task
        }

        func join() { waiters.withLock { $0 += 1 } }

        /// A waiter was cancelled: the open is cancelled once nobody waits for it any more.
        func leave() {
            if waiters.withLock({ count -> Int in count -= 1; return count }) <= 0 { task.cancel() }
        }
    }

    private let opener: Opener
    private let isHealthy: @Sendable (Value) -> Bool
    private let close: @Sendable (Value) async -> Void
    /// A value whose open was superseded while a caller still uses it is closed after this grace period.
    private let supersededGrace: Duration
    private var entries: [UUID: Entry] = [:]
    private var opening: [UUID: PendingOpen] = [:]

    public init(opener: @escaping Opener, isHealthy: @escaping @Sendable (Value) -> Bool = { _ in true },
                close: @escaping @Sendable (Value) async -> Void = { _ in }, supersededGrace: Duration = .seconds(150)) {
        self.opener = opener
        self.isHealthy = isHealthy
        self.close = close
        self.supersededGrace = supersededGrace
    }

    public func value(id: UUID, key: Key) async throws -> Value {
        if let entry = entries[id] {
            if entry.key == key, isHealthy(entry.value) { return entry.value }
            entries[id] = nil
            retire(entry.value, after: .zero)
        }
        let pending: PendingOpen
        if let existing = opening[id], existing.key == key {
            pending = existing
        } else {
            opening[id]?.task.cancel()
            let opener = opener
            pending = PendingOpen(key: key, task: Task { try await opener(key) })
            opening[id] = pending
        }
        pending.join()
        let result = await withTaskCancellationHandler { await pending.task.result } onCancel: { pending.leave() }
        let isCurrent = opening[id] === pending
        if isCurrent { opening[id] = nil }
        let value: Value
        do {
            value = try result.get()
        } catch {
            if Task.isCancelled || error is CancellationError { throw ClickHouseError.cancelled() }
            throw error
        }
        if isCurrent {
            // Callers asking for the same key share this open, so an existing entry is never this key.
            if let stale = entries[id] { retire(stale.value, after: .zero) }
            entries[id] = Entry(key: key, value: value)
        } else {
            // A newer key replaced this open while it ran: serve this call, then close it.
            retire(value, after: supersededGrace)
        }
        if Task.isCancelled { throw ClickHouseError.cancelled() }
        return value
    }

    /// Drops the cached value (after a connectivity failure) so the next call opens a fresh one.
    public func evict(id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        retire(entry.value, after: .zero)
    }

    public func closeAll() async {
        let open = entries.values.map(\.value)
        entries.removeAll()
        for pending in opening.values { pending.task.cancel() }
        opening.removeAll()
        for value in open { await close(value) }
    }

    private func retire(_ value: Value, after delay: Duration) {
        let close = close
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            await close(value)
        }
    }
}

/// A profile together with the AI access it was opened for: any change opens a new client, so a
/// downgrade from Read & write never keeps using a client opened without `readonly=1`.
public struct MCPClientKey: Hashable, Sendable {
    public let profile: ConnectionProfile
    public let access: MCPAccess
}

/// Opens and caches a client per profile for the MCP process (re-opened on profile/access changes,
/// dead tunnels and connectivity failures).
public actor MCPClientRegistry {
    public typealias Opener = @Sendable (ConnectionProfile, MCPAccess) async throws -> ClickHouseClient

    private let cache: KeyedResourceCache<MCPClientKey, ClickHouseClient>

    public init(opener: @escaping Opener) {
        cache = KeyedResourceCache(opener: { key in try await opener(key.profile, key.access) },
                                   isHealthy: { $0.isTunnelAlive }, close: { await $0.close() })
    }

    public func client(for profile: ConnectionProfile, access: MCPAccess) async throws -> ClickHouseClient {
        try await cache.value(id: profile.id, key: MCPClientKey(profile: profile, access: access))
    }

    public func evict(profileID: UUID) async {
        await cache.evict(id: profileID)
    }

    public func closeAll() async {
        await cache.closeAll()
    }
}

/// The saved connections as the MCP server sees them on each call, so a change made in Settings (AI
/// access switched off or downgraded, a host edited) applies to a running server without a restart.
/// A file that cannot be read yields no connections (fail closed).
public struct MCPProfileSource: Sendable {
    private let load: @Sendable () throws -> [ConnectionProfile]
    public let defaultProfile: String?
    public let forceReadOnly: Bool

    public init(defaultProfile: String?, forceReadOnly: Bool, load: @escaping @Sendable () throws -> [ConnectionProfile]) {
        self.load = load
        self.defaultProfile = defaultProfile
        self.forceReadOnly = forceReadOnly
    }

    /// A fixed set of profiles (tests, one-shot tools).
    public init(_ resolver: MCPProfileResolver) {
        let profiles = resolver.profiles
        self.init(defaultProfile: resolver.defaultProfile, forceReadOnly: resolver.forceReadOnly, load: { profiles })
    }

    public func resolver() -> MCPProfileResolver {
        MCPProfileResolver(profiles: (try? load()) ?? [], defaultProfile: defaultProfile, forceReadOnly: forceReadOnly)
    }
}

/// The ClickHouse tool set of the MCP server (design D15, shared ccinn MCP design).
public struct ClickHouseMCPTools: MCPToolProvider {
    public let profiles: MCPProfileSource
    public let registry: MCPClientRegistry
    public let audit: MCPAuditLog?

    public static let defaultRowLimit = 200
    public static let maxRowLimit = 1_000
    public static let defaultTimeout = 30.0
    public static let maxTimeout = 120.0

    public init(profiles: MCPProfileSource, registry: MCPClientRegistry, audit: MCPAuditLog?) {
        self.profiles = profiles
        self.registry = registry
        self.audit = audit
    }

    public init(resolver: MCPProfileResolver, registry: MCPClientRegistry, audit: MCPAuditLog?) {
        self.init(profiles: MCPProfileSource(resolver), registry: registry, audit: audit)
    }

    // MARK: Definitions

    static let connectionProperty: JSONValue = ["type": "string", "description": "Saved connection name or id (see list_connections). Optional when only one connection is enabled or a default was configured."]
    static let databaseProperty: JSONValue = ["type": "string", "description": "Database name."]
    static let tableProperty: JSONValue = ["type": "string", "description": "Table, view, dictionary or materialized view name."]
    static let hoursProperty: JSONValue = ["type": "number", "minimum": 0.05, "maximum": 2160, "description": "Time window in hours (default 1)."]
    static let clusterProperty: JSONValue = ["type": "string", "description": "Cluster name for a cluster-wide view (default: the connection's cluster, if any)."]

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var all = properties
        all["connection"] = connectionProperty
        return ["type": "object", "properties": .object(all), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }

    static let definitions: [MCPTool] = [
        MCPTool(name: "list_connections", title: "List connections",
                description: "Lists the saved ClickHouse connections the user enabled for AI access (no secrets).",
                inputSchema: ["type": "object", "properties": .object([:]), "additionalProperties": false], readOnly: true),
        MCPTool(name: "list_databases", title: "List databases",
                description: "Lists databases with their engine (Atomic, Replicated, MySQL, PostgreSQL, …) and comment.",
                inputSchema: schema([:]), readOnly: true),
        MCPTool(name: "list_tables", title: "List tables",
                description: "Lists tables, views, materialized views and dictionaries of a database with engine, engine family (mergetree, replicated_mergetree, distributed, materialized_view, view, dictionary, streaming, integration, log, memory …), MergeTree variant, rows, bytes on disk, active parts and keys.",
                inputSchema: schema(["database": databaseProperty,
                                     "name_filter": ["type": "string", "description": "Case-insensitive substring to filter table names."]],
                                    required: ["database"]), readOnly: true),
        MCPTool(name: "describe_table", title: "Describe table",
                description: "Columns (type, default, codec, comment, compressed/uncompressed size and ratio, key membership, TTL), engine name and keys (partition, sorting, primary, sampling), projections, skipping indexes, dependent materialized views and the MV target. Object definitions (DDL, engine arguments and settings, view queries) are withheld from AI access.",
                inputSchema: schema(["database": databaseProperty, "table": tableProperty], required: ["database", "table"]), readOnly: true),
        MCPTool(name: "get_parts", title: "Get partitions and parts",
                description: "Partitions of a MergeTree table (active/inactive parts, rows, bytes, compression) with part-count warnings against parts_to_delay_insert / parts_to_throw_insert, and optionally the newest active parts.",
                inputSchema: schema(["database": databaseProperty, "table": tableProperty,
                                     "include_parts": ["type": "boolean", "description": "Also list active parts (default false)."],
                                     "limit": ["type": "integer", "minimum": 1, "maximum": 2000, "description": "Maximum partitions/parts returned (default 200)."]],
                                    required: ["database", "table"]), readOnly: true),
        MCPTool(name: "get_merges_and_mutations", title: "Get merges and mutations",
                description: "Running merges (progress, parts, sizes, memory) and mutations (command, parts to do, latest failure) — server-wide or for one table.",
                inputSchema: schema(["database": databaseProperty, "table": tableProperty,
                                     "include_finished": ["type": "boolean", "description": "Include finished mutations (default false)."]]),
                readOnly: true, idempotent: false),
        MCPTool(name: "get_replication", title: "Get replication",
                description: "Replica health of Replicated* tables (leader, read-only, session expired, absolute delay, queue sizes, last exceptions) and the replication queue (entries with tries and postpone reasons).",
                inputSchema: schema(["database": databaseProperty, "table": tableProperty,
                                     "queue_limit": ["type": "integer", "minimum": 0, "maximum": 1000, "description": "Queue entries to include (default 100)."]]),
                readOnly: true, idempotent: false),
        MCPTool(name: "get_running_queries", title: "Get running queries",
                description: "Queries running now (host, user, query id, elapsed, rows/bytes read, memory, text), across the cluster when one is given or configured.",
                inputSchema: schema(["cluster": clusterProperty]), readOnly: true, idempotent: false),
        MCPTool(name: "analyze_query_log", title: "Analyze query log",
                description: "Analyses system.query_log over a time window: slowest, memory (highest memory), failed, patterns (most expensive normalized queries) or by_user totals.",
                inputSchema: schema(["analysis": ["type": "string", "enum": ["slowest", "memory", "failed", "patterns", "by_user"], "description": "Which analysis (default slowest)."],
                                     "hours": hoursProperty,
                                     "user": ["type": "string", "description": "Only queries of this user (slowest/memory/failed)."],
                                     "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum entries (default 50)."]]),
                readOnly: true, idempotent: false),
        MCPTool(name: "get_cluster", title: "Get cluster topology",
                description: "Clusters from system.clusters (shards, replicas, local node, errors), Keeper/ZooKeeper connection, macros and recent ON CLUSTER DDL tasks.",
                inputSchema: schema([:]), readOnly: true, idempotent: false),
        MCPTool(name: "get_storage", title: "Get disks and storage policies",
                description: "Disks (type, path, free/total space) and storage policies (volumes, disks, move factor).",
                inputSchema: schema([:]), readOnly: true, idempotent: false),
        MCPTool(name: "list_dictionaries", title: "List dictionaries",
                description: "External dictionaries with status, origin, layout type, keys, attributes, element count, memory, hit rate and last exception.",
                inputSchema: schema(["database": databaseProperty]), readOnly: true, idempotent: false),
        MCPTool(name: "run_query", title: "Run read-only SQL",
                description: "Runs one read-only statement (SELECT, WITH, SHOW, DESCRIBE, EXISTS, EXPLAIN) with readonly=1 enforced by ClickHouse, and returns columns (with ClickHouse types) and rows. A LIMIT is added to queries without one; results are capped at `limit` rows and about 256 KB.",
                inputSchema: schema(["sql": ["type": "string", "description": "A single read-only SQL statement."],
                                     "database": ["type": "string", "description": "Current database for unqualified names."],
                                     "limit": ["type": "integer", "minimum": 1, "maximum": .int(Int64(maxRowLimit)), "description": "Maximum rows (default 200)."],
                                     "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(maxTimeout)), "description": "Time limit (default 30)."]],
                                    required: ["sql"]), readOnly: true, idempotent: false),
        MCPTool(name: "explain_query", title: "Explain query",
                description: "Explains a SELECT query: plan, plan_indexes (index usage), pipeline, estimate (rows/marks/parts to read) or ast. Quoted strings in the result are shown as '?'.",
                inputSchema: schema(["sql": ["type": "string", "description": "A SELECT or WITH query."],
                                     "database": ["type": "string", "description": "Current database for unqualified names."],
                                     "kind": ["type": "string", "enum": ["plan", "plan_indexes", "pipeline", "estimate", "ast"], "description": "Kind of EXPLAIN (default plan_indexes)."]],
                                    required: ["sql"]), readOnly: true),
    ]

    static let executeDefinition = MCPTool(
        name: "execute_statement", title: "Execute SQL (writes allowed)",
        description: "Runs one SQL statement that may change data or schema (INSERT, ALTER … UPDATE/DELETE, CREATE, DROP, OPTIMIZE, SYSTEM …). Only available on connections with read-write AI access. Prefer run_query for reads.",
        inputSchema: schema(["sql": ["type": "string", "description": "A single SQL statement."],
                             "database": ["type": "string", "description": "Current database for unqualified names."],
                             "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(maxTimeout))]],
                            required: ["sql"]), readOnly: false, destructive: true, idempotent: false)

    public func tools() async -> [MCPTool] {
        Self.tools(for: profiles.resolver())
    }

    static func tools(for resolver: MCPProfileResolver) -> [MCPTool] {
        resolver.anyWritable ? definitions + [executeDefinition] : definitions
    }

    // MARK: Calls

    /// Collects audit details while a tool runs.
    final class CallContext: @unchecked Sendable {
        var connection: String?
        var profileID: UUID?
        var statement: String?
        var rows: Int?
    }

    public func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        let clock = ContinuousClock()
        let started = clock.now
        let context = CallContext()
        let result: MCPToolResult
        do {
            // Defence in depth under the guard: credentials are masked in every string a tool returns.
            result = .success(Self.maskingSecrets(try await dispatch(name, Arguments(arguments), context)))
        } catch let error as MCPToolError {
            result = .failure(SQLRedactor.maskMessageSecrets(error.message))
        } catch let error as ClickHouseError {
            // A broken connection (network, TLS, SSH tunnel) is re-opened on the next call.
            if [.network, .tls, .sshTunnel].contains(error.kind), let profileID = context.profileID {
                await registry.evict(profileID: profileID)
            }
            var message = error.message
            if let code = error.code { message += " (code \(code)\(error.name.map { ", \($0)" } ?? ""))" }
            if error.code == ClickHouseError.Code.readonly { message += " The connection is read-only for AI access." }
            // Server errors can echo a view's query (`while processing query: …`).
            result = .failure(SQLRedactor.maskMessageSecrets(message))
        } catch is CancellationError {
            result = .failure("The call was cancelled.")
        } catch {
            result = .failure(SQLRedactor.maskMessageSecrets(error.localizedDescription))
        }
        let elapsed = clock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        await audit?.record(tool: name, connection: context.connection, statement: context.statement, durationMilliseconds: milliseconds,
                            rows: context.rows, error: result.isError ? result.payload.stringValue : nil)
        return result
    }

    private func dispatch(_ name: String, _ args: Arguments, _ context: CallContext) async throws -> JSONValue {
        // Profiles and their AI access are re-read for every call (revocation takes effect at once).
        let resolver = profiles.resolver()
        let definitions = Self.tools(for: resolver)
        guard let definition = definitions.first(where: { $0.name == name }) else {
            if name == Self.executeDefinition.name {
                throw MCPToolError("execute_statement is only available when a connection allows read-write AI access.")
            }
            throw MCPToolError("Unknown tool “\(name)”. Available tools: \(definitions.map(\.name).joined(separator: ", ")).")
        }
        try args.validate(against: definition.inputSchema)
        if let key = args.controlCharacterArgument() {
            throw MCPToolError("`\(key)` contains a control character. Names are sent to the server as given, so they must be plain text.")
        }
        if name == "list_connections" { return Self.listConnections(resolver) }
        let resolved = try resolver.resolve(args.string("connection"))
        context.connection = resolved.profile.displayName
        context.profileID = resolved.profile.id
        // Refuse what can be refused without a connection: nothing is opened or sent for rejected SQL.
        switch name {
        case "run_query", "explain_query":
            let sql = try args.required("sql")
            let database = args.string("database")?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? resolved.profile.defaultDatabase
            if let reason = ReadOnlySQLGuard.check(sql, audience: .ai(database: database)) {
                context.statement = sql
                throw MCPToolError(reason + (resolved.access == .readWrite ? " Use execute_statement for statements that change data." : ""))
            }
        case "execute_statement":
            guard resolved.access == .readWrite else {
                throw MCPToolError("Connection “\(resolved.profile.displayName)” only allows read-only AI access; use run_query, or change its AI access to Read & write in CcinnClickHouse.")
            }
        default:
            break
        }
        let client = try await registry.client(for: resolved.profile, access: resolved.access)
        // Before every read-only call: the user's grants (a privileged user is refused unless the connection opts in:
        // readonly=1 does not stop file(), url(), SYSTEM or access management) and the effective readonly level.
        if resolved.access != .readWrite {
            if let refusal = await MCPPrivilegeReport.readOnlyRefusal(client: client, profile: resolved.profile) { throw MCPToolError(refusal) }
        }
        let cluster = args.string("cluster") ?? resolved.profile.defaultCluster?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch name {
        case "list_databases":
            return ["databases": .array(try await client.databases().map { database in
                ["name": .string(database.name), "engine": .string(database.engine), "comment": JSONValue(database.comment)]
            })]
        case "list_tables": return try await listTables(client, args)
        case "describe_table": return try await describeTable(client, args)
        case "get_parts": return try await parts(client, args)
        case "get_merges_and_mutations": return try await mergesAndMutations(client, args)
        case "get_replication": return try await replication(client, args)
        case "get_running_queries":
            let queries = try await client.runningQueries(cluster: cluster)
            return ["cluster": JSONValue(cluster), "queries": .array(queries.prefix(200).map(Self.encode(query:))),
                    "count": .int(Int64(queries.count))]
        case "analyze_query_log": return try await queryLog(client, args)
        case "get_cluster": return try await clusterTopology(client)
        case "get_storage":
            async let disks = client.disks()
            async let policies = client.storagePolicies()
            return ["disks": .array(try await disks.map(Self.encode(disk:))), "storage_policies": .array(try await policies.map(Self.encode(volume:)))]
        case "list_dictionaries":
            return ["dictionaries": .array(try await client.dictionaries(database: args.string("database")).prefix(500).map(Self.encode(dictionary:)))]
        case "run_query": return try await runQuery(client, args, context, access: resolved.access)
        case "explain_query": return try await explain(client, args, context, access: resolved.access)
        case "execute_statement":
            guard resolved.access == .readWrite else {
                throw MCPToolError("Connection “\(resolved.profile.displayName)” only allows read-only AI access; use run_query, or change its AI access to Read & write in CcinnClickHouse.")
            }
            return try await execute(client, args, context)
        default:
            throw MCPToolError("Unknown tool “\(name)”.")
        }
    }

    private static func listConnections(_ resolver: MCPProfileResolver) -> JSONValue {
        ["connections": .array(resolver.enabledProfiles.map { profile in
            [
                "name": .string(profile.displayName),
                "id": .string(profile.id.uuidString),
                "endpoint": .string("\(profile.secure ? "https" : "http")://\(profile.endpoint)"),
                "user": .string(profile.username),
                "default_database": JSONValue(profile.defaultDatabase),
                "cluster": JSONValue(profile.defaultCluster),
                "ssh_tunnel": .bool(profile.ssh != nil),
                "access": .string(resolver.access(of: profile) == .readWrite ? "read_write" : "read_only"),
            ]
        })]
    }

    // MARK: Metadata tools

    private func listTables(_ client: ClickHouseClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        var tables = try await client.tables(database: database).filter { !$0.isInnerTable }
        if let filter = args.string("name_filter") { tables = tables.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        let cap = 1_000
        return ["database": .string(database), "tables": .array(tables.prefix(cap).map(Self.encode(table:))),
                "count": .int(Int64(tables.count)), "truncated": .bool(tables.count > cap)]
    }

    private func findTable(_ client: ClickHouseClient, database: String, name: String) async throws -> TableInfo {
        if let table = try await client.table(database: database, name: name) { return table }
        let all = try await client.tables(database: database)
        if let match = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           let table = try await client.table(database: database, name: match.name) {
            return table
        }
        let similar = all.filter { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }.prefix(10).map(\.name)
        throw MCPToolError("No table named “\(name)” in \(database).\(similar.isEmpty ? "" : " Similar: \(similar.joined(separator: ", ")).")")
    }

    private func describeTable(_ client: ClickHouseClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let table = try await findTable(client, database: database, name: try args.required("table"))
        let details = table.createTableQuery.map(CreateStatementDetails.parse) ?? CreateStatementDetails()
        var columns = try await client.columns(database: database, table: table.name)
        for index in columns.indices { columns[index].ttl = details.columnTTLs[columns[index].name] }
        var result = Self.encode(table: table).objectValue ?? [:]
        result["columns"] = .array(columns.map(Self.encode(column:)))
        // Deny by default: no object definitions for AI access, on any version (22.8 prints credentials in them, 24.8 still
        // prints the ones in URLs). Columns, keys and the engine name stay; engine arguments, settings and queries do not.
        result["definitions_withheld"] = .string(Self.definitionsWithheldNote)
        if table.family.hasParts {
            async let indices = client.skippingIndices(database: database, table: table.name)
            async let projections = client.projections(database: database, table: table.name, createStatement: table.createTableQuery)
            do {
                result["skipping_indexes"] = .array(try await indices.map { index in
                    ["name": .string(index.name), "type": .string(index.typeFull ?? index.type), "expression": .string(index.expression),
                     "granularity": .int(index.granularity), "compressed_bytes": JSONValue(index.compressedBytes),
                     "uncompressed_bytes": JSONValue(index.uncompressedBytes)]
                })
            } catch let error as ClickHouseError where error.isAccessDenied {
                result["skipping_indexes"] = Self.accessDeniedNote("data_skipping_indices")
            }
            result["projections"] = .array(try await projections.map { projection in
                ["name": .string(projection.name), "type": JSONValue(projection.type), "sorting_key": JSONValue(projection.sortingKey),
                 "parts": JSONValue(projection.parts), "rows": JSONValue(projection.rows),
                 "bytes_on_disk": JSONValue(projection.bytesOnDisk)]
            })
        }
        if !table.dependentTables.isEmpty { result["dependent_tables"] = .array(table.dependentTables.map(JSONValue.string)) }
        if let target = details.materializedViewTarget { result["materialized_view_target"] = .string(target) }
        return .object(result)
    }

    private func parts(_ client: ClickHouseClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let table = try await findTable(client, database: database, name: try args.required("table"))
        guard table.family.hasParts else {
            throw MCPToolError("\(database).\(table.name) uses the \(table.engine) engine, which has no MergeTree parts.")
        }
        let limit = args.int("limit", default: 200, range: 1...2_000)
        async let partitionsTask = client.partitions(database: database, table: table.name)
        async let limitsTask = client.mergeTreeLimits()
        let partitions = try await partitionsTask
        let limits = try await limitsTask.overridden(by: table.engineDefinition)
        let warnings = PartHealth.warnings(partitions: partitions, limits: limits)
        var result: [String: JSONValue] = [
            "database": .string(database), "table": .string(table.name),
            "partition_count": .int(Int64(partitions.count)),
            "active_parts": .int(partitions.reduce(0) { $0 &+ $1.activeParts }),
            "rows": .int(partitions.reduce(0) { $0 &+ $1.rows }),
            "bytes_on_disk": .int(partitions.reduce(0) { $0 &+ $1.bytesOnDisk }),
            "limits": ["parts_to_delay_insert": .int(limits.partsToDelayInsert), "parts_to_throw_insert": .int(limits.partsToThrowInsert),
                       "max_parts_in_total": .int(limits.maxPartsInTotal)],
            "warnings": .array(warnings.map { ["level": .string(Self.levelName($0.level)), "message": .string($0.message)] }),
            "partitions": .array(partitions.sorted { $0.activeParts > $1.activeParts }.prefix(limit).map { partition in
                ["partition": .string(partition.partition), "partition_id": .string(partition.partitionID), "active_parts": .int(partition.activeParts),
                 "inactive_parts": .int(partition.inactiveParts), "rows": .int(partition.rows), "bytes_on_disk": .int(partition.bytesOnDisk),
                 "compression_ratio": JSONValue(partition.compressionRatio.map { ($0 * 100).rounded() / 100 }),
                 "min_date": JSONValue(partition.minDate ?? partition.minTime), "max_date": JSONValue(partition.maxDate ?? partition.maxTime),
                 "level": .string(Self.levelName(PartHealth.level(activeParts: partition.activeParts, limits: limits)))]
            }),
            "truncated": .bool(partitions.count > limit),
        ]
        if args.bool("include_parts") ?? false {
            let parts = try await client.parts(database: database, table: table.name, limit: limit)
            result["parts"] = .array(parts.map { part in
                ["name": .string(part.name), "partition": .string(part.partition), "type": JSONValue(part.partType), "level": .int(part.level),
                 "rows": .int(part.rows), "bytes_on_disk": .int(part.bytesOnDisk), "compressed_bytes": .int(part.compressedBytes),
                 "uncompressed_bytes": .int(part.uncompressedBytes), "marks": .int(part.marks), "modified": JSONValue(part.modificationTime),
                 "disk": JSONValue(part.disk), "delete_ttl_min": JSONValue(part.deleteTTLMin), "delete_ttl_max": JSONValue(part.deleteTTLMax)]
            })
        }
        return .object(result)
    }

    private func mergesAndMutations(_ client: ClickHouseClient, _ args: Arguments) async throws -> JSONValue {
        let database = args.string("database")
        let table = args.string("table")
        async let merges = client.merges(database: database, table: table)
        async let mutations = client.mutations(database: database, table: table, activeOnly: !(args.bool("include_finished") ?? false), limit: 200)
        return [
            "merges": .array(try await merges.prefix(200).map { merge in
                ["host": JSONValue(merge.host), "database": .string(merge.database), "table": .string(merge.table),
                 "elapsed_seconds": .double((merge.elapsed * 10).rounded() / 10), "progress": .double((merge.progress * 1000).rounded() / 1000),
                 "parts": .int(merge.numParts), "result_part": .string(merge.resultPartName), "is_mutation": .bool(merge.isMutation),
                 "size_compressed": .int(merge.totalSizeCompressed), "rows_read": .int(merge.rowsRead), "memory": .int(merge.memoryUsage)]
            }),
            "mutations": .array(try await mutations.map { mutation in
                ["database": .string(mutation.database), "table": .string(mutation.table), "mutation_id": .string(mutation.mutationID),
                 "command": .string(String(SQLRedactor.digest(mutation.command).prefix(2_000))), "created": JSONValue(mutation.createTime),
                 "parts_to_do": .int(mutation.partsToDo), "is_done": .bool(mutation.isDone),
                 "latest_fail_reason": JSONValue(mutation.latestFailReason.map {
                     String(SQLRedactor.digestMessage($0, statements: [mutation.command]).prefix(2_000))
                 }),
                 "latest_failed_part": JSONValue(mutation.latestFailedPart)]
            }),
        ]
    }

    private func replication(_ client: ClickHouseClient, _ args: Arguments) async throws -> JSONValue {
        let database = args.string("database")
        let table = args.string("table")
        let queueLimit = args.int("queue_limit", default: 100, range: 0...1_000)
        let replicas = try await client.replicas(database: database, table: table)
        var result: [String: JSONValue] = [
            "replicated_tables": .int(Int64(replicas.count)),
            "replicas": .array(replicas.prefix(500).map { replica in
                ["database": .string(replica.database), "table": .string(replica.table), "health": .string(Self.healthName(replica.health)),
                 "is_leader": .bool(replica.isLeader), "is_readonly": .bool(replica.isReadonly), "is_session_expired": .bool(replica.isSessionExpired),
                 "absolute_delay_seconds": .int(replica.absoluteDelay), "queue_size": .int(replica.queueSize),
                 "inserts_in_queue": .int(replica.insertsInQueue), "merges_in_queue": .int(replica.mergesInQueue),
                 "active_replicas": JSONValue(replica.activeReplicas), "total_replicas": JSONValue(replica.totalReplicas),
                 "replica_name": JSONValue(replica.replicaName), "zookeeper_path": JSONValue(replica.zookeeperPath),
                 "last_queue_update_exception": JSONValue(replica.lastQueueUpdateException), "zookeeper_exception": JSONValue(replica.zookeeperException)]
            }),
        ]
        if queueLimit > 0 {
            let queue = try await client.replicationQueue(database: database, table: table, limit: queueLimit)
            // A failing MUTATE_PART repeats the mutation's literal values in its error: those of the table's mutations are
            // masked there. If the mutations cannot be read, the errors are withheld.
            var mutationCommands: [String: [String]]? = [:]
            if queue.contains(where: { $0.lastException != nil }) {
                mutationCommands = (try? await client.mutations(database: database, table: table, activeOnly: true, limit: 1_000))
                    .map { Dictionary(grouping: $0, by: { "\($0.database).\($0.table)" }).mapValues { $0.map(\.command) } }
            }
            func lastException(_ entry: ReplicationQueueEntry) -> JSONValue {
                guard let message = entry.lastException else { return .null }
                guard let commands = mutationCommands else { return "(withheld: the table's mutations, whose values it may repeat, could not be read)" }
                return .string(String(SQLRedactor.digestMessage(message, statements: commands["\(entry.database).\(entry.table)"] ?? []).prefix(2_000)))
            }
            result["queue"] = .array(queue.map { entry in
                ["database": .string(entry.database), "table": .string(entry.table), "type": .string(entry.type), "node": .string(entry.nodeName),
                 "new_part": JSONValue(entry.newPartName), "tries": .int(entry.numTries), "executing": .bool(entry.isCurrentlyExecuting),
                 "postpone_reason": JSONValue(entry.postponeReason),
                 "last_exception": lastException(entry),
                 "created": JSONValue(entry.createTime)]
            })
        }
        return .object(result)
    }

    private func queryLog(_ client: ClickHouseClient, _ args: Arguments) async throws -> JSONValue {
        let analysis = args.string("analysis") ?? "slowest"
        let hours = min(max(args.double("hours") ?? 1, 0.05), 2_160)
        let limit = args.int("limit", default: 50, range: 1...500)
        let unavailable = MCPToolError("system.query_log is not available on this server (it may be disabled or not flushed yet).")
        switch analysis {
        case "patterns":
            guard let patterns = try await client.queryPatterns(hours: hours, limit: limit) else { throw unavailable }
            return ["analysis": "patterns", "hours": .double(hours), "patterns": .array(patterns.map { pattern in
                ["sample": .string(String(SQLRedactor.digest(pattern.sample).prefix(2_000))), "count": .int(pattern.count),
                 "total_ms": .int(pattern.totalDurationMilliseconds),
                 "avg_ms": .double((pattern.averageDurationMilliseconds * 10).rounded() / 10), "max_ms": .int(pattern.maxDurationMilliseconds),
                 "read_bytes": .int(pattern.totalReadBytes), "max_memory": .int(pattern.maxMemoryUsage), "failures": .int(pattern.failures)]
            })]
        case "by_user":
            guard let users = try await client.queryLogByUser(hours: hours) else { throw unavailable }
            return ["analysis": "by_user", "hours": .double(hours), "users": .array(users.prefix(limit).map { user in
                ["user": .string(user.user), "queries": .int(user.queries), "failures": .int(user.failures), "total_ms": .int(user.totalDurationMilliseconds),
                 "read_bytes": .int(user.readBytes), "read_rows": .int(user.readRows), "max_memory": .int(user.maxMemoryUsage)]
            })]
        case "slowest", "memory", "failed":
            let kind: ClickHouseClient.QueryLogAnalysis = analysis == "memory" ? .memory : analysis == "failed" ? .failed : .slowest
            guard let entries = try await client.queryLog(kind, hours: hours, limit: limit, user: args.string("user")) else { throw unavailable }
            return ["analysis": .string(analysis), "hours": .double(hours), "queries": .array(entries.map { entry in
                ["time": .string(entry.eventTime), "duration_ms": .int(entry.durationMilliseconds), "read_rows": .int(entry.readRows),
                 "read_bytes": .int(entry.readBytes), "result_rows": .int(entry.resultRows), "memory": .int(entry.memoryUsage), "user": .string(entry.user),
                 "query_id": .string(entry.queryID), "query": .string(String(SQLRedactor.digest(entry.query).prefix(2_000))),
                 "exception": JSONValue(entry.exception.map { String(SQLRedactor.digestMessage($0, statements: [entry.query]).prefix(1_000)) })]
            })]
        default:
            throw MCPToolError("Unknown analysis “\(analysis)”; use slowest, memory, failed, patterns or by_user.")
        }
    }

    /// One part of a composite answer the user may not read: said so, instead of failing the whole call.
    static func accessDeniedNote(_ table: String) -> JSONValue {
        .string("access denied: this ClickHouse user may not read system.\(table)")
    }

    private func clusterTopology(_ client: ClickHouseClient) async throws -> JSONValue {
        async let clusters = client.clusters()
        async let keeper = client.keeperStatus()
        async let macros = client.macros()
        async let ddl = client.distributedDDLQueue(limit: 20)
        let keeperState: JSONValue
        switch try await keeper.state {
        case .connected: keeperState = "connected"
        case .notConfigured: keeperState = "not_configured"
        case let .unavailable(message): keeperState = .string("unavailable: \(message.prefix(500))")
        }
        let keeperValue = try await keeper
        let recentDDL: JSONValue
        do {
            recentDDL = .array(try await ddl.map { entry in
                ["entry": .string(entry.entry), "host": JSONValue(entry.host), "status": JSONValue(entry.status),
                 "query": .string(String(SQLRedactor.digest(entry.query).prefix(1_000))), "exception_code": JSONValue(entry.exceptionCode)]
            })
        } catch let error as ClickHouseError where error.isAccessDenied {
            recentDDL = Self.accessDeniedNote("distributed_ddl_queue")
        }
        return [
            "clusters": .array(try await clusters.prefix(500).map { replica in
                ["cluster": .string(replica.cluster), "shard": .int(replica.shardNumber), "replica": .int(replica.replicaNumber),
                 "host": .string(replica.hostName), "port": .int(replica.port), "is_local": .bool(replica.isLocal), "errors": .int(replica.errorsCount)]
            }),
            "keeper": ["state": keeperState, "host": JSONValue(keeperValue.host), "port": JSONValue(keeperValue.port),
                       "session_uptime_seconds": JSONValue(keeperValue.sessionUptimeSeconds)],
            "macros": .object(Dictionary(try await macros.map { ($0.name, JSONValue.string($0.value)) }, uniquingKeysWith: { $1 })),
            "recent_ddl": recentDDL,
        ]
    }

    // MARK: SQL tools

    /// The database unqualified names resolve in for a call: the argument, the connection's, or the user's default.
    static func effectiveDatabase(_ args: Arguments, _ client: ClickHouseClient) -> String? {
        database(args, client) ?? client.serverInfo.defaultDatabase
    }

    /// The guard's AI audience for a call on `client`.
    static func aiAudience(_ args: Arguments, _ client: ClickHouseClient) -> ReadOnlySQLGuard.Audience {
        .ai(database: effectiveDatabase(args, client))
    }

    static let definitionsWithheldNote = "Object definitions (DDL, engine arguments and settings, view and projection queries) are withheld from AI access because they can carry credentials; columns, keys and the engine name are shown."

    /// Every string in `value` with credentials masked (`SQLRedactor.maskSecrets`). When values were altered, the result
    /// says how many (`"masked": N`), so the AI does not take them for the data; the echoed `statement` (the AI's own
    /// text) is masked too but not counted.
    static func maskingSecrets(_ value: JSONValue) -> JSONValue {
        guard case let .object(members) = value else { return value.mappingStrings { SQLRedactor.maskSecrets($0).text } }
        var masked = 0
        var result: [String: JSONValue] = [:]
        for (key, member) in members {
            result[key] = member.mappingStrings { text in
                let outcome = SQLRedactor.maskSecrets(text)
                if key != "statement" { masked += outcome.count }
                return outcome.text
            }
        }
        if masked > 0 { result["masked"] = .int(Int64(masked)) }
        return .object(result)
    }

    /// An EXPLAIN result as AI access may see it: 26.8 prints the literals of the views a query reads in plans
    /// (`Filter column: … != 'secret'`), so every quoted string becomes `'?'`.
    static func maskingPlanLiterals(_ payload: [String: JSONValue]) -> [String: JSONValue] {
        payload.mapValues { $0.mappingStrings(SQLRedactor.maskStringLiterals) }
    }

    private func runQuery(_ client: ClickHouseClient, _ args: Arguments, _ context: CallContext, access: MCPAccess) async throws -> JSONValue {
        let sql = try args.required("sql")
        guard let statement = SQLStatementSplitter.split(sql).first?.text else { throw MCPToolError("The statement is empty.") }
        let limit = args.int("limit", default: Self.defaultRowLimit, range: 1...Self.maxRowLimit)
        // The exact text sent (with the automatic LIMIT) is what the guard checks.
        let prepared: ReadOnlySQLGuard.Prepared
        switch ReadOnlySQLGuard.prepare(statement, autoLimit: limit + 1, audience: Self.aiAudience(args, client)) {
        case let .success(value): prepared = value
        case let .failure(refusal):
            context.statement = sql
            throw MCPToolError(refusal.reason + (access == .readWrite ? " Use execute_statement for statements that change data." : ""))
        }
        let executed = prepared.text
        let limitApplied = prepared.limit != nil
        context.statement = executed
        let timeout = min(max(args.double("timeout_seconds") ?? Self.defaultTimeout, 1), Self.maxTimeout)
        // Read-only calls are also enforced by ClickHouse itself (readonly=1).
        let result = try await client.run(executed, options: QueryOptions(purpose: "mcp", database: Self.database(args, client),
                                                                          limits: RowLimits(maxRows: limit, maxBytes: 64 * 1024 * 1024),
                                                                          timeout: timeout, readOnly: true, idempotent: true))
        var payload = Self.encode(result: result, limit: limit)
        if SQLStatementKind.of(executed) == .explain { payload = Self.maskingPlanLiterals(payload) }
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        payload["statement"] = .string(executed)
        payload["limit_applied"] = .bool(limitApplied)
        payload["database"] = JSONValue(args.string("database"))
        if let summary = result.summary {
            payload["elapsed_ms"] = .int(summary.elapsedNanoseconds / 1_000_000)
            payload["read_rows"] = .int(summary.readRows)
            payload["read_bytes"] = .int(summary.readBytes)
        }
        return .object(payload)
    }

    private func explain(_ client: ClickHouseClient, _ args: Arguments, _ context: CallContext, access: MCPAccess) async throws -> JSONValue {
        let sql = try args.required("sql")
        let statements = SQLStatementSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first?.text else { throw MCPToolError("Pass exactly one SELECT query.") }
        let prefix: String
        switch args.string("kind") ?? "plan_indexes" {
        case "plan": prefix = "EXPLAIN"
        case "plan_indexes": prefix = "EXPLAIN indexes = 1"
        case "pipeline": prefix = "EXPLAIN PIPELINE"
        case "estimate": prefix = "EXPLAIN ESTIMATE"
        case "ast": prefix = "EXPLAIN AST"
        case let other: throw MCPToolError("Unknown kind “\(other)”; use plan, plan_indexes, pipeline, estimate or ast.")
        }
        // The exact text sent (with its EXPLAIN head) is what the guard checks.
        let prepared = ReadOnlySQLGuard.prepare(statement, prefix: SQLStatementKind.of(statement) == .explain ? nil : prefix,
                                                audience: Self.aiAudience(args, client))
        let body: String
        switch prepared {
        case let .success(value): body = value.text
        case let .failure(refusal): throw MCPToolError(refusal.reason)
        }
        context.statement = body
        let result = try await client.run(body, options: QueryOptions(purpose: "mcp", database: Self.database(args, client),
                                                                      limits: RowLimits(maxRows: 20_000, maxBytes: 16 * 1024 * 1024),
                                                                      timeout: Self.defaultTimeout, readOnly: true, idempotent: true))
        if result.columns.count > 1 {
            // EXPLAIN ESTIMATE returns a table.
            var payload = Self.maskingPlanLiterals(Self.encode(result: result, limit: 1_000))
            payload["statement"] = .string(body)
            context.rows = result.rows.count
            return .object(payload)
        }
        let lines = result.rows.map { $0.compactMap { $0 }.joined(separator: "\t") }
        var plan = SQLRedactor.maskStringLiterals(lines.joined(separator: "\n"))
        if plan.utf8.count > MCPResultEncoder.defaultMaxBytes { plan = MCPResultEncoder.prefix(plan, maxBytes: MCPResultEncoder.defaultMaxBytes) + "\n… (truncated)" }
        context.rows = lines.count
        return ["statement": .string(body), "plan": .string(plan)]
    }

    private func execute(_ client: ClickHouseClient, _ args: Arguments, _ context: CallContext) async throws -> JSONValue {
        let sql = try args.required("sql")
        let statements = SQLStatementSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first?.text else { throw MCPToolError("Pass exactly one statement per call.") }
        context.statement = statement
        let timeout = min(max(args.double("timeout_seconds") ?? Self.defaultTimeout, 1), Self.maxTimeout)
        let result = try await client.run(statement, options: QueryOptions(purpose: "mcp", database: Self.database(args, client),
                                                                           limits: RowLimits(maxRows: Self.maxRowLimit, maxBytes: 64 * 1024 * 1024),
                                                                           timeout: timeout))
        var payload = Self.encode(result: result, limit: Self.maxRowLimit)
        payload["statement"] = .string(statement)
        payload["written_rows"] = .int(result.writtenRows)
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        return .object(payload)
    }

    /// The `database` argument, else the connection's default database. Every MCP call is a stateless
    /// request (no server session), so a `USE` or `SET` of one call never carries into the next.
    static func database(_ args: Arguments, _ client: ClickHouseClient) -> String? {
        args.string("database")?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? client.configuration.database
    }

    // MARK: Encoding

    static func encode(result: QueryResult, limit: Int) -> [String: JSONValue] {
        if let raw = result.rawText {
            let text = MCPResultEncoder.prefix(raw, maxBytes: MCPResultEncoder.defaultMaxBytes)
            return ["format": JSONValue(result.format), "text": .string(text), "row_count": 0,
                    "truncated": .bool(result.isTruncated || text.utf8.count < raw.utf8.count)]
        }
        guard result.hasRowSet else {
            return ["row_count": 0, "message": "OK"]
        }
        return MCPResultEncoder.rows(columns: result.columns, rows: Array(result.rows.prefix(limit)),
                                     truncatedByServer: result.isTruncated || result.rows.count > limit).objectValue ?? [:]
    }

    static func familyName(_ family: EngineFamily) -> String {
        switch family {
        case .mergeTree: "mergetree"
        case .replicatedMergeTree: "replicated_mergetree"
        case .sharedMergeTree: "shared_mergetree"
        case .distributed: "distributed"
        case .materializedView: "materialized_view"
        case .view: "view"
        case .dictionary: "dictionary"
        case .streaming: "streaming"
        case .integration: "integration"
        case .dataLake: "data_lake"
        case .log: "log"
        case .memory: "memory"
        case .system: "system"
        case .other: "other"
        }
    }

    static func levelName(_ level: PartHealth.Level) -> String {
        switch level {
        case .ok: "ok"
        case .warning: "warning"
        case .critical: "critical"
        case .failing: "failing"
        }
    }

    static func healthName(_ health: ReplicaStatus.Health) -> String {
        switch health {
        case .healthy: "healthy"
        case .lagging: "lagging"
        case .readonly: "readonly"
        case .sessionExpired: "session_expired"
        }
    }

    static func encode(table: TableInfo) -> JSONValue {
        let classification = table.classification
        var result: [String: JSONValue] = [
            "name": .string(table.name), "engine": .string(table.engine), "family": .string(familyName(classification.family)),
            "variant": JSONValue(classification.variant.flatMap { $0 == .plain ? nil : $0.rawValue }),
            "replicated": classification.isReplicated ? .bool(true) : .null,
            "rows": JSONValue(table.totalRows), "bytes_on_disk": JSONValue(table.totalBytes),
            "bytes_uncompressed": JSONValue(table.totalBytesUncompressed), "active_parts": JSONValue(table.activeParts),
            "comment": JSONValue(table.comment), "partition_key": JSONValue(table.partitionKey), "sorting_key": JSONValue(table.sortingKey),
            "primary_key": JSONValue(table.primaryKey), "sampling_key": JSONValue(table.samplingKey), "storage_policy": JSONValue(table.storagePolicy),
        ]
        if table.isTemporary { result["temporary"] = .bool(true) }
        return .object(result.filter { $0.value != .null })
    }

    static func encode(column: ColumnInfo) -> JSONValue {
        let value: JSONValue = [
            "name": .string(column.name), "type": .string(column.type), "default_kind": JSONValue(column.defaultKind),
            "default": JSONValue(column.defaultExpression), "codec": JSONValue(column.codec), "comment": JSONValue(column.comment),
            "ttl": JSONValue(column.ttl), "compressed_bytes": JSONValue(column.compressedBytes), "uncompressed_bytes": JSONValue(column.uncompressedBytes),
            "compression_ratio": JSONValue(column.compressionRatio.map { ($0 * 100).rounded() / 100 }),
            "in_partition_key": column.isInPartitionKey ? .bool(true) : .null, "in_sorting_key": column.isInSortingKey ? .bool(true) : .null,
            "in_primary_key": column.isInPrimaryKey ? .bool(true) : .null, "in_sampling_key": column.isInSamplingKey ? .bool(true) : .null,
        ]
        return .object((value.objectValue ?? [:]).filter { $0.value != .null })
    }

    static func encode(query: RunningQuery) -> JSONValue {
        ["host": JSONValue(query.host), "query_id": .string(query.queryID), "user": .string(query.user),
         "elapsed_seconds": .double((query.elapsed * 10).rounded() / 10), "read_rows": .int(query.readRows), "read_bytes": .int(query.readBytes),
         "total_rows_approx": .int(query.totalRowsApprox), "memory": .int(query.memoryUsage), "is_initial": .bool(query.isInitialQuery),
         "query": .string(String(SQLRedactor.digest(query.query).prefix(2_000)))]
    }

    static func encode(disk: DiskInfo) -> JSONValue {
        ["name": .string(disk.name), "type": JSONValue(disk.type), "path": JSONValue(disk.path), "free_bytes": .int(disk.freeSpace),
         "total_bytes": .int(disk.totalSpace), "used_fraction": JSONValue(disk.usedFraction.map { ($0 * 1000).rounded() / 1000 })]
    }

    static func encode(volume: StoragePolicyVolume) -> JSONValue {
        ["policy": .string(volume.policy), "volume": .string(volume.volume), "priority": .int(volume.priority),
         "disks": .array(volume.disks.map(JSONValue.string)), "move_factor": JSONValue(volume.moveFactor), "type": JSONValue(volume.volumeType)]
    }

    static func encode(dictionary: DictionaryInfo) -> JSONValue {
        ["database": .string(dictionary.database), "name": .string(dictionary.name), "status": .string(dictionary.status),
         "type": JSONValue(dictionary.type), "origin": JSONValue(dictionary.origin), "keys": .array(dictionary.keyNames.map(JSONValue.string)),
         "attributes": .array(dictionary.attributeNames.map(JSONValue.string)), "elements": .int(dictionary.elementCount),
         "bytes_allocated": .int(dictionary.bytesAllocated), "hit_rate": JSONValue(dictionary.hitRate),
         "last_update": JSONValue(dictionary.lastSuccessfulUpdateTime), "last_exception": JSONValue(dictionary.lastException.map { String($0.prefix(1_000)) })]
    }
}

/// Typed access to tool arguments with clear error messages.
struct Arguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    /// Rejects arguments the tool does not declare (`additionalProperties: false`) and wrong basic types.
    func validate(against schema: JSONValue) throws {
        let properties = schema["properties"]?.objectValue ?? [:]
        let unknown = values.keys.filter { properties[$0] == nil }.sorted()
        if !unknown.isEmpty {
            throw MCPToolError("Unknown argument\(unknown.count == 1 ? "" : "s") \(unknown.map { "`\($0)`" }.joined(separator: ", ")). Allowed: \(properties.keys.sorted().joined(separator: ", ")).")
        }
        for (key, value) in values {
            guard let type = properties[key]?["type"]?.stringValue, value != .null else { continue }
            let valid: Bool = switch (type, value) {
            case ("string", .string), ("string", .int): true
            case ("integer", .int), ("integer", .double), ("integer", .string): value.intValue != nil
            case ("number", .int), ("number", .double), ("number", .string): value.doubleValue?.isFinite == true
            case ("boolean", .bool), ("boolean", .string): value.boolValue != nil
            default: false
            }
            if !valid { throw MCPToolError("Argument `\(key)` must be a \(type).") }
            if let allowed = properties[key]?["enum"]?.arrayValue, let text = value.stringValue, !allowed.contains(.string(text)) {
                throw MCPToolError("Argument `\(key)` must be one of \(allowed.compactMap(\.stringValue).joined(separator: ", ")).")
            }
        }
        for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where string(required) == nil {
            throw MCPToolError("Missing required argument `\(required)`.")
        }
    }

    /// The first argument other than `sql` whose text holds a control character (Unicode Cc: NUL, C0, DEL, C1). A step
    /// that drops or rewrites one (a wire writer, identifier quoting) would make the server read another name than the
    /// one checked; such names are refused before anything is sent.
    func controlCharacterArgument() -> String? {
        values.keys.sorted().first { key in
            guard key != "sql", case let .string(text) = values[key] else { return false }
            return text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        let text: String? = switch value {
        case let .string(string): string
        case let .int(number): String(number)
        default: nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw MCPToolError("Missing required argument `\(key)`.") }
        return value
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let value = values[key]?.intValue else { return fallback }
        return Int(clamping: min(max(value, Int64(range.lowerBound)), Int64(range.upperBound)))
    }

    func double(_ key: String) -> Double? {
        values[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
