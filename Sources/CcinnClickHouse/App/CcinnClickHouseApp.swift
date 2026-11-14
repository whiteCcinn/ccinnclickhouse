import AppKit
import CcinnClickHouseKit
import ClickHouseKit
import SwiftUI

struct CcinnClickHouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup("CcinnClickHouse", id: "main") {
            RootView()
                .frame(minWidth: 1040, minHeight: 640)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Settings {
            SettingsTabs()
                .frame(width: 620)
                .tint(Theme.accent)
        }
    }
}

private struct SettingsTabs: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            MCPSettingsView(store: AppServices.shared.profiles)
                .tabItem { Label("MCP", systemImage: "sparkles") }
                .tag("mcp")
        }
    }
}

/// Automated visual checks must never take focus from the person using the Mac.
enum BackgroundMode {
    /// `--snapshot` runs: no activation, no Dock icon, windows invisible and click-through.
    static let isActive = ProcessInfo.processInfo.arguments.contains("--snapshot")

    @MainActor
    static func prepare(_ window: NSWindow) {
        guard isActive else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.collectionBehavior.insert(.transient)
        window.collectionBehavior.insert(.ignoresCycle)
    }
}

/// Applies `BackgroundMode` to the hosting window as soon as the view is in it.
private struct BackgroundWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { BackgroundMode.prepare(window) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restored windows would only reopen the connection screen; start with one clean window.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        if BackgroundMode.isActive {
            NSApp.setActivationPolicy(.accessory)
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
                NSApp.appearance = NSAppearance(named: arguments[index + 1].lowercased() == "dark" ? .darkAqua : .aqua)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        if !BackgroundMode.isActive {
            // Behave like a regular app when launched from `swift run` (no bundle).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            for window in NSApp.windows { BackgroundMode.prepare(window) }
        }
        SnapshotTool.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Close SSH port forwards synchronously; detached cleanup tasks do not run during exit.
        SSHTunnel.terminateAll()
    }
}

