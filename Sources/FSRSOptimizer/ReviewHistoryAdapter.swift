import FSRS
import Foundation

/// Converts swift-fsrs `[ReviewLog]` per-card histories into the `(rating, delta_t)`
/// shape that fsrs-rs's training loop consumes.
///
/// `delta_t` is the number of days between consecutive reviews of the same
/// card, measured at GMT day boundaries to match the convention used by
/// `Date.dateDiffInDays` inside the core FSRS module.
enum ReviewHistoryAdapter {
    /// Convert a single card's chronologically-ordered review history into an
    /// `FsrsItem`. Returns `nil` if no non-`.manual` reviews remain after
    /// filtering — fsrs-rs cannot train on an empty card history.
    static func item(from history: [ReviewLog]) -> FsrsItem? {
        var reviews: [FsrsReview] = []
        var previous: Date?

        for log in history {
            guard let rating = log.rating.fsrsRSValue else { continue }
            let deltaT = previous.map { dateDiffInDays(from: $0, to: log.review) } ?? 0
            reviews.append(FsrsReview(rating: rating, deltaT: UInt32(max(0, deltaT))))
            previous = log.review
        }

        guard !reviews.isEmpty else { return nil }
        return FsrsItem(reviews: reviews)
    }

    /// Convert an array of per-card histories into `[FsrsItem]`, dropping
    /// histories that contained no usable reviews.
    static func items(from histories: [[ReviewLog]]) -> [FsrsItem] {
        histories.compactMap(item(from:))
    }

    /// GMT day-boundary diff in whole days. Mirrors `Date.dateDiffInDays`
    /// from the core FSRS module — kept inline here to avoid expanding the
    /// public FSRS API surface.
    private static func dateDiffInDays(from last: Date, to current: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .autoupdatingCurrent
        let startOfLast = calendar.startOfDay(for: last)
        let startOfCur = calendar.startOfDay(for: current)
        let delta = startOfCur.timeIntervalSince1970 - startOfLast.timeIntervalSince1970
        return Int(floor(delta / 86_400))
    }
}
