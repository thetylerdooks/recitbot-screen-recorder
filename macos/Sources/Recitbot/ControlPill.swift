import AppKit
import RecitbotCore

/// The recorder's handle on the pill (RecordingPill), called from the recording thread; the pill itself lives on the
/// main thread. parity: Recorder.ShowPill (Invoke, waits until shown) / SetPillSources (Invoke) / Toggle (BeginInvoke) /
/// ClosePill (BeginInvoke)
final class PillHost: RecordingPill, @unchecked Sendable {
    private let gate = NSLock()
    private var pill: ControlPill?
    private var gaveUp = false
    /// parity: AgentRecorder.cs Recorder.ShowPill shown.WaitOne(10000)
    static let showTimeout: TimeInterval = 10

    /// Posts the pill to the main thread and waits up to 10 s for it to be on screen; false = PILL_FAILED. A pill that
    /// only appears after the wait gave up is closed at once (nobody would close it otherwise).
    func show(monitor: MonitorInfo, monitors: [MonitorInfo], cfg: Config, onStop: @escaping () -> Void, onMute: @escaping (String, Bool) -> Void) -> Bool {
        return present(monitor, monitors, cfg, nil, onStop, onMute)
    }

    func showWaiting(monitor: MonitorInfo, monitors: [MonitorInfo], cfg: Config, hint: String, onStop: @escaping () -> Void) -> Bool {
        return present(monitor, monitors, cfg, hint, onStop, { _, _ in })
    }

    private func present(_ monitor: MonitorInfo, _ monitors: [MonitorInfo], _ cfg: Config, _ hint: String?,
                         _ onStop: @escaping () -> Void, _ onMute: @escaping (String, Bool) -> Void) -> Bool {
        let shown = DispatchSemaphore(value: 0)
        let handlers = Box<(() -> Void, (String, Bool) -> Void)>((onStop, onMute))
        let ok = Box<Bool>(false)
        onMainAsync { [self] in
            gate.lock(); let late = gaveUp; gate.unlock()
            if late { return }
            let p = ControlPill(cfg: cfg, target: monitor, monitors: monitors, waitingHint: hint)
            p.stopClicked = handlers.value?.0
            p.muteChanged = handlers.value?.1
            p.show()
            gate.lock()
            let abandoned = gaveUp
            if !abandoned { pill = p; ok.value = p.visible }
            gate.unlock()
            if abandoned { p.close() } else { shown.signal() }
        }
        if shown.wait(timeout: .now() + PillHost.showTimeout) == .timedOut {
            gate.lock(); gaveUp = true; let p = pill; pill = nil; gate.unlock()
            if let f = p { onMainAsync { f.close() } }
            return false
        }
        return ok.value ?? false
    }

    func setSources(mic: Bool, system: Bool) {
        gate.lock(); let p = pill; gate.unlock()
        guard let f = p else { return }
        onMain { f.setSources(mic: mic, system: system) }
    }

    func toggle(_ source: String) {
        gate.lock(); let p = pill; gate.unlock()
        guard let f = p else { return }
        onMainAsync { f.toggle(source) }
    }

    func close() {
        gate.lock(); let p = pill; pill = nil; gate.unlock()
        guard let f = p else { return }
        onMainAsync { f.close() }
    }
}

