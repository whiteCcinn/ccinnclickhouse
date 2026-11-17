import ClickHouseKit
import Foundation
import Testing
@testable import CcinnClickHouseKit

extension LiveSuites {
/// Real ClickHouse error messages are located on the text the user wrote (22.8 – 26.8, both analyzers).
@Suite("Error diagnostics", .serialized)
struct DiagnosticsIntegrationTests {
    /// (statement as written, text expected to be marked)
    static let cases: [(String, String)] = [
        ("SELECT 1 FORM t", "t"),
        ("SELECT 'é🇲🇾', 1 FORM t", "t"),
        ("SELECT 1,\n  2 FORM\n t", "t"),
        ("SELECT * FROM shop.events WHERE", "WHERE"),
        ("SELECT count(1", "("),
        ("SELECT 'abc", "'"),
        ("SELECT 1 /* x", "/*"),
        ("SELECT x FROM shop.events", "x"),
        ("SELECT e.nosuch FROM shop.events AS e", "e.nosuch"),
        ("SELECT `Weird Col` FROM shop.events", "`Weird Col`"),
        ("SELECT * FROM shop.nosuch", "shop.nosuch"),
        ("SELECT * FROM nosuch_table", "nosuch_table"),
        ("SELECT * FROM nosuchdb.t", "nosuchdb"),
        ("SELECT flor(1)", "flor"),
        ("SELECT * FROM numbrs(10)", "numbrs"),
        ("SELECT 1 SETTINGS max_threadz = 1", "max_threadz"),
        ("SELECT number FROM numbers(10) GROUP BY 1 HAVING nosuch > 1", "nosuch"),
        // Positions beyond the first line and beyond 999 bytes.
        ("SELECT " + String(repeating: " ", count: 1200) + "1 FORM t", "t"),
        ("SELECT 1" + String(repeating: "\n", count: 1500) + "FORM t", "t"),
    ]

    private func failure(_ client: ClickHouseClient, _ sql: String) async -> ClickHouseError? {
        do {
            _ = try await client.run(sql)
            return nil
        } catch let error as ClickHouseError {
            return error
        } catch {
            return nil
        }
    }

    private func marked(_ text: String, _ range: Range<Int>?) -> String? {
        guard let range else { return nil }
        return String(decoding: Array(text.utf16)[range], as: UTF16.self)
    }

    @Test func locatesRealErrors() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        for (sql, expected) in Self.cases {
            let error = try #require(await failure(client, sql), "\(sql.prefix(60)) should fail")
            let parsed = SQLServerError.parse(error.message, code: error.code, name: error.name)
            #expect(marked(sql, SQLErrorLocator.range(in: sql, error: parsed)) == expected, "\(sql.prefix(60)) → \(error.message.prefix(300))")
            // The short message never echoes the query or the full list of alternatives.
            #expect(parsed.summary.count <= 200, "\(parsed.summary)")
            #expect(!parsed.summary.contains("in scope") && !parsed.summary.contains("In scope"), "\(parsed.summary)")
        }
    }

    @Test func suggestionsAndKindsSurvive() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let unknown = try #require(await failure(client, "SELECT flor(1)"))
        let parsed = SQLServerError.parse(unknown.message, code: unknown.code, name: unknown.name)
        #expect(parsed.summary.contains("Maybe you meant"), "\(parsed.summary)")
        #expect(parsed.summary.contains("floor"), "\(parsed.summary)")
        #expect(parsed.kindLabel == "Unknown function")
        let syntax = try #require(await failure(client, "SELECT 1 FORM t"))
        let parsedSyntax = SQLServerError.parse(syntax.message, code: syntax.code, name: syntax.name)
        #expect(parsedSyntax.kindLabel == "Syntax error")
        #expect(parsedSyntax.summary.hasPrefix("Syntax error near 't'. Expected one of: "), "\(parsedSyntax.summary)")
    }

    @Test func mapsExplainAndAutoLimitBack() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }

        let source = "SELECT 1 FORM t"
        let prefix = "EXPLAIN indexes = 1 "
        let explained = try #require(await failure(client, prefix + source))
        let mapping = SQLExecutedTextMapping(prefixLength: prefix.utf16.count)
        #expect(marked(source, SQLErrorLocator.range(in: source, executed: prefix + source, mapping: mapping,
                                                     error: SQLServerError.parse(explained.message))) == "t")

        // The LIMIT is inserted right after WHERE (before the comment); the server reports the error there.
        let unfinished = "SELECT * FROM shop.events WHERE -- todo"
        let limited = AutoLimit.apply(to: unfinished, limit: 10)
        #expect(limited.applied)
        let message = try #require(await failure(client, limited.sql))
        #expect(marked(unfinished, SQLErrorLocator.range(in: unfinished, executed: limited.sql,
                                                         mapping: SQLExecutedTextMapping(insertion: limited.insertion),
                                                         error: SQLServerError.parse(message.message))) == "WHERE", "\(message.message.prefix(300))")
    }
}
}
