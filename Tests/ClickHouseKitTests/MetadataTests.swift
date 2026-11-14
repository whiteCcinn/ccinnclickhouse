import ClickHouseWire
import Foundation
import Testing
@testable import ClickHouseKit

@Suite("Metadata parsing and classification")
struct MetadataTests {
    @Test func engineFamilies() {
        let replicated = EngineClassification.classify(engine: "ReplicatedReplacingMergeTree")
        #expect(replicated.family == .replicatedMergeTree)
        #expect(replicated.variant == .replacing)
        #expect(replicated.isReplicated)
        #expect(replicated.badge == "Replacing")
        #expect(EngineClassification.classify(engine: "MergeTree").badge == nil)
        #expect(EngineClassification.classify(engine: "SharedAggregatingMergeTree").family == .sharedMergeTree)
        #expect(EngineClassification.classify(engine: "VersionedCollapsingMergeTree").variant == .versionedCollapsing)
        #expect(EngineClassification.classify(engine: "CoalescingMergeTree").variant == .coalescing)
        #expect(EngineClassification.classify(engine: "Distributed").family == .distributed)
        #expect(EngineClassification.classify(engine: "MaterializedView").family == .materializedView)
        #expect(EngineClassification.classify(engine: "View").family == .view)
        #expect(EngineClassification.classify(engine: "Dictionary").family == .dictionary)
        #expect(EngineClassification.classify(engine: "Kafka").family == .streaming)
        #expect(EngineClassification.classify(engine: "S3Queue").family == .streaming)
        #expect(EngineClassification.classify(engine: "PostgreSQL").family == .integration)
        #expect(EngineClassification.classify(engine: "Iceberg").family == .dataLake)
        #expect(EngineClassification.classify(engine: "TinyLog").family == .log)
        #expect(EngineClassification.classify(engine: "Buffer").family == .memory)
        #expect(EngineClassification.classify(engine: "SystemNumbers", database: "system").family == .system)
        #expect(EngineClassification.classify(engine: "FutureEngine2030").family == .other)
        #expect(EngineFamily.mergeTree < EngineFamily.distributed)
        #expect(EngineFamily.replicatedMergeTree.hasParts)
        #expect(!EngineFamily.distributed.hasParts)
    }

    @Test func databaseEngines() {
        #expect(DatabaseEngineKind(engine: "Atomic") == .atomic)
        #expect(DatabaseEngineKind(engine: "Atomic").badge == nil)
        #expect(DatabaseEngineKind(engine: "Replicated").badge == "Replicated")
        #expect(DatabaseEngineKind(engine: "MaterializedPostgreSQL").isExternal)
        #expect(DatabaseEngineKind(engine: "Whatever") == .other)
    }

    @Test func engineDefinitionParsing() {
        let text = "ReplicatedMergeTree('/clickhouse/tables/{shard}/shop/events', '{replica}') PARTITION BY toYYYYMM(d) PRIMARY KEY k ORDER BY (k, d) "
            + "SAMPLE BY k TTL d + toIntervalYear(1), d + toIntervalMonth(1) TO VOLUME 'cold' SETTINGS index_granularity = 8192, parts_to_delay_insert = 50, storage_policy = 'tiered'"
        let definition = EngineDefinition.parse(text)
        #expect(definition.engine == "ReplicatedMergeTree")
        #expect(definition.arguments == ["'/clickhouse/tables/{shard}/shop/events'", "'{replica}'"])
        #expect(definition.partitionBy == "toYYYYMM(d)")
        #expect(definition.primaryKey == "k")
        #expect(definition.orderBy == "(k, d)")
        #expect(definition.sampleBy == "k")
        #expect(definition.ttl == "d + toIntervalYear(1), d + toIntervalMonth(1) TO VOLUME 'cold'")
        #expect(definition.setting("index_granularity") == "8192")
        #expect(definition.setting("storage_policy") == "tiered")
        #expect(definition.replicationPath?.path == "/clickhouse/tables/{shard}/shop/events")
        #expect(definition.replicationPath?.replica == "{replica}")
        let limits = MergeTreeLimits(partsToDelayInsert: 1_000, partsToThrowInsert: 3_000).overridden(by: definition)
        #expect(limits.partsToDelayInsert == 50)
        #expect(limits.partsToThrowInsert == 3_000)
    }

    @Test func distributedArguments() throws {
        let definition = EngineDefinition.parse("Distributed('demo_cluster', 'shop', 'events_local', cityHash64(user_id))")
        let target = try #require(definition.distributedTarget)
        #expect(target.cluster == "demo_cluster")
        #expect(target.database == "shop")
        #expect(target.table == "events_local")
        #expect(target.shardingKey == "cityHash64(user_id)")
        #expect(EngineDefinition.parse("Distributed(c, db, t)").distributedTarget?.table == "t")
        #expect(EngineDefinition.parse("MergeTree").distributedTarget == nil)
    }

