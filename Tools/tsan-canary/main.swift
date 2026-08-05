// A genuine data race, on purpose.
//
// `Tools/tsan/suppressions.txt` silences one upstream report shape so the CI job stops
// going red on something that is not Loom's bug. A suppression file is a loaded gun
// pointed at the job's usefulness: widen a pattern by one word and the job passes
// forever while races ship. So the pattern set has to be *checked*, not trusted.
//
// This is the check. Two threads write and read the same `Int` through a pointer, with
// no synchronization of any kind and no continuation, no Dispatch async/await bridge —
// nothing the suppressions mention. Run it under TSan with that file loaded and TSan
// must still report the race. If it doesn't, the suppressions have grown too broad and
// the `Thread Sanitizer (ProxyCore)` job has quietly stopped being a gate.
//
// Inverted exit code, deliberately: this program is *expected* to be reported, so the
// workflow step around it fails when TSan stays quiet. See
// `.github/workflows/tsan-reverse-proxy-hunt.yml`'s canary step.
//
//   swiftc -parse-as-library -sanitize=thread main.swift -o canary
//   TSAN_OPTIONS="suppressions=$PWD/Tools/tsan/suppressions.txt" ./canary
//
// Not part of any test target: it would fail the suite it lives in, which is the point.
import Foundation

@main
struct Canary {
    static func main() {
        let shared = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        shared.initialize(to: 0)
        defer { shared.deallocate() }

        // Plain pthread-backed threads rather than a `Task`: the report must not involve
        // the concurrency runtime at all, or a suppression aimed at the runtime's glue
        // could hide it and the canary would be measuring the wrong thing.
        let writer = Thread {
            for i in 0 ..< 1_000_000 { shared.pointee = i }
        }
        let reader = Thread {
            var seen = 0
            for _ in 0 ..< 1_000_000 { seen &+= shared.pointee }
            // Consume it so the loop can't be optimized away.
            if seen == Int.min { print("unreachable") }
        }

        writer.start()
        reader.start()
        // No join API on `Thread`; the race window is what matters, and TSan reports it
        // the moment both accesses have happened.
        Foundation.Thread.sleep(forTimeInterval: 2)
        print("canary finished — TSan should have reported a data race above")
    }
}
