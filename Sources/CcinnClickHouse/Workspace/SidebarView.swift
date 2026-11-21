import CcinnClickHouseKit
import ClickHouseKit
import SwiftUI

/// Databases (with engine badges) → tables grouped by engine family, with variant badges, replication
/// markers, row counts, filtering and context actions.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            List(selection: $workspace.sidebarSelection) {
                if let error = workspace.databasesError {
                    ErrorBanner(message: error).listRowSeparator(.hidden)
                }
                ForEach(visibleDatabases) { database in
                    DatabaseRow(workspace: workspace, database: database, filter: filter)
                }
                if workspace.isLoadingDatabases, workspace.databases.isEmpty {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                } else if let placeholder = workspace.sidebarPlaceholder {
                    SidebarPlaceholderRow(placeholder: placeholder, user: workspace.serverInfo.currentUser) {
                        workspace.showSystemDatabases = true
                    }
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }
            }
            .listStyle(.sidebar)
            .onChange(of: workspace.sidebarSelection) { _, id in
                guard let id, let table = findTable(id) else { return }
                workspace.openObject(table)
            }
        }
        .placedBelowWindowToolbar()
    }

    private var filter: String { workspace.sidebarFilter.trimmingCharacters(in: .whitespaces) }

    private var controls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tables", text: $workspace.sidebarFilter)
                    .textFieldStyle(.plain)
                if !workspace.sidebarFilter.isEmpty {
                    Button { workspace.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            Toggle(isOn: $workspace.showSystemDatabases) {
                Image(systemName: "gearshape")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(workspace.showSystemDatabases ? "Hide system databases" : "Show system databases")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var visibleDatabases: [DatabaseInfo] {
        let base = workspace.visibleDatabases
        guard !filter.isEmpty else { return base }
        return base.filter { database in
            database.name.localizedCaseInsensitiveContains(filter)
                || (workspace.objects(in: database.name)?.contains { $0.name.localizedCaseInsensitiveContains(filter) } ?? false)
        }
    }

    private func findTable(_ id: String) -> TableInfo? {
        for database in workspace.expandedDatabases {
            if let table = workspace.objects(in: database)?.first(where: { $0.id == id }) { return table }
        }
        return nil
    }
}

/// Said instead of a blank list when no database is shown.
private struct SidebarPlaceholderRow: View {
    let placeholder: SidebarPlaceholder
    let user: String?
    let showSystemDatabases: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch placeholder {
            case .noDatabases:
                Text("No databases").font(.callout.weight(.medium))
                Text(user.map { "\($0) has no access to any database." } ?? "This user has no access to any database.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            case .onlySystemDatabases:
                Text("Only system databases").font(.callout.weight(.medium))
                Button("Show System Databases", action: showSystemDatabases).buttonStyle(.link).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct DatabaseRow: View {
    let workspace: WorkspaceModel
    let database: DatabaseInfo
    let filter: String

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { workspace.expandedDatabases.contains(database.name) || (!filter.isEmpty && hasMatches) },
                                            set: { workspace.setExpanded(database.name, $0) })) {
            content
        } label: {
            HStack(spacing: 6) {
                Image(systemName: database.isSystem ? "cylinder.split.1x2" : "cylinder")
                    .foregroundStyle(database.isSystem ? Color.secondary : Theme.accent)
                Text(database.name).lineLimit(1)
                if let badge = database.engineKind.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .foregroundStyle(Theme.color(for: database.engineKind))
                        .background(Theme.color(for: database.engineKind).opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
                        .fixedSize()
                }
                Spacer()
                if let count = workspace.objects(in: database.name)?.filter({ !$0.isInnerTable }).count {
                    Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .help([database.engine + " database", database.comment].compactMap { $0 }.joined(separator: " · "))
            .contextMenu {
                Button("New Query") { workspace.openSQL(database: database.name) }
                Button("Refresh") { workspace.loadObjects(database: database.name, force: true) }
                Divider()
                Button("Merges & Mutations") { workspace.openOperations(section: .mutations) }
                Button("Replication") { workspace.openOperations(section: .replication) }
                Divider()
                Button("Copy Name") { Pasteboard.copy(database.name) }
            }
        }
    }

    private var hasMatches: Bool {
        workspace.objects(in: database.name)?.contains { $0.name.localizedCaseInsensitiveContains(filter) } ?? false
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.databaseStates[database.name] {
        case nil, .loading?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message)?:
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { workspace.loadObjects(database: database.name, force: true) }.buttonStyle(.link).font(.caption)
            }
        case let .loaded(tables)?:
            let visible = tables.filter { !$0.isInnerTable }
            let shown = filter.isEmpty ? visible : visible.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            if shown.isEmpty {
                Text(filter.isEmpty ? "No tables" : "No matches").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(groups(shown), id: \.family) { group in
                HStack(spacing: 4) {
                    Image(systemName: Theme.icon(for: group.family)).font(.system(size: 8.5))
                    Text("\(group.family.groupTitle.uppercased())  \(group.tables.count)")
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .selectionDisabled()
                ForEach(group.tables) { table in
                    TableRow(table: table, workspace: workspace)
                        .tag(table.id)
                }
            }
        }
    }

    private func groups(_ tables: [TableInfo]) -> [(family: EngineFamily, tables: [TableInfo])] {
        Dictionary(grouping: tables, by: \.family).map { ($0.key, $0.value) }.sorted { $0.family < $1.family }
    }
}

private struct TableRow: View {
    let table: TableInfo
    let workspace: WorkspaceModel

    var body: some View {
        let classification = table.classification
        HStack(spacing: 6) {
            FamilyIcon(family: classification.family)
            Text(table.name).lineLimit(1).truncationMode(.middle)
            EngineBadge(classification: classification)
            Spacer(minLength: 4)
            if let rows = table.totalRows, rows > 0 {
                Text(rows.formatted(.number.notation(.compactName))).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .help(help)
        .contextMenu {
            Button("Open") { workspace.openObject(table) }
            if table.family != .dictionary {
                Button("Query in New Tab") {
                    workspace.openSQL(text: "SELECT *\nFROM \(table.qualifiedName)\nLIMIT 100", database: table.database, run: true)
                }
            }
            if table.family.hasParts {
                Button("Partitions & Parts") { workspace.openObject(table, section: .parts) }
                Button("Mutations & Merges") { workspace.openObject(table, section: .mutations) }
            }
            if classification.isReplicated { Button("Replication") { workspace.openObject(table, section: .replication) } }
            Button("DDL") { workspace.openObject(table, section: .ddl) }
            Divider()
            Button("Copy Name") { Pasteboard.copy(table.name) }
            Button("Copy Qualified Name") { Pasteboard.copy(table.qualifiedName) }
        }
    }

    private var help: String {
        var parts = [table.engine]
        if let bytes = table.totalBytes, bytes > 0 { parts.append(Format.bytes(bytes)) }
        if let comment = table.comment, !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " · ")
    }
}
