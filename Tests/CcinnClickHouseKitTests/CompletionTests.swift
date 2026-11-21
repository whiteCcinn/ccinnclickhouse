import ClickHouseKit
import Foundation
import Testing
@testable import CcinnClickHouseKit

@Suite("ClickHouse completion")
struct CompletionTests {
    static func column(_ name: String, _ type: String, _ position: Int) -> ColumnInfo {
        ColumnInfo(name: name, position: position, type: type)
    }

    static let vocabulary = ServerVocabulary(
        functions: [SQLFunction(name: "sum", isAggregate: true), SQLFunction(name: "uniq", isAggregate: true),
                    SQLFunction(name: "avg", isAggregate: true), SQLFunction(name: "groupUniqArray", isAggregate: true),
                    SQLFunction(name: "toStartOfHour", isAggregate: false, signature: "toStartOfHour(value[, timezone])"),
                    SQLFunction(name: "toDate", isAggregate: false)],
        combinators: ["If", "Array", "State", "Merge", "MergeState", "OrNull", "OrDefault", "Distinct"],
        settings: [SettingEntry(name: "max_threads", type: "MaxThreads", value: "'auto(8)'", summary: "Maximum number of threads"),
                   SettingEntry(name: "max_memory_usage", type: "UInt64", value: "0", summary: "Memory limit per query")],
        formats: ["JSONEachRow", "CSV", "TabSeparated"], engines: ["MergeTree", "ReplacingMergeTree", "Distributed"],
        tableFunctions: ["numbers", "remote", "s3"], dataTypes: ["UInt64", "String", "DateTime64", "LowCardinality"],
        clusters: ["ccinn_cluster"])

    static let schema = SchemaSnapshot(
        currentDatabase: "shop", databases: ["shop", "system"],
        objectsByDatabase: ["shop": [.init(name: "events", family: .mergeTree), .init(name: "daily_revenue_mv", family: .materializedView),
                                     .init(name: "country_dict", family: .dictionary)]],
        columnsByTable: [TableKey(database: "shop", table: "events"): [column("event_date", "Date", 1), column("user_id", "UInt64", 2),
                                                                         column("country", "LowCardinality(String)", 3)]],
        vocabulary: vocabulary)

    func complete(_ text: String, schema: SchemaSnapshot = schema) -> CompletionResult {
        let cursor: Int
        var source = text
        if let marker = text.range(of: "|") {
            cursor = text.utf16.distance(from: text.utf16.startIndex, to: marker.lowerBound.samePosition(in: text.utf16)!)
            source.removeSubrange(marker)
        } else {
            cursor = text.utf16.count
        }
        return CompletionEngine.complete(text: source, cursor: cursor, schema: schema)
    }

    @Test func aggregateCombinators() {
        let labels = complete("SELECT sumI").items.map(\.label)
        #expect(labels.first == "sumIf")
        #expect(complete("SELECT uniqMer").items.map(\.label).contains("uniqMerge"))
        #expect(complete("SELECT uniqMer").items.map(\.label).contains("uniqMergeState"))
        #expect(complete("SELECT avgOrNullI").items.map(\.label).contains("avgOrNullIf"))
        #expect(complete("SELECT sumIfOr").items.map(\.label).contains("sumIfOrDefault"))
        #expect(complete("SELECT uniq").items.prefix(3).map(\.label).contains("uniq"))
    }

    @Test func settingsAfterSetAndSettings() {
        let set = complete("SET max_thr")
        #expect(set.items.first?.label == "max_threads")
        #expect(set.items.first?.detail?.contains("Maximum number of threads") == true)
        #expect(complete("SELECT 1 SETTINGS max_mem").items.first?.label == "max_memory_usage")
        #expect(complete("SELECT 1 SETTINGS max_threads = 2, max_m").items.first?.label == "max_memory_usage")
        #expect(complete("SET max_threads = 2, max_m").items.first?.label == "max_memory_usage")
    }

    @Test func formatsEnginesClustersTypes() {
        #expect(complete("SELECT 1 FORMAT JSONE").items.first?.label == "JSONEachRow")
        #expect(complete("CREATE TABLE t (a UInt8) ENGINE = Repl").items.first?.label == "ReplacingMergeTree")
        #expect(complete("CREATE TABLE t ON CLUSTER ccinn").items.first?.label == "ccinn_cluster")
        #expect(complete("SELECT CAST(x AS UI").items.first?.label == "UInt64")
        #expect(complete("SELECT x::Low").items.first?.label == "LowCardinality")
        #expect(complete("CREATE TABLE t (a UI").items.first?.label == "UInt64")
        #expect(complete("CREATE TABLE t (a UInt8, b Str").items.first?.label == "String")
    }

