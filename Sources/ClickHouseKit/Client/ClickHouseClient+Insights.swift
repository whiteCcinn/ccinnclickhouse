import ClickHouseWire
import Foundation

/// Table insights: partitions, parts, indexes, projections, TTL, replication, distribution, dictionaries.
extension ClickHouseClient {
    func tableFilter(database: String, table: String) -> String {
        "database = \(SQLText.literal(database)) AND table = \(SQLText.literal(table))"
    }

    /// Partitions of a MergeTree table with active/inactive part counts and sizes.
    public func partitions(database: String, table: String) async throws -> [PartitionSummary] {
        // Not learned (refused): name the columns, so the server answers values or its error, not NULL dates.
        let known = try await ensureSystemTable("parts")
        let schema = systemSchema
        func range(_ aggregate: String, _ column: String) -> String {
            !known || schema.has("parts", column: column) ? "toString(\(aggregate)(\(column)))" : "NULL"
        }
        let minDate = range("min", "min_date")
        let maxDate = range("max", "max_date")
        let minTime = range("min", "min_time")
        let maxTime = range("max", "max_time")
        let sql = """
            SELECT partition, partition_id, countIf(active) AS active_parts, countIf(NOT active) AS inactive_parts, \
            sumIf(rows, active) AS rows, sumIf(bytes_on_disk, active) AS bytes_on_disk, \
            sumIf(data_compressed_bytes, active) AS data_compressed_bytes, sumIf(data_uncompressed_bytes, active) AS data_uncompressed_bytes, \
            \(minDate) AS min_date, \(maxDate) AS max_date, \(minTime) AS min_time, \(maxTime) AS max_time, \
            toString(maxIf(modification_time, active)) AS last_modified, maxIf(level, active) AS max_level \
            FROM system.parts WHERE \(tableFilter(database: database, table: table)) \
            GROUP BY partition, partition_id HAVING active_parts > 0 OR inactive_parts > 0 ORDER BY partition
            """
        return try await execute(sql).records.map(PartitionSummary.init(record:))
    }

    static let partColumns = ["name", "partition", "partition_id", "part_type", "active", "rows", "bytes_on_disk", "data_compressed_bytes",
                              "data_uncompressed_bytes", "marks", "modification_time", "level", "min_block_number", "max_block_number",
                              "data_version", "disk_name", "min_date", "max_date", "min_time", "max_time", "delete_ttl_info_min",
                              "delete_ttl_info_max", "projections"]

    /// Active parts, newest first, optionally of one partition.
    public func parts(database: String, table: String, partitionID: String? = nil, limit: Int = 2_000) async throws -> [PartInfo] {
        var sql = "SELECT \(try await selectList(system: "parts", Self.partColumns)) FROM system.parts WHERE \(tableFilter(database: database, table: table)) AND active"
        if let partitionID { sql += " AND partition_id = \(SQLText.literal(partitionID))" }
        sql += " ORDER BY modification_time DESC LIMIT \(max(1, min(limit, 100_000)))"
        return try await execute(sql).records.map(PartInfo.init(record:))
    }

    static let skippingIndexColumns = ["name", "type", "type_full", "expr", "granularity", "data_compressed_bytes", "data_uncompressed_bytes",
                                       "marks"]

    public func skippingIndices(database: String, table: String) async throws -> [SkippingIndex] {
        guard try await optionalSystemTable("data_skipping_indices") else { return [] }
        let list = systemSchema.selectList("data_skipping_indices", Self.skippingIndexColumns)
        let result = try await execute("SELECT \(list) FROM system.data_skipping_indices WHERE \(tableFilter(database: database, table: table))")
        return result.records.map(SkippingIndex.init(record:))
    }

    static let projectionColumns = ["name", "type", "sorting_key", "query"]

