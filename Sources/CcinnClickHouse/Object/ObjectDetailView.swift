import Charts
import CcinnClickHouseKit
import ClickHouseKit
import SwiftUI

struct ObjectDetailView: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        VStack(spacing: 0) {
            ObjectHeader(model: model)
            SectionBar(model: model)
            Divider()
            Group {
                switch model.section {
                case .overview: OverviewSection(model: model)
                case .columns: ColumnsSection(model: model)
                case .parts: PartsSection(model: model)
                case .indexes: IndexesSection(model: model)
                case .mutations: MutationsSection(model: model)
                case .replication: ReplicationSection(model: model)
                case .ddl: DDLSection(model: model)
                case .data: DataSection(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $model.inspected) { ValueInspectorView(value: $0) }
        .confirmationDialog("Kill mutation \(model.pendingKill?.mutationID ?? "")?",
                            isPresented: Binding(get: { model.pendingKill != nil }, set: { if !$0 { model.pendingKill = nil } }),
                            titleVisibility: .visible) {
            Button("Kill Mutation", role: .destructive) {
                if let mutation = model.pendingKill { model.killMutation(mutation) }
                model.pendingKill = nil
            }
        } message: {
            Text(model.pendingKill.map { String($0.command.prefix(300)) } ?? "")
        }
    }
}

// MARK: - Header

private struct ObjectHeader: View {
    let model: ObjectDetailModel