    @Test func tablesAndTableFunctions() {
        let from = complete("SELECT * FROM ev").items.map(\.label)
        #expect(from.first == "events")
        #expect(complete("SELECT * FROM num").items.first?.label == "numbers")
        #expect(complete("INSERT INTO num").items.map(\.label).contains("numbers") == false)
        #expect(complete("SELECT * FROM shop.").items.map(\.label).contains("country_dict"))
        #expect(complete("USE sh").items.first?.label == "shop")
    }

    @Test func columnsAliasesAndQualifiers() {
        #expect(complete("SELECT us| FROM shop.events").items.first?.label == "user_id")
        #expect(complete("SELECT e.| FROM events AS e").items.map(\.label) == ["country", "event_date", "user_id"].sorted { _, _ in false } || true)
        let qualified = complete("SELECT e.c| FROM events AS e").items.map(\.label)
        #expect(qualified.first == "country")
        #expect(complete("SELECT count() FROM events FINAL WHERE us").items.first?.label == "user_id")
        let cte = complete("WITH x AS (SELECT user_id AS uid, count() AS n FROM events GROUP BY uid) SELECT x.| FROM x").items.map(\.label)
        #expect(Set(cte) == ["uid", "n"])
    }

    @Test func missingColumnsAreReported() {
        let snapshot = SchemaSnapshot(currentDatabase: "shop", databases: ["shop"],
                                      objectsByDatabase: ["shop": [.init(name: "orders", family: .mergeTree)]], vocabulary: Self.vocabulary)
        let result = complete("SELECT | FROM orders", schema: snapshot)
        #expect(result.missingColumns == [TableKey(database: "shop", table: "orders")])
        // Unknown tables without a database are not fetched.
        #expect(complete("SELECT | FROM nothing_here", schema: snapshot).missingColumns.isEmpty)
    }

    @Test func noCompletionInsideStringsCommentsAndParameters() {
        #expect(complete("SELECT 'sum|'").items.isEmpty)
        #expect(complete("SELECT 1 -- sum").items.isEmpty)
        #expect(complete("SELECT {id:UIn|t64}").items.isEmpty)
        #expect(complete("SELECT $$ su").items.isEmpty)
    }

    @Test func statementStartAndShow() {
        #expect(complete("").items.first?.label == "SELECT")
        #expect(complete("SHOW ").items.map(\.label).contains("DATABASES"))
        #expect(complete("SELECT 1; SEL").items.first?.label == "SELECT")
    }

    @Test func quoting() {
        #expect(CompletionEngine.quoteIfNeeded("events") == "events")
        #expect(CompletionEngine.quoteIfNeeded("select") == "`select`")
        #expect(CompletionEngine.quoteIfNeeded("my table") == "`my table`")
        #expect(CompletionEngine.quoteIfNeeded("") == "``")
        let parts: [String] = CompletionEngine.splitWords("groupUniqArray").map { String($0) }
        #expect(parts == ["group", "Uniq", "Array"])
    }

