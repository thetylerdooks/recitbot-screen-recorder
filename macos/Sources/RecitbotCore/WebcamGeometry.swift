import Foundation

// Webcam bubble sizes, pixels and controls: the pure parts of WebcamBubble / BubbleSurface / ControlLayout /
// ClickGesture (wes-8b83b0f), covered by the selftest. macOS works in points where Windows works in physical pixels at
// a DPI: a size at "dpi 96" is points, and the pixels of a surface are points x backing scale (dpi = 96 x scale).

extension WebcamSize {
    /// The rectangle is 16:9 and 3/4 of the size value high (240 -> 320x180 at 100 %): about the circle's visual weight.
    public static let rectHeight = 0.75

    /// start_recording webcam_size as a number: the bubble's height (the circle's diameter) as a percent of the
    /// monitor's shorter side, as a size on the slider's scale (px at 100 %), clamped to its range.
    /// parity: WebcamBubble.PxForPercent (macOS: monitor in points, dpi 96).
    public static func pxForPercent(_ pct: Int, _ monitor: ISize, _ dpi: Int, _ rect: Bool) -> Int {
        let h = Double(max(1, min(100, pct))) / 100.0 * Double(min(monitor.width, monitor.height)) * 96.0 / Double(max(1, dpi))
        return clampPx(Int(NetFormat.round(rect ? h / rectHeight : h)))
    }

    /// Bubble diameter in pixels for a size at a DPI (even, so the centre stays put when it changes).
    public static func sideFor(_ px: Int, _ dpi: Int) -> Int {
        return max(2, Int(NetFormat.round(Double(Float(px * dpi) / 96 / 2))) * 2)
    }

    /// Window size for a size value at a DPI: the circle's diameter, or a 16:9 rectangle rectHeight of it high. Even
    /// sides keep the centre in place on resize. parity: WebcamBubble.SizeFor
    public static func sizeFor(_ px: Int, _ dpi: Int, _ rect: Bool) -> ISize {
        if !rect { let s = sideFor(px, dpi); return ISize(s, s) }
        let h = max(2, Int(NetFormat.round(Double(px) * rectHeight * Double(dpi) / 96 / 2)) * 2)
        return ISize(max(2, Int(NetFormat.round(Double(Float(h * 16) / 9 / 2))) * 2), h)
    }

    /// Ring width in pixels at a DPI. parity: WebcamBubble.RingWidth
    public static func ringWidth(_ dpi: Int) -> Float { return max(2, Float(NetFormat.round(Double(3 * Float(dpi) / 96)))) }
}

/// The bubble's pixels: premultiplied BGRA holding the camera frame inside an anti-aliased circle (or 16:9 rounded
/// rectangle) with a white ring that follows the shape. Mask and ring coverage are computed once per size and shape,
/// so the ring's pixels are identical in every frame. parity: AgentRecorder.cs BubbleSurface (macOS hands the buffer to
/// a CALayer as one CGImage per frame: the screen and the capture never see a half-painted frame either).
public final class BubbleSurface {
    public let w: Int, h: Int
    let mask: [UInt8], ring: [UInt8]
    public private(set) var pixels: [UInt8]
    var xmap: [Int] = []
    var mapSrc = ISize(0, 0)
    var mapMirror = false

    public init(_ size: ISize, _ ringWidth: Float, _ rect: Bool) {
        w = size.width
        h = size.height
        var m = [UInt8](repeating: 0, count: w * h), r = [UInt8](repeating: 0, count: w * h)
        BubbleSurface.geometry(w, h, ringWidth, rect, &m, &r)
        mask = m
        ring = r
        pixels = [UInt8](repeating: 0, count: w * h * 4)
    }

    /// Corner radius of the rectangle shape: 12 % of its height (the shorter side).
    public static func cornerRadius(_ height: Int) -> Float { return 0.12 * Float(height) }

    /// Analytic coverage for either shape: mask = shape coverage per pixel, ring = share of that coverage that is ring.
    /// Both come from the shape's signed distance d (negative inside): mask = clamp(0.5 - d), inner =
    /// clamp(0.5 - (d + ringWidth)). The circle keeps its original closed form.
    public static func geometry(_ w: Int, _ h: Int, _ ringWidth: Float, _ rect: Bool, _ mask: inout [UInt8], _ ring: inout [UInt8]) {
        if !rect && w == h { geometry(w, ringWidth, &mask, &ring); return }
        let cx = Float(w) / 2, cy = Float(h) / 2, hx = cx - 0.5, hy = cy - 0.5
        let rr = min(cornerRadius(h), min(hx, hy))
        for y in 0..<h {
            for x in 0..<w {
                let qx = abs(Float(x) + 0.5 - cx) - (hx - rr), qy = abs(Float(y) + 0.5 - cy) - (hy - rr)
                let ox = max(qx, 0), oy = max(qy, 0)
                let d = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - rr
                let m = max(0, min(1, 0.5 - d))
                let inner = max(0, min(1, 0.5 - (d + ringWidth)))
                let i = y * w + x
                mask[i] = UInt8(NetFormat.round(Double(m * 255)))
                ring[i] = m > 0 ? UInt8(NetFormat.round(Double((m - inner) / m * 255))) : 0
            }
        }
    }

