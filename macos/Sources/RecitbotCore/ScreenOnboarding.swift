import Foundation

/// One-click Screen Recording onboarding (macOS only; Windows has no such gate). Pure decisions and the pending-start
/// file, covered by the selftest; the agent side (prompt, pane, pill hint, poll, relaunch) is ScreenWait.swift.
///
/// A start command that arrives without Screen Recording is not failed: it is saved here as pending, the system prompt
/// (or the Screen Recording pane) is shown, and a short-lived child (`Recitbot --check-screen`) is polled until the user
/// flips the switch. CGPreflightScreenCaptureAccess stays false inside a process that started without the permission,
/// so the agent then relaunches itself under launchd and the new process starts the saved command. The Worker sees no
/// frame while the recorder waits (the recording stays "starting"), "recording" once it runs, or the usual
/// "failed"/CAPTURE_FAILED when the wait times out or is stopped.
public enum ScreenOnboarding {
    /// How long a start waits for the switch, and how often the child checks it.
    public static let waitSeconds: Int64 = 600
    public static let pollSeconds = 2.0
    /// A --check-screen child that has not answered after this long counts as "not yet".
    public static let checkTimeout = 5.0
    /// Relaunches per pending start: one is expected; a second covers a relaunch that raced the grant.
    public static let maxRelaunches = 2
    /// The pill's hint while it waits.
    public static let hint = "Flip Recitbot on, then come back"
    /// x-apple.systempreferences deep link to Privacy & Security > Screen & System Audio Recording.
    public static let paneUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    /// The failure text the Worker already knows (unchanged from before the one-click flow).
    public static let deniedError = "CAPTURE_FAILED: Screen Recording permission is off for Recitbot"
    public static let stoppedError = "CAPTURE_FAILED: stopped before Screen Recording was turned on"
    public static let replacedError = "CAPTURE_FAILED: replaced by a newer start while waiting for Screen Recording"

    /// Files in the data dir: the pending start (0600, it carries the upload token) and the marker that the system
    /// prompt has been shown once (after that macOS suppresses it, so the agent opens the pane itself).
    public static let pendingFile = "pending-start.json"
    public static let promptedFile = "screen-prompted"

    // MARK: one-shot flags (handled before the data dir, the lock or NSApplication)

    public enum Mode: Equatable { case none, checkScreen, requestScreen }

    /// --check-screen prints the preflight result; --request-screen asks for the permission (the installer's step).
    public static func mode(_ args: [String]) -> Mode {
        if args.contains("--check-screen") { return .checkScreen }
        if args.contains("--request-screen") { return .requestScreen }
        return .none
    }

    /// The child's one line on stdout.
    public static func checkLine(_ granted: Bool) -> String { return granted ? "screen=granted" : "screen=denied" }

    /// The child's answer: true only for an exact "screen=granted" line (anything else, or nothing, is "not yet").
    public static func parseCheck(_ output: String) -> Bool {
        return output.components(separatedBy: .newlines).contains("screen=granted")
    }

    // MARK: launch handoff

    /// A launch by LaunchServices (Finder, `open`, macOS's "Quit & Reopen") passes no `--` flag (at most -psn_ / -NS
    /// arguments); the LaunchAgent and the installer always pass --data.
    public static func isBare(_ args: [String]) -> Bool { return !args.contains { $0.hasPrefix("--") } }

    public enum Launch: Equatable { case run, handOff }

    /// handOff = kickstart the LaunchAgent job and exit at once without taking the instance lock (a running job is left
    /// alone, a stopped one starts and resumes a pending start). Only for a bare launch that is not launchd's own job.
    public static func launchDecision(args: [String], xpcServiceName: String?, label: String) -> Launch {
        if !isBare(args) { return .run }
        return xpcServiceName == label ? .run : .handOff
    }

    // MARK: grant and relaunch

    public enum Grant: Equatable { case wait, startHere, relaunch, giveUp }

    /// After a poll: the child still says no = wait; this process already sees the permission = start here; else
    /// relaunch, unless this start was relaunched for already (then it is failed rather than looped).
    public static func onPoll(childGranted: Bool, inProcess: Bool, relaunches: Int) -> Grant {
        if inProcess { return .startHere }
        if !childGranted { return .wait }
        return relaunches < maxRelaunches ? .relaunch : .giveUp
    }

