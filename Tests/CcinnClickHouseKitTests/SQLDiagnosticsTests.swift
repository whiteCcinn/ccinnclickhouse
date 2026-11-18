import Foundation
import Testing
@testable import CcinnClickHouseKit

/// Text of a UTF-16 range (what the editor would underline).
private func slice(_ text: String, _ range: Range<Int>?) -> String? {
    guard let range else { return nil }
    let units = Array(text.utf16)
    guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
    return String(decoding: units[range], as: UTF16.self)
}

private func utf16Offset(of needle: String, in text: String) -> Int {
    (text as NSString).range(of: needle).location
}

/// `ClickHouseError.message` of real failures (`curl` against 22.8.21, 24.8.14 and 26.8.37): the text after
/// `DB::Exception:` without `(NAME)` and `(version …)`.
private enum Recorded {
    static let expectedList = "token, Comma, FROM, PREWHERE, WHERE, GROUP BY, WITH, HAVING, WINDOW, QUALIFY, ORDER BY, LIMIT, OFFSET, FETCH, SETTINGS, UNION, EXCEPT, INTERSECT, INTO OUTFILE, FORMAT, end of query"
    /// `SELECT 1 FORM t` (24.8)
    static let formT = "Syntax error: failed at position 15 ('t'): t. Expected one of: \(expectedList)."
    /// `SELECT 1 FORM t` (22.8: a shorter list)
    static let formT22 = "Syntax error: failed at position 15 ('t'): t. Expected one of: token, Comma, FROM, PREWHERE, WHERE, GROUP BY, WITH, HAVING, WINDOW, ORDER BY, LIMIT, OFFSET, SETTINGS, UNION, EXCEPT, INTERSECT, INTO OUTFILE, FORMAT, end of query."
    /// `SELECT 1 FORM t` (26.8: the token is not quoted)
    static let formT26 = "Syntax error: failed at position 15 (t): t. Expected one of: \(expectedList), ParallelWithClause, PARALLEL WITH, end of query."
    /// `SELECT * FROM events WHERE`
    static let endOfQuery = "Syntax error: failed at position 27 (end of query): . Expected one of: expression with optional alias, element of expression with optional alias, lambda expression."
    /// `SELECT * FROM events WHERE` (22.8 lists 60 alternatives)
    static let endOfQuery22 = "Syntax error: failed at position 27 (end of query): . Expected one of: expression with optional alias, element of expression with optional alias, lambda expression, token, OpeningRoundBracket, list of elements, identifier, Arrow, expression with ternary operator, logical-OR expression, list, delimited by operator of variable arity, logical-AND expression, logical-NOT expression, expression with prefix unary operator, NOT, nullity checking, comparison expression, list, delimited by binary operators, BETWEEN expression, string concatenation expression, additive expression, INTERVAL operator expression, INTERVAL, TIMESTAMP operator expression, TIMESTAMP, DATE operator expression, DATE, multiplicative expression, unary expression, CAST expression, tuple element expression, array element expression, element of expression, SELECT subquery, CAST operator, tuple, collection of literals, parenthesized expression, array, literal, NULL, number, Bool, true, false, string literal, case, CASE, COLUMNS matcher, COLUMNS, function, qualified asterisk, compound identifier, asterisk, substitution, MySQL-style global variable."
    /// `SELECT 1,\n  2 FORM\n t`
    static let multiLine = "Syntax error: failed at position 21 ('t') (line 3, col 2): t. Expected one of: \(expectedList)."
    /// `SELECT 'é🇲🇾', 1 FORM t` (positions count UTF-8 bytes)
    static let multiByte = "Syntax error: failed at position 29 ('t'): t. Expected one of: \(expectedList)."
    /// `SELECT count(1`
    static let unmatched = "Syntax error: failed at position 13 ('('): (1. Unmatched parentheses: (."
    static let unmatched26 = "Syntax error: failed at position 13 ((): (1. Unmatched parentheses: (."
    /// `SELECT 'abc`
    static let string = "Syntax error: failed at position 8 (''abc'): 'abc. Single quoted string is not closed: ''abc'."
    static let string26 = "Single quoted string is not closed: Syntax error: failed at position 8 ('abc): 'abc. ."
    /// `SELECT 1 /* x`
    static let comment = "Syntax error: failed at position 10 ('/* x'): /* x. Multiline comment is not closed: '/* x'."
    static let comment26 = "Multiline comment is not closed: Syntax error: failed at position 10 (/* x): /* x. ."
    /// `SELECT x FROM events`
    static let identifier = "Unknown expression identifier 'x' in scope SELECT x FROM events."
    static let identifier26 = "Unknown expression identifier `x` in scope SELECT x FROM events."
    static let missingColumns = "Missing columns: 'x' while processing query: 'SELECT x FROM events', required columns: 'x'."
    /// `SELECT e.nosuch FROM events AS e`
    static let qualified = "Identifier 'e.nosuch' cannot be resolved from table with name e. In scope SELECT e.nosuch FROM events AS e."
    static let qualifiedOld = "There's no column 'e.nosuch' in table 'e': While processing e.nosuch."
    /// ``SELECT `Weird Col` FROM events``
    static let quoted = "Unknown expression identifier 'Weird Col' in scope SELECT `Weird Col` FROM events."
    static let quoted26 = "Unknown expression identifier `Weird Col` in scope SELECT `Weird Col` FROM events."
    static let quotedOld = "Missing columns: 'Weird Col' while processing query: 'SELECT `Weird Col` FROM events', required columns: 'Weird Col'."
    /// `SELECT * FROM shop.nosuch` (and `FROM nosuch` on 22.8)
    static let table = "Unknown table expression identifier 'shop.nosuch' in scope SELECT * FROM shop.nosuch."
    static let unqualifiedTable = "Unknown table expression identifier 'nosuch' in scope SELECT * FROM nosuch."
    static let tableOld = "Table shop.nosuch doesn't exist."
    /// `SELECT * FROM nosuchdb.t`
    static let database = "Database nosuchdb does not exist."
    static let databaseOld = "Database nosuchdb doesn't exist."
    /// `SELECT flor(1)`
    static let function = "Function with name 'flor' does not exist. In scope SELECT flor(1). Maybe you meant: ['floor','xor']."
    static let function26 = "Function with name `flor` does not exist. In scope SELECT flor(1). Maybe you meant: ['floor','xor']."
    static let functionOld = "Unknown function flor. Maybe you meant: ['floor','log']: While processing flor(1)."
    static let aggregateOld = "Unknown function sumx: Or unknown aggregate function sumx. Maybe you meant: ['sum']: While processing sumx(1)."
    static let aggregate26 = "Function with name `sumx` does not exist. In scope SELECT sumx(1). Maybe you meant: ['sum']."
    static let tableFunction = "Unknown table function numbrs. Maybe you meant: ['numbers']."
    /// `SELECT 1 SETTINGS max_threadz = 1`
    static let setting = "Setting max_threadz is neither a builtin setting nor started with the prefix 'SQL_' registered for user-defined settings: Maybe you meant ['max_threads']."
    static let settingOld = "Unknown setting max_threadz: Maybe you meant ['max_threads']."
    /// `SELECT number FROM numbers(10) GROUP BY 1 HAVING nosuch > 1`
    static let having = "Unknown expression or function identifier 'nosuch' in scope SELECT number FROM numbers(10) GROUP BY 1 HAVING nosuch > 1."
    static let having26 = "Unknown expression or function identifier `nosuch` in scope SELECT number FROM numbers(10) GROUP BY 1 HAVING nosuch > 1."
    static let havingOld = "Missing columns: 'nosuch' while processing query: 'SELECT number FROM numbers(10) WHERE nosuch > 1 GROUP BY number', required columns: 'number' 'nosuch', maybe you meant: ['number']."
    /// `SELECT toDate('x')`
    static let parseDate = "Cannot parse date: value is too short: Cannot parse Date from String: In scope SELECT toDate('x')."
}

