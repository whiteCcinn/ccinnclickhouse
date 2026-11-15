import ClickHouseKit
import ClickHouseWire
import Foundation
import Testing
@testable import CcinnClickHouseKit

/// Two replicas of one shard with an embedded Keeper and a chproxy in front (`scripts/ch-cluster-up.sh`).
/// Enable with `CCINNCH_IT_CLUSTER=1` (node1 18111, node2 18112, chproxy 18110).
enum ClusterEnvironment {
    static let enabled = ProcessInfo.processInfo.environment["CCINNCH_IT_CLUSTER"] == "1"
    static let cluster = "ccinn_cluster"
    static let node1 = URL(string: "http://127.0.0.1:18111")!
    static let node2 = URL(string: "http://127.0.0.1:18112")!
    static let proxy = URL(string: "http://127.0.0.1:18110")!

    static func connect(_ url: URL, cluster: String? = ClusterEnvironment.cluster) async throws -> ClickHouseClient {
        try await ClickHouseClient.connect(ITEnvironment.configuration(url: url, cluster: cluster))
    }
}

@Suite("Cluster, Keeper and chproxy", .enabled(if: ClusterEnvironment.enabled), .serialized)
struct ClusterIntegrationTests {
    static let ddl = [
        "CREATE DATABASE IF NOT EXISTS ccinn_it ON CLUSTER ccinn_cluster",
        """
        CREATE TABLE IF NOT EXISTS ccinn_it.events_local ON CLUSTER ccinn_cluster (id UInt64, ts DateTime, v Float64) \
        ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/ccinn_it/events_local', '{replica}') PARTITION BY toYYYYMM(ts) ORDER BY id
        """,
        "CREATE TABLE IF NOT EXISTS ccinn_it.events ON CLUSTER ccinn_cluster AS ccinn_it.events_local ENGINE = Distributed(ccinn_cluster, ccinn_it, events_local, rand())",
    ]

    static func prepare(_ client: ClickHouseClient) async throws {
        for statement in ddl { _ = try await client.run(statement, options: QueryOptions(timeout: 60)) }
        _ = try await client.run("INSERT INTO ccinn_it.events_local SELECT number, toDateTime('2026-01-01 00:00:00') + number * 3600, number / 7 FROM numbers(5000)")
        _ = try await client.run("SYSTEM SYNC REPLICA ON CLUSTER ccinn_cluster ccinn_it.events_local", options: QueryOptions(timeout: 60))
    }

