import Foundation

/// A ClickHouse data type as reported in result headers and `system.columns` (`Nullable(String)`,
/// `Array(Tuple(a UInt8, b String))`, `DateTime64(3, 'UTC')`, `Enum8('a' = 1)`, …).
///
/// Parsing never fails: text that does not follow the grammar (or nests deeper than
/// ``maxDepth``) becomes an opaque type whose name is the raw text and whose kind is `.other`.
public struct ClickHouseType: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case integer, float, decimal, boolean
        case string, uuid, ipAddress
        case date, dateTime, time, interval
        case enumeration
        case array, tuple, map, nested
        case json, variant, aggregateState, geo
        case nothing, other
    }

    public indirect enum Argument: Sendable, Hashable {
        case type(ClickHouseType)
        case number(String)
        case string(String)
        /// `name Type` inside `Tuple(…)`, `Nested(…)` and `JSON(…)`.
        case named(String, ClickHouseType)
        /// `'name' = value` inside `Enum8(…)` / `Enum16(…)`.
        case enumEntry(String, Int64)
        /// Anything else (`max_types = 8`, `SKIP a.b`), kept verbatim.
        case raw(String)
    }

    public let name: String
    public let arguments: [Argument]
    /// The text this type was parsed from (trimmed).
    public let raw: String

    public static let maxDepth = 32
    static let maxLength = 64 * 1024

    public init(name: String, arguments: [Argument] = [], raw: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.raw = raw ?? ClickHouseType.render(name: name, arguments: arguments)
    }

    public static func parse(_ text: String) -> ClickHouseType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxLength else { return ClickHouseType(name: trimmed, raw: trimmed) }
        var parser = TypeParser(Array(trimmed.unicodeScalars))
        if let type = parser.parseType(depth: 0), parser.atEnd {
            return ClickHouseType(name: type.name, arguments: type.arguments, raw: trimmed)
        }
        return ClickHouseType(name: trimmed, raw: trimmed)
    }

    // MARK: Classification

    /// Kind of the value after removing `Nullable`, `LowCardinality` and `SimpleAggregateFunction`.
    public var kind: Kind { unwrapped.ownKind }

    /// The type without `Nullable` / `LowCardinality` / `SimpleAggregateFunction` wrappers.
    public var unwrapped: ClickHouseType {
        var current = self
        for _ in 0..<Self.maxDepth {
            switch current.name {
            case "Nullable", "LowCardinality":
                guard case let .type(inner)? = current.arguments.first, current.arguments.count == 1 else { return current }
                current = inner
            case "SimpleAggregateFunction":
                guard case let .type(inner)? = current.arguments.last, current.arguments.count == 2 else { return current }
                current = inner
            default:
                return current
            }
        }
        return current
    }

    /// `Nullable` at any wrapper level (`LowCardinality(Nullable(String))` is nullable).
    public var isNullable: Bool {
        var current = self
        for _ in 0..<Self.maxDepth {
            if current.name == "Nullable" { return true }
            guard current.name == "LowCardinality" || current.name == "SimpleAggregateFunction",
                  case let .type(inner)? = current.arguments.last else { return false }
            current = inner
        }
        return false
    }

    /// Values rendered in ClickHouse literal syntax (`[1,2]`, `(1,'a')`, `{'k':1}`) rather than as escaped text.
    public var isComposite: Bool {
        switch kind {
        case .array, .tuple, .map, .nested: true
        default: false
        }
    }

    public var isNumeric: Bool {
        switch kind {
        case .integer, .float, .decimal: true
        default: false
        }
    }

    public var isTemporal: Bool { kind == .date || kind == .dateTime }

    /// Element type of an `Array`.
    public var elementType: ClickHouseType? {
        let base = unwrapped
        guard base.name == "Array", case let .type(element)? = base.arguments.first else { return nil }
        return element
    }

    /// Explicit time zone of `DateTime('tz')` / `DateTime64(p, 'tz')`.
    public var timeZone: String? {
        let base = unwrapped
        guard base.name.hasPrefix("DateTime") else { return nil }
        for argument in base.arguments {
            if case let .string(zone) = argument { return zone }
        }
        return nil
    }

    private var ownKind: Kind {
        let upper = name.uppercased()
        switch upper {
        case "UINT8", "UINT16", "UINT32", "UINT64", "UINT128", "UINT256", "INT8", "INT16", "INT32", "INT64", "INT128", "INT256",
             "TINYINT", "SMALLINT", "INT", "INTEGER", "BIGINT", "TINYINT UNSIGNED", "BYTE":
            return .integer
        case "FLOAT32", "FLOAT64", "BFLOAT16", "FLOAT", "DOUBLE", "REAL": return .float
        case "DECIMAL", "DECIMAL32", "DECIMAL64", "DECIMAL128", "DECIMAL256", "NUMERIC", "DEC": return .decimal
        case "BOOL", "BOOLEAN": return .boolean
        case "STRING", "FIXEDSTRING", "TEXT", "VARCHAR", "CHAR", "BLOB", "BINARY", "VARBINARY": return .string
        case "UUID": return .uuid
        case "IPV4", "IPV6": return .ipAddress
        case "DATE", "DATE32": return .date
        case "DATETIME", "DATETIME32", "DATETIME64", "TIMESTAMP": return .dateTime
        case "TIME", "TIME64": return .time
        case "ENUM", "ENUM8", "ENUM16": return .enumeration
        case "ARRAY": return .array
        case "TUPLE": return .tuple
        case "MAP": return .map
        case "NESTED": return .nested
        case "JSON", "OBJECT": return .json
        case "VARIANT", "DYNAMIC": return .variant
        case "AGGREGATEFUNCTION": return .aggregateState
        case "POINT", "RING", "LINESTRING", "MULTILINESTRING", "POLYGON", "MULTIPOLYGON", "GEOMETRY": return .geo
        case "NOTHING": return .nothing
        default:
            return upper.hasPrefix("INTERVAL") && upper.count > 8 ? .interval : .other
        }
    }

    // MARK: Rendering

    public var description: String { raw }

    static func render(name: String, arguments: [Argument]) -> String {
        guard !arguments.isEmpty else { return name }
        return name + "(" + arguments.map(render).joined(separator: ", ") + ")"
    }

    static func render(_ argument: Argument) -> String {
        switch argument {
        case let .type(type): type.raw
        case let .number(number): number
        case let .string(text): quote(text)
        case let .named(name, type): "\(name) \(type.raw)"
        case let .enumEntry(name, value): "\(quote(name)) = \(value)"
        case let .raw(text): text
        }
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

/// Recursive-descent parser over unicode scalars with a depth limit.
private struct TypeParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    var atEnd: Bool {
        var probe = index
        while probe < scalars.count, scalars[probe].properties.isWhitespace { probe += 1 }
        return probe == scalars.count
    }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private mutating func skipWhitespace() {
        while let scalar = current, scalar.properties.isWhitespace { index += 1 }
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z") || scalar == "_"
    }

    private static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || (scalar >= "0" && scalar <= "9")
    }

    private mutating func identifier() -> String? {
        guard let first = current, Self.isIdentifierStart(first) else { return nil }
        var name = String.UnicodeScalarView()
        while let scalar = current, Self.isIdentifierPart(scalar) {
            name.append(scalar)
            index += 1
        }
        return String(name)
    }

    /// `Name` or `Name(arg, …)`.
    mutating func parseType(depth: Int) -> ClickHouseType? {
        guard depth < ClickHouseType.maxDepth else { return nil }
        skipWhitespace()
        guard let name = identifier() else { return nil }
        let afterName = index
        skipWhitespace()
        guard current == "(" else {
            index = afterName
            return ClickHouseType(name: name)
        }
        guard let close = matchingParenthesis(from: index) else { return nil }
        let inner = Array(scalars[(index + 1)..<close])
        index = close + 1
        var arguments: [ClickHouseType.Argument] = []
        for piece in Self.splitArguments(inner) {
            guard let argument = Self.parseArgument(piece, depth: depth + 1) else { return nil }
            arguments.append(argument)
        }
        return ClickHouseType(name: name, arguments: arguments)
    }

    /// Index of the `)` that closes the `(` at `open`, skipping quoted text.
    private func matchingParenthesis(from open: Int) -> Int? {
        var depth = 0
        var position = open
        var quote: Unicode.Scalar?
        while position < scalars.count {
            let scalar = scalars[position]
            if let active = quote {
                if scalar == "\\" {
                    position += 2
                    continue
                }
                if scalar == active { quote = nil }
            } else if scalar == "'" || scalar == "`" || scalar == "\"" {
                quote = scalar
            } else if scalar == "(" {
                depth += 1
            } else if scalar == ")" {
                depth -= 1
                if depth == 0 { return position }
            }
            position += 1
        }
        return nil
    }

    /// Splits at top-level commas (outside parentheses and quotes). Empty pieces are kept so that
    /// `Tuple(a, ,)` is rejected.
    static func splitArguments(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var pieces: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var depth = 0
        var quote: Unicode.Scalar?
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            if let active = quote {
                current.append(scalar)
                if scalar == "\\", position + 1 < scalars.count {
                    current.append(scalars[position + 1])
                    position += 2
                    continue
                }
                if scalar == active { quote = nil }
            } else if scalar == "'" || scalar == "`" || scalar == "\"" {
                quote = scalar
                current.append(scalar)
            } else if scalar == "(" {
                depth += 1
                current.append(scalar)
            } else if scalar == ")" {
                depth -= 1
                current.append(scalar)
            } else if scalar == ",", depth == 0 {
                pieces.append(current)
                current = []
            } else {
                current.append(scalar)
            }
            position += 1
        }
        pieces.append(current)
        return pieces
    }

    static func parseArgument(_ piece: [Unicode.Scalar], depth: Int) -> ClickHouseType.Argument? {
        let text = String(String.UnicodeScalarView(piece)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let scalars = Array(text.unicodeScalars)

        // 'string' or 'name' = value
        if scalars[0] == "'" {
            var parser = TypeParser(scalars)
            guard let literal = parser.stringLiteral() else { return .raw(text) }
            if parser.atEnd { return .string(literal) }
            parser.skipWhitespace()
            if parser.current == "=" {
                parser.index += 1
                let rest = String(String.UnicodeScalarView(scalars[parser.index...])).trimmingCharacters(in: .whitespaces)
                if let value = Int64(rest) { return .enumEntry(literal, value) }
            }
            return .raw(text)
        }
        // number
        if scalars[0] == "-" || scalars[0] == "+" || (scalars[0] >= "0" && scalars[0] <= "9") {
            let numeric = scalars.allSatisfy { ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }
            return numeric ? .number(text) : .raw(text)
        }
        // nested type
        var typeParser = TypeParser(scalars)
        if let type = typeParser.parseType(depth: depth), typeParser.atEnd {
            return .type(type)
        }
        if depth >= ClickHouseType.maxDepth { return nil }
        // name Type
        var namedParser = TypeParser(scalars)
        if let name = namedParser.elementName(), let first = namedParser.current, first.properties.isWhitespace {
            if let type = namedParser.parseType(depth: depth), namedParser.atEnd {
                return .named(name, type)
            }
        }
        return .raw(text)
    }

    /// Identifier (dots allowed, for JSON paths) or back-quoted name.
    private mutating func elementName() -> String? {
        if current == "`" {
            index += 1
            var name = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                if scalar == "\\", let next = current {
                    name.append(next)
                    index += 1
                    continue
                }
                if scalar == "`" { return String(name) }
                name.append(scalar)
            }
            return nil
        }
        guard let first = current, Self.isIdentifierStart(first) else { return nil }
        var name = String.UnicodeScalarView()
        while let scalar = current, Self.isIdentifierPart(scalar) || scalar == "." {
            name.append(scalar)
            index += 1
        }
        return String(name)
    }

    /// `'…'` with backslash escapes and doubled quotes.
    private mutating func stringLiteral() -> String? {
        guard current == "'" else { return nil }
        index += 1
        var value = String.UnicodeScalarView()
        while let scalar = current {
            index += 1
            if scalar == "\\" {
                guard let next = current else { return nil }
                index += 1
                switch next {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "0": value.append("\0")
                default: value.append(next)
                }
                continue
            }
            if scalar == "'" {
                if current == "'" {
                    value.append("'")
                    index += 1
                    continue
                }
                return String(value)
            }
            value.append(scalar)
        }
        return nil
    }
}
