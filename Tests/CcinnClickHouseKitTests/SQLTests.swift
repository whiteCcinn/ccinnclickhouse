import Foundation
import Testing
@testable import CcinnClickHouseKit

@Suite("ClickHouse SQL lexer")
struct LexerTests {
    func kinds(_ sql: String) -> [(SQLToken.Kind, String)] {
        let lexer = SQLLexer(sql)
        return lexer.tokens().map { ($0.kind, lexer.text(of: $0)) }
    }

    @Test func basicTokens() {
        let tokens = kinds("SELECT `a b`, \"c\", 'x\\'y', 0x1F, 0b101, 1_000, 1.5e-3, a::UInt8, x -> x + 1 FROM t;")
        #expect(tokens.contains { $0 == (.quotedIdentifier, "`a b`") })
        #expect(tokens.contains { $0 == (.quotedIdentifier, "\"c\"") })
        #expect(tokens.contains { $0 == (.string, "'x\\'y'") })
        #expect(tokens.contains { $0 == (.number, "0x1F") })
        #expect(tokens.contains { $0 == (.number, "0b101") })
        #expect(tokens.contains { $0 == (.number, "1_000") })
        #expect(tokens.contains { $0 == (.number, "1.5e-3") })
        #expect(tokens.contains { $0 == (.operator, "::") })
        #expect(tokens.contains { $0 == (.operator, "->") })
        #expect(tokens.first! == (.keyword, "SELECT"))
    }

    @Test func nestedCommentsAndHashComments() {
        let tokens = kinds("SELECT 1 /* a /* b */ c */ + 2 # trailing\n#!shebang\nSELECT #x")
        #expect(tokens.filter { $0.0 == .comment }.map(\.1) == ["/* a /* b */ c */", "# trailing", "#!shebang"])
        #expect(tokens.contains { $0 == (.operator, "#") })
        #expect(tokens.contains { $0 == (.number, "2") })
    }

    @Test func heredocsAndParameters() {
        let tokens = kinds("SELECT $$it's; fine$$, $tag$ a $$ b $tag$, {id:UInt64}, {name: String}, {'k': 1}, $1")
        #expect(tokens.contains { $0 == (.string, "$$it's; fine$$") })
        #expect(tokens.contains { $0 == (.string, "$tag$ a $$ b $tag$") })
        #expect(tokens.contains { $0 == (.parameter, "{id:UInt64}") })
        #expect(tokens.contains { $0 == (.parameter, "{name: String}") })
        #expect(!tokens.contains { $0.1 == "{'k': 1}" })
        #expect(SQLStatementSplitter.split("SELECT $$a;b$$; SELECT 2").count == 2)
    }

    @Test func identifierAndStringValues() {
        let lexer = SQLLexer("`we\\`ird` \"dq\"\"x\" 'a\\nb'")
        let tokens = lexer.tokens()
        #expect(lexer.identifierValue(of: tokens[0]) == "we`ird")
        #expect(lexer.identifierValue(of: tokens[1]) == "dq\"x")
        #expect(lexer.stringValue(of: tokens[2]) == "a\nb")
    }

    @Test func unterminatedInputNeverFails() {
        for sql in ["'abc", "`abc", "/* never closed /* nested */", "$$ open", "{id:", "\"x", "0x", "1e", "--", "#", "0x1.", "0x1p", "1e-",
                    ".5e+", "1_", "0b", "."] {
            let tokens = SQLLexer.tokenize(sql)
            #expect(tokens.last?.range.upperBound ?? 0 <= sql.utf16.count)
        }
    }

    @Test func fuzzNeverTraps() {
        var generator = SplitMix64(seed: 99)
        let alphabet = Array("SELECT'\"`$#/*-{}:;()[]\\0x1e.ab \n中😀".unicodeScalars)
        for _ in 0..<5_000 {
            var text = ""
            for _ in 0..<Int(generator.next() % 60) { text.unicodeScalars.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
            let lexer = SQLLexer(text)
            for token in lexer.tokens() {
                #expect(token.range.lowerBound >= 0 && token.range.upperBound <= lexer.units.count)
                _ = lexer.identifierValue(of: token)
                _ = lexer.stringValue(of: token)
            }
            _ = SQLStatementSplitter.split(text)
            _ = SQLStatementKind.of(text)
            _ = AutoLimit.apply(to: text, limit: 100)
            _ = ReadOnlySQLGuard.check(text)
            _ = SQLRedactor.redact(text)
        }
    }
}

@Suite("Statements, kinds and auto-limit")
struct StatementTests {
    @Test func splitting() {
        let script = "SELECT ';' AS a; -- c;\nSELECT 2 /* ; */;\n\n  -- only comment\n;SELECT `x;y`"
        let statements = SQLStatementSplitter.split(script)
        #expect(statements.map(\.text) == ["SELECT ';' AS a", "SELECT 2 /* ; */", "SELECT `x;y`"])
        #expect(SQLStatementSplitter.statement(at: (script as NSString).length, in: script)?.text == "SELECT `x;y`")
    }

