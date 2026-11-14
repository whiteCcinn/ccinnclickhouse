import Foundation

/// Pieces of a table's engine definition (`system.tables.engine_full`).
public struct EngineDefinition: Sendable, Equatable {
    public var engine: String
    /// Top-level engine arguments as written (`'/clickhouse/tables/{shard}/t'`, `'{replica}'`).
    public var arguments: [String]
    public var partitionBy: String?
    public var primaryKey: String?
    public var orderBy: String?
    public var sampleBy: String?
    public var ttl: String?
    public var settings: [(name: String, value: String)]

    public static func == (lhs: EngineDefinition, rhs: EngineDefinition) -> Bool {
        lhs.engine == rhs.engine && lhs.arguments == rhs.arguments && lhs.partitionBy == rhs.partitionBy && lhs.primaryKey == rhs.primaryKey
            && lhs.orderBy == rhs.orderBy && lhs.sampleBy == rhs.sampleBy && lhs.ttl == rhs.ttl
            && lhs.settings.map(\.name) == rhs.settings.map(\.name) && lhs.settings.map(\.value) == rhs.settings.map(\.value)
    }

    public func setting(_ name: String) -> String? { settings.first { $0.name == name }?.value }

    static let clauses = ["PARTITION BY", "PRIMARY KEY", "ORDER BY", "SAMPLE BY", "TTL", "SETTINGS", "COMMENT"]

    public static func parse(_ text: String) -> EngineDefinition {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var definition = EngineDefinition(engine: "", arguments: [], settings: [])
        let scalars = Array(source.unicodeScalars)
        var index = 0
        while index < scalars.count, DDLScanner.isIdentifierPart(scalars[index]) { index += 1 }
        definition.engine = String(String.UnicodeScalarView(scalars[0..<index]))
        var rest = index
        while rest < scalars.count, scalars[rest].properties.isWhitespace { rest += 1 }
        if rest < scalars.count, scalars[rest] == "(", let close = DDLScanner.matchingParenthesis(scalars, open: rest) {
            definition.arguments = DDLScanner.splitTopLevel(Array(scalars[(rest + 1)..<close]), separator: ",")
                .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            rest = close + 1
        }
        let remainder = Array(scalars[min(rest, scalars.count)...])
        let found = DDLScanner.topLevelClauses(remainder, keywords: clauses)
        for (keyword, body) in found {
            switch keyword {
            case "PARTITION BY": definition.partitionBy = body
            case "PRIMARY KEY": definition.primaryKey = body
            case "ORDER BY": definition.orderBy = body
            case "SAMPLE BY": definition.sampleBy = body
            case "TTL": definition.ttl = body
            case "SETTINGS": definition.settings = parseSettings(body)
            default: break
            }
        }
        return definition
    }

    static func parseSettings(_ body: String) -> [(name: String, value: String)] {
        DDLScanner.splitTopLevel(Array(body.unicodeScalars), separator: ",").compactMap { piece in
            let text = String(String.UnicodeScalarView(piece))
            guard let equals = text.firstIndex(of: "=") else { return nil }
            let name = text[..<equals].trimmingCharacters(in: .whitespaces)
            var value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            return name.isEmpty ? nil : (name, value)
        }
    }

    /// `Distributed(cluster, database, table[, sharding_key[, policy]])` arguments, unquoted.
    public var distributedTarget: (cluster: String, database: String, table: String, shardingKey: String?)? {
        guard engine == "Distributed", arguments.count >= 3 else { return nil }
        return (DDLScanner.unquote(arguments[0]), DDLScanner.unquote(arguments[1]), DDLScanner.unquote(arguments[2]),
                arguments.count > 3 ? arguments[3] : nil)
    }

    /// Keeper path and replica name of a Replicated* table.
    public var replicationPath: (path: String, replica: String)? {
        guard engine.hasPrefix("Replicated"), arguments.count >= 2 else { return nil }
        return (DDLScanner.unquote(arguments[0]), DDLScanner.unquote(arguments[1]))
    }
}

/// Column-level details only available from the CREATE statement.
public struct CreateStatementDetails: Sendable, Equatable {
    /// Column name → TTL expression.
    public var columnTTLs: [String: String] = [:]
    /// Projections declared in the statement (name, definition).
    public var projections: [(name: String, definition: String)] = []
    /// `TO db.table` of a materialized view.
    public var materializedViewTarget: String?

    public init() {}

    public static func == (lhs: CreateStatementDetails, rhs: CreateStatementDetails) -> Bool {
        lhs.columnTTLs == rhs.columnTTLs && lhs.materializedViewTarget == rhs.materializedViewTarget
            && lhs.projections.map(\.name) == rhs.projections.map(\.name) && lhs.projections.map(\.definition) == rhs.projections.map(\.definition)
    }

