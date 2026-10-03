//! Decides whether a `CursorMoved` event in `/s` mode is the user actually
//! moving the mouse, or just the OS reporting where the cursor already was.
//!
//! A fixed startup grace period alone isn't enough: window creation fires a
//! synthetic `CursorMoved` at the cursor's current position, and on macOS
//! those can arrive *after* the grace window — verified on macOS 26, where
//! `/s` quit on its own 0.8–1.3s after launch in 2 of 5 runs with nobody
//! touching the machine. A real move changes the position; a stale report
//! doesn't, so the guard latches the first position each window sees and
//! only counts motion that travels past a small threshold from it.
//!
//! Pure and side-effect-free (no winit types) so it's unit-testable on any
//! host, the same split as `screensaver_args.rs`.

/// How far, in physical pixels, the cursor must travel from where a window
/// first saw it before that counts as the user moving the mouse. Small
/// enough that any deliberate nudge exits, large enough to absorb sub-pixel
/// jitter and a HiDPI rounding step.
pub const MOVE_THRESHOLD_PX: f64 = 10.0;

/// Tracks one window's cursor anchor. Each screensaver window gets its own,
/// since `CursorMoved` positions are relative to the window reporting them.
#[derive(Debug, Clone, Default)]
pub struct CursorExitGuard {
    anchor: Option<(f64, f64)>,
}

impl CursorExitGuard {
    /// Feeds one `CursorMoved` position. Returns `true` when it's real user
    /// motion (moved more than [`MOVE_THRESHOLD_PX`] from the anchor). The
    /// first position a window ever reports only sets the anchor and never
    /// counts — that's the OS describing where the cursor already sits.
    pub fn is_real_motion(&mut self, x: f64, y: f64) -> bool {
        match self.anchor {
            None => {
                self.anchor = Some((x, y));
                false
            }
            Some((ax, ay)) => {
                let (dx, dy) = (x - ax, y - ay);
                (dx * dx + dy * dy).sqrt() > MOVE_THRESHOLD_PX
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_report_only_sets_the_anchor() {
        let mut guard = CursorExitGuard::default();
        assert!(!guard.is_real_motion(500.0, 300.0));
    }

    #[test]
    fn repeated_reports_at_the_same_spot_never_count() {
        // The bug this exists for: late synthetic events at an unmoved cursor.
        let mut guard = CursorExitGuard::default();
        for _ in 0..50 {
            assert!(!guard.is_real_motion(500.0, 300.0));
        }
    }

    #[test]
    fn jitter_within_the_threshold_does_not_count() {
        let mut guard = CursorExitGuard::default();
        guard.is_real_motion(500.0, 300.0);
        assert!(!guard.is_real_motion(507.0, 304.0)); // ~8.1px
        assert!(!guard.is_real_motion(493.0, 296.0)); // ~8.1px the other way
    }

    #[test]
    fn a_real_move_past_the_threshold_counts() {
        let mut guard = CursorExitGuard::default();
        guard.is_real_motion(500.0, 300.0);
        assert!(guard.is_real_motion(500.0, 311.0)); // 11px straight down
    }

    #[test]
    fn distance_is_measured_from_the_anchor_not_the_last_report() {
        // Creeping in steps under the threshold still adds up to real motion.
        let mut guard = CursorExitGuard::default();
        guard.is_real_motion(0.0, 0.0);
        assert!(!guard.is_real_motion(6.0, 0.0));
        assert!(guard.is_real_motion(12.0, 0.0));
    }

    #[test]
    fn exactly_at_the_threshold_does_not_count() {
        let mut guard = CursorExitGuard::default();
        guard.is_real_motion(0.0, 0.0);
        assert!(!guard.is_real_motion(MOVE_THRESHOLD_PX, 0.0));
    }

    #[test]
    fn each_guard_tracks_its_own_anchor() {
        // Two windows (two monitors) report positions in their own spaces.
        let mut left = CursorExitGuard::default();
        let mut right = CursorExitGuard::default();
        left.is_real_motion(100.0, 100.0);
        assert!(!right.is_real_motion(1800.0, 900.0));
        assert!(!left.is_real_motion(100.0, 100.0));
    }
}
