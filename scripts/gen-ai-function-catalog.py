#!/usr/bin/env python3
"""Generates the reviewed function catalog behind read-only AI access.

Usage: scripts/gen-ai-function-catalog.py URL [URL ...]
  e.g. scripts/gen-ai-function-catalog.py http://127.0.0.1:18122 http://127.0.0.1:18101 http://127.0.0.1:18126
Credentials: CCINNCH_IT_USER / CCINNCH_IT_PASSWORD (default ccinn / ccinn-pass).

Writes Sources/CcinnClickHouseKit/SQL/AIFunctionCatalog.swift and Sources/CcinnClickHouseKit/MCP/PrivilegeHierarchy.swift
from the union of each server's system.functions (origin System), system.table_functions,
system.aggregate_function_combinators, system.data_type_families and system.privileges. The reviewed DENIED lists below
are the security decision; everything else a supported server ships is allowed. Re-run it, and review every new name it
reports, when a ClickHouse version is added.
"""
import base64, os, sys, urllib.request

DENIED = {
    "reaches outside ClickHouse (files, network, external services, libraries, LLMs)": [
        "file", "catboostEvaluate", "modelEvaluate", "aiClassify", "aiEmbed", "aiExtract", "aiFilter", "aiGenerate", "aiRedact",
        "aiSimilarity", "aiTranslate", "reverseDNSQuery", "showCertificate", "hasColumnInTable", "meiliMatch",
        "naiveBayesClassifier", "naiveBayesClassifierWithProb", "naiveBayesClassifierWithAllProbs", "lemmatize", "synonyms",
        "filesystemAvailable", "filesystemCapacity", "filesystemUnreserved", "filesystemFree",
    ],
    "reads objects or request data by name": [
        "joinGet", "joinGetOrNull", "getMaxTableNameLengthForDatabase", "getClientHTTPHeader", "currentRequestURL",
    ],
    "introspects the server binary": ["addressToLine", "addressToLineWithInlines", "addressToSymbol", "demangle"],
    "changes state or holds the server": ["generateSerialID", "logTrace", "sleep", "sleepEachRow", "timeSeriesStoreTags"],
}
DENIED_PREFIXES = {"internal (double underscore)": "__"}

TABLE_FUNCTIONS = {
    "external": [
        "arrowflight", "arrowflightsql", "azureblobstorage", "azureblobstoragecluster", "bigquery", "cosn", "deltalake", "deltalakeazure",
        "deltalakeazurecluster", "deltalakecluster", "deltalakelocal", "deltalakes3", "deltalakes3cluster", "eval", "executable", "file",
        "filecluster", "filesystem", "gcs", "hdfs", "hdfscluster", "hive", "hudi", "hudicluster", "iceberg", "icebergazure",
        "icebergazurecluster", "icebergcluster", "iceberghdfs", "iceberghdfscluster", "iceberglocal", "iceberglocalcluster", "icebergs3",
        "icebergs3cluster", "input", "jdbc", "meilisearch", "mongodb", "mysql", "odbc", "oss", "paimon", "paimonazure",
        "paimonazurecluster", "paimoncluster", "paimonhdfs", "paimonhdfscluster", "paimonlocal", "paimons3", "paimons3cluster",
        "postgresql", "prometheusquery", "prometheusqueryrange", "redis", "remote", "remotesecure", "s3", "s3cluster", "sqlite", "url",
        "urlcluster", "ytsaurus",
    ],
    "allowed": [
        "format", "fuzzjson", "fuzzquery", "generate_series", "generaterandom", "generateseries", "null", "numbers", "numbers_mt",
        "primes", "sqlstandardvalues", "values", "view", "zeros", "zeros_mt",
    ],
    "reviewedLocal": [
        "cluster", "clusterallreplicas", "dictionary", "loop", "merge", "mergetreeindex", "mergetreeprojection", "viewexplain",
        "viewifpermitted",
    ],
    "aiRefused": [
        "mergetreeanalyzeindexes", "mergetreeanalyzeindexesuuid", "mergetreecodecblockcounts", "mergetreetextindex", "timeseriesdata",
        "timeseriesmetrics", "timeseriessamples", "timeseriesselector", "timeseriestags",
    ],
}

# Functions whose first argument may be a function (26.8 marks them in system.functions.higher_order; older servers list
# the same names without the column).
EXTRA_HIGHER_ORDER = []


