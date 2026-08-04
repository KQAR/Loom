// Reproducer for the ThreadSanitizer report that intermittently reddens Loom's
// `Thread Sanitizer (ProxyCore)` job. Ten lines, no SwiftNIO, no Loom: a raw
// continuation resumed from another thread, which is what every `EventLoopFuture.get()`
// does internally.
//
// It exists for the same reason `Tools/h2-stall-repro/` does — to make "this is not
// Loom's code" checkable instead of asserted. Same shape as the upstream report,
// swiftlang/swift#57803 (SR-15498), which was closed in 2023 as no longer
// reproducing; the sighting here is on macOS 26 with the current toolchain.
//
//   swiftc -parse-as-library -sanitize=thread main.swift -o repro && ./repro
//
// A run that prints nothing but the tail line saw no race; TSan prints its own report
// to stderr when it does. Raise `rounds` if a run comes back quiet — the report is
// probabilistic, which is exactly why it reads as a flaky CI job rather than a bug.
import Dispatch

@main
struct Repro {
    static let rounds = 100_000

    static func main() async {
        for _ in 0 ..< rounds {
            let value = await resumedFromAnotherThread()
            precondition(value)
        }
        print("completed \(rounds) continuation round-trips")
    }

    /// The write TSan flags happens in this function's suspend/resume glue; the read it
    /// pairs it with happens inside `resume`, on the global queue's thread.
    static func resumedFromAnotherThread() async -> Bool {
        await withUnsafeContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: true) }
        }
    }
}
