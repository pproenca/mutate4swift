import Foundation

public struct BaselineResult: Sendable {
    public let duration: TimeInterval
    public let timeoutMultiplier: Double

    public init(duration: TimeInterval, timeoutMultiplier: Double = 10.0) {
        self.duration = duration
        self.timeoutMultiplier = timeoutMultiplier
    }

    /// Computed timeout = duration × multiplier, with a minimum of 30 seconds.
    public var timeout: TimeInterval {
        max(duration * timeoutMultiplier, 30.0)
    }
}
