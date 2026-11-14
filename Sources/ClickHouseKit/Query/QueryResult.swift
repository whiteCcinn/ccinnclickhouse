import ClickHouseWire
import Foundation

/// Case-insensitive column-name → index map shared by every record of a result.
public struct ColumnLookup: Sendable, Equatable {
    private let indices: [String: Int]
    public let names: [String]

    public init(names: [String]) {
        self.names = names
        var indices: [String: Int] = [:]
        indices.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            let key = name.lowercased()
            if indices[key] == nil { indices[key] = index }
        }
        self.indices = indices
    }

    /// Index of the first of `names` that exists (alternatives cover renamed columns across versions).
    public func index(of names: [String]) -> Int? {
        for name in names {
            if let index = indices[name.lowercased()] { return index }
        }
        return nil
    }
}

/// One row with access by column name (metadata is never read by position, design D10).
public struct Record: Sendable {
    public let values: [String?]
    let lookup: ColumnLookup

    public init(values: [String?], lookup: ColumnLookup) {
        self.values = values
        self.lookup = lookup
    }

    public func raw(_ names: String...) -> String? { raw(names) }

    public func raw(_ names: [String]) -> String? {
        guard let index = lookup.index(of: names), index < values.count else { return nil }
        return values[index]
    }

    public func has(_ name: String) -> Bool { lookup.index(of: [name]) != nil }

    /// Trimmed text; `nil` for missing columns, NULL and empty strings.
    public func text(_ names: String...) -> String? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Integer, saturating at the Int64 bounds (UInt64 counters never trap).
    public func int(_ names: String...) -> Int64? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let integer = TextValue.integer(value) { return integer }
        // `1.5e9`-style values from float columns.
        guard let double = TextValue.double(value) else { return nil }
        if double >= 9.2e18 { return .max }
        if double <= -9.2e18 { return .min }
        return Int64(double.rounded(.towardZero))
    }

    public func double(_ names: String...) -> Double? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return TextValue.double(value)
    }

    public func bool(_ names: String...) -> Bool? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch value {
        case "true", "1", "yes", "y", "on": return true
        case "false", "0", "no", "n", "off": return false
        default: return nil
        }
    }

    /// `Array(String)` text such as `['a','b\'c']` → `["a", "b'c"]` (best effort; empty on anything unexpected).
    public func stringArray(_ names: String...) -> [String] {
        guard let value = raw(names) else { return [] }
        return ArrayLiteral.strings(value)
    }
}

/// Parses ClickHouse array literals produced by the server.
public enum ArrayLiteral {
    public static func strings(_ text: String) -> [String] {
        let scalars = Array(text.trimmingCharacters(in: .whitespaces).unicodeScalars)
        guard scalars.first == "[", scalars.last == "]" else { return [] }
        var values: [String] = []
        var index = 1
        while index < scalars.count - 1 {
            let scalar = scalars[index]
            if scalar == "'" {
                var value = String.UnicodeScalarView()
                index += 1
                while index < scalars.count - 1, scalars[index] != "'" {
                    if scalars[index] == "\\", index + 1 < scalars.count - 1 {
                        index += 1
                        switch scalars[index] {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "r": value.append("\r")
                        case "0": value.append("\0")
                        default: value.append(scalars[index])
                        }
                    } else {
                        value.append(scalars[index])
                    }
                    index += 1
                }
                values.append(String(value))
            } else if scalar != ",", !scalar.properties.isWhitespace {
                // unquoted element (numbers): read to the next comma
                var value = String.UnicodeScalarView()
                while index < scalars.count - 1, scalars[index] != "," {
                    value.append(scalars[index])
                    index += 1
                }
                values.append(String(value).trimmingCharacters(in: .whitespaces))
                continue
            }
            index += 1
        }
        return values
    }
}

/// The outcome of one statement: a row set (`columns` non-empty), raw text (explicit `FORMAT`),
/// or nothing (DDL/INSERT), plus server statistics.
public struct QueryResult: Sendable {
    public let columns: [ColumnDefinition]
    public let rows: [[String?]]
    /// More rows/bytes existed than the limits allowed; the rest was not read.
    public let isTruncated: Bool
    public let queryID: String
    /// Final `X-ClickHouse-Summary` (statistics at the time the response started).
    public let summary: QueryProgress?
    public let serverDisplayName: String?
    /// Output format when it was not the typed TSV format (the body is in `rawText`).
    public let format: String?
    public let rawText: String?
    /// The server session had expired and was recreated before this statement ran.
    public let sessionRecreated: Bool
    /// Raw bytes of cells that are not valid UTF-8 (their `rows` text is a lossy rendering).
    public let binaryCells: [CellAddress: Data]
    public let lookup: ColumnLookup

    public struct CellAddress: Sendable, Hashable {
        public let row: Int
        public let column: Int
        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    public init(columns: [ColumnDefinition], rows: [[String?]], isTruncated: Bool = false, queryID: String = "",
                summary: QueryProgress? = nil, serverDisplayName: String? = nil, format: String? = nil, rawText: String? = nil,
                sessionRecreated: Bool = false, binaryCells: [CellAddress: Data] = [:]) {
        self.columns = columns
        self.rows = rows
        self.isTruncated = isTruncated
        self.queryID = queryID
        self.summary = summary
        self.serverDisplayName = serverDisplayName
        self.format = format
        self.rawText = rawText
        self.sessionRecreated = sessionRecreated
        self.binaryCells = binaryCells
        lookup = ColumnLookup(names: columns.map(\.name))
    }

    func with(sessionRecreated: Bool) -> QueryResult {
        QueryResult(columns: columns, rows: rows, isTruncated: isTruncated, queryID: queryID, summary: summary,
                    serverDisplayName: serverDisplayName, format: format, rawText: rawText, sessionRecreated: sessionRecreated,
                    binaryCells: binaryCells)
    }

    public var hasRowSet: Bool { !columns.isEmpty }
    public var columnNames: [String] { columns.map(\.name) }

    public func record(at index: Int) -> Record? {
        guard rows.indices.contains(index) else { return nil }
        return Record(values: rows[index], lookup: lookup)
    }

    public var records: [Record] { rows.map { Record(values: $0, lookup: lookup) } }
    public var first: Record? { record(at: 0) }
    /// Raw bytes of a cell for export: the original bytes for binary cells, UTF-8 otherwise.
    public func bytes(row: Int, column: Int) -> Data? {
        if let raw = binaryCells[CellAddress(row: row, column: column)] { return raw }
        guard rows.indices.contains(row), rows[row].indices.contains(column), let text = rows[row][column] else { return nil }
        return Data(text.utf8)
    }

    /// First column of the first row (scalar queries).
    public var scalar: String? { rows.first?.first ?? nil }

    /// Rows written by an INSERT (from the summary header).
    public var writtenRows: Int64 { summary?.writtenRows ?? 0 }
}

/// Bounds applied while reading a result (design D9).
public struct RowLimits: Sendable, Equatable {
    public var maxRows: Int
    /// Bytes of response body consumed before stopping.
    public var maxBytes: Int
    /// Largest single row accepted.
    public var maxLineBytes: Int

    public init(maxRows: Int = 100_000, maxBytes: Int = 512 * 1024 * 1024, maxLineBytes: Int = 64 * 1024 * 1024) {
        self.maxRows = max(0, maxRows)
        self.maxBytes = max(1024, maxBytes)
        self.maxLineBytes = max(1024, maxLineBytes)
    }

    public static let metadata = RowLimits(maxRows: 100_000, maxBytes: 256 * 1024 * 1024)
}