    @Test func kinds() {
        #expect(SQLStatementKind.of("SELECT 1") == .query)
        #expect(SQLStatementKind.of("WITH x AS (SELECT 1) SELECT * FROM x") == .query)
        #expect(SQLStatementKind.of("WITH 1 AS x SELECT x") == .query)
        #expect(SQLStatementKind.of("(SELECT 1) UNION ALL (SELECT 2)") == .query)
        #expect(SQLStatementKind.of("SELECT 1 INTO OUTFILE 'x.csv'") == .other)
        #expect(SQLStatementKind.of("EXPLAIN PIPELINE SELECT 1") == .explain)
        #expect(SQLStatementKind.of("SHOW TABLES") == .show)
        #expect(SQLStatementKind.of("EXISTS TABLE t") == .show)
        #expect(SQLStatementKind.of("USE shop") == .use)
        #expect(SQLStatementKind.of("SET max_threads = 2") == .set)
        #expect(SQLStatementKind.of("SET ROLE admin") == .administration)
        #expect(SQLStatementKind.of("INSERT INTO t SELECT * FROM u") == .dataModification)
        #expect(SQLStatementKind.of("ALTER TABLE t UPDATE x = 1 WHERE 1") == .dataModification)
        #expect(SQLStatementKind.of("ALTER TABLE t ON CLUSTER c DELETE WHERE x = 1") == .dataModification)
        #expect(SQLStatementKind.of("ALTER TABLE t ADD COLUMN c UInt8") == .definition)
        #expect(SQLStatementKind.of("ALTER TABLE t DROP PARTITION 202401") == .definition)
        #expect(SQLStatementKind.of("DELETE FROM t WHERE x = 1") == .dataModification)
        #expect(SQLStatementKind.of("OPTIMIZE TABLE t FINAL") == .administration)
        #expect(SQLStatementKind.of("SYSTEM FLUSH LOGS") == .administration)
        #expect(SQLStatementKind.of("KILL QUERY WHERE 1") == .administration)
        #expect(SQLStatementKind.of("CREATE TABLE t (a UInt8) ENGINE = Memory") == .definition)
        #expect(SQLStatementKind.of("FOO BAR") == .other)
        #expect(SQLStatementKind.of("/* comment */ select 1") == .query)
        #expect(SQLStatementKind.of("FOO BAR").isMutation)
        #expect(SQLStatementKind.of("ALTER TABLE t UPDATE x = 1 WHERE 1").isMutation)
        #expect(!SQLStatementKind.of("SELECT 1").isMutation)
    }

    @Test func autoLimit() {
        #expect(AutoLimit.apply(to: "SELECT * FROM t", limit: 100) == .init(sql: "SELECT * FROM t LIMIT 100", applied: true, insertion: 15..<25))
        #expect(AutoLimit.apply(to: "SELECT * FROM t -- note", limit: 100).sql == "SELECT * FROM t LIMIT 100 -- note")
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 5", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 5 OFFSET 10", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 10 WITH TIES", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 1 BY k", limit: 100).sql == "SELECT * FROM t LIMIT 1 BY k LIMIT 100")
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 1 BY k LIMIT 3", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t SETTINGS max_threads = 1", limit: 100).sql == "SELECT * FROM t LIMIT 100 SETTINGS max_threads = 1")
        #expect(AutoLimit.apply(to: "SELECT * FROM t FORMAT JSON", limit: 100).sql == "SELECT * FROM t LIMIT 100 FORMAT JSON")
        #expect(AutoLimit.apply(to: "SELECT TOP 5 * FROM t", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT 1 UNION ALL SELECT 2", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM (SELECT * FROM t LIMIT 5)", limit: 100).applied == true)
        #expect(AutoLimit.apply(to: "WITH x AS (SELECT 1 LIMIT 1) SELECT * FROM x", limit: 10).sql == "WITH x AS (SELECT 1 LIMIT 1) SELECT * FROM x LIMIT 10")
        #expect(AutoLimit.apply(to: "INSERT INTO t SELECT * FROM u", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SHOW TABLES", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT 1 INTO OUTFILE 'f'", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT 1", limit: 0).applied == false)
    }
}

@Suite("Read-only guard, redaction and error positions")
struct SafetyTests {
    @Test func allowsReads() {
        for sql in ["SELECT 1", "select * from system.tables", "WITH x AS (SELECT 1) SELECT * FROM x", "SHOW CREATE TABLE t", "DESCRIBE t",
                    "EXISTS TABLE t", "EXPLAIN SELECT 1", "EXPLAIN PIPELINE SELECT 1", "EXPLAIN indexes = 1, actions = 1 SELECT 1",
                    "EXPLAIN QUERY TREE SELECT 1", "SELECT drop, insert, create FROM t", "SELECT * FROM t WHERE s = 'DROP TABLE x'",
                    "SELECT 1 -- ; DROP TABLE t", "SELECT system FROM t", "SELECT * FROM t; ", "(SELECT 1)"] {
            #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql) ?? "")")
        }
    }

    @Test func rejectsWrites() {
        for sql in ["INSERT INTO t VALUES (1)", "ALTER TABLE t DELETE WHERE 1", "DROP TABLE t", "CREATE TABLE t (a UInt8) ENGINE = Memory",
                    "TRUNCATE TABLE t", "OPTIMIZE TABLE t", "KILL QUERY WHERE 1", "SYSTEM FLUSH LOGS", "SELECT 1; DROP TABLE t",
                    "SELECT 1 INTO OUTFILE 'x'", "SET readonly = 0", "EXPLAIN ESTIMATE INSERT INTO t SELECT 1", "GRANT ALL ON *.* TO x",
                    "DELETE FROM t WHERE 1", "UPDATE t SET a = 1 WHERE 1", "RENAME TABLE a TO b", "", "  -- only a comment",
                    "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x", "EXPLAIN", "BACKUP TABLE t TO Disk('b', 'x')"] {
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
        }
    }

