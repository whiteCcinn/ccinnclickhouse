import Foundation

/// A running query (`system.processes`, optionally across the cluster).
public struct RunningQuery: Sendable, Hashable, Identifiable {
    public var host: String?
    public var queryID: String
    public var initialQueryID: String?
    public var isInitialQuery: Bool
    public var user: String
    public var address: String?
    public var elapsed: Double
    public var readRows: Int64
    public var readBytes: Int64
    public var totalRowsApprox: Int64
    public var writtenRows: Int64
    public var memoryUsage: Int64
    public var peakMemoryUsage: Int64?
    public var query: String
    public var currentDatabase: String?
    public var queryKind: String?

    public var id: String { "\(host ?? "")\u{1F}\(queryID)" }

    /// Internal monitoring queries of this app (hidden from activity views).
    public var isAppMonitoring: Bool {
        queryID.hasPrefix("ccinnch-meta-") || queryID.hasPrefix("ccinnch-poll-") || queryID.hasPrefix("ccinnch-kill-")
    }

    public var fractionDone: Double? {
        guard totalRowsApprox > 0 else { return nil }
        return min(1, max(0, Double(readRows) / Double(totalRowsApprox)))
    }

    init(record: Record) {
        host = record.text("host")
        queryID = record.raw("query_id") ?? ""
        initialQueryID = record.text("initial_query_id")
        isInitialQuery = record.bool("is_initial_query") ?? true
        user = record.raw("user") ?? ""
        address = record.text("address")
        elapsed = record.double("elapsed") ?? 0
        readRows = record.int("read_rows") ?? 0
        readBytes = record.int("read_bytes") ?? 0
        totalRowsApprox = record.int("total_rows_approx") ?? 0
        writtenRows = record.int("written_rows") ?? 0
        memoryUsage = record.int("memory_usage") ?? 0
        peakMemoryUsage = record.int("peak_memory_usage")
        query = record.raw("query") ?? ""
        currentDatabase = record.text("current_database")
        queryKind = record.text("query_kind")
    }
}

/// One finished (or failed) query from `system.query_log`.
public struct QueryLogEntry: Sendable, Hashable, Identifiable {
    public var eventTime: String
    public var durationMilliseconds: Int64
    public var readRows: Int64
    public var readBytes: Int64
    public var resultRows: Int64
    public var memoryUsage: Int64
    public var user: String
    public var queryID: String
    public var query: String
    public var exception: String?
    public var exceptionCode: Int64?
    public var type: String
    public var queryKind: String?

    public var id: String { queryID + eventTime }

    init(record: Record) {
        eventTime = record.raw("event_time") ?? ""
        durationMilliseconds = record.int("query_duration_ms") ?? 0
        readRows = record.int("read_rows") ?? 0
        readBytes = record.int("read_bytes") ?? 0
        resultRows = record.int("result_rows") ?? 0
        memoryUsage = record.int("memory_usage") ?? 0
        user = record.raw("user") ?? ""
        queryID = record.raw("query_id") ?? ""
        query = record.raw("query") ?? ""
        exception = record.text("exception")
        exceptionCode = record.int("exception_code").flatMap { $0 == 0 ? nil : $0 }
        type = record.raw("type") ?? ""
        queryKind = record.text("query_kind")
    }
}

/// A normalized query pattern from `system.query_log` (grouped by `normalized_query_hash`).
public struct QueryPattern: Sendable, Hashable, Identifiable {
    public var hash: String
    public var sample: String
    public var count: Int64
    public var totalDurationMilliseconds: Int64
    public var averageDurationMilliseconds: Double
    public var maxDurationMilliseconds: Int64
    public var totalReadBytes: Int64
    public var maxMemoryUsage: Int64
    public var failures: Int64
    public var id: String { hash }

    init(record: Record) {
        hash = record.raw("hash") ?? ""
        sample = record.raw("sample") ?? ""
        count = record.int("count") ?? 0
        totalDurationMilliseconds = record.int("total_ms") ?? 0
        averageDurationMilliseconds = record.double("avg_ms") ?? 0
        maxDurationMilliseconds = record.int("max_ms") ?? 0
        totalReadBytes = record.int("read_bytes") ?? 0
        maxMemoryUsage = record.int("max_memory") ?? 0
        failures = record.int("failures") ?? 0
    }
}

/// Per-user totals from `system.query_log`.
public struct UserQueryStats: Sendable, Hashable, Identifiable {
    public var user: String
    public var queries: Int64
    public var failures: Int64
    public var totalDurationMilliseconds: Int64
    public var readBytes: Int64
    public var readRows: Int64
    public var maxMemoryUsage: Int64
    public var id: String { user }

