import FSRS
import Foundation

enum Fixtures {
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = d
        components.hour = hour
        components.minute = 0
        return utcCalendar.date(from: components)!
    }

    /// Synthetic review log helper. Defaults the rich fields the optimizer
    /// doesn't read.
    static func log(rating: Rating, on review: Date) -> ReviewLog {
        ReviewLog(
            rating: rating,
            elapsedDays: 0,
            lastElapsedDays: 0,
            scheduledDays: 0,
            learningSteps: 0,
            review: review
        )
    }

    /// One card reviewed daily for `count` days, all `rating`.
    static func consistentDailyHistory(
        ratings: [Rating],
        startDay: Int = 1
    ) -> [ReviewLog] {
        ratings.enumerated().map { offset, rating in
            log(rating: rating, on: date(2026, 1, startDay + offset))
        }
    }
}