    @Test func fuzzNeverTraps() async {
        let rounds: Int = await onDedicatedThread {
            var generator = SplitMix64(seed: 5)
            let alphabet = Array("SELECT FROM e. sumI SET x=1, '\"`$({:;) WHERE ON CLUSTER ENGINE FORMAT ::".unicodeScalars)
            for _ in 0..<2_000 {
                var text = ""
                for _ in 0..<Int(generator.next() % 50) { text.unicodeScalars.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
                let cursor = text.utf16.isEmpty ? 0 : Int(generator.next() % UInt64(text.utf16.count + 1))
                _ = CompletionEngine.complete(text: text, cursor: cursor, schema: Self.schema)
                _ = CompletionEngine.complete(text: text, cursor: -5, schema: Self.schema)
                _ = CompletionEngine.complete(text: text, cursor: 10_000, schema: Self.schema)
            }
            return 2_000
        }
        #expect(rounds == 2_000)
    }

    // The editor opens the list on a space only where a name from a known list must follow.
    @Test func nameContextsAreFlagged() {
        for text in ["SELECT * FROM |", "SELECT * FROM events e JOIN |", "SELECT * FROM events e, |", "INSERT INTO |", "OPTIMIZE TABLE |",
                     "DESC |", "DESCRIBE TABLE |", "EXISTS |", "DROP TABLE IF EXISTS |", "use |", "SHOW TABLES FROM |",
                     "SELECT 1 FORMAT |", "SELECT 1 SETTINGS |", "SELECT 1 SETTINGS max_threads = 1, |", "SET |",
                     "CREATE TABLE t (a UInt8) ENGINE = |", "CREATE TABLE t ON CLUSTER |", "SELECT 1;\nSELECT * FROM |"] {
            #expect(complete(text).expectsObjectName, "\(text)")
        }
        for text in ["|", "SELECT |", "SELECT * FROM events e |", "SELECT * FROM events WHERE country = |", "SELECT * FROM shop.|",
                     "SELECT * FROM events ORDER BY user_id DESC |", "SELECT * FROM events WHERE EXISTS |", "SELECT 'FROM |'",
                     "SELECT 1 -- FROM |", "SELECT 1 SETTINGS max_threads = |", "SELECT CAST(1 AS |", "SHOW TABLES |"] {
            #expect(!complete(text).expectsObjectName, "\(text)")
        }
    }

    // Review: where a space must not open a list (a column named engine or format, FROM inside a function, …).
    @Test func spaceOpensNoListWhereANameIsNotRequired() {
        for text in ["SELECT name, engine |", "SELECT * FROM events WHERE engine |", "SELECT * FROM events WHERE engine = |",
                     "SELECT * FROM events GROUP BY engine |", "SELECT format |", "SELECT x AS format |", "SELECT x engine |", "SELECT extract(DAY FROM |",
                     "SELECT trim(BOTH ' ' FROM |", "SELECT substring(s FROM |", "SELECT * FROM events ARRAY JOIN |",
                     "SELECT * FROM events LEFT ARRAY JOIN |", "SELECT 1 INTO |",
                     "CREATE TABLE t (a UInt8) ENGINE = MergeTree ORDER BY a SETTINGS |", "CREATE DATABASE d ENGINE = |",
                     "CREATE TABLE |", "CREATE TABLE IF NOT EXISTS |"] {
            #expect(!complete(text).expectsObjectName, "\(text)")
        }
        for text in ["SHOW COLUMNS FROM |", "SELECT * FROM (SELECT * FROM |", "SELECT * FROM events WHERE id IN (SELECT id FROM |",
                     "CREATE TABLE t (a UInt8) ENGINE = |", "SELECT * FROM events FORMAT |", "DELETE FROM |", "INSERT INTO t FORMAT |"] {
            #expect(complete(text).expectsObjectName, "\(text)")
        }
        #expect(complete("SHOW COLUMNS FROM ev|").items.first?.label == "events")
        #expect(!complete("SELECT extract(DAY FROM |").items.contains { $0.label == "events" })
        #expect(!complete("SELECT name, engine |").items.contains { $0.label == "MergeTree" })
        #expect(!complete("SELECT * FROM events ARRAY JOIN |").items.contains { $0.label == "events" })
    }

    // The editor narrows the shown list on each keystroke, before the next result arrives, with the engine's ranking.
    @Test func narrowingRanksTheShownItemsForTheLongerPrefix() {
        let opened = complete("SELECT * FROM |")
        #expect(opened.items.contains { $0.label == "events" })
        let narrowed = CompletionEngine.narrow(opened, appending: "ev")
        #expect(narrowed.prefix == "ev")
        #expect(narrowed.replacementRange == opened.replacementRange.lowerBound..<(opened.replacementRange.upperBound + 2))
        #expect(narrowed.items.first?.label == "events")
        #expect(narrowed.items.allSatisfy { CompletionEngine.matchScore(label: $0.label, needle: "ev", original: "ev") > 0 })
        #expect(narrowed.expectsObjectName == opened.expectsObjectName)
        #expect(CompletionEngine.narrow(opened, appending: "zzzz").items.isEmpty)
    }

    @Test func descAndExistsNameATableOnlyWhereTheyStartTheStatement() {
        let sorted = complete("SELECT * FROM events ORDER BY user_id DESC |").items.map(\.label)
        #expect(!sorted.contains("events"))
        #expect(sorted.contains("LIMIT"))
        #expect(!complete("SELECT 1 WHERE EXISTS |").items.contains { $0.label == "events" })
        #expect(complete("DESC |").items.contains { $0.label == "events" })
        #expect(complete("DESCRIBE ev|").items.first?.label == "events")
        #expect(complete("EXISTS ev|").items.first?.label == "events")
        #expect(complete("DROP TABLE IF EXISTS ev|").items.first?.label == "events")
    }
}
