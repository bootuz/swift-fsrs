import FSRS
import Foundation

/// Errors specific to the optimizer adapter layer.
///
/// Failures originating in the underlying Rust crate surface as `FsrsError`
/// (the uniffi-generated typed error) and propagate directly — they're
/// already a public `Sendable Error` type. `FSRSOptimizerError` only adds
/// adapter-level cases that aren't expressible at the FFI boundary.
public enum FSRSOptimizerError: Error, Sendable {
    /// `memoryState(history:)` was called with a history containing no
    /// non-`.manual` reviews.
    case emptyHistory
}

/// Public entry point for FSRS parameter optimization, memory-state replay,
/// benchmarking, and workload simulation. Wraps the `fsrs` Rust crate via
/// uniffi-rs bindings shipped in the `FSRSRustCore.xcframework` binary target.
public final class FSRSOptimizer: @unchecked Sendable {
    private let handle: FsrsHandle

    /// Create an optimizer.
    ///
    /// - Parameter weights: Initial FSRS weight vector. Pass `nil` (default)
    ///   to use the upstream defaults (19-element FSRS-5 weights at the time
    ///   of writing). To opt into FSRS-6, pass `FSRSDefaults.defaultWv6`.
    /// - Throws: `FsrsError.invalidInput` if the supplied weights aren't
    ///   accepted by the underlying crate.
    public init(weights: [Double]? = nil) throws {
        let floats = (weights ?? []).map(Float.init)
        self.handle = try FsrsHandle(parameters: floats)
    }

    /// Train an optimized weight vector from per-card review histories.
    ///
    /// - Parameter histories: One inner array per card, sorted chronologically
    ///   (oldest review first). `.manual` ratings are filtered out before
    ///   training. Histories that become empty after filtering are skipped.
    /// - Returns: Optimized weights ready to feed into `FSRSParameters(w:)`.
    ///   The vector length matches what the pinned `fsrs` crate produces
    ///   (19 for v5, 21 for v6); swift-fsrs's `FSRSAlgorithmVersion` dispatch
    ///   handles either.
    ///
    /// If the dataset is below the crate's internal minimum size, the
    /// upstream defaults are returned unchanged (matches fsrs-rs's
    /// `unwrap_or_default()` behavior).
    public func computeParameters(histories: [[ReviewLog]]) -> [Double] {
        let items = ReviewHistoryAdapter.items(from: histories)
        return handle.computeParameters(trainSet: items).map(Double.init)
    }

    /// Report training-loss / fit metrics for the given history under the
    /// optimizer's current weights. Useful for showing users the improvement
    /// between defaults and trained weights.
    public func benchmark(histories: [[ReviewLog]]) -> [Double] {
        let items = ReviewHistoryAdapter.items(from: histories)
        return handle.benchmark(trainSet: items).map(Double.init)
    }

    /// Replay a card's review history to derive its current memory state
    /// without running the full scheduler. Useful when migrating an existing
    /// review history into a fresh `Card`.
    ///
    /// - Throws: `FSRSOptimizerError.emptyHistory` if no non-`.manual`
    ///   reviews remain after filtering. `FsrsError` for failures inside the
    ///   underlying crate.
    public func memoryState(
        history: [ReviewLog],
        startingState: FSRSState? = nil
    ) throws -> FSRSState {
        guard let item = ReviewHistoryAdapter.item(from: history) else {
            throw FSRSOptimizerError.emptyHistory
        }
        let starting = startingState.map {
            MemoryState(stability: Float($0.stability), difficulty: Float($0.difficulty))
        }
        let result = try handle.memoryState(item: item, startingState: starting)
        return FSRSState(stability: Double(result.stability), difficulty: Double(result.difficulty))
    }

    /// Convert an SM-2-style `(easeFactor, interval, retention)` triple into
    /// an FSRS memory state. Mirrors `fsrs::memory_state_from_sm2`.
    public func memoryStateFromSM2(
        easeFactor: Double,
        interval: Double,
        sm2Retention: Double
    ) throws -> FSRSState {
        let result = try handle.memoryStateFromSm2(
            easeFactor: Float(easeFactor),
            interval: Float(interval),
            sm2Retention: Float(sm2Retention)
        )
        return FSRSState(stability: Double(result.stability), difficulty: Double(result.difficulty))
    }

    /// Run fsrs-rs's per-day workload simulation. Use this to build a
    /// retention search loop (the equivalent of py-fsrs's
    /// `compute_optimal_retention`) over candidate retention levels.
    public static func simulate(
        weights: [Double],
        desiredRetention: Double,
        config: SimulatorConfig? = nil,
        seed: UInt64? = nil
    ) throws -> SimulationResult {
        try fsrsSimulate(
            weights: weights.map(Float.init),
            desiredRetention: Float(desiredRetention),
            config: config,
            seed: seed
        )
    }

    /// fsrs-rs's recommended default `SimulatorConfig`. Useful as a base to
    /// override individual fields.
    public static func defaultSimulatorConfig() -> SimulatorConfig {
        fsrsDefaultSimulatorConfig()
    }

    /// fsrs-rs's default 19-element FSRS-5 weights, exposed for callers who
    /// want to compare trained output against the upstream baseline.
    public static func defaultParameters() -> [Double] {
        fsrsDefaultParameters().map(Double.init)
    }
}
