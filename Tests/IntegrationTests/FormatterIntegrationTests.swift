import ClickHouseKit
import Foundation
import Testing
@testable import CcinnClickHouseKit

extension LiveSuites {
/// Format SQL against a real server (22.8 – 26.8): the facts the keyword-case analysis relies on hold on this server,
/// and formatted statements return exactly what the originals return.
@Suite("Format SQL", .serialized)
struct FormatterIntegrationTests {
    private enum Outcome: Equatable {
        case result(columns: [String], types: [String], rows: [[String?]], raw: String?)
        case failure(code: Int?)
    }

    private func outcome(_ client: ClickHouseClient, _ sql: String) async -> Outcome {
        do {
            let result = try await client.run(sql)
            return .result(columns: result.columnNames, types: result.columns.map(\.type.name), rows: result.rows, raw: result.rawText)
        } catch let error as ClickHouseError {
            return .failure(code: error.code)
        } catch {
            return .failure(code: nil)
        }
    }

    private func fails(_ client: ClickHouseClient, _ sql: String) async -> Bool {
        if case .failure = await outcome(client, sql) { return true }
        return false
    }

    // MARK: The analysis' facts

    /// Every word the analysis treats as a keyword after a select-list value is refused there as an implicit alias:
    /// `SELECT 1 w` fails or does not return a column called `w`.
    @Test func columnAliasRefusals() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        for word in SQLFormatVocabulary.neverColumnAlias.sorted() {
            let name = word.lowercased()
            if case let .result(columns, _, _, _) = await outcome(client, "SELECT 1 \(name)") {
                #expect(columns != [name], "\(client.serverInfo.versionString) accepts `\(name)` as a column alias")
            }
        }
        // Words the server does accept (so their case must never change after a value).
        for name in ["desc", "end", "null", "over", "select", "when", "then", "distinct"] {
            #expect(await outcome(client, "SELECT 1 \(name)") == .result(columns: [name], types: ["UInt8"], rows: [["1"]], raw: nil),
                    "`\(name)` as a column alias")
        }
    }

    /// … and after a table: `SELECT w.number FROM numbers(1) w` fails.
    @Test func tableAliasRefusals() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        for word in SQLFormatVocabulary.neverTableAlias.sorted() {
            let name = word.lowercased()
            #expect(await fails(client, "SELECT \(name).number FROM numbers(1) \(name)"),
                    "\(client.serverInfo.versionString) accepts `\(name)` as a table alias")
        }
        for name in ["and", "or", "in", "is"] {
            #expect(await !fails(client, "SELECT \(name).number FROM numbers(1) \(name)"), "`\(name)` as a table alias")
        }
    }

    /// Where the analysis assumes no implicit alias at all, a name after a value is a syntax error.
    @Test func noImplicitAliasInExpressionClauses() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let statements = [
            "SELECT number FROM numbers(2) WHERE number zz",
            "SELECT number FROM numbers(2) PREWHERE number zz",
            "SELECT number FROM numbers(2) GROUP BY number zz",
            "SELECT number FROM numbers(2) GROUP BY number HAVING number zz",
            "SELECT number FROM numbers(2) ORDER BY number zz",
            "SELECT number FROM numbers(2) ORDER BY number DESC zz",
            "SELECT number FROM numbers(2) LIMIT 1 zz",
            "SELECT number FROM numbers(2) LIMIT 1 BY number zz",
            "SELECT number FROM numbers(2) SETTINGS max_threads = 1 zz",
            "SELECT a.number FROM numbers(1) a JOIN numbers(1) b ON a.number = b.number zz",
            "SELECT plus(1 zz, 2)",
            "SELECT (1 zz)",
            "SELECT [1 zz]",
            "SELECT 1 IN (1 zz)",
            "WITH 1 zz SELECT 1",
            "SELECT x FROM numbers(1) ARRAY JOIN [1] zz",
            "DELETE FROM default.ccinn_no_such_table zz WHERE 1",
            "CREATE TABLE default.ccinn_no_such_table (x UInt8) ENGINE = Memory zz",
            "INSERT INTO default.ccinn_no_such_table zz VALUES (1)",
            "UPDATE default.ccinn_no_such_table zz SET x = 1 WHERE 1",
            "SELECT CASE WHEN 1 then THEN 2 END",
            "SELECT CASE WHEN 1 THEN 2 else ELSE 3 END",
            "SELECT CASE WHEN 1 THEN 2 when WHEN 3 THEN 4 END",
            // A statement never starts with a name.
            "zz 1",
        ]
        for statement in statements {
            guard case let .failure(code) = await outcome(client, statement) else {
                Issue.record("\(client.serverInfo.versionString) accepts: \(statement)")
                continue
            }
            #expect(code == 62, "\(statement): a syntax error, not \(code.map(String.init) ?? "-")")
        }
        // `END` right after a value inside CASE closes it: the second END is the column's alias.
        if case let .result(columns, _, rows, _) = await outcome(client, "SELECT CASE WHEN 1 THEN 2 end END") {
            #expect(columns == ["END"] && rows == [["2"]])
        } else {
            Issue.record("SELECT CASE WHEN 1 THEN 2 end END failed")
        }
    }

    /// Every word whose case may change is a ClickHouse keyword (`system.keywords`, 24.x and later).
    @Test func changeableWordsAreServerKeywords() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        guard client.serverInfo.version?.isAtLeast(24, 1) == true else { return } // system.keywords does not exist before 24.x
        let result = try await client.run("SELECT DISTINCT arrayJoin(splitByChar(' ', keyword)) FROM system.keywords")
        let words = Set(result.rows.compactMap { $0.first ?? nil })
        let missing = SQLFormatVocabulary.changeableWords.subtracting(words)
        #expect(missing.isEmpty, "not keywords on \(client.serverInfo.versionString): \(missing.sorted())")
    }

    // MARK: Formatted statements

    static let statements = [
        "select country, count() as n, sum(amount) total from shop.events where event_type = 'purchase' and amount between 10 and 100 "
            + "group by country having count() > 1 order by total desc, country limit 5",
        "select e.country, c.name, count() n from shop.events as e global any left join shop.countries as c on e.country = c.code "
            + "and c.region != '' where e.user_id < 50 group by e.country, c.name order by e.country, c.name",
        "with paid as (select * from shop.events where event_type = 'purchase'), cities as (select distinct country from paid) "
            + "select case when count() > 3 then 'many' when count() > 0 then 'some' else 'none' end as k, count() from cities",
        "select country, sum(amount) over (partition by country order by event_time, user_id rows between unbounded preceding and current row) s "
            + "from shop.events where user_id < 3 order by country, event_time, user_id, s limit 10",
        "/* note */ select -1 * user_id as q, `country` from shop.events prewhere user_id < 5 where -amount < 0 "
            + "order by user_id, event_time limit 3 -- end",
        "select arrayMap(x->x*2,[1,2,3]) as a, '1'::UInt8 as b, tuple(1, 'x').2 as c, quantile(0.5)(amount) as d, "
            + "0x1F+1e3 as f, map('k',1)['k'] as g, [10,20][2] as h from shop.events where user_id=1",
        // Brackets and tuples are nesting levels: their commas are no list breaks.
        "select [1,2,3] as a, map('k', 1, 'j', 2) as m, (1, 2) as t, tuple(1,2).2 u, [[1, 2], [3]] n, has([1, 2], 1) h",
        "select x from (select [1, 2] arr) array join arr as x where x in [1, 2] order by x",
        // CRLF line breaks stay CRLF.
        "select 1 as a,\r\n2 as b -- note\r\n, 3 as c\r\n",
        "select 1 desc, 2 end, 3 over, 4 select, null, true, false, interval 1 day as i, 5 distinct",
        "select number from numbers(10) where number global not in (select number from numbers(3)) and number is not null "
            + "and toString(number) not like '9' order by number desc nulls last limit 2 by number % 2 limit 3",
        // WITH TOTALS as raw text: the app's typed TSV reader does not take the totals block.
        "select country, count() c from shop.events group by country with totals order by country format TabSeparated settings max_threads = 2",
        "select number from numbers(10) where number % 3 = 0 order by number with fill from 0 to 12 step 3",
        "select count() from shop.events sample 1 / 2 offset 1 / 2",
        "select a from (select [1, 2, 3] as arr) left array join arr as a order by a",
        "select * except (url, payload, tags) from shop.events order by user_id, event_time limit 2",
        "select x, y from (select 1 x, 2 y) where x = 1 or y = 2 and not x = 3",
        "show create table shop.events",
        "explain syntax select country from shop.events where user_id = 1 and not (country = 'MY')",
        "select count(distinct country), countIf(amount > 10), uniqExact(user_id) from shop.events",
        "select * from (select number from numbers(5) union all select number from numbers(2)) order by number",
        "select if(number > 1, 'a', 'b') as v, left(toString(number), 1) l, any(number) from numbers(5) group by v, l order by v, l",
        "select database, table, name from system.columns where database = 'shop' and table = 'events' order by name limit 3",
        "select number from numbers(3) as t final",
        "select 1 format TabSeparated",
    ]

    @Test func formattedStatementsReturnTheSame() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        for statement in Self.statements {
            let expected = await outcome(client, statement)
            // Only the FINAL probe fails on purpose; every other comparison is between two results.
            if case .failure = expected, !statement.hasSuffix("as t final") { Issue.record("fails unformatted: \(statement)") }
            try await expectSameOutcome(client, statement, expected: expected)
        }
    }

    /// Formatted with every keyword case, `statement` gives exactly `expected` (a result or the same error code).
    private func expectSameOutcome(_ client: ClickHouseClient, _ statement: String, expected: Outcome) async throws {
        for options in [SQLFormatOptions(), SQLFormatOptions(keywordCase: .upper), SQLFormatOptions(keywordCase: .lower, indentWidth: 4)] {
            let formatted = try #require(SQLFormatter.format(statement, options: options), "\(statement)")
            #expect(await outcome(client, formatted) == expected,
                    "\(client.serverInfo.versionString) \(options.keywordCase): \(statement.debugDescription) -> \(formatted.debugDescription)")
        }
    }

    /// Statements a server may reject, keyword-named names and the defect classes of the review: formatted, each gives
    /// the same result or the same error as written, on every server.
    static let comparisons = [
        // `x'41'` is a string on 24.8+, `x` followed by a string (a syntax error) on 22.8.
        "select x'41' as e",
        // Lead follow-ups 4 and 5: `end` before or after `.` and in alias positions never closes a CASE.
        "select case when 1 then end.a else 0 end as k from (select 7 as a) as end",
        "select case when 1 then end.a else 0 end from (select 7 as a) AS end",
        "select case when 0 then 1 else end.a end k from (select 7 as a) as end", // 22.8: 7; 24.8+: END after ELSE
        "select case when 0 then 1 else end end from (select 5 as end)",
        "select case when 1 then end else 0 end k from (select 5 as end)",
        "select case when end then 1 else 0 end k from (select 5 as end)",
        "select case when 1 then (1, 2) else (3, 4) end.1 k",
        "select case when 1 then 2 else 3 end as end from numbers(1) as end",
        "select case when 1 then 2 end end",
        "select end.end + 1 as end from (select 1 as end) as end",
        // Lead: the counting proof. `end` as a column, a column alias and a table alias next to CASE expressions, and
        // `end.1` / `end.a` after a CASE (its END followed by element access).
        "select case when x > 0 then 1 else 0 end, end from (select 1 as x, 2 as end)",
        "select case when x > 0 then 1 else 0 end k from (select 1 as x, 2 as end) where end = 2",
        "select case when x > 0 then 1 else 0 end end from (select 1 as x)",
        "select case when x > 0 then 1 else 0 end as end, end + 1 from (select 1 as x)",
        "select end.x, case when end.x > 0 then 'p' else 'n' end k from (select 1 as x) as end",
        "select case when end.x > 0 then end.x else 0 end k from (select 1 as x) as end",
        "select case when 1 then tuple(1, 2) else tuple(3, 4) end.1 + 1 k",
        "select case when 1 then CAST((1, 2), 'Tuple(a UInt8, b UInt8)') else CAST((3, 4), 'Tuple(a UInt8, b UInt8)') end.a k",
        "select case when x = 1 then end else 0 end k from (select 1 as x, 7 as end)",
        "select case when x then 1 else 2 end k, case when not x then 3 else 4 end l from (select 1 as x)",
        "select t.case, case when t.case > 0 then 1 else 0 end k from (select 1 as case) as t",
        // Non-ASCII look-alikes are no keywords on any server (syntax errors): never re-cased.
        "select 1 ſelect",
        "ſelect 1",
        "select ﬁrst from (select 1 as first)",
        "select diﬆinct 1",
        // Keyword-named aliases and qualified names.
        "select select.x, from.x from (select 1 x) as select, (select 2 x) as from",
        "select t.case, t.end, t.from, t.select from (select 1 as case, 2 as end, 3 as from, 4 as select) as t",
        "select desc.desc from (select 1 desc) as desc order by desc.desc desc",
        "select except.a from (select 1 a) as except",
        // Lead follow-up 4: a set operator needs a proven query.
        "select * from (select 1 a) except (x)",
        "select * from (select 1 a, 2 b) except (select 1 a, 3 b)",
        "select * from (select 1 x union all (select 2)) order by x",
        "select * from (select 1 x union distinct with y as (select 2) select * from y) order by x",
        "select 1 union all values (1)",
        // Review #4: `//` comments, then a comma or the next clause on the next line.
        "SELECT number // first col\n, number*2 AS doubled // second\nFROM system.numbers LIMIT 3",
        "SELECT number, // c\n number * 2 AS y FROM numbers(3)",
        "SELECT number AS x FROM numbers(3) ORDER BY x DESC, // tie-break\n x",
        // Heredoc bodies are data.
        "select $$a  b --x\n  c$$ as h, $t$ y $$ z $t$ as t, length(h), length(t)",
    ]

    @Test func formattedComparisonsReturnTheSame() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        for statement in Self.comparisons {
            try await expectSameOutcome(client, statement, expected: await outcome(client, statement))
        }
    }

    /// Lead follow-up 8 (4): heredoc bodies come through byte for byte.
    @Test func heredocBodiesAreByteIdentical() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let body = "$$a  b\n  -- not a comment\r\n\tselect  from 'x'$$"
        let statement = "select \(body) as h, hex(h) x"
        let formatted = try #require(SQLFormatter.format(statement, options: SQLFormatOptions(keywordCase: .upper)))
        #expect(formatted.contains(body))
        let expected = await outcome(client, statement)
        guard case let .result(_, _, rows, _) = expected else {
            Issue.record("heredocs fail on \(client.serverInfo.versionString)")
            return
        }
        #expect(rows.first?.first == "a  b\n  -- not a comment\r\n\tselect  from 'x'")
        #expect(await outcome(client, formatted) == expected)
    }

    // MARK: The read-only guard against the server

    /// The guard's view matches every server's: what it allows, a read-only user can run as one statement; what each
    /// smuggling probe hides, this server really reads (a SETTINGS clause shows as READONLY, code 164).
    @Test func readOnlyGuardSeesWhatTheServerSees() async throws {
        let client = try await ITEnvironment.connect(readOnly: true) // readonly=1, applied by the server
        defer { Task { await client.close() } }
        let version = client.serverInfo.version
        let allowed = ["SELECT 1 -- c\r; DROP TABLE t", "SELECT 'a\\'; DROP TABLE t; --'", "SELECT $a$; DROP TABLE t; $a$",
                       "SELECT $$; DROP TABLE t; $$", "SELECT 1 /* /* */ ; DROP TABLE t */"]
        for sql in allowed {
            #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql.debugDescription)")
            if case let .failure(code) = await outcome(client, sql) {
                Issue.record("\(client.serverInfo.versionString) does not read \(sql.debugDescription) as one read (code \(code ?? -1))")
            }
        }
        // `.5settings`: every server reads `.5` and a SETTINGS clause.
        for sql in ["SELECT 1, .5settings max_threads = 1", "SELECT 1, .5e1settings max_threads = 1"] {
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
            #expect(await outcome(client, sql) == .failure(code: 164), "\(client.serverInfo.versionString) applies the SETTINGS of \(sql)")
        }
        // A heredoc tag with a space: a string on 22.8 and 24.8, a SETTINGS clause on 26.8.
        let heredoc = "SELECT 1 AS $a, $a b$ SETTINGS max_threads = 1 -- $a b$"
        #expect(ReadOnlySQLGuard.check(heredoc) != nil)
        if version?.isAtLeast(26, 1) == true {
            #expect(await outcome(client, heredoc) == .failure(code: 164), "26.8 reads the SETTINGS clause")
        } else if case .failure = await outcome(client, heredoc) {
            Issue.record("\(client.serverInfo.versionString) should read one string")
        }
        // INTO OUTFILE is refused over HTTP by every server (and by the guard).
        #expect(await outcome(client, "SELECT 1, .5into outfile '/tmp/ccinn_probe'") == .failure(code: 358))
    }

    /// Review: the whitespace every server skips is exactly the lexer's: swept over every Unicode code point (ASCII
    /// controls and punctuation, supplementary planes included) with `normalizeQuery` (the server's own lexer) in one
    /// query. A character the server dropped altogether would show up here too: none does.
    @Test func serverWhitespaceIsExactlyTheLexers() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let sweep = """
            WITH number AS cp, multiIf(cp < 128, char(cp), cp < 2048, char(192 + intDiv(cp, 64), 128 + cp % 64), cp < 65536, \
            char(224 + intDiv(cp, 4096), 128 + intDiv(cp, 64) % 64, 128 + cp % 64), char(240 + intDiv(cp, 262144), \
            128 + intDiv(cp, 4096) % 64, 128 + intDiv(cp, 64) % 64, 128 + cp % 64)) AS ch
            SELECT cp FROM numbers(1114112) WHERE (cp < 55296 OR cp > 57343)
              AND normalizeQuery(concat('1,', ch, 'zz')) = normalizeQuery('1, zz') ORDER BY cp
            """
        let skipped = try await client.run(sweep).rows.compactMap { $0.first.flatMap { $0 }.flatMap { Int($0) } }
        var expected = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]
        for range in SQLLexer.unicodeWhitespace { expected += range.map(Int.init) }
        #expect(skipped == expected.sorted(), "\(client.serverInfo.versionString) skips \(skipped.map { String($0, radix: 16) })")
    }

    /// Review: every Unicode space, separator, format and control character between `1,` and `file(`: the guard and
    /// Format SQL refuse each one, and the server calls `file()` exactly for the ones the lexer reads as whitespace.
    @Test func invisibleCharactersBeforeAFunctionAreRefused() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        var scalars: [Unicode.Scalar] = []
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator, .format, .control: scalars.append(scalar)
            default: break
            }
        }
        scalars += (UInt32(0)...0x1F).compactMap(Unicode.Scalar.init).filter { ![0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains($0.value) }
        scalars.append("\u{7F}")
        for scalar in scalars {
            let sql = "SELECT 1,\(Character(scalar))file('ccinn_no_such_file', 'LineAsString')"
            let code = String(scalar.value, radix: 16)
            #expect(ReadOnlySQLGuard.check(sql) != nil, "U+\(code) passes the guard")
            #expect(SQLFormatter.format(sql) == nil, "U+\(code) is formatted")
            let readAsWhitespace = scalar.value <= 0xFFFF && SQLLexer.isUnicodeWhitespace(UInt16(scalar.value))
            let serverCalledFile = await callsFile(client, sql)
            #expect(serverCalledFile == readAsWhitespace, "\(client.serverInfo.versionString) U+\(code): server \(serverCalledFile)")
        }
        // ASCII punctuation: whenever the server calls `file()`, the lexer saw the call too, and the guard refuses.
        for value in Array(UInt8(0x21)...0x2F) + Array(0x3A...0x40) + Array(0x5B...0x60) + Array(0x7B...0x7E) {
            let character = Character(Unicode.Scalar(value))
            let sql = "SELECT 1,\(character)file('ccinn_no_such_file', 'LineAsString')"
            let lexer = SQLLexer(sql)
            let tokens = lexer.tokens()
            let lexerSeesCall = tokens.indices.dropLast().contains { tokens[$0].kind == .identifier && lexer.text(of: tokens[$0]) == "file"
                && lexer.text(of: tokens[$0 + 1]) == "(" }
            let serverCalledFile = await callsFile(client, sql)
            if serverCalledFile {
                #expect(lexerSeesCall, "\(client.serverInfo.versionString) \(character): the server calls file() unseen")
                #expect(ReadOnlySQLGuard.check(sql) != nil, "\(character) passes the guard")
            }
        }
    }

    /// The server read a call of `file()`: neither a syntax error (62) nor another function's name (46: `$file`, `_file`).
    private func callsFile(_ client: ClickHouseClient, _ sql: String) async -> Bool {
        switch await outcome(client, sql) {
        case .failure(code: 62), .failure(code: 46): false
        default: true
        }
    }

    /// Review #3: after a dot every server reads a digit-led token as digits and word characters only, so a sign after
    /// it is an operator and a call behind it runs (`t.1e-file(…)` is `t.1e` minus `file(…)`). Elsewhere an exponent
    /// takes its sign. Whenever the server reads the `file()` call, the lexer sees it too and the guard refuses.
    @Test func digitsAfterADotThenASignAndACall() async throws {
        let client = try await ITEnvironment.connect(readOnly: true) // file() runs even with readonly=1
        defer { Task { await client.close() } }
        let source = "(SELECT 1 AS `1e`, 1 AS `12abc`, 1 AS `1x`, 1 AS `1e2x`, 1 AS `0x1p`, 1 AS `1_0e`, 1 AS `5e`) AS t"
        let call = "file('ccinn_no_such_file', 'LineAsString')"
        var probes = ["1e-", "1e+", "12abc-", "1x+", "1e2x-", "0x1p-", "1_0e-", " 1e-", "/**/1e+", "1.5e-"].map {
            "SELECT t.\($0)\(call) FROM \(source)"
        }
        probes += ["SELECT 1e-\(call)", "SELECT 1, .5e-\(call)", "SELECT 0b.5e-\(call)", "SELECT 1, .5e+\(call)", "SELECT 0x1p-\(call)"]
        var calls = 0
        for sql in probes {
            let lexer = SQLLexer(sql)
            let tokens = lexer.tokens()
            let lexerSeesCall = tokens.indices.dropLast().contains { lexer.text(of: tokens[$0]) == "file" && lexer.text(of: tokens[$0 + 1]) == "(" }
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
            if await callsFile(client, sql) {
                calls += 1
                #expect(lexerSeesCall, "\(client.serverInfo.versionString) calls file() unseen: \(sql)")
            }
        }
        #expect(calls >= 9, "\(client.serverInfo.versionString): the dotted shapes call file()")
    }

    /// Review: AutoLimit's rewrite. 1.2.0 checked the statement, then sent it with ` LIMIT n` inserted after a bare `#`
    /// (a `# ` comment then hid the `/*` the guard trusted) or a lone `$` (a heredoc then swallowed the inserted text).
    /// The server really runs the hidden `file()` call of those texts; the guard refuses the statements, the texts
    /// 1.2.0 sent, and `prepare` refuses them for every limit.
    @Test func autoLimitRewritesAreGuardedAsSent() async throws {
        let client = try await ITEnvironment.connect(readOnly: true)
        defer { Task { await client.close() } }
        let call = "file('ccinn_no_such_file', 'LineAsString')"
        let cases = [
            ("SELECT 1 #/*\n, \(call) -- */", "SELECT 1 # LIMIT 101/*\n, \(call) -- */", true),
            ("SELECT 1 #FORMAT TSV /*\n, \(call) -- */", "SELECT 1 # LIMIT 101 FORMAT TSV /*\n, \(call) -- */", true),
            ("SELECT 1, $/*Q$ $ LIMIT 101/*Q$, \(call) -- */ */", "SELECT 1, $ LIMIT 101/*Q$ $ LIMIT 101/*Q$, \(call) -- */ */",
             client.serverInfo.version?.isAtLeast(26, 1) != true), // 26.8 accepts only word-character heredoc tags
        ]
        for (original, sent, serverCalls) in cases {
            #expect(await callsFile(client, sent) == serverCalls, "\(client.serverInfo.versionString): \(sent.debugDescription)")
            #expect(ReadOnlySQLGuard.check(original) != nil, "\(original.debugDescription)")
            #expect(ReadOnlySQLGuard.check(sent) != nil, "\(sent.debugDescription)")
            for limit in [101, 1_000] {
                if case .success = ReadOnlySQLGuard.prepare(original, autoLimit: limit) { Issue.record("prepared: \(original.debugDescription)") }
            }
        }
    }

    /// Review: `//` is a line comment on every server; what the guard allows after it, the server reads alike.
    @Test func doubleSlashCommentsReadAlike() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let allowed = "SELECT 1 //'\n, 2 AS x --'"
        #expect(ReadOnlySQLGuard.check(allowed) == nil)
        #expect(await outcome(client, allowed) == .result(columns: ["1", "x"], types: ["UInt8", "UInt8"], rows: [["1", "2"]], raw: nil))
        let smuggled = "SELECT 1 //'\n, file('ccinn_no_such_file', 'LineAsString') --'"
        #expect(ReadOnlySQLGuard.check(smuggled) != nil)
        if case .failure(code: 62) = await outcome(client, smuggled) { Issue.record("the server should read file() after the comment") }
        #expect(await outcome(client, "SELECT 4 //2\n, 3") == .result(columns: ["4", "3"], types: ["UInt8", "UInt8"], rows: [["4", "3"]], raw: nil))
    }

    /// Lead: non-ASCII look-alikes (`ſelect`, `aſ`, `exiſts`, `ınto`) are no keywords on any supported server: syntax
    /// errors, and nothing is created.
    @Test func nonAsciiLookAlikesAreNoKeywords() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let table = "default.ccinn_nonascii_\(UInt32.random(in: 0...UInt32.max))"
        let probes = [("ſelect 1", "ſelect"), ("select 1 aſ x", "aſ"), ("create table if not exiſts \(table) (a Int8) engine = Memory", "exiſts"),
                      ("select 1 ınto outfile 'x'", "ınto"), ("select 1 ſettings max_threads = 1", "ſettings")]
        for (sql, word) in probes {
            #expect(await outcome(client, sql) == .failure(code: 62), "\(client.serverInfo.versionString): \(sql)")
            for options in [SQLFormatOptions(keywordCase: .upper), SQLFormatOptions(keywordCase: .lower)] {
                // Formatting keeps the look-alike exactly as written (or leaves the text alone).
                #expect(SQLFormatter.format(sql, options: options).map { $0.contains(word) } ?? true, "\(sql)")
            }
            if word == "ınto" || word == "ſettings" { #expect(ReadOnlySQLGuard.check(sql) != nil, "the guard folds look-alikes strictly") }
        }
        #expect(await outcome(client, "EXISTS TABLE \(table)") == .result(columns: ["result"], types: ["UInt8"], rows: [["0"]], raw: nil))
    }

    // MARK: Random queries

    /// Adversarial: seeded random queries full of keyword-named names (`end`, `desc`, `select`, `over`, …) in every
    /// position — select items, implicit and explicit aliases, `t.name`, CASE, IN, BETWEEN, IS NULL, WHERE, ORDER BY —
    /// give the same result or the same error formatted with every keyword case.
    @Test func randomKeywordNamedQueriesKeepTheirMeaning() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        // `CCINNCH_FUZZ_SEED` / `CCINNCH_FUZZ_COUNT` explore further; a failure prints the statement to reproduce.
        let environment = ProcessInfo.processInfo.environment
        var random = SeededRandom(seed: environment["CCINNCH_FUZZ_SEED"].flatMap(UInt64.init) ?? 20_261_118)
        let count = environment["CCINNCH_FUZZ_COUNT"].flatMap(Int.init) ?? 250
        var valid = 0
        for _ in 0..<count {
            let statement = RandomQuery.make(&random)
            let expected = await outcome(client, statement)
            if case .result = expected { valid += 1 }
            try await expectSameOutcome(client, statement, expected: expected)
        }
        #expect(valid * 5 > count, "many random queries should run (\(valid) of \(count) did)")
    }

    // MARK: The lexer against the server

    /// Number-adjacent text (lead follow-up 6), probed as `SELECT (<expression>)`.
    static let numberProbes = [
        "1.5x", "1e2x", "1abc", "0x1g", "0b102", "1_000", ".5e", "1.end", "1.2.3", "1inf", "infx", "inf.1", "nan1",
        ".5x", ".5end", ".5e+x", ".5e2x", ".5_1", "0x.5", "0b2.5", "1_000.5", "0x1.8p1", "0x1p3", "1e+5x", "1e-x", "1a$b", "08.5",
        "1..2", "0xg", "0x", "1.e5", "1.5e3x", "1e1_0", "0x1_f", "1__0", "0b101", "0x1F", "1.5e-3", ".5e2", "1.",
    ]

    /// What `SELECT (<expression>)` shows about where the server's first token inside the expression ends. In
    /// parentheses no alias is allowed, so a number followed by a word is a syntax error at the word; one token is a
    /// value, an unknown identifier named in full, or a "wrong number" at the expression's start.
    private enum Boundary: Equatable {
        case oneToken
        case after(Int)
        /// Tuple access: the server split at a `.`.
        case dot
        case inconclusive(String)
    }

    private func serverBoundary(_ client: ClickHouseClient, _ expression: String) async -> Boundary {
        let prefix = "SELECT ("
        do {
            _ = try await client.run(prefix + expression + ")")
            return .oneToken
        } catch let error as ClickHouseError {
            let message = error.message
            switch error.code {
            case 47:
                // `Missing columns: 'x'` (22.8), `identifier 'x'` (24.8), `` identifier `x` `` (26.8).
                guard let name = Self.firstMatch(#"(?:Missing columns: '|identifier '|identifier `)([^'`]*)['`]"#, in: message) else {
                    return .inconclusive(message)
                }
                if name == expression { return .oneToken }
                return expression.hasPrefix(name) ? .after(name.utf8.count) : .inconclusive(message)
            case 62:
                guard let position = Self.firstMatch(#"failed at position (\d+)"#, in: message).flatMap(Int.init) else {
                    return .inconclusive(message)
                }
                let offset = position - 1 - prefix.utf8.count
                if offset <= 0 || offset >= expression.utf8.count { return .oneToken } // nothing inside failed
                return .after(offset)
            case 43, 10, 69, 36:
                return message.contains("tupleElement") || message.contains("Tuple") ? .dot : .inconclusive(message)
            default:
                return .inconclusive(message)
            }
        } catch {
            return .inconclusive("\(error)")
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Where the app's lexer ends the first token of the expression in `SELECT (<expression>)`.
    private func ourBoundary(_ expression: String) -> Boundary {
        let prefix = "SELECT ("
        let lexer = SQLLexer(prefix + expression + ")")
        let start = prefix.utf16.count
        let end = start + expression.utf16.count
        let inside = lexer.tokens().filter { $0.range.lowerBound >= start && $0.range.upperBound <= end }
        guard inside.count > 1 else { return .oneToken }
        if inside.dropFirst().first.map({ lexer.text(of: $0) == "." }) == true { return .dot }
        return .after(inside[1].range.lowerBound - start)
    }

    /// Lead follow-up 6: the lexer splits number-adjacent text exactly where this server does, or Format SQL refuses
    /// the text (where versions disagree, or a boundary falls between two word characters).
    @Test func lexerSplitsNumbersLikeTheServer() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        for expression in Self.numberProbes {
            let server = await serverBoundary(client, expression)
            if case let .inconclusive(message) = server {
                Issue.record("\(client.serverInfo.versionString) \(expression): no boundary in \(message.prefix(200))")
                continue
            }
            let ours = ourBoundary(expression)
            let query = "SELECT (\(expression))"
            let refused = SQLFormatter.format(query) == nil
            #expect(ours == server || refused,
                    "\(client.serverInfo.versionString) \(expression): server \(server), lexer \(ours), formatter does not refuse")
            if ours != server { #expect(SQLFormatter.ambiguousToken(in: query) != nil, "\(expression): refused for the right reason") }
        }
    }

    /// The seed script's DDL (MergeTree with projections, indexes, TTLs, codecs; views; a dictionary) formatted
    /// creates the same objects.
    @Test func formattedDefinitionsCreateTheSameTables() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let suffix = UInt32.random(in: 0...UInt32.max)
        let ddl = """
            create table shop.ccinn_fmt_NAME_\(suffix) (event_date Date, event_time DateTime, user_id UInt64, \
            country LowCardinality(String), event_type Enum8('view' = 1, 'cart' = 2, 'purchase' = 3), amount Decimal(12, 2), \
            url String codec(ZSTD(3)), payload String ttl event_date + interval 30 day, tags Array(String), \
            index idx_url url type bloom_filter granularity 4, \
            projection by_country (select country, count(), sum(amount) group by country)) \
            engine = MergeTree partition by toYYYYMM(event_date) order by (event_type, user_id, event_time) sample by user_id \
            ttl event_date + interval 5 year settings index_granularity = 8192 comment 'Clickstream events'
            """
        func create(_ name: String, _ options: SQLFormatOptions?) async throws -> String? {
            let sql = ddl.replacingOccurrences(of: "NAME", with: name)
            var text = sql
            if let options { text = try #require(SQLFormatter.format(sql, options: options)) }
            _ = try await client.run(text)
            let shown = try await client.run("SHOW CREATE TABLE shop.ccinn_fmt_\(name)_\(suffix)").scalar
            _ = try? await client.run("DROP TABLE IF EXISTS shop.ccinn_fmt_\(name)_\(suffix) SYNC")
            return shown?.replacingOccurrences(of: "ccinn_fmt_\(name)_", with: "ccinn_fmt_X_")
        }
        let original = try await create("plain", nil)
        #expect(original != nil)
        #expect(try await create("upper", SQLFormatOptions(keywordCase: .upper)) == original)
        #expect(try await create("lower", SQLFormatOptions(keywordCase: .lower)) == original)
    }

    /// `INSERT … FORMAT` data is sent byte for byte: tabs, double spaces and SQL-looking text stay data.
    @Test func formattedInsertsInsertTheSameData() async throws {
        let client = try await ITEnvironment.connect()
        defer { Task { await client.close() } }
        let table = "shop.ccinn_fmt_insert_\(UInt32.random(in: 0...UInt32.max))"
        _ = try await client.run("CREATE TABLE \(table) (id UInt8, s String) ENGINE = Memory")
        let insert = "insert   into \(table) (id, s) format TSV\n1\ta  b\n2\tselect  from\n"
        let formatted = try #require(SQLFormatter.format(insert, options: SQLFormatOptions(keywordCase: .upper)))
        #expect(formatted.hasSuffix("FORMAT TSV\n1\ta  b\n2\tselect  from\n"))
        _ = try await client.run(formatted)
        let values = "insert into \(table) values (3, 'x  y'), (4, 'null')"
        _ = try await client.run(try #require(SQLFormatter.format(values, options: SQLFormatOptions(keywordCase: .upper))))
        let rows = try await client.run("SELECT id, s FROM \(table) ORDER BY id").rows
        _ = try? await client.run("DROP TABLE IF EXISTS \(table)")
        #expect(rows == [["1", "a  b"], ["2", "select  from"], ["3", "x  y"], ["4", "null"]])
    }
}
}

