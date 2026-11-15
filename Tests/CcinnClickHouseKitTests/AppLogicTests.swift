import ClickHouseKit
import ClickHouseWire
import Foundation
import Testing
@testable import CcinnClickHouseKit

@Suite("Profiles and secrets")
struct ProfileTests {
    @Test func secretsNeverReachTheProfileFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let repository = ProfileRepository(directory: directory, secrets: secrets)
        let profile = ConnectionProfile(name: "Prod", host: "ch.example.com", port: 8443, secure: true, username: "analyst",
                                        ssh: SSHTunnelConfiguration(host: "bastion", username: "me", authentication: .password))
        try repository.save([profile])
        try repository.storeSecrets(for: profile, password: "s3cret-pass", sshSecret: "ssh-pass")
        let text = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!text.contains("s3cret-pass"))
        #expect(!text.contains("ssh-pass"))
        #expect(repository.password(for: profile) == "s3cret-pass")
        #expect(try repository.load() == [profile])
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("connections.json").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try repository.delete(profile)
        #expect(repository.password(for: profile) == nil)
    }

    @Test func configurationCarriesProfileSettings() {
        let profile = ConnectionProfile(host: " ch ", port: 8443, secure: true, pathPrefix: "/proxy/", username: "u", defaultDatabase: "  ",
                                        defaultCluster: "c1", compression: false, readOnly: true, customCACertificate: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----",
                                        connectTimeout: 9999)
        let configuration = profile.configuration(password: "p")
        #expect(configuration.endpoint == Endpoint(host: "ch", port: 8443))
        #expect(configuration.secure)
        #expect(configuration.database == nil)
        #expect(configuration.defaultCluster == "c1")
        #expect(configuration.readOnly)
        #expect(!configuration.compression)
        #expect(configuration.connectTimeout == 300)
        #expect(configuration.tls.customCACertificate != nil)
        #expect(configuration.baseURL?.absoluteString == "https://ch:8443/proxy/")
        #expect(profile.validationErrors.isEmpty)
        #expect(ConnectionProfile(host: "", port: 0, username: " ").validationErrors.count == 3)
        #expect(ConnectionProfile(customCACertificate: "not a cert!").validationErrors.contains("The CA certificate must be PEM text"))
    }

    @Test func testOnlySecretStoreReadsNamedEnvironmentVariables() throws {
        let profile = ConnectionProfile(name: "IT")
        let environment = [EnvironmentTestSecretStore.prefix + profile.id.uuidString.uppercased(): "from-env"]
        let store = EnvironmentTestSecretStore(fallback: InMemorySecretStore(), environment: environment)
        #expect(try store.secret(for: SecretKey(profileID: profile.id, kind: .password)) == "from-env")
        #expect(try store.secret(for: SecretKey(profileID: UUID(), kind: .password)) == nil)
        #expect(EnvironmentTestSecretStore.isActive(environment: environment))
        #expect(!EnvironmentTestSecretStore.isActive(environment: ["HOME": "/"]))
    }
}

@Suite("History and export")
struct HistoryExportTests {
    @Test func historyRedactsAndIsPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueryHistoryStore(directory: directory, profileID: UUID(), maxEntries: 3)
        await store.append(QueryHistoryEntry(sql: "CREATE USER u IDENTIFIED BY 'secret'", database: nil, durationMilliseconds: 1))
        for index in 0..<4 { await store.append(QueryHistoryEntry(sql: "SELECT \(index)", database: "shop", durationMilliseconds: 1)) }
        let all = await store.all()
        #expect(all.count == 3)
        #expect(all.first?.sql == "SELECT 3")
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("secret"))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func historyRedactsErrorText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueryHistoryStore(directory: directory, profileID: UUID(), maxEntries: 3)
        await store.append(QueryHistoryEntry(sql: "CREATE USER u IDENTIFIED WITH sha256_password BY 'HISTSECRET',", database: nil, durationMilliseconds: 1,
                                             errorMessage: "Syntax error: failed at position 60 ('HISTSECRET') (line 1, col 60): 'HISTSECRET',. Expected one of: token"))
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("HISTSECRET"))
        #expect(await store.all().first?.errorMessage?.contains("failed at position 60") == true)
    }

    @Test func csvNeutralisesFormulasButKeepsNumbers() {
        let columns = [ColumnDefinition(name: "n", typeName: "Int64"), ColumnDefinition(name: "s", typeName: "String"),
                       ColumnDefinition(name: "a", typeName: "Array(String)")]
        let csv = ResultExport.csv(columns: columns, rows: [["-5", "=HYPERLINK(\"x\")", "['a','b']"], [nil, "plain, text", nil]])
        #expect(csv == "n,s,a\r\n-5,\"'=HYPERLINK(\"\"x\"\")\",\"['a','b']\"\r\n,\"plain, text\",\r\n")
    }

    @Test func fileExportWritesRawBytesOfBinaryCells() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let columns = [ColumnDefinition(name: "bin", typeName: "String"), ColumnDefinition(name: "n", typeName: "UInt8")]
        let rows: [[String?]] = [["\u{FFFD}(", "1"], ["ok", "2"]]
        try ResultExport.write(to: url, columns: columns, rows: rows, binaryCells: [QueryResult.CellAddress(row: 0, column: 0): Data([0xC3, 0x28, 0x22])])
        let data = try Data(contentsOf: url)
        #expect(data == Data("bin,n\r\n".utf8) + Data([0x22, 0xC3, 0x28, 0x22, 0x22, 0x22]) + Data(",1\r\nok,2\r\n".utf8))
    }

    @Test func insertStatementsKeepLiterals() {
        let columns = [ColumnDefinition(name: "id", typeName: "UInt64"), ColumnDefinition(name: "name", typeName: "String"),
                       ColumnDefinition(name: "tags", typeName: "Array(String)"), ColumnDefinition(name: "price", typeName: "Decimal(10, 2)")]
        let sql = ResultExport.insertStatements(table: "`t`", columns: columns, rows: [["1", "it's", "['x']", "9.90"], ["2", nil, "[]", "nan"]])
        #expect(sql == "INSERT INTO `t` (`id`, `name`, `tags`, `price`) VALUES (1, 'it\\'s', ['x'], 9.90);\nINSERT INTO `t` (`id`, `name`, `tags`, `price`) VALUES (2, NULL, [], 'nan');")
    }

    @Test func hexDump() {
        #expect(ResultExport.hexDump(Data([0x41, 0x00, 0xFF])) == "00000000  41 00 ff" + String(repeating: " ", count: 40) + "  A..")
    }
}

