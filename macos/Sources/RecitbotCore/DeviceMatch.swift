import CryptoKit
import Foundation

/// A monitor the agent can record. parity: AgentRecorder.cs MonitorInfo
/// macOS: Index = position in the CoreGraphics active display list (main display first); OutputIdx = Index (every
/// display is reachable by ScreenCaptureKit, there is no ddagrab/gdigrab split); DeviceName = "display<CGDirectDisplayID>"
/// (the counterpart of \\.\DISPLAY1, so "display1"-style queries work on both); FriendlyName = NSScreen.localizedName;
/// Id = StableId("mon", the display's UUID); Bounds/WorkArea in global points (top-left origin); Dpi = 96 x backing scale.
public final class MonitorInfo: @unchecked Sendable {
    public var id = "", deviceName = "", label = ""
    public var friendlyName: String?
    public var index = 0, outputIdx = -1, rank = 0, dpi = 96
    public var primary = false
    public var bounds = IRect.empty, workArea = IRect.empty
    /// macOS only: the CGDirectDisplayID and the display's size in pixels (what the inventory reports as width/height,
    /// like the physical pixels Windows reports).
    public var displayID: UInt32 = 0
    public var pixelSize = ISize(0, 0)
    public init() {}
}

/// A microphone or camera. Path is the device's unique id (AVCaptureDevice.uniqueID; Windows: the dshow moniker).
/// parity: AgentRecorder.cs AvDevice
public final class AvDevice: @unchecked Sendable {
    public var id = "", name = ""
    public var path: String?
    public var isDefault = false
    public init(id: String = "", name: String, path: String? = nil, isDefault: Bool = false) {
        self.id = id; self.name = name; self.path = path; self.isDefault = isDefault
    }
    /// The key of the stable id (Windows: the name ffmpeg is given).
    public var ffmpegName: String { return path ?? name }
}

public final class AvDevices: @unchecked Sendable {
    public var mics: [AvDevice] = [], cameras: [AvDevice] = []
    public init() {}
}

/// An open top-level window. parity: AgentRecorder.cs WindowInfo (Hwnd -> the CGWindowID).
public final class WindowInfo: @unchecked Sendable {
    public var id = "", app = "", exe = "", title = "", monitorId = ""
    public var windowID: UInt32 = 0
    public var pid: Int32 = 0
    public var minimized = false
    public var bounds = IRect.empty
    public init() {}
}

/// Live state of a listed window. parity: AgentRecorder.cs WindowState
public struct WindowState: Sendable {
    public var alive = false, minimized = false
    public var bounds = IRect.empty
    public init(alive: Bool = false, minimized: Bool = false, bounds: IRect = .empty) {
        self.alive = alive; self.minimized = minimized; self.bounds = bounds
    }
}

/// Device ids, labels, matching and the inventory report. Pure logic (no OS calls) so the selftest covers it;
/// worker/src/devices.ts implements the same matching rules for the server-side check. parity: AgentRecorder.cs DeviceMatch
public enum DeviceMatch {
    public static func stableId(_ prefix: String, _ key: String?) -> String {
        let h = Array(SHA256.hash(data: Data(NetParse.lowerInvariant(key ?? "").utf8)))
        var s = prefix + "_"
        for i in 0..<5 { s += String(format: "%02x", h[i]) }
        return s
    }

    /// Left-to-right rank and a left/center/right label (one monitor = center).
    public static func label(_ ms: [MonitorInfo]) {
        // List.Sort is not stable; ties (same left and top) do not occur between distinct displays.
        let order = ms.sorted { a, b in a.bounds.left != b.bounds.left ? a.bounds.left < b.bounds.left : a.bounds.top < b.bounds.top }
        for (i, m) in order.enumerated() {
            m.rank = i
            m.label = order.count == 1 ? "center" : i == 0 ? "left" : i == order.count - 1 ? "right" : "center"
        }
    }

    static let primaryWords = ["primary", "main", "default"]
    static let secondaryWords = ["secondary", "second", "2nd", "other", "external", "non-primary"]

    /// Resolves "primary", an index, an id, a device name, left/right/center, "second"/"other" (the only non-primary
    /// monitor) or a unique part of the model name. nil when unknown or ambiguous.
    public static func monitor(_ ms: [MonitorInfo], _ query: String?) -> MonitorInfo? {
        var q = NetParse.lowerInvariant(NetParse.trim(query ?? ""))
        if q.isEmpty || primaryWords.contains(q) { return ms.first { $0.primary } ?? ms.first }
        if let n = NetParse.int32(q) { return ms.first { $0.index == n } }
        if let hit = ms.first(where: { $0.id == q }) { return hit }
        let trimmed = NetParse.trim(query ?? "")
        if let hit = ms.first(where: { NetParse.lowerInvariant($0.deviceName) == NetParse.lowerInvariant(trimmed)
            || trimStart(NetParse.lowerInvariant($0.deviceName), ["\\", "."]) == q }) { return hit }
        if q == "middle" { q = "center" }
        if q == "left" || q == "right" || q == "center" { return unique(ms.filter { $0.label == q }) }
        if secondaryWords.contains(q) { return unique(ms.filter { !$0.primary }) }
        return unique(ms.filter { m in
            guard let f = m.friendlyName, !f.isEmpty else { return false }
            return NetParse.lowerInvariant(f).contains(q)
        })
    }