def query(url, sql):
    user = os.environ.get("CCINNCH_IT_USER", "ccinn")
    password = os.environ.get("CCINNCH_IT_PASSWORD", "ccinn-pass")
    request = urllib.request.Request(url.rstrip("/") + "/", data=(sql + " FORMAT TSV").encode())
    request.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode())
    with urllib.request.urlopen(request, timeout=60) as response:
        text = response.read().decode()
    return [line.split("\t") for line in text.splitlines() if line]


def swift_set(names, indent="        "):
    items = sorted(names)
    lines, line = [], indent
    for item in items:
        piece = '"' + item.replace("\\", "\\\\").replace('"', '\\"') + '", '
        if len(line) + len(piece) > 140:
            lines.append(line.rstrip())
            line = indent
        line += piece
    if line.strip():
        lines.append(line.rstrip())
    return "[\n" + "\n".join(lines) + "\n    ]" if items else "[]"


def main(urls):
    versions, functions, table_functions, combinators, types, privileges, higher_order = [], {}, set(), set(), {}, {}, set()
    for url in urls:
        versions.append(query(url, "SELECT version()")[0][0])
        columns = {row[0] for row in query(url, "SELECT name FROM system.columns WHERE database = 'system' AND table = 'functions'")}
        for name, is_aggregate, case_insensitive, alias_to in query(
                url, "SELECT name, is_aggregate, case_insensitive, alias_to FROM system.functions WHERE origin = 'System'"):
            entry = functions.setdefault(name, {"aggregate": False, "ci": False, "alias": set()})
            entry["aggregate"] |= is_aggregate == "1"
            entry["ci"] |= case_insensitive == "1"
            if alias_to:
                entry["alias"].add(alias_to)
        if "higher_order" in columns:
            higher_order |= {row[0].lower() for row in query(url, "SELECT name FROM system.functions WHERE higher_order")}
        table_functions |= {row[0] for row in query(url, "SELECT name FROM system.table_functions")}
        combinators |= {row[0] for row in query(url, "SELECT name FROM system.aggregate_function_combinators")}
        for name, case_insensitive, _ in query(url, "SELECT name, case_insensitive, alias_to FROM system.data_type_families"):
            types[name] = types.get(name, False) or case_insensitive == "1"
        for privilege, aliases, _, parent in query(url, "SELECT privilege, aliases, level, parent_group FROM system.privileges"):
            entry = privileges.setdefault(privilege.upper(), {"parents": set(), "aliases": set()})
            if parent != "\\N":
                entry["parents"].add(parent.upper())
            for alias in aliases.strip("[]").split(","):
                alias = alias.strip().strip("'")
                if alias:
                    entry["aliases"].add(alias.upper())

    denied = {}
    for reason, names in DENIED.items():
        for name in names:
            denied[name] = reason
    for name in functions:
        for reason, prefix in DENIED_PREFIXES.items():
            if name.startswith(prefix):
                denied[name] = reason
    # Aliases of a denied function are denied too, transitively.
    changed = True
    while changed:
        changed = False
        for name, entry in functions.items():
            if name not in denied and any(target in denied for target in entry["alias"]):
                denied[name] = denied[next(t for t in entry["alias"] if t in denied)]
                changed = True
    unknown_denied = sorted(name for name in denied if name not in functions)

    allowed = {name: entry for name, entry in functions.items() if name not in denied}
    sensitive = {name for name, entry in allowed.items() if not entry["ci"]}
    insensitive = {name.lower() for name, entry in allowed.items() if entry["ci"]}
    aggregates_sensitive = {name for name, entry in allowed.items() if entry["aggregate"] and not entry["ci"]}
    aggregates_insensitive = {name.lower() for name, entry in allowed.items() if entry["aggregate"] and entry["ci"]}
    classified = {name for names in TABLE_FUNCTIONS.values() for name in names}
    unclassified = sorted(name for name in table_functions if name.lower() not in classified)
    if unclassified:
        sys.exit("Unclassified table functions (review them, then add them to TABLE_FUNCTIONS): " + ", ".join(unclassified))

    header = f"""// Generated by scripts/gen-ai-function-catalog.py from ClickHouse {", ".join(versions)}. Do not edit by hand: re-run the
// script against every supported version and review each new name it reports.
//
// How it is made:
// - the union of system.functions (origin System; case_insensitive and alias_to respected), system.table_functions,
//   system.aggregate_function_combinators and system.data_type_families of those servers;
// - minus the reviewed deny-list below (functions that reach outside ClickHouse, read objects or request data by name,
//   introspect the server binary, change state or hold the server, or are internal), and every alias of a denied name.
// Read-only AI access may call only what is allowed here, so a newer server's new functions are refused until a
// CcinnClickHouse update reviews them.
// {len(allowed)} functions allowed ({len(sensitive)} case-sensitive, {len(insensitive)} case-insensitive), {len(denied)} denied.
"""
    out = [header, "/// The reviewed function catalog of read-only AI access (see the header).",
           "enum AIFunctionCatalog {"]
    out.append("    /// Denied functions and why, exactly as ClickHouse names them.")
    out.append("    static let denied: [String: String] = [")
    for name in sorted(denied):
        out.append(f'        "{name}": "{denied[name]}",')
    out.append("    ]\n")
    out.append("    /// Allowed functions callable only as written.")
    out.append("    static let allowedCaseSensitive: Set<String> = " + swift_set(sensitive) + "\n")
    out.append("    /// Allowed functions callable in any case (lower-cased).")
    out.append("    static let allowedCaseInsensitive: Set<String> = " + swift_set(insensitive) + "\n")
    out.append("    /// Allowed aggregate functions (combinator suffixes are stripped before the lookup).")
    out.append("    static let aggregatesCaseSensitive: Set<String> = " + swift_set(aggregates_sensitive) + "\n")
    out.append("    static let aggregatesCaseInsensitive: Set<String> = " + swift_set(aggregates_insensitive) + "\n")
    out.append("    /// Aggregate function combinators, longest first.")
    out.append("    static let combinators: [String] = [" + ", ".join(f'"{c}"' for c in sorted(combinators, key=lambda c: (-len(c), c))) + "]\n")
    out.append("    /// Higher-order functions (lower-cased): their first argument may be a function.")
    out.append("    static let higherOrder: Set<String> = " + swift_set(higher_order | set(EXTRA_HIGHER_ORDER)) + "\n")
    out.append("    /// Data type families, for type names in `CAST(x AS T(…))` and `x::T(…)`.")
    out.append("    static let dataTypesCaseSensitive: Set<String> = " + swift_set({n for n, ci in types.items() if not ci}) + "\n")
    out.append("    static let dataTypesCaseInsensitive: Set<String> = " + swift_set({n.lower() for n, ci in types.items() if ci}) + "\n")
    out.append("    /// Every table function of the supported servers, lower-cased, by class:")
    out.append("    /// external (refused everywhere), allowed (AI and editor), reviewedLocal (reads tables by name: editor only),")
    out.append("    /// aiRefused (reads tables by name; refused for AI, and not on the editor's table-function list either).")
    for key in ["external", "allowed", "reviewedLocal", "aiRefused"]:
        out.append(f"    static let {key}TableFunctions: Set<String> = " + swift_set(TABLE_FUNCTIONS[key]) + "\n")
    out.append("    /// Every table function name the generator saw (lower-cased), for the classification test.")
    out.append("    static let knownTableFunctions: Set<String> = " + swift_set({n.lower() for n in table_functions}))
    out.append("}")
    if unknown_denied:
        out.append("// Denied names no supported server ships (kept for older or newer versions): " + ", ".join(unknown_denied))
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    with open(os.path.join(root, "Sources/CcinnClickHouseKit/SQL/AIFunctionCatalog.swift"), "w") as handle:
        handle.write("\n".join(out) + "\n")

    priv = [f"""// Generated by scripts/gen-ai-function-catalog.py from ClickHouse {", ".join(versions)} (system.privileges). Do not edit by hand.
//
// The pinned privilege hierarchy: each privilege (upper-cased) with its parent groups on any supported version, and
// each alias with its privileges (one alias names different privileges on different versions). Used when a server's own
// system.privileges cannot be read.

extension MCPPrivilegeReport {{
    static let pinnedParents: [String: Set<String>] = ["""]
    for name in sorted(privileges):
        parents = ", ".join(f'"{p}"' for p in sorted(privileges[name]["parents"]))
        priv.append(f'        "{name}": [{parents}],')
    priv.append("    ]\n")
    aliases = {}
    for name in privileges:
        for alias in privileges[name]["aliases"]:
            aliases.setdefault(alias, set()).add(name)
    priv.append("    static let pinnedAliases: [String: Set<String>] = [")
    for alias in sorted(aliases):
        targets = ", ".join(f'"{t}"' for t in sorted(aliases[alias]))
        priv.append(f'        "{alias}": [{targets}],')
    priv.append("    ]")
    priv.append("}")
    with open(os.path.join(root, "Sources/CcinnClickHouseKit/MCP/PrivilegeHierarchy.swift"), "w") as handle:
        handle.write("\n".join(priv) + "\n")
    print(f"versions {versions}: {len(functions)} functions, {len(allowed)} allowed, {len(denied)} denied; "
          f"{len(table_functions)} table functions; {len(privileges)} privileges", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