    /// Analytic coverage of the disc: mask = disc coverage per pixel, ring = share of that coverage that is ring.
    public static func geometry(_ side: Int, _ ringWidth: Float, _ mask: inout [UInt8], _ ring: inout [UInt8]) {
        let c = Float(side) / 2, rOut = c - 0.5, rIn = rOut - ringWidth
        for y in 0..<side {
            for x in 0..<side {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let d = (dx * dx + dy * dy).squareRoot()
                let m = max(0, min(1, rOut - d + 0.5))
                let inner = max(0, min(1, rIn - d + 0.5))
                let i = y * side + x
                mask[i] = UInt8(NetFormat.round(Double(m * 255)))
                ring[i] = m > 0 ? UInt8(NetFormat.round(Double((m - inner) / m * 255))) : 0
            }
        }
    }

    /// Composites one camera frame (BGRA, src size, bytesPerRow; nil = placeholder) and mirrors it if asked. A frame of
    /// another size (camera not yet re-opened after a resize or shape change) is scaled to fit.
    public func compose(_ src: UnsafePointer<UInt8>?, _ srcSize: ISize, _ srcStride: Int, _ mirror: Bool) {
        let sw = srcSize.width, sh = srcSize.height
        let cam = src != nil && sw > 0 && sh > 0
        if cam && (xmap.count != w || mapSrc != srcSize || mapMirror != mirror) {
            xmap = (0..<w).map { x in
                let sx = Int(Int64(x) * Int64(sw) / Int64(w))
                return (mirror ? sw - 1 - sx : sx) * 4
            }
            mapSrc = srcSize
            mapMirror = mirror
        }
        pixels.withUnsafeMutableBufferPointer { px in
            for y in 0..<h {
                let row = cam ? Int(Int64(y) * Int64(sh) / Int64(h)) * srcStride : 0
                for x in 0..<w {
                    let i = y * w + x, o = i * 4, a = Int(mask[i])
                    if a == 0 { px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = 0; continue }
                    var b: Int, g: Int, r: Int
                    if cam, let s = src { let p = row + xmap[x]; b = Int(s[p]); g = Int(s[p + 1]); r = Int(s[p + 2]) } else { b = 27; g = 24; r = 24 }
                    let k = Int(ring[i])
                    if k != 0 {
                        b = (b * (255 - k) + 255 * k + 127) / 255
                        g = (g * (255 - k) + 255 * k + 127) / 255
                        r = (r * (255 - k) + 255 * k + 127) / 255
                    }
                    if a != 255 {
                        b = (b * a + 127) / 255
                        g = (g * a + 127) / 255
                        r = (r * a + 127) / 255
                    }
                    px[o] = UInt8(b); px[o + 1] = UInt8(g); px[o + 2] = UInt8(r); px[o + 3] = UInt8(a)
                }
            }
        }
    }
}

/// Click vs drag for one left-button gesture, in screen units. The pointer moving Threshold or more (straight-line
/// distance from the mouse-down point, at any time during the gesture) makes it a drag, and a drag is never a click.
/// parity: AgentRecorder.cs ClickGesture (macOS: screen points; the C# uses physical pixels).
public final class ClickGesture {
    public static let threshold = 4
    var down = IPoint.zero
    var travel = 0.0
    public private(set) var active = false
    public private(set) var dragging = false
    public private(set) var dx = 0, dy = 0

    public init() {}

    public func down(_ screen: IPoint) {
        down = screen
        travel = 0
        dx = 0; dy = 0
        active = true
        dragging = false
    }

    /// True while the gesture is a drag.
    @discardableResult
    public func move(_ screen: IPoint) -> Bool {
        if !active { return false }
        dx = screen.x - down.x
        dy = screen.y - down.y
        travel = max(travel, (Double(dx) * Double(dx) + Double(dy) * Double(dy)).squareRoot())
        if travel >= Double(ClickGesture.threshold) { dragging = true }
        return dragging
    }

    /// Ends the gesture. True only for a click.
    public func up(_ screen: IPoint) -> Bool {
        if !active { return false }
        move(screen)
        active = false
        return !dragging
    }
}