/// The recording's only always-visible UI: one capsule centred at the top of the recorded monitor (12 points below its
/// work area's top, i.e. under the menu bar) with the REC dot and timer, the mic and PC-sound toggles, and Stop. A
/// borderless non-activating panel of this app: the capture filter excludes every window of this app except the webcam
/// bubble (CaptureFilter.make), so the pill and its tooltip are never in the video; it never becomes key or main and is
/// only ever shown with orderFrontRegardless, so neither showing nor clicking it takes focus from the user's app. Dragged
/// by its body (not the buttons), kept on the monitor it is dropped on, and its spot remembered per monitor (config
/// pill_at_<monitor id>, in points). A button acts only on a real click: pressed and released on it with < 4 points of
/// movement. The toggles mute/unmute mid-recording and never stop it.
/// parity: AgentRecorder.cs ControlPill (wes-8b83b0f; replaces kit-install StopPopup)
@MainActor
final class ControlPill: NSObject {
    let cfg: Config
    let target: MonitorInfo
    let monitors: [MonitorInfo]
    /// Points: AppKit scales to the display's backing pixels (the C# redraws at each monitor's DPI instead).
    let layout: PillLayout
    let panel: NonActivatingPanel
    let view: PillView
    private(set) var tip: PillTip?
    private var tick: Timer?
    private var started = Double.nan, hoverSince = 0.0
    private let gesture = ClickGesture()
    /// Window position in recorder space (top-left, points); the pill sits layout.pill.location inside it.
    private(set) var at = IPoint.zero
    private(set) var stopping = false, micAvailable = false, micOn = false, sysAvailable = false, sysOn = false
    private(set) var hover: String?
    private var pressed: String?
    private var dragBody = false, closed = false
    private var windowStart = IPoint.zero, downAt = IPoint.zero
    /// Always "exclude": the capture filter leaves out every window of this app but the bubble.
    let captureMode = "exclude"
    var stopClicked: (() -> Void)?
    /// (PillLayout.mic or .sys, muted) after a toggle click or toggle().
    var muteChanged: ((String, Bool) -> Void)?
    /// Set while a start waits for Screen Recording (macOS only): this text stays under the pill, the REC dot is
    /// graphite and the timer holds at 00:00; Stop cancels the waiting start. Otherwise the pill is unchanged.
    let waitingHint: String?

    init(cfg: Config, target: MonitorInfo, monitors: [MonitorInfo], waitingHint: String? = nil) {
        self.cfg = cfg
        self.waitingHint = waitingHint
        self.target = target
        self.monitors = monitors.isEmpty ? [target] : monitors
        let l = PillLayout(96)
        layout = l
        let s = l.size
        panel = NonActivatingPanel(frame: NSRect(x: 0, y: 0, width: s.width, height: s.height))
        view = PillView(frame: NSRect(x: 0, y: 0, width: s.width, height: s.height))
        super.init()
        panel.title = PillLayout.title
        panel.acceptsMouseMovedEvents = true
        panel.setAccessibilityTitle(PillLayout.title)
        panel.setAccessibilityLabel(PillLayout.accessibleName)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(PillLayout.accessibleName)
        view.pill = self
        panel.contentView = view
        place()
    }

    /// The pill on screen (without the shadow margin).
    var pillBounds: IRect { return IRect(at.x + layout.pill.x, at.y + layout.pill.y, layout.pill.width, layout.pill.height) }
    var windowAt: IPoint { return at }
    var visible: Bool { return panel.isVisible }
    var elapsed: Double { return started.isNaN || waitingHint != nil ? 0 : Clock.now() - started }

    private func place() {
        let p = layout.place(target.bounds, target.workArea, cfg.pillAt[target.id])
        at = IPoint(p.x - layout.pill.x, p.y - layout.pill.y)
        moveWindow()
    }

    private func moveWindow() {
        panel.setFrameOrigin(ScreenSpace.toAppKit(IRect(at, layout.size)).origin)
    }