    /// Projections from `system.projections` (24.x+) or the CREATE statement, with storage from `system.projection_parts`.
    /// A user who may not read `system.projections` gets them from the CREATE statement too.
    public func projections(database: String, table: String, createStatement: String?) async throws -> [ProjectionInfo] {
        var projections: [ProjectionInfo] = []
        if try await ensureSystemTable("projections") {
            let list = systemSchema.selectList("projections", Self.projectionColumns)
            let result = try await execute("SELECT \(list) FROM system.projections WHERE \(tableFilter(database: database, table: table))")
            projections = result.records.compactMap { record in
                guard let name = record.raw("name") else { return nil }
                let sortingKey = record.stringArray("sorting_key").joined(separator: ", ")
                return ProjectionInfo(name: name, type: record.text("type"), sortingKey: sortingKey.isEmpty ? record.text("sorting_key") : sortingKey,
                                      definition: record.text("query"))
            }
        } else if let createStatement {
            projections = CreateStatementDetails.parse(createStatement).projections.map { ProjectionInfo(name: $0.name, definition: $0.definition) }
        }
        guard !projections.isEmpty, try await ensureSystemTable("projection_parts") else { return projections }
        let sizes = try await tolerant("""
            SELECT name, count() AS parts, sum(rows) AS rows, sum(bytes_on_disk) AS bytes_on_disk FROM system.projection_parts \
            WHERE \(tableFilter(database: database, table: table)) AND active GROUP BY name
            """)
        for record in sizes?.records ?? [] {
            guard let name = record.raw("name"), let index = projections.firstIndex(where: { $0.name == name }) else { continue }
            projections[index].parts = record.int("parts")
            projections[index].rows = record.int("rows")
            projections[index].bytesOnDisk = record.int("bytes_on_disk")
        }
        return projections
    }

    /// Server-wide insert-throttling thresholds (`system.merge_tree_settings`).
    public func mergeTreeLimits() async throws -> MergeTreeLimits {
        let result = try await tolerant("""
            SELECT name, value FROM system.merge_tree_settings WHERE name IN ('parts_to_delay_insert', 'parts_to_throw_insert', 'max_parts_in_total')
            """)
        var values: [String: Int64] = [:]
        for record in result?.records ?? [] {
            if let name = record.raw("name"), let value = record.int("value") { values[name] = value }
        }
        return MergeTreeLimits(partsToDelayInsert: values["parts_to_delay_insert"] ?? 1_000, partsToThrowInsert: values["parts_to_throw_insert"] ?? 3_000,
                               maxPartsInTotal: values["max_parts_in_total"] ?? 100_000)
    }

    static let replicaColumns = ["database", "table", "engine", "is_leader", "is_readonly", "is_session_expired", "future_parts", "parts_to_check",
                                 "zookeeper_path", "replica_name", "queue_size", "inserts_in_queue", "merges_in_queue", "part_mutations_in_queue",
                                 "queue_oldest_time", "absolute_delay", "last_queue_update", "last_queue_update_exception", "zookeeper_exception",
                                 "lost_part_count"]

    /// Replica health (cheap columns only: `total_replicas`/`active_replicas` query Keeper per table) — all
    /// replicated tables, or one table with the Keeper-backed counters.
    public func replicas(database: String? = nil, table: String? = nil) async throws -> [ReplicaStatus] {
        var columns = Self.replicaColumns
        if table != nil { columns += ["total_replicas", "active_replicas"] }
        var sql = "SELECT \(try await selectList(system: "replicas", columns)) FROM system.replicas"
        if let database, let table {
            sql += " WHERE \(tableFilter(database: database, table: table))"
        } else if let database {
            sql += " WHERE database = \(SQLText.literal(database))"
        }
        sql += " ORDER BY absolute_delay DESC, database, table"
        return try await execute(sql).records.map(ReplicaStatus.init(record:))
    }

    static let queueColumns = ["database", "table", "replica_name", "position", "node_name", "type", "create_time", "source_replica", "new_part_name",
                               "parts_to_merge", "is_currently_executing", "num_tries", "last_exception", "last_attempt_time", "num_postponed",
                               "postpone_reason"]

    public func replicationQueue(database: String? = nil, table: String? = nil, limit: Int = 1_000) async throws -> [ReplicationQueueEntry] {
        var sql = "SELECT \(try await selectList(system: "replication_queue", Self.queueColumns)) FROM system.replication_queue"
        if let database, let table { sql += " WHERE \(tableFilter(database: database, table: table))" }
        sql += " ORDER BY num_tries DESC, create_time LIMIT \(max(1, min(limit, 100_000)))"
        return try await execute(sql).records.map(ReplicationQueueEntry.init(record:))
    }

