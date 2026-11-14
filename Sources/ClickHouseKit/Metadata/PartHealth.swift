import Foundation

/// Part-count assessment (design D14): compares active parts per partition with the table's
/// insert-throttling thresholds and flags tables with many tiny parts or too many partitions.
public enum PartHealth {
    public enum Level: Int, Sendable, Comparable, Hashable {
        case ok, warning, critical, failing
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Warning: Sendable, Hashable {
        public let level: Level
        public let message: String
    }

    /// Level for one partition's active part count.
    public static func level(activeParts: Int64, limits: MergeTreeLimits) -> Level {
        if activeParts >= limits.partsToThrowInsert { return .failing }
        if activeParts >= limits.partsToDelayInsert { return .critical }
        if activeParts * 2 >= limits.partsToDelayInsert { return .warning }
        return .ok
    }

    public static let smallPartBytes: Int64 = 10 * 1024 * 1024
    public static let manyPartitions = 1_000

    /// Table-level warnings, most severe first.
    public static func warnings(partitions: [PartitionSummary], limits: MergeTreeLimits) -> [Warning] {
        var warnings: [Warning] = []
        let worst = partitions.max { $0.activeParts < $1.activeParts }
        if let worst {
            let level = level(activeParts: worst.activeParts, limits: limits)
            let label = worst.isUnpartitioned ? "The table" : "Partition \(worst.partition)"
            switch level {
            case .failing:
                warnings.append(Warning(level: .failing, message: "\(label) has \(worst.activeParts) active parts (≥ parts_to_throw_insert \(limits.partsToThrowInsert)): inserts fail with TOO_MANY_PARTS."))
            case .critical:
                warnings.append(Warning(level: .critical, message: "\(label) has \(worst.activeParts) active parts (≥ parts_to_delay_insert \(limits.partsToDelayInsert)): inserts are being delayed."))
            case .warning:
                warnings.append(Warning(level: .warning, message: "\(label) has \(worst.activeParts) active parts, half of parts_to_delay_insert (\(limits.partsToDelayInsert)). Batch inserts or check merges."))
            case .ok:
                break
            }
        }
        let totalParts = partitions.reduce(Int64(0)) { $0 &+ $1.activeParts }
        if totalParts >= limits.maxPartsInTotal {
            warnings.append(Warning(level: .failing, message: "\(totalParts) active parts in total (≥ max_parts_in_total \(limits.maxPartsInTotal)): inserts fail."))
        } else if totalParts * 2 >= limits.maxPartsInTotal {
            warnings.append(Warning(level: .warning, message: "\(totalParts) active parts in total, half of max_parts_in_total (\(limits.maxPartsInTotal))."))
        }
        let totalBytes = partitions.reduce(Int64(0)) { $0 &+ $1.bytesOnDisk }
        if totalParts > 100, totalBytes / max(1, totalParts) < smallPartBytes {
            warnings.append(Warning(level: .warning, message: "\(totalParts) parts averaging \(totalBytes / max(1, totalParts) / 1024) KB: many small parts (frequent small inserts, or a partition key that is too fine)."))
        }
        if partitions.count > manyPartitions {
            warnings.append(Warning(level: .warning, message: "\(partitions.count) partitions: a partition key this fine slows down queries and merges; prefer coarser partitions (e.g. by month)."))
        }
        return warnings.sorted { $0.level > $1.level }
    }
}
