import CcinnClickHouseKit
import ClickHouseKit
import SwiftUI

struct OperationsView: View {
    @Bindable var model: OperationsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.section {
                case .running: RunningQueriesView(model: model)
                case .merges: LoadableView(state: model.merges, retry: { model.refresh() }) { MergeTable(merges: $0, showsTable: true) }
                case .mutations:
                    LoadableView(state: model.mutations, retry: { model.refresh() }) { mutations in
                        MutationTable(mutations: mutations, showsTable: true, canKill: !model.workspace.isReadOnly) { model.confirmKill($0) }
                    }
                case .replication: ReplicationOverview(model: model)
                case .queryLog: QueryLogView(model: model)
                case .storage: StorageView(model: model)
                case .dictionaries: DictionariesView(model: model)
                case .cluster: ClusterView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(model.pendingAction?.title ?? "", isPresented: Binding(get: { model.pendingAction != nil }, set: { if !$0 { model.pendingAction = nil } }),
                            titleVisibility: .visible) {
            Button(model.pendingAction?.confirmLabel ?? "OK", role: .destructive) { model.runPendingAction() }
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
        } message: {
            Text(model.pendingAction?.message ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(Theme.accent)
                Text("Operations").font(.title2.weight(.semibold))
                Badge(text: model.workspace.versionLabel, color: Theme.accent)
                Spacer()
                if let cluster = model.workspace.cluster, [.running, .merges].contains(model.section) {
                    Toggle("Whole cluster (\(cluster))", isOn: $model.clusterWide).toggleStyle(.switch).controlSize(.small)
                }
                if model.section == .mutations {
                    Toggle("Include finished", isOn: $model.showFinishedMutations).toggleStyle(.switch).controlSize(.small)
                }
                if model.section.isLive {
                    Toggle("Auto-refresh", isOn: $model.autoRefresh)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Refresh every 5 seconds")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now")
                if let refreshed = model.lastRefreshed {
                    Text(refreshed, style: .time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(spacing: 2) {
                ForEach(OperationsModel.Section.allCases) { section in
                    let selected = model.section == section
                    Button {
                        model.section = section
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? Theme.accent : .secondary)
                            .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Running queries

private struct RunningQueriesView: View {
    let model: OperationsModel
    @State private var selection: RunningQuery.ID?

    var body: some View {
        LoadableView(state: model.queries, retry: { model.refresh() }) { queries in
            if queries.isEmpty {
                ContentUnavailableView("Nothing Running", systemImage: "moon.zzz", description: Text("No queries are running right now (this view hides its own monitoring queries)."))
            } else {
                Table(queries, selection: $selection) {
                    TableColumn("Elapsed") { Text(Format.duration(seconds: $0.elapsed)).monospacedDigit() }.width(70)
                    TableColumn("Host") { Text($0.host ?? "—").foregroundStyle(.secondary) }.width(min: 70, ideal: 110)
                    TableColumn("User") { Text($0.user) }.width(min: 60, ideal: 90)
                    TableColumn("Query") { Text($0.query.replacingOccurrences(of: "\n", with: " ")).font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled) }
                    TableColumn("Read") { query in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(Format.count(query.readRows)) rows").monospacedDigit()
                            Text(Format.bytes(query.readBytes)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .width(100)
                    TableColumn("Progress") { query in
                        if let fraction = query.fractionDone { ProgressView(value: fraction).frame(width: 70) } else { Text("—").foregroundStyle(.tertiary) }
                    }
                    .width(80)
                    TableColumn("Memory") { Text(Format.bytes($0.memoryUsage)).monospacedDigit() }.width(76)
                    TableColumn("Query ID") { Text($0.queryID).font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled) }.width(min: 80, ideal: 140)
                    TableColumn("") { query in
                        Button("Kill…") { model.confirmKill(query) }.buttonStyle(.borderless).foregroundStyle(.red)
                    }
                    .width(44)
                }
                .contextMenu(forSelectionType: RunningQuery.ID.self) { ids in
                    if let id = ids.first, let query = queries.first(where: { $0.id == id }) {
                        Button("Copy Query") { Pasteboard.copy(query.query) }
                        Button("Copy Query ID") { Pasteboard.copy(query.queryID) }
                        Button("Open in Editor") { model.workspace.openSQL(text: query.query, database: query.currentDatabase) }
                        Divider()
                        Button("Kill Query…") { model.confirmKill(query) }
                    }
                }
            }
        }
    }
}

// MARK: - Replication

private struct ReplicationOverview: View {
    let model: OperationsModel

    var body: some View {
        VSplitView {
            LoadableView(state: model.replicas, retry: { model.refresh() }) { replicas in
                if replicas.isEmpty {
                    ContentUnavailableView("No Replicated Tables", systemImage: "square.on.square", description: Text("This server has no Replicated*MergeTree tables."))
                } else {
                    Table(replicas) {
                        TableColumn("Health") { Badge(text: Theme.label(for: $0.health), color: Theme.color(for: $0.health)) }.width(110)
                        TableColumn("Table") { Text("\($0.database).\($0.table)").font(Theme.monospacedSmall) }.width(min: 140, ideal: 200)
                        TableColumn("Delay") { Text(Format.duration(seconds: Double($0.absoluteDelay))).monospacedDigit() }.width(70)
                        TableColumn("Queue") { Text("\($0.queueSize)").monospacedDigit() }.width(50)
                        TableColumn("Inserts") { Text("\($0.insertsInQueue)").monospacedDigit() }.width(54)
                        TableColumn("Merges") { Text("\($0.mergesInQueue)").monospacedDigit() }.width(54)
                        TableColumn("Leader") { Text($0.isLeader ? "yes" : "") }.width(50)
                        TableColumn("Replica") { Text($0.replicaName ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
                        TableColumn("Exception") { Text($0.zookeeperException ?? $0.lastQueueUpdateException ?? "").foregroundStyle(.red).lineLimit(2) }
                    }
                }
            }
            .frame(minHeight: 160)
            LoadableView(state: model.queue, retry: { model.refresh() }) { queue in
                ReplicationQueueTable(queue: queue, showsTable: true)
            }
            .frame(minHeight: 120)
        }
    }
}

// MARK: - Query log

private struct QueryLogView: View {
    @Bindable var model: OperationsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Analysis", selection: $model.logAnalysis) {
                    ForEach(OperationsModel.LogAnalysis.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Picker("Window", selection: $model.logHours) {
                    Text("15 minutes").tag(0.25)
                    Text("1 hour").tag(1.0)
                    Text("6 hours").tag(6.0)
                    Text("24 hours").tag(24.0)
                    Text("7 days").tag(168.0)
                }
                .frame(maxWidth: 180)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            switch model.logAnalysis {
            case .slowest, .memory, .failed:
                LoadableView(state: model.logEntries, retry: { model.refresh() }) { entries in
                    if let entries { QueryLogTable(entries: entries, workspace: model.workspace, emphasizeMemory: model.logAnalysis == .memory) } else { unavailable }
                }
            case .patterns:
                LoadableView(state: model.patterns, retry: { model.refresh() }) { patterns in
                    if let patterns {
                        Table(patterns) {
                            TableColumn("Total") { Text(Format.duration(milliseconds: Double($0.totalDurationMilliseconds))).monospacedDigit() }.width(80)
                            TableColumn("Count") { Text(Format.count($0.count)).monospacedDigit() }.width(64)
                            TableColumn("Avg") { Text(Format.duration(milliseconds: $0.averageDurationMilliseconds)).monospacedDigit() }.width(70)
                            TableColumn("Max") { Text(Format.duration(milliseconds: Double($0.maxDurationMilliseconds))).monospacedDigit() }.width(70)
                            TableColumn("Read") { Text(Format.bytes($0.totalReadBytes)).monospacedDigit() }.width(80)
                            TableColumn("Max memory") { Text(Format.bytes($0.maxMemoryUsage)).monospacedDigit() }.width(84)
                            TableColumn("Failures") { Text($0.failures > 0 ? "\($0.failures)" : "").foregroundStyle(.red).monospacedDigit() }.width(60)
                            TableColumn("Example") { Text($0.sample.replacingOccurrences(of: "\n", with: " ")).font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled) }
                        }
                    } else { unavailable }
                }
            case .users:
                LoadableView(state: model.users, retry: { model.refresh() }) { users in
                    if let users {
                        Table(users) {
                            TableColumn("User") { Text($0.user) }
                            TableColumn("Queries") { Text(Format.count($0.queries)).monospacedDigit() }.width(80)
                            TableColumn("Failures") { Text(Format.count($0.failures)).monospacedDigit().foregroundStyle($0.failures > 0 ? .red : .secondary) }.width(70)
                            TableColumn("Total time") { Text(Format.duration(milliseconds: Double($0.totalDurationMilliseconds))).monospacedDigit() }.width(90)
                            TableColumn("Rows read") { Text(Format.count($0.readRows)).monospacedDigit() }.width(110)
                            TableColumn("Bytes read") { Text(Format.bytes($0.readBytes)).monospacedDigit() }.width(90)
                            TableColumn("Max memory") { Text(Format.bytes($0.maxMemoryUsage)).monospacedDigit() }.width(90)
                        }
                    } else { unavailable }
                }
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Query Log Unavailable", systemImage: "list.bullet.rectangle",
                               description: Text("system.query_log does not exist on this server yet (it appears after the first flush, or the log is disabled in the server config)."))
    }
}

private struct QueryLogTable: View {
    let entries: [QueryLogEntry]
    let workspace: WorkspaceModel
    var emphasizeMemory = false
    @State private var selection: QueryLogEntry.ID?

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("Time") { Text($0.eventTime).monospacedDigit().foregroundStyle(.secondary) }.width(min: 120, ideal: 140)
            TableColumn("Duration") { Text(Format.duration(milliseconds: Double($0.durationMilliseconds))).monospacedDigit() }.width(76)
            TableColumn("Memory") { entry in
                Text(Format.bytes(entry.memoryUsage)).monospacedDigit().fontWeight(emphasizeMemory ? .semibold : .regular)
            }
            .width(80)
            TableColumn("Read") { Text("\(Format.count($0.readRows)) · \(Format.bytes($0.readBytes))").monospacedDigit() }.width(min: 110, ideal: 140)
            TableColumn("User") { Text($0.user) }.width(min: 50, ideal: 80)
            TableColumn("Query") { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.query.replacingOccurrences(of: "\n", with: " ")).font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled)
                    if let exception = entry.exception { Text(exception).font(.caption).foregroundStyle(.red).lineLimit(2) }
                }
            }
        }
        .contextMenu(forSelectionType: QueryLogEntry.ID.self) { ids in
            if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                Button("Copy Query") { Pasteboard.copy(entry.query) }
                Button("Copy Query ID") { Pasteboard.copy(entry.queryID) }
                Button("Open in Editor") { workspace.openSQL(text: entry.query) }
            }
        }
    }
}

// MARK: - Storage and dictionaries

private struct StorageView: View {
    let model: OperationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LoadableView(state: model.disks, retry: { model.refresh() }) { disks in
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(disks) { disk in
                            Card(title: disk.name, systemImage: "internaldrive") {
                                if let used = disk.usedFraction {
                                    ProgressView(value: used).tint(used > 0.9 ? .red : used > 0.8 ? .orange : Theme.accent)
                                }
                                KeyValueList(items: [("Type", disk.type ?? "local"), ("Free", Format.bytes(disk.freeSpace)), ("Total", Format.bytes(disk.totalSpace)),
                                                     ("Path", disk.path ?? "—")], monospacedValues: true)
                            }
                        }
                    }
                }
                .frame(minHeight: 100)
                Card(title: "Storage policies", systemImage: "square.3.layers.3d") {
                    LoadableView(state: model.policies, retry: { model.refresh() }) { volumes in
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("Policy").foregroundStyle(.secondary)
                                Text("Volume").foregroundStyle(.secondary)
                                Text("Disks").foregroundStyle(.secondary)
                                Text("Move factor").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            ForEach(volumes) { volume in
                                GridRow {
                                    Text(volume.policy).font(Theme.monospacedSmall)
                                    Text("\(volume.priority). \(volume.volume)")
                                    Text(volume.disks.joined(separator: ", ")).font(Theme.monospacedSmall)
                                    Text(volume.moveFactor.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit()
                                }
                            }
                        }
                    }
                    .frame(minHeight: 40)
                }
            }
            .padding(18)
        }
    }
}

