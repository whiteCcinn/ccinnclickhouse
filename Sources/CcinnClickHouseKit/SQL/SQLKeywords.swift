import Foundation

/// Keyword vocabulary for ClickHouse SQL (highlighting, completion, quoting).
public enum SQLKeywords {
    /// Words highlighted as keywords.
    public static let all: Set<String> = Set("""
    ADD ADMIN AFTER ALIAS ALL ALTER AND ANTI ANY ARRAY AS ASC ASOF ASYNC ATTACH BACKUP BEGIN BETWEEN BOTH BY CASE CAST CHECK \
    CLEAR CLUSTER CODEC COLLATE COLUMN COLUMNS COMMENT COMMIT CONSTRAINT CREATE CROSS CUBE CURRENT DATABASE DATABASES DATE \
    DAY DEDUPLICATE DEFAULT DELETE DESC DESCRIBE DETACH DETACHED DICTIONARIES DICTIONARY DISTINCT DIV DROP ELSE EMPTY END \
    ENGINE ENGINES EPHEMERAL ESTIMATE EVENTS EXCEPT EXCHANGE EXISTS EXPLAIN EXPRESSION FALSE FETCH FILL FINAL FIRST FOLLOWING \
    FOR FORMAT FREEZE FROM FULL FUNCTION FUNCTIONS GLOBAL GRANT GRANULARITY GROUP GROUPING HAVING HOUR ID IF ILIKE IN INDEX \
    INDEXES INF INNER INSERT INTERPOLATE INTERSECT INTERVAL INTO IS JOIN KEY KILL LAST LAYOUT LEADING LEFT LIFETIME LIKE \
    LIMIT LIVE LOCAL LOGS MATERIALIZE MATERIALIZED MAX MERGES MIN MINUTE MODIFY MONTH MOVE MUTATION NAN NATURAL NO NOT NULL \
    NULLS OFFSET ON OPTIMIZE OR ORDER OUTER OUTFILE OVER OVERRIDE PARALLEL PART PARTITION PARTS PASTE PIPELINE PLAN POLICY \
    POPULATE PRECEDING PREWHERE PRIMARY PRIVILEGES PROCESSLIST PROFILE PROJECTION QUARTER QUERY QUOTA RANGE RECOMPRESS \
    RECURSIVE REFRESH RELOAD REMOVE RENAME REPLACE REPLICA REPLICAS RESET RESTORE REVOKE RIGHT ROLE ROLES ROLLBACK ROLLUP ROW \
    ROWS SAMPLE SECOND SELECT SEMI SETTINGS SET SHOW SOURCE START STEP STOP SUBSTRING SYNC SYNTAX SYSTEM TABLE TABLES \
    TEMPORARY TEST THEN TIES TIMESTAMP TO TOP TOTALS TRAILING TRANSACTION TREE TRIM TRUE TRUNCATE TTL TYPE UNBOUNDED UNDROP \
    UNFREEZE UNION UPDATE USE USER USERS USING UUID VALUES VIEW VOLUME WATCH WEEK WHEN WHERE WINDOW WITH YEAR
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Words that must be back-quoted when used as identifiers.
    public static let reserved: Set<String> = Set("""
    ALL ALTER AND ANTI ANY ARRAY AS ASC ASOF BETWEEN BY CASE CAST CREATE CROSS DATABASE DEFAULT DELETE DESC DESCRIBE DISTINCT \
    DROP ELSE END EXCEPT EXISTS EXPLAIN FALSE FINAL FORMAT FROM FULL GLOBAL GROUP HAVING IF ILIKE IN INNER INSERT INTERSECT \
    INTERVAL INTO IS JOIN KEY KILL LEFT LIKE LIMIT NOT NULL OFFSET ON OR ORDER OUTER PARTITION PREWHERE PRIMARY RIGHT SAMPLE \
    SELECT SEMI SET SETTINGS SHOW TABLE THEN TO TOP TRUE UNION UPDATE USING VALUES WHEN WHERE WITH
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Keywords that start a statement.
    public static let statementStarters: [String] = [
        "SELECT", "WITH", "SHOW", "DESCRIBE", "EXPLAIN", "EXPLAIN PIPELINE", "EXPLAIN indexes = 1", "EXISTS", "USE", "SET",
        "INSERT INTO", "ALTER TABLE", "ALTER TABLE … UPDATE", "ALTER TABLE … DELETE WHERE", "DELETE FROM", "OPTIMIZE TABLE",
        "CREATE TABLE", "CREATE DATABASE", "CREATE MATERIALIZED VIEW", "CREATE VIEW", "CREATE DICTIONARY", "DROP TABLE",
        "TRUNCATE TABLE", "RENAME TABLE", "EXCHANGE TABLES", "KILL QUERY WHERE", "KILL MUTATION WHERE", "SYSTEM RELOAD DICTIONARY",
        "SYSTEM FLUSH LOGS", "SYSTEM STOP MERGES", "SYSTEM START MERGES", "SYSTEM SYNC REPLICA", "CHECK TABLE", "DETACH TABLE",
        "ATTACH TABLE", "GRANT", "REVOKE",
    ]

    /// Useful `SHOW` targets.
    public static let showTargets: [String] = [
        "DATABASES", "TABLES", "TABLES FROM", "DICTIONARIES", "CREATE TABLE", "CREATE DICTIONARY", "CREATE VIEW", "CREATE USER",
        "COLUMNS FROM", "INDEXES FROM", "PROCESSLIST", "CLUSTERS", "CLUSTER", "SETTINGS LIKE", "CHANGED SETTINGS", "FUNCTIONS",
        "ENGINES", "GRANTS", "USERS", "ROLES", "PROFILES", "QUOTAS", "ACCESS", "MERGES", "FILESYSTEM CACHES", "PRIVILEGES",
    ]

    /// Clause keywords offered inside a query.
    public static let clauseKeywords: [String] = [
        "FROM", "WHERE", "PREWHERE", "GROUP BY", "WITH TOTALS", "WITH ROLLUP", "WITH CUBE", "HAVING", "QUALIFY", "ORDER BY",
        "WITH FILL", "LIMIT", "LIMIT BY", "OFFSET", "SETTINGS", "FORMAT", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN",
        "FULL OUTER JOIN", "CROSS JOIN", "ANY LEFT JOIN", "ASOF JOIN", "LEFT ARRAY JOIN", "ARRAY JOIN", "GLOBAL IN", "GLOBAL JOIN",
        "ON", "USING", "AS", "AND", "OR", "NOT", "IN", "IS NULL", "IS NOT NULL", "LIKE", "ILIKE", "BETWEEN", "CASE", "WHEN",
        "THEN", "ELSE", "END", "DISTINCT", "DISTINCT ON", "UNION ALL", "EXCEPT", "INTERSECT", "EXISTS", "OVER", "PARTITION BY",
        "ASC", "DESC", "NULLS FIRST", "NULLS LAST", "INTERVAL", "FINAL", "SAMPLE",
    ]
}

/// A function offered by completion (from `system.functions`, or the static fallback).
public struct SQLFunction: Sendable, Hashable {
    public let name: String
    public let isAggregate: Bool
    public let signature: String?
    public let summary: String?

