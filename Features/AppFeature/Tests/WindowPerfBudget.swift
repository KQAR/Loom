import Foundation

@testable import AppFeature

/// The time budget for the two guards that run at the window's full cap.
///
/// Both of them used to say `elapsed < 1.0`, and that second was a property of
/// the **cap** rather than of the code under test: raising `FlowLimits.windowRows`
/// from 20 000 to 99 999 made the linear shape cost five times as much and turned
/// both guards red on CI while the shape they exist to catch was unchanged. A
/// budget that has to be retuned every time the cap moves is a budget that will
/// be retuned upward without anyone checking what it still guards.
///
/// So it is stated **per row** and the absolute figure follows the cap. That
/// keeps both guards honest, because the failures they were written against are
/// **quadratic** rather than merely slower: filling the window one flow at a time
/// through observed state measured 14 s at 20 000 rows, which is ~350 s here, and
/// per-row needle work grows with the window as well as with the keystrokes.
///
/// One number for both, because the old flat second happened to be the same
/// per-row allowance for each: filling the window once and rebuilding the
/// projection five times are different amounts of work, and neither is close to
/// this ceiling — the point is the order, not the constant.
enum WindowPerf {
    /// 50 µs per row, against a measured ~4.5 µs on the linear path (90 ms to
    /// fill 20 000 rows). Deliberately ~10× loose: this must not fail because CI
    /// is busy, only because the shape came back.
    static let perRowSeconds: TimeInterval = 50e-6

    /// The budget at the current cap — 5.0 s at 99 999 rows.
    static var fullWindowBudget: TimeInterval {
        Double(CaptureFeature.State.displayCap) * perRowSeconds
    }
}