@Suite("Charts")
struct ChartTests {
    @Test func suggestsFromClickHouseTypes() {
        let columns = [ColumnDefinition(name: "t", typeName: "DateTime('UTC')"), ColumnDefinition(name: "n", typeName: "UInt64"),
                       ColumnDefinition(name: "country", typeName: "LowCardinality(String)")]
        let rows: [[String?]] = [["2026-01-01 00:00:00", "5", "MY"], ["2026-01-02 00:00:00", "7", "CN"]]
        let roles = ChartSuggester.roles(columns: columns, rows: rows)
        #expect(roles == [.temporal, .numeric, .categorical])
        let spec = ChartSuggester.suggest(roles: roles, rows: rows)
        #expect(spec?.kind == .line)
        #expect(spec?.xColumn == 0)
        #expect(spec?.yColumns == [1])
        // Text columns that hold numbers are sampled.
        #expect(ChartSuggester.roles(columns: [ColumnDefinition(name: "s", typeName: "String")], rows: [["1.5"], ["2"]]) == [.numeric])
        #expect(ChartSuggester.roles(columns: [ColumnDefinition(name: "b", typeName: "Bool")], rows: [["true"]]) == [.categorical])
    }

    @Test func nonFiniteValuesNeverTrap() {
        let columns = [ColumnDefinition(name: "x", typeName: "Float64"), ColumnDefinition(name: "y", typeName: "Float64")]
        let rows: [[String?]] = (0..<5_000).map { index in [index % 3 == 0 ? "inf" : String(index), index % 5 == 0 ? "nan" : "1"] }
            + [["1.7e308", "1"], ["-1.7e308", "2"]]
        let spec = ChartSpec(kind: .line, xColumn: 0, yColumns: [1])
        let data = ChartDataBuilder.build(columns: columns, rows: rows, spec: spec, roles: [.numeric, .numeric], pointBudget: 100)
        #expect(data.points.count <= 200)
        #expect(data.points.allSatisfy { $0.y.isFinite })
    }

    @Test func aggregatesThatOverflowAreDropped() {
        let columns = [ColumnDefinition(name: "k", typeName: "String"), ColumnDefinition(name: "y", typeName: "Float64")]
        let rows: [[String?]] = [["a", "1.7e308"], ["a", "1.7e308"], ["b", "1"], ["b", "2"]]
        for aggregation in [ChartAggregation.sum, .average, .max] {
            let data = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .bar, xColumn: 0, yColumns: [1], aggregation: aggregation),
                                              roles: [.categorical, .numeric], pointBudget: 100)
            #expect(data.points.allSatisfy { $0.y.isFinite }, "\(aggregation)")
            #expect(data.points.contains { $0.x == .category("b") })
        }
        // Average of large finite values is computed without overflowing.
        let average = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .bar, xColumn: 0, yColumns: [1], aggregation: .average),
                                             roles: [.categorical, .numeric], pointBudget: 100)
        #expect(average.points.first { $0.x == .category("a") }?.y == 1.7e308)
    }

    @Test func datesAreUTC() {
        #expect(TextValue.dateTime("2026-03-29 02:30:00") == Date(timeIntervalSince1970: 1_774_751_400))
        #expect(TextValue.dateTime("2026-03-29T02:30:00Z") == Date(timeIntervalSince1970: 1_774_751_400))
        #expect(TextValue.dateTime("2026-03-29 02:30:00.123456789")?.timeIntervalSince1970 ?? 0 > 1_774_751_400)
        #expect(ChartX.date(Date(timeIntervalSince1970: 0)).label == "1970-01-01")
    }
}

@Suite("Private files")
struct PrivateFileTests {
    @Test func everyWriteIsCreatedWithMode0600AndLeavesNoTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnch-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("connections.json")
        // A file someone left world-readable is replaced by a private one.
        FileManager.default.createFile(atPath: file.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
        let previousUmask = umask(0o022)
        defer { umask(previousUmask) }
        for round in 0..<3 {
            try PrivateFile.write(Data("round \(round)".utf8), to: file)
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
            #expect(try String(contentsOf: file, encoding: .utf8) == "round \(round)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["connections.json"])
        #expect(throws: (any Error).self) { try PrivateFile.write(Data(), to: directory.appendingPathComponent("missing/dir/file")) }
    }
}
