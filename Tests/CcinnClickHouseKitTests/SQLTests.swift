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
        #expect(AutoLimit.apply(to: "SELECT * FROM t", limit: 100) == .init(sql: "SELECT * FROM t\nLIMIT 100", applied: true, insertion: 15..<25))
        #expect(AutoLimit.apply(to: "SELECT * FROM t -- note", limit: 100).sql == "SELECT * FROM t\nLIMIT 100 -- note")
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 5", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 5 OFFSET 10", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 10 WITH TIES", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 1 BY k", limit: 100).sql == "SELECT * FROM t LIMIT 1 BY k\nLIMIT 100")
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 1 BY k LIMIT 3", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t SETTINGS max_threads = 1", limit: 100).sql == "SELECT * FROM t\nLIMIT 100 SETTINGS max_threads = 1")
        #expect(AutoLimit.apply(to: "SELECT * FROM t FORMAT JSON", limit: 100).sql == "SELECT * FROM t\nLIMIT 100 FORMAT JSON")
        #expect(AutoLimit.apply(to: "SELECT TOP 5 * FROM t", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT 1 UNION ALL SELECT 2", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM (SELECT * FROM t LIMIT 5)", limit: 100).applied == true)
        #expect(AutoLimit.apply(to: "WITH x AS (SELECT 1 LIMIT 1) SELECT * FROM x", limit: 10).sql == "WITH x AS (SELECT 1 LIMIT 1) SELECT * FROM x\nLIMIT 10")
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

/// Review: client-side rewrites. AutoLimit used to insert ` LIMIT n` after a bare `#` (which then became a `# ` comment
/// hiding the `/*` the guard had trusted) or after a lone `$` (which then opened a heredoc whose tag held the inserted
/// text). The guard now checks the exact text sent, refuses bare `#` and lone `$`, and AutoLimit starts a new line.
@Suite("Read-only guard: the text sent is the text checked")
struct GuardedWireTextTests {
    static let repros = [
        "SELECT 1 #/*\n, file('nonexistent.txt') -- */",
        "SELECT 1 #FORMAT TSV /*\n, file('nonexistent.txt') -- */",
        "SELECT 1, $/*Q$ $ LIMIT 101/*Q$, file('nonexistent.txt') -- */ */",
        "SELECT 1, $/*Q$ $ LIMIT 1001/*Q$, file('nonexistent.txt') -- */ */",
        "SELECT 1, $/*Q$ $\nLIMIT 101/*Q$, file('nonexistent.txt') -- */ */",
        "SELECT 1, $/*Q$ $\nLIMIT 101\n/*Q$, file('nonexistent.txt') -- */ */",
    ]

