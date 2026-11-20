import Foundation

/// Control pill checks: timer, tooltips, control order, the layout matrix at 100-200 %, placement on the monitor and of
/// the tooltip, click vs drag on Stop and the toggles, and the per-monitor spot in config.dat. Same cases and vectors as
/// the C# selftest; its font-measuring and rendered-pixel checks need a graphics context and are not run headless here.
/// parity: AgentRecorder.cs Program.SelfTest, "Control pill" blocks (wes-8b83b0f)
enum SelfTestPill {
    static let controlDpis = [96, 120, 144, 168, 192]

    static func mid(_ r: IRect) -> IPoint { return IPoint(r.x + r.width / 2, r.y + r.height / 2) }

    static func pill(_ t: SelfTest) {
        t.check("pill: timer mm:ss, h:mm:ss from one hour", PillLayout.elapsed(0) == "00:00" && PillLayout.elapsed(83.9) == "01:23"
                && PillLayout.elapsed(3599.9) == "59:59" && PillLayout.elapsed(3600) == "1:00:00"
                && PillLayout.elapsed(36061) == "10:01:01" && PillLayout.elapsed(-1) == "00:00",
                [0, 83.9, 3599.9, 3600, 36061, -1].map { PillLayout.elapsed($0) }.joined(separator: " "))
        t.check("pill: tooltips", PillLayout.tip(PillLayout.mic, true, true) == "Mute mic" && PillLayout.tip(PillLayout.mic, true, false) == "Unmute mic"
                && PillLayout.tip(PillLayout.sys, true, true) == "Mute PC sound" && PillLayout.tip(PillLayout.sys, true, false) == "Unmute PC sound"
                && PillLayout.tip(PillLayout.mic, false, false) == "No mic in this recording" && PillLayout.tip(PillLayout.stop, true, true) == "Stop recording")
        t.check("pill: no PC sound tooltip", PillLayout.tip(PillLayout.sys, false, false) == "No PC sound in this recording" && PillLayout.allTips.count == 7)
        t.equal("pill: control order is rec timer, mic, speaker, Stop", PillLayout.order, ["timer", "mic", "sys", "stop"])
        t.check("pill: toggle keys are the --toggle keys", PillLayout.mic == Toggles.mic && PillLayout.sys == Toggles.sys && PillLayout.stop == Toggles.stop)
        t.check("pill: brand colours, title and accessible name", PillLayout.ink == RGB(17, 19, 24) && PillLayout.paper == RGB(245, 243, 238)
                && PillLayout.red == RGB(242, 70, 58) && PillLayout.graphite == RGB(91, 96, 107) && PillLayout.title == "Recitbot recording"
                && PillLayout.accessibleName == "Recording controls: timer, mic, PC sound, Stop")
        t.check("pill: design sizes", PillLayout.w == 222 && PillLayout.h == 40 && PillLayout.margin == 12 && PillLayout.topGap == 12
                && PillLayout.timerPx == 13.5 && PillLayout.stopPx == 12.5 && PillLayout.tipPx == 12 && PillLayout.pulseSeconds == 1.6
                && PillLayout.tickMs == 80 && PillLayout.tipDelayMs == 450 && ClickGesture.threshold == 4)
        // REC dot pulse 100 % -> 45 % over 1.6 s; shadow 9 layers to ~30 %; Stop and toggle states.
        t.check("pill: dot pulse", PillLayout.pulse(0) == 1 && abs(PillLayout.pulse(0.8)) < 1e-9 && PillLayout.dotAlpha(1) == 255
                && PillLayout.dotAlpha(0) == 115 && abs(PillLayout.pulse(1.6) - 1) < 1e-9)
        let sh = PillLayout(96).shadowLayers()
        t.check("pill: shadow layers", sh.count == 9 && sh.alpha == 10, "\(sh)")
        t.check("pill: Stop colours", PillLayout.stopColor(stopping: false, pressed: false, hover: false) == PillLayout.red
                && PillLayout.stopColor(stopping: true, pressed: true, hover: true) == RGB.mix(PillLayout.red, PillLayout.ink, 0.45)
                && PillLayout.stopColor(stopping: false, pressed: true, hover: true) == RGB.mix(PillLayout.red, PillLayout.ink, 0.15)
                && PillLayout.stopColor(stopping: false, pressed: false, hover: true) == RGB.mix(PillLayout.red, PillLayout.paper, 0.12))
        let off = PillLayout.toggleColors(available: false, on: false, hover: true, down: true)
        let muted = PillLayout.toggleColors(available: true, on: false, hover: true, down: true)
        let live = PillLayout.toggleColors(available: true, on: true, hover: false, down: false)
        t.check("pill: toggle states (on: no fill; muted: faint fill; not recorded: dimmed, no fill)",
                off.fill == 0 && off.fg == PillLayout.graphite && off.bg == PillLayout.ink && muted.fill == 60 && muted.fg == PillLayout.paper
                && live.fill == 0 && live.fg == PillLayout.paper)

        for dpi in controlDpis {
            let pct = " @" + String(dpi * 100 / 96) + "%"
            let l = PillLayout(dpi)
            let els = [l.dot, l.timer, l.micButton, l.sysButton, l.stopButton]
            var ok = IRect(IPoint.zero, l.size).contains(l.pill) && l.pill.height % 2 == 0
            for i in 0..<els.count {
                let e = els[i]
                ok = ok && e.width > 0 && l.inPill(mid(e)) && l.inPill(IPoint(e.x, e.y + e.height / 2)) && l.inPill(IPoint(e.right - 1, e.y + e.height / 2))
                    && l.inPill(IPoint(e.x + e.width / 2, e.y)) && l.inPill(IPoint(e.x + e.width / 2, e.bottom - 1))
                for j in (i + 1)..<els.count where els[i].intersectsWith(els[j]) { ok = false }
            }
            ok = ok && l.inPill(IPoint(l.timer.x, l.timer.y)) && l.inPill(IPoint(l.timer.right - 1, l.timer.bottom - 1))
            // A visible gap between the buttons, so a click is never ambiguous.
            ok = ok && l.micButton.left - l.timer.right >= 3 && l.sysButton.left - l.micButton.right >= 3 && l.stopButton.left - l.sysButton.right >= 3
            t.check("pill" + pct + ": dot, timer, mic, PC sound, Stop inside the capsule, apart and in that order", ok)
            let xs = l.ordered.map { $0.1.x }
            t.check("pill" + pct + ": controls left to right = rec timer, mic, speaker, Stop", l.ordered.map { $0.0 } == PillLayout.order
                    && xs == xs.sorted() && Set(xs).count == xs.count && l.ordered.last?.0 == PillLayout.stop)
            let gap = IPoint((l.micButton.right + l.sysButton.left) / 2, mid(l.micButton).y)
            t.check("pill" + pct + ": hit-test", l.hitTest(mid(l.micButton)) == PillLayout.mic && l.hitTest(mid(l.sysButton)) == PillLayout.sys
                    && l.hitTest(mid(l.stopButton)) == PillLayout.stop && l.hitTest(gap) == nil && l.hitTest(mid(l.timer)) == nil && l.hitTest(mid(l.dot)) == nil)
            // Dragged by the body only: never from a button, never from the shadow around the capsule.
            t.check("pill" + pct + ": body drags, buttons and shadow do not", l.isBody(mid(l.timer)) && l.isBody(mid(l.dot)) && l.isBody(gap)
                    && !l.isBody(mid(l.stopButton)) && !l.isBody(mid(l.micButton)) && !l.isBody(mid(l.sysButton))
                    && !l.inPill(IPoint(l.pill.x + 1, l.pill.y + 1)) && !l.inPill(IPoint(l.pill.right - 2, l.pill.bottom - 2)) && !l.inPill(IPoint(1, 1))
                    && !l.inPill(IPoint(mid(l.pill).x, l.pill.bottom + 1)) && !l.inPill(IPoint(mid(l.pill).x, l.pill.y - 1)))
            t.check("pill" + pct + ": click = down and up on the same button", l.clickTarget(true, mid(l.micButton), mid(l.micButton)) == PillLayout.mic
                    && l.clickTarget(true, mid(l.sysButton), mid(l.sysButton)) == PillLayout.sys && l.clickTarget(true, mid(l.stopButton), mid(l.stopButton)) == PillLayout.stop
                    && l.clickTarget(true, mid(l.micButton), mid(l.sysButton)) == nil && l.clickTarget(true, mid(l.stopButton), mid(l.micButton)) == nil
                    && l.clickTarget(false, mid(l.micButton), mid(l.micButton)) == nil && l.clickTarget(true, mid(l.timer), mid(l.micButton)) == nil)
            // The shadow fits in the margin (the C# checks the rendered pixels; here the geometry that guarantees it).
            let layers = l.shadowLayers().count
            t.check("pill" + pct + ": shadow stays inside the window", l.pill.x - layers >= 1 && l.pill.y - layers + l.s(2) >= 1
                    && l.pill.right + layers <= l.size.width - 1 && l.pill.bottom + layers + l.s(2) <= l.size.height - 1)
            // Placement: centred, 12 below the work area's top; saved spots (also off the monitor) kept fully on it.
            var bad = 0, cases = 0
            for mon in [IRect(0, 0, 1920, 1080), IRect(1920, -200, 2560, 1440), IRect(-3840, 0, 3840, 2160)] {
                for wa in [IRect(mon.x, mon.y, mon.width, mon.height - 48), IRect(mon.x, mon.y + 48, mon.width, mon.height - 48)] {
                    let def = l.place(mon, wa, nil)
                    cases += 1
                    if def.y != wa.top + l.s(Float(PillLayout.topGap)) || abs(def.x + l.pill.width / 2 - (wa.x + wa.width / 2)) > 1 { bad += 1 }
                    for fx in [-400, 0, 1, 2, 3, 50000] {
                        for fy in [-400, 0, 1, 2, 3, 50000] {
                            let x = fx <= 3 && fx >= 0 ? fx * (mon.width - l.pill.width / 2) / 3 : fx
                            let y = fy <= 3 && fy >= 0 ? fy * (mon.height - l.pill.height / 2) / 3 : fy
                            let at = IRect(l.place(mon, wa, IPoint(x, y)), l.pill.size)
                            cases += 1
                            if !mon.contains(at) { bad += 1 }
                        }
                    }
                    let kept = IRect(l.place(mon, wa, IPoint(40, 300)), l.pill.size)
                    cases += 1
                    if kept.location != IPoint(mon.x + 40, mon.y + 300) { bad += 1 }
                }
            }
            t.check("pill" + pct + ": top centre by default, \(cases) placements incl. saved spots at edges and off-screen stay on the monitor", bad == 0)
            let screen = IRect(0, 0, 1920, 1080)
            let tsz = ISize(l.s(140), l.s(26))
            func btn(_ pill: IRect, _ tg: String) -> IRect {
                let r = l.of(tg)
                return IRect(pill.x + r.x - l.pill.x, pill.y + r.y - l.pill.y, r.width, r.height)
            }
            let top = IRect(l.place(screen, screen, nil), l.pill.size)
            let t1 = IRect(l.tipAt(btn(top, PillLayout.mic), top, tsz, screen), tsz)
            let low = IRect(top.x, screen.bottom - top.height, top.width, top.height)
            let t2 = IRect(l.tipAt(btn(low, PillLayout.mic), low, tsz, screen), tsz)
            let corner = IRect(screen.right - top.width, 0, top.width, top.height)
            let t3 = IRect(l.tipAt(btn(corner, PillLayout.sys), corner, tsz, screen), tsz)
            t.check("pill" + pct + ": tooltip under its button, above the pill at the bottom, always on the monitor",
                    t1.top >= top.bottom && abs(t1.x + t1.width / 2 - mid(btn(top, PillLayout.mic)).x) <= 1 && t2.bottom <= low.top
                    && screen.contains(t1) && screen.contains(t2) && screen.contains(t3) && !t3.intersectsWith(corner))
            t.check("pill" + pct + ": tooltip size = text + 20, 26 high", l.tipSize(100.2) == ISize(101 + l.s(20), l.s(26)))
        }
        let l96 = PillLayout(96)
        t.check("pill @100%: rectangles match the C# design", l96.size == ISize(246, 64) && l96.pill == IRect(12, 12, 222, 40)
                && l96.dot == IRect(28, 27, 10, 10) && l96.timer == IRect(44, 20, 58, 24) && l96.micButton == IRect(106, 18, 28, 28)
                && l96.sysButton == IRect(138, 18, 28, 28) && l96.stopButton == IRect(174, 19, 54, 26))
        t.check("pill: default spot on a 1440x900 screen under a 25 pt menu bar", l96.place(IRect(0, 0, 1440, 900), IRect(0, 25, 1440, 875), nil) == IPoint(609, 37))

        // Control pill: drag threshold vs Stop.
        let stop = l96.stopButton
        let sIn = IPoint(stop.x + stop.width / 2, stop.y + stop.height / 2), timer = IPoint(l96.timer.x + 4, l96.timer.y + l96.timer.height / 2)
        let g = ClickGesture()
        g.down(IPoint(1000, 500)); g.move(IPoint(1002, 501))
        let c1 = g.up(IPoint(1002, 501))
        t.check("stop: click on Stop (2 px jitter) stops", l96.clickTarget(c1, sIn, IPoint(sIn.x + 2, sIn.y + 1)) == PillLayout.stop)
        g.down(IPoint(1000, 500)); g.move(IPoint(1040, 520)); g.move(IPoint(1001, 500))
        let c2 = g.up(IPoint(1000, 500))
        t.check("stop: drag away and back onto Stop never stops", !c2 && g.dragging && l96.clickTarget(c2, sIn, sIn) == nil)
        g.down(IPoint(1000, 500))
        let c5 = g.up(IPoint(1000, 500))
        t.check("stop: press outside Stop, release on it does not stop", l96.clickTarget(c5, timer, sIn) == nil)
        t.check("stop: press on Stop, release outside does not stop", l96.clickTarget(c5, sIn, timer) == nil)
        // Drag vs click on the toggles: the same 4 px rule as Stop.
        let mic = mid(l96.micButton)
        g.down(IPoint(500, 500)); g.move(IPoint(502, 501))
        t.check("toggle: click with 2 px jitter toggles", l96.clickTarget(g.up(IPoint(502, 501)), mic, IPoint(mic.x + 2, mic.y + 1)) == PillLayout.mic)
        g.down(IPoint(500, 500)); g.move(IPoint(520, 500)); g.move(IPoint(500, 500))
        t.check("toggle: drag away and back is never a toggle", l96.clickTarget(g.up(IPoint(500, 500)), mic, mic) == nil)
        g.down(IPoint(500, 500))
        t.check("toggle: exactly 4 px is a drag", l96.clickTarget(g.up(IPoint(504, 500)), mic, IPoint(mic.x + 4, mic.y)) == nil)

        // The pill's spot per monitor in config.dat (old popup_x/popup_y lines are ignored by the pill).
        let cdir = (NSTemporaryDirectory() as NSString).appendingPathComponent("recitbot-selftest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: cdir) }
        do {
            try DataDir.create(cdir)
            let path = (cdir as NSString).appendingPathComponent("config.dat")
            try SecureFile.write(path, ["server=https://x", "popup_x=5", "popup_y=6", "pill_at_mon_f7b81f0c95=12,-3", "pill_at_mon_bad=1", "pill_at_=4,4"]
                                    .map { $0 + "\n" }.joined())
            let pc = try Config.load(cdir)
            t.check("config: pill_at_<monitor> parsed, malformed lines skipped", pc?.pillAt.count == 1 && pc?.pillAt["mon_f7b81f0c95"] == IPoint(12, -3),
                    "\(pc?.pillAt ?? [:])")
            pc?.setPrefs("pill_at_mon_f7b81f0c95", "40,8")
            t.check("config: pill spot saved in place", (try? Config.load(cdir))?.pillAt["mon_f7b81f0c95"] == IPoint(40, 8))
        } catch {
            t.check("config: pill_at_<monitor> parsed, malformed lines skipped", false, Config.message(error))
        }
    }
}