private struct DictionariesView: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.dictionaries, retry: { model.refresh() }) { dictionaries in
            if dictionaries.isEmpty {
                ContentUnavailableView("No Dictionaries", systemImage: "book.closed")
            } else {
                Table(dictionaries) {
                    TableColumn("Status") { StateBadge(state: $0.status) }.width(130)
                    TableColumn("Dictionary") { Text($0.qualifiedName).font(Theme.monospacedSmall) }.width(min: 120, ideal: 180)
                    TableColumn("Layout") { Text($0.type ?? "—") }.width(min: 80, ideal: 120)
                    TableColumn("Elements") { Text(Format.count($0.elementCount)).monospacedDigit() }.width(80)
                    TableColumn("Memory") { Text(Format.bytes($0.bytesAllocated)).monospacedDigit() }.width(80)
                    TableColumn("Hit rate") { Text(Format.percent($0.hitRate.map { $0 * 100 })).monospacedDigit() }.width(64)
                    TableColumn("Last update") { Text($0.lastSuccessfulUpdateTime ?? "—").foregroundStyle(.secondary).monospacedDigit() }.width(min: 120, ideal: 140)
                    TableColumn("Last exception") { Text($0.lastException ?? "").foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
                    TableColumn("") { dictionary in
                        if !model.workspace.isReadOnly {
                            Button("Reload…") { model.reload(dictionary) }.buttonStyle(.borderless)
                        }
                    }
                    .width(60)
                }
            }
        }
    }
}