    /// Both repros, as MCP run_query (LIMIT `limit + 1`), MCP explain (an EXPLAIN prefix) and the editor (its auto-limit)
    /// would send them: refused, whatever AutoLimit would make of them.
    @Test(arguments: repros)
    func reprosAreRefusedOnEveryPath(sql: String) {
        for limit in [101, 201, 1001, 5000] {
            #expect(throws: ReadOnlySQLGuard.Refusal.self, "\(sql.debugDescription) LIMIT \(limit)") {
                try ReadOnlySQLGuard.prepare(sql, autoLimit: limit).get()
            }
            #expect(throws: ReadOnlySQLGuard.Refusal.self) {
                try ReadOnlySQLGuard.prepare(sql, autoLimit: limit, audience: .ai(database: nil)).get()
            }
        }
        #expect(throws: ReadOnlySQLGuard.Refusal.self) {
            try ReadOnlySQLGuard.prepare(sql, prefix: "EXPLAIN", audience: .ai(database: nil)).get()
        }
        #expect(ReadOnlySQLGuard.check(sql) != nil)
    }

    /// What the guard checks is exactly what is sent: the text with the automatic LIMIT on its own line.
    @Test func theCheckedTextIsTheSentText() throws {
        let prepared = try ReadOnlySQLGuard.prepare("SELECT * FROM t -- note", autoLimit: 101).get()
        #expect(prepared.text == "SELECT * FROM t\nLIMIT 101 -- note")
        #expect(prepared.limit?.applied == true)
        #expect(ReadOnlySQLGuard.check(prepared.text) == nil)
        let explained = try ReadOnlySQLGuard.prepare("SELECT 1", prefix: "EXPLAIN indexes = 1").get()
        #expect(explained.text == "EXPLAIN indexes = 1 SELECT 1")
        #expect(explained.limit == nil)
        let unlimited = try ReadOnlySQLGuard.prepare("SHOW TABLES", autoLimit: 101).get()
        #expect(unlimited.text == "SHOW TABLES")
        // A real `# ` comment stays a comment: the LIMIT goes on the line before it.
        #expect(try ReadOnlySQLGuard.prepare("SELECT 1 # c", autoLimit: 101).get().text == "SELECT 1\nLIMIT 101 # c")
    }

    /// Review: `USE db` on a read-only connection goes through the same checkpoint (ClickHouse allows it at readonly=1;
    /// it only switches the session's database): exactly `USE <name>`, comments allowed, no LIMIT or EXPLAIN head, and
    /// the lexical checks on the exact text. AI access has no sessions, so it still refuses USE.
    @Test func useGoesThroughTheCheckpoint() throws {
        for sql in ["USE shop", "use shop /* switch */", "USE `x y`", "USE \"x\" -- note", "USE system", "USE default\n"] {
            #expect(try ReadOnlySQLGuard.prepare(sql, autoLimit: 1_000).get().text == sql, "\(sql.debugDescription)")
            #expect(throws: ReadOnlySQLGuard.Refusal.self, "AI: \(sql)") {
                try ReadOnlySQLGuard.prepare(sql, audience: .ai(database: nil)).get()
            }
        }
        for sql in ["USE", "USE shop DROP", "USE a.b", "USE shop, other", "USE #x", "USE $", "USE \u{FEFF}shop", "USE 'shop'", "USE shop /* open",
                    "USE $a b$ x $a b$", "USE (shop)", "USE shop SETTINGS readonly = 0"] {
            #expect(throws: ReadOnlySQLGuard.Refusal.self, "\(sql.debugDescription)") { try ReadOnlySQLGuard.prepare(sql, autoLimit: 1_000).get() }
        }
        #expect(throws: ReadOnlySQLGuard.Refusal.self) { try ReadOnlySQLGuard.prepare("USE shop", prefix: "EXPLAIN").get() }
    }

    /// A `#` that does not start a comment (no space or `!` after it) and a `$` that opens nothing change meaning with
    /// whatever follows: refused anywhere outside strings, quoted names and comments.
    @Test func bareHashAndLoneDollarAreRefused() {
        for sql in ["SELECT 1 #", "SELECT 1 #x", "SELECT 1 #/**/", "SELECT $", "SELECT $ 1", "SELECT 1, $/* $ */", "SELECT 1 + $"] {
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql.debugDescription)")
        }
        for sql in ["SELECT 1 # comment", "SELECT 1 #! shebang", "SELECT '#', '$', `#$`", "SELECT 1 -- # $", "SELECT $a$x$a$", "SELECT $$x$$", "SELECT a$b FROM t",
                    "SELECT $1"] {
            #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql.debugDescription) → \(ReadOnlySQLGuard.check(sql) ?? "")")
        }
    }

    /// AutoLimit puts its clause on a line of its own, so no comment before it can absorb it and it can never start one.
    @Test func autoLimitStartsANewLine() {
        #expect(AutoLimit.apply(to: "SELECT 1 # c", limit: 5).sql == "SELECT 1\nLIMIT 5 # c")
        #expect(AutoLimit.apply(to: "SELECT 1 FORMAT TSV", limit: 5).sql == "SELECT 1\nLIMIT 5 FORMAT TSV")
        #expect(AutoLimit.apply(to: "SELECT 1 /* c */\nFORMAT TSV", limit: 5).sql == "SELECT 1\nLIMIT 5 /* c */\nFORMAT TSV")
    }

    /// Review: for AI access the guard reads `system` through an ALLOW-LIST (schema browsing and diagnostics; no other
    /// sessions' SQL text, no credentials), and table functions through one too. Every other `system` source is refused
    /// in any form: qualified, bare, as the session database, renamed (`query_log_0`), through `loop`/`merge`/`cluster`
    /// or any other table function, and in SHOW. The editor (people) keeps them.
    @Test func aiAccessReadsSystemThroughAnAllowList() {
        let ai = ReadOnlySQLGuard.Audience.ai(database: nil)
        for sql in ["SELECT query FROM system.query_log", "SELECT * FROM `system`.`processes`", "SELECT * FROM system.QUERY_THREAD_LOG",
                    "SELECT command FROM system.mutations", "SELECT * FROM system.query_log_0", "SELECT name, auth_type FROM system.users",
                    "SELECT * FROM system.named_collections", "SELECT * FROM system.settings_profile_elements", "SELECT * FROM system.dictionaries",
                    "SELECT * FROM loop(system, query_log)", "SELECT * FROM loop('system', 'query_log')", "SELECT * FROM merge('shop', '^e')",
                    "SELECT * FROM merge(REGEXP('^s'), '^query')", "SELECT * FROM clusterAllReplicas('c', system.query_log)",
                    "SELECT * FROM cluster('c', 'system', 'query_log')", "SELECT * FROM mergeTreeIndex('system', 'query_log')",
                    "SELECT * FROM numbers(1) JOIN loop(system, one) USING (number)", "SELECT * FROM dictionary('d')", "SHOW PROCESSLIST",
                    "SHOW USERS", "SHOW CREATE USER x", "SHOW ACCESS", "SHOW GRANTS FOR x", "SHOW TABLES FROM system", "SELECT system FROM t",
                    "SELECT x FROM (SELECT query AS x FROM system.asynchronous_insert_log)", "EXPLAIN SELECT * FROM system.query_log",
                    "DESCRIBE system.query_log", "SELECT * FROM someFutureTableFunction('system', 'query_log')"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "\(sql)")
        }
        // Unqualified names in the `system` database: refused (qualify them instead).
        #expect(ReadOnlySQLGuard.check("SELECT name FROM tables", audience: .ai(database: "system")) != nil)
        #expect(ReadOnlySQLGuard.check("SELECT * FROM PROCESSES", audience: .ai(database: "SYSTEM")) != nil)
        for sql in ["SELECT name, engine FROM system.tables WHERE database = 'shop'", "SELECT * FROM system.columns", "SELECT * FROM system.parts",
                    "SELECT * FROM system.merges", "SELECT * FROM system.replicas", "SELECT name FROM system.functions", "SELECT * FROM system.one",
                    "SELECT * FROM shop.query_log", "SELECT query_log FROM t", "SELECT number FROM numbers(10)", "SELECT * FROM generateRandom('a UInt8') LIMIT 1",
                    "SELECT * FROM view(SELECT 1)", "SELECT * FROM values('a UInt8', 1)", "SHOW TABLES FROM shop",
                    "SELECT count(*) FROM system.tables", "SELECT table_name FROM information_schema.tables", "SELECT a * b FROM shop.t"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql, audience: ai) ?? "")")
        }
        // The editor keeps all of these.
        for sql in ["SELECT query FROM system.query_log", "SELECT * FROM merge('shop', '^e')", "SHOW PROCESSLIST", "SELECT command FROM system.mutations"] {
            #expect(ReadOnlySQLGuard.check(sql) == nil, "editor: \(sql)")
        }
    }

    /// Review (deny by default): AI access never receives raw object definitions, on ANY version — 22.8 prints
    /// credentials in them, and 24.8 still prints credentials inside URLs (`url('http://user:secret@…')` in a view).
    /// Definition columns are refused with any qualifier, alias or quoting; SHOW CREATE of any kind; and any `*` but
    /// `count(*)` in a query that reads system.tables / databases / functions or information_schema.
    @Test func aiAccessNeverReadsDefinitions() {
        let ai = ReadOnlySQLGuard.Audience.ai(database: nil)
        for sql in ["SELECT create_table_query FROM system.tables", "SELECT t.create_table_query FROM system.tables AS t",
                    "SELECT tables.engine_full FROM system.tables", "SELECT \"as_select\" AS a FROM system.tables", "SELECT `engine_full` FROM system.databases",
                    "SELECT create_query FROM system.functions", "SELECT view_definition FROM information_schema.views",
                    "SELECT VIEW_DEFINITION FROM INFORMATION_SCHEMA.VIEWS", "SELECT * FROM system.tables", "SELECT t.* FROM system.tables AS t",
                    "SELECT tuple(*) FROM system.tables", "SELECT [*] FROM system.tables", "SELECT formatRow('TSV', *) FROM system.tables",
                    "SELECT * EXCEPT (name) FROM system.databases", "SELECT COLUMNS('.*') FROM system.tables", "SELECT * FROM system.functions",
                    "SELECT * FROM information_schema.views", "SELECT * FROM INFORMATION_SCHEMA.TABLES", "SHOW CREATE TABLE shop.events",
                    "SHOW CREATE DICTIONARY shop.d", "SHOW CREATE DATABASE shop", "SHOW CREATE shop.events", "SHOW CREATE VIEW shop.v",
                    "SELECT name FROM system.tables WHERE create_table_query LIKE '%x%'", "SELECT query FROM system.projections",
                    "SELECT p.query AS q FROM system.projections AS p", "SELECT * FROM system.projections", "SELECT `query` FROM `system`.`projections`"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "\(sql)")
        }
        #expect(ReadOnlySQLGuard.check("SELECT * FROM views", audience: .ai(database: "information_schema")) != nil)
        for sql in ["SELECT name, engine, sorting_key FROM system.tables", "SELECT count(*) FROM system.tables", "SELECT COUNT(*) FROM system.functions",
                    "SELECT * FROM system.columns", "SELECT name FROM system.databases", "SELECT * FROM shop.events", "SELECT total_rows * 2 FROM shop.t",
                    "SELECT name, type, sorting_key FROM system.projections", "SELECT query FROM shop.t"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql, audience: ai) ?? "")")
        }
        // The editor (people) keeps them.
        #expect(ReadOnlySQLGuard.check("SELECT create_table_query FROM system.tables") == nil)
    }

    /// Review: servers decode `\xHH` and `\N` inside quoted names (22.8, 24.8, 26.8 verified): `` `\x66ile`('x') `` calls
    /// file(), `` `\x73ystem`.query_log `` reads query_log. The guard refuses every backslash in a quoted name, in both
    /// audiences, instead of trusting a decoder to match every server version.
    @Test func escapedQuotedNamesAreRefused() {
        for sql in ["SELECT `\\x66ile`('x')", "SELECT \"\\x75rl\"('http://h/')", "SELECT count() FROM `\\x73ystem`.query_log",
                    "SELECT count() FROM `sys\\Ntem`.query_log", "SELECT `\\x63reate_table_query` FROM system.tables", "SELECT `a\\`b` FROM t"] {
            #expect(ReadOnlySQLGuard.check(sql) != nil, "editor: \(sql)")
            #expect(ReadOnlySQLGuard.check(sql, audience: .ai(database: nil)) != nil, "ai: \(sql)")
        }
        #expect(ReadOnlySQLGuard.check("SELECT `a``b`, \"c\"\"d\" FROM t WHERE s = 'x\\ny'") == nil, "doubled quotes and escapes in strings stay allowed")
    }

    /// Review (Unicode probe): ClickHouse does not fold `ı`, `ſ`, `İ`, `K` or `ﬁ`, but Swift's case mapping turns them
    /// into ASCII letters, so the guard read `` system.`ſettings` `` as `settings`. A name holding a letter whose upper,
    /// lower or title case contains an ASCII letter is refused, in both audiences.
    @Test func namesWithASCIIFoldingLettersAreRefused() {
        for sql in ["SELECT fıle('x')", "SELECT * FROM `ſystem`.processes", "SELECT * FROM system.`ſettings`", "SELECT ﬁle('x')",
                    "SELECT * FROM ſystem.query_log", "SELECT \"İd\" FROM t", "SELECT \"Größe\" FROM t", "SELECT 1 AS \u{212A}elvin"] {
            #expect(ReadOnlySQLGuard.check(sql) != nil, "editor: \(sql)")
            #expect(ReadOnlySQLGuard.check(sql, audience: .ai(database: nil)) != nil, "ai: \(sql)")
        }
        for sql in ["SELECT café, `名前`, \"Grün\" FROM shop.t", "SELECT 'ſ ı ﬁ in a string' AS s", "SELECT 1 -- ſystem"] {
            #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql) ?? "")")
        }
    }

    /// The refused letters are exactly those Unicode maps (upper, lower or title case) to text with an ASCII letter: 19.
    @Test func asciiFoldingLettersAreDerivedFromUnicode() {
        var derived: Set<Unicode.Scalar> = []
        for value in UInt32(0x80)...0x10FFFF {
            // A mapping that holds an ASCII letter differs from the letter itself: only case-changing scalars are mapped.
            guard let scalar = Unicode.Scalar(value), scalar.properties.changesWhenCaseMapped else { continue }
            let mappings = [scalar.properties.uppercaseMapping, scalar.properties.lowercaseMapping, scalar.properties.titlecaseMapping]
            if mappings.contains(where: { $0.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic } }) { derived.insert(scalar) }
        }
        #expect(derived == ReadOnlySQLGuard.asciiFoldingLetters)
        #expect(String(String.UnicodeScalarView(ReadOnlySQLGuard.asciiFoldingLetters.sorted { $0.value < $1.value })) == "ßİıŉſǰẖẗẘẙẚKﬀﬁﬂﬃﬄﬅﬆ")
    }

    /// Review: on 24.8+ `SHOW TABLE x` / `SHOW VIEW x` are SHOW CREATE, and SHOW FUNCTIONS returns SQL UDF bodies. AI
    /// access runs only the SHOW forms that list names or settings.
    @Test func aiShowIsAnAllowList() {
        let ai = ReadOnlySQLGuard.Audience.ai(database: nil)
        for sql in ["SHOW TABLE shop.v", "SHOW VIEW shop.v", "SHOW DICTIONARY shop.d", "SHOW DATABASE shop", "SHOW TEMPORARY TABLE t",
                    "SHOW FUNCTIONS", "SHOW FUNCTIONS LIKE 'f'", "SHOW SETTINGS PROFILES", "SHOW PROCESSLIST", "SHOW FULL PROCESSLIST",
                    "SHOW GRANTS", "SHOW ACCESS", "SHOW CURRENT ROLES", "SHOW CREATE TABLE t", "SHOW CREATE TEMPORARY TABLE t", "SHOW SOMETHINGNEW"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "\(sql)")
        }
        for sql in ["SHOW TABLES", "SHOW TABLES FROM shop LIKE 'e%'", "SHOW FULL TABLES FROM shop", "SHOW TEMPORARY TABLES", "SHOW DATABASES",
                    "SHOW DICTIONARIES FROM shop", "SHOW COLUMNS FROM shop.t", "SHOW EXTENDED FULL COLUMNS FROM t IN shop", "SHOW INDEX FROM shop.t",
                    "SHOW KEYS FROM shop.t", "SHOW ENGINES", "SHOW CLUSTERS", "SHOW CLUSTER c", "SHOW SETTINGS LIKE 'max%'", "SHOW CHANGED SETTINGS"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql, audience: ai) ?? "")")
        }
        #expect(ReadOnlySQLGuard.check("SHOW TABLE shop.v") == nil, "the editor keeps it")
    }

    /// Review: 22.8 and 24.8 inline each view's query into EXPLAIN SYNTAX, literals included; AI access runs only the
    /// EXPLAIN kinds that print plans (whose quoted strings are masked in the result) or its own query's AST.
    @Test func aiExplainKinds() {
        let ai = ReadOnlySQLGuard.Audience.ai(database: nil)
        for sql in ["EXPLAIN SYNTAX SELECT * FROM shop.v", "EXPLAIN QUERY TREE SELECT 1", "EXPLAIN QUERY TREE run_passes = 1 SELECT 1",
                    "EXPLAIN SYNTAX oneline = 1 SELECT 1", "SELECT * FROM (EXPLAIN SYNTAX SELECT * FROM shop.v)",
                    "WITH x AS (EXPLAIN SYNTAX SELECT * FROM shop.v) SELECT * FROM x", "SELECT * FROM (EXPLAIN actions = 1 SELECT * FROM shop.v)",
                    "SELECT * FROM viewExplain('EXPLAIN', '', (SELECT * FROM shop.v))"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "\(sql)")
        }
        if case .success = ReadOnlySQLGuard.prepare("SELECT * FROM shop.v", prefix: "EXPLAIN SYNTAX", audience: ai) {
            Issue.record("an EXPLAIN SYNTAX head must be refused too")
        }
        for sql in ["EXPLAIN SELECT 1", "EXPLAIN PLAN indexes = 1 SELECT * FROM shop.v", "EXPLAIN indexes = 1 SELECT 1", "EXPLAIN PIPELINE SELECT 1",
                    "EXPLAIN ESTIMATE SELECT * FROM shop.v", "EXPLAIN AST SELECT 1", "SELECT \"explain\", t.explain FROM shop.t AS t"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql, audience: ai) ?? "")")
        }
        #expect(ReadOnlySQLGuard.check("EXPLAIN SYNTAX SELECT 1") == nil, "the editor keeps it")
    }

    /// Results reach AI access in the tool's JSON, where they are masked: `FORMAT Parquet` would compress a plan's
    /// literals past the masking (verified on 24.8 and 26.8), so AI access sends no FORMAT clause.
    @Test func aiSendsNoFormatClause() {
        let ai = ReadOnlySQLGuard.Audience.ai(database: nil)
        for sql in ["SELECT 1 FORMAT Parquet", "EXPLAIN actions = 1 SELECT * FROM shop.v FORMAT JSON", "SELECT format FROM shop.t",
                    "SHOW TABLES FORMAT TSVRaw"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "\(sql)")
        }
        for sql in ["SELECT \"format\", t.format FROM shop.t AS t", "SELECT * FROM format(JSONEachRow, '{\"a\":1}')"] {
            #expect(ReadOnlySQLGuard.check(sql, audience: ai) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql, audience: ai) ?? "")")
        }
        #expect(ReadOnlySQLGuard.check("SELECT 1 FORMAT JSON") == nil, "the editor keeps it")
    }

    /// 26.8 prints view literals in plans (`Filter column: notEquals(toString(number), 'secret')`): every quoted string
    /// of an EXPLAIN result becomes `'?'` for AI access; numbers (granules, rows) stay.
    @Test func explainOutputHidesQuotedStrings() {
        let masked = SQLRedactor.maskStringLiterals("Filter column: notEquals(toString(number), 'zzwheresecret') (removed)\nGranules: 3/10")
        #expect(masked == "Filter column: notEquals(toString(number), '?') (removed)\nGranules: 3/10", "\(masked)")
        #expect(SQLRedactor.maskStringLiterals("a 'it''s' b 'x\\'y' c") == "a '?' b '?' c")
        #expect(SQLRedactor.maskStringLiterals("{\"Description\": \"equals(s, 'zzjsonsecret')\"}") == "{\"Description\": \"equals(s, '?')\"}")
        #expect(SQLRedactor.maskStringLiterals("tail 'zzopensecret") == "tail '?", "an unterminated quote masks to the end")
        #expect(SQLRedactor.maskStringLiterals("no quotes, 42") == "no quotes, 42")
    }

    /// Defence in depth: credentials in any text the AI tools return are masked, and counted (the tools report the
    /// count): URL passwords, credential-named `key=value` pairs and literals, and, in definition-like text, the
    /// credential arguments of table functions and engines.
    @Test(arguments: [
        ("CREATE VIEW v AS SELECT * FROM url('http://user:zzurlsecret@h/x', CSV) WHERE p = 'password=zzpairsecret'", 2),
        ("ENGINE = MySQL('h:3306', 'db', 't', 'u', 'zzmysqlsecret')", 2),
        ("CREATE TABLE t (a Int8) ENGINE = S3('https://b.s3/x.csv', 'AKIAKEY', 'zzs3secret', 'CSV')", 3),
        ("http://reader:zzurlpw@host:8123/?query=1", 1),
        ("Server=db;Uid=app;Pwd=zzpwd;", 1),
        ("https://acct.blob/c?sv=1&sig=zzsig&api_key=zzapikey", 2),
        ("kafka_sasl_password = 'zzkafkapw'", 1),
        ("CREATE USER u IDENTIFIED BY 'zzuserpw'", 1),
        ("password 'zzkwpw', token: 'zztokenpw'", 2),
    ])
    func returnedTextIsMasked(text: String, spans: Int) {
        let masked = SQLRedactor.maskSecrets(text)
        #expect(!masked.text.contains("zz"), "\(masked.text)")
        #expect(masked.count == spans, "\(masked.count) spans in \(masked.text)")
    }

    /// Review: the masker altered legitimate data. A user without a password, a bare KEY, an apostrophe, a name that only
    /// contains `auth`, and table-function calls stored as plain data stay as they are.
    @Test(arguments: ["ssh://git@github.com:22/x", "https://user@host/path", "http://host:8123/x@y", "PRIMARY KEY 'id'",
                      "It's John's KEY 'id' value", "s3('a','b','c')", "SELECT * FROM mysql('h', 'db', 't', 'u', 'p') -- example", "author = 'John'",
                      "keyboard=qwerty; monkey=1", "http://u:***@h/x", "password=***", "plain text, 42", "Create a new KEY 'x' now"])
    func legitimateDataIsNotMasked(text: String) {
        let masked = SQLRedactor.maskSecrets(text)
        #expect(masked.text == text && masked.count == 0, "\(text) → \(masked.text)")
    }
}

