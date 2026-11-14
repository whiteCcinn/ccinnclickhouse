import Foundation
import Testing
@testable import ClickHouseWire

@Suite("TabSeparatedWithNamesAndTypes parser")
struct TSVParserTests {
    static let header = "a\tb\tc\td\te\tf\tg\th\nUInt8\tString\tNullable(Nothing)\tFloat64\tArray(UInt8)\tMap(String, UInt8)\tArray(String)\tNullable(String)\n"
    /// Recorded from ClickHouse 24.8 (`SELECT 1 AS a, 'x\\y' AS b, NULL AS c, nan AS d, [1,2] AS e, map('k\tz', 1) AS f, ['a\tb'] AS g, toNullable('\\N') AS h`).
    static let recorded = header + "1\tx\\\\y\t\\N\tnan\t[1,2]\t{'k\\tz':1}\t['a\\tb']\t\\\\N\n"

    static func parseAll(_ text: String, chunkSize: Int = .max, tag: String? = nil, abruptly: Bool = false) throws -> (columns: [ColumnDefinition]?, rows: [[String?]]) {
        var parser = TSVResultParser(exceptionTag: tag)
        var rows: [[String?]] = []
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + max(1, chunkSize == .max ? bytes.count : chunkSize))
            rows += try parser.consume(Array(bytes[offset..<end]))
            offset = end
        }
        rows += try parser.finish(abruptly: abruptly)
        return (parser.columns, rows)
    }

    @Test func recordedResult() throws {
        let (columns, rows) = try Self.parseAll(Self.recorded)
        #expect(columns?.map(\.name) == ["a", "b", "c", "d", "e", "f", "g", "h"])
        #expect(columns?[1].type.kind == .string)
        #expect(columns?[4].type.isComposite == true)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row[0] == "1")
        #expect(row[1] == "x\\y")
        #expect(row[2] == nil)
        #expect(row[3] == "nan")
        #expect(row[4] == "[1,2]")
        // Composite values stay in ClickHouse literal syntax.
        #expect(row[5] == "{'k\\tz':1}")
        #expect(row[6] == "['a\\tb']")
        // A string that is literally backslash-N is not NULL.
        #expect(row[7] == "\\N")
    }

    @Test func everyChunkingGivesTheSameResult() throws {
        let text = Self.recorded + "2\tline\\nbreak\t\\N\t-inf\t[]\t{}\t[]\t\\N\n"
        let expected = try Self.parseAll(text)
        for size in [1, 2, 3, 7, 16, 64] {
            let chunked = try Self.parseAll(text, chunkSize: size)
            #expect(chunked.rows == expected.rows)
            #expect(chunked.columns == expected.columns)
        }
        #expect(expected.rows[1][1] == "line\nbreak")
    }

    @Test func escapes() {
        let decoded = TSVResultParser.unescape(Array("a\\tb\\nc\\\\d\\'e\\0f\\bg\\fh\\ri\\zj".utf8))
        #expect(decoded == "a\tb\nc\\d'e\0f\u{08}g\u{0C}h\ri" + "zj")
        #expect(TSVResultParser.unescape(Array("trailing\\".utf8)) == "trailing\\")
    }

    @Test func emptyResultHasColumns() throws {
        let (columns, rows) = try Self.parseAll("n\nUInt64\n")
        #expect(columns?.count == 1)
        #expect(rows.isEmpty)
    }

    @Test func noBodyMeansNoResultSet() throws {
        let (columns, rows) = try Self.parseAll("")
        #expect(columns == nil)
        #expect(rows.isEmpty)
    }

    @Test func singleColumnEmptyStrings() throws {
        let (_, rows) = try Self.parseAll("s\nString\n\n\nx\n")
        #expect(rows == [[""], [""], ["x"]])
    }

    @Test func invalidUTF8IsReplacedNotFatal() throws {
        var bytes = Array("s\nString\n".utf8)
        bytes += [0xFF, 0xFE, 0x41, 0x0A]
        var parser = TSVResultParser()
        let rows = try parser.consume(bytes) + parser.finish(abruptly: false)
        #expect(rows.count == 1)
        #expect(rows[0][0]?.hasSuffix("A") == true)
    }

    @Test func midStreamExceptionClassic() {
        // 22.x / 24.x: the exception text is appended after the last complete row and the body ends normally.
        let text = "number\tthrowIf(equals(number, 200000))\nUInt64\tUInt8\n199998\t0\n199999\t0\n"
            + "Code: 395. DB::Exception: Value passed to 'throwIf' function is non-zero: while executing 'FUNCTION throwIf()'. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 24.8.14.39 (official build))\n"
        #expect(throws: ClickHouseServerException.self) { try Self.parseAll(text) }
        do {
            _ = try Self.parseAll(text)
        } catch let error as ClickHouseServerException {
            #expect(error.code == 395)
            #expect(error.name == "FUNCTION_THROW_IF_VALUE_IS_NON_ZERO")
            #expect(error.message.hasPrefix("Value passed to 'throwIf'"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func midStreamExceptionSingleColumn() {
        // In a one-column String result the exception line has the "right" shape; it only counts at the end of the stream.
        let tail = "Code: 241. DB::Exception: Memory limit (total) exceeded. (MEMORY_LIMIT_EXCEEDED) (version 22.8.21.38 (official build))\n"
        #expect(throws: ClickHouseServerException.self) { try Self.parseAll("s\nString\nhello\n" + tail) }
    }

    @Test func exceptionLookingValueInTheMiddleIsData() throws {
        let value = "Code: 1. DB::Exception: not really. (X) (version 1.0)"
        let (_, rows) = try Self.parseAll("s\nString\n\(value)\nnext\n")
        #expect(rows == [[value], ["next"]])
    }

    @Test func midStreamExceptionBrokenChunking() {
        // 25.x appends the exception and then breaks the chunked encoding (transport error).
        let text = "n\tx\nUInt64\tUInt8\n1\t0\nCode: 395. DB::Exception: boom. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 25.8.33.6 (official build))\n"
        do {
            _ = try Self.parseAll(text, abruptly: true)
            Issue.record("expected an exception")
        } catch let error as ClickHouseServerException {
            #expect(error.code == 395)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func midStreamExceptionTagFraming() {
        // 26.x framing announced by X-ClickHouse-Exception-Tag.
        let tag = "kyxfbvxszeugdkuu"
        let message = "Code: 395. DB::Exception: Value passed to 'throwIf' function is non-zero. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 26.8.23.6 (official build))\n"
        let text = "n\tx\nUInt64\tUInt8\n199999\t0\n\r\n__exception__\r\n\(tag)\r\n\(message)\(message.utf8.count) \(tag)\r\n__exception__\r\n"
        for chunk in [1, 5, 4096] {
            do {
                _ = try Self.parseAll(text, chunkSize: chunk, tag: tag, abruptly: true)
                Issue.record("expected an exception")
            } catch let error as ClickHouseServerException {
                #expect(error.code == 395)
                #expect(error.message.contains("throwIf"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func truncatedStreamWithoutExceptionIsReported() {
        #expect(throws: TSVParseError.self) { try Self.parseAll("n\tx\nUInt64\tUInt8\n1\t0\n2\t", abruptly: true) }
        #expect(throws: TSVParseError.self) { try Self.parseAll("n\tx\nUInt64\tUInt8\n1\t0\n2\t") }
    }

    @Test func malformedRowWithoutExceptionIsAProtocolError() {
        #expect(throws: TSVParseError.self) { try Self.parseAll("n\tx\nUInt64\tUInt8\n1\t0\t9\n") }
    }

    @Test func lineLengthIsBounded() {
        var parser = TSVResultParser(maxLineBytes: 64)
        #expect(throws: TSVParseError.self) {
            _ = try parser.consume(Array(("s\nString\n" + String(repeating: "x", count: 200)).utf8))
        }
    }

    @Test func fuzzNeverTraps() {
        var generator = SplitMix64(seed: 42)
        let alphabet: [UInt8] = Array("ab\t\n\\N'Code: 1. DB::Exception: (version )\r_".utf8) + [0xFF, 0xC3, 0x00]
        for _ in 0..<3_000 {
            var parser = TSVResultParser(exceptionTag: generator.next() % 2 == 0 ? "tag" : nil, maxLineBytes: 512)
            var bytes = Array("a\tb\nString\tNullable(UInt8)\n".utf8)
            for _ in 0..<Int(generator.next() % 200) { bytes.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
            var offset = 0
            do {
                while offset < bytes.count {
                    let end = min(bytes.count, offset + 1 + Int(generator.next() % 17))
                    _ = try parser.consume(Array(bytes[offset..<end]))
                    offset = end
                }
                _ = try parser.finish(abruptly: generator.next() % 2 == 0)
            } catch {
                // errors are fine, traps are not
            }
        }
    }
}

@Suite("Server exceptions")
struct ExceptionTests {
    @Test func parsesHTTPBody() throws {
        let body = "Code: 60. DB::Exception: Table default.x does not exist. (UNKNOWN_TABLE) (version 24.8.14.39 (official build))\n"
        let exception = try #require(ClickHouseServerException.parse(body))
        #expect(exception.code == 60)
        #expect(exception.name == "UNKNOWN_TABLE")
        #expect(exception.message == "Table default.x does not exist.")
        #expect(exception.version == "24.8.14.39")
    }

    @Test func parsesUserPrefixAndMissingName() throws {
        let body = "Code: 516. DB::Exception: ccinn: Authentication failed: password is incorrect, or there is no user with such name. (AUTHENTICATION_FAILED) (version 24.8.14.39 (official build))"
        let exception = try #require(ClickHouseServerException.parse(body))
        #expect(exception.code == 516)
        #expect(exception.message.hasPrefix("ccinn: Authentication failed"))
        let old = try #require(ClickHouseServerException.parse("Code: 62, e.displayText() = DB::Exception: Syntax error: failed at position 1"))
        #expect(old.code == 62)
        #expect(old.message.hasPrefix("Syntax error"))
    }

    @Test func rejectsNonClickHouseText() {
        #expect(ClickHouseServerException.parse("<html>502 Bad Gateway</html>") == nil)
        #expect(ClickHouseServerException.parse("Code: x. DB::Exception: y") == nil)
        #expect(ClickHouseServerException.parse("Code: 99999999999999999999999. DB::Exception: y")?.code == nil)
    }

    @Test func syntaxErrorPosition() throws {
        let message = "Syntax error: failed at position 19 ('t') (line 2, col 9): t. Expected one of: token"
        #expect(ClickHouseServerException.errorPosition(in: message) == .lineColumn(line: 2, column: 9))
        #expect(ClickHouseServerException.errorPosition(in: "Syntax error: failed at position 8 ('FRM'): FRM t") == .byteOffset(8))
        #expect(ClickHouseServerException.errorPosition(in: "Syntax error: failed at position 99999999999999999999999") == nil)
        #expect(ClickHouseServerException.errorPosition(in: "no position") == nil)
    }
}