    @Test func redaction() {
        #expect(SQLRedactor.redact("CREATE USER u IDENTIFIED BY 'secret'") == "CREATE USER u IDENTIFIED BY '***'")
        #expect(SQLRedactor.redact("CREATE USER u IDENTIFIED WITH sha256_password BY 'secret'") == "CREATE USER u IDENTIFIED WITH sha256_password BY '***'")
        #expect(SQLRedactor.redact("ALTER USER u IDENTIFIED WITH sha256_hash BY 'abc' SALT 'pepper'") == "ALTER USER u IDENTIFIED WITH sha256_hash BY '***' SALT '***'")
        #expect(SQLRedactor.redact("SOURCE(CLICKHOUSE(USER 'u' PASSWORD 'p' DB 'shop'))") == "SOURCE(CLICKHOUSE(USER 'u' PASSWORD '***' DB 'shop'))")
        #expect(SQLRedactor.redact("SELECT * FROM mysql('db:3306', 'shop', 'orders', 'root', 'pw')") == "SELECT * FROM mysql('db:3306', 'shop', 'orders', '***', '***')")
        #expect(SQLRedactor.redact("SELECT * FROM s3('https://b.s3.amazonaws.com/x.csv', 'AKIA', 'SECRET', 'CSV')") == "SELECT * FROM s3('https://b.s3.amazonaws.com/x.csv', '***', '***', '***')")
        #expect(SQLRedactor.redact("SELECT * FROM remote('h:9000', db.t, 'u', 'pw')") == "SELECT * FROM remote('h:9000', db.t, '***', '***')")
        #expect(SQLRedactor.redact("CREATE NAMED COLLECTION c AS host = 'h', password = 'p'") == "CREATE NAMED COLLECTION c AS host = 'h', password = '***'")
        #expect(SQLRedactor.redact("SELECT * FROM url('https://user:pw@example.com/a.csv', CSV)") == "SELECT * FROM url('https://***@example.com/a.csv', CSV)")
        #expect(SQLRedactor.redact("SELECT 'plain', password FROM users") == "SELECT 'plain', password FROM users")
    }

    @Test func errorPositions() {
        let statement = "SELECT 1,\n  2 FRM t"
        #expect(SQLErrorLocator.offset(in: statement, message: "Syntax error: failed at position 19 ('t') (line 2, col 9): t.") == 18)
        #expect(SQLErrorLocator.offset(in: statement, message: "Syntax error: failed at position 19 ('t'): t.") == 18)
        // Multi-byte characters: byte offsets map to UTF-16 offsets.
        #expect(SQLErrorLocator.offset(in: "SELECT '中文' FRM", message: "failed at position 17 ('FRM')") == 12)
        #expect(SQLErrorLocator.offset(in: "SELECT 😀 x", message: "failed at position 13") == 10)
        // Absurd positions are clamped.
        #expect(SQLErrorLocator.offset(in: "SELECT", message: "failed at position 999999999") == 6)
        #expect(SQLErrorLocator.offset(in: "SELECT", message: "(line 9, col 1)") == nil)
        #expect(SQLErrorLocator.offset(in: "SELECT", message: "no position") == nil)
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

@Suite("Read-only guard: external access and settings")
struct ExternalAccessGuardTests {
    @Test(arguments: [
        "SELECT * FROM url('http://169.254.169.254/latest/meta-data', 'RawBLOB')",
        "SELECT * FROM URL('http://x', 'RawBLOB')",
        "SELECT * FROM `url`('http://x', 'RawBLOB')",
        "SELECT * FROM \"file\"('/etc/passwd', 'LineAsString')",
        "SELECT file('/etc/passwd')",
        "SELECT * FROM remote('10.0.0.5', system.one)",
        "SELECT * FROM remoteSecure('10.0.0.5:9440', system.one)",
        "SELECT * FROM s3('https://b.s3.amazonaws.com/x.csv')",
        "SELECT * FROM s3Cluster('c', 'https://b/x.csv')",
        "SELECT * FROM hdfs('hdfs://x/y', 'CSV')",
        "SELECT * FROM mysql('h:3306', 'd', 't', 'u', 'p')",
        "SELECT * FROM postgresql('h', 'd', 't', 'u', 'p')",
        "SELECT * FROM jdbc('jdbc:x', 't')",
        "SELECT * FROM odbc('DSN=x', 't')",
        "SELECT * FROM executable('x.sh', 'CSV', 'a String')",
        "SELECT * FROM input('a String')",
        "SELECT * FROM urlCluster('c', 'http://x')",
        "SELECT * FROM azureBlobStorage('x')",
        "SELECT * FROM numbers(3) AS n, url('http://x', 'RawBLOB') AS u",
        "SELECT * FROM numbers(3) JOIN url('http://x', 'RawBLOB') USING (number)",
        "SELECT * FROM (SELECT * FROM url('http://x', 'RawBLOB'))",
        "SELECT number IN (SELECT * FROM file('x')) FROM numbers(3)",
        "SELECT * FROM someFutureExternalSource('http://x')",
        "SELECT 1 SETTINGS readonly = 0",
        "SELECT 1 SETTINGS max_execution_time = 0",
        "SELECT * FROM numbers(1e12) SETTINGS max_result_rows = 0, max_memory_usage = 0",
        "SELECT * FROM (SELECT 1 SETTINGS allow_ddl = 1)",
        "EXPLAIN SELECT * FROM url('http://x', 'RawBLOB')",
        "SYSTEM STOP MERGES",
        "KILL QUERY WHERE 1",
        "SELECT 1 INTO OUTFILE '/tmp/x'",
    ])
    func rejected(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    @Test(arguments: [
        "SELECT * FROM numbers(10)",
        "SELECT * FROM numbers_mt(10) AS a, zeros(3) AS b",
        "SELECT * FROM generateRandom('a UInt8') LIMIT 1",
        "SELECT * FROM clusterAllReplicas('c', system.processes)",
        "SELECT * FROM cluster('c', system.one)",
        "SELECT * FROM merge('db', '^t')",
        "SELECT * FROM view(SELECT 1)",
        "SELECT * FROM values('a UInt8', 1, 2)",
        "SELECT url, file FROM t",
        "SELECT domain(url), lower(path) FROM shop.events",
        "SELECT count() FROM shop.events WHERE url LIKE '%file(%'",
        "SELECT toStartOfHour(ts) AS h, count() FROM t GROUP BY h ORDER BY h",
        "EXPLAIN indexes = 1 SELECT 1",
        "SELECT * FROM t1 JOIN t2 ON t1.a = t2.a",
        "SELECT * FROM t AS x, (SELECT 1) AS y",
    ])
    func allowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql) ?? "")")
    }
}

