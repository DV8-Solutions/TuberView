import Foundation

/// How long to wait before trying a stream again.
public enum Backoff {
    /// 1, 2, 4, 8, 15, 30, 30, … seconds. Attempts count from 1.
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: return 1
        case 2: return 2
        case 3: return 4
        case 4: return 8
        case 5: return 15
        default: return 30
        }
    }
}

/// Decides whether a stream has stopped moving.
///
/// A stream is alive while any of its counters changes: the clock, the bytes
/// read from the network, or the pictures shown. A connection that died while
/// the Mac slept keeps reporting "playing" forever, which is why the state
/// alone is not trusted.
public struct StallDetector: Equatable {
    public private(set) var lastSignature: [Int] = []
    public private(set) var lastProgress: TimeInterval
    public private(set) var hasPlayed = false

    public init(now: TimeInterval) {
        self.lastProgress = now
    }

    /// Feed the current counters. Returns how long nothing has changed.
    public mutating func observe(signature: [Int], playing: Bool, now: TimeInterval) -> TimeInterval {
        if signature != lastSignature {
            // the first reading is a baseline, not progress
            if !lastSignature.isEmpty && playing { hasPlayed = true }
            lastSignature = signature
            lastProgress = now
        }
        return now - lastProgress
    }

    /// Opening a stream is allowed longer than a stream that was already
    /// playing and froze.
    public func limit(openingAllowance: TimeInterval = 25,
                      stallAllowance: TimeInterval = 10) -> TimeInterval {
        hasPlayed ? stallAllowance : openingAllowance
    }
}
