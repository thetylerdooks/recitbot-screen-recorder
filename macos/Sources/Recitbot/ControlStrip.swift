import AppKit
import RecitbotCore

/// Size slider, mirror toggle and shape switch shown next to the bubble after a click. Its own small window of this app,
/// so the capture filter keeps it out of the video. Like the bubble and the pill it never takes focus; instead, while
/// open, it polls the mouse buttons (NSEvent.pressedMouseButtons, no permission) and hides on a press anywhere outside
/// itself and the bubble, or when another app comes to the front. parity: AgentRecorder.cs ControlStrip
@MainActor
final class ControlStrip: NSObject {
    let owner: WebcamBubble
    let panel: NonActivatingPanel
    let view: StripView
    let layout: ControlLayout
    private var watch: Timer?
    var value = WebcamSize.defaultPx
    var mirror = true, rect = false, sliding = false
    private var buttonWasDown = false
    private var foregroundAtOpen: pid_t = 0

    init(owner: WebcamBubble) {
        self.owner = owner
        let l = ControlLayout(96)
        layout = l
        let s = l.size
        let p = NonActivatingPanel(frame: NSRect(x: 0, y: 0, width: s.width, height: s.height))
        p.title = "Agent Recorder webcam controls"
        panel = p
        view = StripView(frame: NSRect(x: 0, y: 0, width: s.width, height: s.height))
        super.init()
        view.strip = self
        panel.contentView = view
    }

    var visible: Bool { return panel.isVisible }
    var bounds: IRect { return ScreenSpace.fromAppKit(panel.frame) }

    /// Click-away detection without focus: a new press outside the strip and the bubble, or another app coming to the
    /// front (Cmd+Tab, Dock), closes the strip.
    private func tick() {
        if !visible { watch?.invalidate(); watch = nil; return }
        let down = NSEvent.pressedMouseButtons != 0
        if down && !buttonWasDown && !sliding {
            let p = ScreenSpace.mouse()
            if !bounds.contains(p) && !owner.bounds.contains(p) { hide(); return }
        }
        buttonWasDown = down
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundAtOpen && !sliding { hide() }
    }

    /// Places the strip beside the bubble fully inside the work area of the bubble's display (ControlLayout.place) and
    /// shows it.
    func showNear(_ bubble: IRect) {
        value = owner.px
        mirror = owner.mirrored
        rect = owner.isRect
        let mon = Displays.nearest(ScreenSpace.displays(), Displays.center(bubble))
        let wa = mon?.workArea ?? bubble
        let at = layout.place(bubble, wa)
        panel.setFrame(ScreenSpace.toAppKit(IRect(at, layout.size)), display: false)
        view.needsDisplay = true
        if !visible {
            foregroundAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            buttonWasDown = NSEvent.pressedMouseButtons != 0
            panel.orderFrontRegardless()
            watch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        if E2e.on {
            let b = bounds
            E2e.write("controls-rect.json", "{\"x\":\(b.x),\"y\":\(b.y),\"w\":\(b.width),\"h\":\(b.height),\"capture_excluded\":true,\"capture_mode\":\"exclude\"}")
        }
    }

    func hide() {
        watch?.invalidate()
        watch = nil
        panel.orderOut(nil)
        if sliding { sliding = false; owner.commitPx() }
    }

    /// strip.Close() hides first (OnVisibleChanged): a slide in progress is committed.
    func close() {
        watch?.invalidate()
        watch = nil
        panel.orderOut(nil)
        panel.close()
        if sliding { sliding = false; owner.commitPx() }
    }

    // MARK: input (view coordinates = layout coordinates: top-left origin, points)

    func mouseDown(_ p: IPoint) {
        if layout.trackHit.contains(p) { sliding = true; setFromX(p.x); return }
        if layout.mirrorHit.contains(p) {
            mirror = !mirror
            view.needsDisplay = true
            owner.setMirror(mirror)
            return
        }
        if layout.shapeHit.contains(p) {
            let want = layout.shapeFor(p, rect)
            if want == rect { return }
            rect = want
            view.needsDisplay = true
            owner.setShape(rect) // resizes the bubble and re-places this strip beside it
        }
    }

    func mouseDragged(_ p: IPoint) { if sliding { setFromX(p.x) } }

    func mouseUp() {
        if !sliding { return }
        sliding = false
        owner.commitPx()
    }

    func scroll(_ up: Bool) {
        value = WebcamSize.clampPx(value + (up ? 10 : -10))
        view.needsDisplay = true
        owner.previewPx(value)
        owner.commitPx()
    }

    private func setFromX(_ x: Int) {
        let v = layout.valueAt(x)
        if v == value { return }
        value = v
        view.needsDisplay = true
        owner.previewPx(v)
    }
}

/// Paints ControlLayout (parity: ControlLayout.Draw / Render), flipped so its design rectangles apply as they are.
final class StripView: NSView {
    weak var strip: ControlStrip?
    /// --controls-shots: a state painted without a strip (parity: ControlLayout.Render(px, mirror, rect)).
    var shot: (value: Int, mirror: Bool, rect: Bool)?

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    static func color(_ c: (Int, Int, Int)) -> NSColor {
        return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
    }

    static func r(_ r: IRect) -> NSRect { return NSRect(x: r.x, y: r.y, width: r.width, height: r.height) }