@Suite("Server error parsing")
struct ServerErrorParsingTests {
    @Test func syntaxErrorsHaveAPosition() {
        let error = SQLServerError.parse(Recorded.formT, code: 62, name: "SYNTAX_ERROR")
        #expect(error.phase == .syntax)
        #expect(error.position == .byteOffset(15))
        #expect(!error.atEndOfQuery)
        #expect(error.names.isEmpty)
        #expect(SQLServerError.parse(Recorded.multiLine).position == .lineColumn(line: 3, column: 2))
        #expect(SQLServerError.parse(Recorded.endOfQuery).atEndOfQuery)
        #expect(SQLServerError.parse(Recorded.string26).position == .byteOffset(8))
    }

    @Test func otherErrorsHaveNoPositionEvenIfTheEchoLooksLikeOne() {
        let error = SQLServerError.parse("Unknown expression identifier 'x' in scope SELECT '(line 1, col 3)', 'failed at position 2'.", code: 47, name: "UNKNOWN_IDENTIFIER")
        #expect(error.phase == .other)
        #expect(error.position == nil)
        #expect(error.names == [["x"]])
    }

    @Test func rawExceptionTextIsUnderstood() {
        let raw = "Code: 62. DB::Exception: Syntax error: failed at position 15 ('t'): t. Expected one of: token, Comma, FROM. (SYNTAX_ERROR) (version 24.8.14.39 (official build))"
        let error = SQLServerError.parse(raw)
        #expect(error.code == 62)
        #expect(error.name == "SYNTAX_ERROR")
        #expect(error.phase == .syntax)
        #expect(error.position == .byteOffset(15))
        #expect(error.summary == "Syntax error near 't'. Expected one of: token, Comma, FROM")
        #expect(!error.detail.contains("version"))
    }

    @Test func stackTracesAreDropped() {
        let error = SQLServerError.parse("Unknown expression identifier 'x' in scope SELECT x. Stack trace:\n\n0. DB::Exception::Exception(…) @ 0x0000000\n1. …")
        #expect(error.summary == "Unknown expression identifier 'x'")
        #expect(!error.detail.contains("Stack trace"))
    }

    @Test func kindLabelsComeFromTheErrorName() {
        #expect(SQLServerError.parse(Recorded.formT, code: 62, name: "SYNTAX_ERROR").kindLabel == "Syntax error")
        #expect(SQLServerError.parse(Recorded.formT).kindLabel == "Syntax error")
        #expect(SQLServerError.parse(Recorded.identifier, code: 47, name: "UNKNOWN_IDENTIFIER").kindLabel == "Unknown identifier")
        #expect(SQLServerError.parse(Recorded.parseDate, code: 38, name: "CANNOT_PARSE_DATE").kindLabel == "Cannot parse date")
        #expect(SQLServerError.parse("Connection refused").kindLabel == "Error")
    }