/// The shared lexer is a security boundary: whatever a supported server (22.8, 24.8, 26.8) reads as a clause or a second
/// statement, the read-only guard must see too, or refuse. Each text below hides a SETTINGS clause, a table function, a
/// write or a second statement behind a construct; every one is refused. Server behaviour: `FormatterIntegrationTests`.
@Suite("Read-only guard: nothing hides behind a construct")
struct GuardSmugglingTests {
    @Test(arguments: [
        // A number that starts with `.` takes no word characters: every server reads `.5` and then the keyword
        // (1.2.0 read one number `.5settings` and let these through).
        "SELECT 1, .5settings max_threads = 1",
        "SELECT 1, .5SETTINGS readonly = 0",
        "SELECT 1, .5e1settings max_execution_time = 0",
        "SELECT 1, .5e+1settings max_memory_usage = 0",
        "SELECT 1, .5into outfile '/tmp/x'",
        "SELECT 1, .5from someFutureExternalSource('http://x')",
        "SELECT (.5)settings max_threads = 1",
        // Heredoc tags other than letters, digits and `_`: one string on 22.8/24.8, names on 26.8 (1.2.0 let these through).
        "SELECT 1 AS $a, $a b$ SETTINGS max_threads = 1 -- $a b$",
        "SELECT $a b$; DROP TABLE t; $a b$",
        "SELECT 1 $x-y$; ALTER TABLE t DELETE WHERE 1 -- $x-y$",
        "SELECT 1 $é$; INSERT INTO t VALUES (1) -- $é$",
        "SELECT $ $; TRUNCATE TABLE t; $ $",
        "SELECT $a.b$ x $a.b$",
        // Comments, strings and escapes every server reads alike: a statement after them is still a second statement.
        "SELECT 1 # c\n; DROP TABLE t",
        "SELECT 1 #\t; DROP TABLE t",
        "SELECT 1 /* a /* b */ c */; ALTER TABLE t DELETE WHERE 1",
        "SELECT 1 -- c\n; INSERT INTO t VALUES (1)",
        "SELECT 'a\\\\'; DROP TABLE t",
        "SELECT `a\\\\`; DROP TABLE t",
        "SELECT $t$ x $t$; INSERT INTO t VALUES (1)",
        // Review: `//` is a line comment on every server; 1.2.0 read two `/` and a fake string after them.
        "SELECT 1 //'\n, file('/etc/passwd') --'",
        "SELECT 1 //'\nSETTINGS max_threads = 1 --'",
        "SELECT * FROM numbers(1) //'\n, url('http://169.254.169.254/') --'",
        "SELECT 1 //\n; DROP TABLE t",
        // Review: servers skip U+FEFF, U+00A0, U+200B, … as whitespace; 1.2.0 glued them to the next word.
        "SELECT 1,\u{FEFF}file('/etc/passwd')",
        "SELECT * FROM\u{A0}url('http://169.254.169.254/', 'RawBLOB')",
        "SELECT * FROM numbers(1),\u{200B}remote('h', system.one)",
        "SELECT 1\u{2060}SETTINGS max_threads = 1",
        "SELECT 1 FROM\u{3000}someFutureExternalSource('x')",
        "SELECT 1,\u{200E}file('x')",
        "SELECT 1,\u{85}file('x')",
        "SELECT 1,\u{1F}file('x')",
        "SELECT 1,\u{E0020}file('x')",
        // Review #3: after a dot servers read digits and word characters only, so a sign is an operator.
        "SELECT t.1e-file('nonexistent.txt') FROM (SELECT 1 AS `1e`) AS t",
        "SELECT t.1e+file('nonexistent.txt') FROM (SELECT 1 AS `1e`) AS t",
        "SELECT t . 12abc-file('x') FROM t",
        "SELECT t./**/0x1p-url('http://x') FROM t",
        "SELECT 0b.5e-file('x')",
        "SELECT 1e-file('x')",
        "SELECT 1, .5e-file('x')",
        "SELECT 1, .5e+settings",
        "SELECT 1e2; DROP TABLE t",
        "SELECT 0x.5; DROP TABLE t",
        "SELECT 1 /* open; DROP TABLE t",
    ])
    func refused(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql.debugDescription)")
    }

    /// The same constructs where every server reads only one harmless statement (pinned against servers by the
    /// integration suite): allowed.
    @Test(arguments: [
        "SELECT 1 -- c\r; DROP TABLE t",
        "SELECT 'a\\'; DROP TABLE t; --'",
        "SELECT $a$; DROP TABLE t; $a$",
        "SELECT $$; DROP TABLE t; $$",
        "SELECT 1 /* /* */ ; DROP TABLE t */",
        "SELECT 1, .5",
        "SELECT 1.5e3",
        "SELECT 4 //2\n",
        "SELECT 'a\u{A0}b\u{FEFF}', `c\u{200B}d`",
        "SELECT 1 -- 查询\u{3000}说明",
        "SELECT 1 /* \u{FEFF} */",
        "SELECT t.1e FROM (SELECT 1 AS `1e`) AS t",
        "SELECT 1e-5, 1_000, 0x1F, x.1.2",
    ])
    func allowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql.debugDescription) → \(ReadOnlySQLGuard.check(sql) ?? "")")
    }
}

