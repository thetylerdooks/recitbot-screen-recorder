import AppKit
import AVFoundation
import QuartzCore
import RecitbotCore

/// Borderless panel that never becomes key or main: showing it or clicking it never takes focus from the user's app.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

    convenience init(frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        isMovable = false
    }
}

/// Interlocked.Exchange on a flag: set() is true only for the caller that changed it.
final class AtomicFlag: @unchecked Sendable {
    private let gate = NSLock()
    private var on = false
    func set() -> Bool { gate.lock(); defer { gate.unlock() }; if on { return false }; on = true; return true }
    func clear() { gate.lock(); on = false; gate.unlock() }
}

/// A string set on one thread and read on another.
final class LockedString: @unchecked Sendable {
    private let gate = NSLock()
    private var s = ""
    var value: String {
        get { gate.lock(); defer { gate.unlock() }; return s }
        set { gate.lock(); s = newValue; gate.unlock() }
    }
}

/// Draggable webcam preview, round or a 16:9 rounded rectangle. A normal on-screen window of this app that the screen
/// capture keeps (the capture filter excepts it from this app's otherwise excluded windows), so the video shows it; it
/// never takes focus. Click: size slider, mirror and shape toggles (ControlStrip, excluded from the video). Drag: move.
/// Right-click: camera, mirror, shape, hide. Each frame is one premultiplied image (BubbleSurface) set on the view's
/// layer in one transaction, so neither the screen nor the capture sees a half-painted frame.
/// parity: AgentRecorder.cs WebcamBubble (wes-8b83b0f). Positions are top-left corners in global points (see
/// ScreenSpace); bubble_x / bubble_y keep that meaning (Windows: physical pixels, same corner and orientation).
@MainActor
final class WebcamBubble: NSObject, NSMenuDelegate, NSWindowDelegate {
    let cfg: Config
    let cameras: [AvDevice]
    private(set) var camera: AvDevice
    let panel: NonActivatingPanel
    let view: BubbleView
    let menu = NSMenu()
    let gesture = ClickGesture()
    nonisolated let shownEvent = Event(), failedEvent = Event()
    nonisolated let lastError = LockedString()
    nonisolated let windowNumberBox = Box<Int>()
    /// One redraw posted at a time (renderPending).
    nonisolated let renderQueued = AtomicFlag()
    private var feed: CameraFeed?
    private var surface: BubbleSurface?
    private var strip: ControlStrip?
    private var lastFrame: [UInt8] = []
    private var lastSize = ISize(0, 0)
    private(set) var px: Int
    private var dpi: Int
    private(set) var mirror: Bool
    private(set) var rect: Bool
    private var everShown = false, closing = false
    private var formStart = IPoint.zero
    private var refeed: Timer?
    private var stats = RenderStats()
    private var camsItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
    private var mirItem = NSMenuItem(), roundItem = NSMenuItem(), boxItem = NSMenuItem()

    /// homeBounds = the recorded monitor: the bubble starts there so it is in the video. inside = the recorded window's
    /// visible rectangle (window recordings): the bubble starts at its saved spot only if that is inside the window, else
    /// at the window's bottom-left.
    init(cfg: Config, cameras: [AvDevice], camera: AvDevice, px: Int, rect: Bool, homeBounds: IRect, homeWork: IRect, inside: IRect? = nil) {
        self.cfg = cfg
        self.cameras = cameras
        self.camera = camera
        let size = WebcamSize.clampPx(px)
        self.px = size
        self.rect = rect
        mirror = cfg.mirror
        dpi = Int(NetFormat.round(96 * Double(ScreenSpace.scaleAt(Displays.center(homeWork)))))
        let dims = WebcamSize.sizeFor(size, 96, rect)
        let margin = 24
        let def = IPoint(homeWork.left + margin, homeWork.bottom - dims.height - margin)
        var at = def
        if let w = inside {
            at = IPoint(w.left + margin, w.bottom - dims.height - margin)
            if let bx = cfg.bubbleX, let by = cfg.bubbleY, w.contains(IRect(IPoint(bx, by), dims)) { at = IPoint(bx, by) }
        } else if let bx = cfg.bubbleX, let by = cfg.bubbleY {
            let saved = IRect(IPoint(bx, by), dims)
            if let on = ScreenSpace.displays().first(where: { $0.bounds.contains(Displays.center(saved)) }) {
                at = on.bounds == homeBounds ? Displays.keepInside(saved, homeBounds) : Displays.remap(saved.location, saved.size, on.bounds, homeBounds)
            }
        }
        let p = NonActivatingPanel(frame: ScreenSpace.toAppKit(IRect(at, dims)))
        p.title = "Agent Recorder webcam"
        panel = p
        view = BubbleView(frame: NSRect(origin: .zero, size: NSSize(width: dims.width, height: dims.height)))
        super.init()
        view.owner = self
        panel.contentView = view
        panel.delegate = self
        windowNumberBox.value = panel.windowNumber
        buildMenu()
        let real = Int(NetFormat.round(96 * Double(panel.backingScaleFactor)))
        if real != dpi { dpi = real }
        let area = inside.map { IRect.intersect($0, homeBounds) } ?? homeBounds
        rebuild(Displays.keepInside(IRect(at, dims), area))
    }

