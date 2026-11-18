import ClickHouseKit
import Foundation

/// What the ClickHouse user of an AI connection may do beyond reading tables, from `SHOW GRANTS` (which every user may
/// run). `readonly=1` stops writes, but not `file()`, `url()`, `remote()` and other sources, `SYSTEM` commands, access
/// management or functions that reveal secrets, and no SQL text guard can stop a privileged account in general (views,
/// dictionaries and functions reach files, programs and other sessions' data). So read-only AI access needs a user with
/// none of these, unless the connection explicitly opts in.
public struct MCPPrivilegeReport: Sendable, Equatable {
    public enum Risk: Sendable, Equatable {
        case all
        case sources
        case system
        case accessManagement
        case introspection
        case roles
        case grantOption
        case unknown(String)

        var order: Int {
            switch self {
            case .all: 0
            case .sources: 1
            case .system: 2
            case .accessManagement: 3
            case .introspection: 4
            case .roles: 5
            case .grantOption: 6
            case .unknown: 7
            }
        }

        public var label: String {
            switch self {
            case .all: "ALL"
            case .sources: "sources (file(), url(), remote(), s3() …)"
            case .system: "SYSTEM"
            case .accessManagement: "access management or secrets"
            case .introspection: "INTROSPECTION"
            case .roles: "roles, whose privileges SHOW GRANTS does not list"
            case .grantOption: "the right to grant privileges"
            case let .unknown(reason): "unknown privileges (SHOW GRANTS failed: \(reason.prefix(200)))"
            }
        }
    }

    /// In a fixed order, each at most once; empty for a plain user.
    public let risks: [Risk]

    public var isPlain: Bool { risks.isEmpty }

    /// Privileges (upper-cased) that make a user risky, with everything under them in system.privileges' hierarchy: a
    /// future child of a risky group is covered. Names some versions lack (EXECUTABLE, GCS …) are listed for themselves.
    static let riskyRoots: [String: Risk] = {
        var roots: [String: Risk] = [:]
        for name in ["SOURCES", "FILE", "URL", "REMOTE", "MONGO", "REDIS", "MYSQL", "POSTGRES", "SQLITE", "ODBC", "JDBC", "HDFS", "S3", "HIVE",
                     "AZURE", "KAFKA", "NATS", "RABBITMQ", "YTSAURUS", "ARROW FLIGHT", "BIGQUERY", "DISK", "AI FUNCTIONS", "READ", "WRITE", "GCS",
                     "EXECUTABLE", "MEILISEARCH"] {
            roots[name] = .sources
        }
        roots["SYSTEM"] = .system
        for name in ["ACCESS MANAGEMENT", "NAMED COLLECTION ADMIN", "NAMED COLLECTION CONTROL", "NAMED COLLECTION", "NAMED COLLECTION USAGE",
                     "USE NAMED COLLECTION", "SHOW ACCESS", "SHOW NAMED COLLECTIONS", "SHOW NAMED COLLECTIONS SECRETS", "DISPLAYSECRETSINSHOWANDSELECT",
                     "SET DEFINER", "ALLOW SQL SECURITY NONE", "IMPERSONATE", "ROLE ADMIN"] {
            roots[name] = .accessManagement
        }
        for name in ["INTROSPECTION", "ADDRESSTOLINE", "ADDRESSTOLINEWITHINLINES", "ADDRESSTOSYMBOL", "DEMANGLE"] { roots[name] = .introspection }
        return roots
    }()
    static let accessObjects = ["USER", "ROLE", "ROW POLICY", "POLICY", "QUOTA", "SETTINGS PROFILE", "PROFILE", "MASKING POLICY"]