    // Without an editor position the title has no (statement-relative) position.
    @Test func titleUsesOnlyEditorPositions() {
        let error = SQLServerError.parse(Recorded.multiLine, code: 62, name: "SYNTAX_ERROR")
        #expect(error.title(at: nil) == "Syntax error")
        #expect(error.title(at: SQLTextPosition(line: 11, column: 4)) == "Syntax error at line 11, column 4")
        #expect(SQLServerError.parse(Recorded.table, code: 60, name: "UNKNOWN_TABLE").title(at: SQLTextPosition(line: 1, column: 15))
            == "Unknown table at line 1, column 15")
    }

    @Test(arguments: [
        (Recorded.formT, "Syntax error near 't'. Expected one of: token, Comma, FROM, PREWHERE, WHERE, GROUP BY, WITH, HAVING, WINDOW, QUALIFY, ORDER BY, LIMIT, …"),
        (Recorded.formT26, "Syntax error near 't'. Expected one of: token, Comma, FROM, PREWHERE, WHERE, GROUP BY, WITH, HAVING, WINDOW, QUALIFY, ORDER BY, LIMIT, …"),
        (Recorded.formT22, "Syntax error near 't'. Expected one of: token, Comma, FROM, PREWHERE, WHERE, GROUP BY, WITH, HAVING, WINDOW, ORDER BY, LIMIT, OFFSET, …"),
        (Recorded.endOfQuery, "Syntax error at end of query. Expected one of: expression with optional alias, element of expression with optional alias, lambda expression"),
        (Recorded.unmatched, "Syntax error: Unmatched parentheses"),
        (Recorded.unmatched26, "Syntax error: Unmatched parentheses"),
        (Recorded.string, "Syntax error: Single quoted string is not closed"),
        (Recorded.string26, "Syntax error: Single quoted string is not closed"),
        (Recorded.comment, "Syntax error: Multiline comment is not closed"),
        (Recorded.comment26, "Syntax error: Multiline comment is not closed"),
        (Recorded.identifier, "Unknown expression identifier 'x'"),
        (Recorded.identifier26, "Unknown expression identifier `x`"),
        (Recorded.missingColumns, "Missing columns: 'x'"),
        (Recorded.qualified, "Identifier 'e.nosuch' cannot be resolved from table with name e"),
        (Recorded.qualifiedOld, "There's no column 'e.nosuch' in table 'e'"),
        (Recorded.table, "Unknown table expression identifier 'shop.nosuch'"),
        (Recorded.tableOld, "Table shop.nosuch doesn't exist"),
        (Recorded.database, "Database nosuchdb does not exist"),
        (Recorded.function, "Function with name 'flor' does not exist. Maybe you meant: ['floor','xor']"),
        (Recorded.functionOld, "Unknown function flor. Maybe you meant: ['floor','log']"),
        (Recorded.aggregateOld, "Unknown function sumx: Or unknown aggregate function sumx. Maybe you meant: ['sum']"),
        (Recorded.aggregate26, "Function with name `sumx` does not exist. Maybe you meant: ['sum']"),
        (Recorded.quotedOld, "Missing columns: 'Weird Col'"),
        (Recorded.having26, "Unknown expression or function identifier `nosuch`"),
        (Recorded.tableFunction, "Unknown table function numbrs. Maybe you meant: ['numbers']"),
        (Recorded.settingOld, "Unknown setting max_threadz: Maybe you meant ['max_threads']"),
        (Recorded.havingOld, "Missing columns: 'nosuch'. Maybe you meant: ['number']"),
        (Recorded.parseDate, "Cannot parse date: value is too short: Cannot parse Date from String"),
    ])
    func summaries(message: String, expected: String) {
        #expect(SQLServerError.parse(message).summary == expected)
    }

    @Test func longAlternativeListsAreShortened() {
        let summary = SQLServerError.parse(Recorded.endOfQuery22).summary
        #expect(summary.hasPrefix("Syntax error at end of query. Expected one of: expression with optional alias, "))
        #expect(summary.hasSuffix(", …"))
        #expect(summary.count < 180)
        // The full text stays available.
        #expect(SQLServerError.parse(Recorded.endOfQuery22).detail.contains("MySQL-style global variable"))
    }

    @Test func longMessagesAreSummarised() {
        let echo = String(repeating: "x ", count: 100_000)
        let scoped = SQLServerError.parse("Unknown expression identifier 'x' in scope SELECT \(echo).")
        #expect(scoped.summary == "Unknown expression identifier 'x'")
        #expect(scoped.names == [["x"]])
        let unbounded = SQLServerError.parse("Cannot parse input: " + echo)
        #expect(unbounded.summary.count <= SQLServerError.summaryLimit + 1)
        #expect(unbounded.summary.hasSuffix("…"))
        let syntax = SQLServerError.parse("Syntax error: failed at position 3 ('x'): \(echo.prefix(160)). Expected one of: \(String(repeating: "alternative, ", count: 5_000))end of query.")
        #expect(syntax.position == .byteOffset(3))
        #expect(syntax.summary.count < 200)
    }

    // Messages are capped at 16 KB by the client, but an echoed query can be mostly whitespace.
    @Test func whitespaceHeavyMessagesStayCheap() {
        let clock = ContinuousClock()
        let started = clock.now
        let spaces = String(repeating: " ", count: 16_000)
        let error = SQLServerError.parse("Cannot parse input:\(spaces)x\(spaces)in scopX\(spaces)while processing querX")
        #expect(error.summary.hasPrefix("Cannot parse input"))
        #expect(clock.now - started < .seconds(1))
    }

    @Test(arguments: [
        (Recorded.identifier, [["x"]]),
        (Recorded.identifier26, [["x"]]),
        (Recorded.missingColumns, [["x"]]),
        (Recorded.qualified, [["e", "nosuch"]]),
        (Recorded.qualifiedOld, [["e", "nosuch"]]),
        (Recorded.quoted, [["Weird Col"]]),
        (Recorded.quoted26, [["Weird Col"]]),
        (Recorded.quotedOld, [["Weird Col"]]),
        (Recorded.table, [["shop", "nosuch"]]),
        (Recorded.unqualifiedTable, [["nosuch"]]),
        (Recorded.tableOld, [["shop", "nosuch"]]),
        (Recorded.database, [["nosuchdb"]]),
        (Recorded.databaseOld, [["nosuchdb"]]),
        (Recorded.function, [["flor"]]),
        (Recorded.function26, [["flor"]]),
        (Recorded.functionOld, [["flor"]]),
        (Recorded.aggregateOld, [["sumx"]]),
        (Recorded.aggregate26, [["sumx"]]),
        (Recorded.tableFunction, [["numbrs"]]),
        (Recorded.setting, [["max_threadz"]]),
        (Recorded.settingOld, [["max_threadz"]]),
        (Recorded.having, [["nosuch"]]),
        (Recorded.havingOld, [["nosuch"]]),
        (Recorded.having26, [["nosuch"]]),
        (Recorded.parseDate, []),
        (Recorded.formT, []),
        ("Table `shop`.`we``ird` doesn't exist.", [["shop", "we`ird"]]),
        ("Database `nosuchdb` does not exist.", [["nosuchdb"]]),
        ("No such column nosuch in table shop.events (abc-123).", [["nosuch"]]),
        ("Unknown data type family: Strin. Maybe you meant: ['String'].", [["Strin"]]),
    ])
    func namesInMessages(message: String, expected: [[String]]) {
        #expect(SQLServerError.parse(message).names == expected)
    }

    @Test func namesInTheEchoedQueryAreIgnored() {
        let error = SQLServerError.parse("Unknown expression identifier 'x' in scope SELECT x, 'Missing columns: \\'y\\'' FROM t.")
        #expect(error.names == [["x"]])
    }

    @Test func overflowingPositionsAreIgnored() {
        #expect(SQLServerError.parse("Syntax error: failed at position 99999999999999999999 ('t'): t.").position == nil)
    }
}

