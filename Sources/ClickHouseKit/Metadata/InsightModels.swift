import Foundation

/// Active parts of one partition (`system.parts` grouped by partition).
public struct PartitionSummary: Sendable, Hashable, Identifiable {
    public var partition: String
    public var partitionID: String
    public var activeParts: Int64
    public var inactiveParts: Int64
    public var rows: Int64
    public var bytesOnDisk: Int64
    public var compressedBytes: Int64
    public var uncompressedBytes: Int64
    public var minDate: String?
    public var maxDate: String?
    public var minTime: String?
    public var maxTime: String?
    public var lastModified: String?
    public var maxLevel: Int64?

    public var id: String { partitionID }

    /// Tables without PARTITION BY have one partition named `tuple()` (id `all`).
    public var isUnpartitioned: Bool { partition.isEmpty || partition == "tuple()" || partitionID == "all" }

    public var compressionRatio: Double? {
        guard compressedBytes > 0, uncompressedBytes > 0 else { return nil }
        return Double(uncompressedBytes) / Double(compressedBytes)
    }

    init(record: Record) {
        partition = record.raw("partition") ?? ""
        partitionID = record.raw("partition_id") ?? partition
        activeParts = record.int("active_parts") ?? 0
        inactiveParts = record.int("inactive_parts") ?? 0
        rows = record.int("rows") ?? 0
        bytesOnDisk = record.int("bytes_on_disk") ?? 0
        compressedBytes = record.int("data_compressed_bytes") ?? 0
        uncompressedBytes = record.int("data_uncompressed_bytes") ?? 0
        minDate = Self.meaningfulDate(record.text("min_date"))
        maxDate = Self.meaningfulDate(record.text("max_date"))
        minTime = Self.meaningfulDate(record.text("min_time"))
        maxTime = Self.meaningfulDate(record.text("max_time"))
        lastModified = record.text("last_modified")
        maxLevel = record.int("max_level")
    }

    public init(partition: String, partitionID: String, activeParts: Int64, rows: Int64 = 0, bytesOnDisk: Int64 = 0) {
        self.partition = partition
        self.partitionID = partitionID
        self.activeParts = activeParts
        inactiveParts = 0
        self.rows = rows
        self.bytesOnDisk = bytesOnDisk
        compressedBytes = 0
        uncompressedBytes = 0
    }

    /// `1970-01-01` / `1970-01-01 00:00:00` mean "no date column in the partition key".
    static func meaningfulDate(_ text: String?) -> String? {
        guard let text, !text.hasPrefix("1970-01-01"), !text.hasPrefix("1900-01-01") else { return nil }
        return text
    }
}

/// One data part (`system.parts`).
public struct PartInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var partition: String
    public var partitionID: String
    public var partType: String?
    public var isActive: Bool
    public var rows: Int64
    public var bytesOnDisk: Int64
    public var compressedBytes: Int64
    public var uncompressedBytes: Int64
    public var marks: Int64
    public var modificationTime: String?
    public var level: Int64
    public var minBlock: Int64?
    public var maxBlock: Int64?
    public var dataVersion: Int64?
    public var disk: String?
    public var minDate: String?
    public var maxDate: String?
    public var minTime: String?
    public var maxTime: String?
    public var deleteTTLMin: String?
    public var deleteTTLMax: String?
    public var projections: [String]

    public var id: String { name }

    public var compressionRatio: Double? {
        guard compressedBytes > 0, uncompressedBytes > 0 else { return nil }
        return Double(uncompressedBytes) / Double(compressedBytes)
    }

    init(record: Record) {
        name = record.raw("name") ?? ""
        partition = record.raw("partition") ?? ""
        partitionID = record.raw("partition_id") ?? ""
        partType = record.text("part_type")
        isActive = record.bool("active") ?? true
        rows = record.int("rows") ?? 0
        bytesOnDisk = record.int("bytes_on_disk") ?? 0
        compressedBytes = record.int("data_compressed_bytes") ?? 0
        uncompressedBytes = record.int("data_uncompressed_bytes") ?? 0
        marks = record.int("marks") ?? 0
        modificationTime = record.text("modification_time")
        level = record.int("level") ?? 0
        minBlock = record.int("min_block_number")
        maxBlock = record.int("max_block_number")
        dataVersion = record.int("data_version")
        disk = record.text("disk_name")
        minDate = PartitionSummary.meaningfulDate(record.text("min_date"))
        maxDate = PartitionSummary.meaningfulDate(record.text("max_date"))
        minTime = PartitionSummary.meaningfulDate(record.text("min_time"))
        maxTime = PartitionSummary.meaningfulDate(record.text("max_time"))
        deleteTTLMin = PartitionSummary.meaningfulDate(record.text("delete_ttl_info_min"))
        deleteTTLMax = PartitionSummary.meaningfulDate(record.text("delete_ttl_info_max"))
        projections = record.stringArray("projections")
    }
}

