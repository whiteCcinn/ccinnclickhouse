import ClickHouseWire
import Foundation
import os

/// Column sets of the `system` tables the app reads, so one query shape works on every version
/// (design D10): missing columns are selected as `NULL AS name`, expensive ones are never selected
/// by accident, and optional tables are detected instead of failing.
///
/// A table's columns are known, or it is unavailable (absent on this version, or not readable by this user),
/// or nothing is known yet. Unknown is never "a table without columns": `system.columns` hides the `system`
/// tables from users without `SHOW COLUMNS` on them, though they may still read them, so readers learn a table
/// (``ClickHouseClient/ensureSystemTable(_:)``) before building a select list.
public final class SystemSchema: Sendable {
    /// Tables loaded at connect time.
    public static let knownTables = [
        "tables", "columns", "databases", "parts", "parts_columns", "detached_parts", "merges", "mutations", "replicas", "replication_queue",
        "processes", "query_log", "disks", "storage_policies", "dictionaries", "clusters", "data_skipping_indices", "projections",
        "projection_parts", "settings", "functions", "zookeeper_connection", "distribution_queue", "distributed_ddl_queue", "macros",
        "merge_tree_settings", "table_engines", "formats", "table_functions", "data_type_families", "aggregate_function_combinators",
        "keywords", "database_engines",
    ]

    public static var loadQuery: String {
        "SELECT table, name FROM system.columns WHERE database = 'system' AND table IN ("
            + knownTables.map(SQLText.literal).joined(separator: ", ") + ")"
    }

    /// How long a table that could not be read is remembered: grants change, and `*_log` tables appear after the
    /// first flush. Other tables a version lacks are remembered for the connection.
    static let defaultRetryInterval: Duration = .seconds(60)

    /// Whether a `system` table can be read.
    public enum Availability: Sendable {
        case available
        /// Not on this version (or no Keeper configured).
        case absent
        /// This user may not read it; the server's refusal.
        case denied(ClickHouseError)
    }

    /// What learning a table found out.
    enum Discovery: Sendable {
        case columns(Set<String>)
        case absent
        case denied(ClickHouseError)
    }

    private struct Unavailable {
        var availability: Availability
        /// `nil`: for the connection's lifetime.
        var until: ContinuousClock.Instant?
    }

    private typealias Waiter = CheckedContinuation<Availability, any Error>

    private struct State {
        var columns: [String: Set<String>]
        var unavailable: [String: Unavailable] = [:]
        /// Tables being learned; one discovery per table at a time.
        var discovering: Set<String> = []
        /// Callers waiting for a table's discovery, by ticket, so a cancelled caller can leave alone.
        var waiters: [String: [UInt64: Waiter]] = [:]
        var nextTicket: UInt64 = 0
    }

    private enum Step {
        case settled(Availability)
        case cancelled
        case wait
        case discover
    }

    private let state: OSAllocatedUnfairLock<State>
    private let retryInterval: Duration

    public convenience init(columns: [String: Set<String>]) {
        self.init(columns: columns, retryInterval: Self.defaultRetryInterval)
    }

    init(columns: [String: Set<String>], retryInterval: Duration) {
        state = OSAllocatedUnfairLock(initialState: State(columns: columns))
        self.retryInterval = retryInterval
    }

    convenience init(result: QueryResult) {
        var columns: [String: Set<String>] = [:]
        for record in result.records {
            guard let table = record.text("table"), let name = record.text("name") else { continue }
            columns[table, default: []].insert(name)
        }
        self.init(columns: columns)
    }

    /// The table's columns are known.
    public func hasTable(_ table: String) -> Bool { state.withLock { $0.columns[table] != nil } }

    public func has(_ table: String, column: String) -> Bool { state.withLock { $0.columns[table]?.contains(column) ?? false } }

    /// The table's columns, or `nil` while they are not known.
    public func columns(of table: String) -> Set<String>? { state.withLock { $0.columns[table] } }

    /// `a, b, NULL AS c` for `system.<table>`; every wanted column exists in the output. For a table whose columns
    /// are not known, the wanted names as they are: the server then answers real values or its own error, never
    /// rows of `NULL`. Learn the table first (``ClickHouseClient/selectList(system:_:)``).
    func selectList(_ table: String, _ wanted: [String]) -> String {
        guard let available = columns(of: table) else { return wanted.map(SQLText.quoteIdentifier).joined(separator: ", ") }
        return wanted.map { name in
            available.contains(name) ? SQLText.quoteIdentifier(name) : "NULL AS \(SQLText.quoteIdentifier(name))"
        }.joined(separator: ", ")
    }