@Suite("Error location")
struct ErrorLocatorTests {
    @Test(arguments: [
        ("SELECT 1 FORM t", Recorded.formT, "t"),
        ("SELECT 1 FORM t", Recorded.formT26, "t"),
        ("SELECT 1 FORM t", Recorded.formT22, "t"),
        ("SELECT * FROM events WHERE", Recorded.endOfQuery, "WHERE"),
        ("SELECT 1,\n  2 FORM\n t", Recorded.multiLine, "t"),
        ("SELECT 'é🇲🇾', 1 FORM t", Recorded.multiByte, "t"),
        ("SELECT count(1", Recorded.unmatched, "("),
        ("SELECT count(1", Recorded.unmatched26, "("),
        ("SELECT 'abc", Recorded.string, "'"),
        ("SELECT 'abc", Recorded.string26, "'"),
        ("SELECT 1 /* x", Recorded.comment, "/*"),
        ("SELECT 1 /* x", Recorded.comment26, "/*"),
    ])
    func syntaxPositionsMarkTheirToken(statement: String, message: String, expected: String) {
        #expect(slice(statement, SQLErrorLocator.range(in: statement, message: message)) == expected)
    }

    @Test func endOfQueryAfterACommentMarksTheLastToken() {
        let sql = "SELECT * FROM events WHERE -- todo"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: "Syntax error: failed at position 35 (end of query): . Expected one of: lambda expression.")) == "WHERE")
    }

    @Test func nestedUnterminatedCommentMarksTheOuterOpener() {
        let sql = "SELECT 1 /* a /* b */ c"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: "Syntax error: failed at position 10 ('/* a /* b */ c'): /* a. Multiline comment is not closed.")) == "/*")
        // A terminated (nested) comment is skipped.
        let closed = "SELECT 1 /* a /* b */ */ FORM t"
        #expect(slice(closed, SQLErrorLocator.range(in: closed, message: "Syntax error: failed at position 31 ('t'): t.")) == "t")
    }

    @Test func largePositionsLocateTheRightToken() {
        let wide = "SELECT " + String(repeating: " ", count: 1200) + "1 FORM t"
        #expect(slice(wide, SQLErrorLocator.range(in: wide, message: "Syntax error: failed at position 1215 ('t'): t.")) == "t")
        let tall = "SELECT 1" + String(repeating: "\n", count: 1500) + "FORM t"
        #expect(slice(tall, SQLErrorLocator.range(in: tall, message: "Syntax error: failed at position 1514 ('t') (line 1501, col 6): t.")) == "t")
    }

    @Test(arguments: [
        ("SELECT x FROM events", Recorded.identifier, "x"),
        ("SELECT x FROM events", Recorded.identifier26, "x"),
        ("SELECT x FROM events", Recorded.missingColumns, "x"),
        ("SELECT e.nosuch FROM events AS e", Recorded.qualified, "e.nosuch"),
        ("SELECT e.nosuch FROM events AS e", Recorded.qualifiedOld, "e.nosuch"),
        ("SELECT `Weird Col` FROM events", Recorded.quoted, "`Weird Col`"),
        ("SELECT \"Weird Col\" FROM events", Recorded.quoted26, "\"Weird Col\""),
        ("SELECT `Weird Col` FROM events", Recorded.quotedOld, "`Weird Col`"),
        ("SELECT * FROM shop.nosuch", Recorded.table, "shop.nosuch"),
        ("SELECT * FROM nosuch", Recorded.unqualifiedTable, "nosuch"),
        ("SELECT * FROM nosuch", Recorded.tableOld, "nosuch"),
        ("SELECT * FROM `shop` . `nosuch`", Recorded.tableOld, "`shop` . `nosuch`"),
        ("SELECT * FROM nosuchdb.t", Recorded.database, "nosuchdb"),
        ("SELECT flor(1)", Recorded.function, "flor"),
        ("SELECT flor(1)", Recorded.functionOld, "flor"),
        ("SELECT sumx(1)", Recorded.aggregateOld, "sumx"),
        ("SELECT sumx(1)", Recorded.aggregate26, "sumx"),
        ("SELECT * FROM numbrs(10)", Recorded.tableFunction, "numbrs"),
        ("SELECT 1 SETTINGS max_threadz = 1", Recorded.setting, "max_threadz"),
        ("SELECT number FROM numbers(10) GROUP BY 1 HAVING nosuch > 1", Recorded.having, "nosuch"),
        ("SELECT number FROM numbers(10) GROUP BY 1 HAVING nosuch > 1", Recorded.having26, "nosuch"),
        ("SELECT number FROM numbers(10) GROUP BY 1 HAVING nosuch > 1", Recorded.havingOld, "nosuch"),
        ("SELECT 1 SETTINGS max_threadz = 1", Recorded.settingOld, "max_threadz"),
        ("SELECT * FROM nosuchdb.t", Recorded.databaseOld, "nosuchdb"),
        ("SELECT 吉 FROM t", "Unknown expression identifier '吉' in scope SELECT 吉 FROM t.", "吉"),
    ])
    func namedIdentifiers(statement: String, message: String, expected: String) {
        #expect(slice(statement, SQLErrorLocator.range(in: statement, message: message)) == expected)
    }

    @Test func exactSpellingWinsOverCaseInsensitive() {
        // ClickHouse identifiers are case-sensitive.
        let sql = "SELECT X, x FROM t"
        #expect(SQLErrorLocator.range(in: sql, message: Recorded.identifier) == utf16Offset(of: "x FROM", in: sql)..<(utf16Offset(of: "x FROM", in: sql) + 1))
        // Function names usually are not: fall back to a case-insensitive match.
        #expect(slice("SELECT FLOR(1)", SQLErrorLocator.range(in: "SELECT FLOR(1)", message: Recorded.function)) == "FLOR")
    }

    @Test func aDottedNameIsTriedWholeBeforeItsSuffix() {
        let sql = "SELECT b, `a.b` FROM t"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: "Unknown expression identifier 'a.b' in scope SELECT b, `a.b` FROM t.")) == "`a.b`")
    }

    @Test func namesInsideStringsAndCommentsAreSkipped() {
        let sql = "SELECT 'x', /* x */ -- x\n x FROM t"
        let range = SQLErrorLocator.range(in: sql, message: Recorded.identifier)
        #expect(range?.lowerBound == utf16Offset(of: " x FROM", in: sql) + 1)
    }

    @Test func unknownNamesAndMessagesGiveNoRange() {
        #expect(SQLErrorLocator.range(in: "SELECT 1", message: Recorded.identifier) == nil)
        #expect(SQLErrorLocator.range(in: "SELECT toDate('x')", message: Recorded.parseDate) == nil)
        #expect(SQLErrorLocator.range(in: "", message: "Syntax error: failed at position 1 (end of query): .") == nil)
        #expect(SQLErrorLocator.range(in: "-- only a comment", message: "Syntax error: failed at position 18 (end of query): .") == nil)
    }

    @Test func explainPrefixMapsBack() {
        let source = "SELECT 1 FORM t"
        let prefix = "EXPLAIN indexes = 1 "
        let mapping = SQLExecutedTextMapping(prefixLength: (prefix as NSString).length)
        let error = SQLServerError.parse("Syntax error: failed at position 35 ('t'): t. Expected one of: FROM.")
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: prefix + source, mapping: mapping, error: error)) == "t")
    }

    @Test func multiByteTextInsideThePrefixAndBefore() {
        // Byte positions are resolved in the executed text, then mapped back in UTF-16.
        let source = "SELECT '吉', 1 FORM t"
        let prefix = "EXPLAIN AST "
        let bytes = Array((prefix + source).utf8)
        let position = bytes.count // the `t`, 1-based
        let error = SQLServerError.parse("Syntax error: failed at position \(position) ('t'): t.")
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: prefix + source, mapping: SQLExecutedTextMapping(prefixLength: prefix.utf16.count), error: error)) == "t")
    }

    @Test func autoLimitInsertionMapsBack() throws {
        let source = "SELECT * FROM events WHERE -- todo"
        let outcome = AutoLimit.apply(to: source, limit: 10)
        #expect(outcome.applied)
        let insertion = try #require(outcome.insertion)
        #expect(insertion.lowerBound == utf16Offset(of: " -- todo", in: source))
        let mapping = SQLExecutedTextMapping(insertion: insertion)
        // A position inside the inserted LIMIT maps to the insertion point, after the last source token.
        let inside = insertion.lowerBound + 3
        let error = SQLServerError.parse("Syntax error: failed at position \(inside + 1) ('LIMIT'): x.")
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: outcome.sql, mapping: mapping, error: error)) == "WHERE")
        #expect(mapping.sourceOffset(forExecuted: (outcome.sql as NSString).length) == (source as NSString).length)
    }

    // The original API keeps working (start offset, no token expansion).
    @Test func offsetStillWorks() {
        let statement = "SELECT 1,\n  2 FRM t"
        #expect(SQLErrorLocator.offset(in: statement, message: "Syntax error: failed at position 19 ('t') (line 2, col 9): t.") == 18)
        #expect(SQLErrorLocator.offset(in: statement, message: Recorded.identifier) == nil)
    }
}