    /// The bubble in recorder space (points, top-left origin).
    var bounds: IRect { return ScreenSpace.fromAppKit(panel.frame) }
    nonisolated var windowNumber: Int { return windowNumberBox.value ?? 0 }
    var isRect: Bool { return rect }
    var mirrored: Bool { return mirror }

    /// Size in points (dpi 96) and in pixels (the backing scale's dpi).
    private var dims: ISize { return WebcamSize.sizeFor(px, 96, rect) }
    private var pixelDims: ISize { return WebcamSize.sizeFor(px, dpi, rect) }

    /// Window recordings: when the recorded window moves or resizes, a bubble sitting on it moves along, keeping its
    /// offset from the window's bottom-left corner (where it starts), unless the user is dragging it.
    func followWindow(_ from: IRect, _ to: IRect) {
        if closing || gesture.active { return }
        let b = bounds
        if !from.contains(Displays.center(b)) { return }
        let p = IPoint(to.left + (b.left - from.left), to.bottom - (from.bottom - b.top))
        moveTo(Displays.keepInside(IRect(p, b.size), to))
        e2eRect()
    }

    private func moveTo(_ p: IPoint) {
        panel.setFrameOrigin(ScreenSpace.toAppKit(IRect(p, dims)).origin)
    }

    /// New surface for the current size, positioned at `at`, presented with the last frame (no blank flash).
    private func rebuild(_ at: IPoint) {
        let pd = pixelDims
        surface = BubbleSurface(pd, WebcamSize.ringWidth(dpi), rect)
        let d = dims
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(ScreenSpace.toAppKit(IRect(at, d)), display: false)
        view.frame = NSRect(x: 0, y: 0, width: d.width, height: d.height)
        CATransaction.commit()
        present()
    }

    private func render() {
        if closing || surface == nil { return }
        if let f = feed, f.copyLatest(&lastFrame) { lastSize = f.size; stats.frame() }
        present()
    }

    private func present() {
        guard let s = surface else { return }
        let cam = !lastFrame.isEmpty && lastFrame.count >= lastSize.width * lastSize.height * 4
        if cam {
            lastFrame.withUnsafeBufferPointer { s.compose($0.baseAddress, lastSize, lastSize.width * 4, mirror) }
        } else {
            s.compose(nil, ISize(0, 0), 0, mirror)
        }
        view.show(s)
    }

    private func reportStats() {
        guard let f = feed else { return }
        let r = stats.report(f.frames)
        Log.write("webcam: redraw " + r)
        E2e.write("bubble-stats.json", r)
    }

    func startCamera() {
        if let f = feed { reportStats(); f.stop() }
        stats = RenderStats()
        let f = CameraFeed(device: MacCatalog.device(camera), name: camera.name, size: pixelDims)
        f.onFrame = { [weak self] in
            guard let b = self, b.renderQueued.set() else { return }
            onMainAsync { b.frameArrived(f) }
        }
        f.onFailed = { [weak self] why in
            guard let b = self else { return }
            onMainAsync { b.cameraFailed(f, why) }
        }
        feed = f
        f.start()
    }

    /// A camera frame is ready: one redraw at a time; the first one shows the bubble.
    private func frameArrived(_ f: CameraFeed) {
        renderQueued.clear()
        guard f === feed, !closing else { return }
        render()
        if !everShown {
            everShown = true
            panel.orderFrontRegardless()
            shownEvent.set()
            e2eRect()
        }
    }

    private func cameraFailed(_ f: CameraFeed, _ why: String) {
        guard f === feed else { return }
        lastError.value = why
        Log.write("webcam: " + camera.name + " failed (" + why + "); continuing without the bubble")
        failedEvent.set()
        shutdown()
    }

