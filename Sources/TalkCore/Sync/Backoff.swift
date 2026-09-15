import Foundation

/// Exponential backoff with jitter, used by every retry loop in the app.
///
/// Jitter matters more than it looks: without it, a server coming back from maintenance
/// gets every client in the world reconnecting on the same second.
struct Backoff: Sendable, Equatable {
    var base: TimeInterval = 1
    var maximum: TimeInterval = 60
    var multiplier: Double = 2
    /// Fraction of the delay that is randomized, e.g. 0.2 means ±20%.
    var jitter: Double = 0.2

    static let networkRetry = Backoff(base: 1, maximum: 60)
    /// The long poll reconnects quickly — a dropped poll is normal, not an outage.
    static let longPoll = Backoff(base: 0.5, maximum: 30)

    /// - Parameter attempt: 1 for the first retry.
    func delay(forAttempt attempt: Int, random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponential = base * pow(multiplier, Double(attempt - 1))
        let capped = min(exponential, maximum)
        guard jitter > 0 else { return capped }
        let spread = capped * jitter
        return max(0, capped + random(-spread...spread))
    }

    /// The delay to actually use, honouring anything the server told us.
    ///
    /// The server's suggestion is honoured, not obeyed: `Retry-After` is a number a hostile
    /// or broken server picks, and taking it literally means a `0` spins this loop as fast
    /// as the socket allows and a `999999999` parks sync for thirty years. It is clamped
    /// into the same range our own schedule lives in, which is what ``maximum`` was always
    /// documented to be.
    func delay(forAttempt attempt: Int, after error: TalkError) -> TimeInterval {
        if let suggested = error.suggestedRetryDelay {
            guard suggested.isFinite else { return maximum }
            return min(max(suggested, base), maximum)
        }
        return delay(forAttempt: attempt)
    }
}