/// A data-skipping index (`system.data_skipping_indices`).
public struct SkippingIndex: Sendable, Hashable, Identifiable {
    public var name: String
    public var type: String
    public var typeFull: String?
    public var expression: String
    public var granularity: Int64
    public var compressedBytes: Int64?
    public var uncompressedBytes: Int64?
    public var marks: Int64?
    public var id: String { name }

    init(record: Record) {
        name = record.raw("name") ?? ""
        type = record.text("type") ?? ""
        typeFull = record.text("type_full")
        expression = record.text("expr") ?? ""
        granularity = record.int("granularity") ?? 0
        compressedBytes = record.int("data_compressed_bytes")
        uncompressedBytes = record.int("data_uncompressed_bytes")
        marks = record.int("marks")
    }
}

/// A projection with its storage (`system.projections` / CREATE statement + `system.projection_parts`).
public struct ProjectionInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var type: String?
    public var sortingKey: String?
    public var definition: String?
    public var parts: Int64?
    public var rows: Int64?
    public var bytesOnDisk: Int64?
    public var id: String { name }

    public init(name: String, type: String? = nil, sortingKey: String? = nil, definition: String? = nil) {
        self.name = name
        self.type = type
        self.sortingKey = sortingKey
        self.definition = definition
    }
}

/// Health of one replicated table (`system.replicas`, Keeper-free columns only).
public struct ReplicaStatus: Sendable, Hashable, Identifiable {
    public enum Health: Sendable, Hashable { case healthy, lagging, readonly, sessionExpired }

    public var database: String
    public var table: String
    public var engine: String?
    public var isLeader: Bool
    public var isReadonly: Bool
    public var isSessionExpired: Bool
    public var futureParts: Int64
    public var partsToCheck: Int64
    public var zookeeperPath: String?
    public var replicaName: String?
    public var queueSize: Int64
    public var insertsInQueue: Int64
    public var mergesInQueue: Int64
    public var mutationsInQueue: Int64
    public var queueOldestTime: String?
    public var absoluteDelay: Int64
    public var lastQueueUpdate: String?
    public var lastQueueUpdateException: String?
    public var zookeeperException: String?
    public var lostPartCount: Int64?
    public var totalReplicas: Int64?
    public var activeReplicas: Int64?

    public var id: String { "\(database).\(table)" }

    /// Delay above this many seconds counts as lagging.
    public static let lagThresholdSeconds: Int64 = 300

    public var health: Health {
        if isSessionExpired { return .sessionExpired }
        if isReadonly { return .readonly }
        if absoluteDelay > Self.lagThresholdSeconds || queueSize > 500 { return .lagging }
        return .healthy
    }

    init(record: Record) {
        database = record.raw("database") ?? ""
        table = record.raw("table") ?? ""
        engine = record.text("engine")
        isLeader = record.bool("is_leader") ?? false
        isReadonly = record.bool("is_readonly") ?? false
        isSessionExpired = record.bool("is_session_expired") ?? false
        futureParts = record.int("future_parts") ?? 0
        partsToCheck = record.int("parts_to_check") ?? 0
        zookeeperPath = record.text("zookeeper_path")
        replicaName = record.text("replica_name")
        queueSize = record.int("queue_size") ?? 0
        insertsInQueue = record.int("inserts_in_queue") ?? 0
        mergesInQueue = record.int("merges_in_queue") ?? 0
        mutationsInQueue = record.int("part_mutations_in_queue") ?? 0
        queueOldestTime = PartitionSummary.meaningfulDate(record.text("queue_oldest_time"))
        absoluteDelay = record.int("absolute_delay") ?? 0
        lastQueueUpdate = PartitionSummary.meaningfulDate(record.text("last_queue_update"))
        lastQueueUpdateException = record.text("last_queue_update_exception")
        zookeeperException = record.text("zookeeper_exception")
        lostPartCount = record.int("lost_part_count")
        totalReplicas = record.int("total_replicas")
        activeReplicas = record.int("active_replicas")
    }
}