    private func e2eRect() {
        if !E2e.on { return }
        let d = dims, b = bounds
        let radius = rect ? BubbleSurface.cornerRadius(d.height) : Float(d.width) / 2
        E2e.write("bubble-rect.json", "{\"x\":\(b.x),\"y\":\(b.y),\"side\":\(d.width),\"w\":\(d.width),\"h\":\(d.height),\"shape\":\"" + (rect ? "rect" : "circle")
                  + "\",\"radius\":" + NetFormat.upTo(Double(radius), 3) + ",\"ring_width\":" + NetFormat.upTo(Double(WebcamSize.ringWidth(dpi)), 3)
                  + ",\"px\":\(px),\"mirror\":" + (mirror ? "true" : "false") + "}")
    }

    /// Stops the camera and closes. Safe to call more than once, before or after the first show.
    func shutdown() {
        if closing { return }
        closing = true
        refeed?.invalidate()
        refeed = nil
        strip?.close()
        reportStats()
        feed?.stop()
        panel.orderOut(nil)
        panel.close()
    }

    /// Moved onto a display with another scale: same size in points, the surface and camera at the new pixel size.
    func windowDidChangeBackingProperties(_ notification: Notification) {
        let real = Int(NetFormat.round(96 * Double(panel.backingScaleFactor)))
        if real == dpi || closing { return }
        dpi = real
        rebuild(bounds.location)
        restartRefeed()
    }

