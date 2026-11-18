import ClickHouseKit
import Foundation

/// Removal of the server objects integration tests create. A failing mutation retries until it is killed, so a
/// table's mutations are killed before it is dropped, however the test ends; what a crashed or cancelled run left is
/// swept when the next run starts.
enum ITCleanup {
    /// Runs `body`, then kills the mutations of `tables` (in `shop`) and drops them, also when `body` throws or is
    /// cancelled: the removal runs in a detached task, which the caller's cancellation does not reach.
    static func guarding<T: Sendable>(_ admin: ClickHouseClient, tables: [String], _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await removeTablesDetached(admin, tables)
            return value
        } catch {
            await removeTablesDetached(admin, tables)
            throw error
        }
    }

    /// Kills the mutations of `tables` (in `shop`), then drops them.
    static func removeTables(_ admin: ClickHouseClient, _ tables: [String]) async {
        for table in tables {
            _ = try? await admin.run("KILL MUTATION WHERE database = 'shop' AND table = '\(table)'")
            _ = try? await admin.run("DROP TABLE IF EXISTS shop.`\(table)` SYNC")
        }
    }

    private static func removeTablesDetached(_ admin: ClickHouseClient, _ tables: [String]) async {
        await Task.detached { await removeTables(admin, tables) }.value
    }

    /// Tables in `shop` named `prefix…` and created more than `olderThanSeconds` ago, left by a crashed or cancelled
    /// run: their mutations killed and the tables dropped. Younger ones may belong to a run in progress elsewhere.
    @discardableResult
    static func sweep(_ admin: ClickHouseClient, prefix: String = "zz_mw5_mut_", olderThanSeconds: Int = 120) async -> [String] {
        let sql = "SELECT name FROM system.tables WHERE database = 'shop' AND startsWith(name, '\(prefix)') "
            + "AND metadata_modification_time <= now() - \(olderThanSeconds) ORDER BY name"
        guard let stale = try? await admin.run(sql).rows.compactMap({ $0.first.flatMap { $0 } }) else { return [] }
        await removeTables(admin, stale)
        return stale
    }

    /// Mutations of `shop.table` that are not done.
    static func pendingMutations(_ admin: ClickHouseClient, table: String) async throws -> Int {
        let rows = try await admin.run("SELECT count() FROM system.mutations WHERE database = 'shop' AND table = '\(table)' AND NOT is_done")
        return rows.rows.first?.first.flatMap { $0 }.flatMap { Int($0) } ?? -1
    }
}
