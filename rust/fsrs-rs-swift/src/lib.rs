//! Swift bindings for the `fsrs` crate.
//!
//! Mirrors the surface that `fsrs-rs-python` exposes (PyO3) but uses uniffi-rs
//! proc-macros instead, producing an Apple `.xcframework` that swift-fsrs's
//! `FSRSOptimizer` target consumes via `binaryTarget`.

use std::panic::{self, AssertUnwindSafe};
use std::sync::Mutex;

use fsrs::ComputeParametersInput;

const DEFAULT_PARAMETERS: [f32; 19] = [
    0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192, 1.01925,
    1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
];

mod simulator_config;
use simulator_config::SimulatorConfig;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FsrsError {
    #[error("training failed: {message}")]
    TrainingFailed { message: String },
    #[error("invalid input: {message}")]
    InvalidInput { message: String },
}

impl From<fsrs::FSRSError> for FsrsError {
    fn from(e: fsrs::FSRSError) -> Self {
        FsrsError::TrainingFailed {
            message: format!("{e:?}"),
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy)]
pub struct MemoryState {
    pub stability: f32,
    pub difficulty: f32,
}

impl From<fsrs::MemoryState> for MemoryState {
    fn from(s: fsrs::MemoryState) -> Self {
        Self {
            stability: s.stability,
            difficulty: s.difficulty,
        }
    }
}

impl From<MemoryState> for fsrs::MemoryState {
    fn from(s: MemoryState) -> Self {
        Self {
            stability: s.stability,
            difficulty: s.difficulty,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy)]
pub struct FsrsReview {
    /// 1=Again, 2=Hard, 3=Good, 4=Easy. Same encoding as swift-fsrs `Rating`.
    pub rating: u32,
    /// Days elapsed since the previous review for this card. 0 for the first review.
    pub delta_t: u32,
}

impl From<FsrsReview> for fsrs::FSRSReview {
    fn from(r: FsrsReview) -> Self {
        fsrs::FSRSReview {
            rating: r.rating,
            delta_t: r.delta_t,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FsrsItem {
    pub reviews: Vec<FsrsReview>,
}

impl From<FsrsItem> for fsrs::FSRSItem {
    fn from(item: FsrsItem) -> Self {
        fsrs::FSRSItem {
            reviews: item.reviews.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy)]
pub struct ItemState {
    pub memory: MemoryState,
    pub interval: f32,
}

impl From<fsrs::ItemState> for ItemState {
    fn from(s: fsrs::ItemState) -> Self {
        Self {
            memory: s.memory.into(),
            interval: s.interval,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy)]
pub struct NextStates {
    pub again: ItemState,
    pub hard: ItemState,
    pub good: ItemState,
    pub easy: ItemState,
}

impl From<fsrs::NextStates> for NextStates {
    fn from(s: fsrs::NextStates) -> Self {
        Self {
            again: s.again.into(),
            hard: s.hard.into(),
            good: s.good.into(),
            easy: s.easy.into(),
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct SimulationResult {
    pub memorized_cnt_per_day: Vec<f32>,
    pub review_cnt_per_day: Vec<u64>,
    pub learn_cnt_per_day: Vec<u64>,
    pub cost_per_day: Vec<f32>,
    pub correct_cnt_per_day: Vec<u64>,
}

impl From<fsrs::SimulationResult> for SimulationResult {
    fn from(s: fsrs::SimulationResult) -> Self {
        Self {
            memorized_cnt_per_day: s.memorized_cnt_per_day,
            review_cnt_per_day: s.review_cnt_per_day.into_iter().map(|v| v as u64).collect(),
            learn_cnt_per_day: s.learn_cnt_per_day.into_iter().map(|v| v as u64).collect(),
            cost_per_day: s.cost_per_day,
            correct_cnt_per_day: s.correct_cnt_per_day.into_iter().map(|v| v as u64).collect(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct FsrsHandle {
    inner: Mutex<fsrs::FSRS>,
}

#[uniffi::export]
impl FsrsHandle {
    #[uniffi::constructor]
    pub fn new(parameters: Vec<f32>) -> Result<std::sync::Arc<Self>, FsrsError> {
        // `fsrs::FSRS::new(None)` produces a parameter-less instance that
        // panics on `memory_state` and similar scheduling APIs ("command
        // requires parameters to be set on creation"). Substitute the
        // upstream defaults when the caller passes an empty vector so the
        // resulting handle is fully usable.
        let resolved: Vec<f32> = if parameters.is_empty() {
            DEFAULT_PARAMETERS.to_vec()
        } else {
            parameters
        };
        let inner =
            fsrs::FSRS::new(Some(&resolved)).map_err(|e| FsrsError::InvalidInput {
                message: format!("{e:?}"),
            })?;
        Ok(std::sync::Arc::new(Self {
            inner: Mutex::new(inner),
        }))
    }

    pub fn compute_parameters(&self, train_set: Vec<FsrsItem>) -> Vec<f32> {
        // The upstream training loop calls `.unwrap()` on internal operations
        // when the dataset is too small (e.g. `NotEnoughData`). uniffi
        // converts those panics into Swift fatal errors, which is hostile to
        // a "fall back to defaults" UX. Catch and degrade.
        let input = ComputeParametersInput {
            train_set: train_set.into_iter().map(Into::into).collect(),
            progress: None,
            enable_short_term: true,
            num_relearning_steps: None,
        };
        let result = panic::catch_unwind(AssertUnwindSafe(|| {
            self.inner
                .lock()
                .expect("FSRS handle poisoned")
                .compute_parameters(input)
        }));
        match result {
            Ok(Ok(weights)) => weights,
            _ => DEFAULT_PARAMETERS.to_vec(),
        }
    }

    pub fn benchmark(&self, train_set: Vec<FsrsItem>) -> Vec<f32> {
        let input = ComputeParametersInput {
            train_set: train_set.into_iter().map(Into::into).collect(),
            progress: None,
            enable_short_term: true,
            num_relearning_steps: None,
        };
        let result = panic::catch_unwind(AssertUnwindSafe(|| {
            self.inner
                .lock()
                .expect("FSRS handle poisoned")
                .benchmark(input)
        }));
        result.unwrap_or_default()
    }

    pub fn next_states(
        &self,
        current_memory_state: Option<MemoryState>,
        desired_retention: f32,
        days_elapsed: u32,
    ) -> Result<NextStates, FsrsError> {
        Ok(self
            .inner
            .lock()
            .expect("FSRS handle poisoned")
            .next_states(
                current_memory_state.map(Into::into),
                desired_retention,
                days_elapsed,
            )?
            .into())
    }

    pub fn memory_state(
        &self,
        item: FsrsItem,
        starting_state: Option<MemoryState>,
    ) -> Result<MemoryState, FsrsError> {
        Ok(self
            .inner
            .lock()
            .expect("FSRS handle poisoned")
            .memory_state(item.into(), starting_state.map(Into::into))?
            .into())
    }

    pub fn memory_state_from_sm2(
        &self,
        ease_factor: f32,
        interval: f32,
        sm2_retention: f32,
    ) -> Result<MemoryState, FsrsError> {
        Ok(self
            .inner
            .lock()
            .expect("FSRS handle poisoned")
            .memory_state_from_sm2(ease_factor, interval, sm2_retention)?
            .into())
    }
}

// Names are prefixed with `fsrs_` so the uniffi-generated Swift free functions
// don't collide with method names on the Swift `FSRSOptimizer` class wrapper.
#[uniffi::export]
pub fn fsrs_simulate(
    weights: Vec<f32>,
    desired_retention: f32,
    config: Option<SimulatorConfig>,
    seed: Option<u64>,
) -> Result<SimulationResult, FsrsError> {
    let cfg = config.unwrap_or_default();
    let result = fsrs::simulate(&cfg.into_inner(), &weights, desired_retention, seed, None)
        .map_err(|e| FsrsError::TrainingFailed {
            message: format!("{e:?}"),
        })?;
    Ok(result.into())
}

#[uniffi::export]
pub fn fsrs_default_simulator_config() -> SimulatorConfig {
    SimulatorConfig::default()
}

#[uniffi::export]
pub fn fsrs_default_parameters() -> Vec<f32> {
    DEFAULT_PARAMETERS.to_vec()
}