    @Test func keywordsInsideStringsAndIdentifiersAreIgnored() {
        let definition = EngineDefinition.parse("MergeTree ORDER BY (ttl, `ORDER BY`) SETTINGS storage_policy = 'TTL policy'")
        #expect(definition.orderBy == "(ttl, `ORDER BY`)")
        #expect(definition.ttl == nil)
        #expect(definition.setting("storage_policy") == "TTL policy")
    }

    @Test func createStatementDetails() {
        let statement = """
            CREATE TABLE shop.events (`d` Date, `k` UInt64, `ttl` String TTL d + toIntervalDay(30), `payload` String CODEC(ZSTD(3)) TTL d + toIntervalDay(7) COMMENT 'x', \
            INDEX idx k TYPE minmax GRANULARITY 1, PROJECTION by_k (SELECT k, count() GROUP BY k)) ENGINE = MergeTree ORDER BY k
            """
        let details = CreateStatementDetails.parse(statement)
        #expect(details.columnTTLs == ["ttl": "d + toIntervalDay(30)", "payload": "d + toIntervalDay(7)"])
        #expect(details.projections.map(\.name) == ["by_k"])
        #expect(details.projections.first?.definition == "(SELECT k, count() GROUP BY k)")
        let view = CreateStatementDetails.parse("CREATE MATERIALIZED VIEW shop.mv TO shop.daily (`d` Date) AS SELECT d FROM shop.events")
        #expect(view.materializedViewTarget == "shop.daily")
        #expect(CreateStatementDetails.parse("CREATE MATERIALIZED VIEW shop.mv (`d` Date) ENGINE = MergeTree ORDER BY d AS SELECT d FROM t").materializedViewTarget == nil)
    }

    @Test func ddlParsingNeverTraps() {
        var generator = SplitMix64(seed: 7)
        let alphabet = Array("()'`\" ,=ORDER BY TTL SETTINGS PARTITION\\abc".unicodeScalars)
        for _ in 0..<3_000 {
            var text = ""
            for _ in 0..<Int(generator.next() % 80) { text.unicodeScalars.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
            _ = EngineDefinition.parse(text)
            _ = CreateStatementDetails.parse("CREATE TABLE t (" + text)
            _ = CreateStatementDetails.parse("CREATE MATERIALIZED VIEW " + text)
        }
    }

    @Test func partHealthLevels() {
        let limits = MergeTreeLimits(partsToDelayInsert: 100, partsToThrowInsert: 300, maxPartsInTotal: 10_000)
        #expect(PartHealth.level(activeParts: 10, limits: limits) == .ok)
        #expect(PartHealth.level(activeParts: 50, limits: limits) == .warning)
        #expect(PartHealth.level(activeParts: 150, limits: limits) == .critical)
        #expect(PartHealth.level(activeParts: 300, limits: limits) == .failing)
        let partitions = [PartitionSummary(partition: "202401", partitionID: "202401", activeParts: 160, rows: 10, bytesOnDisk: 1_000),
                          PartitionSummary(partition: "202402", partitionID: "202402", activeParts: 3, rows: 10, bytesOnDisk: 1_000)]
        let warnings = PartHealth.warnings(partitions: partitions, limits: limits)
        #expect(warnings.first?.level == .critical)
        #expect(warnings.first?.message.contains("partition 202401") == true)
        #expect(warnings.contains { $0.message.contains("small parts") })
        #expect(PartHealth.warnings(partitions: [], limits: limits).isEmpty)
    }

    @Test func recordsSaturateAndParseArrays() {
        let record = Record(values: ["18446744073709551615", "-170141183460469231731687303715884105728", "1.5e9", "['a','b\\'c','']", "[1, 2]", "x"],
                            lookup: ColumnLookup(names: ["u64", "i128", "f", "arr", "nums", "bad"]))
        #expect(record.int("u64") == .max)
        #expect(record.int("i128") == .min)
        #expect(record.int("f") == 1_500_000_000)
        #expect(record.stringArray("arr") == ["a", "b'c", ""])
        #expect(record.stringArray("nums") == ["1", "2"])
        #expect(record.int("bad") == nil)
        #expect(record.stringArray("bad").isEmpty)
        #expect(record.int("missing") == nil)
    }

    @Test func versions() {
        #expect(ClickHouseVersion("24.8.14.39")?.isAtLeast(24, 3) == true)
        #expect(ClickHouseVersion("v23.3.1.2823-lts")?.major == 23)
        #expect(ClickHouseVersion("22.8") != nil)
        #expect(ClickHouseVersion("garbage") == nil)
        #expect(ClickHouseVersion("99999999999999.1") != nil)
        #expect(ClickHouseVersion("22.8.21.38")! < ClickHouseVersion("24.8.14.39")!)
    }
}

/// Deterministic PRNG for fuzz tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