    /// Form.Show without activation (ShowWithoutActivation, WS_EX_NOACTIVATE): on screen with its pixels from the first
    /// frame, then the clock and the 80 ms repaint tick start (OnShown).
    func show() {
        view.display()
        panel.orderFrontRegardless()
        started = Clock.now()
        let t = Timer(timeInterval: Double(PillLayout.tickMs) / 1000, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
        if waitingHint != nil { showTip() }
    }

    /// What this recording has: each toggle starts ON when its source is recorded, and is dimmed when it is not.
    func setSources(mic: Bool, system: Bool) {
        micAvailable = mic; micOn = mic
        sysAvailable = system; sysOn = system
        repaint()
        e2eRect()
    }

    /// The toggle action itself (the click handler calls this, and so does --toggle). Never stops the recording.
    func toggle(_ t: String) {
        if closed { return }
        let muted: Bool
        if t == PillLayout.mic && micAvailable { micOn = !micOn; muted = !micOn }
        else if t == PillLayout.sys && sysAvailable { sysOn = !sysOn; muted = !sysOn }
        else { return }
        hideTip()
        hoverSince = Clock.now() // the tooltip comes back with the new state
        repaint()
        Log.write((t == PillLayout.mic ? "mic" : "system audio") + (muted ? " muted" : " unmuted") + " from the pill")
        muteChanged?(t, muted)
        e2eRect()
    }

    /// Dev preview only: shows the hover state and tooltip of one button without moving the mouse.
    func previewHover(_ t: String) {
        hover = t
        hoverSince = Clock.now()
        repaint()
        showTip()
    }

    /// --controls-shots: the state PillLayout.Render(micAvailable, micOn, sysAvailable, sysOn, hover) paints. Nothing is
    /// shown, no tooltip, no log line, no MuteChanged.
    func shotState(micAvailable: Bool, micOn: Bool, sysAvailable: Bool, sysOn: Bool, hover: String?) {
        self.micAvailable = micAvailable; self.micOn = micOn
        self.sysAvailable = sysAvailable; self.sysOn = sysOn
        self.hover = hover
    }

    func repaint() { view.needsDisplay = true }

    /// What the view paints now: the hover only while no button is held, the pressed button only until it becomes a drag.
    var paintHover: String? { return gesture.active ? nil : hover }
    var paintPressed: String? { return gesture.active && !gesture.dragging ? pressed : nil }

    private func onTick() {
        repaint()
        if waitingHint != nil { return } // the hint holds the tooltip's place
        if hover != nil && !gesture.active && (Clock.now() - hoverSince) * 1000 >= Double(PillLayout.tipDelayMs) && !(tip?.visible ?? false) { showTip() }
    }

    private func showTip() {
        if closed { return }
        if tip == nil { tip = PillTip(layout) }
        if let hint = waitingHint {
            let pill = pillBounds
            let d = Displays.nearest(ScreenSpace.displays(), Displays.center(pill))
            tip?.showTip(hint, pill, pill, d?.bounds ?? pill)
            return
        }
        guard let h = hover else { return }
        let b = layout.of(h)
        let pill = pillBounds
        let d = Displays.nearest(ScreenSpace.displays(), Displays.center(pill))
        tip?.showTip(PillLayout.tip(h, h == PillLayout.mic ? micAvailable : sysAvailable, h == PillLayout.mic ? micOn : sysOn),
                     IRect(at.x + b.x, at.y + b.y, b.width, b.height), pill, d?.bounds ?? pill)
    }

    private func hideTip() { if waitingHint == nil, let t = tip, t.visible { t.hide() } }

    // MARK: mouse (from PillView, window coordinates = layout coordinates)

    func mouseDown(_ p: IPoint) {
        if stopping || closed { return }
        let h = layout.hitTest(p)
        if h == nil && !layout.inPill(p) { return } // the shadow
        hideTip()
        gesture.down(ScreenSpace.mouse())
        windowStart = at
        downAt = p
        dragBody = h == nil
        pressed = h
        repaint()
    }

    func mouseMoved(_ p: IPoint) {
        if gesture.active || closed { return }
        let h = layout.hitTest(p)
        // Cursors.Hand on a button, Cursors.SizeAll on the body (the closest macOS cursor: the open hand).
        (h != nil ? NSCursor.pointingHand : layout.inPill(p) ? NSCursor.openHand : NSCursor.arrow).set()
        if h != hover { hover = h; hoverSince = Clock.now(); hideTip(); repaint() }
    }

    func mouseDragged() {
        if !gesture.active { return }
        let dragging = gesture.move(ScreenSpace.mouse())
        if dragging && dragBody {
            at = IPoint(windowStart.x + gesture.dx, windowStart.y + gesture.dy)
            moveWindow()
            if waitingHint != nil { showTip() }
        }
        if dragging { repaint() }
    }

    func mouseExited() {
        NSCursor.arrow.set()
        if hover != nil && !gesture.active { hover = nil; hideTip(); repaint() }
    }

    func mouseUp(_ p: IPoint) {
        if !gesture.active { return }
        let click = gesture.up(ScreenSpace.mouse())
        pressed = nil
        if dragBody && gesture.dragging { drop(); return }
        let t = layout.clickTarget(click, downAt, p)
        repaint()
        if t == PillLayout.mic || t == PillLayout.sys { toggle(t!); return }
        if t != PillLayout.stop || stopping { return }
        stopping = true
        repaint()
        stopClicked?()
    }

    /// End of a drag: the pill goes fully onto the monitor holding its centre, and that monitor remembers the spot.
    private func drop() {
        let r = pillBounds
        let d = Displays.nearest(ScreenSpace.displays(), Displays.center(r))
        let bounds = d?.bounds ?? r
        let p = Displays.keepInside(r, bounds)
        at = IPoint(p.x - layout.pill.x, p.y - layout.pill.y)
        moveWindow()
        if waitingHint != nil { showTip() }
        repaint()
        let m = monitors.first { $0.bounds == bounds }
        if let m = m, !m.id.isEmpty {
            let off = IPoint(p.x - bounds.x, p.y - bounds.y)
            cfg.pillAt[m.id] = off
            cfg.setPrefs("pill_at_" + m.id, String(off.x) + "," + String(off.y))
        }
        Log.write("pill moved to " + String(p.x) + "," + String(p.y) + (m != nil ? " on monitor " + String(m!.index) : ""))
        e2eRect()
    }

    func e2eRect() {
        if !E2e.on || closed { return }
        let p = pillBounds
        func s(_ r: IRect) -> IRect { return IRect(at.x + r.x, at.y + r.y, r.width, r.height) }
        let d = s(layout.dot), st = s(layout.stopButton), mi = s(layout.micButton), sy = s(layout.sysButton), tm = s(layout.timer)
        func b(_ v: Bool) -> String { return v ? "true" : "false" }
        let n: [Int] = [p.x, p.y, p.width, p.height, at.x, at.y, layout.size.width, layout.size.height, dpi,
                        d.x, d.y, d.width, st.x, st.y, st.width, st.height, mi.x, mi.y, sy.x, sy.y, mi.width]
        let k = ["x", "y", "w", "h", "window_x", "window_y", "window_w", "window_h", "dpi", "dot_x", "dot_y", "dot_w",
                 "stop_x", "stop_y", "stop_w", "stop_h", "mic_x", "mic_y", "sys_x", "sys_y", "toggle_w"]
        var j = "{"
        for i in 0..<k.count { j += "\"" + k[i] + "\":" + String(n[i]) + "," }
        j += "\"capture_excluded\":" + b(captureMode == "exclude") + ",\"capture_mode\":\"" + captureMode + "\""
        j += ",\"mic_available\":" + b(micAvailable) + ",\"mic_on\":" + b(micOn)
        j += ",\"sys_available\":" + b(sysAvailable) + ",\"sys_on\":" + b(sysOn)
        j += ",\"body_x\":" + String(tm.x + tm.width / 2) + ",\"body_y\":" + String(tm.y + tm.height / 2) + "}"
        E2e.write("pill-rect.json", j)
    }

    /// The display's scale as a DPI (96 x backing scale); the layout itself is always in points.
    var dpi: Int { return Int(NetFormat.round(96 * Double(panel.backingScaleFactor))) }

    func close() {
        if closed { return }
        closed = true
        tick?.invalidate()
        tick = nil
        tip?.close()
        tip = nil
        panel.orderOut(nil)
        panel.close()
        Log.write("pill closed")
    }
}

/// Inter (the brand face) when installed, else the system face (the C# falls back to Segoe UI). Sizes in points =
/// the C# pixel sizes at 96 dpi. parity: PillLayout.UiFamily / TipFamily / Fonts
@MainActor
enum PillFonts {
    static let interInstalled = NSFontManager.shared.availableFontFamilies.contains { $0.caseInsensitiveCompare("Inter") == .orderedSame }

