import Foundation

/// Runs an operation with a time limit. On timeout the operation's task is cancelled, which closes
/// any socket it is waiting on (connections close their transport on cancellation).
public enum Deadline {
    public static func run<T: Sendable>(seconds: Double, timeoutError: @escaping @Sendable () -> ClickHouseError,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(Int(min(max(0.05, seconds.isFinite ? seconds : 86_400), 86_400) * 1000)))
                throw timeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw timeoutError() }
            return result
        }
    }
}

/// Whole seconds for messages and integer parameters; never traps (non-finite and huge values are
/// clamped).
public func wholeSeconds(_ value: Double, maximum: Int = 1_000_000_000) -> Int {
    guard value.isFinite, value > 0 else { return 0 }
    return value >= Double(maximum) ? maximum : Int(value.rounded(.up))
}