    public static func parse(_ statement: String) -> CreateStatementDetails {
        var details = CreateStatementDetails()
        let scalars = Array(statement.unicodeScalars)
        guard scalars.count <= 4 * 1024 * 1024 else { return details }
        let upper = statement.uppercased()
        if upper.hasPrefix("CREATE MATERIALIZED VIEW"), let to = DDLScanner.topLevelClauses(scalars, keywords: ["TO", "AS", "ENGINE", "REFRESH", "EMPTY"])
            .first(where: { $0.keyword == "TO" }) {
            let target = to.body.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? to.body
            details.materializedViewTarget = target.isEmpty ? nil : target
        }
        // Column list: the first top-level parenthesis.
        guard let open = DDLScanner.firstTopLevel(scalars, "("), let close = DDLScanner.matchingParenthesis(scalars, open: open) else { return details }
        for piece in DDLScanner.splitTopLevel(Array(scalars[(open + 1)..<close]), separator: ",") {
            let text = String(String.UnicodeScalarView(piece)).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = text.split(separator: " ", maxSplits: 1).map(String.init)
            guard let first = words.first else { continue }
            switch first.uppercased() {
            case "INDEX", "CONSTRAINT", "PRIMARY", "STATISTICS":
                continue
            case "PROJECTION":
                let remainder = words.count > 1 ? words[1] : ""
                let name = remainder.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let definition = remainder.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
                details.projections.append((DDLScanner.unquote(name), definition))
            default:
                let definition = text.dropFirst(first.count)
                let clauses = DDLScanner.topLevelClauses(Array(definition.unicodeScalars),
                                                         keywords: ["TTL", "CODEC", "COMMENT", "DEFAULT", "MATERIALIZED", "ALIAS", "EPHEMERAL", "SETTINGS", "STATISTICS"])
                if let ttl = clauses.first(where: { $0.keyword == "TTL" }) {
                    details.columnTTLs[DDLScanner.unquote(first)] = ttl.body
                }
            }
        }
        return details
    }
}

/// Quote- and parenthesis-aware scanning helpers for server-formatted DDL.
enum DDLScanner {
    static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "_"
    }

    /// Index of the `)` matching `open`, skipping quoted text.
    static func matchingParenthesis(_ scalars: [Unicode.Scalar], open: Int) -> Int? {
        var depth = 0
        var index = open
        var quote: Unicode.Scalar?
        while index < scalars.count {
            let scalar = scalars[index]
            if let active = quote {
                if scalar == "\\" { index += 2; continue }
                if scalar == active { quote = nil }
            } else if scalar == "'" || scalar == "`" || scalar == "\"" {
                quote = scalar
            } else if scalar == "(" {
                depth += 1
            } else if scalar == ")" {
                depth -= 1
                if depth == 0 { return index }
                if depth < 0 { return nil }
            }
            index += 1
        }
        return nil
    }

    static func firstTopLevel(_ scalars: [Unicode.Scalar], _ target: Unicode.Scalar) -> Int? {
        var quote: Unicode.Scalar?
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if let active = quote {
                if scalar == "\\" { index += 2; continue }
                if scalar == active { quote = nil }
            } else if scalar == "'" || scalar == "`" || scalar == "\"" {
                quote = scalar
            } else if scalar == target {
                return index
            }
            index += 1
        }
        return nil
    }

    static func splitTopLevel(_ scalars: [Unicode.Scalar], separator: Unicode.Scalar) -> [[Unicode.Scalar]] {
        var pieces: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var depth = 0
        var quote: Unicode.Scalar?
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if let active = quote {
                current.append(scalar)
                if scalar == "\\", index + 1 < scalars.count {
                    current.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == active { quote = nil }
            } else if scalar == "'" || scalar == "`" || scalar == "\"" {
                quote = scalar
                current.append(scalar)
            } else if scalar == "(" || scalar == "[" {
                depth += 1
                current.append(scalar)
            } else if scalar == ")" || scalar == "]" {
                depth = max(0, depth - 1)
                current.append(scalar)
            } else if scalar == separator, depth == 0 {
                pieces.append(current)
                current = []
            } else {
                current.append(scalar)
            }
            index += 1
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Splits text at top-level keywords (whole words, depth 0, outside quotes) and returns each
    /// keyword with its trimmed body, in order.
    static func topLevelClauses(_ scalars: [Unicode.Scalar], keywords: [String]) -> [(keyword: String, body: String)] {
        let keywordScalars = keywords.map { Array($0.unicodeScalars) }
        var found: [(keyword: String, start: Int, bodyStart: Int)] = []
        var depth = 0
        var quote: Unicode.Scalar?
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if let active = quote {
                if scalar == "\\" { index += 2; continue }
                if scalar == active { quote = nil }
                index += 1
                continue
            }
            if scalar == "'" || scalar == "`" || scalar == "\"" {
                quote = scalar
            } else if scalar == "(" || scalar == "[" {
                depth += 1
            } else if scalar == ")" || scalar == "]" {
                depth = max(0, depth - 1)
            } else if depth == 0, index == 0 || !isIdentifierPart(scalars[index - 1]) {
                var matched = false
                for (offset, keyword) in keywordScalars.enumerated() where matches(scalars, at: index, keyword) {
                    let end = index + keyword.count
                    if end == scalars.count || !isIdentifierPart(scalars[end]) {
                        found.append((keywords[offset], index, end))
                        index = end
                        matched = true
                        break
                    }
                }
                if matched { continue }
            }
            index += 1
        }
        return found.enumerated().map { offset, entry in
            let end = offset + 1 < found.count ? found[offset + 1].start : scalars.count
            let body = String(String.UnicodeScalarView(scalars[min(entry.bodyStart, end)..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
            return (entry.keyword, body)
        }
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ keyword: [Unicode.Scalar]) -> Bool {
        guard index + keyword.count <= scalars.count else { return false }
        for offset in keyword.indices {
            let candidate = scalars[index + offset]
            let expected = keyword[offset]
            if candidate == expected { continue }
            // Server-formatted DDL writes keywords in upper case; identifiers such as `ttl` must not match.
            if expected == " ", candidate.properties.isWhitespace { continue }
            return false
        }
        return true
    }

    /// Removes one level of `'…'`, `` `…` `` or `"…"` quoting (with backslash escapes).
    static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, ["'", "`", "\""].contains(first), trimmed.count >= 2, trimmed.last == first else { return trimmed }
        var output = ""
        var escaped = false
        for character in trimmed.dropFirst().dropLast() {
            if escaped {
                output.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                output.append(character)
            }
        }
        return output
    }
}
