import CcinnClickHouseKit
import ClickHouseKit
import SwiftUI

/// Clusters → shards → replicas, Keeper connection, macros and recent ON CLUSTER tasks.
struct ClusterView: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.cluster, retry: { model.refresh() }) { snapshot in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        keeperCard(snapshot.keeper)
                        if !snapshot.macros.isEmpty {
                            Card(title: "Macros", systemImage: "curlybraces") {
                                KeyValueList(items: snapshot.macros.map { ($0.name, $0.value) }, monospacedValues: true)
                            }
                        }
                    }
                    let clusters = Dictionary(grouping: snapshot.replicas, by: \.cluster).sorted { lhs, rhs in
                        // The configured cluster first, then by name.
                        if (lhs.key == model.workspace.cluster) != (rhs.key == model.workspace.cluster) { return lhs.key == model.workspace.cluster }
                        return lhs.key < rhs.key
                    }
                    if clusters.isEmpty {
                        NoticeBanner(message: "This server defines no clusters (single node).")
                    }
                    ForEach(clusters, id: \.key) { cluster, replicas in
                        ClusterCard(name: cluster, replicas: replicas, isConfigured: cluster == model.workspace.cluster)
                    }
                    if !snapshot.ddl.isEmpty {
                        Card(title: "Recent ON CLUSTER tasks", systemImage: "list.bullet.clipboard") {
                            ForEach(snapshot.ddl.prefix(30)) { entry in
                                HStack(alignment: .top) {
                                    StateBadge(state: entry.status ?? "—")
                                    Text(entry.host ?? "").foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                                    Text(entry.query).font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled)
                                    Spacer()
                                    if let code = entry.exceptionCode { Badge(text: "code \(code)", color: .red) }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func keeperCard(_ keeper: KeeperStatus) -> some View {
        Card(title: "Keeper / ZooKeeper", systemImage: "key.horizontal") {
            switch keeper.state {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                KeyValueList(items: [("Host", [keeper.host, keeper.port.map(String.init)].compactMap { $0 }.joined(separator: ":")),
                                     ("Session uptime", Format.duration(seconds: keeper.sessionUptimeSeconds.map(Double.init))),
                                     ("API version", keeper.apiVersion.map(String.init) ?? "—")].filter { !$0.1.isEmpty })
            case .notConfigured:
                Label("Not configured (no replicated tables or ON CLUSTER DDL)", systemImage: "minus.circle").foregroundStyle(.secondary)
            case let .unavailable(message):
                ErrorBanner(message: message)
            }
        }
    }
}

private struct ClusterCard: View {
    let name: String
    let replicas: [ClusterReplica]
    let isConfigured: Bool

    var body: some View {
        let shards = Dictionary(grouping: replicas, by: \.shardNumber).sorted { $0.key < $1.key }
        Card(title: name, systemImage: "server.rack") {
            HStack(spacing: 8) {
                Badge(text: "\(shards.count) shard\(shards.count == 1 ? "" : "s")", color: .indigo)
                Badge(text: "\(replicas.count) replica\(replicas.count == 1 ? "" : "s")", color: .teal)
                if isConfigured { Badge(text: "Used by this connection", color: Theme.accent) }
            }
            ForEach(shards, id: \.key) { shard, members in
                HStack(alignment: .top, spacing: 10) {
                    Text("Shard \(shard)").font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(members) { replica in
                            HStack(spacing: 8) {
                                Circle().fill(replica.errorsCount > 0 ? Color.orange : Color.green).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(replica.hostName + ":" + String(replica.port)).font(Theme.monospacedSmall)
                                    Text("replica \(replica.replicaNumber)\(replica.errorsCount > 0 ? " · \(replica.errorsCount) errors" : "")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if replica.isLocal { Badge(text: "local", color: Theme.accent) }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
                        }
                    }
                }
            }
        }
    }
}
