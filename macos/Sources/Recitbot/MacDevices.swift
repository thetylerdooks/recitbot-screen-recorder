import AppKit
import AVFoundation
import CoreGraphics
import RecitbotCore
import ScreenCaptureKit

/// Global display points with a top-left origin (CoreGraphics display space; the recorder's IRect space) <-> AppKit's
/// bottom-left screen coordinates. Both put the main display's corner at 0,0: CG its top-left, AppKit its bottom-left.
enum ScreenSpace {
    static func mainHeight() -> CGFloat { return CGDisplayBounds(CGMainDisplayID()).height }

    static func toAppKit(_ r: IRect) -> NSRect {
        return NSRect(x: CGFloat(r.x), y: mainHeight() - CGFloat(r.y + r.height), width: CGFloat(r.width), height: CGFloat(r.height))
    }

    static func fromAppKit(_ r: NSRect) -> IRect {
        let top = mainHeight() - r.maxY
        return IRect(Int(r.minX.rounded()), Int(top.rounded()), Int(r.width.rounded()), Int(r.height.rounded()))
    }

    static func fromCG(_ r: CGRect) -> IRect {
        return IRect(Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.width.rounded()), Int(r.height.rounded()))
    }

    /// The pointer in recorder space (Cursor.Position / MessagePos). NSEvent.mouseLocation needs no permission.
    static func mouse() -> IPoint {
        let p = NSEvent.mouseLocation
        return IPoint(Int(p.x.rounded(.down)), Int((mainHeight() - p.y).rounded(.down)))
    }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        return (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Live display list (parity: Displays.All): NSScreen frames and visible frames (menu bar and Dock excluded = the
    /// work area). Runs on the main thread.
    static func displays() -> [DisplayInfo] {
        return onMain {
            NSScreen.screens.map { s in
                let id = displayID(s)
                return DisplayInfo(deviceName: "display" + String(id), bounds: fromAppKit(s.frame), workArea: fromAppKit(s.visibleFrame),
                                   primary: id == CGMainDisplayID())
            }
        }
    }

    /// Backing scale of the screen holding a point (1 when none).
    static func scaleAt(_ p: IPoint) -> CGFloat {
        return onMain {
            let ns = NSPoint(x: CGFloat(p.x), y: mainHeight() - CGFloat(p.y))
            return (NSScreen.screens.first { NSMouseInRect(ns, $0.frame, false) } ?? NSScreen.main)?.backingScaleFactor ?? 1
        }
    }
}

/// Runs f on the main thread (the main actor) and returns its value (directly when already there). Callers are
/// background threads that never hold anything the main thread waits for.
func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(f) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(f) }
}

/// Runs f on the main actor later (BeginInvoke).
func onMainAsync(_ f: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(f) }
}

/// A value handed over from a completion handler (which may run on any queue).
final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ v: T? = nil) { value = v }
}

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// Monitors, mics, cameras and windows on this Mac, and window probing. parity: WindowsFfmpegBackend's IDeviceCatalog
/// half (Monitors: Displays.All + MonitorNames; AudioVideo: dshow; Windows/Probe/BringToFront: WindowsApi).
/// Windows come from SCShareableContent (titles need Screen Recording only), live bounds from CGWindowList; no
/// Accessibility API is used anywhere.
final class MacCatalog: @unchecked Sendable {
    /// Dev only (--no-front): a recorded window is left where it is, never activated.
    var noFront = false
    private let logGate = NSLock()
    private var permissionLogged = false

    // MARK: monitors

