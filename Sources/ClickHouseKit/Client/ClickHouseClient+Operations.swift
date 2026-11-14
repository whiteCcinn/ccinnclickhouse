import ClickHouseWire
import Foundation

/// Server operations: running queries, query-log analysis, storage, clusters, Keeper, live progress.
extension ClickHouseClient {
    static let processColumns = ["query_id", "initial_query_id", "is_initial_query", "user", "address", "elapsed", "read_rows", "read_bytes",
                                 "total_rows_approx", "written_rows", "memory_usage", "peak_memory_usage", "query", "current_database", "query_kind"]

    /// Running queries, across all replicas of `cluster` when given; the app's own monitoring queries are hidden.
    public func runningQueries(cluster: String? = nil, includeAppMonitoring: Bool = false) async throws -> [RunningQuery] {
        let list = systemSchema.selectList("processes", Self.processColumns)
        let sql = "SELECT hostName() AS host, \(list) FROM \(source("processes", cluster: cluster)) ORDER BY elapsed DESC LIMIT 2000"
        let queries = try await run(sql, options: QueryOptions(purpose: "poll", limits: .metadata, timeout: Self.metadataTimeout, waitEndOfQuery: true))
            .records.map(RunningQuery.init(record:))
        return includeAppMonitoring ? queries : queries.filter { !$0.isAppMonitoring }
    }

    /// Kills a query listed by ``runningQueries(cluster:includeAppMonitoring:)`` on the node that runs it.
    @discardableResult
    public func kill(_ query: RunningQuery, cluster: String? = nil) async throws -> KillOutcome {
        let target = query.isInitialQuery ? query.queryID : (query.initialQueryID ?? query.queryID)
        let local = query.host == nil || query.host == serverInfo.hostName
        return try await killQuery(queryID: target, cluster: cluster, onAnotherNode: !local)
    }

    /// Live progress of a running query (`system.processes`), `nil` once it is no longer running.
    public func progress(of queryID: String, cluster: String? = nil) async throws -> QueryProgress? {
        let schema = systemSchema
        func column(_ name: String) -> String { schema.has("processes", column: name) ? SQLText.quoteIdentifier(name) : "0" }
        let sql = """
            SELECT \(column("elapsed")) AS elapsed, \(column("read_rows")) AS read_rows, \(column("read_bytes")) AS read_bytes, \
            \(column("total_rows_approx")) AS total_rows_approx, \(column("written_rows")) AS written_rows, \(column("written_bytes")) AS written_bytes, \
            \(column("memory_usage")) AS memory_usage, \(column("peak_memory_usage")) AS peak_memory_usage \
            FROM \(source("processes", cluster: isLoadBalanced ? cluster : nil)) WHERE query_id = \(SQLText.literal(queryID)) LIMIT 1
            """
        let result = try await run(sql, options: QueryOptions(purpose: "poll", limits: RowLimits(maxRows: 1), timeout: 10, waitEndOfQuery: true))
        guard let record = result.first else { return nil }
        var progress = QueryProgress()
        progress.elapsedNanoseconds = Int64(min(9.2e18, max(0, (record.double("elapsed") ?? 0) * 1e9)))
        progress.readRows = max(0, record.int("read_rows") ?? 0)
        progress.readBytes = max(0, record.int("read_bytes") ?? 0)
        progress.totalRowsToRead = max(0, record.int("total_rows_approx") ?? 0)
        progress.writtenRows = max(0, record.int("written_rows") ?? 0)
        progress.writtenBytes = max(0, record.int("written_bytes") ?? 0)
        progress.memoryUsage = max(0, record.int("memory_usage") ?? 0)
        progress.peakMemoryUsage = max(0, record.int("peak_memory_usage") ?? 0)
        return progress
    }

    // MARK: Query log

    public enum QueryLogAnalysis: String, Sendable, CaseIterable {
        case slowest, memory, failed, recent
    }

