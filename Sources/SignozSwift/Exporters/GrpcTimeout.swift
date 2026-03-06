import Foundation

enum GrpcTimeout {
    static func duration(from timeout: TimeInterval) -> Duration {
        guard timeout.isFinite else {
            return timeout.sign == .minus ? .nanoseconds(0) : .seconds(Int64.max)
        }

        guard timeout > 0 else {
            return .nanoseconds(0)
        }

        let nanoseconds = timeout * 1_000_000_000
        if nanoseconds >= Double(Int64.max) {
            return .seconds(Int64.max)
        }

        // Round up so small positive values don't collapse to an immediate timeout.
        let roundedNanoseconds = max(Int64(1), Int64(nanoseconds.rounded(.up)))
        return .nanoseconds(roundedNanoseconds)
    }

    static func deadline(from timeout: TimeInterval) -> DispatchTime {
        guard timeout.isFinite else {
            return timeout.sign == .minus ? .now() : .distantFuture
        }

        guard timeout > 0 else {
            return .now()
        }

        let nanoseconds = timeout * 1_000_000_000
        let cappedNanoseconds = min(max(1, nanoseconds.rounded(.up)), Double(Int.max))
        return .now() + .nanoseconds(Int(cappedNanoseconds))
    }
}

private final class GrpcExportResultBox<Result>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result

    init(_ value: Result) {
        self.value = value
    }

    func set(_ newValue: Result) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Result {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum GrpcExportExecutor {
    static func run(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = GrpcExportResultBox(false)
        let task = Task.detached { @Sendable in
            defer { semaphore.signal() }
            do {
                try await operation()
                resultBox.set(true)
            } catch is CancellationError {
                resultBox.set(false)
            } catch {
                resultBox.set(false)
            }
        }

        if semaphore.wait(timeout: GrpcTimeout.deadline(from: timeout)) == .timedOut {
            resultBox.set(false)
            task.cancel()
            return false
        }

        return resultBox.get()
    }
}