    /// Resolves an id, exact name, device path, "default" or a unique part of the name ("HyperX"). nil otherwise.
    public static func av(_ ds: [AvDevice], _ query: String?) -> AvDevice? {
        let q = NetParse.lowerInvariant(NetParse.trim(query ?? ""))
        if q.isEmpty { return nil }
        if let hit = ds.first(where: { d in d.id == q || NetParse.lowerInvariant(d.name) == q || (d.path != nil && NetParse.lowerInvariant(d.path!) == q) }) {
            return hit
        }
        if q == "default" { return ds.first { $0.isDefault } }
        return unique(ds.filter { NetParse.lowerInvariant($0.name).contains(q) })
    }

    static func unique<T>(_ l: [T]) -> T? { return l.count == 1 ? l[0] : nil }

    static func trimStart(_ s: String, _ chars: [Character]) -> String {
        return String(s.drop(while: { chars.contains($0) }))
    }

    public static let maxWindows = 40

    /// parity: DeviceMatch.WindowId(hwnd, pid, exe); macOS keys on the CGWindowID.
    public static func windowId(_ windowID: UInt32, _ pid: Int32, _ exe: String?) -> String {
        return stableId("win", String(windowID) + "|" + String(pid) + "|" + (exe ?? ""))
    }

    static let windowFiller = ["the", "my", "a", "an", "this", "that", "window", "app", "application", "tab", "open", "opened", "with", "and", "of", "on", "in"]

    public static func windowTokens(_ query: String?) -> [String] {
        return splitWhite(NetParse.lowerInvariant(NetParse.trim(query ?? ""))).filter { !windowFiller.contains($0) }
    }

    /// string.Split((char[])null, RemoveEmptyEntries): split on char.IsWhiteSpace.
    static func splitWhite(_ s: String) -> [String] {
        var out: [String] = [], cur: [UInt16] = []
        for u in s.utf16 {
            if NetParse.isWhiteSpace(u) {
                if !cur.isEmpty { out.append(String(decoding: cur, as: UTF16.self)); cur.removeAll() }
            } else { cur.append(u) }
        }
        if !cur.isEmpty { out.append(String(decoding: cur, as: UTF16.self)) }
        return out
    }

    /// An id, an exact title, or tokens that must all appear in "app exe title" ("chrome youtube"). nil when no window
    /// or more than one matches: the recorder never guesses (the server already asked the user). A browser tab is
    /// the browser window whose title is that tab's title (SCWindow.title), so "chrome youtube" finds it the same way.
    public static func window(_ ws: [WindowInfo], _ query: String?) -> WindowInfo? {
        let q = NetParse.lowerInvariant(NetParse.trim(query ?? ""))
        if q.isEmpty { return nil }
        if let hit = ws.first(where: { $0.id == q }) { return hit }
        let exact = ws.filter { NetParse.lowerInvariant($0.title) == q }
        if exact.count == 1 { return exact[0] }
        let tokens = windowTokens(q)
        if tokens.isEmpty { return nil }
        return unique(ws.filter { w in
            let hay = NetParse.lowerInvariant(w.app + " " + w.exe + " " + w.title)
            return tokens.allSatisfy { hay.contains($0) }
        })
    }

    /// Marks the microphone matching the system default input (by its unique id on macOS; Windows matches the endpoint's
    /// friendly name because dshow can cut names at 31 characters).
    public static func markDefaultMic(_ mics: [AvDevice], _ uniqueID: String?) {
        guard let u = uniqueID, !u.isEmpty else { return }
        mics.first { $0.path == u }?.isDefault = true
    }

    /// string.Substring(0, max) on UTF-16 code units.
    static func cut(_ s: String?, _ max: Int = 128) -> String {
        let s = s ?? ""
        let u = Array(s.utf16)
        return u.count > max ? String(decoding: u[0..<max], as: UTF16.self) : s
    }