/// SplitMix64: a small seeded generator, so a failing random query can be reproduced.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Random SELECTs over a one-row subquery whose columns and alias are keyword-named.
enum RandomQuery {
    static let names = ["end", "desc", "select", "from", "case", "when", "then", "else", "null", "over", "key", "values", "format",
                        "settings", "final", "sample", "by", "limit", "is", "in", "and", "or", "not", "with", "totals", "fill", "step",
                        "to", "array", "join", "left", "interval", "day", "exists", "distinct", "all", "union", "except", "first",
                        "last", "nulls", "rows", "range", "current", "row", "preceding", "following", "table", "if", "on", "using",
                        "global", "any", "asof", "x", "y", "asc", "between", "like", "where", "group", "order", "having", "window"]

    static func make(_ random: inout SeededRandom) -> String {
        func pick(_ options: [String]) -> String { options.randomElement(using: &random) ?? "" }
        func keyword(_ word: String) -> String { Bool.random(using: &random) ? word.uppercased() : word }
        func space() -> String { pick([" ", " ", " ", "  ", "\n", " /* c */ ", "\t"]) }
        let a = pick(names), b = pick(names), c = pick(names), t = pick(names), alias = pick(names)
        let column = pick([a, "\(t).\(a)", b, "\(t).\(b)"])
        let items = [
            column, "\(column) + 1", "-\(column)", "\(column) \(keyword("as")) \(alias)", "\(column) \(alias)",
            "\(keyword("case")) \(keyword("when")) \(column) > 0 \(keyword("then")) \(pick([b, "\(t).\(b)", "1"])) \(keyword("else")) 0 \(keyword("end"))",
            "\(keyword("case")) \(keyword("when")) \(column) > 0 \(keyword("then")) 1 \(keyword("end")) \(alias)",
            "if(\(column) = 1, 'x', 'y')", "\(c)[1]", "\(t).\(c)", "(\(a), \(b)).1", "\(column) \(keyword("in")) (1, 2)",
            "\(column) \(keyword("between")) 0 \(keyword("and")) 3", "\(column) \(keyword("is not null"))", "\(keyword("not")) \(column)",
            "[\(a), \(b)]", "tuple(\(a), 1).2", "\(keyword("interval")) 1 \(keyword("day"))", "\(keyword("null"))",
        ]
        var sql = keyword("select") + space() + pick(items)
        for _ in 0..<Int.random(in: 0...2, using: &random) { sql += "," + space() + pick(items) }
        sql += space() + keyword("from") + space()
            + "(\(keyword("select")) 1 \(keyword("as")) `\(a)`, 2 \(keyword("as")) `\(b)`, [1, 2] \(keyword("as")) `\(c)`)"
            + space() + pick([keyword("as") + " ", ""]) + t
        if Bool.random(using: &random) {
            sql += space() + keyword("where") + space() + pick(["\(column) = 1", "\(t).\(b) > 0 \(keyword("and")) \(a) < 5",
                                                              "\(a) \(keyword("in")) (1, 2) \(keyword("or")) \(b) = 2", "\(keyword("not")) \(column) = 3"])
        }
        if Bool.random(using: &random) {
            sql += space() + keyword("order by") + space() + column + pick(["", " " + keyword("desc"), " " + keyword("asc") + " " + keyword("nulls first")])
        }
        if Bool.random(using: &random) { sql += space() + keyword("limit") + " 1" }
        return sql
    }
}