/// One replication queue entry (`system.replication_queue`).
public struct ReplicationQueueEntry: Sendable, Hashable, Identifiable {
    public var database: String
    public var table: String
    public var replicaName: String?
    public var position: Int64
    public var nodeName: String
    public var type: String
    public var createTime: String?
    public var sourceReplica: String?
    public var newPartName: String?
    public var partsToMerge: [String]
    public var isCurrentlyExecuting: Bool
    public var numTries: Int64
    public var lastException: String?
    public var lastAttemptTime: String?
    public var numPostponed: Int64
    public var postponeReason: String?

    public var id: String { "\(database).\(table).\(nodeName)" }

    init(record: Record) {
        database = record.raw("database") ?? ""
        table = record.raw("table") ?? ""
        replicaName = record.text("replica_name")
        position = record.int("position") ?? 0
        nodeName = record.raw("node_name") ?? ""
        type = record.text("type") ?? ""
        createTime = record.text("create_time")
        sourceReplica = record.text("source_replica")
        newPartName = record.text("new_part_name")
        partsToMerge = record.stringArray("parts_to_merge")
        isCurrentlyExecuting = record.bool("is_currently_executing") ?? false
        numTries = record.int("num_tries") ?? 0
        lastException = record.text("last_exception")
        lastAttemptTime = PartitionSummary.meaningfulDate(record.text("last_attempt_time"))
        numPostponed = record.int("num_postponed") ?? 0
        postponeReason = record.text("postpone_reason")
    }
}

/// A running merge (`system.merges`).
public struct MergeInfo: Sendable, Hashable, Identifiable {
    public var host: String?
    public var database: String
    public var table: String
    public var elapsed: Double
    public var progress: Double
    public var numParts: Int64
    public var resultPartName: String
    public var partitionID: String?
    public var isMutation: Bool
    public var totalSizeCompressed: Int64
    public var bytesReadUncompressed: Int64
    public var rowsRead: Int64
    public var rowsWritten: Int64
    public var memoryUsage: Int64
    public var mergeType: String?
    public var mergeAlgorithm: String?

    public var id: String { "\(host ?? "").\(database).\(table).\(resultPartName)" }

    init(record: Record) {
        host = record.text("host")
        database = record.raw("database") ?? ""
        table = record.raw("table") ?? ""
        elapsed = record.double("elapsed") ?? 0
        progress = min(1, max(0, record.double("progress") ?? 0))
        numParts = record.int("num_parts") ?? 0
        resultPartName = record.raw("result_part_name") ?? ""
        partitionID = record.text("partition_id")
        isMutation = record.bool("is_mutation") ?? false
        totalSizeCompressed = record.int("total_size_bytes_compressed") ?? 0
        bytesReadUncompressed = record.int("bytes_read_uncompressed") ?? 0
        rowsRead = record.int("rows_read") ?? 0
        rowsWritten = record.int("rows_written") ?? 0
        memoryUsage = record.int("memory_usage") ?? 0
        mergeType = record.text("merge_type")
        mergeAlgorithm = record.text("merge_algorithm")
    }
}

/// A mutation (`system.mutations`).
public struct MutationInfo: Sendable, Hashable, Identifiable {
    public var database: String
    public var table: String
    public var mutationID: String
    public var command: String
    public var createTime: String?
    public var partsToDo: Int64
    public var isDone: Bool
    public var isKilled: Bool
    public var latestFailedPart: String?
    public var latestFailTime: String?
    public var latestFailReason: String?

    public var id: String { "\(database).\(table).\(mutationID)" }
    public var isStuck: Bool { !isDone && latestFailReason != nil }

    init(record: Record) {
        database = record.raw("database") ?? ""
        table = record.raw("table") ?? ""
        mutationID = record.raw("mutation_id") ?? ""
        command = record.text("command") ?? ""
        createTime = record.text("create_time")
        partsToDo = record.int("parts_to_do") ?? 0
        isDone = record.bool("is_done") ?? false
        isKilled = record.bool("is_killed") ?? false
        latestFailedPart = record.text("latest_failed_part")
        latestFailTime = PartitionSummary.meaningfulDate(record.text("latest_fail_time"))
        latestFailReason = record.text("latest_fail_reason")
    }
}

