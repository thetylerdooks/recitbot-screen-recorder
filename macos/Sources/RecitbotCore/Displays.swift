import Foundation

/// One connected display. parity: AgentRecorder.cs Display (DeviceName, Bounds, WorkArea, Primary).
/// macOS: bounds/workArea in global display points, top-left origin (see Geometry.swift).
public struct DisplayInfo: Equatable, Sendable {
    public var deviceName: String
    public var bounds: IRect, workArea: IRect
    public var primary: Bool
    public init(deviceName: String, bounds: IRect, workArea: IRect, primary: Bool) {
        self.deviceName = deviceName; self.bounds = bounds; self.workArea = workArea; self.primary = primary
    }
}

/// Window placement math shared by the bubble, the controls and the pill. parity: AgentRecorder.cs Displays (pure part)
public enum Displays {
    public static func center(_ r: IRect) -> IPoint { return IPoint(r.x + r.width / 2, r.y + r.height / 2) }

    /// Moves r inside area (top-left wins when r is larger than area).
    public static func keepInside(_ r: IRect, _ area: IRect) -> IPoint {
        let x = max(area.left, min(area.right - r.width, r.x))
        let y = max(area.top, min(area.bottom - r.height, r.y))
        return IPoint(x, y)
    }

    /// A saved window position is used only while its centre is on a connected monitor (then kept fully inside that
    /// monitor); otherwise (monitor unplugged, resolution changed) the caller's default is used.
    public static func restore(_ screens: [IRect], _ x: Int?, _ y: Int?, _ size: ISize, _ fallback: IPoint) -> IPoint {
        guard let x = x, let y = y else { return fallback }
        let r = IRect(x, y, size.width, size.height)
        for s in screens where s.contains(center(r)) { return keepInside(r, s) }
        return fallback
    }

    /// Same relative spot on another monitor (keeps "bottom-left" bottom-left when the recorded monitor changes).
    public static func remap(_ p: IPoint, _ size: ISize, _ from: IRect, _ to: IRect) -> IPoint {
        var fx = from.width > size.width ? Double(p.x - from.left) / Double(from.width - size.width) : 0
        var fy = from.height > size.height ? Double(p.y - from.top) / Double(from.height - size.height) : 0
        fx = max(0, min(1, fx))
        fy = max(0, min(1, fy))
        return IPoint(to.left + Int(NetFormat.round(fx * Double(max(0, to.width - size.width)))),
                      to.top + Int(NetFormat.round(fy * Double(max(0, to.height - size.height)))))
    }

    /// The monitor holding a point, else the one whose centre is nearest; nil only when the list is empty.
    public static func nearest(_ all: [DisplayInfo], _ c: IPoint) -> DisplayInfo? {
        var best: DisplayInfo?
        var bestD = Int64.max
        for d in all {
            if d.bounds.contains(c) { return d }
            let dc = center(d.bounds)
            let dx = Int64(dc.x - c.x), dy = Int64(dc.y - c.y)
            let dist = dx * dx + dy * dy
            if dist < bestD { bestD = dist; best = d }
        }
        return best
    }

    /// Keeps a window rectangle fully on the monitor holding its centre (or the nearest one).
    public static func onScreen(_ all: [DisplayInfo], _ r: IRect) -> IPoint {
        guard let best = nearest(all, center(r)) else { return r.location }
        return keepInside(r, best.bounds)
    }
}

/// Dev/test hook files (AGENT_RECORDER_E2E_DIR). parity: AgentRecorder.cs E2e.Write
public enum E2e {
    static let dir = ProcessInfo.processInfo.environment["AGENT_RECORDER_E2E_DIR"] ?? ""

    public static var on: Bool { return !dir.isEmpty }

    public static func write(_ name: String, _ text: String) {
        if !on { return }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            Log.write("e2e: " + Config.message(error))
        }
    }
}