@Suite("Read-only editor batches")
struct ReadOnlyBatchTests {
    @Test func editorBatchesOnReadOnlyConnectionsUseTheGuard() {
        #expect(ReadOnlySQLGuard.firstRefusal(in: ["USE shop", "SELECT 1", "SHOW TABLES"]) == nil)
        #expect(ReadOnlySQLGuard.firstRefusal(in: ["SELECT 1", "SELECT * FROM url('http://127.0.0.1:18199/x', CSV)"])?.sql.hasPrefix("SELECT * FROM url") == true)
        #expect(ReadOnlySQLGuard.firstRefusal(in: ["SET max_threads = 1"]) != nil)
        #expect(ReadOnlySQLGuard.firstRefusal(in: ["SELECT 1 SETTINGS readonly = 0"]) != nil)
        #expect(ReadOnlySQLGuard.firstRefusal(in: ["SELECT 1", "TRUNCATE TABLE t"])?.sql == "TRUNCATE TABLE t")
    }
}

@Suite("Settings and format as column names")
struct ClauseLookalikeTests {
    @Test func autoLimitLeavesColumnsNamedSettingsOrFormatAlone() {
        #expect(AutoLimit.apply(to: "SELECT query, Settings FROM system.query_log", limit: 201).sql
            == "SELECT query, Settings FROM system.query_log LIMIT 201")
        #expect(AutoLimit.apply(to: "SELECT format, count() FROM files GROUP BY format", limit: 201).sql
            == "SELECT format, count() FROM files GROUP BY format LIMIT 201")
        #expect(AutoLimit.apply(to: "SELECT t.settings FROM t", limit: 201).sql == "SELECT t.settings FROM t LIMIT 201")
        #expect(AutoLimit.apply(to: "SELECT Settings['max_threads'] FROM system.query_log WHERE Settings['x'] = '1'", limit: 5).sql
            == "SELECT Settings['max_threads'] FROM system.query_log WHERE Settings['x'] = '1' LIMIT 5")
        // Real clauses still get the limit in front of them.
        #expect(AutoLimit.apply(to: "SELECT Settings FROM system.query_log SETTINGS max_threads = 1", limit: 5).sql
            == "SELECT Settings FROM system.query_log LIMIT 5 SETTINGS max_threads = 1")
        #expect(AutoLimit.apply(to: "SELECT format FROM files FORMAT JSONEachRow", limit: 5).sql
            == "SELECT format FROM files LIMIT 5 FORMAT JSONEachRow")
        #expect(AutoLimit.apply(to: "SELECT 1 FORMAT Template SETTINGS format_template_row = 'r'", limit: 5).sql
            == "SELECT 1 LIMIT 5 FORMAT Template SETTINGS format_template_row = 'r'")
        #expect(AutoLimit.apply(to: "SELECT 1 SETTINGS `max_threads` = 1", limit: 5).sql == "SELECT 1 LIMIT 5 SETTINGS `max_threads` = 1")
        #expect(AutoLimit.apply(to: "SELECT 1 SETTINGS limit = 3", limit: 5).sql == "SELECT 1 LIMIT 5 SETTINGS limit = 3")
    }

    @Test func autoLimitSkipsQueriesWithAnOffsetClause() {
        #expect(AutoLimit.apply(to: "SELECT * FROM t OFFSET 10", limit: 201).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t ORDER BY k OFFSET 10 ROWS", limit: 201).applied == false)
        #expect(AutoLimit.apply(to: "SELECT offset FROM t", limit: 201).sql == "SELECT offset FROM t LIMIT 201")
    }

    @Test func readOnlyGuardAllowsColumnsNamedSettings() {
        #expect(ReadOnlySQLGuard.check("SELECT query, Settings FROM system.query_log") == nil)
        #expect(ReadOnlySQLGuard.check("SELECT Settings['max_threads'] AS t FROM system.query_log") == nil)
        #expect(ReadOnlySQLGuard.check("SELECT mapKeys(Settings), Settings AS s FROM system.query_log ORDER BY event_time DESC") == nil)
        #expect(ReadOnlySQLGuard.check("SELECT l.settings FROM system.query_log AS l") == nil)
    }

    @Test(arguments: [
        "SELECT 1 SETTINGS readonly = 0",
        "SELECT 1 SETTINGS readonly=0",
        "SELECT 1 settings `readonly` = 0",
        "SELECT * FROM t SETTINGS max_execution_time = 0, max_result_rows = 0",
        "SELECT Settings FROM system.query_log SETTINGS readonly = 0",
        "SELECT 1 SETTINGS limit = 0",
        "SELECT 1 SETTINGS a.b = 1",
        "SELECT * FROM (SELECT 1 SETTINGS readonly = 0)",
        "SELECT Settings = map() FROM system.query_log",
    ])
    func readOnlyGuardStillRefusesSettingsClauses(_ sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }
}

@Suite("Error positions after auto-LIMIT")
struct AutoLimitOffsetMappingTests {
    @Test func errorOffsetsMapBackToTheOriginalText() {
        let original = "SELECT * FROM t WHERE x = 1 SETTINGS max_threads = 1"
        let outcome = AutoLimit.apply(to: original, limit: 1000)
        #expect(outcome.sql == "SELECT * FROM t WHERE x = 1 LIMIT 1000 SETTINGS max_threads = 1")
        let executed = outcome.sql as NSString
        // A position after the insertion (the SETTINGS keyword) maps back to the same token.
        let settingsInExecuted = executed.range(of: "SETTINGS").location
        let settingsInOriginal = (original as NSString).range(of: "SETTINGS").location
        #expect(outcome.originalOffset(ofExecuted: settingsInExecuted) == settingsInOriginal)
        // Before the insertion nothing moves; inside it maps to the insertion point.
        #expect(outcome.originalOffset(ofExecuted: 7) == 7)
        #expect(outcome.originalOffset(ofExecuted: executed.range(of: "1000").location) == settingsInOriginal)
        #expect(AutoLimit.Outcome(sql: original, applied: false).originalOffset(ofExecuted: 12) == 12)
    }
}