@Suite("Error location bounds")
struct ErrorLocatorBoundsTests {
    @Test func hugePositionsAreClamped() {
        let statement = "SELECT\n`x`"
        #expect(SQLErrorLocator.offset(in: statement, message: "Syntax error: failed at position 999999999 ('t')") == statement.utf16.count)
        #expect(slice(statement, SQLErrorLocator.range(in: statement, message: "Syntax error: failed at position 999999999 (end of query): .")) == "`x`")
        #expect(SQLErrorLocator.range(in: statement, message: "Syntax error: failed at position 3 ('t') (line 9, col 1): t.") == nil)
    }

    @Test func mappingNeverGoesNegative() {
        let mapping = SQLExecutedTextMapping(prefixLength: 8, insertion: 20..<29)
        #expect(mapping.sourceOffset(forExecuted: 0) == 0)
        #expect(mapping.sourceOffset(forExecuted: Int.max) == Int.max - 9 - 8)
        #expect(mapping.sourceOffset(forExecuted: 25) == 12)
    }
}

@Suite("Lexer: unterminated tokens")
struct UnterminatedTokenTests {
    private func last(_ text: String) -> (SQLLexer, SQLToken)? {
        let lexer = SQLLexer(text)
        guard let token = lexer.tokens().last else { return nil }
        return (lexer, token)
    }

    @Test(arguments: ["SELECT 'abc", "SELECT `abc", "SELECT \"abc", "SELECT 'a\\'", "SELECT 1 /* x", "SELECT 1 /* a /* b */", "SELECT 1 /*/", "SELECT 1 /*"])
    func unterminated(text: String) throws {
        let (lexer, token) = try #require(last(text))
        #expect(lexer.isUnterminated(token))
    }