    func monitors() -> [MonitorInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        let cap = max(count, 1)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(cap))
        CGGetActiveDisplayList(cap, &ids, &count)
        ids = Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        // Main display first (CoreGraphics lists it first already; kept explicit like DXGI's adapter order).
        ids.sort { a, b in (CGDisplayIsMain(a) != 0 ? 0 : 1) < (CGDisplayIsMain(b) != 0 ? 0 : 1) }
        let screens: [(CGDirectDisplayID, String, IRect)] = onMain {
            NSScreen.screens.map { (ScreenSpace.displayID($0), $0.localizedName, ScreenSpace.fromAppKit($0.visibleFrame)) }
        }
        var list: [MonitorInfo] = []
        for (i, id) in ids.enumerated() {
            let m = MonitorInfo()
            let b = CGDisplayBounds(id)
            m.displayID = id
            m.index = i
            m.outputIdx = i
            m.deviceName = "display" + String(id)
            m.bounds = ScreenSpace.fromCG(b)
            let ns = screens.first { $0.0 == id }
            m.workArea = ns?.2 ?? m.bounds
            m.friendlyName = ns?.1
            m.primary = CGDisplayIsMain(id) != 0
            var pw = Int(b.width), ph = Int(b.height)
            if let mode = CGDisplayCopyDisplayMode(id) { pw = mode.pixelWidth; ph = mode.pixelHeight }
            m.pixelSize = ISize(pw, ph)
            m.dpi = b.width > 0 ? Int(NetFormat.round(96.0 * Double(pw) / Double(b.width))) : 96
            var key = m.deviceName
            if let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), let s = CFUUIDCreateString(nil, u) { key = s as String }
            m.id = DeviceMatch.stableId("mon", key)
            list.append(m)
        }
        DeviceMatch.label(list)
        return list
    }

    // MARK: microphones and cameras

    static func micSession() -> AVCaptureDevice.DiscoverySession {
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
    }

    static func cameraSession() -> AVCaptureDevice.DiscoverySession {
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video,
                                                position: .unspecified)
    }

    /// Lists the mics (system default input marked) and cameras. Listing needs no permission.
    func audioVideo() -> AvDevices {
        let d = AvDevices()
        for dev in MacCatalog.micSession().devices {
            d.mics.append(AvDevice(id: DeviceMatch.stableId("mic", dev.uniqueID), name: dev.localizedName, path: dev.uniqueID))
        }
        for dev in MacCatalog.cameraSession().devices {
            d.cameras.append(AvDevice(id: DeviceMatch.stableId("cam", dev.uniqueID), name: dev.localizedName, path: dev.uniqueID))
        }
        DeviceMatch.markDefaultMic(d.mics, AVCaptureDevice.default(for: .audio)?.uniqueID)
        return d
    }

    /// parity: CachedAudioVideo (AVFoundation lists devices in milliseconds; there is nothing to cache).
    func cachedAudioVideo() -> AvDevices { return audioVideo() }

    static func device(_ d: AvDevice) -> AVCaptureDevice? {
        return AVCaptureDevice(uniqueID: d.path ?? "")
    }

    // MARK: windows

    /// SCShareableContent, waited for (at most 10 s). Never called without Screen Recording permission.
    static func shareable(onScreenOnly: Bool) throws -> SCShareableContent {
        let done = DispatchSemaphore(value: 0)
        let box = Box<SCShareableContent>(), err = Box<Error>()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: onScreenOnly) { c, e in
            box.value = c
            err.value = e
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut { throw CaptureError("shareable content timed out") }
        if let c = box.value { return c }
        throw err.value ?? CaptureError("shareable content unavailable")
    }

    /// Screen Recording granted (no prompt).
    static func screenAllowed() -> Bool { return CGPreflightScreenCaptureAccess() }

    /// Open windows of other apps (on-screen ones in front-to-back order, then minimized / hidden ones), at most
    /// DeviceMatch.maxWindows: normal layer, with a title, not this process (pill, bubble).
    func windows(_ monitors: [MonitorInfo]) -> [WindowInfo] {
        if !MacCatalog.screenAllowed() {
            logGate.lock()
            let first = !permissionLogged
            permissionLogged = true
            logGate.unlock()
            if first { Log.write("windows: Screen Recording permission is off; no windows listed") }
            return []
        }
        let content: SCShareableContent
        do { content = try MacCatalog.shareable(onScreenOnly: false) } catch {
            Log.write("window enumeration: " + Agent.message(error))
            return []
        }
        let me = getpid()
        var on: [WindowInfo] = [], off: [WindowInfo] = []
        var exes: [Int32: String] = [:]
        for w in content.windows {
            guard let app = w.owningApplication, app.processID != me, w.windowLayer == 0 else { continue }
            let title = w.title ?? ""
            if NetParse.trim(title).isEmpty || w.frame.width < 1 || w.frame.height < 1 { continue }
            let pid = app.processID
            if exes[pid] == nil {
                exes[pid] = NSRunningApplication(processIdentifier: pid)?.executableURL?.lastPathComponent ?? app.applicationName
            }
            let wi = WindowInfo()
            wi.windowID = w.windowID
            wi.pid = pid
            wi.app = app.applicationName
            wi.exe = exes[pid] ?? ""
            wi.title = title
            wi.minimized = !w.isOnScreen
            wi.bounds = ScreenSpace.fromCG(w.frame)
            wi.id = DeviceMatch.windowId(w.windowID, pid, wi.exe)
            wi.monitorId = (WindowTrack.mostlyOn(monitors, wi.bounds) ?? nearest(monitors, wi.bounds))?.id ?? ""
            if w.isOnScreen { on.append(wi) } else { off.append(wi) }
        }
        return Array((on + off).prefix(DeviceMatch.maxWindows))
    }

    /// MONITOR_DEFAULTTONEAREST: the monitor whose centre is nearest the window's.
    func nearest(_ ms: [MonitorInfo], _ r: IRect) -> MonitorInfo? {
        let c = Displays.center(r)
        return ms.min { a, b in
            let ca = Displays.center(a.bounds), cb = Displays.center(b.bounds)
            let da = Int64(ca.x - c.x) * Int64(ca.x - c.x) + Int64(ca.y - c.y) * Int64(ca.y - c.y)
            let db = Int64(cb.x - c.x) * Int64(cb.x - c.x) + Int64(cb.y - c.y) * Int64(cb.y - c.y)
            return da < db
        }
    }

    /// Live state of a listed window (CGWindowList, cheap enough for the follower's 100 ms poll). Not alive once it is
    /// closed or its id belongs to another process.
    func probe(_ w: WindowInfo) -> WindowState {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowID)) as? [[String: Any]],
              let d = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == w.windowID })
        else { return WindowState() }
        if (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != w.pid { return WindowState() }
        let onScreen = (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        var bounds = IRect.empty
        if let bd = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd as CFDictionary) {
            bounds = ScreenSpace.fromCG(r)
        }
        return WindowState(alive: true, minimized: !onScreen, bounds: bounds)
    }

    /// Brings the window's app to the front (NSRunningApplication.activate: no Accessibility, no input injected). macOS
    /// cannot restore one minimized window without Accessibility, so a minimized window stays minimized (black video
    /// until the user restores it, like a window minimized during a Windows recording).
    func bringToFront(_ w: WindowInfo) -> String {
        if noFront { return "left in place (--no-front)" }
        guard let app = NSRunningApplication(processIdentifier: w.pid) else { return "raised (foreground refused)" }
        if app.isActive && !probe(w).minimized { return "already in front" }
        let ok = app.activate(options: [])
        if probe(w).minimized { return ok ? "app activated; window still minimized (restore it from the Dock)" : "minimized (foreground refused)" }
        return ok ? "foreground" : "raised (foreground refused)"
    }

    // MARK: inventory

    /// The {"type":"devices",...} report. parity: Agent.ReportDevices + DeviceMatch.InventoryJson
    func inventory(requestId: String) -> DeviceInventory {
        let mons = monitors()
        let wins = windows(mons)
        let av = audioVideo()
        var inv = DeviceInventory(json: DeviceMatch.inventoryJson(requestId, mons, av, wins))
        inv.monitors = mons.count
        inv.mics = av.mics.count
        inv.cameras = av.cameras.count
        inv.windows = wins.count
        return inv
    }
}
