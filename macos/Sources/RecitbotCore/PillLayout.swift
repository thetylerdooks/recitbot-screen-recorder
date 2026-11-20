import Foundation

/// Geometry of the recording control pill at one DPI, in window coordinates (top-left origin, y down). One row in a
/// capsule: REC dot and timer, mic toggle, PC-sound toggle, Stop (the homepage demo's order). The window is the pill plus
/// a transparent margin that holds its shadow. Every rectangle is a 96-dpi design rectangle with each edge scaled and
/// rounded on its own (as ControlLayout), so elements apart at 100 % stay apart at any scale. Pure, covered by the
/// selftest. macOS draws it at dpi 96 in points (the backing scale makes it sharp on Retina); the other DPIs exist for
/// the selftest matrix, the same as Windows.
/// parity: AgentRecorder.cs PillLayout (wes-8b83b0f; replaces kit-install PopupLayout)
public final class PillLayout {
    public static let w = 222, h = 40, margin = 12, topGap = 12
    public static let timerPx: Float = 13.5, stopPx: Float = 12.5, tipPx: Float = 12
    public static let pulseSeconds = 1.6
    /// The toggles and Stop (hit-test and tooltip keys). Toggles.mic / Toggles.sys use the same strings.
    public static let mic = "mic", sys = "sys", stop = "stop"
    /// Left to right: what the pill shows, in order. "timer" = the REC dot and the timer.
    public static let order = ["timer", mic, sys, stop]
    /// Brand: Ink pill, Paper icons and text, Tally Red only on the REC dot and Stop. Graphite = a toggle whose source is
    /// not in this recording.
    public static let ink = RGB(0x11, 0x13, 0x18), paper = RGB(0xF5, 0xF3, 0xEE), red = RGB(0xF2, 0x46, 0x3A)
    public static let graphite = RGB(0x5B, 0x60, 0x6B)
    /// Window text and accessible name (Form.Text / AccessibleName).
    public static let title = "Recitbot recording"
    public static let accessibleName = "Recording controls: timer, mic, PC sound, Stop"
    /// Repaint tick (the timer and the pulse) and the hover delay before the tooltip shows.
    public static let tickMs = 80, tipDelayMs = 450

    public let dpi: Int
    public let scale: Float
    /// The window: the pill plus margin on every side.
    public let size: ISize
    public private(set) var pill = IRect.empty, dot = IRect.empty, timer = IRect.empty
    public private(set) var stopButton = IRect.empty, micButton = IRect.empty, sysButton = IRect.empty

    public init(_ dpi: Int) {
        let d = dpi > 0 ? dpi : 96
        let sc = Float(d) / 96
        self.dpi = d
        scale = sc
        size = ISize(Int(NetFormat.round(Double(Float(PillLayout.w + 2 * PillLayout.margin) * sc))),
                     Int(NetFormat.round(Double(Float(PillLayout.h + 2 * PillLayout.margin) * sc))))
        pill = r(0, 0, PillLayout.w, PillLayout.h)
        dot = r(16, 15, 10, 10)
        timer = r(32, 8, 58, 24)
        micButton = r(94, 6, 28, 28)
        sysButton = r(126, 6, 28, 28)
        stopButton = r(162, 7, 54, 26)
    }

    public func s(_ v: Float) -> Int { return Int(NetFormat.round(Double(v * scale))) }

    func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> IRect {
        let m = PillLayout.margin
        return IRect.fromLTRB(s(Float(m + x)), s(Float(m + y)), s(Float(m + x + w)), s(Float(m + y + h)))
    }

    public func of(_ target: String?) -> IRect {
        return target == PillLayout.mic ? micButton : target == PillLayout.sys ? sysButton : target == PillLayout.stop ? stopButton : .empty
    }

    public func hitTest(_ p: IPoint) -> String? {
        for t in [PillLayout.stop, PillLayout.mic, PillLayout.sys] where of(t).contains(p) { return t }
        return nil
    }

    /// Inside the capsule (the shadow around it is not part of the pill).
    public func inPill(_ p: IPoint) -> Bool {
        let r = Float(pill.height) / 2, x = Float(p.x) + 0.5, y = Float(p.y) + 0.5, cy = Float(pill.y) + r
        let cx = max(Float(pill.x) + r, min(Float(pill.right) - r, x))
        return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
    }

    /// The pill's body: the part that drags it (inside the capsule, not on a button).
    public func isBody(_ p: IPoint) -> Bool { return inPill(p) && hitTest(p) == nil }

    /// The button a finished gesture clicked (window coordinates), or nil: it must be a click (under the drag threshold)
    /// that went down and up on the same button.
    public func clickTarget(_ wasClick: Bool, _ downClient: IPoint, _ upClient: IPoint) -> String? {
        if !wasClick { return nil }
        guard let t = hitTest(downClient), t == hitTest(upClient) else { return nil }
        return t
    }