@Suite("Redaction of connection strings, extra auth methods and error text")
struct RedactionGapTests {
    @Test(arguments: [
        ("SELECT * FROM azureBlobStorage('DefaultEndpointsProtocol=https;AccountName=a;AccountKey=AZSECRET==;EndpointSuffix=core.windows.net', 'c', 'b')", "AZSECRET"),
        ("SELECT * FROM azureBlobStorage('BlobEndpoint=https://a.blob.core.windows.net/;SharedAccessSignature=sv=2022&sig=SASSECRET', 'c', 'b')", "SASSECRET"),
        ("CREATE USER u IDENTIFIED WITH plaintext_password BY 'FIRSTSECRET', sha256_password BY 'SECONDSECRET'", "SECONDSECRET"),
        ("CREATE USER u IDENTIFIED WITH plaintext_password BY 'FIRSTSECRET', sha256_password BY 'SECONDSECRET'", "FIRSTSECRET"),
        ("ALTER USER u ADD IDENTIFIED WITH bcrypt_password BY 'BCRYPTSECRET'", "BCRYPTSECRET"),
        ("SELECT * FROM jdbc('jdbc:mysql://h:3306/db?user=u&password=JDBCSECRET', 't')", "JDBCSECRET"),
        ("SELECT * FROM odbc('DSN=x;UID=u;PWD=ODBCSECRET', 'db', 't')", "ODBCSECRET"),
        ("SELECT * FROM url('https://h/x.csv?access_token=URLSECRET', CSV)", "URLSECRET"),
        ("SELECT * FROM url('https://h/x.csv?X-Amz-Signature=AMZSECRET&X-Amz-Credential=AKIA', CSV)", "AMZSECRET"),
    ])
    func secretsAreMasked(sql: String, secret: String) {
        let redacted = SQLRedactor.redact(sql)
        #expect(!redacted.contains(secret), "\(redacted)")
    }

    @Test func harmlessTextIsKept() {
        #expect(SQLRedactor.redact("SELECT * FROM url('https://h/x.csv?format=csv&user=bob', CSV)") == "SELECT * FROM url('https://h/x.csv?format=csv&user=bob', CSV)")
        #expect(SQLRedactor.redact("SELECT 'config=1', 'design=2'") == "SELECT 'config=1', 'design=2'")
    }

    @Test(arguments: [
        ("Syntax error: failed at position 40 ('SYNTAXSECRET') (line 1, col 40): 'SYNTAXSECRET', sha256_password BY 'OTHER'. Expected one of: token", "SYNTAXSECRET"),
        ("Syntax error: failed at position 40 ('SYNTAXSECRET') (line 1, col 40): 'SYNTAXSECRET', sha256_password BY 'OTHER'. Expected one of: token", "OTHER"),
        ("Code: 499. DB::Exception: Access denied. While processing s3('https://b.s3.amazonaws.com/x.csv', 'AKIAEXAMPLE', 'S3SECRET')", "S3SECRET"),
        ("Cannot connect: DefaultEndpointsProtocol=https;AccountName=a;AccountKey=MSGSECRET;EndpointSuffix=x", "MSGSECRET"),
        ("Poco::Exception. https://user:URLPASS@host/x failed", "URLPASS"),
    ])
    func errorMessagesAreRedacted(message: String, secret: String) {
        let redacted = SQLRedactor.redactMessage(message)
        #expect(!redacted.contains(secret), "\(redacted)")
    }

    @Test func errorMessagesKeepTheirMeaning() {
        let message = "Syntax error: failed at position 40 ('x') (line 1, col 40): x. Expected one of: token, identifier"
        let redacted = SQLRedactor.redactMessage(message)
        #expect(redacted.contains("failed at position 40"))
        #expect(redacted.contains("Expected one of: token, identifier"))
        #expect(SQLRedactor.redactMessage("Table default.t doesn't exist. (UNKNOWN_TABLE)") == "Table default.t doesn't exist. (UNKNOWN_TABLE)")
    }
}

/// The lexer must split and classify like ClickHouse's own lexer (src/Parsers/Lexer.cpp), or the app
/// and the server see different statements.
@Suite("Lexer agrees with ClickHouse on heredocs and comments")
struct LexerParityTests {
    func kinds(_ sql: String) -> [(SQLToken.Kind, String)] {
        let lexer = SQLLexer(sql)
        return lexer.tokens().map { ($0.kind, lexer.text(of: $0)) }
    }

    @Test func unterminatedHeredocIsABareWord() {
        // ClickHouse: no closing `$a$`, so `$a$` is a bare word and `;` ends the statement.
        let statements = SQLStatementSplitter.split("SELECT 1 AS $a$; DROP TABLE t")
        #expect(statements.count == 2)
        #expect(ReadOnlySQLGuard.check("SELECT 1 AS $a$; DROP TABLE t") != nil)
        #expect(SQLStatementKind.of("SELECT 1 AS $a$; DROP TABLE t") == .query, "the first statement")
        #expect(kinds("SELECT 1 AS $a$").contains { $0 == (.identifier, "$a$") })
        #expect(SQLStatementSplitter.split("SELECT $$ open; SELECT 2").count == 2)
    }

    @Test func heredocTagsMatchClickHouse() {
        // Any text up to the next `$` is the tag; `$1$ … $1$` is a heredoc too.
        #expect(kinds("SELECT $1$ x; y $1$").contains { $0 == (.string, "$1$ x; y $1$") })
        #expect(kinds("SELECT $a b$ x $a b$").contains { $0 == (.string, "$a b$ x $a b$") })
        // A lone `$` before a non-word character is the dollar sign.
        #expect(kinds("SELECT $ 1").contains { $0 == (.operator, "$") })
        #expect(kinds("SELECT $1").contains { $0 == (.identifier, "$1") })
    }