    /// `system.query_log` is flushed periodically and may be disabled; `nil` when it does not exist.
    public func queryLog(_ analysis: QueryLogAnalysis, hours: Double = 1, limit: Int = 100, user: String? = nil) async throws -> [QueryLogEntry]? {
        guard try await ensureSystemTable("query_log") else { return nil }
        let list = systemSchema.selectList("query_log", ["event_time", "query_duration_ms", "read_rows", "read_bytes", "result_rows", "memory_usage",
                                                         "user", "query_id", "query", "exception", "exception_code", "type", "query_kind"])
        var predicates = [timeWindow(hours: hours)]
        switch analysis {
        case .slowest, .memory: predicates.append("type = 'QueryFinish'")
        case .failed: predicates.append("type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')")
        case .recent: predicates.append("type != 'QueryStart'")
        }
        predicates.append("query_id NOT LIKE 'ccinnch-meta-%' AND query_id NOT LIKE 'ccinnch-poll-%' AND query_id NOT LIKE 'ccinnch-kill-%'")
        if let user { predicates.append("user = \(SQLText.literal(user))") }
        let order = switch analysis {
        case .slowest: "query_duration_ms DESC"
        case .memory: "memory_usage DESC"
        case .failed, .recent: "event_time DESC"
        }
        let sql = "SELECT \(list) FROM system.query_log WHERE \(predicates.joined(separator: " AND ")) ORDER BY \(order) LIMIT \(max(1, min(limit, 10_000)))"
        return try await execute(sql, timeout: 60).records.map(QueryLogEntry.init(record:))
    }

    /// Most expensive normalized query patterns.
    public func queryPatterns(hours: Double = 1, limit: Int = 50) async throws -> [QueryPattern]? {
        guard try await ensureSystemTable("query_log") else { return nil }
        guard systemSchema.has("query_log", column: "normalized_query_hash") else { return [] }
        let sql = """
            SELECT toString(normalized_query_hash) AS hash, any(query) AS sample, count() AS count, sum(query_duration_ms) AS total_ms, \
            avg(query_duration_ms) AS avg_ms, max(query_duration_ms) AS max_ms, sum(read_bytes) AS read_bytes, max(memory_usage) AS max_memory, \
            countIf(type != 'QueryFinish') AS failures FROM system.query_log \
            WHERE \(timeWindow(hours: hours)) AND type != 'QueryStart' AND query_id NOT LIKE 'ccinnch-meta-%' AND query_id NOT LIKE 'ccinnch-poll-%' \
            GROUP BY normalized_query_hash ORDER BY total_ms DESC LIMIT \(max(1, min(limit, 1_000)))
            """
        return try await execute(sql, timeout: 60).records.map(QueryPattern.init(record:))
    }

    /// Totals per user.
    public func queryLogByUser(hours: Double = 1) async throws -> [UserQueryStats]? {
        guard try await ensureSystemTable("query_log") else { return nil }
        let sql = """
            SELECT user, count() AS queries, countIf(type != 'QueryFinish') AS failures, sum(query_duration_ms) AS total_ms, \
            sum(read_bytes) AS read_bytes, sum(read_rows) AS read_rows, max(memory_usage) AS max_memory FROM system.query_log \
            WHERE \(timeWindow(hours: hours)) AND type != 'QueryStart' GROUP BY user ORDER BY total_ms DESC LIMIT 500
            """
        return try await execute(sql, timeout: 60).records.map(UserQueryStats.init(record:))
    }

    func timeWindow(hours: Double) -> String {
        let seconds = Int64(min(max(hours.isFinite ? hours : 1, 0.01), 24 * 90) * 3600)
        let dateFilter = systemSchema.has("query_log", column: "event_date") ? "event_date >= toDate(now() - \(seconds)) AND " : ""
        return "\(dateFilter)event_time >= now() - \(seconds)"
    }

