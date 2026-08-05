// Two genuine data races, on purpose.
//
// `Tools/tsan/suppressions.txt` silences one upstream report shape so the CI job stops
// going red on something that is not Loom's bug. Its single entry is a whole-stack
// `race:` pattern — the breadth that file's own header set out to avoid, kept only
// because `race_top:` was measured not to match the report (run 31011274393). A broad
// pattern that nobody checks is how a gate quietly stops being one.
//
// So the breadth claim is checked here instead of asserted:
//
// - `threads` — two pthread-backed threads racing on a pointer. No async, no
//   continuation, nothing the suppression mentions. The floor: if this stops being
//   reported, the suppressions have gone catastrophically wide.
//
// - `async` — the case the suppression is actually near, and the class of the real bugs
//   found while chasing this flake (#210 teardown running into the next test, #212
//   `stopAll()` mutating the dict it iterates, #213 a leaked event-loop group): Loom-ish
//   code racing on shared state *inside async functions, with continuations resumed
//   cross-thread in the same process*. The safety argument for `race:UnsafeContinuation
//   .resume` is that the frame only appears when the racy access happens inside `resume`
//   itself — a coroutine-frame access — and never when async code races on its own
//   state. That is exactly what this mode tests, and it is the one that would catch the
//   suppression being too broad in the way that matters.
//
// Inverted exit code, deliberately: this program is *expected* to be reported, so the
// workflow step around it fails when TSan stays quiet.
//
//   swiftc -parse-as-library -sanitize=thread main.swift -o canary
//   TSAN_OPTIONS="suppressions=$PWD/Tools/tsan/suppressions.txt" ./canary threads
//   TSAN_OPTIONS="suppressions=$PWD/Tools/tsan/suppressions.txt" ./canary async
//
// Not part of any test target: it would fail the suite it lives in, which is the point.
import Foundation

/// Shared mutable state with no protection whatsoever. `nonisolated(unsafe)` is the
/// honest annotation: this is unsafe, and being unsafe is the payload.
final class Box: @unchecked Sendable {
    var n = 0
}

@main
struct Canary {
    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "threads"
        switch mode {
        case "threads": threadRace()
        case "async": await asyncRace()
        default:
            print("usage: canary [threads|async]")
            exit(2)
        }
        print("canary(\(mode)) finished — TSan should have reported a data race above")
    }

    /// Plain threads on a raw pointer: the report must not involve the concurrency
    /// runtime at all, or a suppression aimed at the runtime's glue could hide it and
    /// this mode would be measuring the wrong thing.
    static func threadRace() {
        let shared = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        shared.initialize(to: 0)

        Thread { for i in 0 ..< 1_000_000 { shared.pointee = i } }.start()
        Thread {
            var seen = 0
            for _ in 0 ..< 1_000_000 { seen &+= shared.pointee }
            if seen == Int.min { print("unreachable") }
        }.start()

        // No join on `Thread`; TSan reports as soon as both accesses have happened.
        Thread.sleep(forTimeInterval: 2)
    }

    /// The case that matters: two async tasks racing on a class property while
    /// continuations are being resumed from other threads all around them. The racing
    /// accesses are performed by *this* code, so `UnsafeContinuation.resume` is not a
    /// frame in either stack and the suppression must not reach it.
    static func asyncRace() async {
        let box = Box()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    for i in 0 ..< 50_000 {
                        // Unsynchronized read-modify-write from four tasks at once.
                        box.n = box.n &+ i
                        // Suspend across a continuation resumed on another thread every
                        // so often, so the process carries the same glue the suppression
                        // targets while this race happens.
                        if i % 5_000 == 0 { await Self.resumedElsewhere() }
                    }
                }
            }
        }
        if box.n == Int.min { print("unreachable") }
    }

    /// A continuation resumed from a different thread — the shape the suppressed
    /// upstream report comes from, present here as background noise rather than as the
    /// thing being tested.
    static func resumedElsewhere() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume() }
        }
    }
}
