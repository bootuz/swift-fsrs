A Swift implementation of FSRS-6.0 (FSRS-5.0 supported via 19-length `w`).

[![codecov](https://codecov.io/gh/open-spaced-repetition/swift-fsrs/graph/badge.svg?token=K2C0Z5PFEH)](https://codecov.io/gh/open-spaced-repetition/swift-fsrs)

```swift
import FSRS

// v5 (default — 19-length w):
let v5 = FSRS(parameters: .init())

// v6 — pass a 21-length w (e.g. the canonical default):
let v6 = FSRS(parameters: .init(w: FSRSDefaults.defaultWv6))

let card = FSRSDefaults().createEmptyCard()
let next = try v6.next(card: card, now: Date(), grade: .good).card
```

## Optional: `FSRSOptimizer` (Rust-backed weight optimizer)

A separate `FSRSOptimizer` library wraps the [`fsrs`](https://crates.io/crates/fsrs)
Rust crate (the optimizer Anki ships) via [uniffi-rs](https://github.com/mozilla/uniffi-rs)
and is distributed as a prebuilt `FSRSRustCore.xcframework`. It exposes:

- `computeParameters(histories:)` — train optimized FSRS weights from per-card review histories.
- `benchmark(histories:)` — report fit metrics for a given history under the current weights.
- `memoryState(history:)` / `memoryStateFromSM2(...)` — replay a card's history to derive `(stability, difficulty)`.
- `simulate(weights:desiredRetention:config:seed:)` — fsrs-rs's per-day workload simulator (use it to build a retention search loop).

```swift
import FSRS
import FSRSOptimizer

// Group your stored reviews by card, chronologically:
let histories: [[ReviewLog]] = …

let optimizer = try FSRSOptimizer()
let trained = optimizer.computeParameters(histories: histories)

let tunedFSRS = FSRS(parameters: .init(w: trained))
```

### Optional FSRSOptimizer target

`FSRSOptimizer` wraps the [`fsrs`](https://crates.io/crates/fsrs) Rust crate
(the optimizer Anki ships) via a uniffi-generated Swift binding, distributed
as `FSRSRustCore.xcframework`. It is **opt-in**: `Package.swift` only declares
the `FSRSOptimizer` library/target when the env var `FSRS_BUILD_OPTIMIZER=1`
is set. Without that flag, the package builds exactly as before.

```sh
# Build the xcframework (requires `rustup` + Xcode):
./scripts/build-xcframework.sh

# Build & test the optimizer target:
FSRS_BUILD_OPTIMIZER=1 swift build
FSRS_BUILD_OPTIMIZER=1 swift test --filter FSRSOptimizerTests
```

The build script:
1. Compiles `rust/fsrs-rs-swift` to static libs for macOS arm64+x86_64,
   iOS device arm64, and iOS sim arm64+x86_64.
2. Runs `cargo run --bin uniffi-bindgen -- generate ... --language swift`
   to emit the Swift wrapper + C header.
3. Vendors the generated `fsrs_rs_swift.swift` into
   `Sources/FSRSOptimizer/Generated/` (gitignored — regenerated on each
   build, so the Swift glue and the binary slice stay in lockstep).
4. Assembles `build/FSRSRustCore.xcframework`, which the `binaryTarget` in
   `Package.swift` consumes via `path:`. Tagged releases (`optimizer-v*`)
   produce a checksum'd zip uploaded to GitHub Releases — at that point the
   maintainer flips `binaryTarget(path:)` to `binaryTarget(url:checksum:)`.