    public init(name: String, isAggregate: Bool, signature: String? = nil, summary: String? = nil) {
        self.name = name
        self.isAggregate = isAggregate
        self.signature = signature
        self.summary = summary
    }
}

/// Fallback vocabulary when the server's `system.*` dictionaries are unavailable.
public enum StaticVocabulary {
    public static let aggregateFunctions = [
        "count", "sum", "avg", "min", "max", "any", "anyLast", "argMin", "argMax", "uniq", "uniqExact", "uniqCombined", "uniqHLL12",
        "quantile", "quantiles", "quantileExact", "quantileTDigest", "median", "groupArray", "groupUniqArray", "groupBitmap", "topK",
        "sumMap", "stddevPop", "stddevSamp", "varPop", "varSamp", "corr", "covarPop", "simpleLinearRegression", "histogram",
        "windowFunnel", "retention", "sequenceMatch", "sequenceCount", "countIf", "sumIf", "avgIf", "uniqIf",
    ]

    public static let functions = [
        "now", "today", "yesterday", "toDate", "toDateTime", "toDateTime64", "toStartOfDay", "toStartOfHour", "toStartOfMinute",
        "toStartOfFifteenMinutes", "toStartOfInterval", "toStartOfMonth", "toStartOfWeek", "toYYYYMM", "toYYYYMMDD", "toYear",
        "toMonth", "toDayOfWeek", "toHour", "dateDiff", "dateAdd", "dateSub", "formatDateTime", "parseDateTimeBestEffort",
        "toUInt8", "toUInt32", "toUInt64", "toInt64", "toFloat64", "toDecimal64", "toString", "toTypeName", "concat", "substring",
        "lower", "upper", "length", "lengthUTF8", "position", "replaceAll", "replaceRegexpAll", "match", "extract", "splitByChar",
        "arrayJoin", "arrayMap", "arrayFilter", "arrayExists", "has", "hasAny", "length", "empty", "notEmpty", "if", "multiIf",
        "coalesce", "ifNull", "nullIf", "assumeNotNull", "cityHash64", "sipHash64", "xxHash64", "murmurHash3_64", "rand", "round",
        "floor", "ceil", "intDiv", "modulo", "abs", "greatest", "least", "JSONExtractString", "JSONExtractInt", "JSONExtract",
        "visitParamExtractString", "dictGet", "dictGetOrDefault", "dictHas", "formatReadableSize", "formatReadableQuantity",
        "hostName", "version", "currentDatabase", "currentUser", "uptime", "timezone", "getSetting", "throwIf", "sleep",
        "tuple", "tupleElement", "map", "mapKeys", "mapValues", "toUUID", "generateUUIDv4", "IPv4NumToString", "toIPv4", "toIPv6",
    ]