/// Per-window root: connection manager, progress, or workspace.
struct RootView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var session = WindowSession()
    private let store = AppServices.shared.profiles

    var body: some View {
        Group {
            switch session.phase {
            case .connections:
                ConnectionsView(session: session, store: store)
                    .transition(.opacity)
            case let .connecting(name, status):
                ConnectingView(name: name, status: status) { session.cancelConnecting() }
                    .transition(.opacity)
            case let .connected(workspace):
                WorkspaceView(workspace: workspace, session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .background(BackgroundWindowConfigurator().frame(width: 0, height: 0))
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .onDisappear { session.disconnect() }
        .task {
            LaunchArguments.consume(into: session, store: store)
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--settings"), arguments.indices.contains(index + 1) {
                UserDefaults.standard.set(arguments[index + 1], forKey: "settingsTab")
                openSettings()
            }
        }
    }

    private var phaseKey: Int {
        switch session.phase {
        case .connections: 0
        case .connecting: 1
        case .connected: 2
        }
    }

    private var windowTitle: String {
        switch session.phase {
        case .connections: "CcinnClickHouse — Connections"
        case let .connecting(name, _): "Connecting to \(name)"
        case let .connected(workspace): workspace.profile.displayName
        }
    }
}

/// Full-window progress while a connection is being established.
struct ConnectingView: View {
    let name: String
    let status: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 64).symbolEffect(.pulse)
            Text("Connecting to \(name)").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Developer conveniences, deep links and automated visual checks:
/// `CcinnClickHouse --connect host:port [--https] [--user u] [--database db] [--cluster c] [--object db.table]
///  [--section overview|columns|parts|indexes|mutations|replication|ddl|data] [--sql "…"] [--auto-run]
///  [--view grid|chart|plan] [--operations running|merges|mutations|replication|querylog|storage|dictionaries|cluster]
///  [--log slowest|memory|failed|patterns|byuser] [--profile name]`
/// Passwords come from `CCINNCLICKHOUSE_PASSWORD`, never from the command line.
@MainActor
enum LaunchArguments {
    private static var consumed = false

    static func consume(into session: WindowSession, store: ProfileStore) {
        guard !consumed else { return }
        consumed = true
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let profile: ConnectionProfile
        var password: String?
        if let name = value("--profile"), let saved = store.profiles.first(where: { $0.displayName == name }) {
            profile = saved
        } else if let raw = value("--connect") {
            let secure = arguments.contains("--https")
            let parts = raw.split(separator: ":")
            let host = parts.first.map(String.init) ?? "127.0.0.1"
            let port = parts.count > 1 ? Int(parts[1]) ?? (secure ? 8443 : 8123) : (secure ? 8443 : 8123)
            profile = ConnectionProfile(name: value("--name") ?? "\(host):\(port)", host: host, port: port, secure: secure,
                                        username: value("--user") ?? "default", defaultDatabase: value("--database"),
                                        defaultCluster: value("--cluster"), readOnly: arguments.contains("--read-only"), color: .orange,
                                        connectTimeout: value("--connect-timeout").flatMap(Double.init) ?? 30)
            password = ProcessInfo.processInfo.environment["CCINNCLICKHOUSE_PASSWORD"] ?? ""
        } else {
            return
        }
        session.connect(profile: profile, store: store, password: password) { workspace in
            Task { @MainActor in
                if let target = value("--object"), let dot = target.firstIndex(of: ".") {
                    let database = String(target[..<dot])
                    let name = String(target[target.index(after: dot)...])
                    workspace.setExpanded(database, true)
                    if let table = await workspace.awaitObjects(database: database)?.first(where: { $0.name == name }) {
                        let section = value("--section").flatMap { raw in
                            ObjectDetailModel.Section.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
                        }
                        workspace.openObject(table, section: section)
                    }
                }
                if let sql = value("--sql") {
                    let model = workspace.openSQL(text: sql.replacingOccurrences(of: "\\n", with: "\n"), database: value("--database"))
                    if arguments.contains("--auto-run") {
                        model.runAll()
                        if let view = value("--view"), let mode = StatementOutcome.ViewMode.allCases.first(where: { $0.rawValue.lowercased() == view.lowercased() }) {
                            for _ in 0..<100 where model.isRunning || model.outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                            model.selectedOutcome?.viewMode = mode
                        }
                    }
                }
                if let raw = value("--operations"),
                   let section = OperationsModel.Section.allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(raw.lowercased()) }) {
                    workspace.openOperations(section: section)
                    if let log = value("--log"), case let .operations(model)? = workspace.selectedTab?.kind,
                       let analysis = OperationsModel.LogAnalysis.allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == log.lowercased() }) {
                        model.logAnalysis = analysis
                    }
                }
            }
        }
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot]`: renders the main window
/// into a PNG without showing it or taking focus (needs no screen-recording permission).
@MainActor
enum SnapshotTool {
    static func scheduleIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else { return }
        let path = arguments[index + 1]
        var delay = 6.0
        if let delayIndex = arguments.firstIndex(of: "--snapshot-delay"), arguments.indices.contains(delayIndex + 1),
           let parsed = Double(arguments[delayIndex + 1]) {
            delay = min(max(parsed, 0.5), 600)
        }
        let quit = arguments.contains("--quit-after-snapshot")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var candidates = NSApp.windows
            if let titleIndex = arguments.firstIndex(of: "--snapshot-window"), arguments.indices.contains(titleIndex + 1) {
                let title = arguments[titleIndex + 1]
                candidates = NSApp.windows.filter { $0.title.localizedCaseInsensitiveContains(title) } + candidates
            }
            if let window = candidates.first(where: { $0.contentView != nil && $0.frame.width > 400 }),
               let view = window.contentView?.superview ?? window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if quit { NSApp.terminate(nil) }
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            // Snapshot runs pass `--appearance dark|light`.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
                return arguments[index + 1].lowercased() == "dark" ? .dark : .light
            }
            return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("autoLimit") private var autoLimit = 1000

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Automatic LIMIT for SELECT", selection: $autoLimit) {
                Text("None").tag(0)
                ForEach([100, 500, 1000, 5000, 10_000, 50_000], id: \.self) { Text($0.formatted()).tag($0) }
            }
            LabeledContent("Saved connections") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ProfileRepository.defaultDirectory])
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Commands

struct WindowSessionKey: FocusedValueKey {
    typealias Value = WindowSession
}

extension FocusedValues {
    var windowSession: WindowSession? {
        get { self[WindowSessionKey.self] }
        set { self[WindowSessionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowSession) private var session

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Query") { session?.workspace?.openSQL() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session?.workspace == nil)
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
        CommandMenu("Server") {
            Button("Refresh Databases") { session?.workspace?.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Running Queries") { session?.workspace?.openOperations(section: .running) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Button("Merges") { session?.workspace?.openOperations(section: .merges) }
                .disabled(session?.workspace == nil)
            Button("Mutations") { session?.workspace?.openOperations(section: .mutations) }
                .disabled(session?.workspace == nil)
            Button("Replication") { session?.workspace?.openOperations(section: .replication) }
                .disabled(session?.workspace == nil)
            Button("Query Log") { session?.workspace?.openOperations(section: .queryLog) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Button("Storage") { session?.workspace?.openOperations(section: .storage) }
                .disabled(session?.workspace == nil)
            Button("Dictionaries") { session?.workspace?.openOperations(section: .dictionaries) }
                .disabled(session?.workspace == nil)
            Button("Cluster") { session?.workspace?.openOperations(section: .cluster) }
                .disabled(session?.workspace == nil)
            Divider()
            Button("Close Tab") { session?.workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedTab == nil)
            Button("Next Tab") { session?.workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Previous Tab") { session?.workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
    }
}