    // MARK: Storage

    public func disks() async throws -> [DiskInfo] {
        let list = systemSchema.selectList("disks", ["name", "path", "type", "free_space", "total_space", "unreserved_space", "keep_free_space", "is_read_only"])
        return try await execute("SELECT \(list) FROM system.disks ORDER BY name").records.map(DiskInfo.init(record:))
    }

    public func storagePolicies() async throws -> [StoragePolicyVolume] {
        let list = systemSchema.selectList("storage_policies", ["policy_name", "volume_name", "volume_priority", "disks", "volume_type", "max_data_part_size",
                                                                "move_factor", "prefer_not_to_merge"])
        return try await execute("SELECT \(list) FROM system.storage_policies ORDER BY policy_name, volume_priority").records.map(StoragePolicyVolume.init(record:))
    }

    // MARK: Cluster

    public func clusters() async throws -> [ClusterReplica] {
        let list = systemSchema.selectList("clusters", ["cluster", "shard_num", "shard_weight", "replica_num", "host_name", "host_address", "port",
                                                        "is_local", "user", "errors_count", "slowdowns_count", "estimated_recovery_time"])
        return try await execute("SELECT \(list) FROM system.clusters ORDER BY cluster, shard_num, replica_num").records.map(ClusterReplica.init(record:))
    }

    /// Names of the clusters the server knows.
    public func clusterNames() async throws -> [String] {
        Array(Set(try await clusters().map(\.cluster))).sorted()
    }

    public func keeperStatus() async throws -> KeeperStatus {
        if systemSchema.hasTable("zookeeper_connection") {
            let list = systemSchema.selectList("zookeeper_connection", ["host", "port", "session_uptime_elapsed_seconds", "is_expired", "keeper_api_version"])
            if let record = try await tolerant("SELECT \(list) FROM system.zookeeper_connection LIMIT 1")?.first {
                return KeeperStatus(state: .connected, host: record.text("host"), port: record.int("port"),
                                    sessionUptimeSeconds: record.int("session_uptime_elapsed_seconds"), isExpired: record.bool("is_expired"),
                                    apiVersion: record.int("keeper_api_version"))
            }
        }
        do {
            _ = try await execute("SELECT count() FROM system.zookeeper WHERE path = '/'", timeout: 10)
            return KeeperStatus(state: .connected)
        } catch let error as ClickHouseError where error.kind == .server {
            let lowered = error.message.lowercased()
            // Without a <zookeeper> section the system.zookeeper table does not exist at all (UNKNOWN_TABLE).
            if error.code == 60 || lowered.contains("no zookeeper") || lowered.contains("not configured") || lowered.contains("zookeeper is not")
                || error.name == "NO_ZOOKEEPER" {
                return KeeperStatus(state: .notConfigured)
            }
            return KeeperStatus(state: .unavailable(error.message))
        }
    }

    public func macros() async throws -> [(name: String, value: String)] {
        guard let result = try await tolerant("SELECT macro, substitution FROM system.macros ORDER BY macro") else { return [] }
        return result.records.compactMap { record in
            guard let name = record.raw("macro") else { return nil }
            return (name, record.raw("substitution") ?? "")
        }
    }

    public func distributedDDLQueue(limit: Int = 200) async throws -> [DistributedDDLEntry] {
        guard systemSchema.hasTable("distributed_ddl_queue") else { return [] }
        let list = systemSchema.selectList("distributed_ddl_queue", ["entry", "host", "host_name", "status", "cluster", "query", "query_create_time",
                                                                     "query_finish_time", "exception_code"])
        let sql = "SELECT \(list) FROM system.distributed_ddl_queue ORDER BY query_create_time DESC LIMIT \(max(1, min(limit, 10_000)))"
        guard let result = try await tolerant(sql, timeout: 20) else { return [] }
        return result.records.map(DistributedDDLEntry.init(record:))
    }
}
