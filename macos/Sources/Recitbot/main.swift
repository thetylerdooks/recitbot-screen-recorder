import AppKit
import RecitbotCore

// Entry point: mirrors Program.Main. --selftest runs first and returns before NSApplication exists (headless: no UI,
// no capture, no TCC prompt). The agent itself is an LSUIElement (.accessory) app: no Dock icon, never activates itself.
// parity: AgentRecorder.cs Program.Main

let args = Array(CommandLine.arguments.dropFirst())
func has(_ flag: String) -> Bool { return args.contains(flag) }

// The end-to-end mix (synthetic frames and WAVs, no capture, no TCC) runs inside --selftest; --muxtest runs it alone.
if has("--selftest") { SelfTest.groups.append(MuxTest.group); exit(SelfTest.run()) }
if has("--muxtest") { exit(MuxTest.run()) }
// Dev-only modes. Windows also handles these before the data dir is touched.
if has("--controls-shots") { exit(DevCLI.controlsShots(args)) }
if has("--webcam-preview") { DevCLI.webcamPreview(args) }
if has("--list-devices") { exit(DevCLI.listDevices()) }
// --pill-preview (wes-8b83b0f); --popup-preview is kit-install's name for the same dev check.
if has("--pill-preview") || has("--popup-preview") { DevCLI.pillPreview(args) }
if has("--record-local") { DevCLI.recordLocal(args) }
if has("--chain-bench") { exit(CLI.pending("--chain-bench", "n/a: ffmpeg video chains do not exist on macOS")) }
if has("--start-latency") { DevCLI.startLatency(args) }

// Screen Recording one-shots (no data dir, no lock, no NSApplication). --check-screen: a fresh process's answer, which
// the waiting agent polls (its own answer never changes after it started). --request-screen: the installer's step, so
// Recitbot is already listed in System Settings before the first recording; started through LaunchServices (open)
// so the request is Recitbot's own.
switch ScreenOnboarding.mode(args) {
case .checkScreen:
    print(ScreenOnboarding.checkLine(CGPreflightScreenCaptureAccess()))
    exit(Program.exitOk)
case .requestScreen:
    if CGPreflightScreenCaptureAccess() { print(ScreenOnboarding.checkLine(true)); exit(Program.exitOk) }
    _ = CGRequestScreenCaptureAccess()
    if let d = Program.arg(args, "--data") {
        let dir = DataDir.fullPath(d)
        try? DataDir.create(dir)
        try? SecureFile.write((dir as NSString).appendingPathComponent(ScreenOnboarding.promptedFile), String(Int64(Date().timeIntervalSince1970)))
    }
    Thread.sleep(forTimeInterval: 1) // the request reaches tccd before this process goes away
    print("screen=requested")
    exit(Program.exitOk)
case .none:
    break
}

// Launched by LaunchServices (Finder, open, macOS's "Quit & Reopen") while the LaunchAgent is loaded: start (or leave
// running) launchd's copy and exit without touching the lock, so there is only ever launchd's one copy. Without a
// loaded LaunchAgent (a --no-autostart install) this copy runs as before.
if ScreenOnboarding.launchDecision(args: args, xpcServiceName: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
                                   label: InstallLayout.label) == .handOff,
   Detached.run(ScreenOnboarding.kickstartArgv(uid: getuid(), label: InstallLayout.label), timeout: 10) == 0 {
    exit(Program.exitOk)
}

let dataDir = DataDir.fullPath(Program.arg(args, "--data") ?? DataDir.defaultPath)
do { try DataDir.create(dataDir) } catch {
    FileHandle.standardError.write(Data(("data folder not usable: " + Config.message(error) + "\n").utf8))
    exit(Program.exitFailed)
}
Log.pathName = (dataDir as NSString).appendingPathComponent("agent.log")
if has("--enroll") { exit(CLI.enroll(args, dataDir)) }
if has("--set") { exit(CLI.setSetting(Program.arg(args, "--set"), dataDir)) }

let instanceLock: InstanceLock
switch InstanceLock.acquire(dataDir) {
case .acquired(let l): instanceLock = l
case .held:
    Log.write("already running")
    exit(Program.exitAlreadyRunning)
case .failed(let why):
    Log.write("instance lock failed: " + why)
    exit(Program.exitAlreadyRunning)
}

let config: Config
do {
    guard let c = try Config.load(dataDir), !c.accounts.isEmpty else { Log.write("not enrolled"); exit(Program.exitNotEnrolled) }
    config = c
} catch {
    Log.write("config unreadable: " + Config.message(error))
    exit(Program.exitNotEnrolled)
}
try? SecureFile.write((dataDir as NSString).appendingPathComponent("agent.pid"), String(getpid()))

func osVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

func runtimeArch() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "?"
    #endif
}

Log.write("starting agent (macOS " + osVersion() + ", " + (MemoryLayout<Int>.size == 8 ? "64" : "32") + "-bit, " + runtimeArch()
          + ", version " + Program.version + ")")
let agent = Agent(cfg: config)
// Dev runs against a local Worker beside someone using the Mac: the same switches as --record-local.
agent.mac.noFront = has("--no-front")
CameraFeed.testCamera = has("--test-camera")

/// Apple-event quits ("Quit & Reopen" in System Settings, Activity Monitor's Quit). parity: none (macOS only)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = AppDelegate.sessionEnding()
        if ScreenOnboarding.refuseQuit(busy: agent.recorder.busy || agent.resuming, sessionEnding: session) {
            Log.write("quit request ignored: a recording is running or about to start")
            return .terminateCancel
        }
        if session { agent.screen.abandon() } else { agent.screen.handOver() }
        Log.write("quitting (" + (session ? "session ending" : "quit request") + ")")
        return .terminateNow
    }

    /// A logout / restart / shutdown quit carries kAEQuitReason; a plain quit does not.
    static func sessionEnding() -> Bool {
        return NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    agent.run()
    withExtendedLifetime((instanceLock, delegate)) { app.run() }
}