    static let mergeColumns = ["database", "table", "elapsed", "progress", "num_parts", "result_part_name", "partition_id", "is_mutation",
                               "total_size_bytes_compressed", "bytes_read_uncompressed", "rows_read", "rows_written", "memory_usage", "merge_type",
                               "merge_algorithm"]

    public func merges(database: String? = nil, table: String? = nil, cluster: String? = nil) async throws -> [MergeInfo] {
        let list = try await selectList(system: "merges", Self.mergeColumns)
        var sql = "SELECT hostName() AS host, \(list) FROM \(source("merges", cluster: cluster))"
        if let database, let table { sql += " WHERE \(tableFilter(database: database, table: table))" }
        sql += " ORDER BY elapsed DESC"
        return try await execute(sql).records.map(MergeInfo.init(record:))
    }

    static let mutationColumns = ["database", "table", "mutation_id", "command", "create_time", "parts_to_do", "is_done", "is_killed",
                                  "latest_failed_part", "latest_fail_time", "latest_fail_reason"]

    public func mutations(database: String? = nil, table: String? = nil, activeOnly: Bool = false, limit: Int = 500) async throws -> [MutationInfo] {
        var predicates: [String] = []
        if let database, let table { predicates.append(tableFilter(database: database, table: table)) }
        if activeOnly { predicates.append("NOT is_done") }
        var sql = "SELECT \(try await selectList(system: "mutations", Self.mutationColumns)) FROM system.mutations"
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += " ORDER BY is_done, create_time DESC LIMIT \(max(1, min(limit, 10_000)))"
        return try await execute(sql).records.map(MutationInfo.init(record:))
    }

    /// `KILL MUTATION` for one mutation; returns the number of mutations the server matched.
    @discardableResult
    public func killMutation(database: String, table: String, mutationID: String) async throws -> Int {
        let result = try await run("""
            KILL MUTATION WHERE \(tableFilter(database: database, table: table)) AND mutation_id = \(SQLText.literal(mutationID))
            """, options: QueryOptions(purpose: "kill", limits: .metadata, timeout: 30, waitEndOfQuery: true))
        return result.rows.count
    }

    static let distributionQueueColumns = ["database", "table", "data_path", "is_blocked", "error_count", "data_files", "data_compressed_bytes",
                                           "last_exception"]

    public func distributionQueue(database: String, table: String) async throws -> [DistributionQueueEntry] {
        guard try await optionalSystemTable("distribution_queue") else { return [] }
        let list = systemSchema.selectList("distribution_queue", Self.distributionQueueColumns)
        return try await execute("SELECT \(list) FROM system.distribution_queue WHERE \(tableFilter(database: database, table: table))")
            .records.map(DistributionQueueEntry.init(record:))
    }

    static let dictionaryColumns = ["database", "name", "status", "origin", "type", "key.names", "attribute.names", "bytes_allocated", "query_count",
                                    "hit_rate", "found_rate", "element_count", "load_factor", "source", "lifetime_min", "lifetime_max",
                                    "last_successful_update_time", "loading_duration", "last_exception", "comment"]

    public func dictionaries(database: String? = nil) async throws -> [DictionaryInfo] {
        var sql = "SELECT \(try await selectList(system: "dictionaries", Self.dictionaryColumns)) FROM system.dictionaries"
        if let database { sql += " WHERE database = \(SQLText.literal(database))" }
        sql += " ORDER BY database, name"
        return try await execute(sql).records.map(DictionaryInfo.init(record:))
    }

    public func reloadDictionary(_ dictionary: DictionaryInfo) async throws {
        let name = dictionary.database.isEmpty ? SQLText.quoteIdentifier(dictionary.name) : SQLText.qualified(dictionary.database, dictionary.name)
        _ = try await run("SYSTEM RELOAD DICTIONARY \(name)", options: QueryOptions(purpose: "meta", limits: .metadata, timeout: 120, waitEndOfQuery: true))
    }

    /// `system.<table>` locally or across every replica of `cluster`.
    func source(_ table: String, cluster: String?) -> String {
        guard let cluster, !cluster.isEmpty else { return "system.\(table)" }
        return "clusterAllReplicas(\(SQLText.literal(cluster)), system.\(table))"
    }
}