    /// The service target the relaunch helper kickstarts: launchd's own job only (XPC_SERVICE_NAME is the job's label
    /// in its processes); nil for anything else (a --no-autostart start), which starts itself again instead.
    public static func relaunchTarget(xpcServiceName: String?, uid: UInt32, label: String) -> String? {
        return xpcServiceName == label ? "gui/" + String(uid) + "/" + label : nil
    }

    /// The detached helper's argv: waits (at most ~20 s) for `pid` to exit, then `launchctl kickstart <target>` (never
    /// -k: a copy that already started is left alone); when there is no target or kickstart fails (the job is not
    /// loaded), it execs `respawn` (this binary with its own arguments). Positional arguments only, so no path is ever
    /// re-parsed by the shell.
    public static func helperArgv(waitFor pid: Int32, kickstart target: String?, respawn: [String]) -> [String] {
        return ["/bin/sh", "-c",
                "i=0; while kill -0 \"$0\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; "
                + "if [ -n \"$1\" ] && /bin/launchctl kickstart \"$1\" >/dev/null 2>&1; then exit 0; fi; shift; exec \"$@\"",
                String(pid), target ?? ""] + respawn
    }

    /// A bare launch's handoff: `launchctl kickstart` of the LaunchAgent job (a running job is left alone).
    public static func kickstartArgv(uid: UInt32, label: String) -> [String] {
        return ["/bin/launchctl", "kickstart", "gui/" + String(uid) + "/" + label]
    }

    /// An Apple-event quit (System Settings' "Quit & Reopen", Activity Monitor) is refused while recording, so the
    /// recording is never lost to it; a logout / restart / shutdown quit (it carries a kAEQuitReason) always proceeds.
    public static func refuseQuit(busy: Bool, sessionEnding: Bool) -> Bool { return busy && !sessionEnding }
}

/// The saved start command: the verified frame as received (its nonce is already spent; it is never verified again),
/// when it was saved, and how far the onboarding got.
public struct PendingStart: Equatable, Sendable {
    public var recordingId: String
    public var frame: String
    public var savedAt: Int64
    public var relaunches: Int

    public init(recordingId: String, frame: String, savedAt: Int64, relaunches: Int = 0) {
        self.recordingId = recordingId; self.frame = frame; self.savedAt = savedAt; self.relaunches = relaunches
    }

    public var json: String {
        return "{\"v\":1,\"recording_id\":" + Json.esc(recordingId) + ",\"saved_at\":" + String(savedAt)
            + ",\"relaunches\":" + String(relaunches) + ",\"frame\":" + Json.esc(frame) + "}"
    }

    public static func parse(_ text: String) -> PendingStart? {
        guard let f = try? Json.parseFlat(text), Fields.opt(f, "v") == "1",
              let id = Fields.opt(f, "recording_id"), !id.isEmpty, let frame = Fields.opt(f, "frame"),
              let at = Int64(Fields.opt(f, "saved_at") ?? ""), let n = Int(Fields.opt(f, "relaunches") ?? "") else { return nil }
        return PendingStart(recordingId: id, frame: frame, savedAt: at, relaunches: n)
    }

    /// Still worth starting: saved no more than waitSeconds ago (and not in the future: a clock change voids it).
    public func fresh(_ now: Int64) -> Bool { return now >= savedAt - 5 && now - savedAt < ScreenOnboarding.waitSeconds }

    public func expiresIn(_ now: Int64) -> Int64 { return max(0, savedAt + ScreenOnboarding.waitSeconds - now) }
}

/// pending-start.json in the data dir. save replaces atomically; claim takes it exactly once (rename first, so two
/// processes can never both start it).
public enum PendingStore {
    public static func path(_ dir: String) -> String { return (dir as NSString).appendingPathComponent(ScreenOnboarding.pendingFile) }

    public static func save(_ dir: String, _ p: PendingStart) throws { try SecureFile.replace(path(dir), p.json) }

    public static func load(_ dir: String) -> PendingStart? {
        guard let t = try? SecureFile.readText(path(dir)) else { return nil }
        return PendingStart.parse(t)
    }

    public static func clear(_ dir: String) { SecureFile.delete(path(dir)) }

    /// The pending start if it is still fresh; an expired or unreadable file is removed either way.
    public static func claim(_ dir: String, now: Int64) -> PendingStart? {
        let p = path(dir), taken = p + ".claimed." + String(getpid())
        if rename(p, taken) != 0 { return nil }
        defer { SecureFile.delete(taken) }
        guard let t = try? SecureFile.readText(taken), let s = PendingStart.parse(t), s.fresh(now) else { return nil }
        return s
    }
}