    public static let combinators = ["If", "Array", "Map", "State", "Merge", "MergeState", "ForEach", "Distinct", "OrDefault", "OrNull",
                                     "Resample", "SimpleState", "ArgMin", "ArgMax"]

    public static let formats = ["TabSeparated", "TabSeparatedWithNames", "TabSeparatedWithNamesAndTypes", "CSV", "CSVWithNames",
                                 "JSON", "JSONEachRow", "JSONCompact", "JSONCompactEachRow", "Pretty", "PrettyCompact", "Vertical",
                                 "Values", "Native", "RowBinary", "Parquet", "Arrow", "ORC", "Markdown", "Null"]

    public static let engines = ["MergeTree", "ReplacingMergeTree", "SummingMergeTree", "AggregatingMergeTree", "CollapsingMergeTree",
                                 "VersionedCollapsingMergeTree", "ReplicatedMergeTree", "Distributed", "Memory", "Log", "TinyLog",
                                 "Buffer", "Null", "Merge", "Dictionary", "Kafka", "S3", "URL", "File", "MySQL", "PostgreSQL"]

    public static let tableFunctions = ["numbers", "numbers_mt", "zeros", "generateRandom", "remote", "remoteSecure", "cluster",
                                        "clusterAllReplicas", "url", "s3", "file", "mysql", "postgresql", "merge", "values", "input",
                                        "format", "view", "dictionary", "generate_series"]

    public static let dataTypes = ["UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256", "Int8", "Int16", "Int32", "Int64",
                                   "Int128", "Int256", "Float32", "Float64", "BFloat16", "Decimal", "Decimal32", "Decimal64",
                                   "Decimal128", "Decimal256", "Bool", "String", "FixedString", "UUID", "Date", "Date32", "DateTime",
                                   "DateTime64", "Enum8", "Enum16", "LowCardinality", "Nullable", "Array", "Tuple", "Map", "Nested",
                                   "IPv4", "IPv6", "JSON", "Variant", "Dynamic", "AggregateFunction", "SimpleAggregateFunction",
                                   "Point", "Ring", "Polygon", "MultiPolygon"]
}