    /// The elements left to right, keyed as `order` (the dot and the timer together).
    public var ordered: [(String, IRect)] {
        return [("timer", IRect.union(dot, timer)), (PillLayout.mic, micButton), (PillLayout.sys, sysButton), (PillLayout.stop, stopButton)]
    }

    /// The timer: mm:ss, h:mm:ss from one hour on.
    public static func elapsed(_ seconds: Double) -> String {
        let s = max(0, seconds.isNaN ? 0 : Int64(seconds.rounded(.down)))
        return s < 3600 ? String(format: "%02lld:%02lld", s / 60, s % 60) : String(format: "%lld:%02lld:%02lld", s / 3600, s / 60 % 60, s % 60)
    }

    public static func tip(_ target: String, _ available: Bool, _ on: Bool) -> String {
        if target == stop { return "Stop recording" }
        let what = target == mic ? "mic" : "PC sound"
        if !available { return "No " + what + " in this recording" }
        return (on ? "Mute " : "Unmute ") + what
    }

    public static let allTips = [
        tip(stop, true, true), tip(mic, true, true), tip(mic, true, false), tip(mic, false, false),
        tip(sys, true, true), tip(sys, true, false), tip(sys, false, false),
    ]

    /// Where the pill (not its window) goes on a monitor: the spot saved for that monitor (offset from its top-left),
    /// else centred at the top of the work area, TopGap down; always fully inside the monitor. macOS: the work area is
    /// the screen's visible frame, so the default spot is 12 points under the menu bar.
    public func place(_ bounds: IRect, _ workArea: IRect, _ saved: IPoint?) -> IPoint {
        let p = saved.map { IPoint(bounds.x + $0.x, bounds.y + $0.y) }
            ?? IPoint(workArea.x + (workArea.width - pill.width) / 2, workArea.top + s(Float(PillLayout.topGap)))
        return Displays.keepInside(IRect(p, pill.size), bounds)
    }

    /// The tooltip under the pill, centred on its button; above the pill when there is no room below on the monitor.
    public func tipAt(_ button: IRect, _ pill: IRect, _ tip: ISize, _ screen: IRect) -> IPoint {
        let x = button.x + button.width / 2 - tip.width / 2
        var y = pill.bottom + s(6)
        if y + tip.height > screen.bottom { y = pill.top - s(6) - tip.height }
        return Displays.keepInside(IRect(IPoint(x, y), tip), screen)
    }

    /// Tooltip size for a measured text width (MeasureTypo): text + 20, 26 high.
    public func tipSize(_ textWidth: Double) -> ISize { return ISize(Int(textWidth.rounded(.up)) + s(20), s(26)) }

    /// REC dot: a gentle opacity pulse, 1 = fully lit, period PulseSeconds.
    public static func pulse(_ seconds: Double) -> Double { return 0.5 + 0.5 * cos(2 * Double.pi * seconds / pulseSeconds) }

    /// The dot's alpha (100 % -> 45 %), 0-255.
    public static func dotAlpha(_ pulse: Double) -> Int { return Int(NetFormat.round(255 * (0.45 + 0.55 * pulse))) }

    /// Shadow: n stacked translucent capsules, each this alpha (about 30 % black at the pill's edge).
    public func shadowLayers() -> (count: Int, alpha: Int) {
        let n = s(9)
        return (n, max(1, Int(NetFormat.round(255 * (1 - pow(0.7, 1.0 / Double(n)))))))
    }

    public static func stopColor(stopping: Bool, pressed: Bool, hover: Bool) -> RGB {
        return stopping ? RGB.mix(red, ink, 0.45) : pressed ? RGB.mix(red, ink, 0.15) : hover ? RGB.mix(red, paper, 0.12) : red
    }

    /// A toggle's background fill amount (0 = none) and its background / icon colours.
    public static func toggleColors(available: Bool, on: Bool, hover: Bool, down: Bool) -> (fill: Int, bg: RGB, fg: RGB) {
        let fill = !available ? 0 : (on ? 0 : 24) + (hover ? 22 : 0) + (down ? 14 : 0)
        return (fill, RGB.mix(ink, paper, Float(fill) / 255), available ? paper : graphite)
    }
}

/// System.Drawing.Color without alpha. parity: Color.FromArgb(r, g, b)
public struct RGB: Equatable, Sendable {
    public var r: Int, g: Int, b: Int
    public init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }

    /// PillLayout.Mix: a + (b - a) * t per channel, rounded.
    public static func mix(_ a: RGB, _ b: RGB, _ t: Float) -> RGB {
        func m(_ x: Int, _ y: Int) -> Int { return Int(NetFormat.round(Double(Float(x) + Float(y - x) * t))) }
        return RGB(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b))
    }
}