    /// The device-inventory report sent over the device WebSocket ({"type":"devices",...}).
    public static func inventoryJson(_ requestId: String?, _ ms: [MonitorInfo], _ av: AvDevices?, _ windows: [WindowInfo]?) -> String {
        var sb = "{\"type\":\"devices\",\"request_id\":" + Json.esc(requestId ?? "") + ",\"monitors\":["
        for (i, m) in ms.prefix(16).enumerated() {
            if i > 0 { sb += "," }
            let w = m.pixelSize.width > 0 ? m.pixelSize.width : m.bounds.width
            let h = m.pixelSize.height > 0 ? m.pixelSize.height : m.bounds.height
            sb += "{\"id\":" + Json.esc(m.id) + ",\"index\":" + String(m.index) + ",\"output_idx\":" + String(m.outputIdx)
                + ",\"name\":" + Json.esc(cut(m.deviceName)) + ",\"friendly_name\":" + Json.esc(cut(m.friendlyName))
                + ",\"primary\":" + (m.primary ? "true" : "false")
                + ",\"x\":" + String(m.bounds.x) + ",\"y\":" + String(m.bounds.y)
                + ",\"width\":" + String(w) + ",\"height\":" + String(h)
                + ",\"scale\":" + NetFormat.upTo(Double(m.dpi) / 96.0, 2)
                + ",\"position\":" + String(m.rank) + ",\"label\":" + Json.esc(m.label) + "}"
        }
        sb += "],\"mics\":["
        appendAv(&sb, av?.mics, true)
        sb += "],\"cameras\":["
        appendAv(&sb, av?.cameras, false)
        sb += "],\"windows\":["
        for (i, w) in (windows ?? []).prefix(maxWindows).enumerated() {
            if i > 0 { sb += "," }
            // Titles are cut to keep the report small (40 windows stay well under the server's 32 KB frame limit).
            sb += "{\"id\":" + Json.esc(w.id) + ",\"app\":" + Json.esc(cut(w.app, 64))
                + ",\"exe\":" + Json.esc(cut(w.exe, 64)) + ",\"title\":" + Json.esc(cut(w.title, 120))
                + ",\"monitor\":" + Json.esc(w.monitorId) + ",\"minimized\":" + (w.minimized ? "true" : "false")
                + ",\"x\":" + String(w.bounds.x) + ",\"y\":" + String(w.bounds.y)
                + ",\"width\":" + String(max(0, w.bounds.width)) + ",\"height\":" + String(max(0, w.bounds.height)) + "}"
        }
        return sb + "]}"
    }

    static func appendAv(_ sb: inout String, _ l: [AvDevice]?, _ withDefault: Bool) {
        guard let l = l else { return }
        for (i, d) in l.prefix(32).enumerated() {
            if i > 0 { sb += "," }
            sb += "{\"id\":" + Json.esc(d.id) + ",\"name\":" + Json.esc(cut(d.name))
            if withDefault { sb += ",\"default\":" + (d.isDefault ? "true" : "false") }
            sb += "}"
        }
    }
}

/// What a window recording shows: a crop of the recorded monitor (monitor-relative), or black. parity: WindowView
public struct WindowView: Equatable, Sendable {
    public var crop: IRect
    public var blank: Bool
    public init(crop: IRect = .empty, blank: Bool = false) { self.crop = crop; self.blank = blank }
}

/// Pure geometry for window recordings (no OS calls; covered by the selftest). parity: AgentRecorder.cs WindowTrack
/// (Commands and Filter build ffmpeg filter commands and have no macOS counterpart: the crop is the SCStream's
/// sourceRect, updated live, and a blank view is encoded as black frames).
public enum WindowTrack {
    /// Fixed video size for a window: its size scaled to fit 1920x1080 (never up), even, at least 2x2.
    public static func outputSize(_ s: ISize) -> ISize {
        let k = min(1.0, min(1920.0 / Double(max(1, s.width)), 1080.0 / Double(max(1, s.height))))
        return ISize(max(2, Int(Double(s.width) * k) / 2 * 2), max(2, Int(Double(s.height) * k) / 2 * 2))
    }

    static func area(_ r: IRect) -> Int64 { return r.width <= 0 || r.height <= 0 ? 0 : Int64(r.width) * Int64(r.height) }

    /// Fraction of r that lies on the monitor.
    public static func share(_ r: IRect, _ monitor: IRect) -> Double {
        let a = area(r)
        return a == 0 ? 0 : Double(area(IRect.intersect(r, monitor))) / Double(a)
    }

    /// The monitor holding most of r (nil when r is on none).
    public static func mostlyOn(_ ms: [MonitorInfo], _ r: IRect) -> MonitorInfo? {
        var best: MonitorInfo?
        var bestA: Int64 = 0
        for m in ms {
            let a = area(IRect.intersect(r, m.bounds))
            if a > bestA { bestA = a; best = m }
        }
        return best
    }

    /// The view for the window's current state on the recorded monitor: the visible part of the window, or black
    /// (keeping the last crop) while it is minimized, closed or off this monitor.
    public static func view(_ window: IRect, _ minimized: Bool, _ alive: Bool, _ monitor: IRect, _ last: WindowView) -> WindowView {
        let vis = IRect.intersect(window, monitor)
        if !alive || minimized || vis.width < 16 || vis.height < 16 { return WindowView(crop: last.crop, blank: true) }
        return WindowView(crop: vis.offsetBy(-monitor.x, -monitor.y), blank: false)
    }
}
