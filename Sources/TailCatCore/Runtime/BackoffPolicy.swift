import Foundation

/// Exponential restart backoff: base, 2·base, 4·base … capped. A run that lasted at least
/// `stableAfter` seconds counts as healthy and resets the attempt counter.
public struct BackoffPolicy: Equatable, Sendable {
    public var base: TimeInterval
    public var cap: TimeInterval
    public var stableAfter: TimeInterval

    public init(base: TimeInterval = 1, cap: TimeInterval = 60, stableAfter: TimeInterval = 60) {
        self.base = base
        self.cap = cap
        self.stableAfter = stableAfter
    }

    /// `attempt` is 1-based.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 30)
        return min(cap, base * Double(1 << exponent))
    }
}