    /// From the lines `SHOW GRANTS` printed, each privilege judged with its ancestors in `hierarchy` (the server's own
    /// system.privileges when readable, else the pinned one). A privilege the hierarchy does not know is risky.
    public init(grants: [String], hierarchy: PrivilegeHierarchy = .pinned) {
        var found: [Risk] = []
        func add(_ risk: Risk) { if !found.contains(risk) { found.append(risk) } }
        for line in grants {
            let lexer = SQLLexer(line)
            let tokens = lexer.tokens().filter { $0.kind != .comment }
            let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : lexer.text(of: $0) }
            guard words.first == "GRANT" else { continue } // REVOKE only narrows
            if line.uppercased().contains("WITH GRANT OPTION") || line.uppercased().contains("WITH ADMIN OPTION") { add(.grantOption) }
            var privileges: [String] = []
            var current: [String] = []
            var depth = 0
            var sawOn = false
            for index in tokens.indices.dropFirst() {
                let token = tokens[index]
                if token.kind == .punctuation, words[index] == "(" { depth += 1; continue }
                if token.kind == .punctuation, words[index] == ")" { depth -= 1; continue }
                guard depth == 0 else { continue }
                if token.kind == .keyword || token.kind == .identifier, words[index] == "ON" { sawOn = true; break }
                if token.kind == .keyword || token.kind == .identifier, words[index] == "TO" { break }
                if token.kind == .punctuation, words[index] == "," {
                    privileges.append(current.joined(separator: " "))
                    current = []
                } else if token.kind == .keyword || token.kind == .identifier || token.kind == .quotedIdentifier {
                    current.append(words[index].uppercased())
                }
            }
            if !current.isEmpty { privileges.append(current.joined(separator: " ")) }
            guard sawOn else {
                add(.roles) // `GRANT role TO user`: the role's privileges are not shown
                continue
            }
            for privilege in privileges {
                if privilege == "ALL" || privilege == "ALL PRIVILEGES" {
                    add(.all)
                    continue
                }
                guard let lineage = hierarchy.lineage(of: privilege) else {
                    if let risk = Self.riskyRoots[privilege] { add(risk) } else { add(.unknown("“\(privilege)” is not a privilege this server's hierarchy knows")) }
                    continue
                }
                for name in lineage {
                    if let risk = Self.riskyRoots[name] { add(risk) }
                    if name == "SYSTEM" || name.hasPrefix("SYSTEM ") { add(.system) }
                    if ["CREATE", "ALTER", "DROP"].contains(where: { verb in Self.accessObjects.contains { name == "\(verb) \($0)" } }) {
                        add(.accessManagement)
                    }
                }
            }
        }
        risks = found.sorted { $0.order < $1.order }
    }

    /// The grants could not be read: not provably plain.
    public init(failure: String) {
        risks = [.unknown(failure)]
    }

    /// Reads the user's grants on `client` (allowed for every user, also with readonly=1), judged with the server's own
    /// privilege hierarchy when it can be read, else the pinned one.
    public static func load(from client: ClickHouseClient) async -> MCPPrivilegeReport {
        let options = QueryOptions(purpose: "meta", limits: .metadata, timeout: 30, readOnly: true, idempotent: true)
        async let hierarchyRows = try? client.run("SELECT privilege, aliases, parent_group FROM system.privileges", options: options)
        do {
            let result = try await client.run("SHOW GRANTS", options: options)
            let hierarchy = await hierarchyRows.flatMap { PrivilegeHierarchy(rows: $0.rows) } ?? .pinned
            return MCPPrivilegeReport(grants: result.rows.compactMap { $0.first ?? nil }, hierarchy: hierarchy)
        } catch {
            _ = await hierarchyRows
            return MCPPrivilegeReport(failure: (error as? ClickHouseError)?.message ?? error.localizedDescription)
        }
    }

    /// Checked before every read-only AI call, whatever the tool (metadata tools send SQL too), on the request path the
    /// call takes: the user's grants (`SHOW GRANTS`; `SHOW ACCESS` needs a privilege a SELECT-only user lacks), the
    /// effective readonly level and the parser settings (`ClickHouseClient.readOnlyRequestPathRefusal`). Fails closed:
    /// grants or settings that cannot be read, a level of 0, or a profile that changes the dialect or adds an implicit
    /// table refuse the call.
    public static func readOnlyRefusal(client: ClickHouseClient, profile: ConnectionProfile) async -> String? {
        async let report = load(from: client)
        async let path = client.readOnlyRequestPathRefusal()
        if let refusal = await report.refusal(for: profile, user: client.serverInfo.currentUser) {
            _ = await path
            return refusal
        }
        if let refusal = await path { return "Read-only AI tools are off for “\(profile.displayName)”: \(refusal)" }
        return nil
    }

    /// Why read-only AI tools refuse this connection, or `nil` when they may run.
    public func refusal(for profile: ConnectionProfile, user: String?) -> String? {
        guard !isPlain, !profile.mcpAllowPrivilegedUser else { return nil }
        let account = user ?? profile.username
        return """
            Connection “\(profile.displayName)” gives AI read-only access as ClickHouse user “\(account)”, who holds \
            \(risks.map(\.label).joined(separator: "; ")). readonly=1 does not stop these (file() and url() read files and the \
            network, SYSTEM and access management act on the server), so read-only AI tools are off for this connection. \
            Connect it as a dedicated user with SELECT grants only (Settings → MCP shows the SQL), or allow this user for AI \
            access in the connection's settings.
            """
    }
}

/// ClickHouse's privilege hierarchy (system.privileges): each privilege, upper-cased, with its parent groups, and aliases.
public struct PrivilegeHierarchy: Sendable, Equatable {
    let parents: [String: Set<String>]
    let aliases: [String: Set<String>]

    /// Pinned from the supported versions (scripts/gen-ai-function-catalog.py).
    public static let pinned = PrivilegeHierarchy(parents: MCPPrivilegeReport.pinnedParents, aliases: MCPPrivilegeReport.pinnedAliases)

    init(parents: [String: Set<String>], aliases: [String: Set<String>]) {
        self.parents = parents
        self.aliases = aliases
    }

    /// From `SELECT privilege, aliases, parent_group FROM system.privileges` (aliases as `['A','B']`); `nil` when the rows
    /// do not look like it.
    init?(rows: [[String?]]) {
        var parents: [String: Set<String>] = [:]
        var aliases: [String: Set<String>] = [:]
        for row in rows {
            guard row.count >= 3, let privilege = row[0]?.uppercased(), !privilege.isEmpty else { return nil }
            var entry = parents[privilege] ?? []
            if let parent = row[2]?.uppercased(), !parent.isEmpty { entry.insert(parent) }
            parents[privilege] = entry
            let list = (row[1] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            for alias in list.split(separator: ",") {
                let name = alias.trimmingCharacters(in: CharacterSet(charactersIn: " '")).uppercased()
                if !name.isEmpty { aliases[name, default: []].insert(privilege) }
            }
        }
        guard !parents.isEmpty else { return nil }
        self.init(parents: parents, aliases: aliases)
    }

    /// `name` (or the privileges it is an alias of) and every ancestor but ALL; `nil` when the hierarchy does not know it.
    public func lineage(of name: String) -> Set<String>? {
        let upper = name.uppercased()
        let start: Set<String> = parents[upper] != nil ? [upper] : aliases[upper] ?? []
        guard !start.isEmpty else { return nil }
        var seen = start
        var pending = Array(start)
        while let current = pending.popLast() {
            for parent in parents[current] ?? [] where parent != "ALL" && seen.insert(parent).inserted {
                pending.append(parent)
            }
        }
        return seen
    }
}
