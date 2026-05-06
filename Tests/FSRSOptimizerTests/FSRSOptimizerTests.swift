import FSRS
import Foundation
import Testing
@testable import FSRSOptimizer

/// Adapter-level tests don't require running the Rust training loop — they
/// exercise the pure-Swift `[ReviewLog] → FsrsItem` conversion.
@Suite struct ReviewHistoryAdapterTests {

    @Test func mapsRatingsAndComputesDeltaT() throws {
        let history: [ReviewLog] = [
            Fixtures.log(rating: .good, on: Fixtures.date(2026, 1, 1)),
            Fixtures.log(rating: .hard, on: Fixtures.date(2026, 1, 4)), // +3
            Fixtures.log(rating: .again, on: Fixtures.date(2026, 1, 5)), // +1
            Fixtures.log(rating: .easy, on: Fixtures.date(2026, 1, 12)), // +7
        ]

        let item = try #require(ReviewHistoryAdapter.item(from: history))
        #expect(item.reviews.count == 4)
        #expect(item.reviews[0].rating == 3) // good
        #expect(item.reviews[0].deltaT == 0) // first review
        #expect(item.reviews[1].rating == 2) // hard
        #expect(item.reviews[1].deltaT == 3)
        #expect(item.reviews[2].rating == 1) // again
        #expect(item.reviews[2].deltaT == 1)
        #expect(item.reviews[3].rating == 4) // easy
        #expect(item.reviews[3].deltaT == 7)
    }

    @Test func dropsManualReviews() throws {
        let history: [ReviewLog] = [
            Fixtures.log(rating: .good, on: Fixtures.date(2026, 1, 1)),
            Fixtures.log(rating: .manual, on: Fixtures.date(2026, 1, 2)),
            Fixtures.log(rating: .easy, on: Fixtures.date(2026, 1, 3)),
        ]
        let item = try #require(ReviewHistoryAdapter.item(from: history))
        #expect(item.reviews.count == 2)
        #expect(item.reviews.allSatisfy { $0.rating != 0 })
        // delta_t for the second non-manual review is measured from the first
        // *non-manual* predecessor, but in our adapter we walk in source order
        // and only update the cursor on rated reviews — so for [good, manual,
        // easy] the easy review should have delta_t == 2 (Jan 3 - Jan 1).
        #expect(item.reviews[1].deltaT == 2)
    }

    @Test func returnsNilForEmptyOrAllManual() {
        #expect(ReviewHistoryAdapter.item(from: []) == nil)
        let manualOnly = [Fixtures.log(rating: .manual, on: Fixtures.date(2026, 1, 1))]
        #expect(ReviewHistoryAdapter.item(from: manualOnly) == nil)
    }

    @Test func clampsNegativeDeltaTToZero() throws {
        // Out-of-order reviews shouldn't produce negative delta_t (which would
        // panic when cast to UInt32). The adapter floors them at 0.
        let history: [ReviewLog] = [
            Fixtures.log(rating: .good, on: Fixtures.date(2026, 1, 5)),
            Fixtures.log(rating: .good, on: Fixtures.date(2026, 1, 1)), // earlier!
        ]
        let item = try #require(ReviewHistoryAdapter.item(from: history))
        #expect(item.reviews[1].deltaT == 0)
    }

    @Test func gmtDayBoundary() throws {
        // Two reviews 23 hours apart that straddle a GMT day boundary should
        // produce delta_t = 1 (matching `Date.dateDiffInDays` in the core
        // module).
        let monday = Fixtures.date(2026, 1, 5, hour: 23) // 2026-01-05 23:00 UTC
        let tuesday = Fixtures.date(2026, 1, 6, hour: 22) // 2026-01-06 22:00 UTC
        let history = [
            Fixtures.log(rating: .good, on: monday),
            Fixtures.log(rating: .good, on: tuesday),
        ]
        let item = try #require(ReviewHistoryAdapter.item(from: history))
        #expect(item.reviews[1].deltaT == 1)
    }

    @Test func skipsHistoriesWithNoRatedReviews() {
        let valid = Fixtures.consistentDailyHistory(ratings: [.good, .good, .good])
        let allManual = [Fixtures.log(rating: .manual, on: Fixtures.date(2026, 1, 1))]
        let items = ReviewHistoryAdapter.items(from: [valid, allManual, []])
        #expect(items.count == 1)
    }
}