    @Test func topologyKeeperAndReplication() async throws {
        let client = try await ClusterEnvironment.connect(ClusterEnvironment.node1)
        defer { Task { await client.close() } }
        try await Self.prepare(client)
        let replicas = try await client.clusters().filter { $0.cluster == ClusterEnvironment.cluster }
        #expect(replicas.count == 2)
        #expect(replicas.filter(\.isLocal).count == 1)
        #expect(try await client.keeperStatus().state == .connected)
        #expect(try await client.macros().contains { $0.name == "replica" && $0.value == "node1" })
        let tables = try await client.tables(database: "ccinn_it")
        #expect(tables.first { $0.name == "events_local" }?.classification == EngineClassification(engine: "ReplicatedReplacingMergeTree",
                                                                                                    family: .replicatedMergeTree, variant: .replacing,
                                                                                                    isReplicated: true))
        let distributed = try #require(try await client.table(database: "ccinn_it", name: "events"))
        #expect(distributed.family == .distributed)
        #expect(distributed.engineDefinition?.distributedTarget?.table == "events_local")
        _ = try await client.distributionQueue(database: "ccinn_it", table: "events")
        let replica = try #require(try await client.replicas(database: "ccinn_it", table: "events_local").first)
        #expect(replica.totalReplicas == 2)
        #expect(replica.activeReplicas == 2)
        #expect(replica.health == .healthy)
        _ = try await client.replicationQueue()
        #expect(!(try await client.distributedDDLQueue(limit: 50)).isEmpty)
        // The data reached the other replica.
        let node2 = try await ClusterEnvironment.connect(ClusterEnvironment.node2)
        defer { Task { await node2.close() } }
        #expect(try await node2.run("SELECT count() FROM ccinn_it.events_local").scalar == "5000")
        #expect(try await node2.run("SELECT count() FROM ccinn_it.events").scalar == "5000")
    }

    @Test func clusterWideQueriesAndKillOnAnotherNode() async throws {
        let node1 = try await ClusterEnvironment.connect(ClusterEnvironment.node1)
        let node2 = try await ClusterEnvironment.connect(ClusterEnvironment.node2)
        defer { Task { await node1.close(); await node2.close() } }
        let queryID = "ccinnch-sql-it-remote-\(UUID().uuidString.prefix(8))"
        let task = Task {
            try await node2.run("SELECT count() FROM system.numbers_mt WHERE NOT ignore(sipHash64(number))", options: QueryOptions(queryID: queryID, timeout: 90))
        }
        // node1 sees the query on node2 through clusterAllReplicas …
        var remote: RunningQuery?
        _ = try await waitUntil(.seconds(10)) {
            remote = try await node1.runningQueries(cluster: ClusterEnvironment.cluster).first { $0.queryID == queryID }
            return remote != nil
        }
        let query = try #require(remote)
        #expect(query.host == "ccinnch-it-node2")
        // … and kills it there (the plain KILL on node1 finds nothing; ON CLUSTER reaches node2).
        #expect(try await node1.kill(query, cluster: ClusterEnvironment.cluster) != .notFound)
        await #expect(throws: ClickHouseError.self) { _ = try await task.value }
        let gone = try await waitUntil(.seconds(10)) {
            try await node2.execute("SELECT count() FROM system.processes WHERE query_id = \(SQLText.literal(queryID))").scalar == "0"
        }
        #expect(gone)
    }

    @Test func throughChproxy() async throws {
        let client = try await ClusterEnvironment.connect(ClusterEnvironment.proxy)
        defer { Task { await client.close() } }
        #expect(!client.capabilities.settingsLocked)
        // chproxy balances requests over both replicas.
        for _ in 0..<4 { _ = try await client.run("SELECT 1", options: QueryOptions(idempotent: true)) }
        #expect(client.isLoadBalanced)
        #expect(client.nodesSeen.isSuperset(of: ["ccinnch-it-node1", "ccinnch-it-node2"]))
        // Sessions stick to one node, so USE and SET survive.
        let session = client.openSession()
        _ = try await session.run("USE ccinn_it")
        _ = try await session.run("SET max_threads = 3")
        for _ in 0..<3 {
            #expect(try await session.run("SELECT currentDatabase(), getSetting('max_threads')").rows == [["ccinn_it", "3"]])
        }
        // chproxy replaces query ids and does not stop upstream queries when the client goes away; cancel
        // still stops the query because it is also tagged with a log_comment marker.
        let queryID = "ccinnch-sql-it-proxy-\(UUID().uuidString.prefix(8))"
        let marker = RequestBuilder.marker(application: "CcinnClickHouse", queryID: queryID)
        let task = Task {
            try await client.run("SELECT count() FROM system.numbers_mt WHERE NOT ignore(sipHash64(number))", options: QueryOptions(queryID: queryID, timeout: 90))
        }
        let node1 = try await ClusterEnvironment.connect(ClusterEnvironment.node1)
        defer { Task { await node1.close() } }
        let started = try await waitUntil(.seconds(10)) {
            try await node1.run("SELECT count() FROM clusterAllReplicas('ccinn_cluster', system.processes) WHERE Settings['log_comment'] = \(SQLText.literal(marker))").scalar == "1"
        }
        #expect(started)
        task.cancel()
        _ = try? await task.value
        let gone = try await waitUntil(.seconds(15)) {
            try await node1.run("SELECT count() FROM clusterAllReplicas('ccinn_cluster', system.processes) WHERE Settings['log_comment'] = \(SQLText.literal(marker))").scalar == "0"
        }
        #expect(gone)
        // Metadata through the proxy.
        #expect(try await client.tables(database: "ccinn_it").count >= 2)
    }

    @Test func mcpGetClusterAndReplicationThroughTheProxy() async throws {
        // Read-only AI access through chproxy needs a ClickHouse user that is read-only itself (chproxy
        // drops the readonly parameter); `reader` is mapped to such a user.
        let profile = ConnectionProfile(name: "Proxy", host: "127.0.0.1", port: 18110, username: "reader",
                                        defaultCluster: ClusterEnvironment.cluster, mcpAccess: .readOnly)
        let tools = ClickHouseMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                                       registry: MCPClientRegistry { profile, access in
                                           try await ClientOpener.open(profile: profile, password: "reader-pass", sshSecret: nil,
                                                                       readOnlyOverride: access != .readWrite)
                                       }, audit: nil)
        let cluster = await tools.call(name: "get_cluster", arguments: [:])
        #expect(!cluster.isError)
        #expect(cluster.payload["keeper"]?["state"] == .string("connected"))
        let replication = await tools.call(name: "get_replication", arguments: ["database": "ccinn_it", "table": "events_local"])
        #expect(!replication.isError)
        #expect(replication.payload["replicas"]?[0]?["health"] == .string("healthy"))
        let running = await tools.call(name: "get_running_queries", arguments: [:])
        #expect(running.payload["cluster"] == .string(ClusterEnvironment.cluster))
    }
}