    @Test func commentsEndLikeClickHouse() {
        // `--` comments run to `\n` only: a lone `\r` does not end them.
        #expect(SQLStatementSplitter.split("SELECT 1 -- note\r; DROP TABLE t").count == 1)
        #expect(SQLStatementSplitter.split("SELECT 1 -- note\n; DROP TABLE t").count == 2)
        // `#` starts a comment only before a space or `!`.
        #expect(!kinds("SELECT 1 #\tx").contains { $0.0 == .comment })
        #expect(!kinds("SELECT 1 #").contains { $0.0 == .comment })
        #expect(kinds("SELECT 1 # x").contains { $0 == (.comment, "# x") })
    }

    private func texts(_ sql: String) -> [String] { kinds(sql).map(\.1) }

    /// `//` starts a line comment on every server (22.8, 24.8, 26.8), up to `\n` only, even right after a number.
    @Test func doubleSlashIsALineComment() {
        #expect(texts("SELECT 1 // c\n, 2") == ["SELECT", "1", "// c", ",", "2"])
        #expect(texts("SELECT 4 //2\n") == ["SELECT", "4", "//2"])
        #expect(texts("SELECT 1//2") == ["SELECT", "1", "//2"])
        #expect(texts("SELECT 1 // c\r AS x") == ["SELECT", "1", "// c\r AS x"])
        #expect(texts("SELECT '//' AS x") == ["SELECT", "'//'", "AS", "x"])
        #expect(texts("SELECT 4 / 2") == ["SELECT", "4", "/", "2"])
        let lexer = SQLLexer("SELECT 1 // open")
        #expect(lexer.tokens().last.map(lexer.isUnterminated) == false, "a line comment is never unterminated")
        #expect(SQLStatementSplitter.split("SELECT 1 // ; DROP TABLE t").count == 1)
    }

    /// The whitespace servers skip besides ASCII (U+00A0, U+FEFF, U+200B, …; every code point is checked against the
    /// servers by `FormatterIntegrationTests`) separates tokens; other non-ASCII stays part of a word.
    @Test func unicodeWhitespaceSeparatesTokens() {
        #expect(texts("SELECT\u{A0}1,\u{FEFF}file(") == ["SELECT", "1", ",", "file", "("])
        #expect(texts("a\u{200B}b\u{3000}c\u{2028}d\u{85}e") == ["a", "b", "c", "d", "e"])
        #expect(texts("aéb x\u{200E}y") == ["aéb", "x\u{200E}y"], "U+200E is a format character servers reject, not whitespace")
        #expect(texts("'a\u{A0}b'") == ["'a\u{A0}b'"])
    }

    /// Numbers end where ClickHouse's lexer ends them (probed on 22.8, 24.8 and 26.8; re-checked by
    /// `FormatterIntegrationTests`). Where versions differ, the longer token is taken (and Format SQL refuses the text).
    @Test func numbersEndLikeClickHouse() {
        // A number runs on through word characters: a name (`1abc`, `1e2x`, `0x1g`) or a malformed number (`1.5x`).
        for word in ["1.5x", "1e2x", "1abc", "0x1g", "0b102", "1_000", "1.end", "1inf", "1e+5x", "1.5e3x", "08", "1__0", "1ex"] {
            #expect(texts(word) == [word], "\(word)")
        }
        #expect(kinds("1e2x").map { "\($0.0)" } == ["number"])
        // Literal shapes: fractions, exponents with signs, hexadecimal floats, separators.
        for literal in ["1.", "1.e5", "1.e+2", "08.5", "0x1.8p1", "0x1p3", "0x1.", "0x1_f", "1e1_0", "1_000.5", "1e-5"] {
            #expect(texts(literal) == [literal], "\(literal)")
        }
        // Version-dependent prefixes take the longer (22.8) reading: one token.
        #expect(texts("0x.5") == ["0x.5"])
        #expect(texts("0b2.5") == ["0b2.5"])
        // A hexadecimal number's exponent is `p`: `e` is a digit, and a `+` after it is an operator.
        #expect(texts("0x1e+2x") == ["0x1e", "+", "2x"])
        // An exponent takes its sign only with digits after it (servers would take `1e-x` whole, as a malformed number:
        // `uncertainToken` refuses such text in the guard and Format SQL).
        #expect(texts("1e-x") == ["1e", "-", "x"])
        #expect(texts("1e+") == ["1e", "+"])
        #expect(texts("1.5e-x") == ["1.5e", "-", "x"])
        #expect(texts("0x1p-x") == ["0x1p", "-", "x"])
        // Word characters end at `$` and at non-ASCII letters.
        #expect(texts("1a$b") == ["1a", "$b"])
        #expect(texts("1é") == ["1", "é"])
    }

    /// `.` followed by a digit is a dot (tuple access) after a name, a number, `)` or `]` — counting the token before
    /// it across whitespace and comments, as ClickHouse does — and starts a number elsewhere. A number that starts
    /// with `.` takes no word characters after it: `.5x` is `.5` and `x`.
    @Test func dotsAndNumbersLikeClickHouse() {
        #expect(texts("1.2.3") == ["1.2", ".", "3"])
        #expect(texts("1..2") == ["1.", ".", "2"])
        #expect(texts("x .5") == ["x", ".", "5"])
        #expect(texts("(1, 2) .1") == ["(", "1", ",", "2", ")", ".", "1"])
        #expect(texts("t./*c*/1") == ["t", ".", "/*c*/", "1"])
        #expect(texts("t /*c*/ .1") == ["t", "/*c*/", ".", "1"])
        #expect(texts("(1,2)--c\n.1") == ["(", "1", ",", "2", ")", "--c", ".", "1"])
        #expect(texts("SELECT .5") == ["SELECT", ".", "5"], "a dot after a word, even a keyword")
        #expect(texts("1 .5") == ["1", ".", "5"])
        #expect(texts(".5") == [".5"])
        #expect(texts("(.5)") == ["(", ".5", ")"])
        #expect(texts("1+.5, .5e2") == ["1", "+", ".5", ",", ".5e2"])
        #expect(texts("'a'.1") == ["'a'", ".1"])
        #expect(texts("{p:UInt8}.1") == ["{p:UInt8}", ".1"])
        #expect(texts("(.5x)") == ["(", ".5", "x", ")"])
        #expect(texts("(.5end)") == ["(", ".5e", "nd", ")"])
        #expect(texts("(.5e+x)") == ["(", ".5e", "+", "x", ")"])
        #expect(texts("(.5_1)") == ["(", ".5_1", ")"])
    }

