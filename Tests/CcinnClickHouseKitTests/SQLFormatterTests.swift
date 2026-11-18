import Foundation
import Testing
@testable import CcinnClickHouseKit

private let upper = SQLFormatOptions(keywordCase: .upper)

@Suite("SQL formatter")
struct SQLFormatterTests {
    private func format(_ sql: String, _ options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        SQLFormatter.format(sql, options: options)
    }

    // MARK: Layout

    @Test func selectListsBreakOneItemPerLine() {
        #expect(format("select a, b from t where x = 1 and y = 2 order by a") == """
            select
              a,
              b
            from t
            where x = 1
              and y = 2
            order by a
            """)
    }

    @Test func aSingleItemStaysOnTheClauseLine() {
        #expect(format("select count() from t limit 10") == "select count()\nfrom t\nlimit 10")
        #expect(format("SELECT DISTINCT a, b FROM t") == "SELECT DISTINCT\n  a,\n  b\nFROM t")
    }

    @Test func clickHouseClauses() {
        let sql = "select a from t final sample 0.1 offset 0.5 prewhere x = 1 where y = 2 group by a with totals "
            + "order by a desc nulls last limit 1 by a limit 10 settings max_threads = 1, max_block_size = 100 format JSONEachRow"
        #expect(format(sql, upper) == """
            SELECT a
            FROM t FINAL SAMPLE 0.1 OFFSET 0.5
            PREWHERE x = 1
            WHERE y = 2
            GROUP BY a WITH TOTALS
            ORDER BY a DESC NULLS LAST
            LIMIT 1 BY a
            LIMIT 10
            SETTINGS max_threads = 1, max_block_size = 100
            FORMAT JSONEachRow
            """)
        #expect(format("select a from t order by a with fill from 1 to 10 step 1 limit 5 with ties", upper) == """
            SELECT a
            FROM t
            ORDER BY a WITH FILL FROM 1 TO 10 STEP 1
            LIMIT 5 WITH TIES
            """)
        #expect(format("select a, count() from t group by a with rollup having count() > 1 limit 3 offset 1", upper) == """
            SELECT
              a,
              count()
            FROM t
            GROUP BY a WITH ROLLUP
            HAVING count() > 1
            LIMIT 3
            OFFSET 1
            """)
        #expect(format("select * from t into outfile 'out.csv' and stdout format CSV", upper) == """
            SELECT *
            FROM t
            INTO OUTFILE 'out.csv' AND STDOUT
            FORMAT CSV
            """)
    }

    @Test func joinsAndTheirConditions() {
        let sql = "select a.id, b.v from a global any left join b on a.id = b.id and b.x > 0 "
            + "left array join a.arr as x asof join c on a.id = c.id and a.ts >= c.ts cross join e inner join f using (id)"
        #expect(format(sql, upper) == """
            SELECT
              a.id,
              b.v
            FROM a
            GLOBAL ANY LEFT JOIN b
              ON a.id = b.id
              AND b.x > 0
            LEFT ARRAY JOIN a.arr AS x
            ASOF JOIN c
              ON a.id = c.id
              AND a.ts >= c.ts
            CROSS JOIN e
            INNER JOIN f USING (id)
            """)
        #expect(format("select x from t array join arr as x", upper) == "SELECT x\nFROM t\nARRAY JOIN arr AS x")
    }

    @Test func operatorsAfterAnOperand() {
        let sql = "select a from t where a global not in (select a from u) and b is not null and c between 1 and 5 and d not ilike '%x%' or e like 'y'"
        #expect(format(sql, upper) == """
            SELECT a
            FROM t
            WHERE a GLOBAL NOT IN (
              SELECT a
              FROM u
            )
              AND b IS NOT NULL
              AND c BETWEEN 1 AND 5
              AND d NOT ILIKE '%x%'
              OR e LIKE 'y'
            """)
        // `not (b)` and `not(b)` are the same call; only the prefix operator before a plain operand changes.
        #expect(format("select a from t where not a and not (b) and x = interval 1 day", upper)
            == "SELECT a\nFROM t\nWHERE NOT a\n  AND not (b)\n  AND x = INTERVAL 1 DAY")
    }

    @Test func subqueriesAndCommonTableExpressions() {
        #expect(format("select * from (select a from t) s where a in (select a from u where b = 1)") == """
            select *
            from (
              select a
              from t
            ) s
            where a in (
              select a
              from u
              where b = 1
            )
            """)
        #expect(format("with x as (select 1 as a), y as (select 2 as b) select * from x, y", upper) == """
            WITH x AS (
              SELECT 1 AS a
            ),
            y AS (
              SELECT 2 AS b
            )
            SELECT *
            FROM x, y
            """)
        #expect(format("select 1 union all select 2 except select 3", upper) == "SELECT 1\nUNION ALL\nSELECT 2\nEXCEPT\nSELECT 3")
        #expect(format("with 1 as one select one", upper) == "WITH 1 AS one\nSELECT one")
    }

    @Test func caseExpressionsWithSeveralBranches() {
        #expect(format("select case when a then 1 when b then 2 else 3 end as x, y from t", upper) == """
            SELECT
              CASE
                WHEN a THEN 1
                WHEN b THEN 2
                ELSE 3
              END AS x,
              y
            FROM t
            """)
        #expect(format("select case when a then 1 end from t", upper) == "SELECT CASE WHEN a THEN 1 END\nFROM t")
        // `end` read where an operand is expected is a column there, but 24.8+ closes a CASE at `else end`: any `end`
        // inside a CASE but its own END leaves the whole CASE as written.
        #expect(format("select case when a then end else 0 end from t", upper) == "SELECT case when a then end else 0 end\nFROM t")
    }

    @Test func windowsAndWindowFrames() {
        #expect(format("select sum(a) over (partition by b order by c desc rows between unbounded preceding and current row) s from t", upper)
            == "SELECT sum(a) OVER (PARTITION BY b ORDER BY c DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) s\nFROM t")
        #expect(format("select sum(a) over w from t window w as (order by b rows between 1 preceding and 1 following)", upper)
            == "SELECT sum(a) OVER w\nFROM t\nWINDOW w AS (ORDER BY b ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)")
        // An incomplete frame keeps its words as written.
        #expect(format("select sum(a) over (order by b rows) from t", upper) == "SELECT sum(a) OVER (ORDER BY b rows)\nFROM t")
    }

    @Test func clickHouseExpressionsStayIntact() {
        let sql = "select arrayMap(x->x*2,[1,2,3]), '1'::UInt8, arr[1], f(x)[2], {'a':1}, {id:UInt64}, $$a  b$$, $tag$ c $tag$, t.1, "
            + "quantile(0.5)(v), \"Quoted Col\", `back tick`, x'0F', -y, 1 - -1, a ? b : c, 'a' || 'b' from t where id={id:UInt64}"
        #expect(format(sql) == """
            select
              arrayMap(x -> x * 2, [1, 2, 3]),
              '1'::UInt8,
              arr[1],
              f(x)[2],
              {'a':1},
              {id:UInt64},
              $$a  b$$,
              $tag$ c $tag$,
              t.1,
              quantile(0.5)(v),
              "Quoted Col",
              `back tick`,
              x'0F',
              -y,
              1 - -1,
              a ? b : c,
              'a' || 'b'
            from t
            where id = {id:UInt64}
            """)
        #expect(format("select {db:Identifier}.{t:Identifier}, (x, y) -> x + y, tuple(1, 2).2, [1, 2][1] from t") == """
            select
              {db:Identifier}.{t:Identifier},
              (x, y) -> x + y,
              tuple(1, 2).2,
              [1, 2][1]
            from t
            """)
    }

    @Test func insertUpdateAndDelete() {
        #expect(format("insert into t (a, b) values (1, 'x'), (2, 'y')", upper) == "INSERT INTO t (a, b)\nVALUES\n  (1, 'x'),\n  (2, 'y')")
        #expect(format("insert into t select a from u", upper) == "INSERT INTO t\nSELECT a\nFROM u")
        #expect(format("insert into function remote('h', db.t) select 1", upper) == "INSERT INTO FUNCTION remote('h', db.t)\nSELECT 1")
        #expect(format("delete from t where id = 3", upper) == "DELETE FROM t\nWHERE id = 3")
        #expect(format("update t set a = 1, b = 2 where id = 3", upper) == "UPDATE t\nSET\n  a = 1,\n  b = 2\nWHERE id = 3")
        // VALUES rows are data: nothing in them changes case.
        #expect(format("insert into t values (null, true, 1 and 2)", upper) == "INSERT INTO t\nVALUES (null, true, 1 and 2)")
    }

    /// Inline data after `INSERT … FORMAT` is not SQL: its whitespace is data (TSV tabs, CSV lines).
    @Test func insertDataIsKeptVerbatim() {
        #expect(format("insert   into t format TSV\n1\ta  b\n2\tc\n;select  1") == "insert into t\nformat TSV\n1\ta  b\n2\tc\n;\n\nselect 1")
        #expect(format("INSERT INTO t FORMAT CSV 1,  2\n3,4\n") == "INSERT INTO t\nFORMAT CSV 1,  2\n3,4\n")
        #expect(format("insert into t (a) settings async_insert = 1 format JSONEachRow {\"a\":  1}", upper)
            == "INSERT INTO t (a)\nSETTINGS async_insert = 1\nFORMAT JSONEachRow {\"a\":  1}")
        // A table called `format`: the data still starts after the real FORMAT clause.
        #expect(format("insert into format format Values (1,  2)") == "insert into format\nformat Values (1,  2)")
        // Data that looks like SQL keeps its text and case.
        #expect(format("insert into t format TSV\nselect\tfrom\n", upper) == "INSERT INTO t\nFORMAT TSV\nselect\tfrom\n")
    }

    @Test func clickHouseTableDefinitions() {
        let sql = """
            create table if not exists shop.t on cluster c (id UInt64 default 0 comment 'id', name String codec(ZSTD(3)), \
            ts DateTime ttl ts + interval 1 day, index i name type bloom_filter granularity 4, \
            projection p (select name, count() group by name)) engine = ReplicatedMergeTree('/t', '{replica}') \
            partition by toYYYYMM(ts) order by (id, ts) primary key id sample by id ttl ts + interval 30 day \
            settings index_granularity = 8192 comment 'events'
            """
        #expect(format(sql, upper) == """
            CREATE TABLE IF NOT EXISTS shop.t ON CLUSTER c (
              id UInt64 default 0 comment 'id',
              name String codec(ZSTD(3)),
              ts DateTime ttl ts + INTERVAL 1 DAY,
              index i name type bloom_filter granularity 4,
              projection p (
                SELECT
                  name,
                  count()
                GROUP BY name
              )
            )
            ENGINE = ReplicatedMergeTree('/t', '{replica}')
            PARTITION BY toYYYYMM(ts)
            ORDER BY (id, ts)
            PRIMARY KEY id
            SAMPLE BY id
            TTL ts + INTERVAL 30 DAY
            SETTINGS index_granularity = 8192
            COMMENT 'events'
            """)
        #expect(format("create table t (a UInt8) engine = Null", upper) == "CREATE TABLE t (\n  a UInt8\n)\nENGINE = Null")
        #expect(format("create materialized view mv to dst as select a from src", upper)
            == "CREATE MATERIALIZED VIEW mv TO dst AS\nSELECT a\nFROM src")
        #expect(format("create dictionary d (id UInt64, v String) primary key id source(CLICKHOUSE(TABLE 'x')) layout(FLAT()) lifetime(MIN 0 MAX 10)", upper) == """
            CREATE DICTIONARY d (
              id UInt64,
              v String
            )
            PRIMARY KEY id
            SOURCE(CLICKHOUSE(TABLE 'x'))
            LAYOUT(FLAT())
            LIFETIME(MIN 0 MAX 10)
            """)
    }

    @Test func otherStatementsOnlyGetNormalisedSpacing() {
        #expect(format("show  create table shop.events", upper) == "SHOW CREATE TABLE shop.events")
        #expect(format("alter table t on cluster c delete where x in (1,2)", upper) == "ALTER TABLE t ON CLUSTER c delete where x IN (1, 2)")
        #expect(format("system flush logs") == "system flush logs")
        #expect(format("system flush logs", upper) == "SYSTEM flush logs")
        #expect(format("explain indexes = 1 select a from t", upper) == "EXPLAIN indexes = 1\nSELECT a\nFROM t")
        #expect(format("explain pipeline select 1", upper) == "EXPLAIN PIPELINE SELECT 1")
    }

    // MARK: Case

    /// ClickHouse names and functions are case-sensitive, and many keywords are also everyday names.
    @Test func namesAndFunctionsNeverChangeCase() {
        let sql = "select database, table, partition, key, default, format from system.parts where active and table = 'events' order by database"
        #expect(format(sql, upper) == """
            SELECT
              database,
              table,
              partition,
              key,
              default,
              format
            FROM system.parts
            WHERE active
              AND table = 'events'
            ORDER BY database
            """)
        #expect(format("select if(x, 1, 2), left(s, 2), any(v), array(1, 2), cast(x as UInt8), not(x), sumIf(v, x) from t", upper) == """
            SELECT
              if(x, 1, 2),
              left(s, 2),
              any(v),
              array(1, 2),
              cast(x AS UInt8),
              not(x),
              sumIf(v, x)
            FROM t
            """)
        #expect(format("select * from format(JSONEachRow, '{}') format Null", upper) == "SELECT *\nFROM format(JSONEachRow, '{}')\nFORMAT Null")
        #expect(format("select 1 format Values", upper) == "SELECT 1\nFORMAT Values")
        #expect(format("use default", upper) == "USE default")
        #expect(format("drop table if exists table", upper) == "DROP TABLE IF EXISTS table")
        #expect(format("select t.from, default.events.key from default.events as t", upper)
            == "SELECT\n  t.from,\n  default.events.key\nFROM default.events AS t")
        #expect(format("select a key, b as final from t final", upper) == "SELECT\n  a key,\n  b AS final\nFROM t FINAL")
        #expect(format("select 1 settings final = 1", upper) == "SELECT 1\nSETTINGS final = 1")
    }

    /// Positions that hold a name, whatever it spells: column definitions, INSERT columns, tables, settings, windows.
    @Test func namePositionsNeverChangeCase() {
        #expect(format("create table t (null UInt8, case String, not Int8, interval UInt8) engine = Memory", upper)
            == "CREATE TABLE t (\n  null UInt8,\n  case String,\n  not Int8,\n  interval UInt8\n)\nENGINE = Memory")
        #expect(format("insert into t (null, case, not) values (1, 2, 3)", upper) == "INSERT INTO t (null, case, not)\nVALUES (1, 2, 3)")
        #expect(format("insert into function file('x.csv', CSV, 'a Int8') (null) select 1", upper)
            == "INSERT INTO FUNCTION file('x.csv', CSV, 'a Int8') (null)\nSELECT 1")
        #expect(format("select * from null, case join not on 1", upper) == "SELECT *\nFROM null, case\nJOIN not\n  ON 1")
        #expect(format("select 1 settings null = null, true = true", upper) == "SELECT 1\nSETTINGS null = NULL, true = TRUE")
        #expect(format("select 1 window null as (order by 1), case as ()", upper) == "SELECT 1\nWINDOW null AS (ORDER BY 1), case AS ()")
        #expect(format("create view v (null UInt8) as select 1", upper) == "CREATE VIEW v (\n  null UInt8\n) AS\nSELECT 1")
    }

    /// Review #1: the case-changeable words are those the servers refuse as names where they stand. ClickHouse accepts
    /// `desc`, `end`, `is`, `null`, `over`, `select` as implicit column aliases and `and`, `or`, `in`, `is` as table
    /// aliases (recorded on 22.8, 24.8 and 26.8; see FormatterIntegrationTests).
    @Test func wordsTheServerReadsAsNamesKeepTheirCase() {
        #expect(format("select 1 desc, 2 end, 3 is, 4 null, 5 over, 6 select", upper) == """
            SELECT
              1 desc,
              2 end,
              3 is,
              4 null,
              5 over,
              6 select
            """)
        #expect(format("select x from t and", upper) == "SELECT x\nFROM t and")
        #expect(format("select from, select, case, interval, exists from (select 1 as from)", upper)
            == "SELECT\n  from,\n  select,\n  case,\n  interval,\n  exists\nFROM (\n  SELECT 1 AS from\n)")
        // The same words where only a keyword can stand.
        #expect(format("select a from t order by a desc", upper) == "SELECT a\nFROM t\nORDER BY a DESC")
        #expect(format("select x is null, null from t", upper) == "SELECT\n  x IS NULL,\n  NULL\nFROM t")
        #expect(format("select (select) from (select 1 as select)", upper) == "SELECT (select)\nFROM (\n  SELECT 1 AS select\n)")
        #expect(format("select count(distinct x), count(distinct) from t", upper) == "SELECT\n  count(DISTINCT x),\n  count(distinct)\nFROM t")
    }

    /// 22.8 reads `paste` and `qualify` after a table as its alias, so their case never changes there.
    @Test func joinAndClauseWordsNotRefusedByEveryServerKeepTheirCase() {
        #expect(format("select 1 from a paste join b", upper) == "SELECT 1\nFROM a\npaste join b")
        #expect(format("select 1 from a qualify x = 1", upper) == "SELECT 1\nFROM a\nqualify x = 1")
        #expect(format("select 1 from a where y qualify x = 1", upper) == "SELECT 1\nFROM a\nWHERE y\nQUALIFY x = 1")
    }

    @Test func keywordCaseOptions() {
        #expect(format("Select a From t") == "Select a\nFrom t", "the default keeps every word as written")
        #expect(format("SELECT a FROM t WHERE x IS NULL", SQLFormatOptions(keywordCase: .lower)) == "select a\nfrom t\nwhere x is null")
        #expect(format("select a from t", SQLFormatOptions(indentWidth: 4)) == "select a\nfrom t")
        #expect(format("select a, b from t", SQLFormatOptions(indentWidth: 4)) == "select\n    a,\n    b\nfrom t")
        #expect(SQLFormatOptions().keywordCase == .preserve)
        #expect(SQLFormatOptions(indentWidth: 0).indentWidth == 1)
        #expect(SQLFormatOptions(indentWidth: 99).indentWidth == 8)
    }

    /// Only ASCII letters change case: `ſelect` uppercases to `SELECT` in Unicode, but ClickHouse reads it as a name.
    @Test func onlyAsciiKeywordsChangeCase() {
        #expect(format("ſelect 1", upper) == "ſelect 1")
        #expect(format("select ſelect from t", upper) == "SELECT ſelect\nFROM t")
    }

    // MARK: Spacing

    /// Review #5: tokens that touch in the input keep touching, except where whitespace never matters.
    @Test func touchingTokensStayTogether() {
        for sql in ["select x'41'", "select 0x1F", "select 0b101", "select 1e3", "select '1'::UInt8", "select arr[1]", "select {p:UInt8}",
                    "select quantile(0.5)(x)", "select $$a  b$$", "select -1", "select t.1", "select a.b", "select {'a':1}",
                    "select json.a.:Int64", "select 1?2:3"] {
            #expect(format(sql) == sql, "\(sql)")
        }
        // Separated stays separated: `f (x)` and `- 1` keep their space.
        for sql in ["select f (x)", "select - 1", "select quantile (0.5) (x)", "select arr [1]", "select a . b", "select x :: UInt8"] {
            #expect(format(sql) == sql, "\(sql)")
        }
        // Allowed: around binary operators and lambdas, after commas, inside brackets.
        #expect(format("select a+b*c,x->x,(1),[ 1 ]") == "select\n  a + b * c,\n  x -> x,\n  (1),\n  [1]")
        #expect(format("select*from t") == "select *\nfrom t")
        #expect(format("select count(*)from t") == "select count(*)\nfrom t")
    }

    // MARK: Text that is not layout

    @Test func stringsQuotedNamesAndCommentsAreUntouched() {
        #expect(format("select 'a  b', `x  y` -- keep\nfrom t /* c  d */ where a=1 # hash\nand b=2") == """
            select
              'a  b',
              `x  y` -- keep
            from t /* c  d */
            where a = 1 # hash
              and b = 2
            """)
        #expect(format("-- header\n\nselect /* hint */ a, b from t") == """
            -- header
            select /* hint */
              a,
              b
            from t
            """)
        #expect(format("select a -- note   \nfrom t") == "select a -- note   \nfrom t", "trailing spaces of a line comment are kept")
    }

    /// Review #4: a line that starts with a comment keeps the order of the comments on it.
    @Test func commentsOnOneLineKeepTheirOrder() {
        #expect(format("select 1\n/* a */ /* b */ -- c\nfrom t") == "select 1\n/* a */ /* b */ -- c\nfrom t")
        #expect(format("select 1\n/* a */\n/* b */ /* c */\nfrom t") == "select 1\n/* a */\n/* b */ /* c */\nfrom t")
        #expect(format("select 1\n/* a *//* b */\nfrom t") == "select 1\n/* a *//* b */\nfrom t")
    }

    @Test func statementsAreSeparatedByABlankLine() {
        #expect(format("select 1;select 2;\n\n\nuse shop") == "select 1;\n\nselect 2;\n\nuse shop")
        #expect(format("select 1; -- done\nselect 2") == "select 1; -- done\n\nselect 2")
        #expect(format("select 1;\n") == "select 1;\n", "a trailing newline is kept")
    }

    @Test func emptyAndWhitespaceInput() {
        #expect(format("") == "")
        #expect(format("   \n  ") == "")
        #expect(format("-- just a note") == "-- just a note")
    }

    @Test func unbalancedAndUnterminatedInputNeverCrash() {
        #expect(format("select (a from t") != nil)
        #expect(format("select a) from t") != nil)
        #expect(format("select [a, (b] from t}") != nil)
        #expect(format("select 'abc") == "select 'abc")
        #expect(format("select /* open") == "select /* open")
        #expect(format("select $$ open") != nil)
        #expect(format("case when when then end end end", upper) != nil)
        #expect(format("select ) ) ( ( over over () ()", upper) != nil)
    }

    // MARK: Limits

    /// Review #7: deep nesting is not indented without bound, and a result that would explode is refused.
    @Test func indentationIsCappedAndGrowthIsBounded() throws {
        #expect(SQLFormatLayout.maximumIndentLevel == 16)
        let depth = 60
        let nested = String(repeating: "select (", count: depth) + "1" + String(repeating: ")", count: depth)
        let formatted = try #require(format(nested))
        let deepest = formatted.components(separatedBy: "\n").map { line in line.prefix { $0 == " " }.count }.max() ?? 0
        #expect(deepest == SQLFormatLayout.maximumIndentLevel * 2)
        // Each `select(` (7 characters) becomes two lines indented up to 128 spaces: far more than 16 × the input.
        let wide = String(repeating: "select(", count: 2_000) + "1" + String(repeating: ")", count: 2_000)
        #expect(SQLFormatter.edit(for: wide, selection: NSRange(location: 0, length: 0), options: SQLFormatOptions(indentWidth: 8))
            == .refused(.tooLarge))
        #expect(SQLFormatter.outputLimit(forInputLength: 1_000) == 16 * 1_000 + 65_536)
    }

    @Test func aCancelledFormatStops() async {
        let script = String(repeating: "select a, b from t where x = 1;\n", count: 20_000)
        let task = Task.detached { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return SQLFormatter.format(script)
        }
        #expect(await task.value == nil)
    }

    // MARK: Safety

    @Test func formattingIsIdempotent() throws {
        for sql in Self.corpus {
            for options in [SQLFormatOptions(), upper, SQLFormatOptions(keywordCase: .lower)] {
                let once = try #require(format(sql, options), "\(sql)")
                #expect(format(once, options) == once, "\(sql)")
            }
        }
    }

    /// The safety property: the formatted text has the same tokens; with the default options their text is
    /// identical, otherwise only the case of keyword tokens may differ. Review #8: `:` runs and adjacency included.
    @Test func randomInputKeepsItsTokens() async {
        let pieces = ["select", "from", "where", "and", "or", "between", "case", "when", "then", "end", "in", "not", "is", "null",
                      "global", "any", "left", "join", "on", "array", "final", "sample", "format", "settings", "insert", "into",
                      "values", "with", "totals", "limit", "by", "key", "table", "over", "rows", "desc", "interval", "day",
                      "(", ")", "[", "]", "{", "}", ",", ";", ".", ":", "::", ":::", "?", "->", "-", "+", "*", "=", "'x y'", "`a b`",
                      "\"q\"", "$$h  d$$", "{p:UInt8}", "-- c\n", "# h\n", "/* d */", "1", "2.5", "0x1F", "1e3", "a", "b", "t",
                      "$", "#", "x'41'", "\n", " ", "  "]
        // On a thread of its own; the failures come back to be reported here.
        let (refused, failures): (Int, [String]) = await onDedicatedThread {
            var generator = SystemRandomNumberGenerator()
            var refused = 0
            var failures: [String] = []
            for round in 0..<3_000 {
                let count = Int.random(in: 0...40, using: &generator)
                let text = (0..<count).map { _ in pieces.randomElement(using: &generator) ?? " " }
                    .joined(separator: Bool.random(using: &generator) ? " " : "")
                let options = [SQLFormatOptions(), SQLFormatOptions(keywordCase: .upper), SQLFormatOptions(keywordCase: .lower, indentWidth: 4)][round % 3]
                guard let formatted = SQLFormatter.format(text, options: options) else { // refused: never wrong, at worst unhelpful
                    refused += 1
                    continue
                }
                if !Self.sameTokens(text, formatted, caseMayDiffer: options.keywordCase != .preserve) {
                    failures.append("\(text.debugDescription) -> \(formatted.debugDescription)")
                }
                if SQLFormatter.format(formatted, options: options) != formatted { failures.append("not idempotent: \(text.debugDescription)") }
            }
            return (refused, failures)
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(refused < 30, "the formatter should almost never have to refuse (\(refused) of 3000)")
    }

    private static func sameTokens(_ lhs: String, _ rhs: String, caseMayDiffer: Bool) -> Bool {
        let left = SQLLexer(lhs)
        let right = SQLLexer(rhs)
        let leftTokens = left.tokens()
        let rightTokens = right.tokens()
        guard leftTokens.count == rightTokens.count else { return false }
        for (a, b) in zip(leftTokens, rightTokens) {
            guard a.kind == b.kind else { return false }
            let original = left.text(of: a)
            let formatted = right.text(of: b)
            if original == formatted { continue }
            guard caseMayDiffer, original.lowercased() == formatted.lowercased() else { return false }
        }
        return true
    }

    /// The safety check refuses a result whose tokens differ, whose case changed outside the proven words, whose
    /// touching tokens were split where that may matter, or whose INSERT data changed.
    @Test func theCheckRefusesWhatFormattingMustNeverDo() {
        func verify(_ original: String, _ output: String) -> Bool {
            let lexer = SQLLexer(original)
            let tokens = lexer.tokens()
            let analysis = SQLFormatAnalysis.analyze(lexer: lexer, tokens: tokens)
            return SQLFormatter.verify(lexer: lexer, tokens: tokens, analysis: analysis, changeable: analysis.changeable, output: output)
        }
        #expect(verify("select a from t", "SELECT a FROM t"))
        #expect(!verify("select a from t", "SELECT A FROM t"), "a name changed case")
        #expect(!verify("select 1 desc", "select 1 DESC"), "an alias changed case")
        #expect(!verify("select x'41'", "select x '41'"))
        #expect(!verify("select arr[1]", "select arr [1]"))
        #expect(!verify("select f(x)", "select f (x)"))
        #expect(!verify("select f (x)", "select f(x)"))
        #expect(!verify("select - 1", "select -1"))
        #expect(!verify("insert into t format TSV\n1\t2\n", "insert into t format TSV\n1 2\n"), "data changed")
        #expect(!verify("select 1", "select 1 2"))
    }

    @Test func cursorPositionsMapAcrossFormatting() throws {
        let original = "select a,b from   t where x=1"
        let formatted = try #require(format(original, upper))
        let afterFrom = (original as NSString).range(of: "from").upperBound
        #expect(SQLFormatter.mapOffset(afterFrom, from: original, to: formatted) == (formatted as NSString).range(of: "FROM").upperBound)
        #expect(SQLFormatter.mapOffset(0, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(original.utf16.count, from: original, to: formatted) == formatted.utf16.count)
        #expect(SQLFormatter.mapOffset(-5, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(10_000, from: original, to: formatted) == formatted.utf16.count)
    }

    // MARK: Selections

    @Test func selectionsAreCheckedInTheWholeText() throws {
        let text = "select 'a   b' from t; select x,y from u"
        let ns = text as NSString
        let second = ns.range(of: "select x,y from u")
        #expect(SQLFormatter.formatSelection(in: text, range: second, options: upper)
            == .init(range: second, text: "SELECT\n  x,\n  y\nFROM u"))
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: 0, length: 10_000)) == nil)
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: NSNotFound, length: 0)) == nil)
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: -1, length: 2)) == nil)
    }

    /// Review #3: a selection that starts or ends inside a token is widened to the whole token, never formatted as a
    /// fragment (`or` inside `color` would otherwise become `OR`).
    @Test func selectionBoundariesSnapToWholeTokens() throws {
        let named = "select color from t"
        let inside = NSRange(location: (named as NSString).range(of: "color").location + 3, length: 2)
        let snapped = try #require(SQLFormatter.formatSelection(in: named, range: inside, options: upper))
        #expect(snapped == .init(range: (named as NSString).range(of: "color"), text: "color"))

        let text = "select 'a   b' from t"
        let ns = text as NSString
        let cut = NSRange(location: ns.range(of: "a   b").location, length: ns.range(of: "from").upperBound - ns.range(of: "a   b").location)
        let whole = try #require(SQLFormatter.formatSelection(in: text, range: cut, options: upper))
        #expect(whole.range == NSRange(location: ns.range(of: "'a   b'").location, length: ns.range(of: "from").upperBound - ns.range(of: "'a   b'").location))
        #expect(whole.text == "'a   b' FROM")
        // Only whitespace selected: nothing to do.
        let blank = "select 1  ,  2"
        let gap = NSRange(location: 8, length: 1)
        #expect(SQLFormatter.formatSelection(in: blank, range: gap) == .init(range: gap, text: " "))
    }

    /// Keyword case needs the whole statement: decided on the whole text, not on the fragment.
    @Test func aSelectionTakesItsKeywordCaseFromTheWholeStatement() {
        let text = "select key from kv"
        let range = (text as NSString).range(of: "key from kv")
        #expect(SQLFormatter.formatSelection(in: text, range: range, options: upper)?.text == "key FROM kv")
        let alias = "select 1 desc"
        let word = (alias as NSString).range(of: "desc")
        #expect(SQLFormatter.formatSelection(in: alias, range: word, options: upper)?.text == "desc", "an alias stays as written")
        let ordered = "select a from t order by a desc"
        #expect(SQLFormatter.formatSelection(in: ordered, range: (ordered as NSString).range(of: "desc"), options: upper)?.text == "DESC")
    }

    @Test func aSelectionInsideInsertDataIsRefused() {
        let text = "insert into t format TSV\n1\ta  b\n2\tc"
        let range = (text as NSString).range(of: "a  b\n2")
        #expect(SQLFormatter.formatSelection(in: text, range: range) == nil)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        #expect(SQLFormatter.formatSelection(in: text, range: whole)?.text == "insert into t\nformat TSV\n1\ta  b\n2\tc")
    }

    /// What the editor does: the selection when there is one, else the whole text with the cursor mapped.
    @Test func editorEdits() {
        let text = "select a,b from t"
        let all = SQLFormatter.edit(for: text, selection: NSRange(location: 9, length: 0), options: upper)
        #expect(all == .replace(range: NSRange(location: 0, length: 17), text: "SELECT\n  a,\n  b\nFROM t",
                                selection: NSRange(location: 11, length: 0)))
        let part = SQLFormatter.edit(for: text, selection: NSRange(location: 7, length: 3), options: upper)
        #expect(part == .replace(range: NSRange(location: 7, length: 3), text: "a, b", selection: NSRange(location: 7, length: 4)))
        #expect(SQLFormatter.edit(for: "select 1", selection: NSRange(location: 0, length: 0)) == .unchanged)
        if case .refused = SQLFormatter.edit(for: "select a from t where x in (select", selection: NSRange(location: 0, length: 0)) {
            Issue.record("an unfinished statement is still formatted")
        }
        #expect(SQLFormatter.edit(for: "insert into t format TSV\na  b", selection: NSRange(location: 25, length: 4)) == .refused(.notEquivalent))
        #expect(SQLFormatter.edit(for: text, selection: NSRange(location: NSNotFound, length: 0), options: upper)
            == .replace(range: NSRange(location: 0, length: 17), text: "SELECT\n  a,\n  b\nFROM t", selection: NSRange(location: 0, length: 0)))
    }

    // MARK: Review round 3: defect classes

    /// A word right before or after `.` is a name: it never opens or closes a structure and never changes case. A CASE
    /// with any other `end` inside it (next to `.`, where a value or a name stands, after AS) is ambiguous: ClickHouse
    /// 24.8+ closes a CASE at `else end`, 22.8 reads a column there. None of its words change case.
    @Test func endNextToADotOrWhereANameStandsIsNeverCaseEnd() {
        let lower = SQLFormatOptions(keywordCase: .lower)
        #expect(format("select case when 1 then end.a else 0 end as k from (select 7 as a) as end", upper) == """
            SELECT case when 1 then end.a else 0 end AS k
            FROM (
              SELECT 7 AS a
            ) AS end
            """)
        #expect(format("SELECT CASE WHEN 1 THEN end.a ELSE 0 END FROM t AS end", lower)
            == "select CASE WHEN 1 THEN end.a ELSE 0 END\nfrom t as end")
        // `end` before `.` closes nothing: the CASE stays open, so nothing after it is judged either.
        #expect(format("select case when x then 1 end.a from t", upper) == "SELECT case when x then 1 end.a from t")
        #expect(format("select case when 0 then 1 else end end from t", upper) == "SELECT case when 0 then 1 else end end\nFROM t")
        #expect(format("select case when end then 1 else 2 end k from t", upper) == "SELECT case when end then 1 else 2 end k\nFROM t")
        #expect(format("select case when 1 then 2 as end end from t", upper) == "SELECT case when 1 then 2 AS end end\nFROM t")
        #expect(format("select case when x then (1, 2) else (3, 4) end.1 from t", upper)
            == "SELECT case when x then (1, 2) else (3, 4) end.1 from t")
        // A nested CASE of its own is fine; an `end` in its own parentheses is left over there, so the counting proof
        // fails and every CASE word of the statement stays as written.
        #expect(format("select case when x then 1 else case when y then 2 end end from t", upper) == """
            SELECT CASE
              WHEN x THEN 1
              ELSE CASE WHEN y THEN 2 END
            END
            FROM t
            """)
        #expect(format("select case when f(end) then 1 else case when y then 2 end end from t", upper)
            == "SELECT case when f(end) then 1 else case when y then 2 end end\nFROM t")
        // Every keyword-named word next to a dot keeps its text.
        #expect(format("select from.select, select.from, t.case, case.t, end.end from t", upper) == """
            SELECT
              from.select,
              select.from,
              t.case,
              case.t,
              end.end
            FROM t
            """)
        #expect(format("select x from t where y = 1 and.z = 2", upper) == "SELECT x\nFROM t\nWHERE y = 1 and.z = 2")
    }

    /// Lead: the CASE…END counting proof. Within each pair of brackets of a statement, the words `case` (not next to
    /// `.`) and EVERY word `end` must pair up; any `end` left over (a column, an alias, a table alias, `end.a`) means the
    /// statement's CASE words keep their exact text and get no layout.
    @Test func caseWordsNeedTheCountingProof() {
        let lower = SQLFormatOptions(keywordCase: .lower)
        #expect(format("select case when x then 1 else 2 end, end from t", upper) == "SELECT\n  case when x then 1 else 2 end,\n  end\nFROM t")
        #expect(format("select case when x then 1 else 2 end k from t where end = 1", upper)
            == "SELECT case when x then 1 else 2 end k\nFROM t\nWHERE end = 1")
        #expect(format("select case when x then 1 else 2 end end from t", upper) == "SELECT case when x then 1 else 2 end end\nFROM t")
        #expect(format("select end.x, case when end.x > 0 then 1 else 0 end k from t as end", upper)
            == "SELECT\n  end.x,\n  case when end.x > 0 then 1 else 0 end k\nFROM t AS end")
        // `END.1` counts as a candidate END (it is one: tuple access on the CASE) but is never re-cased itself, and the
        // CASE it closes is not proven: nothing after it is judged either.
        #expect(format("SELECT CASE WHEN x THEN (1, 2) ELSE (3, 4) END.1 FROM t", lower) == "select CASE WHEN x THEN (1, 2) ELSE (3, 4) END.1 FROM t")
        // `t.case` is a name, never a CASE: it does not need an `end`.
        #expect(format("select t.case, case when x then 1 else 2 end k from t", upper)
            == "SELECT\n  t.case,\n  CASE\n    WHEN x THEN 1\n    ELSE 2\n  END k\nFROM t")
        // Statements are proven one by one.
        #expect(format("select end from t; select case when x then 1 else 2 end from t", upper)
            == "SELECT end\nFROM t;\n\nSELECT CASE\n  WHEN x THEN 1\n  ELSE 2\nEND\nFROM t")
        // Quoted names are other tokens.
        #expect(format("select case when x then 1 else 2 end as `end` from t", upper)
            == "SELECT CASE\n  WHEN x THEN 1\n  ELSE 2\nEND AS `end`\nFROM t")
    }

    /// Lead (MySQL port): `ſ` upper-cases to `S`, `ﬁ` to `FI`; words with any non-ASCII letter never change case, and
    /// the equivalence check counts any change to a non-ASCII character as a mismatch.
    @Test func longSAndLigaturesAreNeverKeywords() {
        let lower = SQLFormatOptions(keywordCase: .lower)
        #expect(format("select 1 ſelect", upper) == "SELECT 1 ſelect")
        #expect(format("SELECT 1 ſELECT", lower) == "select 1 ſELECT")
        #expect(format("select ﬁrst, diﬆinct from t", upper) == "SELECT\n  ﬁrst,\n  diﬆinct\nFROM t")
        func verify(_ original: String, _ output: String) -> Bool {
            let lexer = SQLLexer(original)
            let tokens = lexer.tokens()
            let analysis = SQLFormatAnalysis.analyze(lexer: lexer, tokens: tokens)
            let everything = [Bool](repeating: true, count: tokens.count) // even if a word were marked changeable
            return SQLFormatter.verify(lexer: lexer, tokens: tokens, analysis: analysis, changeable: everything, output: output)
        }
        #expect(!verify("select 1 ſelect", "select 1 SELECT"))
        #expect(!verify("select 1 ſelect", "select 1 Select"))
        #expect(verify("select 1 x", "SELECT 1 X"), "ASCII letters may change where allowed")
    }

    /// UNION / EXCEPT / INTERSECT are set operators only before a query (SELECT, WITH, or `(` opening one; ClickHouse
    /// has no VALUES query): `from (select 1 a) except (x)` stays as written.
    @Test func setOperatorsNeedAProvenQuery() {
        #expect(format("select * from (select 1 a) except (x)", upper) == "SELECT *\nFROM (\n  SELECT 1 a\n) except (x)")
        #expect(format("select 1 union all values (1)", upper) == "SELECT 1 union all values (1)")
        #expect(format("select 1 except (select 1)", upper) == "SELECT 1\nEXCEPT (\n  SELECT 1\n)")
        #expect(format("select 1 union all ((select 2))", upper) == "SELECT 1\nUNION ALL ((\n  SELECT 2\n))")
        #expect(format("select 1 a union distinct with x as (select 2) select * from x", upper) == """
            SELECT 1 a
            UNION DISTINCT
            WITH x AS (
              SELECT 2
            )
            SELECT *
            FROM x
            """)
        #expect(format("select * except (a) from t", upper) == "SELECT * EXCEPT (a)\nFROM t", "a column transformer")
    }

    /// Final review (a): brackets, braces, `map(…)` and tuples are nesting levels; their commas are never list breaks.
    @Test func bracketsBracesAndTuplesKeepTheirItemsTogether() {
        #expect(format("select [1,2,3] as a, {'a':1, 'b':2} as m, map('k', 1, 'j', 2) as mm, (1, 2) as t, [[1, 2], [3]] n from t") == """
            select
              [1, 2, 3] as a,
              {'a':1, 'b':2} as m,
              map('k', 1, 'j', 2) as mm,
              (1, 2) as t,
              [[1, 2], [3]] n
            from t
            """)
        #expect(format("select x from t array join [1, 2] as a where x in [1, 2]") == "select x\nfrom t\narray join [1, 2] as a\nwhere x in [1, 2]")
        #expect(format("select [1]") == "select [1]", "the space between a keyword and `[` stays")
        #expect(format("select f([1]), f( [1] ), g({'a': 1})") == "select\n  f([1]),\n  f([1]),\n  g({'a': 1})")
        #expect(format("select a from t group by a, [b, c] order by [a, b] desc, c") == """
            select a
            from t
            group by
              a,
              [b, c]
            order by
              [a, b] desc,
              c
            """)
    }

    /// Final review (b): options can never make the formatter trap; the indent width is clamped on every assignment.
    @Test func indentWidthIsAlwaysClamped() throws {
        var options = SQLFormatOptions()
        options.indentWidth = -1
        #expect(options.indentWidth == 1)
        #expect(format("select a, b from t", options) == "select\n a,\n b\nfrom t")
        options.indentWidth = .max
        #expect(options.indentWidth == 8)
        #expect(SQLFormatOptions(indentWidth: .min).indentWidth == 1)
        #expect(SQLFormatOptions(indentWidth: 0).indentWidth == 1)
    }

    /// Final review (c): a word with any non-ASCII character is never a keyword (`ﬁrst` is not FIRST, `diﬆinct` not
    /// DISTINCT), and never changes case.
    @Test func nonAsciiWordsAreNeverKeywords() {
        #expect(format("select diﬆinct a from t order by a nulls ﬁrst", upper) == "SELECT diﬆinct a\nFROM t\nORDER BY a nulls ﬁrst")
        #expect(format("ﬁrst ſelect", upper) == "ﬁrst ſelect")
    }

    /// Final review (e): a `,` never ends up alone on a line after a comment; it starts the next item's line.
    @Test func aCommaAfterALineCommentStartsTheNextItem() {
        #expect(format("select a /* x */ -- y\n, b from t") == "select\n  a /* x */ -- y\n  , b\nfrom t")
        #expect(format("select a\n-- y\n, b from t") == "select\n  a\n  -- y\n  , b\nfrom t")
        #expect(format("select a -- y\n, b, c from t") == "select\n  a -- y\n  , b,\n  c\nfrom t")
        #expect(format("create table t (a UInt8 -- x\n, b UInt8) engine = Memory") == """
            create table t (
              a UInt8 -- x
              , b UInt8
            )
            engine = Memory
            """)
    }

    /// Final review (e): CRLF input comes out with CRLF line breaks; breaks inside strings, comments and data are kept
    /// as they are and do not decide.
    @Test func crlfInputGetsCrlfOutput() {
        #expect(format("select a,\r\nb from t\r\n") == "select\r\n  a,\r\n  b\r\nfrom t\r\n")
        #expect(format("select 1;\r\nselect 2") == "select 1;\r\n\r\nselect 2")
        #expect(format("select 'x\r\ny', a from t") == "select\n  'x\r\ny',\n  a\nfrom t")
        #expect(format("select a -- c\r\n, b from t") == "select\r\n  a -- c\r\n  , b\r\nfrom t")
        #expect(format("select a -- c\r\nfrom t\r\n") == "select a -- c\r\nfrom t\r\n")
        #expect(format("insert into t format CSV\r\n1,2\r\n") == "insert into t\r\nformat CSV\r\n1,2\r\n")
        for sql in ["select a,\r\nb from t\r\n", "select a -- c\r\n, b from t", "select 1;\r\nselect 2"] {
            let once = format(sql)
            #expect(once.flatMap { format($0) } == once, "idempotent: \(sql.debugDescription)")
        }
    }

    /// Review: a `//` comment runs to the line end, so the next token goes on the next line; invisible characters
    /// outside strings and comments (servers skip U+00A0, U+FEFF, U+200B, … as whitespace) make Format SQL refuse.
    @Test func doubleSlashCommentsAndInvisibleCharacters() {
        #expect(format("select a // note\n, b from t") == "select\n  a // note\n  , b\nfrom t")
        #expect(format("select 1 // note\nfrom t") == "select 1 // note\nfrom t")
        #expect(format("select 4 //2\n") == "select 4 //2\n")
        #expect(SQLFormatter.edit(for: "select 1,\u{FEFF}2", selection: NSRange(location: 0, length: 0)) == .refused(.invisibleCharacter(0xFEFF)))
        #expect(format("select\u{A0}1") == nil)
        // Review #5: an alias spelled like a clause behind U+00A0 (`x<NBSP>as from`) is never re-cased: refused.
        for alias in ["from", "settings", "format", "where", "limit", "and"] {
            for options in [upper, SQLFormatOptions(keywordCase: .lower)] {
                #expect(format("select x\u{A0}as \(alias) from (select 1 x)", options) == nil, "\(alias)")
            }
        }
        #expect(format("select 'a\u{A0}b', 1 -- c\u{3000}d") == "select\n  'a\u{A0}b',\n  1 -- c\u{3000}d")
    }

    /// Heredoc bodies are data: byte for byte, whatever they contain.
    @Test func heredocBodiesAreByteIdentical() throws {
        let body = "$$a  b\n  -- not a comment\r\n\tselect  from$$"
        let tagged = "$t$x $$ y$t$"
        let formatted = try #require(format("select \(body) as h, \(tagged) t, 1 from t", upper))
        #expect(formatted == "SELECT\n  \(body) AS h,\n  \(tagged) t,\n  1\nFROM t")
    }

    /// The lexer reads numbers as ClickHouse does, but where supported versions read a token differently (`1_000` is
    /// a name on 22.8, `0x.5` one number on 22.8 and `0x` `.` `5` later) or a token boundary falls between two word
    /// characters (`.5x` is `.5` and `x`), the text is refused rather than trusted.
    @Test func ambiguousTokensAreRefused() {
        for sql in ["select 1_000", "select 0x.5", "select 0b2.5", "select 0xg", "select 0x", "select 1 from t where x = .5x",
                    "select 1é", "select (.5end)", "select $a b$ x $a b$", "select $a-b$ 1 $a-b$"] {
            #expect(format(sql) == nil, "\(sql)")
            #expect(SQLFormatter.ambiguousToken(in: sql) != nil, "\(sql)")
        }
        #expect(SQLFormatter.ambiguousToken(in: "select 1_000 a") == "1_000")
        for sql in ["select 0x1F, 0b101, 1e3, 1.5e-3, .5, 0x1.8p1, 1abc, t.1, x .5", "select $$a$$b"] {
            #expect(SQLFormatter.ambiguousToken(in: sql) == nil, "\(sql)")
        }
        #expect(SQLFormatter.edit(for: "select 1_000, a", selection: NSRange(location: 0, length: 0)) == .refused(.ambiguousToken("1_000")))
    }

    /// Final review: time stays linear on pathological nesting (precomputed matching, no forward rescans).
    @Test func pathologicalInputStaysLinear() async {
        let inputs: [(String, String)] = [
            ("select ( × 50k", String(repeating: "select (", count: 50_000)),
            ("(with x as ( × 20k", String(repeating: "(with x as (", count: 20_000)),
            ("nested CASE × 20k", "select " + String(repeating: "case when x then ", count: 20_000)),
            ("closed nested CASE × 20k", "select " + String(repeating: "case when x then 1 else ", count: 20_000) + String(repeating: " end", count: 20_000)),
            ("OVER ( × 20k", "select " + String(repeating: "sum(x) over (", count: 20_000)),
            ("[ × 50k", String(repeating: "[", count: 50_000)),
            ("50k items", "select " + String(repeating: "a, ", count: 50_000) + "b from t"),
            ("UNION ALL × 20k", String(repeating: "select 1 union all ", count: 20_000) + "select 2"),
            ("UNION ALL ( × 20k", String(repeating: "select 1 union all (", count: 20_000)),
            ("( × 50k )", String(repeating: "(", count: 50_000) + String(repeating: ")", count: 50_000)),
        ]
        // On a thread of its own (CPU time measured there), so the cooperative pool stays free for other tests.
        let costs: [(String, Duration)] = await onDedicatedThread {
            inputs.map { input in
                let started = Self.threadCPUTime()
                _ = SQLFormatter.format(input.1)
                return (input.0, Self.threadCPUTime() - started)
            }
        }
        for (label, cost) in costs {
            // Linear work takes a few seconds of CPU at most in a debug build (12 s for nested CASE × 20k on the 3-core CI
            // runner, about 4× slower than a developer Mac); the quadratic look-aheads this replaced took minutes.
            #expect(cost < .seconds(45), "\(label): debug-build bound")
        }
    }

    /// CPU time of this thread: unlike the wall clock, other work on a busy machine does not inflate it. Formatting is
    /// synchronous, so it all runs on the calling thread.
    static func threadCPUTime() -> Duration {
        .nanoseconds(Int64(clamping: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }

    @Test func aMegabyteScriptFormatsQuickly() async throws {
        let statement = "select o.id, sum(o.total) total, case when o.x > 1 then 'a' when o.x < 0 then 'b' else 'c' end k "
            + "from shop.orders o global left join shop.customers c on o.cid = c.id and c.city in ('KL', 'PG') "
            + "prewhere o.d between '2024-01-01' and '2024-12-31' where o.status = 'paid' group by o.id, k order by total desc limit 10;\n"
        let script = String(repeating: statement, count: 1_048_576 / statement.utf8.count + 1)
        let (result, cost): (String?, Duration) = await onDedicatedThread {
            let started = Self.threadCPUTime()
            let formatted = SQLFormatter.format(script, options: SQLFormatOptions(keywordCase: .upper))
            return (formatted, Self.threadCPUTime() - started)
        }
        let formatted = try #require(result)
        #expect(cost < .seconds(20), "debug build bound; release is far faster")
        #expect(formatted.count > script.count)
    }

    static let corpus = [
        "select a, b from t where x = 1 and y = 2 order by a",
        "select * from (select a from t) s where a in (select a from u)",
        "with x as (select 1), y as (select 2) select * from x join y on x.a = y.a",
        "select case when a then 1 when b then 2 else 3 end x from t; alter table t update a = 1 where b = 2",
        "create table t (a UInt8, b String) engine = MergeTree order by a settings index_granularity = 8192",
        "select 'a' -- c\n, b from t /* x */ where a between 1 and 2 and b = 1",
        "insert into t (a, b) values (1, 2), (3, 4); delete from t where a = 1",
        "insert into t format CSV\n1,2\n3,4",
        "select arrayMap(x -> x + 1, [1, 2]), m['k'], t.1, a::UInt8, {p:String} from t final sample 0.5 settings max_threads = 2 format JSON",
        "select sum(a) over (partition by b order by c rows between unbounded preceding and current row) from t limit 1 by b",
        "select 1\n/* a */ /* b */\nfrom t",
        "select a+b*c,x->x from t where y=-1 and z in(1,2)",
        "explain pipeline select 1; show create table t; drop table if exists t",
    ]
}
