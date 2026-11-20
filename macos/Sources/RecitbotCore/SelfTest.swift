import Foundation

/// --selftest: headless checks of the pure logic (no network, no UI, no capture, no TCC). One line per test
/// (`PASS name` / `FAIL name: why`), then `selftest: N passed, M failed`. Exit 0 only when all pass.
/// parity: AgentRecorder.cs Program.SelfTest (same case names and the same Worker test vectors where the C# has them).
public final class SelfTest {
    public private(set) var passed = 0, failed = 0
    let out: (String) -> Void

    public init(out: @escaping (String) -> Void = { print($0) }) { self.out = out }

    public func check(_ name: String, _ ok: Bool, _ why: @autoclosure () -> String = "") {
        if ok { passed += 1; out("PASS " + name) }
        else { failed += 1; let w = why(); out("FAIL " + name + ": " + (w.isEmpty ? "check failed" : w)) }
    }

    /// Equality check that says what came out.
    public func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got), want \(want)")
    }

    /// Runs every registered group; returns the process exit code.
    public static func run() -> Int32 {
        let t = SelfTest()
        for group in groups { group(t) }
        t.out("selftest: \(t.passed) passed, \(t.failed) failed")
        return t.failed == 0 ? 0 : 1
    }

    /// Test groups, in order. Later phases append theirs (capture math, layouts, upload planning, link policy, updater).
    public static var groups: [(SelfTest) -> Void] = [
        SelfTestCases.commands,
        SelfTestCases.blocks,
        SelfTestCases.json,
        SelfTestCases.config,
        SelfTestCases.protocolFrames,
        SelfTestCapture.devices,
        SelfTestCapture.windows,
        SelfTestCapture.webcam,
        SelfTestCapture.controls,
        SelfTestPill.pill,
        SelfTestCapture.audio,
        SelfTestCapture.wav,
        SelfTestCapture.mix,
        SelfTestCapture.transcript,
        SelfTestUpload.upload,
        SelfTestKeyframes.keyframes,
        SelfTestUpdate.update,
        SelfTestInstall.install,
        SelfTestUninstall.uninstall,
        SelfTestAccounts.accounts,
        SelfTestOnboarding.onboarding,
    ]
}