/// Geometry of the webcam controls at one DPI (client coordinates, top-left origin): row 1 is the size slider and its
/// value, row 2 the "Mirror" label and toggle, row 3 the "Shape" label and a two-segment circle / rectangle switch.
/// Every rectangle is a 96-dpi design rectangle with each edge scaled and rounded on its own. Pure, covered by the
/// selftest. parity: AgentRecorder.cs ControlLayout (macOS uses dpi 96: points, Retina via the backing scale).
public final class ControlLayout {
    public static let w = 232, h = 118
    public static let fontPx: Float = 12
    public static let mirrorText = "Mirror", shapeText = "Shape"
    /// Background 24,24,27 and accent 59,130,246 (RGB); track 63,63,70; dividers 39,39,42; value text 161,161,170;
    /// labels 228,228,231; toggle off 82,82,91.
    public static let bg = (24, 24, 27), accent = (59, 130, 246), track = (63, 63, 70), divider = (39, 39, 42)
    public static let valueColor = (161, 161, 170), labelColor = (228, 228, 231), toggleOff = (82, 82, 91)
    public let dpi: Int
    public let scale: Float
    public let size: ISize
    public let track: IRect, trackHit: IRect, value: IRect, mirrorLabel: IRect, toggle: IRect, mirrorHit: IRect, divider: IRect
    public let divider2: IRect, shapeLabel: IRect, shapeSwitch: IRect, circleSeg: IRect, rectSeg: IRect, shapeHit: IRect
    public let thumbR: Int, corner: Int, gap: Int

    public init(_ dpi: Int) {
        let d = dpi > 0 ? dpi : 96
        let sc = Float(d) / 96
        func s(_ v: Float) -> Int { return Int(NetFormat.round(Double(v * sc))) }
        func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> IRect { return IRect.fromLTRB(s(Float(x)), s(Float(y)), s(Float(x + w)), s(Float(y + h))) }
        let W = ControlLayout.w, H = ControlLayout.h
        self.dpi = d
        scale = sc
        size = ISize(s(Float(W)), s(Float(H)))
        track = r(16, 20, 140, 4)       // row 1, centred on y 22
        trackHit = r(8, 6, 160, 32)
        value = r(170, 12, 48, 20)
        divider = r(14, 40, W - 28, 1)
        mirrorLabel = r(16, 48, 150, 20)  // row 2, centred on y 58
        toggle = r(W - 14 - 34, 49, 34, 18)
        mirrorHit = r(8, 42, W - 16, 34)
        divider2 = r(14, 78, W - 28, 1)
        shapeLabel = r(16, 87, 120, 20)   // row 3, centred on y 97
        shapeSwitch = r(W - 14 - 64, 86, 64, 22)
        circleSeg = r(W - 14 - 64, 86, 32, 22)
        rectSeg = r(W - 14 - 32, 86, 32, 22)
        shapeHit = r(8, 80, W - 16, 34)
        thumbR = s(7)
        corner = s(14)
        gap = s(10)
    }

    public var fontSize: Float { return ControlLayout.fontPx * scale }

    public func thumbX(_ px: Int) -> Int {
        let p = WebcamSize.clampPx(px)
        return track.left + Int(NetFormat.round(Double(p - WebcamSize.minPx) * Double(track.width) / Double(WebcamSize.maxPx - WebcamSize.minPx)))
    }

    public func thumb(_ px: Int) -> IRect {
        let cy = track.top + track.height / 2
        return IRect(thumbX(px) - thumbR, cy - thumbR, 2 * thumbR, 2 * thumbR)
    }

    public func valueAt(_ x: Int) -> Int {
        return WebcamSize.clampPx(WebcamSize.minPx + Int(NetFormat.round(Double(x - track.left) * Double(WebcamSize.maxPx - WebcamSize.minPx) / Double(track.width))))
    }

    public static func valueText(_ px: Int) -> String { return String(px) + " px" }

    /// Where the controls go: beside the bubble (right, else left), else below, else above, slid along that side to
    /// stay fully inside the work area of the bubble's monitor and at least `gap` away from the bubble. When the bubble
    /// leaves no room on any side, the controls still stay fully inside the work area (over the bubble).
    public func place(_ bubble: IRect, _ work: IRect) -> IPoint {
        let c = Displays.center(bubble)
        let tries = [
            IPoint(bubble.right + gap, c.y - size.height / 2),
            IPoint(bubble.left - gap - size.width, c.y - size.height / 2),
            IPoint(c.x - size.width / 2, bubble.bottom + gap),
            IPoint(c.x - size.width / 2, bubble.top - gap - size.height),
        ]
        let keepOff = bubble.inflated(gap, gap)
        for p in tries {
            let at = Displays.keepInside(IRect(p, size), work)
            if !IRect(at, size).intersectsWith(keepOff) { return at }
        }
        return Displays.keepInside(IRect(tries[0], size), work)
    }

    /// Shape for a press in row 3: the segment under it, or the other shape for a press on the label (toggle).
    public func shapeFor(_ p: IPoint, _ current: Bool) -> Bool {
        if circleSeg.contains(p) { return false }
        if rectSeg.contains(p) { return true }
        return !current
    }
}
