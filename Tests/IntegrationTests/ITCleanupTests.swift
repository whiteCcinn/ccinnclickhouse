import ClickHouseKit
import Foundation
import Testing

/// Review: a failing mutation retries until it is killed, and an aborted test run left some burning CPU on every server.
/// The cleanup must run however a test ends, and the next run must sweep what a crashed run left.
@Suite("Integration cleanup", .enabled(if: ITEnvironment.enabled), .serialized)
struct ITCleanupTests {
    /// A table with a mutation that fails, and keeps failing, on its one row.
    private func failingMutationTable(_ admin: ClickHouseClient, _ table: String) async throws {
        _ = try await admin.run("CREATE TABLE shop.\(table) (id UInt8) ENGINE = MergeTree ORDER BY id")
        _ = try await admin.run("INSERT INTO shop.\(table) VALUES (1)")
        _ = try await admin.run("ALTER TABLE shop.\(table) DELETE WHERE throwIf(id = 1, 'zz_cleanup_probe') = 0")
        let failing = try await waitUntil {
            try await ITCleanup.pendingMutations(admin, table: table) == 1
        }
        #expect(failing, "the mutation is pending")
    }

    private func exists(_ admin: ClickHouseClient, _ table: String) async throws -> Bool {
        try await admin.run("SELECT count() FROM system.tables WHERE database = 'shop' AND name = '\(table)'").rows.first?.first.flatMap { $0 } == "1"
    }

    @Test func aThrowingTestStillKillsItsMutationAndDropsItsTable() async throws {
        let admin = try await ITEnvironment.connect()
        let table = "zz_mw5_mut_guard_\(UInt32.random(in: 0...UInt32.max))"
        struct Planned: Error {}
        await #expect(throws: Planned.self) {
            try await ITCleanup.guarding(admin, tables: [table]) {
                try await failingMutationTable(admin, table)
                throw Planned()
            }
        }
        #expect(try await ITCleanup.pendingMutations(admin, table: table) == 0)
        #expect(try await !exists(admin, table))
        await admin.close()
    }

    @Test func leftoversOfACrashedRunAreSwept() async throws {
        let admin = try await ITEnvironment.connect()
        let prefix = "zz_mw5_mut_sweep_\(UInt32.random(in: 0...UInt32.max))_"
        let table = prefix + "1"
        do {
            try await failingMutationTable(admin, table)
            // A sweep spares what is younger than its limit (a concurrent run's live table) …
            #expect(await ITCleanup.sweep(admin, prefix: prefix, olderThanSeconds: 3_600).isEmpty)
            #expect(try await exists(admin, table))
            // … and removes the rest.
            #expect(await ITCleanup.sweep(admin, prefix: prefix, olderThanSeconds: 0) == [table])
            #expect(try await ITCleanup.pendingMutations(admin, table: table) == 0)
            #expect(try await !exists(admin, table))
        } catch {
            await ITCleanup.removeTables(admin, [table])
            throw error
        }
        await admin.close()
    }
}