/// Review: tools that show other sessions' SQL (running queries, query log, mutations, DDL queue) replace EVERY string
/// and numeric literal with `?`, digest style, and drop comments: the raw sources are blocked for AI access because of
/// what literals hold, not only credentials.
@Suite("SQL digests")
struct SQLDigestTests {
    @Test func everyLiteralBecomesAPlaceholder() {
        #expect(SQLRedactor.digest("SELECT * FROM t WHERE card = '4111 1111 1111 1111' AND pin = 1234 AND x IN (1.5, -2e3, 0x1F)")
            == "SELECT * FROM t WHERE card = ? AND pin = ? AND x IN (?, -?, ?)")
        #expect(SQLRedactor.digest("ALTER TABLE t UPDATE note = 'my secret plan' WHERE id = 7") == "ALTER TABLE t UPDATE note = ? WHERE id = ?")
        #expect(SQLRedactor.digest("SELECT $$heredoc secret$$, x'41', `quoted name`, {p:String}") == "SELECT ?, x?, `quoted name`, {p:String}")
        #expect(SQLRedactor.digest("SELECT 1 -- the password is hunter2\n, 2 /* hunter2 */") == "SELECT ? \n, ? ")
        #expect(SQLRedactor.digest("SELECT 'unterminated secret") == "SELECT ?")
        #expect(!SQLRedactor.digest("INSERT INTO t VALUES ('hunter2', 99)").contains("hunter2"))
    }

    @Test func messagesLoseTheirLiteralsToo() {
        let message = "Code: 62. DB::Exception: Syntax error: failed at position 30 ('hunter2'): 'hunter2' FORMAT x. Cannot parse 'hunter2' as UInt64: While processing equals(pin, 4242)"
        let digested = SQLRedactor.digestMessage(message)
        #expect(!digested.contains("hunter2") && !digested.contains("4242"), "\(digested)")
        #expect(digested.contains("Syntax error"))
    }

    /// Review: a double-quoted "value" (a mistaken string in a failed, logged query) and an unclosed heredoc came back
    /// verbatim. Double-quoted names and every unterminated token (string, quoted name, heredoc, comment) become `?`;
    /// backticked and bare names stay.
    @Test func quotedValuesAndUnterminatedTokensBecomePlaceholders() {
        #expect(SQLRedactor.digest("SELECT * FROM t WHERE x = \"zz_rv_dq_secret\"") == "SELECT * FROM t WHERE x = ?")
        #expect(SQLRedactor.digest("SELECT $s$zz_rv_heredoc_secret, 1") == "SELECT ?")
        #expect(SQLRedactor.digest("SELECT $$zz_rv_heredoc_secret") == "SELECT ?")
        #expect(SQLRedactor.digest("SELECT `zz_open_name_secret") == "SELECT ?")
        #expect(SQLRedactor.digest("SELECT \"zz_open_dq_secret") == "SELECT ?")
        #expect(SQLRedactor.digest("SELECT 1 /* zz_open_comment_secret") == "SELECT ? ")
        #expect(SQLRedactor.digest("SELECT `col`, t.name, $1 FROM t") == "SELECT `col`, t.name, $1 FROM t", "names and parameters stay")
    }

    /// Review: server errors echo quoted names (22.8 `'x'`, 26.8 `` `x` ``) and, on 24.8+, the whole statement after
    /// `in scope`, with a double-quoted value unquoted. Recorded from 22.8, 24.8 and 26.8.
    @Test(arguments: [
        "Code: 47. DB::Exception: Missing columns: 'zz_rv_dq_secret' while processing query: 'SELECT id, s FROM shop.t WHERE s = zz_rv_dq_secret', required columns: 'id' 's' 'zz_rv_dq_secret', maybe you meant: ['id','s']. (UNKNOWN_IDENTIFIER) (version 22.8.21.38 (official build))",
        "Code: 47. DB::Exception: Unknown expression or function identifier 'zz_rv_dq_secret' in scope SELECT * FROM shop.t WHERE s = zz_rv_dq_secret. (UNKNOWN_IDENTIFIER) (version 24.8.14.39 (official build))",
        "Code: 47. DB::Exception: Unknown expression or function identifier `zz_rv_dq_secret` in scope SELECT * FROM shop.t WHERE s = zz_rv_dq_secret. (UNKNOWN_IDENTIFIER) (version 26.8.37.168 (official build))",
        "Code: 47. DB::Exception: Unknown expression identifier `$s$zz_rv_heredoc_secret` in scope SELECT `$s$zz_rv_heredoc_secret`: Note: the query does not have the FROM clause. Did you forget to add it?. (UNKNOWN_IDENTIFIER) (version 26.8.37.168 (official build))",
        "Code: 47. DB::Exception: Missing columns: 'zz_rv_insert_secret' while processing query: 'zz_rv_insert_secret', required columns: 'zz_rv_insert_secret' 'zz_rv_insert_secret': While executing ValuesBlockInputFormat. (UNKNOWN_IDENTIFIER) (version 22.8.21.38 (official build))",
        "Code: 47. DB::Exception: Unknown expression identifier `zz_rv_insert_secret` in scope zz_rv_insert_secret: While executing WaitForAsyncInsert. (UNKNOWN_IDENTIFIER) (version 26.8.37.168 (official build))",
        "Code: 47. DB::Exception: Unknown identifier \"zz_rv_dq_secret\". (UNKNOWN_IDENTIFIER)",
        "Code: 47. DB::Exception: No such file or directory: In scope SELECT zz_rv_scope_secret, 1 FROM t. (UNKNOWN_IDENTIFIER) (version 24.8.14.39 (official build))",
    ])
    func messagesLoseQuotedNamesAndStatementEchoes(message: String) {
        let digested = SQLRedactor.digestMessage(message)
        #expect(!digested.contains("zz_rv"), "\(digested)")
        #expect(digested.contains("UNKNOWN_IDENTIFIER"), "the error kind stays: \(digested)")
    }


    /// Review: server errors repeat some literal values unquoted (recorded from 22.8, 24.8 and 26.8). Each error is
    /// masked with the literal values of its own statement (strings, quoted names, heredoc bodies of 3+ characters,
    /// numbers of 4+ digits), longest first, before the digest.
    @Test(arguments: [
        ("SELECT toUUID('zz_secret_uuid')", "Code: 376. DB::Exception: Cannot parse uuid zz_secret_uuid: Cannot parse UUID from String: In scope SELECT toUUID('zz_secret_uuid'). (CANNOT_PARSE_UUID) (version 24.8.14.39 (official build))"),
        ("SELECT match(s, '(zz_secret_re') FROM t", "Code: 427. DB::Exception: OptimizedRegularExpression: cannot compile re2: (zz_secret_re, error: missing ): (zz_secret_re. Look at https://github.com/google/re2/wiki/Syntax for reference. (CANNOT_COMPILE_REGEXP) (version 26.8.37.168 (official build))"),
        ("SELECT CAST(1, 'zz_secret_type')", "Code: 50. DB::Exception: Unknown data type family: zz_secret_type: While processing CAST(1, 'zz_secret_type'). (UNKNOWN_TYPE) (version 22.8.21.38 (official build))"),
        ("SELECT toIPv4('zz_secret_ip')", "Code: 675. DB::Exception: Cannot parse IPv4 zz_secret_ip: Cannot parse IPv4 from String: In scope SELECT toIPv4('zz_secret_ip'). (CANNOT_PARSE_IPV4) (version 26.8.37.168 (official build))"),
        ("SELECT toIPv6('zz_secret_ip6')", "Code: 676. DB::Exception: Cannot parse IPv6 zz_secret_ip6: Cannot parse IPv6 from String: In scope SELECT toIPv6('zz_secret_ip6'). (CANNOT_PARSE_IPV6) (version 24.8.14.39 (official build))"),
        ("SELECT base64Decode('zz_secret_b64!')", "Code: 117. DB::Exception: Invalid base64Decode value (zz_secret_b64!), cannot be decoded: In scope SELECT base64Decode('zz_secret_b64!'). (INCORRECT_DATA) (version 26.8.37.168 (official build))"),
        ("SELECT throwIf(1, 'zz_secret_msg')", "Code: 395. DB::Exception: zz_secret_msg: while executing 'FUNCTION throwIf(1_UInt8 :: 1, 'zz_secret_msg'_String :: 2) -> throwIf(1_UInt8, 'zz_secret_msg'_String) UInt8 : 3'. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 26.8.37.168 (official build))"),
        ("SELECT getSetting('zz_secret_setting')", "Code: 115. DB::Exception: Unknown setting zz_secret_setting: While processing getSetting('zz_secret_setting'). (UNKNOWN_SETTING) (version 22.8.21.38 (official build))"),
        ("SELECT 1 FROM t WHERE x IN (\"zz_secret_table\")", "Code: 60. DB::Exception: Table default.zz_secret_table doesn't exist: While processing x IN (zz_secret_table). (UNKNOWN_TABLE) (version 22.8.21.38 (official build))"),
        ("SELECT $s$zz_secret_heredoc$s$ || 'x'", "Code: 43. DB::Exception: Illegal types of arguments: zz_secret_heredoc. (ILLEGAL_TYPE_OF_ARGUMENT)"),
        ("ALTER TABLE t UPDATE pin = 98765432 WHERE id = 1", "Code: 69. DB::Exception: Value 98765432 is out of range for pin. (ARGUMENT_OUT_OF_BOUND)"),
        ("ALTER TABLE t UPDATE s = toString(throwIf(id = 1, 'zz_secret_secret_longer')) WHERE 1",
         "Code: 395. DB::Exception: zz_secret_secret_longer: while executing 'FUNCTION throwIf(…)'. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO)"),
    ])
    func errorsLoseTheirStatementsLiteralValues(statement: String, message: String) {
        let digested = SQLRedactor.digestMessage(message, statements: [statement])
        #expect(!digested.contains("zz_secret") && !digested.contains("98765432"), "\(digested)")
        #expect(digested.contains("DB::"), "the error stays readable: \(digested)")
    }

    /// Short values (under 3 characters) and short numbers are not cross-masked: they would erase the error itself.
    @Test func shortValuesAreNotCrossMasked() {
        let message = "Code: 53. DB::Exception: Cannot convert ab to UInt8: in column id. (TYPE_MISMATCH)"
        #expect(SQLRedactor.literalValues(of: "SELECT 'ab', 123, 4567, \"name\", `col`") == ["4567", "name", "col"])
        #expect(SQLRedactor.digestMessage(message, statements: ["SELECT 'ab', 12"]).contains("Cannot convert ab to UInt8"))
        // Review nit: values under 6 characters are replaced only as whole tokens; longer ones anywhere.
        let uuid = "Code: 376. DB::Exception: Cannot parse uuid par: Cannot parse UUID from String: In scope SELECT toUUID('par'). (CANNOT_PARSE_UUID)"
        let digested = SQLRedactor.digestMessage(uuid, statements: ["SELECT toUUID('par')"])
        #expect(digested.contains("Cannot parse uuid ?") && digested.contains("Cannot parse UUID") && !digested.contains("?se"), "\(digested)")
        #expect(SQLRedactor.digestMessage("x xsecret1y 4242 a4242", statements: ["SELECT 'secret1', 4242"]) == "x x?y ? a4242")
        // Longest first: a value that contains another is replaced whole.
        #expect(SQLRedactor.digestMessage("x zz_secret_long y zz_secret z", statements: ["SELECT 'zz_secret', 'zz_secret_long'"]) == "x ? y ? z")
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
            == "SELECT query, Settings FROM system.query_log\nLIMIT 201")
        #expect(AutoLimit.apply(to: "SELECT format, count() FROM files GROUP BY format", limit: 201).sql
            == "SELECT format, count() FROM files GROUP BY format\nLIMIT 201")
        #expect(AutoLimit.apply(to: "SELECT t.settings FROM t", limit: 201).sql == "SELECT t.settings FROM t\nLIMIT 201")
        #expect(AutoLimit.apply(to: "SELECT Settings['max_threads'] FROM system.query_log WHERE Settings['x'] = '1'", limit: 5).sql
            == "SELECT Settings['max_threads'] FROM system.query_log WHERE Settings['x'] = '1'\nLIMIT 5")
        // Real clauses still get the limit in front of them.
        #expect(AutoLimit.apply(to: "SELECT Settings FROM system.query_log SETTINGS max_threads = 1", limit: 5).sql
            == "SELECT Settings FROM system.query_log\nLIMIT 5 SETTINGS max_threads = 1")
        #expect(AutoLimit.apply(to: "SELECT format FROM files FORMAT JSONEachRow", limit: 5).sql
            == "SELECT format FROM files\nLIMIT 5 FORMAT JSONEachRow")
        #expect(AutoLimit.apply(to: "SELECT 1 FORMAT Template SETTINGS format_template_row = 'r'", limit: 5).sql
            == "SELECT 1\nLIMIT 5 FORMAT Template SETTINGS format_template_row = 'r'")
        #expect(AutoLimit.apply(to: "SELECT 1 SETTINGS `max_threads` = 1", limit: 5).sql == "SELECT 1\nLIMIT 5 SETTINGS `max_threads` = 1")
        #expect(AutoLimit.apply(to: "SELECT 1 SETTINGS limit = 3", limit: 5).sql == "SELECT 1\nLIMIT 5 SETTINGS limit = 3")
    }

    @Test func autoLimitSkipsQueriesWithAnOffsetClause() {
        #expect(AutoLimit.apply(to: "SELECT * FROM t OFFSET 10", limit: 201).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t ORDER BY k OFFSET 10 ROWS", limit: 201).applied == false)
        #expect(AutoLimit.apply(to: "SELECT offset FROM t", limit: 201).sql == "SELECT offset FROM t\nLIMIT 201")
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
        #expect(outcome.sql == "SELECT * FROM t WHERE x = 1\nLIMIT 1000 SETTINGS max_threads = 1")
        let executed = outcome.sql as NSString
        // A position after the insertion (the SETTINGS keyword) maps back to the same token.
        let settingsInExecuted = executed.range(of: "SETTINGS").location
        let settingsInOriginal = (original as NSString).range(of: "SETTINGS").location
        #expect(outcome.originalOffset(ofExecuted: settingsInExecuted) == settingsInOriginal)
        // Before the insertion nothing moves; inside it maps to the insertion point.
        #expect(outcome.originalOffset(ofExecuted: 7) == 7)
        #expect(outcome.originalOffset(ofExecuted: executed.range(of: "1000").location) == (original as NSString).range(of: "= 1").upperBound)
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