    init(record: Record) {
        user = record.raw("user") ?? ""
        queries = record.int("queries") ?? 0
        failures = record.int("failures") ?? 0
        totalDurationMilliseconds = record.int("total_ms") ?? 0
        readBytes = record.int("read_bytes") ?? 0
        readRows = record.int("read_rows") ?? 0
        maxMemoryUsage = record.int("max_memory") ?? 0
    }
}

/// A disk (`system.disks`).
public struct DiskInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String?
    public var type: String?
    public var freeSpace: Int64
    public var totalSpace: Int64
    public var unreservedSpace: Int64?
    public var keepFreeSpace: Int64?
    public var isReadOnly: Bool?
    public var id: String { name }

    public var usedFraction: Double? {
        guard totalSpace > 0 else { return nil }
        return min(1, max(0, 1 - Double(freeSpace) / Double(totalSpace)))
    }

    init(record: Record) {
        name = record.raw("name") ?? ""
        path = record.text("path")
        type = record.text("type")
        freeSpace = record.int("free_space") ?? 0
        totalSpace = record.int("total_space") ?? 0
        unreservedSpace = record.int("unreserved_space")
        keepFreeSpace = record.int("keep_free_space")
        isReadOnly = record.bool("is_read_only")
    }
}

/// One volume of a storage policy (`system.storage_policies`).
public struct StoragePolicyVolume: Sendable, Hashable, Identifiable {
    public var policy: String
    public var volume: String
    public var priority: Int64
    public var disks: [String]
    public var volumeType: String?
    public var maxDataPartSize: Int64?
    public var moveFactor: Double?
    public var preferNotToMerge: Bool?
    public var id: String { "\(policy).\(volume)" }

    init(record: Record) {
        policy = record.raw("policy_name") ?? ""
        volume = record.raw("volume_name") ?? ""
        priority = record.int("volume_priority") ?? 0
        disks = record.stringArray("disks")
        volumeType = record.text("volume_type")
        maxDataPartSize = record.int("max_data_part_size")
        moveFactor = record.double("move_factor")
        preferNotToMerge = record.bool("prefer_not_to_merge")
    }
}

/// One replica of one shard of a cluster (`system.clusters`).
public struct ClusterReplica: Sendable, Hashable, Identifiable {
    public var cluster: String
    public var shardNumber: Int64
    public var shardWeight: Int64
    public var replicaNumber: Int64
    public var hostName: String
    public var hostAddress: String?
    public var port: Int64
    public var isLocal: Bool
    public var user: String?
    public var errorsCount: Int64
    public var slowdownsCount: Int64?
    public var estimatedRecoveryTime: Int64?
    public var id: String { "\(cluster).\(shardNumber).\(replicaNumber).\(hostName):\(port)" }

    init(record: Record) {
        cluster = record.raw("cluster") ?? ""
        shardNumber = record.int("shard_num") ?? 0
        shardWeight = record.int("shard_weight") ?? 1
        replicaNumber = record.int("replica_num") ?? 0
        hostName = record.raw("host_name") ?? ""
        hostAddress = record.text("host_address")
        port = record.int("port") ?? 0
        isLocal = record.bool("is_local") ?? false
        user = record.text("user")
        errorsCount = record.int("errors_count") ?? 0
        slowdownsCount = record.int("slowdowns_count")
        estimatedRecoveryTime = record.int("estimated_recovery_time")
    }
}

/// Keeper / ZooKeeper connection of the server.
public struct KeeperStatus: Sendable, Hashable {
    public enum State: Sendable, Hashable { case connected, notConfigured, unavailable(String) }
    public var state: State
    public var host: String?
    public var port: Int64?
    public var sessionUptimeSeconds: Int64?
    public var isExpired: Bool?
    public var apiVersion: Int64?

    public init(state: State, host: String? = nil, port: Int64? = nil, sessionUptimeSeconds: Int64? = nil, isExpired: Bool? = nil,
                apiVersion: Int64? = nil) {
        self.state = state
        self.host = host
        self.port = port
        self.sessionUptimeSeconds = sessionUptimeSeconds
        self.isExpired = isExpired
        self.apiVersion = apiVersion
    }
}

/// An `ON CLUSTER` DDL task (`system.distributed_ddl_queue`).
public struct DistributedDDLEntry: Sendable, Hashable, Identifiable {
    public var entry: String
    public var host: String?
    public var status: String?
    public var cluster: String?
    public var query: String
    public var createTime: String?
    public var finishTime: String?
    public var exceptionCode: Int64?
    public var id: String { "\(entry).\(host ?? "")" }

    init(record: Record) {
        entry = record.raw("entry") ?? ""
        host = record.text("host") ?? record.text("host_name")
        status = record.text("status")
        cluster = record.text("cluster")
        query = record.raw("query") ?? ""
        createTime = record.text("query_create_time")
        finishTime = PartitionSummary.meaningfulDate(record.text("query_finish_time"))
        exceptionCode = record.int("exception_code").flatMap { $0 == 0 ? nil : $0 }
    }
}