/// Smoke tests that exercise the FFI. These need the prebuilt
/// `FSRSRustCore.xcframework` — the whole `FSRSOptimizerTests` target is
/// gated by `FSRS_BUILD_OPTIMIZER=1` in `Package.swift`.
@Suite struct FSRSOptimizerSmokeTests {

    @Test func handleConstructionWithDefaults() throws {
        // Empty weights means "use upstream defaults" — must not throw.
        _ = try FSRSOptimizer()
    }

    @Test func handleConstructionWithExplicitWeights() throws {
        // Use the public defaults from the Rust crate (matches what
        // `FsrsHandle::new(&[])` would pick).
        let defaults = FSRSOptimizer.defaultParameters()
        _ = try FSRSOptimizer(weights: defaults)
    }

    @Test func tinyDatasetReturnsDefaultsLengthVector() throws {
        // Below the crate's internal training threshold — should return the
        // upstream defaults rather than crash. We assert only the shape:
        // 19 (FSRS-5) or 21 (FSRS-6) elements.
        let optimizer = try FSRSOptimizer()
        let history = Fixtures.consistentDailyHistory(ratings: [.good, .good, .good])
        let result = optimizer.computeParameters(histories: [history])
        #expect(result.count == 19 || result.count == 21)
    }

    @Test func trainedWeightsConstructValidFSRSParameters() throws {
        let optimizer = try FSRSOptimizer()
        let history = Fixtures.consistentDailyHistory(ratings: [.good, .good, .good, .good])
        let weights = optimizer.computeParameters(histories: [history])

        // Should construct a usable parameters object that `FSRS()` accepts.
        let params = FSRSParameters(w: weights)
        let fsrs = FSRS(parameters: params)
        // A round-trip through `repeat(card:now:)` must not throw on a fresh
        // card — basic smoke that the trained weights are well-formed.
        let card = Card()
        _ = fsrs.repeat(card: card, now: Fixtures.date(2026, 1, 1))
    }

    @Test func benchmarkReturnsSomeMetrics() throws {
        let optimizer = try FSRSOptimizer()
        let histories = (0..<3).map { _ in
            Fixtures.consistentDailyHistory(ratings: [.good, .good, .hard, .good])
        }
        let metrics = optimizer.benchmark(histories: histories)
        // We don't assert magnitudes — fsrs-rs's benchmark API may evolve. We
        // just want to know the call survived the FFI round-trip.
        #expect(!metrics.contains(where: { $0.isNaN || $0.isInfinite }))
    }

    @Test func memoryStateThrowsOnEmptyHistory() throws {
        let optimizer = try FSRSOptimizer()
        #expect(throws: FSRSOptimizerError.self) {
            _ = try optimizer.memoryState(history: [])
        }
    }

    @Test func memoryStateForShortHistoryProducesPositives() throws {
        let optimizer = try FSRSOptimizer()
        let history = Fixtures.consistentDailyHistory(ratings: [.good, .good, .good])
        let state = try optimizer.memoryState(history: history)
        #expect(state.stability > 0)
        #expect(state.difficulty > 0)
    }

    @Test func memoryStateFromSM2ReasonableRange() throws {
        let optimizer = try FSRSOptimizer()
        let state = try optimizer.memoryStateFromSM2(
            easeFactor: 2.5,
            interval: 5,
            sm2Retention: 0.9
        )
        #expect(state.stability > 0)
        #expect(state.difficulty >= 1 && state.difficulty <= 10)
    }

    @Test func defaultParametersIs19Elements() {
        // The pinned fsrs crate (5.2.0) exposes 19-element FSRS-5 defaults via
        // `default_parameters()`. If the crate moves to 21-element defaults
        // upstream, this test surfaces it.
        #expect(FSRSOptimizer.defaultParameters().count == 19)
    }

    @Test func simulateProducesPerDayArrays() throws {
        let weights = FSRSOptimizer.defaultParameters()
        let result = try FSRSOptimizer.simulate(
            weights: weights,
            desiredRetention: 0.9,
            seed: 42
        )
        let span = FSRSOptimizer.defaultSimulatorConfig().learnSpan
        #expect(result.memorizedCntPerDay.count == Int(span))
        #expect(result.reviewCntPerDay.count == Int(span))
    }
}