    /// Whether `table` can be read, learning its columns with `discover` when nothing is known. Concurrent callers
    /// share one discovery; a cancelled caller returns at once while the discovery goes on for the others. Errors
    /// are rethrown and not remembered.
    func resolve(_ table: String, discover: @escaping @Sendable () async throws -> Discovery) async throws -> Availability {
        let ticket = state.withLock { state -> UInt64 in
            state.nextTicket &+= 1
            return state.nextTicket
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: Waiter) in
                let step = state.withLock { state -> Step in
                    if let known = settled(table, in: state, now: .now) { return .settled(known) }
                    // Checked under the lock the cancellation handler takes, so a cancellation is never missed.
                    if Task.isCancelled { return .cancelled }
                    state.waiters[table, default: [:]][ticket] = waiter
                    if state.discovering.contains(table) { return .wait }
                    state.discovering.insert(table)
                    return .discover
                }
                switch step {
                case let .settled(availability): waiter.resume(returning: availability)
                case .cancelled: waiter.resume(throwing: ClickHouseError.cancelled())
                case .wait: break
                case .discover: Task { await self.settle(table, discover) }
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters[table]?.removeValue(forKey: ticket) }
            waiter?.resume(throwing: ClickHouseError.cancelled())
        }
    }

    /// Callers waiting for `table`'s discovery (tests).
    func waiterCount(_ table: String) -> Int { state.withLock { $0.waiters[table]?.count ?? 0 } }

    private func settled(_ table: String, in state: State, now: ContinuousClock.Instant) -> Availability? {
        if state.columns[table] != nil { return .available }
        guard let unavailable = state.unavailable[table] else { return nil }
        if let until = unavailable.until, now >= until { return nil }
        return unavailable.availability
    }

    private func settle(_ table: String, _ discover: @Sendable () async throws -> Discovery) async {
        let outcome: Result<Discovery, any Error>
        do {
            outcome = .success(try await discover())
        } catch {
            outcome = .failure(error)
        }
        let retryAt = ContinuousClock.now.advanced(by: retryInterval)
        let (waiters, result) = state.withLock { state -> ([Waiter], Result<Availability, any Error>) in
            state.discovering.remove(table)
            let waiting = Array((state.waiters.removeValue(forKey: table) ?? [:]).values)
            switch outcome {
            case let .success(.columns(names)) where !names.isEmpty:
                state.columns[table] = names
                state.unavailable[table] = nil
                return (waiting, .success(.available))
            case .success(.columns), .success(.absent):
                state.unavailable[table] = Unavailable(availability: .absent, until: table.hasSuffix("_log") ? retryAt : nil)
                return (waiting, .success(.absent))
            case let .success(.denied(error)):
                state.unavailable[table] = Unavailable(availability: .denied(error), until: retryAt)
                return (waiting, .success(.denied(error)))
            case let .failure(error):
                return (waiting, .failure(error))
            }
        }
        for waiter in waiters { waiter.resume(with: result) }
    }
}

extension ClickHouseClient {
    /// A DESCRIBE should answer as fast as the connect probe: the connection's connect timeout, at most 10 s.
    var discoveryTimeout: Double { min(10, ConnectionConfiguration.sanitizedConnectTimeout(configuration.connectTimeout)) }

    /// Whether `system.<table>` can be read, learning its columns on first use when the connect-time load did not
    /// list them (`system.columns` hides the `system` tables from users without `SHOW COLUMNS` on them): from
    /// `DESCRIBE (SELECT * FROM system.<table>)`, which needs exactly the grant the real query needs and executes
    /// nothing. Timeouts, cancellation and network errors propagate.
    public func systemTableAvailability(_ table: String) async throws -> SystemSchema.Availability {
        try await systemSchema.resolve(table) { [self] in try await discoverSystemColumns(table) }
    }

    /// `true` when `system.<table>` can be read (see ``systemTableAvailability(_:)``).
    @discardableResult
    public func ensureSystemTable(_ table: String) async throws -> Bool {
        if case .available = try await systemTableAvailability(table) { return true }
        return false
    }

    /// For optional tables: `true` when readable, `false` when this version lacks it, and the server's refusal
    /// when the user may not read it (so a view says "access denied", not "nothing here").
    func optionalSystemTable(_ table: String) async throws -> Bool {
        switch try await systemTableAvailability(table) {
        case .available: true
        case .absent: false
        case let .denied(error): throw error
        }
    }

    /// `a, b, NULL AS c` for `system.<table>`, after learning the table's columns. For a table that cannot be read,
    /// the wanted names, so the query reports the server's error.
    public func selectList(system table: String, _ wanted: [String]) async throws -> String {
        try await ensureSystemTable(table)
        return systemSchema.selectList(table, wanted)
    }

    /// DESCRIBE executes nothing, so an abandoned one (timeout, cancellation) needs no KILL: it is sent without the
    /// kill-on-abandon of ``run(_:options:)``, and a stuck server is not sent a KILL for every lookup.
    func discoverSystemColumns(_ table: String) async throws -> SystemSchema.Discovery {
        let sql = "DESCRIBE (SELECT * FROM system.\(SQLText.quoteIdentifier(table)))"
        let builder = builder
        let transport = transport
        let seconds = discoveryTimeout
        do {
            let outcome = try await Deadline.run(seconds: seconds, timeoutError: {
                ClickHouseError(.timeout, "The server did not describe system.\(table) within \(Int(seconds)) s")
            }) {
                let options = QueryOptions.metadata(timeout: seconds)
                do {
                    return try await Self.run(sql, builder: builder, transport: transport, options: options)
                } catch let error as ClickHouseError where error.isConnectionLostBeforeResponse && !Task.isCancelled {
                    // A keep-alive connection the server closed (22.x: after 3 s idle): once more on a fresh one, with a
                    // new query id, as for every idempotent statement.
                    return try await Self.run(sql, builder: builder, transport: transport, options: options, freshConnection: true)
                }
            }
            noteNode(outcome.result.serverDisplayName)
            let names = Set(outcome.result.records.compactMap { $0.raw("name") })
            return names.isEmpty ? .absent : .columns(names)
        } catch let error as ClickHouseError where error.isFeatureUnavailable {
            return error.isAccessDenied ? .denied(error) : .absent
        }
    }
}