    override func draw(_ dirtyRect: NSRect) {
        let s: (layout: ControlLayout, value: Int, mirror: Bool, rect: Bool)
        if let st = strip { s = (st.layout, st.value, st.mirror, st.rect) }
        else if let shot = shot { s = (ControlLayout(96), shot.value, shot.mirror, shot.rect) }
        else { return }
        let l = s.layout
        NSColor.clear.setFill()
        bounds.fill()
        // The window's rounded shape: CreateRoundRectRgn with a 14 px corner ellipse.
        StripView.color(ControlLayout.bg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: CGFloat(l.corner) / 2, yRadius: CGFloat(l.corner) / 2).fill()
        let t = l.track
        let tx = l.thumbX(s.value)
        StripView.color(ControlLayout.track).setFill()
        StripView.r(t).fill()
        StripView.color(ControlLayout.accent).setFill()
        NSRect(x: t.x, y: t.y, width: tx - t.left, height: t.height).fill()
        StripView.color(ControlLayout.divider).setFill()
        StripView.r(l.divider).fill()
        StripView.r(l.divider2).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: StripView.r(l.thumb(s.value))).fill()

        let font = NSFont.systemFont(ofSize: CGFloat(l.fontSize))
        text(ControlLayout.valueText(s.value), l.value, font, ControlLayout.valueColor)
        text(ControlLayout.mirrorText, l.mirrorLabel, font, ControlLayout.labelColor)
        text(ControlLayout.shapeText, l.shapeLabel, font, ControlLayout.labelColor)

        // Shape switch: two segments, the chosen one filled; icons = a circle and a 16:9 rounded rectangle.
        let sr = CGFloat(NetFormat.round(Double(6 * l.scale)))
        StripView.color(ControlLayout.track).setFill()
        NSBezierPath(roundedRect: StripView.r(l.shapeSwitch), xRadius: sr, yRadius: sr).fill()
        StripView.color(ControlLayout.accent).setFill()
        NSBezierPath(roundedRect: StripView.r(s.rect ? l.rectSeg : l.circleSeg), xRadius: sr, yRadius: sr).fill()
        let on = NSColor.white, off = StripView.color(ControlLayout.valueColor)
        let d = Int(NetFormat.round(Double(11 * l.scale)))
        let cc = IPoint(l.circleSeg.x + l.circleSeg.width / 2, l.circleSeg.y + l.circleSeg.height / 2)
        (s.rect ? off : on).setFill()
        NSBezierPath(ovalIn: NSRect(x: cc.x - d / 2, y: cc.y - d / 2, width: d, height: d)).fill()
        let rw = Int(NetFormat.round(Double(16 * l.scale))), rh = Int(NetFormat.round(Double(9 * l.scale)))
        let rc = IPoint(l.rectSeg.x + l.rectSeg.width / 2, l.rectSeg.y + l.rectSeg.height / 2)
        let rr = CGFloat(max(2, Int(NetFormat.round(Double(4 * l.scale))))) / 2
        (s.rect ? on : off).setFill()
        NSBezierPath(roundedRect: NSRect(x: rc.x - rw / 2, y: rc.y - rh / 2, width: rw, height: rh), xRadius: rr, yRadius: rr).fill()

        // Mirror toggle: a capsule, the knob right when on.
        let tg = l.toggle
        StripView.color(s.mirror ? ControlLayout.accent : ControlLayout.toggleOff).setFill()
        NSBezierPath(roundedRect: StripView.r(tg), xRadius: CGFloat(tg.height) / 2, yRadius: CGFloat(tg.height) / 2).fill()
        let k = tg.height - Int(NetFormat.round(Double(4 * l.scale))), m = Int(NetFormat.round(Double(2 * l.scale)))
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: s.mirror ? tg.right - m - k : tg.x + m, y: tg.y + m, width: k, height: k)).fill()
    }

    /// Left-aligned, vertically centred, no wrapping (StringFormat NoWrap, LineAlignment Center).
    private func text(_ s: String, _ r: IRect, _ font: NSFont, _ c: (Int, Int, Int)) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: StripView.color(c)])
        let size = a.size()
        a.draw(at: NSPoint(x: CGFloat(r.x), y: CGFloat(r.y) + (CGFloat(r.height) - size.height) / 2))
    }

    private func point(_ e: NSEvent) -> IPoint {
        let p = convert(e.locationInWindow, from: nil)
        return IPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
    }

    override func mouseDown(with event: NSEvent) { strip?.mouseDown(point(event)) }
    override func mouseDragged(with event: NSEvent) { strip?.mouseDragged(point(event)) }
    override func mouseUp(with event: NSEvent) { strip?.mouseUp() }
    /// A mouse wheel notch is one step (WM_MOUSEWHEEL); a trackpad's fine deltas add up to a step every 10 points.
    private var scrolled: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        if !event.hasPreciseScrollingDeltas {
            if event.scrollingDeltaY != 0 { strip?.scroll(event.scrollingDeltaY > 0) }
            return
        }
        scrolled += event.scrollingDeltaY
        while abs(scrolled) >= 10 {
            strip?.scroll(scrolled > 0)
            scrolled -= scrolled > 0 ? 10 : -10
        }
    }
}
