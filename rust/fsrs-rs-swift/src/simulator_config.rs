//! Mirror of `fsrs::SimulatorConfig` exposed across the FFI boundary.
//!
//! The upstream `fsrs::SimulatorConfig` carries closures (`post_scheduling_fn`,
//! `review_priority_fn`) that can't cross the FFI boundary, plus fixed-size
//! 2D arrays that `uniffi::Record` can't represent directly. We surface a
//! parallel struct that uses `Vec<Vec<f32>>` for the matrices and drops the
//! closure fields, then reconstruct the upstream type field-by-field.
//!
//! Field names tracked against `fsrs = 5.2.0`. Bump deliberately.

#[derive(uniffi::Record, Debug, Clone)]
pub struct SimulatorConfig {
    pub deck_size: u64,
    pub learn_span: u64,
    pub max_cost_perday: f32,
    pub max_ivl: f32,
    /// Probability of giving each rating to a brand-new card.
    /// Must be exactly 4 elements: \[Again, Hard, Good, Easy\].
    pub first_rating_prob: Vec<f32>,
    /// Probability of giving each rating on a successful recall.
    /// Must be exactly 3 elements: \[Hard, Good, Easy\].
    pub review_rating_prob: Vec<f32>,
    pub learn_limit: u64,
    pub review_limit: u64,
    pub new_cards_ignore_review_limit: bool,
    pub suspend_after_lapses: Option<u32>,
    /// 3 rows × 4 cols.
    pub learning_step_transitions: Vec<Vec<f32>>,
    /// 3 rows × 4 cols.
    pub relearning_step_transitions: Vec<Vec<f32>>,
    /// 3 rows × 4 cols.
    pub state_rating_costs: Vec<Vec<f32>>,
    pub learning_step_count: u64,
    pub relearning_step_count: u64,
}

impl Default for SimulatorConfig {
    fn default() -> Self {
        let inner = fsrs::SimulatorConfig::default();
        Self::from(inner)
    }
}

impl From<fsrs::SimulatorConfig> for SimulatorConfig {
    fn from(c: fsrs::SimulatorConfig) -> Self {
        SimulatorConfig {
            deck_size: c.deck_size as u64,
            learn_span: c.learn_span as u64,
            max_cost_perday: c.max_cost_perday,
            max_ivl: c.max_ivl,
            first_rating_prob: c.first_rating_prob.to_vec(),
            review_rating_prob: c.review_rating_prob.to_vec(),
            learn_limit: c.learn_limit as u64,
            review_limit: c.review_limit as u64,
            new_cards_ignore_review_limit: c.new_cards_ignore_review_limit,
            suspend_after_lapses: c.suspend_after_lapses,
            learning_step_transitions: c
                .learning_step_transitions
                .iter()
                .map(|row| row.to_vec())
                .collect(),
            relearning_step_transitions: c
                .relearning_step_transitions
                .iter()
                .map(|row| row.to_vec())
                .collect(),
            state_rating_costs: c.state_rating_costs.iter().map(|row| row.to_vec()).collect(),
            learning_step_count: c.learning_step_count as u64,
            relearning_step_count: c.relearning_step_count as u64,
        }
    }
}

impl SimulatorConfig {
    pub fn into_inner(self) -> fsrs::SimulatorConfig {
        let mut cfg = fsrs::SimulatorConfig::default();
        cfg.deck_size = self.deck_size as usize;
        cfg.learn_span = self.learn_span as usize;
        cfg.max_cost_perday = self.max_cost_perday;
        cfg.max_ivl = self.max_ivl;
        if let Ok(arr) = <[f32; 4]>::try_from(self.first_rating_prob.as_slice()) {
            cfg.first_rating_prob = arr;
        }
        if let Ok(arr) = <[f32; 3]>::try_from(self.review_rating_prob.as_slice()) {
            cfg.review_rating_prob = arr;
        }
        cfg.learn_limit = self.learn_limit as usize;
        cfg.review_limit = self.review_limit as usize;
        cfg.new_cards_ignore_review_limit = self.new_cards_ignore_review_limit;
        cfg.suspend_after_lapses = self.suspend_after_lapses;
        if let Some(matrix) = vec_of_vecs_into_3x4(&self.learning_step_transitions) {
            cfg.learning_step_transitions = matrix;
        }
        if let Some(matrix) = vec_of_vecs_into_3x4(&self.relearning_step_transitions) {
            cfg.relearning_step_transitions = matrix;
        }
        if let Some(matrix) = vec_of_vecs_into_3x4(&self.state_rating_costs) {
            cfg.state_rating_costs = matrix;
        }
        cfg.learning_step_count = self.learning_step_count as usize;
        cfg.relearning_step_count = self.relearning_step_count as usize;
        cfg
    }
}

fn vec_of_vecs_into_3x4(v: &[Vec<f32>]) -> Option<[[f32; 4]; 3]> {
    if v.len() != 3 {
        return None;
    }
    let mut out = [[0.0_f32; 4]; 3];
    for (i, row) in v.iter().enumerate() {
        if row.len() != 4 {
            return None;
        }
        out[i].copy_from_slice(row);
    }
    Some(out)
}
