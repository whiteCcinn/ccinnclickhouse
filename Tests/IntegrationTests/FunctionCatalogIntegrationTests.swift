import ClickHouseKit
import Foundation
import Testing
@testable import CcinnClickHouseKit

/// Review (D): the reviewed catalog must cover what this server ships. Every table function is in exactly one class,
/// every function is allowed or denied, every privilege is known and judged the same by the server's own hierarchy
/// and the pinned one. Anything unknown fails, so a new ClickHouse version is reviewed before it is supported.
@Suite("Function and privilege catalog against the server", .enabled(if: ITEnvironment.enabled), .serialized)
struct FunctionCatalogIntegrationTests {
    private func names(_ sql: String) async throws -> [String] {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        return try await client.run(sql).rows.compactMap { $0.first ?? nil }
    }

    @Test func everyTableFunctionIsClassified() async throws {
        let classes = ["external": AIFunctionCatalog.externalTableFunctions, "allowed": AIFunctionCatalog.allowedTableFunctions,
                       "reviewedLocal": AIFunctionCatalog.reviewedLocalTableFunctions, "aiRefused": AIFunctionCatalog.aiRefusedTableFunctions]
        let all = try await names("SELECT name FROM system.table_functions ORDER BY name")
        #expect(!all.isEmpty)
        for name in all {
            let memberships = classes.filter { $0.value.contains(name.lowercased()) }.map(\.key)
            #expect(memberships.count == 1, "\(name): \(memberships.isEmpty ? "unknown" : memberships.joined(separator: ", "))")
            let call = "SELECT * FROM \(name)()"
            let refusedForAI = ReadOnlySQLGuard.check(call, audience: .ai(database: "shop")) != nil
            #expect(refusedForAI == !AIFunctionCatalog.allowedTableFunctions.contains(name.lowercased()), "AI: \(call)")
            if AIFunctionCatalog.externalTableFunctions.contains(name.lowercased()) {
                #expect(ReadOnlySQLGuard.check(call) != nil, "editor: \(call)")
                #expect(ReadOnlySQLGuard.check("SELECT * FROM shop.a AS a JOIN shop.b AS b USING (n), \(name)() AS f") != nil, "editor, gap A: \(name)")
            }
        }
    }

    @Test func everyFunctionIsAllowedOrDenied() async throws {
        let all = try await names("SELECT name FROM system.functions WHERE origin = 'System' ORDER BY name")
        #expect(all.count > 1_000)
        for name in all {
            let allowed = ReadOnlySQLGuard.isAllowedFunction(name)
            let denied = AIFunctionCatalog.denied[name] != nil
            #expect(allowed != denied, "\(name): \(allowed ? "allowed and denied" : "unknown: review it in scripts/gen-ai-function-catalog.py")")
        }
    }

    @Test func everyPrivilegeIsKnownAndJudgedAlike() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let rows = try await client.run("SELECT privilege, aliases, parent_group FROM system.privileges").rows
        let live = try #require(PrivilegeHierarchy(rows: rows))
        for privilege in rows.compactMap({ $0.first ?? nil }) where privilege != "ALL" {
            let grant = "GRANT \(privilege) ON *.* TO u"
            let pinned = MCPPrivilegeReport(grants: [grant]).risks
            #expect(PrivilegeHierarchy.pinned.lineage(of: privilege) != nil, "\(privilege): unknown to the pinned hierarchy")
            #expect(pinned == MCPPrivilegeReport(grants: [grant], hierarchy: live).risks, "\(privilege)")
            #expect(!pinned.contains { if case .unknown = $0 { true } else { false } }, "\(privilege)")
        }
        #expect(MCPPrivilegeReport(grants: ["GRANT SELECT ON *.* TO u"], hierarchy: live).isPlain)
        #expect(MCPPrivilegeReport(grants: ["GRANT SOURCES ON *.* TO u"], hierarchy: live).risks == [.sources])
        if rows.contains(where: { $0.first == "aiGenerate" }) {
            #expect(MCPPrivilegeReport(grants: ["GRANT aiGenerate ON *.* TO u"], hierarchy: live).risks == [.sources])
        }
    }
}

/// Review (dialect / implicit table): every setting a server has that may change parsing or name resolution is either
/// verified on each read-only request path or reviewed as harmless; an unknown one fails, so it is reviewed first.
@Suite("Parser settings against the server", .enabled(if: ITEnvironment.enabled), .serialized)
struct ParserSettingsIntegrationTests {
    @Test func everyParserSettingIsVerifiedOrReviewed() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let rows = try await client.run("SELECT name, description FROM system.settings").rows
        #expect(rows.count > 300)
        let verified = Set(ParserSettings.verified.map(\.name))
        for row in rows {
            let name = row[0] ?? "", description = row.count > 1 ? row[1] ?? "" : ""
            guard ParserSettings.mayAffectParsing(name: name, description: description) else { continue }
            #expect(verified.contains(name) || ParserSettings.reviewed.contains(name), "\(name): review it in ParserSettings")
        }
        // The verified values are each version's defaults (24.8+ print them).
        if let defaults = try? await client.run("SELECT name, default FROM system.settings WHERE name IN ("
                                                    + ParserSettings.verified.map { "'\($0.name)'" }.joined(separator: ", ") + ")").rows {
            for row in defaults {
                let expected = ParserSettings.verified.first { $0.name == row[0] }?.value
                #expect(row[1] == expected, "\(row[0] ?? ""): default \(row[1] ?? "nil")")
            }
        }
    }
}