    static func ui(_ size: Float) -> NSFont {
        let s = CGFloat(size)
        if interInstalled {
            let d = NSFontDescriptor(fontAttributes: [.family: "Inter", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
            if let f = NSFont(descriptor: d, size: s) { return f }
        }
        return NSFont.systemFont(ofSize: s, weight: .semibold)
    }

    static func tip(_ size: Float) -> NSFont {
        let s = CGFloat(size)
        if interInstalled, let f = NSFont(name: "Inter", size: s) ?? NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: "Inter"]), size: s) { return f }
        return NSFont.systemFont(ofSize: s)
    }

    static let timer = ui(PillLayout.timerPx), button = ui(PillLayout.stopPx), tipFont = tip(PillLayout.tipPx)
}

/// Drawing helpers shared by the pill and its tooltip.
@MainActor
enum PillPaint {
    static func color(_ c: RGB, _ alpha: Int = 255) -> NSColor {
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(alpha) / 255)
    }

    static func r(_ r: IRect) -> NSRect { return NSRect(x: r.x, y: r.y, width: r.width, height: r.height) }

    /// Fully rounded ends (a circle when square). parity: PillLayout.Capsule
    static func capsule(_ r: NSRect) -> NSBezierPath {
        let rad = min(r.width, r.height) / 2
        return NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
    }

    static func width(_ s: String, _ f: NSFont) -> CGFloat {
        return NSAttributedString(string: s, attributes: [.font: f]).size().width
    }

    /// Text centred in r (StringAlignment.Center both ways), no wrapping.
    static func centered(_ s: String, _ r: NSRect, _ f: NSFont, _ c: NSColor) {
        let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
        let z = a.size()
        a.draw(at: NSPoint(x: r.midX - z.width / 2, y: r.midY - z.height / 2))
    }

    /// Tabular figures: every digit gets the widest digit's advance, so the timer never jitters. parity: DrawTabular
    static func tabular(_ s: String, _ area: NSRect, _ f: NSFont, _ c: NSColor) {
        var digit: CGFloat = 0
        for ch in "0123456789" { digit = max(digit, width(String(ch), f)) }
        let colon = width(":", f)
        let h = NSAttributedString(string: "0", attributes: [.font: f]).size().height
        var x = area.minX
        let y = area.minY + (area.height - h) / 2
        for ch in s {
            let w = ch.isNumber ? digit : colon
            centered(String(ch), NSRect(x: x, y: y, width: w, height: h), f, c)
            x += w
        }
    }

    /// GraphicsPath.AddArc on a circle: degrees, positive sweep = clockwise on screen (the view is flipped, y down).
    static func arc(_ p: NSBezierPath, _ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ start: CGFloat, _ sweep: CGFloat, newFigure: Bool) {
        let c = NSPoint(x: x + d / 2, y: y + d / 2), rad = d / 2
        if newFigure {
            let a = start * .pi / 180
            p.move(to: NSPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a)))
        }
        p.appendArc(withCenter: c, radius: rad, startAngle: start, endAngle: start + sweep, clockwise: sweep < 0)
    }
}

