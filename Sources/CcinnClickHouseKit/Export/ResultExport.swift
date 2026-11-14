import ClickHouseKit
import ClickHouseWire
import Foundation

/// CSV / TSV rendering of results.
public enum ResultExport {
    /// RFC 4180 CSV text. Text cells that a spreadsheet would evaluate as a formula (`=`, `+`, `-`, `@`,
    /// tab, CR) are prefixed with `'`; numeric columns are left untouched so negative numbers survive.
    public static func csv(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool = true) -> String {
        var output = Data()
        write(columns: columns, rows: rows, binaryCells: [:], separator: ",", includeHeader: includeHeader) { output.append($0) }
        return String(decoding: output, as: UTF8.self)
    }

    /// Streams CSV (or TSV) to a file in ~1 MB chunks. Cells that were not valid UTF-8 are written with
    /// their original bytes.
    public static func write(to url: URL, result: QueryResult, format: Format = .csv) throws {
        try write(to: url, columns: result.columns, rows: result.rows, binaryCells: result.binaryCells, format: format)
    }

    public enum Format: Sendable {
        case csv, tsv
    }

    public static func write(to url: URL, columns: [ColumnDefinition], rows: [[String?]], binaryCells: [QueryResult.CellAddress: Data] = [:],
                             format: Format = .csv) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = Data()
        var failure: (any Error)?
        write(columns: columns, rows: rows, binaryCells: binaryCells, separator: format == .csv ? "," : "\t", includeHeader: true) { chunk in
            guard failure == nil else { return }
            buffer.append(chunk)
            if buffer.count >= 1 << 20 {
                do { try handle.write(contentsOf: buffer) } catch { failure = error }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if let failure { throw failure }
        try handle.write(contentsOf: buffer)
    }

    private static func write(columns: [ColumnDefinition], rows: [[String?]], binaryCells: [QueryResult.CellAddress: Data], separator: String,
                              includeHeader: Bool, emit: (Data) -> Void) {
        let numeric = columns.map(\.type.isNumeric)
        let csv = separator == ","
        let separatorData = Data(separator.utf8)
        let newline = Data((csv ? "\r\n" : "\n").utf8)
        if includeHeader {
            var line = Data()
            for (index, column) in columns.enumerated() {
                if index > 0 { line.append(separatorData) }
                line.append(Data((csv ? escapeCSV(column.name, neutralize: true) : cleanTSV(column.name)).utf8))
            }
            line.append(newline)
            emit(line)
        }
        for (rowIndex, row) in rows.enumerated() {
            var line = Data()
            for index in columns.indices {
                if index > 0 { line.append(separatorData) }
                if let raw = binaryCells[QueryResult.CellAddress(row: rowIndex, column: index)] {
                    line.append(csv ? escapeCSVBytes(raw) : cleanTSVBytes(raw))
                    continue
                }
                guard index < row.count, let value = row[index] else { continue }
                line.append(Data((csv ? escapeCSV(value, neutralize: !numeric[index]) : cleanTSV(value)).utf8))
            }
            line.append(newline)
            emit(line)
        }
    }

    static func escapeCSV(_ value: String, neutralize: Bool) -> String {
        var value = value
        if neutralize, let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || value != value.trimmingCharacters(in: .whitespaces) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Binary cells are always quoted (quotes doubled) so arbitrary bytes cannot break the row structure.
    static func escapeCSVBytes(_ bytes: Data) -> Data {
        var output = Data([0x22])
        for byte in bytes {
            if byte == 0x22 { output.append(0x22) }
            output.append(byte)
        }
        output.append(0x22)
        return output
    }

    static func cleanTSVBytes(_ bytes: Data) -> Data {
        Data(bytes.map { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
    }

    /// Tab-separated text for the clipboard (pastes into spreadsheets); NULL becomes empty.
    public static func tsv(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool = true) -> String {
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        if includeHeader { lines.append(columns.map { cleanTSV($0.name) }.joined(separator: "\t")) }
        for row in rows {
            lines.append(columns.indices.map { index in index < row.count ? cleanTSV(row[index] ?? "") : "" }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    static func cleanTSV(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return value }
        return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// `INSERT INTO t (…) VALUES (…);` statements for the selected rows. Numbers stay bare, composite
    /// values (arrays, tuples, maps) are already ClickHouse literals, everything else is quoted.
    public static func insertStatements(table: String, columns: [ColumnDefinition], rows: [[String?]]) -> String {
        let columnList = columns.map { SQLText.quoteIdentifier($0.name) }.joined(separator: ", ")
        return rows.map { row in
            let values = columns.indices.map { index -> String in
                guard index < row.count, let value = row[index] else { return "NULL" }
                let type = columns[index].type
                if type.isNumeric, TextValue.double(value) != nil || TextValue.integer(value) != nil { return value }
                if type.isComposite { return value }
                return SQLText.literal(value)
            }.joined(separator: ", ")
            return "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
        }.joined(separator: "\n")
    }

    /// Hex dump of raw bytes (value inspector for binary cells).
    public static func hexDump(_ bytes: Data, limit: Int = 64 * 1024) -> String {
        var lines: [String] = []
        let shown = bytes.prefix(limit)
        var offset = 0
        while offset < shown.count {
            let slice = shown[shown.startIndex + offset..<shown.startIndex + min(offset + 16, shown.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(slice.map { $0 >= 0x20 && $0 < 0x7F ? Character(Unicode.Scalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii)
            offset += 16
        }
        if bytes.count > limit { lines.append("… \(bytes.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }
}
