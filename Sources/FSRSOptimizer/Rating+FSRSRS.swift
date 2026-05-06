import FSRS

extension Rating {
    /// fsrs-rs encodes ratings as `u32` 1..4 (Again, Hard, Good, Easy).
    /// `.manual` reviews are not part of the algorithm's training surface
    /// and are dropped before being sent across the FFI boundary.
    var fsrsRSValue: UInt32? {
        guard self != .manual else { return nil }
        return UInt32(rawValue)
    }
}