    /// Review #3: after a dot every server reads a digit-led token as digits and word characters only — no fraction,
    /// no exponent sign (`t.1e-x` is `t.1e` minus `x`; `x.1.2` is chained tuple access), across whitespace and comments.
    @Test func digitsAfterADotAreANamePart() {
        #expect(texts("t.1e-file(") == ["t", ".", "1e", "-", "file", "("])
        #expect(texts("t . 1e+x") == ["t", ".", "1e", "+", "x"])
        #expect(texts("t./**/12abc-x") == ["t", ".", "/**/", "12abc", "-", "x"])
        #expect(texts("t.0x1p-x") == ["t", ".", "0x1p", "-", "x"])
        #expect(texts("t.1_0e-x") == ["t", ".", "1_0e", "-", "x"])
        #expect(texts("x.1.2") == ["x", ".", "1", ".", "2"])
        #expect(texts("x.1e2x") == ["x", ".", "1e2x"])
    }

    /// Review #6: heredoc closings are found in one pass. The index finds exactly what a scan from each `$` finds (the
    /// tag runs to the next `$`; the heredoc ends after the next `$tag$`), on random `$`-heavy text.
    @Test func heredocIndexMatchesAScan() {
        func scanEnd(_ units: [UInt16], from index: Int) -> Int? {
            var tagEnd = index + 1
            while tagEnd < units.count, units[tagEnd] != 0x24 { tagEnd += 1 }
            guard tagEnd < units.count else { return nil }
            let length = tagEnd + 1 - index
            var position = tagEnd + 1
            while position + length <= units.count {
                if units[position] == 0x24, (1..<length).allSatisfy({ units[position + $0] == units[index + $0] }) { return position + length }
                position += 1
            }
            return nil
        }
        var generator = SplitMix64(seed: 6)
        let alphabet = Array("$$$ab1 _".utf16)
        for _ in 0..<3_000 {
            let units = (0..<Int(generator.next() % 30)).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }
            let text = String(decoding: units, as: UTF16.self)
            let lexer = SQLLexer(text)
            for token in lexer.tokens() where units[token.range.lowerBound] == 0x24 {
                let expected = scanEnd(units, from: token.range.lowerBound)
                if token.kind == .string {
                    #expect(token.range.upperBound == expected, "\(text.debugDescription)")
                } else {
                    #expect(expected == nil, "\(text.debugDescription): a heredoc missed")
                }
            }
        }
    }

    /// Review #6: `$0 + $1 + …` (no tag ever closes) is linear: 1.2.0 took 8.8 s at 349 KB, rescanning to the end from
    /// every `$`, and froze highlighting on every keystroke.
    @Test func manyUnclosedDollarsStayLinear() {
        let text = "select " + (0..<40_000).map { "$\($0)" }.joined(separator: " + ")
        #expect(text.utf16.count > 300_000)
        let started = SQLFormatterTests.threadCPUTime()
        let tokens = SQLLexer.tokenize(text)
        _ = SQLLinter.diagnose(text)
        _ = SQLStatementSplitter.split(text)
        _ = ReadOnlySQLGuard.check(text)
        #expect(SQLFormatterTests.threadCPUTime() - started < .seconds(5), "debug-build bound")
        #expect(tokens.count > 79_000)
    }

    /// Tokens whose range a supported server could read differently: the read-only guard refuses them.
    @Test func uncertainTokens() {
        func uncertain(_ sql: String) -> String? {
            let lexer = SQLLexer(sql)
            return lexer.uncertainToken(in: lexer.tokens()).map(lexer.text(of:))
        }
        #expect(uncertain("SELECT 1e-x") == "1e")
        #expect(uncertain("SELECT 1, .5e+x") == ".5e")
        #expect(uncertain("SELECT .5e+x") == nil, "after SELECT the dot is a dot, as on every server: `5e` is a name part")
        #expect(uncertain("SELECT 0x1p-x") == "0x1p")
        #expect(uncertain("SELECT 1_000.5") == "1_000.5")
        #expect(uncertain("SELECT 0x.5") == "0x.5")
        #expect(uncertain("SELECT $a b$ x $a b$") == "$a b$ x $a b$")
        for sql in ["SELECT 1e-5", "SELECT 1_000", "SELECT 0xg", "SELECT t.1e-x", "SELECT 1e - x", "SELECT 1abe-x", "SELECT 0x1e-x", "SELECT 1e2"] {
            #expect(uncertain(sql) == nil, "\(sql)")
        }
    }

    /// The shared lexer folds words with Unicode upper-casing, so the read-only guard treats `ſettings` like SETTINGS
    /// (stricter; ClickHouse itself rejects such words). Format SQL matches keywords on ASCII only (its own tests).
    @Test func keywordFoldingStaysStrictForTheGuard() {
        #expect(kinds("ﬁrst first ſelect x").map { "\($0.0)" } == ["keyword", "keyword", "keyword", "identifier"])
        #expect(ReadOnlySQLGuard.check("SELECT 1 ſettings max_threads = 1") != nil)
    }
}
