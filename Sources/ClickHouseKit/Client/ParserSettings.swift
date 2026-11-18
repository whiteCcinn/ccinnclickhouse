import Foundation

/// Settings that change how ClickHouse parses a statement or resolves its names. A settings profile can set them:
/// `dialect = 'polyglot'` with `polyglot_dialect = 'postgresql'` reads `'\'` as a complete string (no backslash escapes),
/// and `implicit_table_at_top_level` gives a SELECT without FROM a table. Either way the read-only guard would judge a
/// different statement than the server runs. Read-only requests send the safe values where the server accepts them, and
/// every read-only request path verifies the effective values, failing closed.
public enum ParserSettings {
    public struct Expectation: Sendable, Equatable {
        public let name: String
        public let value: String
    }

    /// Verified on every read-only request path. A server without the setting (22.8 has no `dialect`) counts as having it
    /// at this value.
    public static let verified: [Expectation] = [
        Expectation(name: "dialect", value: "clickhouse"),
        Expectation(name: "implicit_table_at_top_level", value: ""),
        Expectation(name: "implicit_select", value: "0"),
        Expectation(name: "polyglot_dialect", value: ""),
        Expectation(name: "enable_json_ast_dialect", value: "0"),
    ]

    /// Sent with every read-only request where the server accepts settings (a profile with readonly=1 refuses them all):
    /// every verified setting at its safe value, so a profile that changes one of them is neutralised rather than refused.
    public static let forced: [Expectation] = verified

    /// Settings whose name or description concerns dialects, the parser or implicit tables, reviewed as unable to change
    /// what a read-only statement reads once the verified ones hold: they enable dialects (the dialect itself is
    /// verified), configure another dialect, limit the parser, or concern data formats and implicit transactions.
    public static let reviewed: Set<String> = [
        "allow_experimental_kusto_dialect", "allow_experimental_polyglot_dialect", "allow_experimental_prql_dialect",
        "cast_string_to_date_time_mode", "date_time_input_format", "evaluation_time", "force_data_skipping_indices", "implicit_transaction",
        "input_format_json_validate_types_from_metadata", "input_format_parquet_allow_geoparquet_parser",
        "input_format_read_datetime_number_as_raw_value", "input_format_values_deduce_templates_of_expressions",
        "input_format_values_interpret_expressions", "input_format_with_names_use_header", "input_format_with_types_use_header",
        "json_extract_use_cast_string_to_date_time_mode", "max_parser_backtracks", "max_parser_depth", "max_query_size", "promql_database",
        "promql_evaluation_time", "promql_table",
    ]

    /// Whether a setting may change parsing or name resolution: `dialect*`, `polyglot*`, `implicit_*`, `*_ast_dialect`, or
    /// a description that mentions a dialect, the parser or an implicit table. Each such setting must be verified or
    /// reviewed (the per-version integration test checks every setting a server has).
    public static func mayAffectParsing(name: String, description: String) -> Bool {
        let lowerName = name.lowercased()
        if lowerName.contains("dialect") || lowerName.contains("polyglot") || lowerName.hasPrefix("implicit_") { return true }
        let text = description.lowercased()
        return text.contains("dialect") || text.contains("parser") || text.contains("implicit table")
    }

    /// The effective values, with `readonly` (which every version has) as proof that the table could be read.
    public static let query: String = {
        let names: [String] = ["readonly"] + verified.map(\.name)
        return "SELECT name, value FROM system.settings WHERE name IN (" + names.map { "'\($0)'" }.joined(separator: ", ") + ")"
    }()

    /// Why a read-only request path with these effective values is unsafe; `nil` when it is safe. `values` maps setting
    /// names to values as system.settings printed them; a missing `readonly` means they could not be read.
    public static func refusal(_ values: [String: String]) -> String? {
        guard let readonly = values["readonly"], let level = Int(readonly) else {
            return "The connection's effective settings could not be read, so read-only access cannot be confirmed."
        }
        guard level >= 1 else {
            return "ClickHouse does not apply readonly on this connection's request path (a proxy may drop it), so read-only access is off."
        }
        for expectation in verified {
            guard let value = values[expectation.name], value != expectation.value else { continue }
            return "The connection's settings profile sets \(expectation.name) = '\(value.prefix(80))', which changes how ClickHouse parses statements or resolves names, so read-only access is off. Read-only access needs \(expectation.name) = '\(expectation.value)': remove it from the profile (a profile with readonly=1 also stops CcinnClickHouse from overriding it per request)."
        }
        return nil
    }
}

extension ClickHouseClient {
    /// Checks the read-only request path as this connection sends it (the forced settings included): readonly ≥ 1 and the
    /// parser settings the read-only guard assumes. `nil` when safe; fails closed when the settings cannot be read.
    public func readOnlyRequestPathRefusal() async -> String? {
        do {
            let result = try await run(ParserSettings.query, options: QueryOptions(purpose: "meta", limits: .metadata, timeout: 30, readOnly: true,
                                                                                    idempotent: true))
            var values: [String: String] = [:]
            for row in result.rows where row.count >= 2 {
                if let name = row[0] { values[name] = row[1] ?? "" }
            }
            return ParserSettings.refusal(values)
        } catch {
            return "The connection's effective settings could not be read (\((error as? ClickHouseError)?.message.prefix(200) ?? "error")), so read-only access cannot be confirmed."
        }
    }
}
