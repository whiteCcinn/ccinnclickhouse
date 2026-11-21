import CcinnClickHouseKit
import ClickHouseKit
import Foundation
import Observation

/// Server operations: running queries, merges, mutations, replication, query log, storage,
/// dictionaries and cluster topology. Refreshes the visible section periodically while auto-refresh
/// is on; a refresh never interrupts a slower one started by the timer, and results of superseded
/// refreshes are discarded (generation token).
@MainActor
@Observable
final class OperationsModel {
    enum Section: String, CaseIterable, Identifiable {
        case running = "Running Queries"
        case merges = "Merges"
        case mutations = "Mutations"
        case replication = "Replication"
        case queryLog = "Query Log"
        case storage = "Storage"
        case dictionaries = "Dictionaries"
        case cluster = "Cluster"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .running: "bolt.horizontal.circle"
            case .merges: "arrow.triangle.merge"
            case .mutations: "wand.and.stars"
            case .replication: "arrow.triangle.2.circlepath"
            case .queryLog: "list.bullet.rectangle"
            case .storage: "internaldrive"
            case .dictionaries: "book.closed"
            case .cluster: "server.rack"
            }
        }

        /// Sections worth refreshing every few seconds.
        var isLive: Bool { self == .running || self == .merges || self == .mutations || self == .replication }
    }

    enum LogAnalysis: String, CaseIterable, Identifiable {
        case slowest = "Slowest"
        case memory = "Memory"
        case failed = "Failed"
        case patterns = "Patterns"
        case users = "By User"
        var id: String { rawValue }
    }

    struct ClusterSnapshot {
        var replicas: [ClusterReplica]
        var keeper: KeeperStatus
        var macros: [(name: String, value: String)]
        var ddl: [DistributedDDLEntry]
        /// The user may not read `system.distributed_ddl_queue`; the rest of the snapshot still shows.
        var ddlDenied = false
    }

    unowned let workspace: WorkspaceModel
    var section: Section { didSet { if section != oldValue { refresh() } } }
    var autoRefresh = true { didSet { autoRefresh ? startAutoRefresh() : stopAutoRefresh() } }
    var clusterWide: Bool { didSet { if clusterWide != oldValue { refresh() } } }
    var logAnalysis: LogAnalysis = .slowest { didSet { if logAnalysis != oldValue { refresh() } } }
    var logHours: Double = 1 { didSet { if logHours != oldValue { refresh() } } }
    var showFinishedMutations = false { didSet { if showFinishedMutations != oldValue { refresh() } } }
    var lastRefreshed: Date?

    var queries: Loadable<[RunningQuery]> = .idle
    var merges: Loadable<[MergeInfo]> = .idle
    var mutations: Loadable<[MutationInfo]> = .idle
    var replicas: Loadable<[ReplicaStatus]> = .idle
    var queue: Loadable<[ReplicationQueueEntry]> = .idle
    var logEntries: Loadable<[QueryLogEntry]?> = .idle
    var patterns: Loadable<[QueryPattern]?> = .idle
    var users: Loadable<[UserQueryStats]?> = .idle
    var disks: Loadable<[DiskInfo]> = .idle
    var policies: Loadable<[StoragePolicyVolume]> = .idle
    var dictionaries: Loadable<[DictionaryInfo]> = .idle
    var cluster: Loadable<ClusterSnapshot> = .idle
    var pendingAction: PendingAction?

    struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let run: @MainActor () async throws -> String
    }

    private var refreshTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var isRefreshing = false

    init(workspace: WorkspaceModel, section: Section) {
        self.workspace = workspace
        self.section = section
        clusterWide = workspace.cluster != nil
        refresh()
        startAutoRefresh()
    }

    var client: ClickHouseClient { workspace.client }
    var clusterScope: String? { clusterWide ? workspace.cluster : nil }

    // MARK: Refresh

    /// `fromTimer` refreshes are skipped while one is still running, so slow servers are never
    /// interrupted half-way (which would leave the view loading forever).
    func refresh(fromTimer: Bool = false) {
        if fromTimer, isRefreshing { return }
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let section = section
        let clusterName = clusterScope
        isRefreshing = true
        refreshTask = Task {
            defer { if refreshGeneration == generation { isRefreshing = false } }
            let client = client
            switch section {
            case .running:
                await load(generation, { self.queries = $0 }, keep: queries.value) { try await client.runningQueries(cluster: clusterName) }
            case .merges:
                await load(generation, { self.merges = $0 }, keep: merges.value) { try await client.merges(cluster: clusterName) }
            case .mutations:
                let finished = showFinishedMutations
                await load(generation, { self.mutations = $0 }, keep: mutations.value) { try await client.mutations(activeOnly: !finished, limit: 500) }
            case .replication:
                await load(generation, { self.replicas = $0 }, keep: replicas.value) { try await client.replicas() }
                await load(generation, { self.queue = $0 }, keep: queue.value) { try await client.replicationQueue(limit: 500) }
            case .queryLog:
                let hours = logHours
                switch logAnalysis {
                case .slowest, .memory, .failed:
                    let kind: ClickHouseClient.QueryLogAnalysis = logAnalysis == .memory ? .memory : logAnalysis == .failed ? .failed : .slowest
                    await load(generation, { self.logEntries = $0 }, keep: nil) { try await client.queryLog(kind, hours: hours, limit: 300) }
                case .patterns:
                    await load(generation, { self.patterns = $0 }, keep: nil) { try await client.queryPatterns(hours: hours, limit: 100) }
                case .users:
                    await load(generation, { self.users = $0 }, keep: nil) { try await client.queryLogByUser(hours: hours) }
                }
            case .storage:
                await load(generation, { self.disks = $0 }, keep: disks.value) { try await client.disks() }
                await load(generation, { self.policies = $0 }, keep: policies.value) { try await client.storagePolicies() }
            case .dictionaries:
                await load(generation, { self.dictionaries = $0 }, keep: dictionaries.value) { try await client.dictionaries() }
            case .cluster:
                await load(generation, { self.cluster = $0 }, keep: self.cluster.value) {
                    async let replicas = client.clusters()
                    async let keeper = client.keeperStatus()
                    async let macros = client.macros()
                    async let ddl = client.distributedDDLQueue(limit: 100)
                    var snapshot = ClusterSnapshot(replicas: try await replicas, keeper: try await keeper, macros: try await macros, ddl: [])
                    do {
                        snapshot.ddl = try await ddl
                    } catch let error as ClickHouseError where error.isAccessDenied {
                        snapshot.ddlDenied = true
                    }
                    return snapshot
                }
            }
            if !Task.isCancelled, refreshGeneration == generation { lastRefreshed = Date() }
        }
    }

    /// Shows a spinner only on the first load; later refreshes swap data in place. Results of a
    /// superseded refresh are dropped.
    private func load<Value>(_ generation: UInt64, _ assign: (Loadable<Value>) -> Void, keep current: Value?,
                             _ body: () async throws -> Value) async {
        if current == nil { assign(.loading) }
        do {
            let value = try await body()
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            assign(.loaded(value))
        } catch {
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            assign(.failed(describe(error)))
        }
    }

    func startAutoRefresh() {
        guard autoRefresh, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.autoRefresh else { return }
                if self.section.isLive { self.refresh(fromTimer: true) }
            }
        }
    }

    func stopAutoRefresh() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Stops everything when the tab closes.
    func close() {
        stopAutoRefresh()
        refreshTask?.cancel()
    }

    // MARK: Actions

    func confirmKill(_ query: RunningQuery) {
        let cluster = clusterScope ?? workspace.cluster
        pendingAction = PendingAction(
            title: "Kill query \(query.queryID.prefix(36))\(query.host.map { " on \($0)" } ?? "")?",
            message: String(query.query.prefix(300)), confirmLabel: "Kill Query") { [client] in
                switch try await client.kill(query, cluster: cluster) {
                case let .killed(status): return "Kill sent (\(status ?? "ok"))"
                case .notFound:
                    if let host = query.host, host != client.serverInfo.hostName {
                        throw ClickHouseError(.server, "The query runs on \(host), which this endpoint could not reach. Set the connection's cluster so kills are sent ON CLUSTER, or connect to \(host) directly.")
                    }
                    return "The query had already finished"
                }
            }
    }

    func confirmKill(_ mutation: MutationInfo) {
        pendingAction = PendingAction(title: "Kill mutation \(mutation.mutationID) on \(mutation.database).\(mutation.table)?",
                                      message: String(mutation.command.prefix(300)), confirmLabel: "Kill Mutation") { [client] in
            let killed = try await client.killMutation(database: mutation.database, table: mutation.table, mutationID: mutation.mutationID)
            return killed > 0 ? "Mutation killed" : "The mutation had already finished"
        }
    }

    func reload(_ dictionary: DictionaryInfo) {
        pendingAction = PendingAction(title: "Reload dictionary \(dictionary.qualifiedName)?",
                                      message: "The dictionary is reloaded from its source now.", confirmLabel: "Reload") { [client] in
            try await client.reloadDictionary(dictionary)
            return "Dictionary reloaded"
        }
    }

    func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task {
            do {
                workspace.showToast(try await action.run())
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
        }
    }
}