    var body: some View {
        let table = model.table
        let classification = model.classification
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: Theme.icon(for: classification.family))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.color(for: classification.family))
                .frame(width: 44, height: 44)
                .background(Theme.color(for: classification.family).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(table.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    EngineBadge(classification: classification)
                    if classification.isReplicated { Badge(text: "Replicated", color: Theme.color(for: .replicatedMergeTree), systemImage: "square.on.square") }
                    if let worst = model.partWarnings.first {
                        Badge(text: worst.level == .warning ? "Many parts" : "Too many parts", color: Theme.color(for: worst.level),
                              systemImage: "exclamationmark.triangle.fill")
                    }
                }
                HStack(spacing: 6) {
                    Text(table.engine)
                    Text("·")
                    Text(table.database)
                    if let comment = table.comment, !comment.isEmpty { Text("· \(comment)").lineLimit(1) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if table.family != .dictionary, table.family != .streaming {
                Button { model.openQuery() } label: { Label("Query", systemImage: "play.rectangle") }
                    .help("Open a SQL editor with SELECT * FROM \(table.name)")
            }
            Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Reload this table's details")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SectionBar: View {
    let model: ObjectDetailModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.availableSections) { section in
                let selected = model.section == section
                Button {
                    model.select(section)
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
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// Shows loading / error / content for a `Loadable`.
struct LoadableView<Value, Content: View>: View {
    let state: Loadable<Value>
    var retry: (() -> Void)?
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                ErrorBanner(message: message)
                if let retry { Button("Try Again", action: retry) }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(value):
            content(value)
        }
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        let table = model.details.value ?? model.table
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if table.family.hasParts {
                    statTiles(table)
                    ForEach(model.partWarnings, id: \.message) { warning in
                        NoticeBanner(message: warning.message, systemImage: "exclamationmark.triangle.fill", color: Theme.color(for: warning.level))
                    }
                }
                if case let .failed(message) = model.details { ErrorBanner(message: message) }
                HStack(alignment: .top, spacing: 14) {
                    keysCard(table)
                    if let settings = model.definition?.settings, !settings.isEmpty {
                        Card(title: "Settings", systemImage: "slider.horizontal.3") {
                            KeyValueList(items: settings.map { ($0.name, $0.value) }, monospacedValues: true)
                        }
                        .frame(maxWidth: 360)
                    }
                }
                if table.family == .distributed { distributedCard }
                if table.family == .materializedView { materializedViewCard(table) }
                if table.family == .view, let query = table.asSelect { queryCard(title: "Definition", query: query) }
                if table.family == .dictionary { dictionaryCard }
                if model.classification.isReplicated { replicationCard }
                if table.family.hasParts { compressionCard }
                if !table.dependentTables.isEmpty {
                    Card(title: "Materialized views reading this table", systemImage: "square.stack.3d.up.fill") {
                        FlowText(items: table.dependentTables)
                    }
                }
            }
            .padding(18)
        }
    }

    private func statTiles(_ table: TableInfo) -> some View {
        let partitions = model.partitions.value
        let activeParts = partitions?.reduce(Int64(0)) { $0 &+ $1.activeParts } ?? table.activeParts
        let ratio = table.compressionRatio ?? compressionFromPartitions(partitions)
        return HStack(spacing: 12) {
            StatTile(title: "Rows", value: Format.count(table.totalRows), systemImage: "number")
            StatTile(title: "On disk", value: Format.bytes(table.totalBytes), systemImage: "internaldrive")
            StatTile(title: "Compression", value: ratio.map { String(format: "%.1f×", $0) } ?? "—", systemImage: "arrow.down.right.and.arrow.up.left")
            StatTile(title: "Active parts", value: Format.count(activeParts), systemImage: "square.stack.3d.down.forward",
                     tint: model.partWarnings.first.map { Theme.color(for: $0.level) } ?? Theme.accent)
            StatTile(title: "Partitions", value: partitions.map { Format.count($0.count) } ?? "—", systemImage: "square.split.bottomrightquarter")
        }
    }

    private func compressionFromPartitions(_ partitions: [PartitionSummary]?) -> Double? {
        guard let partitions else { return nil }
        let compressed = partitions.reduce(Int64(0)) { $0 &+ $1.compressedBytes }
        let uncompressed = partitions.reduce(Int64(0)) { $0 &+ $1.uncompressedBytes }
        guard compressed > 0, uncompressed > 0 else { return nil }
        return Double(uncompressed) / Double(compressed)
    }

    private func keysCard(_ table: TableInfo) -> some View {
        // The engine with its arguments; keys, TTL and settings are listed separately.
        let arguments = model.definition?.arguments ?? []
        var items: [(String, String)] = [("Engine", arguments.isEmpty ? table.engine : "\(table.engine)(\(arguments.joined(separator: ", ")))")]
        if let key = table.partitionKey, !key.isEmpty { items.append(("Partition by", key)) }
        if let key = table.sortingKey, !key.isEmpty { items.append(("Order by", key)) }
        if let key = table.primaryKey, !key.isEmpty, key != table.sortingKey { items.append(("Primary key", key)) }
        if let key = table.samplingKey, !key.isEmpty { items.append(("Sample by", key)) }
        if let ttl = model.definition?.ttl { items.append(("TTL", ttl)) }
        let columnTTLs = model.createDetails?.columnTTLs ?? [:]
        for (column, ttl) in columnTTLs.sorted(by: { $0.key < $1.key }) { items.append(("TTL · \(column)", ttl)) }
        if let policy = table.storagePolicy, !policy.isEmpty { items.append(("Storage policy", policy)) }
        if let replication = model.definition?.replicationPath {
            items.append(("Keeper path", replication.path))
            items.append(("Replica", replication.replica))
        }
        if let modified = table.metadataModificationTime { items.append(("Metadata changed", modified)) }
        return Card(title: "Engine & keys", systemImage: "key") {
            KeyValueList(items: items, monospacedValues: true)
        }
    }

    @ViewBuilder
    private var distributedCard: some View {
        if let target = model.definition?.distributedTarget {
            Card(title: "Distributed", systemImage: "point.3.connected.trianglepath.dotted") {
                KeyValueList(items: [("Cluster", target.cluster), ("Local table", "\(target.database).\(target.table)"),
                                     ("Sharding key", target.shardingKey ?? "—")], monospacedValues: true)
                LoadableView(state: model.distributionQueue, retry: model.loadDistributionQueue) { queue in
                    if queue.isEmpty {
                        Label("No pending asynchronous inserts", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
                    } else {
                        ForEach(queue) { entry in
                            HStack {
                                Text(entry.dataPath).font(Theme.monospacedSmall).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(entry.dataFiles) files · \(Format.bytes(entry.dataCompressedBytes))").monospacedDigit()
                                if entry.isBlocked { Badge(text: "Blocked", color: .red) }
                                if entry.errorCount > 0 { Badge(text: "\(entry.errorCount) errors", color: .orange) }
                            }
                            if let error = entry.lastException { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
                        }
                    }
                }
                .frame(minHeight: 30)
            }
        }
    }

    private func materializedViewCard(_ table: TableInfo) -> some View {
        Card(title: "Materialized view", systemImage: "square.stack.3d.up.fill") {
            KeyValueList(items: [("Writes to", model.createDetails?.materializedViewTarget ?? "inner table (.inner_id.…)")], monospacedValues: true)
            if let query = table.asSelect {
                Text(query).font(Theme.monospacedSmall).textSelection(.enabled).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
            }
        }
    }

    private func queryCard(title: String, query: String) -> some View {
        Card(title: title, systemImage: "eye") {
            Text(query).font(Theme.monospacedSmall).textSelection(.enabled)
        }
    }

    private var dictionaryCard: some View {
        Card(title: "Dictionary", systemImage: "book.closed") {
            LoadableView(state: model.dictionary, retry: model.loadDictionary) { dictionary in
                if let dictionary {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StateBadge(state: dictionary.status)
                            Spacer()
                            Button { model.reloadDictionary() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                                .disabled(model.actionInFlight || model.workspace.isReadOnly)
                        }
                        KeyValueList(items: [
                            ("Layout", dictionary.type ?? "—"), ("Source", dictionary.source ?? "—"), ("Keys", dictionary.keyNames.joined(separator: ", ")),
                            ("Attributes", dictionary.attributeNames.joined(separator: ", ")), ("Elements", Format.count(dictionary.elementCount)),
                            ("Memory", Format.bytes(dictionary.bytesAllocated)), ("Hit rate", Format.percent(dictionary.hitRate.map { $0 * 100 })),
                            ("Lifetime", "\(dictionary.lifetimeMin ?? 0)–\(dictionary.lifetimeMax ?? 0) s"),
                            ("Last update", dictionary.lastSuccessfulUpdateTime ?? "—"),
                        ])
                        if let error = dictionary.lastException { ErrorBanner(message: error) }
                    }
                } else {
                    Text("The dictionary is not loaded yet; it loads on first use.").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 40)
        }
    }

    private var replicationCard: some View {
        Card(title: "Replication", systemImage: "arrow.triangle.2.circlepath") {
            LoadableView(state: model.replica, retry: model.loadReplication) { replica in
                if let replica {
                    ReplicaSummary(replica: replica)
                } else {
                    Text("No replica status (the table may be starting up).").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 40)
        }
    }

    @ViewBuilder
    private var compressionCard: some View {
        if let columns = model.columns.value, columns.contains(where: { ($0.compressedBytes ?? 0) > 0 }) {
            let top = columns.filter { ($0.compressedBytes ?? 0) > 0 }.sorted { ($0.compressedBytes ?? 0) > ($1.compressedBytes ?? 0) }.prefix(12)
            Card(title: "Largest columns on disk", systemImage: "chart.bar.xaxis") {
                Chart(Array(top)) { column in
                    BarMark(x: .value("Bytes", column.compressedBytes ?? 0), y: .value("Column", column.name))
                        .foregroundStyle(Theme.accent.gradient)
                        .annotation(position: .trailing) {
                            Text(column.compressionRatio.map { String(format: "%.1f×", $0) } ?? "")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis { AxisMarks { value in AxisValueLabel { if let bytes = value.as(Int64.self) { Text(Format.bytes(bytes)) } } } }
                .frame(height: CGFloat(max(3, top.count)) * 24 + 30)
            }
        }
    }
}

/// Health summary of one replicated table.
struct ReplicaSummary: View {
    let replica: ReplicaStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(text: Theme.label(for: replica.health), color: Theme.color(for: replica.health))
                if replica.isLeader { Badge(text: "Leader", color: .indigo) }
                if let active = replica.activeReplicas, let total = replica.totalReplicas {
                    Badge(text: "\(active)/\(total) replicas active", color: active < total ? .orange : .green)
                }
            }
            KeyValueList(items: [
                ("Absolute delay", Format.duration(seconds: Double(replica.absoluteDelay))),
                ("Queue", "\(replica.queueSize) (inserts \(replica.insertsInQueue), merges \(replica.mergesInQueue), mutations \(replica.mutationsInQueue))"),
                ("Oldest queue entry", replica.queueOldestTime ?? "—"),
                ("Future parts / to check", "\(replica.futureParts) / \(replica.partsToCheck)"),
                ("Replica", replica.replicaName ?? "—"),
                ("Keeper path", replica.zookeeperPath ?? "—"),
            ], monospacedValues: true)
            if let error = replica.lastQueueUpdateException { ErrorBanner(message: error) }
            if let error = replica.zookeeperException { ErrorBanner(message: error) }
        }
    }
}

/// Wrapping list of monospaced names.
struct FlowText: View {
    let items: [String]

    var body: some View {
        Text(items.joined(separator: "   ")).font(Theme.monospacedSmall).textSelection(.enabled)
    }
}

// MARK: - Columns

private struct ColumnsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.columns, retry: model.loadColumns) { columns in
            VStack(spacing: 0) {
                if model.table.family.hasParts, !columns.contains(where: { ($0.compressedBytes ?? 0) > 0 }), columns.contains(where: { ($0.uncompressedBytes ?? 0) == 0 }) {
                    NoticeBanner(message: "Per-column sizes are not available for Compact parts (small parts store all columns in one file).")
                        .padding(10)
                }
                Table(columns) {
                    TableColumn("#") { Text("\($0.position)").foregroundStyle(.tertiary).monospacedDigit() }.width(30)
                    TableColumn("Name") { column in
                        HStack(spacing: 4) {
                            if column.isInPartitionKey { KeyMark(text: "P", help: "Partition key", color: .orange) }
                            if column.isInSortingKey { KeyMark(text: "S", help: "Sorting key", color: Theme.accent) }
                            if column.isInPrimaryKey { KeyMark(text: "K", help: "Primary key", color: .indigo) }
                            if column.isInSamplingKey { KeyMark(text: "≈", help: "Sampling key", color: .teal) }
                            Text(column.name).fontWeight(column.isInSortingKey ? .semibold : .regular).textSelection(.enabled)
                        }
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn("Type") { Text($0.type).font(Theme.monospacedSmall).foregroundStyle(Color(nsColor: .syntaxKeyword)) }.width(min: 100, ideal: 170)
                    TableColumn("Default") { column in
                        Text([column.defaultKind, column.defaultExpression].compactMap { $0 }.joined(separator: " ")).font(Theme.monospacedSmall).foregroundStyle(.secondary)
                    }
                    TableColumn("Codec") { Text($0.codec ?? "").font(Theme.monospacedSmall) }.width(min: 60, ideal: 110)
                    TableColumn("TTL") { Text($0.ttl ?? "").font(Theme.monospacedSmall).foregroundStyle(.orange) }.width(min: 40, ideal: 90)
                    TableColumn("Compressed") { Text(Format.bytes($0.compressedBytes)).monospacedDigit() }.width(84)
                    TableColumn("Uncompressed") { Text(Format.bytes($0.uncompressedBytes)).monospacedDigit() }.width(92)
                    TableColumn("Ratio") { column in
                        Text(column.compressionRatio.map { String(format: "%.1f×", $0) } ?? "—").monospacedDigit()
                            .foregroundStyle((column.compressionRatio ?? 10) < 1.5 ? .orange : .primary)
                    }
                    .width(52)
                    TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
    }
}

private struct KeyMark: View {
    let text: String
    let help: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .frame(width: 13, height: 13)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .help(help)
    }
}

// MARK: - Parts

private struct PartsSection: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        VSplitView {
            LoadableView(state: model.partitions, retry: model.loadPartitions) { partitions in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("\(Format.count(partitions.count)) partitions · \(Format.count(partitions.reduce(0) { $0 &+ $1.activeParts })) active parts")
                            .font(.callout.weight(.semibold))
                        if let limits = model.limits {
                            Text("parts_to_delay_insert \(limits.partsToDelayInsert) · parts_to_throw_insert \(limits.partsToThrowInsert)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.partsPartition != nil {
                            Button("Show all parts") { model.partsPartition = nil }.buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    Table(partitions.reversed(), selection: Binding(get: { model.partsPartition }, set: { model.partsPartition = $0 })) {
                        TableColumn("Partition") { partition in
                            HStack(spacing: 6) {
                                if let limits = model.limits {
                                    Circle().fill(Theme.color(for: PartHealth.level(activeParts: partition.activeParts, limits: limits))).frame(width: 7, height: 7)
                                }
                                Text(partition.isUnpartitioned ? "(unpartitioned)" : partition.partition).font(Theme.monospacedSmall).textSelection(.enabled)
                            }
                        }
                        TableColumn("Active parts") { Text(Format.count($0.activeParts)).monospacedDigit() }.width(78)
                        TableColumn("Inactive") { Text(Format.count($0.inactiveParts)).monospacedDigit().foregroundStyle(.secondary) }.width(60)
                        TableColumn("Rows") { Text(Format.count($0.rows)).monospacedDigit() }.width(90)
                        TableColumn("On disk") { Text(Format.bytes($0.bytesOnDisk)).monospacedDigit() }.width(80)
                        TableColumn("Ratio") { Text($0.compressionRatio.map { String(format: "%.1f×", $0) } ?? "—").monospacedDigit() }.width(52)
                        TableColumn("Data range") { partition in
                            Text([partition.minDate ?? partition.minTime, partition.maxDate ?? partition.maxTime].compactMap { $0 }.joined(separator: " → "))
                                .foregroundStyle(.secondary)
                        }
                        TableColumn("Last change") { Text($0.lastModified ?? "—").foregroundStyle(.secondary).monospacedDigit() }.width(min: 120, ideal: 140)
                    }
                }
            }
            .frame(minHeight: 160)
            LoadableView(state: model.parts, retry: model.loadParts) { parts in
                VStack(spacing: 0) {
                    HStack {
                        Text(model.partsPartition.map { "Active parts of partition \($0)" } ?? "Newest active parts").font(.callout.weight(.semibold))
                        Text("\(Format.count(parts.count))").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    Table(parts) {
                        Group {
                            TableColumn("Part") { (part: PartInfo) in Text(part.name).font(Theme.monospacedSmall).textSelection(.enabled) }
                                .width(min: 140, ideal: 190)
                            TableColumn("Type") { (part: PartInfo) in Text(part.partType ?? "—") }.width(66)
                            TableColumn("Level") { (part: PartInfo) in Text("\(part.level)").monospacedDigit() }.width(40)
                        }
                        TableColumn("Rows") { Text(Format.count($0.rows)).monospacedDigit() }.width(86)
                        TableColumn("On disk") { Text(Format.bytes($0.bytesOnDisk)).monospacedDigit() }.width(76)
                        TableColumn("Uncompressed") { Text(Format.bytes($0.uncompressedBytes)).monospacedDigit() }.width(90)
                        TableColumn("Ratio") { Text($0.compressionRatio.map { String(format: "%.1f×", $0) } ?? "—").monospacedDigit() }.width(50)
                        TableColumn("Marks") { Text(Format.count($0.marks)).monospacedDigit() }.width(60)
                        TableColumn("Disk") { Text($0.disk ?? "—") }.width(70)
                        TableColumn("Modified") { Text($0.modificationTime ?? "—").monospacedDigit().foregroundStyle(.secondary) }.width(min: 120, ideal: 140)
                        TableColumn("Delete TTL") { part in
                            Text([part.deleteTTLMin, part.deleteTTLMax].compactMap { $0 }.joined(separator: " → ")).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }
}

// MARK: - Indexes & projections

private struct IndexesSection: View {
    let model: ObjectDetailModel

    var body: some View {
        VSplitView {
            LoadableView(state: model.indices, retry: model.loadIndexes) { indices in
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Data-skipping indexes", count: indices.count)
                    if indices.isEmpty {
                        Text("No skipping indexes. Add one with ALTER TABLE … ADD INDEX … TYPE minmax / set / bloom_filter.").foregroundStyle(.secondary).padding(14)
                        Spacer()
                    } else {
                        Table(indices) {
                            TableColumn("Name") { Text($0.name).font(Theme.monospacedSmall) }
                            TableColumn("Type") { Text($0.typeFull ?? $0.type).font(Theme.monospacedSmall).foregroundStyle(Color(nsColor: .syntaxKeyword)) }
                            TableColumn("Expression") { Text($0.expression).font(Theme.monospacedSmall).textSelection(.enabled) }
                            TableColumn("Granularity") { Text("\($0.granularity)").monospacedDigit() }.width(76)
                            TableColumn("Compressed") { Text(Format.bytes($0.compressedBytes)).monospacedDigit() }.width(84)
                            TableColumn("Uncompressed") { Text(Format.bytes($0.uncompressedBytes)).monospacedDigit() }.width(92)
                        }
                    }
                }
            }
            .frame(minHeight: 140)
            LoadableView(state: model.projections, retry: model.loadIndexes) { projections in
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Projections", count: projections.count)
                    if projections.isEmpty {
                        Text("No projections.").foregroundStyle(.secondary).padding(14)
                        Spacer()
                    } else {
                        Table(projections) {
                            TableColumn("Name") { Text($0.name).font(Theme.monospacedSmall) }.width(min: 100, ideal: 140)
                            TableColumn("Type") { Text($0.type ?? "—") }.width(80)
                            TableColumn("Definition") { Text($0.definition ?? $0.sortingKey ?? "").font(Theme.monospacedSmall).textSelection(.enabled) }
                            TableColumn("Parts") { Text(Format.count($0.parts)).monospacedDigit() }.width(56)
                            TableColumn("Rows") { Text(Format.count($0.rows)).monospacedDigit() }.width(86)
                            TableColumn("On disk") { Text(Format.bytes($0.bytesOnDisk)).monospacedDigit() }.width(80)
                        }
                    }
                }
            }
            .frame(minHeight: 140)
        }
    }
}

private func sectionTitle(_ title: String, count: Int) -> some View {
    HStack {
        Text(title).font(.callout.weight(.semibold))
        Text("\(count)").foregroundStyle(.secondary)
        Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
}

// MARK: - Mutations & merges

private struct MutationsSection: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        VSplitView {
            LoadableView(state: model.mutations, retry: model.loadMutations) { mutations in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Mutations").font(.callout.weight(.semibold))
                        Text("\(mutations.filter { !$0.isDone }.count) running").foregroundStyle(.secondary)
                        Spacer()
                        Button { model.loadMutations() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    MutationTable(mutations: mutations, canKill: !model.workspace.isReadOnly) { model.pendingKill = $0 }
                }
            }
            .frame(minHeight: 160)
            LoadableView(state: model.merges, retry: model.loadMutations) { merges in
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Running merges", count: merges.count)
                    MergeTable(merges: merges)
                }
            }
            .frame(minHeight: 120)
        }
    }
}

struct MutationTable: View {
    let mutations: [MutationInfo]
    var showsTable = false
    let canKill: Bool
    let onKill: (MutationInfo) -> Void

    var body: some View {
        if mutations.isEmpty {
            Text("No mutations.").foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Table(mutations) {
                TableColumn("State") { mutation in
                    if mutation.isDone {
                        Badge(text: mutation.isKilled ? "KILLED" : "DONE", color: mutation.isKilled ? .secondary : .green)
                    } else {
                        Badge(text: mutation.isStuck ? "FAILING" : "RUNNING", color: mutation.isStuck ? .red : .blue)
                    }
                }
                .width(74)
                TableColumn("Table") { Text(showsTable ? "\($0.database).\($0.table)" : $0.mutationID).font(Theme.monospacedSmall) }.width(min: 110, ideal: 150)
                TableColumn("Command") { Text($0.command).font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled) }
                TableColumn("Created") { Text($0.createTime ?? "—").monospacedDigit().foregroundStyle(.secondary) }.width(min: 120, ideal: 140)
                TableColumn("Parts to do") { Text("\($0.partsToDo)").monospacedDigit() }.width(70)
                TableColumn("Latest failure") { Text($0.latestFailReason ?? "").foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
                TableColumn("") { mutation in
                    if !mutation.isDone, canKill {
                        Button("Kill…") { onKill(mutation) }.buttonStyle(.borderless).foregroundStyle(.red)
                    }
                }
                .width(44)
            }
        }
    }
}

struct MergeTable: View {
    let merges: [MergeInfo]
    var showsTable = false

    var body: some View {
        if merges.isEmpty {
            Text("No merges running.").foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Table(merges) {
                TableColumn("Table") { Text("\($0.database).\($0.table)").font(Theme.monospacedSmall) }.width(min: 120, ideal: 160)
                TableColumn("Result part") { Text($0.resultPartName).font(Theme.monospacedSmall) }.width(min: 140, ideal: 180)
                TableColumn("Progress") { merge in
                    ProgressView(value: merge.progress).frame(width: 90)
                }
                .width(100)
                TableColumn("Parts") { Text("\($0.numParts)").monospacedDigit() }.width(44)
                TableColumn("Size") { Text(Format.bytes($0.totalSizeCompressed)).monospacedDigit() }.width(80)
                TableColumn("Rows read") { Text(Format.count($0.rowsRead)).monospacedDigit() }.width(90)
                TableColumn("Memory") { Text(Format.bytes($0.memoryUsage)).monospacedDigit() }.width(76)
                TableColumn("Elapsed") { Text(Format.duration(seconds: $0.elapsed)).monospacedDigit() }.width(70)
                TableColumn("Kind") { Text($0.isMutation ? "mutation" : ($0.mergeType ?? "merge")).foregroundStyle(.secondary) }.width(80)
                TableColumn("Host") { Text($0.host ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 100)
            }
        }
    }
}

// MARK: - Replication

private struct ReplicationSection: View {
    let model: ObjectDetailModel

    var body: some View {
        VSplitView {
            ScrollView {
                LoadableView(state: model.replica, retry: model.loadReplication) { replica in
                    if let replica {
                        ReplicaSummary(replica: replica).padding(18)
                    } else {
                        Text("No replica status.").foregroundStyle(.secondary).padding(18)
                    }
                }
                .frame(minHeight: 120)
            }
            .frame(minHeight: 180)
            LoadableView(state: model.queue, retry: model.loadReplication) { queue in
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Replication queue", count: queue.count)
                    ReplicationQueueTable(queue: queue)
                }
            }
            .frame(minHeight: 140)
        }
    }
}

struct ReplicationQueueTable: View {
    let queue: [ReplicationQueueEntry]
    var showsTable = false

    var body: some View {
        if queue.isEmpty {
            Text("The replication queue is empty.").foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Table(queue) {
                TableColumn("Table") { Text("\($0.database).\($0.table)").font(Theme.monospacedSmall) }.width(min: 120, ideal: 160)
                TableColumn("Type") { Text($0.type).font(Theme.monospacedSmall) }.width(min: 90, ideal: 110)
                TableColumn("Part") { Text($0.newPartName ?? "").font(Theme.monospacedSmall) }.width(min: 120, ideal: 170)
                TableColumn("Tries") { entry in
                    Text("\(entry.numTries)").monospacedDigit().foregroundStyle(entry.numTries > 10 ? .red : .primary)
                }
                .width(44)
                TableColumn("Executing") { Text($0.isCurrentlyExecuting ? "yes" : "") }.width(64)
                TableColumn("Postponed") { Text($0.postponeReason ?? "").foregroundStyle(.secondary).lineLimit(2) }
                TableColumn("Last exception") { Text($0.lastException ?? "").foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
                TableColumn("Created") { Text($0.createTime ?? "").monospacedDigit().foregroundStyle(.secondary) }.width(min: 120, ideal: 140)
            }
        }
    }
}

// MARK: - DDL and data

private struct DDLSection: View {
    let model: ObjectDetailModel
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        LoadableView(state: model.ddl, retry: model.loadDDL) { ddl in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        Pasteboard.copy(ddl)
                        model.workspace.showToast("DDL copied")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.workspace.openSQL(text: ddl, database: model.table.database)
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                SQLEditor(text: .constant(ddl), selection: $selection, isEditable: false, highlightsCurrentStatement: false)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

private struct DataSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.preview, retry: model.loadPreview) { result in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("First \(Format.count(result.rows.count)) rows").font(.callout.weight(.semibold))
                    Spacer()
                    Button { model.loadPreview() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button { model.openQuery() } label: { Label("Open in Editor", systemImage: "square.and.pencil") }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                ResultGrid(resultID: model.previewID, columns: result.columns, rows: result.rows, binaryCells: result.binaryCells,
                           insertTableName: model.table.qualifiedName, onInspect: { model.inspected = $0 })
            }
        }
    }
}
