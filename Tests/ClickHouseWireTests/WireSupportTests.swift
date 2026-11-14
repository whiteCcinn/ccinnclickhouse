import Compression
import Foundation
import Testing
@testable import ClickHouseWire

@Suite("Headers, quoting, query strings and gzip")
struct WireSupportTests {
    @Test func summaryHeader() throws {
        let header = #"{"read_rows":"20000000","read_bytes":"160000000","written_rows":"0","written_bytes":"0","total_rows_to_read":"20000000","result_rows":"3","result_bytes":"96","elapsed_ns":"242290459"}"#
        let summary = try #require(QueryProgress(headerValue: header))
        #expect(summary.readRows == 20_000_000)
        #expect(summary.readBytes == 160_000_000)
        #expect(summary.totalRowsToRead == 20_000_000)
        #expect(summary.resultRows == 3)
        #expect(summary.elapsedNanoseconds == 242_290_459)
        #expect(abs(summary.elapsedSeconds - 0.242290459) < 1e-9)
    }

    @Test func summaryHeaderIsTolerant() throws {
        // Numbers as JSON numbers, absurd values clamped, unknown keys ignored.
        let summary = try #require(QueryProgress(headerValue: #"{"read_rows":5,"read_bytes":"99999999999999999999999","peak_memory_usage":"10","x":true}"#))
        #expect(summary.readRows == 5)
        #expect(summary.readBytes == Int64.max)
        #expect(summary.peakMemoryUsage == 10)
        #expect(QueryProgress(headerValue: "not json") == nil)
        #expect(QueryProgress(headerValue: "[1,2]") == nil)
    }

    @Test func lastProgressHeaderWins() {
        let values = [#"{"read_rows":"1"}"#, #"{"read_rows":"7"}"#]
        #expect(QueryProgress.latest(fromHeaderValues: values)?.readRows == 7)
        // URLSession may join repeated headers with ", "
        #expect(QueryProgress.latest(fromHeaderValues: [values.joined(separator: ", ")])?.readRows == 7)
    }

    @Test func identifierQuoting() {
        #expect(SQLText.quoteIdentifier("events") == "`events`")
        #expect(SQLText.quoteIdentifier("we`ird\\name") == "`we\\`ird\\\\name`")
        #expect(SQLText.quoteIdentifier("nul\0byte") == "`nulbyte`")
        #expect(SQLText.qualified("db", "t") == "`db`.`t`")
        #expect(SQLText.qualified(nil, "t") == "`t`")
    }

    @Test func literalQuoting() {
        #expect(SQLText.literal("it's") == "'it\\'s'")
        #expect(SQLText.literal("a\\b\nc\t\0") == "'a\\\\b\\nc\\t\\0'")
        #expect(SQLText.literal("中文") == "'中文'")
    }

    @Test func queryString() throws {
        let url = try #require(QueryURL.build(base: URL(string: "https://ch.example.com:8443/proxy/")!,
                                               parameters: [("query_id", "ccinnch-sql-1"), ("database", "a&b=c d"),
                                                            ("format_tsv_null_representation", "\\N"), ("log_comment", "x+y")]))
        #expect(url.absoluteString == "https://ch.example.com:8443/proxy/?query_id=ccinnch-sql-1&database=a%26b%3Dc%20d&format_tsv_null_representation=%5CN&log_comment=x%2By")
    }

    @Test func crc32Vectors() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum([]) == 0)
        var crc = CRC32()
        crc.update(Array("1234".utf8))
        crc.update(Array("56789".utf8))
        #expect(crc.value == 0xCBF4_3926)
    }

    @Test func gzipRoundTrip() throws {
        let text = String(repeating: "SELECT number FROM system.numbers LIMIT 10;\n", count: 5_000)
        let input = Data(text.utf8)
        let compressed = try #require(Gzip.compress(input))
        #expect(compressed.count < input.count / 10)
        #expect(Array(compressed.prefix(3)) == [0x1F, 0x8B, 0x08])
        // Trailer: CRC-32 and size, little endian.
        let trailer = Array(compressed.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        #expect(crc == CRC32.checksum(Array(input)))
        #expect(size == UInt32(input.count))
        // The deflate stream between header and trailer decodes back to the input.
        let deflate = Array(compressed.dropFirst(10).dropLast(8))
        var output = [UInt8](repeating: 0, count: input.count + 16)
        let decoded = deflate.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        #expect(decoded == input.count)
        #expect(Data(output.prefix(decoded)) == input)
    }

    @Test func gzipEmptyInput() throws {
        let compressed = try #require(Gzip.compress(Data()))
        #expect(compressed.count >= 18)
    }
}
