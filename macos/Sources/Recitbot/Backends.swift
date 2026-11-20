import Foundation
import RecitbotCore

// The seams between the agent and the platform, mirroring the C# interfaces so upload, link opening, self-update and
// the pill can be filled in by later phases without touching the agent or command logic.
// parity: AgentRecorder.cs ICaptureBackend / IDeviceCatalog / IRecorderHost

/// One device inventory report: the {"type":"devices",...} frame and the counts for the log line.
/// parity: AgentRecorder.cs DeviceMatch.InventoryJson + Agent.ReportDevices
struct DeviceInventory {
    var json: String
    var monitors = 0, mics = 0, cameras = 0, windows = 0
}

/// Monitors, mics, cameras and windows. parity: AgentRecorder.cs IDeviceCatalog
protocol DeviceCatalog: AnyObject {
    func inventory(requestId: String) throws -> DeviceInventory
}

/// parity: AgentRecorder.cs ICaptureBackend. Its ffmpeg members (encoder probes, process start, filter commands, mix,
/// concat, camera process) have no macOS counterpart: ScreenCaptureKit + VideoToolbox + AVAssetWriter, see PARITY.md.
protocol CaptureBackend: AnyObject {
    /// The one-time probes a start would otherwise wait for. parity: AgentRecorder.cs Recorder.Warm
    func warm(pinnedEncoder: String?)
}

extension MacCatalog: DeviceCatalog, CaptureBackend {
    /// Nothing to probe: VideoToolbox's H.264 encoder is always there.
    func warm(pinnedEncoder: String?) {}
}

/// What the recorder reports to and hands over to. parity: AgentRecorder.cs IRecorderHost
protocol RecorderHost: AnyObject {
    var cfg: Config { get }
    var mac: MacCatalog { get }
    var workDir: String { get }
    func sendStatus(_ id: String?, _ status: String, _ error: String?)
    /// Hands over the finished files: upload to the server, or keep them (dev CLI). hasTranscript: the transcription WAV
    /// `audio` was made (a mic was recorded); without it there is no WAV to send.
    func deliver(id: String, video: String, audio: String, hasTranscript: Bool, hasSystemAudio: Bool, token: String?, duration: Double, partBytes: Int64) throws
}

/// The recording state machine the agent drives. parity: AgentRecorder.cs Recorder (Start / Stop / Busy)
protocol RecorderControl: AnyObject {
    var busy: Bool { get }
    /// The recording id in progress (nil when idle).
    var current: String? { get }
    func start(id: String?, maxSeconds: Int, opts: StartOpts, uploadToken: String?, received: Double)
    func stop(id: String?)
}

/// The recording control pill. parity: Recorder.ShowPill / SetPillSources / Toggle / ClosePill and ControlPill's
/// StopClicked / MuteChanged events. Every window of this app except the bubble is kept out of the video by the capture
/// filter (CaptureFilter.make), so the pill and its tooltip need nothing extra for that. Implemented by PillHost.
protocol RecordingPill: AnyObject {
    /// Shows the pill on the recorded monitor; true once it is on screen (false = PILL_FAILED).
    func show(monitor: MonitorInfo, monitors: [MonitorInfo], cfg: Config, onStop: @escaping () -> Void, onMute: @escaping (String, Bool) -> Void) -> Bool
    /// The same pill while a start waits for Screen Recording (macOS): REC dot and toggles dimmed, timer held at 00:00,
    /// the hint shown under it, Stop cancels the waiting start. true once it is on screen.
    func showWaiting(monitor: MonitorInfo, monitors: [MonitorInfo], cfg: Config, hint: String, onStop: @escaping () -> Void) -> Bool
    /// Which sources are recorded (a toggle starts on when its source is recorded, dimmed when not).
    func setSources(mic: Bool, system: Bool)
    /// Presses a toggle ("mic" / "sys") through the pill's own click path.
    func toggle(_ source: String)
    func close()
}

/// The upload of one recording's files. parity: AgentRecorder.cs Recorder.Upload + Uploader
protocol RecordingUploader: AnyObject {
    func upload(server: String?, id: String, video: String, audio: String, hasTranscript: Bool, hasSystemAudio: Bool, token: String?,
                duration: Double, partBytes: Int64) throws
    /// One keyframe JPEG (Stills) to /upload/<id>/{path}: the HTTP status, 0 = no response. parity: Recorder.PutStill
    func putStill(server: String?, id: String, token: String?, path: String, jpg: String) throws -> Int
}

/// Share link policy and opener. parity: AgentRecorder.cs LinkPolicy.Allowed + LinkOpener.Open
protocol ShareLinkOpener: AnyObject {
    func allowed(url: String?, server: String?, recordingId: String?) -> Bool
    func open(_ url: String)
}

struct PendingError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