    @Test(arguments: ["SELECT 'abc'", "SELECT `a``b`", "SELECT \"a\\\"b\"", "SELECT 1 /* a /* b */ */", "SELECT 1 /**/", "SELECT 1 -- x", "SELECT 1 # x", "SELECT x", "SELECT $$a$$"])
    func terminated(text: String) throws {
        let (lexer, token) = try #require(last(text))
        #expect(!lexer.isUnterminated(token))
    }

    @Test func heredocOpeners() {
        let lexer = SQLLexer("SELECT $$abc, $t$x, $1 + $2, $q$ok$q$")
        let text = "SELECT $$abc, $t$x, $1 + $2, $q$ok$q$" as NSString
        #expect(lexer.unterminatedHeredocOpener(at: text.range(of: "$$abc").location) == 7..<9)
        #expect(lexer.unterminatedHeredocOpener(at: text.range(of: "$t$").location).map { text.substring(with: NSRange($0)) } == "$t$")
        #expect(lexer.unterminatedHeredocOpener(at: text.range(of: "$1").location) == nil)
        #expect(lexer.unterminatedHeredocOpener(at: text.range(of: "$q$").location) == nil)
        #expect(lexer.unterminatedHeredocOpener(at: 0) == nil)
        #expect(lexer.unterminatedHeredocOpener(at: 9_999) == nil)
    }
}

@Suite("Local checks")
struct LinterTests {
    private func lint(_ text: String) -> [(SQLDiagnostic.Severity, String, String)] {
        SQLLinter.diagnose(text).map { ($0.severity, slice(text, $0.range) ?? "?", $0.message) }
    }

    @Test func unclosedParenthesis() {
        let found = lint("SELECT count(1 FROM t")
        #expect(found.count == 1)
        #expect(found.first?.0 == .error)
        #expect(found.first?.1 == "(")
        #expect(found.first?.2 == "'(' is not closed")
    }

    @Test func unmatchedClosers() {
        #expect(lint("SELECT 1)").map { [$0.1, $0.2] } == [[")", "Unmatched ')': there is no matching '(' before it"]])
        #expect(lint("SELECT 1]").map(\.1) == ["]"])
        #expect(lint("SELECT 1}").map(\.1) == ["}"])
    }

    @Test func bracketsOfEveryKind() {
        #expect(lint("SELECT [1, 2").map { [$0.1, $0.2] } == [["[", "'[' is not closed"]])
        // `]` matches the `[` below the unclosed `(`: the `(` is reported.
        #expect(lint("SELECT [1, (2]").map(\.1) == ["("])
        #expect(lint("SELECT map('a', [1, 2]), {'k': (1)}").isEmpty)
    }

    @Test func parenthesesArePerStatement() {
        let text = "SELECT (1; SELECT 2)"
        let diagnostics = SQLLinter.diagnose(text)
        #expect(diagnostics.map { slice(text, $0.range) } == ["(", ")"])
        #expect(diagnostics.first?.scope == 7..<9)
    }

    @Test func unterminatedQuotes() {
        #expect(lint("SELECT 'abc").map { [$0.1, $0.2] } == [["'", "Unterminated string: add the closing '"]])
        #expect(lint("SELECT \"abc").map { [$0.1, $0.2] } == [["\"", "Unterminated quoted identifier: add the closing \""]])
        #expect(lint("SELECT `abc").map(\.2) == ["Unterminated quoted identifier: add the closing `"])
        #expect(lint("SELECT 'a\\").map(\.1) == ["'"])
    }

    @Test func unterminatedQuoteSuppressesBracketNoise() {
        #expect(lint("SELECT count('abc)").map(\.1) == ["'"])
        #expect(lint("SELECT count($$abc)").map(\.1) == ["$$"])
    }

    @Test func unterminatedCommentsAreErrors() {
        let found = lint("SELECT 1 /* note")
        #expect(found.map(\.0) == [.error])
        #expect(found.map(\.1) == ["/*"])
        #expect(found.map(\.2) == ["Unterminated comment: add the closing */"])
        #expect(lint("SELECT 1 /* a /* b */").map(\.1) == ["/*"])
        #expect(lint("SELECT 1 /*/").map(\.0) == [.error])
    }

    @Test func unterminatedHeredocs() {
        #expect(lint("SELECT $$abc").map { [$0.1, $0.2] } == [["$$", "Unterminated heredoc: add the closing $$"]])
        let tagged = lint("SELECT $json$ {")
        #expect(tagged.map(\.0) == [.warning])
        #expect(tagged.map(\.1) == ["$json$"])
        #expect(tagged.map(\.2) == ["Unterminated heredoc? Add the closing $json$"])
    }

    @Test(arguments: ["SELECT 'it''s', \"a\\\"b\", (1), `x``y` FROM t", "SELECT 1 -- (", "/**/ SELECT (1)", "SELECT ')' FROM t", "", "SELECT 1 # )",
                      "SELECT $$ ( $$", "SELECT {p:UInt8}", "SELECT [1, (2)]", "/* /* nested */ */ SELECT 1", "SELECT $tag$x$tag$", "SELECT $1 + $2",
                      "SELECT 1 #! (", "SELECT t.1 FROM (SELECT (1, 2) AS t)"])
    func cleanTextHasNoDiagnostics(text: String) {
        #expect(SQLLinter.diagnose(text).isEmpty)
    }

    @Test func diagnosticsAreCapped() {
        #expect(SQLLinter.diagnose(String(repeating: ")", count: 500)).count == SQLLinter.maximumDiagnostics)
        #expect(SQLLinter.diagnose(String(repeating: "(", count: 500)).count == SQLLinter.maximumDiagnostics)
    }

    @Test func localDiagnosticsAreMarkedAsLocal() {
        #expect(SQLLinter.diagnose("SELECT (").allSatisfy { $0.source == .local })
    }
}