/// Paints PillLayout (parity: PillLayout.Draw / DrawToggle) and forwards the mouse. Flipped, so the layout's design
/// rectangles apply as they are.
final class PillView: NSView {
    weak var pill: ControlPill?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return false }
    override var mouseDownCanMoveWindow: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill(using: .copy)
        guard let p = pill else { return }
        let l = p.layout
        // Soft shadow: stacked translucent capsules, widest first, 2 below the pill (~30 % black at its edge).
        let sh = l.shadowLayers()
        PillPaint.color(RGB(0, 0, 0), sh.alpha).setFill()
        var i = sh.count
        while i >= 1 {
            PillPaint.capsule(NSRect(x: l.pill.x - i, y: l.pill.y - i + l.s(2), width: l.pill.width + 2 * i, height: l.pill.height + 2 * i)).fill()
            i -= 1
        }
        let body = PillPaint.r(l.pill)
        PillPaint.color(PillLayout.ink).setFill()
        PillPaint.capsule(body).fill()
        let bw = CGFloat(max(1, l.s(1)))
        let border = PillPaint.capsule(body.insetBy(dx: bw / 2, dy: bw / 2))
        border.lineWidth = bw
        PillPaint.color(PillLayout.paper, 38).setStroke()
        border.stroke()
        // REC dot: a gentle opacity pulse (100 % -> 45 %), as on the homepage demo.
        if p.waitingHint != nil { PillPaint.color(PillLayout.graphite).setFill() }
        else { PillPaint.color(PillLayout.red, PillLayout.dotAlpha(PillLayout.pulse(p.elapsed))).setFill() }
        NSBezierPath(ovalIn: PillPaint.r(l.dot)).fill()
        PillPaint.tabular(PillLayout.elapsed(p.elapsed), PillPaint.r(l.timer), PillFonts.timer, PillPaint.color(PillLayout.paper))
        let hover = p.paintHover, pressed = p.paintPressed
        PillPaint.color(PillLayout.stopColor(stopping: p.stopping, pressed: pressed == PillLayout.stop, hover: hover == PillLayout.stop)).setFill()
        PillPaint.capsule(PillPaint.r(l.stopButton)).fill()
        PillPaint.centered("Stop", PillPaint.r(l.stopButton), PillFonts.button, PillPaint.color(PillLayout.paper, p.stopping ? 150 : 255))
        drawToggle(l, PillLayout.mic, p.micAvailable, p.micOn, hover == PillLayout.mic, pressed == PillLayout.mic)
        drawToggle(l, PillLayout.sys, p.sysAvailable, p.sysOn, hover == PillLayout.sys, pressed == PillLayout.sys)
    }

    /// One toggle: a lucide-style mic or speaker (the homepage demo's icons) in Paper. Muted: a slash and a faint fill;
    /// not in this recording: dimmed with a slash.
    private func drawToggle(_ l: PillLayout, _ target: String, _ available: Bool, _ on: Bool, _ hover: Bool, _ down: Bool) {
        let r = PillPaint.r(l.of(target))
        let c = PillLayout.toggleColors(available: available, on: on, hover: hover, down: down)
        let bg = PillPaint.color(c.bg), fg = PillPaint.color(c.fg)
        if c.fill > 0 { bg.setFill(); PillPaint.capsule(r).fill() }
        let size = 16 * CGFloat(l.scale), k = size / 24, ox = r.minX + (r.width - size) / 2, oy = r.minY + (r.height - size) / 2
        let path = NSBezierPath()
        // 24x24 grid, the demo's SVG paths.
        if target == PillLayout.mic {
            PillPaint.arc(path, 9, 3, 6, 180, 180, newFigure: false)
            PillPaint.arc(path, 9, 8, 6, 0, 180, newFigure: false)
            path.close()
            PillPaint.arc(path, 5, 4, 14, 0, 180, newFigure: true)
            path.move(to: NSPoint(x: 12, y: 18))
            path.line(to: NSPoint(x: 12, y: 21))
        } else {
            let pts: [(CGFloat, CGFloat)] = [(4, 9), (4, 15), (8, 15), (13, 19), (13, 5), (8, 9)]
            path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
            for q in pts.dropFirst() { path.line(to: NSPoint(x: q.0, y: q.1)) }
            path.close()
            if on && available {
                PillPaint.arc(path, 9.354, 8, 8, -48.59, 97.18, newFigure: true)
                PillPaint.arc(path, 5.709, 4, 16, -48.59, 97.18, newFigure: true)
            }
        }
        path.transform(using: AffineTransform(m11: k, m12: 0, m21: 0, m22: k, tX: ox, tY: oy))
        path.lineWidth = 2.25 * k
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        fg.setStroke()
        path.stroke()
        if !on || !available {
            // Slash with a background-coloured edge so it reads on top of the icon.
            let a = NSPoint(x: ox + 3 * k, y: oy + 3 * k), z = NSPoint(x: ox + 21 * k, y: oy + 21 * k)
            let edge = NSBezierPath()
            edge.move(to: a); edge.line(to: z)
            edge.lineWidth = 5.5 * k
            edge.lineCapStyle = .round
            bg.setStroke()
            edge.stroke()
            let slash = NSBezierPath()
            slash.move(to: a); slash.line(to: z)
            slash.lineWidth = 2.25 * k
            slash.lineCapStyle = .round
            fg.setStroke()
            slash.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // activeAlways: this app is never active, the pill still gets hover and cursor updates.
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ e: NSEvent) -> IPoint {
        let p = convert(e.locationInWindow, from: nil)
        return IPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
    }

    override func mouseDown(with event: NSEvent) { pill?.mouseDown(point(event)) }
    override func mouseDragged(with event: NSEvent) { pill?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { pill?.mouseUp(point(event)) }
    override func mouseMoved(with event: NSEvent) { pill?.mouseMoved(point(event)) }
    override func mouseEntered(with event: NSEvent) { pill?.mouseMoved(point(event)) }
    override func mouseExited(with event: NSEvent) { pill?.mouseExited() }
}

/// The pill's tooltip: a small panel like the pill (excluded from capture with every other window of this app, never
/// activated, click-through), under the hovered button, or above the pill when the pill sits at the bottom of its
/// monitor. A system tooltip would need the app to be active. parity: AgentRecorder.cs PillTip
@MainActor
final class PillTip {
    let layout: PillLayout
    let panel: NonActivatingPanel
    let view: TipView
    private(set) var screenRect = IRect.empty

    init(_ layout: PillLayout) {
        self.layout = layout
        panel = NonActivatingPanel(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        panel.ignoresMouseEvents = true // WS_EX_TRANSPARENT
        panel.title = "" // PillTip has no Text
        view = TipView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.layout = layout
        panel.contentView = view
    }

    var visible: Bool { return panel.isVisible }

    func showTip(_ text: String, _ button: IRect, _ pill: IRect, _ screen: IRect) {
        let size = layout.tipSize(Double(PillPaint.width(text, PillFonts.tipFont)))
        let at = layout.tipAt(button, pill, size, screen)
        screenRect = IRect(at, size)
        view.text = text
        view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        panel.setFrame(ScreenSpace.toAppKit(screenRect), display: false)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

/// The tooltip, filling its whole surface: Ink, 1 point border, Paper text. parity: PillLayout.DrawTip
final class TipView: NSView {
    var layout: PillLayout?
    var text = ""

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill(using: .copy)
        guard let l = layout else { return }
        // RoundRectF(r, d): d is the corner's diameter.
        let d = CGFloat(l.s(12)), bw = CGFloat(max(1, l.s(1)))
        PillPaint.color(PillLayout.ink).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: d / 2, yRadius: d / 2).fill()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: bw / 2, dy: bw / 2), xRadius: (d - bw) / 2, yRadius: (d - bw) / 2)
        edge.lineWidth = bw
        PillPaint.color(PillLayout.paper, 38).setStroke()
        edge.stroke()
        PillPaint.centered(text, bounds, PillFonts.tipFont, PillPaint.color(PillLayout.paper))
    }
}