    private func restartRefeed() {
        refeed?.invalidate()
        refeed = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.refeed = nil
                if !self.closing && (self.feed == nil || self.feed!.size != self.pixelDims) { self.startCamera() }
            }
        }
    }

    /// Live resize from the slider (keeps the centre; the camera is re-opened at the new size once the slider rests).
    func previewPx(_ v: Int) {
        let v = WebcamSize.clampPx(v)
        if v == px || closing { return }
        px = v
        reshape()
    }

    /// New size or shape around the same centre, kept on screen; the camera re-opens at the new size once it rests.
    private func reshape() {
        let c = Displays.center(bounds)
        let d = dims
        rebuild(Displays.onScreen(ScreenSpace.displays(), IRect(IPoint(c.x - d.width / 2, c.y - d.height / 2), d)))
        restartRefeed()
    }

    /// Circle or 16:9 rounded rectangle; persisted like size and mirror.
    func setShape(_ toRect: Bool) {
        if toRect == rect || closing { return }
        rect = toRect
        cfg.shape = rect ? "rect" : "circle"
        reshape()
        let b = bounds
        cfg.bubbleX = b.left; cfg.bubbleY = b.top
        cfg.setPrefs("webcam_shape", cfg.shape, "bubble_x", String(b.left), "bubble_y", String(b.top))
        Log.write("webcam: shape " + cfg.shape)
        if let s = strip, s.visible { s.showNear(bounds) }
        e2eRect()
    }

    func commitPx() {
        let b = bounds
        cfg.webcamPx = px
        cfg.bubbleX = b.left; cfg.bubbleY = b.top
        cfg.setPrefs("webcam_px", String(px), "bubble_x", String(b.left), "bubble_y", String(b.top))
        if let s = strip, s.visible { s.showNear(bounds) }
        e2eRect()
    }

    func setMirror(_ on: Bool) {
        if on == mirror || closing { return }
        mirror = on
        cfg.mirror = on
        cfg.setPrefs("mirror", on ? "1" : "0")
        render()
        e2eRect()
    }

    // MARK: mouse (from BubbleView)

    func mouseDown() {
        gesture.down(ScreenSpace.mouse())
        formStart = bounds.location
    }

    func mouseDragged() {
        if !gesture.active { return }
        let was = gesture.dragging
        if !gesture.move(ScreenSpace.mouse()) { return }
        if !was { hideStrip() }
        moveTo(IPoint(formStart.x + gesture.dx, formStart.y + gesture.dy))
    }

    func mouseUp() {
        if !gesture.active { return }
        let click = gesture.up(ScreenSpace.mouse())
        if gesture.dragging {
            let d = dims
            moveTo(Displays.onScreen(ScreenSpace.displays(), IRect(formStart.x + gesture.dx, formStart.y + gesture.dy, d.width, d.height)))
            let b = bounds
            cfg.bubbleX = b.left; cfg.bubbleY = b.top
            cfg.setPrefs("bubble_x", String(b.left), "bubble_y", String(b.top))
            Log.write("webcam: bubble moved to " + String(b.left) + "," + String(b.top))
            e2eRect()
        } else if click { toggleStrip() }
    }

    func rightMouseUp(_ event: NSEvent) {
        if closing { return }
        hideStrip()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func toggleStrip() {
        if closing { return }
        if let s = strip, s.visible { hideStrip(); return }
        if strip == nil { strip = ControlStrip(owner: self) }
        strip?.showNear(bounds)
        Log.write("webcam: controls shown")
    }

    private func hideStrip() {
        if let s = strip, s.visible { s.hide() }
    }

    private func setCamera(_ dev: AvDevice) {
        if dev.id == camera.id || closing { return }
        camera = dev
        cfg.camera = dev.name
        cfg.setPrefs("camera", dev.name)
        Log.write("webcam: switched to " + dev.name)
        startCamera()
    }

    // MARK: menu: Camera >, Mirror, -, Round, Rectangle, -, Hide bubble

    private func buildMenu() {
        menu.autoenablesItems = false
        let cams = NSMenu(title: "Camera")
        cams.autoenablesItems = false
        for c in cameras {
            let it = NSMenuItem(title: c.name, action: #selector(cameraPicked(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.id
            cams.addItem(it)
        }
        camsItem.submenu = cams
        mirItem = NSMenuItem(title: "Mirror", action: #selector(mirrorPicked), keyEquivalent: "")
        roundItem = NSMenuItem(title: "Round", action: #selector(roundPicked), keyEquivalent: "")
        boxItem = NSMenuItem(title: "Rectangle", action: #selector(rectPicked), keyEquivalent: "")
        let hide = NSMenuItem(title: "Hide bubble", action: #selector(hidePicked), keyEquivalent: "")
        for it in [mirItem, roundItem, boxItem, hide] { it.target = self }
        menu.addItem(camsItem)
        menu.addItem(mirItem)
        menu.addItem(.separator())
        menu.addItem(roundItem)
        menu.addItem(boxItem)
        menu.addItem(.separator())
        menu.addItem(hide)
        menu.delegate = self
    }

    /// menu.Opening: the check marks.
    func menuNeedsUpdate(_ m: NSMenu) {
        mirItem.state = mirror ? .on : .off
        roundItem.state = rect ? .off : .on
        boxItem.state = rect ? .on : .off
        for it in camsItem.submenu?.items ?? [] { it.state = (it.representedObject as? String) == camera.id ? .on : .off }
    }

    @objc private func cameraPicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let dev = cameras.first(where: { $0.id == id }) { setCamera(dev) }
    }

    @objc private func mirrorPicked() { setMirror(!mirror) }
    @objc private func roundPicked() { setShape(false) }
    @objc private func rectPicked() { setShape(true) }
    @objc private func hidePicked() { Log.write("webcam: bubble hidden by user"); shutdown() }
}

/// Redraw rate of the bubble: camera frames presented, the longest wait between two, and how many waits were longer than
/// two camera frames (each one is a visible stutter). parity: WebcamBubble.RenderStats
struct RenderStats {
    let started = Clock.now()
    var last = -1.0
    var presented = 0, late = 0
    var maxGapMs = 0.0

    mutating func frame() {
        let now = Clock.now()
        if last >= 0 {
            let ms = (now - last) * 1000
            if ms > maxGapMs { maxGapMs = ms }
            if ms > 67 { late += 1 }
        }
        last = now
        presented += 1
    }

    func report(_ cameraFrames: Int) -> String {
        let s = max(0.001, Clock.now() - started)
        return "{\"seconds\":" + NetFormat.fixed(s, 2) + ",\"camera_frames\":" + String(cameraFrames) + ",\"presented\":" + String(presented)
            + ",\"camera_fps\":" + NetFormat.fixed(Double(cameraFrames) / s, 1) + ",\"present_fps\":" + NetFormat.fixed(Double(presented) / s, 1)
            + ",\"max_gap_ms\":" + NetFormat.fixed(maxGapMs, 1) + ",\"late\":" + String(late) + "}"
    }
}

/// The bubble's pixels as the layer's contents; mouse events go to the bubble.
final class BubbleView: NSView {
    weak var owner: WebcamBubble?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override var isOpaque: Bool { return false }

    func show(_ s: BubbleSurface) {
        let data = Data(s.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let img = CGImage(width: s.w, height: s.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s.w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = img
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // Cursors.SizeAll: the closest macOS cursor for "drag to move".
    override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp() }
    override func rightMouseUp(with event: NSEvent) { owner?.rightMouseUp(event) }
}
