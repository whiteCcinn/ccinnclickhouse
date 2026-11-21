import CcinnClickHouseKit
import Darwin
import Foundation
import ClickHouseKit

/// `CcinnClickHouse mcp [--profile <name|id>] [--read-only]` — a headless MCP server on stdio.
/// Only protocol messages are written to stdout; diagnostics go to stderr.
enum MCPCommand {
    static let usage = """
    Usage: CcinnClickHouse mcp [--profile <name|id>] [--read-only]

    Runs a Model Context Protocol server on stdin/stdout so AI clients (Claude Code, Codex,
    Claude Desktop, …) can use the ClickHouse connections you enabled for AI access in CcinnClickHouse.
    Read-only access is enforced by ClickHouse itself (readonly=1) as well as by the app.

      --profile <name|id>   Connection used when a tool call does not name one.
      --read-only           Treat every connection as read-only, even if read-write is allowed.

    Example (Claude Code):
      claude mcp add ccinnclickhouse -- "\(executablePath)" mcp
    """

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "CcinnClickHouse"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.1"
    }

    static func run(arguments: [String]) -> Never {
        var profile: String?
        var readOnly = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--profile":
                guard index + 1 < arguments.count else { fail("--profile needs a connection name or id") }
                profile = arguments[index + 1]
                index += 1
            case "--read-only":
                readOnly = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                fail("unknown option \(arguments[index])\n\n\(usage)")
            }
            index += 1
        }

        signal(SIGPIPE, SIG_IGN)
        // Test-only: CCINNCLICKHOUSE_TEST_PASSWORD_<PROFILE-UUID> supplies passwords without the Keychain
        // (used by the subprocess integration test; documented as test-only).
        let secrets: any SecretStore = EnvironmentTestSecretStore.isActive()
            ? EnvironmentTestSecretStore(fallback: KeychainSecretStore()) : KeychainSecretStore()
        let repository = ProfileRepository(secrets: secrets)
        let profiles: [ConnectionProfile]
        do {
            profiles = try repository.load()
        } catch {
            fail("could not read saved connections: \(error.localizedDescription)")
        }
        let resolver = MCPProfileResolver(profiles: profiles, defaultProfile: profile, forceReadOnly: readOnly)
        if let profile, (try? resolver.resolve(profile)) == nil {
            log("warning: connection “\(profile)” is unknown or not enabled for AI access")
        }
        log("CcinnClickHouse MCP server \(version): \(resolver.enabledProfiles.count) connection(s) enabled for AI access")

        let registry = MCPClientRegistry { profile, access in
            let password = repository.password(for: profile) ?? ""
            let sshSecret = profile.ssh != nil ? repository.sshSecret(for: profile) : nil
            // Read-only AI access: every request of this client carries readonly=1.
            return try await ClientOpener.open(profile: profile, password: password, sshSecret: sshSecret, readOnlyOverride: access != .readWrite)
        }
        // Profiles are re-read on every call, so switching AI access off (or down to read-only) in
        // Settings applies to this running server at once.
        let source = MCPProfileSource(defaultProfile: profile, forceReadOnly: readOnly, load: { try repository.load() })
        let provider = ClickHouseMCPTools(profiles: source, registry: registry,
                                          audit: MCPAuditLog(directory: ProfileRepository.defaultDirectory))
        let output = StandardOutput()
        let server = MCPServer(info: MCPServerInfo(name: "ccinnclickhouse", title: "CcinnClickHouse", version: version, instructions: instructions),
                               provider: provider, send: { await output.write($0) })

        let lines = StandardInputLines.stream()
        Task {
            for await event in lines {
                switch event {
                case let .line(line):
                    await server.receive(line)
                case .oversized:
                    await output.write(JSONValue.object(["jsonrpc": "2.0", "id": .null,
                                                         "error": ["code": -32600, "message": "Message exceeds the 4 MB limit"]]).serialized())
                }
            }
            // stdin closed: the client went away.
            await server.shutdown()
            await registry.closeAll()
            SSHTunnel.terminateAll()
            exit(0)
        }
        for terminating in [SIGTERM, SIGINT] {
            signal(terminating, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: terminating, queue: .main)
            source.setEventHandler {
                SSHTunnel.terminateAll()
                exit(0)
            }
            source.resume()
            SignalSources.retain(source)
        }
        dispatchMain()
    }

    static let instructions = """
    CcinnClickHouse gives you access to the ClickHouse servers the user enabled for AI access. \
    Start with list_connections, then explore with list_databases, list_tables (engine family: MergeTree variants, Replicated, \
    Distributed, materialized views, views, dictionaries, streaming and external engines) and describe_table (columns with \
    compression, keys, TTL, projections, skipping indexes). ClickHouse insights: get_parts (part counts and warnings), \
    get_merges_and_mutations, get_replication, get_running_queries, analyze_query_log, get_cluster, get_storage and \
    list_dictionaries. run_query executes one read-only statement (SELECT/WITH/SHOW/DESCRIBE/EXISTS/EXPLAIN) with readonly=1 \
    enforced by ClickHouse; results are limited to 200 rows by default (max 1000) and about 256 KB, so aggregate in SQL \
    instead of fetching raw rows. Statements time out after 30 s by default. explain_query shows plans with index usage. \
    execute_statement (writes) exists only for connections with read-write access.
    """

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        log("error: \(message)")
        exit(64)
    }
}

/// Keeps signal sources alive for the life of the process.
private enum SignalSources {
    nonisolated(unsafe) private static var sources: [any DispatchSourceSignal] = []
    static func retain(_ source: any DispatchSourceSignal) { sources.append(source) }
}

/// Serializes protocol output so concurrent responses never interleave.
private actor StandardOutput {
    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            // The client closed the pipe; nothing more can be delivered.
            exit(0)
        }
    }
}

/// Reads stdin on a dedicated thread (blocking reads) and frames it into lines.
private enum StandardInputLines {
    static func stream() -> AsyncStream<LineFramer.Event> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                var framer = LineFramer(maxLineBytes: 4 * 1024 * 1024)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    for event in framer.append(Array(buffer[0..<count])) { continuation.yield(event) }
                }
                continuation.finish()
            }
            thread.name = "mcp-stdin"
            thread.start()
        }
    }
}