/// Pending asynchronous inserts of a Distributed table (`system.distribution_queue`).
public struct DistributionQueueEntry: Sendable, Hashable, Identifiable {
    public var database: String
    public var table: String
    public var dataPath: String
    public var isBlocked: Bool
    public var errorCount: Int64
    public var dataFiles: Int64
    public var dataCompressedBytes: Int64
    public var lastException: String?
    public var id: String { dataPath }

    init(record: Record) {
        database = record.raw("database") ?? ""
        table = record.raw("table") ?? ""
        dataPath = record.raw("data_path") ?? ""
        isBlocked = record.bool("is_blocked") ?? false
        errorCount = record.int("error_count") ?? 0
        dataFiles = record.int("data_files") ?? 0
        dataCompressedBytes = record.int("data_compressed_bytes") ?? 0
        lastException = record.text("last_exception")
    }
}

/// An external dictionary (`system.dictionaries`).
public struct DictionaryInfo: Sendable, Hashable, Identifiable {
    public var database: String
    public var name: String
    public var status: String
    public var origin: String?
    public var type: String?
    public var keyNames: [String]
    public var attributeNames: [String]
    public var bytesAllocated: Int64
    public var queryCount: Int64
    public var hitRate: Double?
    public var foundRate: Double?
    public var elementCount: Int64
    public var loadFactor: Double?
    public var source: String?
    public var lifetimeMin: Int64?
    public var lifetimeMax: Int64?
    public var lastSuccessfulUpdateTime: String?
    public var loadingDuration: Double?
    public var lastException: String?
    public var comment: String?

    public var id: String { "\(database).\(name)" }
    public var qualifiedName: String { database.isEmpty ? name : "\(database).\(name)" }
    public var isFailed: Bool { status.uppercased().contains("FAILED") }

    init(record: Record) {
        database = record.raw("database") ?? ""
        name = record.raw("name") ?? ""
        status = record.text("status") ?? ""
        origin = record.text("origin")
        type = record.text("type")
        keyNames = record.stringArray("key.names")
        attributeNames = record.stringArray("attribute.names")
        bytesAllocated = record.int("bytes_allocated") ?? 0
        queryCount = record.int("query_count") ?? 0
        hitRate = record.double("hit_rate")
        foundRate = record.double("found_rate")
        elementCount = record.int("element_count") ?? 0
        loadFactor = record.double("load_factor")
        source = record.text("source")
        lifetimeMin = record.int("lifetime_min")
        lifetimeMax = record.int("lifetime_max")
        lastSuccessfulUpdateTime = PartitionSummary.meaningfulDate(record.text("last_successful_update_time"))
        loadingDuration = record.double("loading_duration")
        lastException = record.text("last_exception")
        comment = record.text("comment")
    }
}

/// Insert-blocking thresholds of a MergeTree table (server defaults overridden by table SETTINGS).
public struct MergeTreeLimits: Sendable, Hashable {
    public var partsToDelayInsert: Int64
    public var partsToThrowInsert: Int64
    public var maxPartsInTotal: Int64

    public init(partsToDelayInsert: Int64 = 1_000, partsToThrowInsert: Int64 = 3_000, maxPartsInTotal: Int64 = 100_000) {
        self.partsToDelayInsert = max(1, partsToDelayInsert)
        self.partsToThrowInsert = max(1, partsToThrowInsert)
        self.maxPartsInTotal = max(1, maxPartsInTotal)
    }

    /// Applies `SETTINGS parts_to_delay_insert = …` from the table's engine definition.
    public func overridden(by definition: EngineDefinition?) -> MergeTreeLimits {
        var copy = self
        if let value = definition?.setting("parts_to_delay_insert").flatMap({ Int64($0) }), value > 0 { copy.partsToDelayInsert = value }
        if let value = definition?.setting("parts_to_throw_insert").flatMap({ Int64($0) }), value > 0 { copy.partsToThrowInsert = value }
        if let value = definition?.setting("max_parts_in_total").flatMap({ Int64($0) }), value > 0 { copy.maxPartsInTotal = value }
        return copy
    }
}
