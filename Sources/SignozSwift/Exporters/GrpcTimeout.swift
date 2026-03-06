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
}
