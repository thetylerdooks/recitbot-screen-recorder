import Foundation
import RecitbotCore

/// Follows a recorded window while it is captured (polls every 100 ms, only during window recordings): live crop
/// updates for moves and resizes, black while minimized, a monitor switch once the window has been mostly on another
/// monitor for 0.6 s, and a stop once it has been closed for 1 s. Updates are paced (110 ms each), always sending the
/// latest state, so a long drag never builds a backlog. parity: AgentRecorder.cs WindowFollower (the crop goes to the
/// SCStream configuration instead of ffmpeg filter commands).
final class WindowFollower: @unchecked Sendable {
    let catalog: MacCatalog
    let win: WindowInfo
    let monitors: [MonitorInfo]
    private let gate = NSLock()
    private let queue = DispatchQueue(label: "com.recitbot.window-follower")
    private var timer: DispatchSourceTimer?
    private var seg: ScreenSegment?
    private var mon: MonitorInfo?
    private var sent = WindowView()
    private var busyUntil = -Double.infinity, otherSince = 0.0, goneSince = Double.nan
    private var other: MonitorInfo?
    private var lastBounds: IRect
    private var stopped = false
    var onMonitorChanged: ((MonitorInfo) -> Void)?
    var onClosed: (() -> Void)?
    var onMoved: ((IRect, IRect) -> Void)?

    init(catalog: MacCatalog, win: WindowInfo, monitors: [MonitorInfo]) {
        self.catalog = catalog
        self.win = win
        self.monitors = monitors
        lastBounds = win.bounds
    }

    func attach(_ s: ScreenSegment, _ m: MonitorInfo, _ view: WindowView) {
        gate.lock(); seg = s; mon = m; sent = view; busyUntil = -Double.infinity; other = nil; gate.unlock()
    }

    func detach() { gate.lock(); seg = nil; gate.unlock() }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        gate.lock(); stopped = true; seg = nil; gate.unlock()
        timer?.cancel()
        timer = nil
    }

    /// The window's view on monitor m right now (used to continue on another monitor).
    func viewOn(_ m: MonitorInfo) -> WindowView {
        let s = catalog.probe(win)
        return WindowTrack.view(s.bounds, s.minimized, s.alive, m.bounds, WindowView(crop: IRect(0, 0, m.bounds.width, m.bounds.height)))
    }

    private func tick() {
        gate.lock()
        let p = seg, m = mon, last = sent, done = stopped
        gate.unlock()
        guard !done, let s = p, let m = m else { return }
        let now = Clock.now()
        let st = catalog.probe(win)
        if !st.alive {
            if goneSince.isNaN { goneSince = now } else if now - goneSince > 1.0 {
                Log.write("window: closed; stopping")
                gate.lock(); stopped = true; gate.unlock()
                onClosed?()
                return
            }
        } else { goneSince = .nan }
        if st.alive && !st.minimized && st.bounds != lastBounds {
            let from = lastBounds
            lastBounds = st.bounds
            onMoved?(from, st.bounds)
        }
        if st.alive && !st.minimized {
            if let on = WindowTrack.mostlyOn(monitors, st.bounds), on !== m, WindowTrack.share(st.bounds, m.bounds) < 0.5 {
                if other !== on { other = on; otherSince = now } else if now - otherSince >= 0.6 {
                    detach()
                    onMonitorChanged?(on)
                    return
                }
            } else { other = nil }
        }
        if now < busyUntil { return }
        let view = WindowTrack.view(st.bounds, st.minimized, st.alive, m.bounds, last)
        if view == last { return }
        gate.lock()
        if seg !== s { gate.unlock(); return }
        sent = view
        gate.unlock()
        s.apply(view)
        busyUntil = now + 0.110
        if view.blank != last.blank {
            Log.write("window: " + (view.blank ? "hidden (minimized, closed or off the monitor): video is black" : "visible again"))
        }
    }
}
