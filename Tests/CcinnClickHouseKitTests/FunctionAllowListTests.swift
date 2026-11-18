import Testing
@testable import CcinnClickHouseKit

/// Review (final round): AI access calls only reviewed functions, everywhere in a statement, and both audiences see every
/// way a statement names a function: `name(`, APPLY, a bare higher-order argument, a string-named aggregate.
@Suite("Function references and the AI allow-list")
struct FunctionAllowListTests {
    let ai = ReadOnlySQLGuard.Audience.ai(database: "shop")

    /// Gap A: a table function after a comma that follows USING (…), ON …, FINAL or SAMPLE n.
    @Test(arguments: [
        "SELECT f.name FROM zz_rv_db.t AS a JOIN zz_rv_db.t AS b USING (n), filesystem() AS f",
        "SELECT * FROM shop.a AS a JOIN shop.b AS b ON a.n = b.n, filesystem() AS f",
        "SELECT * FROM shop.a FINAL, filesystem() AS f",
        "SELECT * FROM shop.a SAMPLE 1 / 10, filesystem() AS f",
        "SELECT * FROM shop.a AS a JOIN shop.b AS b USING (n), someFutureTableFunction() AS f",
    ])
    func tableFunctionsAfterJoinClausesAreSeen(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "editor: \(sql)")
        #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "ai: \(sql)")
    }

    /// Gap B: 26.8's LLM functions, catboostEvaluate, new external table functions and name-reading local ones.
    @Test(arguments: [
        "SELECT aiGenerate('x')", "SELECT aiClassify('x', ['a'])", "SELECT aiEmbed('x')", "SELECT aiExtract('x', 'y')", "SELECT aiFilter('x', 'y')",
        "SELECT aiRedact('x')", "SELECT aiSimilarity('x', 'y')", "SELECT aiTranslate('x', 'en')", "SELECT catboostEvaluate('/m.bin', 1)",
        "SELECT * FROM filesystem('/')", "SELECT * FROM bigquery('p', 'd', 't')", "SELECT * FROM paimonCluster('c', 'u')",
        "SELECT * FROM icebergLocalCluster('c', '/p')", "SELECT * FROM eval('SELECT 1')", "SELECT reverseDNSQuery('1.1.1.1')",
    ])
    func externalFunctionsAreRefusedForEveryone(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "editor: \(sql)")
        #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "ai: \(sql)")
    }

    @Test(arguments: [
        "SELECT * FROM timeSeriesSamples(shop.ts)", "SELECT * FROM mergeTreeTextIndex(shop, t, idx)", "SELECT * FROM mergeTreeCodecBlockCounts(shop, t)",
        "SELECT * FROM mergeTreeAnalyzeIndexes(shop, t)", "SELECT someFutureFunction(1)", "SELECT joinGet('shop.j', 'v', 1)", "SELECT sleep(3)",
        "SELECT generateSerialID('s')", "SELECT logTrace('x')", "SELECT __getScalar('x')", "SELECT getClientHTTPHeader('Authorization')",
        "SELECT x FROM shop.t WHERE someFutureFunction(x) = 1", "SELECT [someFutureFunction(1)]", "SELECT FILE('x')",
    ])
    func aiCallsOnlyReviewedFunctions(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "ai: \(sql)")
    }

    @Test(arguments: [
        "SELECT sum(x), countIf(x > 1), uniqExactIf(x, y), quantile(0.5)(x), quantilesTimingState(0.5, 0.9)(x) FROM shop.t",
        "SELECT sumArrayIfOrNull(a, c), groupArrayResample(0, 10, 1)(x, k), SUM(x), Count() FROM shop.t",
        "SELECT arrayMap(x -> x + 1, a), arrayFilter((x, y) -> x > y, a, b), arraySort(a), arrayPartialSort(2, a), arraySum(a) FROM shop.t",
        "SELECT arrayMap(length, ['a']), arrayReduce('sumIf', a, c), arrayReduce('uniqUpTo(3)', a), initializeAggregation('uniqState', x) FROM shop.t",
        "SELECT CAST(x AS Decimal(10, 2)), x::Nullable(String), CAST(x AS Array(Nullable(String))), toDecimal64(x, 2) FROM shop.t",
        "SELECT EXTRACT(DAY FROM d), TRIM(BOTH ' ' FROM s), position(s, 'a'), dictGet('shop.d', 'v', toUInt64(1)) FROM shop.t",
        "SELECT count() OVER (PARTITION BY x ORDER BY y) FROM shop.t WHERE x IN (1, 2) AND EXISTS (SELECT 1) AND NOT (x = 1)",
        "WITH t AS (SELECT 1 AS x) SELECT * FROM t", "SELECT * FROM numbers(10)", "SELECT * FROM view(SELECT 1)", "SELECT * FROM generateRandom('a UInt8') LIMIT 1",
        "SELECT * APPLY(toString) FROM shop.t", "SELECT * APPLY(x -> toString(x)) FROM shop.t", "SELECT COLUMNS('a') APPLY sum FROM shop.t",
        "SELECT * EXCEPT (a) REPLACE (b + 1 AS b) FROM shop.t", "SELECT if(x, 1, 2), multiIf(x, 1, 2), tuple(1, 2).1 FROM shop.t",
        "SELECT x FROM shop.t ORDER BY (x, y) LIMIT 1", "SELECT * FROM (SELECT 1) AS s (a)", "SELECT max(x) FROM shop.t GROUP BY ROLLUP(x)",
    ])
    func reviewedFunctionsAreAllowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql, audience: ai) == nil, "\(sql) → \(ReadOnlySQLGuard.check(sql, audience: ai) ?? "")")
        #expect(ReadOnlySQLGuard.check(sql) == nil, "editor: \(sql) → \(ReadOnlySQLGuard.check(sql) ?? "")")
    }

    /// CRITICAL (1.2.0 and 0d80420): APPLY calls a function by name without `name(`; 26.8's higher-order functions take a
    /// bare function name. Every variant opened a file under readonly=1.
    @Test(arguments: [
        "SELECT * APPLY(file) FROM (SELECT 'nonexistent.txt' AS p)", "SELECT * APPLY file FROM (SELECT 'x' AS p)",
        "SELECT COLUMNS('p') APPLY(file) FROM (SELECT 'x' AS p)", "SELECT * APPLY(`file`) FROM (SELECT 'x' AS p)",
        "SELECT t.* APPLY(file) FROM (SELECT 'x' AS p) AS t", "SELECT * EXCEPT (q) APPLY(file) FROM (SELECT 'x' AS p, 1 AS q)",
        "SELECT * APPLY(file) APPLY(length) FROM (SELECT 'x' AS p)", "SELECT * APPLY(length) APPLY(file) FROM (SELECT 'x' AS p)",
        "SELECT * APPLY \"file\" FROM (SELECT 'x' AS p)", "SELECT * APPLY(aiGenerate) FROM (SELECT 'x' AS p)",
        "SELECT arrayMap(file, ['x'])", "SELECT arrayFilter(file, ['x'])", "SELECT arrayFold(file, ['x'], '')", "SELECT mapApply(file, map('a', 'b'))",
        "SELECT arrayMap(`file`, ['x'])", "SELECT * APPLY('file') FROM (SELECT 'x' AS p)", "SELECT * APPLY(1) FROM (SELECT 'x' AS p)",
        "SELECT arrayMap(concat('fi', 'le'), ['x'])", "SELECT arrayMap((file), ['x'])", "SELECT t.APPLY(file) FROM (SELECT 'x' AS p) AS t",
        "SELECT * APPLY(x -> file(x)) FROM (SELECT 'x' AS p)", "SELECT * APPLY(file)APPLY(length) FROM (SELECT 'x' AS p)",
    ])
    func functionReferencesAreChecked(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "editor: \(sql)")
        #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "ai: \(sql)")
    }

    /// For AI access the referenced function must be reviewed, and a function named by a string must be an aggregate.
    @Test(arguments: [
        "SELECT * APPLY(someFutureFunction) FROM shop.t", "SELECT arrayMap(someFutureFunction, a) FROM shop.t", "SELECT arrayReduce('file', a) FROM shop.t",
        "SELECT arrayReduce(concat('su', 'm'), a) FROM shop.t", "SELECT initializeAggregation('aiGenerate', x) FROM shop.t",
        "SELECT arrayReduceInRanges(s, [(1, 2)], a) FROM shop.t", "SELECT (x -> x)(1)", "SELECT fileIf(x, y) FROM shop.t",
    ])
    func aiChecksEveryReference(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql, audience: ai) != nil, "ai: \(sql)")
    }

    @Test func catalogLookups() {
        #expect(ReadOnlySQLGuard.isAllowedFunction("sum") && ReadOnlySQLGuard.isAllowedFunction("SUM") && ReadOnlySQLGuard.isAllowedFunction("countIf"))
        #expect(ReadOnlySQLGuard.isAllowedFunction("quantilesTimingArrayIfOrNull") && ReadOnlySQLGuard.isAllowedFunction("uniqMergeState"))
        #expect(!ReadOnlySQLGuard.isAllowedFunction("file") && !ReadOnlySQLGuard.isAllowedFunction("FILE") && !ReadOnlySQLGuard.isAllowedFunction("fileIf"))
        #expect(!ReadOnlySQLGuard.isAllowedFunction("AIGenerate") && !ReadOnlySQLGuard.isAllowedFunction("aiGenerate"))
        #expect(!ReadOnlySQLGuard.isAllowedFunction("sum" + String(repeating: "OrNull", count: 5_000)), "bounded")
        #expect(ReadOnlySQLGuard.isAllowedFunction("sum" + String(repeating: "OrNull", count: 20)))
        for name in AIFunctionCatalog.denied.keys { #expect(!ReadOnlySQLGuard.isAllowedFunction(name), "\(name)") }
    }

    /// Words that open a parenthesis without a call are never a denied function's name.
    @Test func syntacticKeywordsAreNoDeniedFunctions() {
        for keyword in FunctionReferences.syntacticKeywords {
            let lower = keyword.lowercased()
            let isFunction = AIFunctionCatalog.denied.keys.contains { $0.lowercased() == lower } || AIFunctionCatalog.knownTableFunctions.contains(lower)
            #expect(!isFunction || ReadOnlySQLGuard.isAllowedFunction(lower) || AIFunctionCatalog.allowedTableFunctions.contains(lower), "\(keyword)")
        }
    }

    /// Linear in the statement: deeply nested calls and long APPLY chains.
    @Test func pathologicalStatementsStayFast() async {
        let nested = "SELECT " + String(repeating: "arrayMap(x -> x, ", count: 2_000) + "[1]" + String(repeating: ")", count: 2_000)
        let chain = "SELECT * " + String(repeating: "APPLY(length) ", count: 5_000) + "FROM shop.t"
        // CPU time on a thread of its own: a loaded machine does not inflate it.
        let cost: Duration = await onDedicatedThread {
            let started = SQLFormatterTests.threadCPUTime()
            _ = ReadOnlySQLGuard.check(nested, audience: .ai(database: "shop"))
            _ = ReadOnlySQLGuard.check(chain, audience: .ai(database: "shop"))
            return SQLFormatterTests.threadCPUTime() - started
        }
        #expect(cost < .seconds(5), "\(cost)")
    }
}