@Suite("Diagnostic edit tracking")
struct DiagnosticTrackingTests {
    private let diagnostic = SQLDiagnostic(range: 10..<14, scope: 5..<20, severity: .error, source: .server, message: "m")

    private func apply(_ edits: SQLTextEdit...) -> SQLDiagnostic? {
        SQLDiagnosticTracker.apply(edits, to: [diagnostic]).first
    }

    @Test func editBeforeShifts() {
        let moved = apply(SQLTextEdit(range: 0..<0, replacementLength: 3))
        #expect(moved?.range == 13..<17)
        #expect(moved?.scope == 8..<23)
    }

    @Test func separatedInsertionAtScopeStartShifts() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 2, separatorBeforeEnd: true))?.range == 12..<16)
    }

    @Test func gluedInsertionAtScopeStartDrops() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 1, separatorBeforeEnd: false)) == nil)
    }

    @Test func deletionEndingAtScopeStart() {
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: true))?.scope == 2..<17)
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: false)) == nil)
    }

    @Test func separatedInsertionAtScopeEndKeeps() {
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: true)) == diagnostic)
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: false)) == nil)
    }

    @Test func editAfterKeeps() {
        #expect(apply(SQLTextEdit(range: 21..<21, replacementLength: 1)) == diagnostic)
    }

    @Test(arguments: [SQLTextEdit(range: 12..<12, replacementLength: 1), SQLTextEdit(range: 20..<20, replacementLength: 1),
                      SQLTextEdit(range: 3..<6, replacementLength: 1), SQLTextEdit(range: 19..<25, replacementLength: 0),
                      SQLTextEdit(range: 0..<100, replacementLength: 0), SQLTextEdit(range: 6..<6, replacementLength: 1, separatorBeforeEnd: true)])
    func editTouchingTheScopeDrops(edit: SQLTextEdit) {
        #expect(SQLDiagnosticTracker.apply([edit], to: [diagnostic]).isEmpty)
    }

    @Test func sequencesApplyInOrder() {
        let roundTrip = apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 0..<3, replacementLength: 0))
        #expect(roundTrip == diagnostic)
        #expect(apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 14..<14, replacementLength: 1)) == nil)
    }

    @Test func rangeEditTracksASingleRange() {
        #expect(SQLTextEdit(range: 0..<0, replacementLength: 4).adjust(6..<9) == 10..<13)
        #expect(SQLTextEdit(range: 7..<7, replacementLength: 4).adjust(6..<9) == nil)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<0, replacementLength: 2)], to: [6..<9, nil]) == [8..<11, nil])
    }

    @Test func malformedEditsDrop() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<0, replacementLength: -5)], to: [diagnostic]).isEmpty)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<Int.max, replacementLength: 0)], to: [diagnostic]).isEmpty)
    }

    // The edit is described from the text after it.
    @Test func editsDescribedFromTheEditedText() throws {
        let glued = try #require(SQLTextEdit.made(in: "SELECT 1;xSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(!glued.separatorBeforeEnd)
        #expect(glued.adjust(9..<24) == nil)
        let newline = try #require(SQLTextEdit.made(in: "SELECT 1;\nSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(newline.adjust(9..<24) == 10..<25)
        let after = try #require(SQLTextEdit.made(in: "SELECT x FORM t\n", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(after.separatorAtStart)
        #expect(after.adjust(0..<15) == 0..<15)
        #expect(after.insertedLineBreaks == [0])
        let typed = try #require(SQLTextEdit.made(in: "SELECT x FORM tx", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(typed.adjust(0..<15) == nil)
        let merged = try #require(SQLTextEdit.made(in: "SELECT 1SELECT x", editedRange: NSRange(location: 8, length: 0), changeInLength: -1))
        #expect(merged.range == 8..<9)
        #expect(merged.adjust(9..<16) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 2, length: 5), changeInLength: 0) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 1, length: 1), changeInLength: 3) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: NSNotFound, length: 0), changeInLength: 0) == nil)
    }
}

@Suite("Local diagnostic tracking")
struct LocalTrackingTests {
    private let local = SQLDiagnostic(range: 12..<13, scope: 12..<20, severity: .error, source: .local, message: "'(' is not closed")

    @Test func typingInsideTheScopeKeepsTheMarker() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 15..<15, replacementLength: 1)], to: [local]).first
        #expect(moved?.range == 12..<13)
        #expect(moved?.scope == 12..<21)
    }

    @Test func typingRightAfterTheMarkKeepsIt() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 13..<13, replacementLength: 2)], to: [local]).first?.range == 12..<13)
    }

    @Test func insertionBeforeTheMarkShiftsIt() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 12..<12, replacementLength: 2)], to: [local]).first
        #expect(moved?.range == 14..<15)
        #expect(moved?.scope == 14..<22)
    }

    @Test func editingTheMarkedTextDrops() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 11..<13, replacementLength: 0)], to: [local]).isEmpty)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<Int.max, replacementLength: 0)], to: [local]).isEmpty)
    }
}

@Suite("Diagnostic navigation")
struct NavigationTests {
    @Test func adjacentDiagnosticsAreReachable() {
        let text = "SELECT count((a FROM t"
        let diagnostics = SQLLinter.diagnose(text)
        #expect(diagnostics.map(\.range) == [12..<13, 13..<14])
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 12) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 13) == 1)
    }

    @Test func preferenceResolvesTies() {
        let a = SQLDiagnostic(range: 5..<9, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 5..<6, scope: 5..<20, severity: .error, source: .local, message: "b")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5, preferred: b) == 1)
    }

    @Test func cursorPositions() {
        let a = SQLDiagnostic(range: 2..<10, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 4..<5, scope: 4..<20, severity: .error, source: .local, message: "b")
        let c = SQLDiagnostic(range: 14..<15, scope: 14..<20, severity: .error, source: .local, message: "c")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 4) == 1)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 7) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 15) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 12) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 0) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 99) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [], cursor: 0) == nil)
    }
}

@Suite("Line index")
struct LineIndexTests {
    @Test func positionsAreOneBasedCodePoints() {
        let text = "SELECT\n  '🇲🇾' x"
        let index = SQLLineIndex(text)
        #expect(index.lineStarts == [0, 7])
        #expect(index.position(of: utf16Offset(of: "x", in: text), in: text as NSString) == SQLTextPosition(line: 2, column: 8))
        #expect(index.position(of: 999, in: text as NSString) == SQLTextPosition(line: 2, column: 9))
        #expect(index.position(of: -1, in: text as NSString) == SQLTextPosition(line: 1, column: 1))
    }

    @Test func editsKeepTheIndexEqualToARebuild() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab\n;吉🇲🇾 ")
        var text = "SELECT 1;\nSELECT 2\n"
        var index = SQLLineIndex(text)
        for _ in 0..<1_500 {
            let units = Array(text.utf16)
            let start = Int.random(in: 0...units.count, using: &generator)
            let end = Int.random(in: start...min(units.count, start + 6), using: &generator)
            let inserted = String((0..<Int.random(in: 0...4, using: &generator)).compactMap { _ in alphabet.randomElement(using: &generator) })
            let updated = String(decoding: units[..<start], as: UTF16.self) + inserted + String(decoding: units[end...], as: UTF16.self)
            let insertedLength = updated.utf16.count - (units.count - (end - start))
            let edit = try #require(SQLTextEdit.made(in: updated as NSString, editedRange: NSRange(location: start, length: insertedLength),
                                                     changeInLength: insertedLength - (end - start)))
            let applied = index.apply(edit)
            #expect(applied)
            text = updated
            #expect(index == SQLLineIndex(text))
        }
    }

    @Test func invalidEditsAreRefused() {
        var index = SQLLineIndex("ab\ncd")
        let beyondEnd = index.apply(SQLTextEdit(range: 3..<9, replacementLength: 0))
        let negative = index.apply(SQLTextEdit(range: 0..<0, replacementLength: -1))
        #expect(!beyondEnd)
        #expect(!negative)
        #expect(index == SQLLineIndex("ab\ncd"))
    }
}

@Suite("Text positions")
struct TextPositionTests {
    @Test func lineAndColumnAreOneBasedCodePoints() {
        let text = "SELECT\n  e.x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "e.x", in: text), in: text) == SQLTextPosition(line: 2, column: 3))
        let emoji = "'🇲🇾' x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "x", in: emoji), in: emoji) == SQLTextPosition(line: 1, column: 6))
        #expect(SQLTextPosition.lineAndColumn(of: 999, in: "ab\nc") == SQLTextPosition(line: 2, column: 2))
        #expect(SQLTextPosition.lineAndColumn(of: -3, in: "ab") == SQLTextPosition(line: 1, column: 1))
    }
}

@Suite("Diagnostics robustness")
struct DiagnosticsFuzzTests {
    @Test func randomInputNeverCrashes() async {
        let alphabet = Array("select from 'x' \"y\" `z` -- # #! /* */ ; . , ( ) [ ] { } $$ $t$ {p:UInt8} 0x1F 1e9 吉 🇲🇾 é \\ \n")
        let messages = [Recorded.formT, Recorded.endOfQuery, Recorded.multiLine, Recorded.qualified, Recorded.tableOld, Recorded.function,
                        "Syntax error: failed at position 9999 ('x'): x.", "Syntax error: failed at position 3 ('x') (line 2, col 9999): x.",
                        "Unknown expression identifier `a`.`b` in scope x.", "Syntax error: failed at position 1 ('(): x."]
        // The messages do not depend on the text: parse them once (the locator is what meets random text).
        let errors = messages.map { SQLServerError.parse($0) }
        let positions = (1...120).map { SQLServerError.parse("Syntax error: failed at position \($0) ('x'): x.") }
        // On a thread of its own; the violations come back to be reported here.
        let violations: [String] = await onDedicatedThread {
            var violations: [String] = []
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<2_000 {
                let text = String((0..<Int.random(in: 0...80, using: &generator)).compactMap { _ in alphabet.randomElement(using: &generator) })
                let length = text.utf16.count
                let diagnostics = SQLLinter.diagnose(text)
                for diagnostic in diagnostics {
                    if !(diagnostic.range.lowerBound >= 0 && diagnostic.range.upperBound <= length) { violations.append(text.debugDescription) }
                    if !(diagnostic.scope.lowerBound <= diagnostic.range.lowerBound && diagnostic.range.upperBound <= diagnostic.scope.upperBound) { violations.append(text.debugDescription) }
                }
                for error in errors {
                    if let range = SQLErrorLocator.range(in: text, error: error) {
                        if !(range.lowerBound >= 0 && range.upperBound <= length && !range.isEmpty) { violations.append(text.debugDescription) }
                    }
                }
                let prefix = "EXPLAIN PLAN "
                let mapping = SQLExecutedTextMapping(prefixLength: prefix.utf16.count)
                if let error = positions.randomElement(using: &generator),
                   let range = SQLErrorLocator.range(in: text, executed: prefix + text, mapping: mapping, error: error) {
                    if !(range.lowerBound >= 0 && range.upperBound <= length && !range.isEmpty) { violations.append(text.debugDescription) }
                }
                let start = Int.random(in: 0...length, using: &generator)
                let end = Int.random(in: start...length, using: &generator)
                let edit = SQLTextEdit(range: start..<end, replacementLength: Int.random(in: 0...5, using: &generator),
                                       separatorBeforeEnd: Bool.random(using: &generator), separatorAtStart: Bool.random(using: &generator))
                for diagnostic in SQLDiagnosticTracker.apply([edit], to: diagnostics) {
                    if !(diagnostic.range.lowerBound >= 0) { violations.append(text.debugDescription) }
                }
                _ = SQLTextPosition.lineAndColumn(of: Int.random(in: -2...(length + 2), using: &generator), in: text)
            }
            return violations
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
    }
}
