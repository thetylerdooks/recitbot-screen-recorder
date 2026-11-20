import Foundation

/// Phase (b) selftests: device matching, window geometry, placement, webcam sizes and bubble pixels, webcam controls,
/// click vs drag, mute spans, start trim / late-audio delay, the system-audio WAV timeline and the native mix.
/// Case names and vectors are copied from AgentRecorder.cs (wes-8b83b0f) Program.SelfTest / AudioSelfTest /
/// ControlsSelfTest; checks that only test ffmpeg strings (filters, framecrc, -progress) have no macOS counterpart and
/// are replaced by the same vectors on the native plan (AudioMath.sliceOps).
enum SelfTestCapture {
    static func fakeMonitor(_ index: Int, _ name: String, _ friendly: String?, _ primary: Bool, _ x: Int, _ w: Int, _ h: Int) -> MonitorInfo {
        let m = MonitorInfo()
        m.index = index; m.outputIdx = index; m.deviceName = name; m.friendlyName = friendly; m.primary = primary
        m.bounds = IRect(x, 0, w, h); m.workArea = IRect(x, 0, w, h - 40); m.id = DeviceMatch.stableId("mon", name)
        return m
    }

    static func twoMonitors() -> [MonitorInfo] {
        let ms = [fakeMonitor(0, "\\\\.\\DISPLAY2", "LG ULTRAGEAR", true, 0, 2560, 1440), fakeMonitor(1, "\\\\.\\DISPLAY1", "DELL S2421H", false, 2560, 1920, 1080)]
        DeviceMatch.label(ms)
        return ms
    }

    static func avFixture() -> AvDevices {
        // The C# dshow fixture as parsed: three cameras (the "(none)" one last), three mics.
        let d = AvDevices()
        d.cameras = [AvDevice(name: "Full HD webcam", path: "@device_pnp_\\\\?\\usb#vid_1bcf\\global"), AvDevice(name: "Capture card"),
                     AvDevice(name: "OBS Virtual Camera", path: "@device_sw_{860BB310}\\{A3FCE0F5}")]
        d.mics = [AvDevice(name: "Microphone (HyperX Cloud Alpha Wireless)", path: "@device_cm_{33D9}\\wave_{E8E2}"),
                  AvDevice(name: "Microphone (Realtek(R) Audio)"), AvDevice(name: "Capture card")]
        for m in d.mics { m.id = DeviceMatch.stableId("mic", m.ffmpegName) }
        for c in d.cameras { c.id = DeviceMatch.stableId("cam", c.ffmpegName) }
        return d
    }

    static func winFixture(_ ms: [MonitorInfo]) -> [WindowInfo] {
        func w(_ hwnd: UInt32, _ app: String, _ exe: String, _ title: String) -> WindowInfo {
            let x = WindowInfo()
            x.windowID = hwnd; x.pid = 100 + Int32(hwnd); x.app = app; x.exe = exe; x.title = title; x.monitorId = ms[0].id
            x.id = DeviceMatch.windowId(hwnd, 100 + Int32(hwnd), exe); x.bounds = IRect(100, 100, 1280, 800)
            return x
        }
        return [w(0x10, "Google Chrome", "chrome.exe", "YouTube - Google Chrome"), w(0x20, "Google Chrome", "chrome.exe", "Inbox (3) - Gmail - Google Chrome"),
                w(0x30, "Notepad", "Notepad.exe", "notes.txt - Notepad"), w(0x40, "Notepad", "Notepad.exe", "todo.txt - Notepad"),
                w(0x50, "Zoom Workplace", "Zoom.exe", "Zoom Meeting")]
    }

    static func devices(_ t: SelfTest) {
        let ms = twoMonitors()
        t.check("monitor labels", ms[0].label == "left" && ms[1].label == "right" && ms[1].rank == 1)
        t.check("monitor: primary / main / empty", DeviceMatch.monitor(ms, "primary") === ms[0] && DeviceMatch.monitor(ms, "Main") === ms[0]
                && DeviceMatch.monitor(ms, nil) === ms[0])
        t.check("monitor: index", DeviceMatch.monitor(ms, "1") === ms[1] && DeviceMatch.monitor(ms, "7") == nil)
        t.check("monitor: id", DeviceMatch.monitor(ms, ms[1].id) === ms[1])
        t.check("monitor: device name", DeviceMatch.monitor(ms, "\\\\.\\DISPLAY1") === ms[1] && DeviceMatch.monitor(ms, "display2") === ms[0])
        t.check("monitor: left/right", DeviceMatch.monitor(ms, "RIGHT") === ms[1] && DeviceMatch.monitor(ms, "left") === ms[0])
        t.check("monitor: second/other", DeviceMatch.monitor(ms, "second") === ms[1] && DeviceMatch.monitor(ms, "other") === ms[1])
        t.check("monitor: model name part", DeviceMatch.monitor(ms, "dell") === ms[1] && DeviceMatch.monitor(ms, "samsung") == nil)
        let three = [fakeMonitor(0, "\\\\.\\DISPLAY1", nil, true, 0, 1920, 1080), fakeMonitor(1, "\\\\.\\DISPLAY2", nil, false, -1920, 1920, 1080),
                     fakeMonitor(2, "\\\\.\\DISPLAY3", nil, false, 1920, 1920, 1080)]
        DeviceMatch.label(three)
        t.check("three monitors: left/center/right", three[1].label == "left" && three[0].label == "center" && three[2].label == "right")
        t.check("three monitors: 'second' is ambiguous", DeviceMatch.monitor(three, "second") == nil)
        let mac = [fakeMonitor(0, "display1", "Built-in Retina Display", true, 0, 1512, 982), fakeMonitor(1, "display3", "LG HDR 4K", false, 1512, 2560, 1440)]
        DeviceMatch.label(mac)
        t.check("monitor (macOS): display<id> names, NSScreen model names", DeviceMatch.monitor(mac, "display3") === mac[1]
                && DeviceMatch.monitor(mac, "DISPLAY1") === mac[0] && DeviceMatch.monitor(mac, "retina") === mac[0] && DeviceMatch.monitor(mac, "lg") === mac[1])

        let av = avFixture()
        DeviceMatch.markDefaultMic(av.mics, "@device_cm_{33D9}\\wave_{E8E2}")
        t.check("default mic marked", av.mics[0].isDefault && !av.mics[1].isDefault)
        t.check("mic: brand part", DeviceMatch.av(av.mics, "hyperx") === av.mics[0] && DeviceMatch.av(av.mics, "HyperX Cloud") === av.mics[0])
        t.check("mic: ambiguous part", DeviceMatch.av(av.mics, "microphone") == nil)
        t.check("mic: id / exact name / unknown", DeviceMatch.av(av.mics, av.mics[1].id) === av.mics[1]
                && DeviceMatch.av(av.mics, "microphone (realtek(r) audio)") === av.mics[1] && DeviceMatch.av(av.mics, "Blue Yeti") == nil
                && DeviceMatch.av(av.mics, "") == nil)
        t.check("mic: default / device path", DeviceMatch.av(av.mics, "default") === av.mics[0]
                && DeviceMatch.av(av.mics, "@DEVICE_CM_{33D9}\\WAVE_{E8E2}") === av.mics[0])
        t.check("camera: injected name is not in the inventory", DeviceMatch.av(av.cameras, "x\" -f lavfi -i \"evil") == nil)
        t.check("stable ids", DeviceMatch.stableId("cam", "ABC") == DeviceMatch.stableId("cam", "abc") && DeviceMatch.stableId("cam", "a").count == 14
                && av.mics[0].id.hasPrefix("mic_") && av.cameras[0].id.hasPrefix("cam_"))

        let wins = winFixture(ms)
        t.check("window: 'chrome youtube' = app AND title", DeviceMatch.window(wins, "chrome youtube") === wins[0] && DeviceMatch.window(wins, "the youtube window") === wins[0])
        t.check("window: 'chrome' / 'that notepad' are ambiguous", DeviceMatch.window(wins, "chrome") == nil && DeviceMatch.window(wins, "that notepad") == nil)
        t.check("window: 'notepad todo' / 'zoom' / exe + title", DeviceMatch.window(wins, "notepad todo") === wins[3] && DeviceMatch.window(wins, "Zoom") === wins[4]
                && DeviceMatch.window(wins, "Chrome.EXE gmail") === wins[1])
        t.check("window: id and exact title", DeviceMatch.window(wins, wins[2].id) === wins[2] && DeviceMatch.window(wins, "NOTES.TXT - NOTEPAD") === wins[2])
        t.check("window: unknown / filler only / empty", DeviceMatch.window(wins, "slack") == nil && DeviceMatch.window(wins, "chrome slack") == nil
                && DeviceMatch.window(wins, "the window") == nil && DeviceMatch.window(wins, "") == nil)
        t.check("window ids", wins[0].id.hasPrefix("win_") && wins[0].id.count == 14 && wins[0].id != wins[1].id
                && DeviceMatch.windowId(0x10, 116, "CHROME.EXE") == wins[0].id && DeviceMatch.windowId(0x10, 117, "chrome.exe") != wins[0].id)
        // A browser tab = its browser window, titled with the tab (SCWindow.title of Safari / Chrome on macOS).
        let tabs = winFixture(ms) + [{ () -> WindowInfo in
            let w = WindowInfo()
            w.windowID = 0x60; w.pid = 0x60 + 100; w.app = "Safari"; w.exe = "Safari"; w.title = "Pricing – Recitbot"
            w.id = DeviceMatch.windowId(0x60, 0x60 + 100, "Safari")
            return w
        }()]
        t.check("window: browser tab by app + tab title", DeviceMatch.window(tabs, "safari pricing") === tabs[5] && DeviceMatch.window(tabs, "the recitbot tab") === tabs[5])

        let json = DeviceMatch.inventoryJson("r1", ms, av, wins)
        t.check("inventory json", json.hasPrefix("{\"type\":\"devices\",\"request_id\":\"r1\",\"monitors\":[{\"id\":\"mon_")
                && json.contains("\"name\":\"\\\\\\\\.\\\\DISPLAY2\"") && json.contains("\"label\":\"right\"") && json.contains("\"default\":true") && json.hasSuffix("}]}")
                && json.contains(",\"windows\":[{\"id\":\"win_") && json.contains("\"app\":\"Google Chrome\",\"exe\":\"chrome.exe\",\"title\":\"YouTube - Google Chrome\",\"monitor\":\"mon_"))
        let retina = fakeMonitor(0, "display1", nil, true, 0, 2560, 1440)
        retina.pixelSize = ISize(5120, 2880)
        retina.dpi = 192
        DeviceMatch.label([retina])
        let rj = DeviceMatch.inventoryJson("", [retina], nil, nil)
        t.equal("inventory json (macOS): pixels, scale 2, no model name = \"\"", rj,
                "{\"type\":\"devices\",\"request_id\":\"\",\"monitors\":[{\"id\":\"" + retina.id + "\",\"index\":0,\"output_idx\":0,\"name\":\"display1\","
                + "\"friendly_name\":\"\",\"primary\":true,\"x\":0,\"y\":0,\"width\":5120,\"height\":2880,\"scale\":2,\"position\":0,\"label\":\"center\"}],"
                + "\"mics\":[],\"cameras\":[],\"windows\":[]}")
    }

    static func windows(_ t: SelfTest) {
        let ms = twoMonitors()
        t.check("window output size", WindowTrack.outputSize(ISize(1280, 800)) == ISize(1280, 800)
                && WindowTrack.outputSize(ISize(2560, 1400)) == ISize(1920, 1050) && WindowTrack.outputSize(ISize(1001, 333)) == ISize(1000, 332))
        t.check("window: mostly on", WindowTrack.mostlyOn(ms, IRect(2400, 100, 800, 600)) === ms[1]
                && abs(WindowTrack.share(IRect(2400, 100, 800, 600), ms[1].bounds) - 0.8) < 1e-9 && WindowTrack.mostlyOn(ms, IRect(-900, 0, 800, 600)) == nil)
        let monR = IRect(2560, 218, 1920, 1080)
        let v0 = WindowTrack.view(IRect(2660, 318, 800, 600), false, true, monR, WindowView())
        let vPart = WindowTrack.view(IRect(4000, 318, 800, 600), false, true, monR, v0)
        let vMin = WindowTrack.view(IRect(2660, 318, 800, 600), true, true, monR, v0)
        let vMoved = WindowTrack.view(IRect(2670, 323, 800, 600), false, true, monR, v0)
        t.check("window view: monitor-relative crop", !v0.blank && v0.crop == IRect(100, 100, 800, 600))
        t.check("window view: partly off the monitor = visible part", !vPart.blank && vPart.crop == IRect(1440, 100, 480, 600))
        t.check("window view: minimized = black, crop kept", vMin.blank && vMin.crop == v0.crop)
        t.check("window view: off this monitor / closed = black", WindowTrack.view(IRect(0, 0, 800, 600), false, true, monR, v0).blank
                && WindowTrack.view(IRect(2660, 318, 800, 600), false, false, monR, v0).blank)
        t.check("window view: a move is a new crop, an unchanged window is no update", vMoved.crop == IRect(110, 105, 800, 600)
                && WindowTrack.view(IRect(2660, 318, 800, 600), false, true, monR, v0) == v0)
        t.check("video size (macOS: every display through the fit-1920x1080 rule)", WindowTrack.outputSize(ISize(3024, 1964)) == ISize(1662, 1080)
                && WindowTrack.outputSize(ISize(3840, 2160)) == ISize(1920, 1080) && WindowTrack.outputSize(ISize(1366, 768)) == ISize(1366, 768)
                && WindowTrack.outputSize(ISize(5120, 1440)) == ISize(1920, 540))
        // C# "video path: output sizes", its cpu vectors (VideoChain.Output("cpu", s) == WindowTrack.OutputSize(s), the one
        // rule every macOS recording uses; the gpu / gpu-scale paths do not exist here).
        t.check("video path: output sizes (the cpu rule)", WindowTrack.outputSize(ISize(3840, 2160)) == ISize(1920, 1080)
                && WindowTrack.outputSize(ISize(3440, 1440)) == ISize(1920, 802) && WindowTrack.outputSize(ISize(1366, 768)) == ISize(1366, 768)
                && WindowTrack.outputSize(ISize(1281, 721)) == ISize(1280, 720))
    }

    static func webcam(_ t: SelfTest) {
        // "webcam sizes" and "webcam px clamp" run with the config group (phase a).
        let screens = [IRect(0, 0, 2560, 1440), IRect(2560, 218, 1920, 1080)]
        let def = IPoint(2300, 1350)
        t.check("placement: saved spot on a connected monitor", Displays.restore(screens, 3000, 600, ISize(236, 52), def) == IPoint(3000, 600))
        t.check("placement: half off-screen is pulled inside", Displays.restore(screens, 4300, 600, ISize(236, 52), def) == IPoint(4480 - 236, 600))
        t.check("placement: unplugged monitor falls back to default", Displays.restore(screens, 6000, 600, ISize(236, 52), def) == def)
        t.check("placement: nothing saved uses default", Displays.restore(screens, nil, 5, ISize(236, 52), def) == def)
        t.check("placement: remap keeps the relative corner",
                Displays.remap(IPoint(24, 1440 - 240 - 24), ISize(240, 240), screens[0], screens[1]) == IPoint(2560 + 17, 218 + 823))

        // Bubble geometry: hard-coded expectations of the anti-aliased mask and the opaque ring.
        let side = 240
        var mask = [UInt8](repeating: 0, count: side * side)
        var ring = mask
        BubbleSurface.geometry(side, 3, &mask, &ring)
        t.check("bubble: corners transparent, centre opaque camera", mask[0] == 0 && mask[side * side - 1] == 0 && mask[120 * side + 120] == 255 && ring[120 * side + 120] == 0)
        t.check("bubble: ring opaque across its width", ring[120 * side + 1] == 255 && ring[120 * side + 2] == 255 && mask[120 * side + 1] == 255)
        t.check("bubble: edge anti-aliased", mask[120 * side + 0] > 0 && mask[120 * side + 0] < 255)
        var sym = true
        for i in 0..<(side * side) {
            let x = i % side, y = i / side
            if mask[i] != mask[y * side + (side - 1 - x)] || ring[i] != ring[(side - 1 - y) * side + x] { sym = false }
        }
        t.check("bubble: mask and ring symmetric", sym)
        t.check("bubble sizes: circle diameter / 16:9 rectangle 3/4 of the size high", WebcamSize.sizeFor(240, 96, false) == ISize(240, 240)
                && WebcamSize.sizeFor(240, 96, true) == ISize(320, 180) && WebcamSize.sizeFor(240, 192, true) == ISize(640, 360)
                && WebcamSize.sizeFor(WebcamSize.minPx, 120, true) == ISize(200, 112) && WebcamSize.sizeFor(WebcamSize.maxPx, 96, true) == ISize(640, 360))
        t.check("webcam_size percent of the monitor's short side", WebcamSize.pxForPercent(25, ISize(2560, 1440), 96, false) == 360
                && WebcamSize.pxForPercent(25, ISize(2560, 1440), 96, true) == 480 && WebcamSize.pxForPercent(25, ISize(3840, 2160), 192, false) == 270
                && WebcamSize.pxForPercent(1, ISize(1920, 1080), 96, false) == WebcamSize.minPx && WebcamSize.pxForPercent(100, ISize(1920, 1080), 96, false) == WebcamSize.maxPx)
        for rdpi in [96, 144, 192] {
            let rs = WebcamSize.sizeFor(240, rdpi, true)
            let rw = rs.width, rh = rs.height
            let ringW = WebcamSize.ringWidth(rdpi), rr = BubbleSurface.cornerRadius(rh)
            var rmask = [UInt8](repeating: 0, count: rw * rh)
            var rring = rmask
            BubbleSurface.geometry(rw, rh, ringW, true, &rmask, &rring)
            let at = " @\(rdpi * 100 / 96)% (\(rw)x\(rh))"
            t.check("rect bubble" + at + ": corners transparent, centre opaque camera", rmask[0] == 0 && rmask[rw - 1] == 0 && rmask[(rh - 1) * rw] == 0
                    && rmask[rw * rh - 1] == 0 && rmask[2 * rw + 2] == 0 && rmask[(rh / 2) * rw + rw / 2] == 255 && rring[(rh / 2) * rw + rw / 2] == 0)
            var edges = true
            var x = Int(rr) + 2
            while Float(x) < Float(rw) - rr - 2 { edges = edges && rring[1 * rw + x] == 255 && rring[(rh - 2) * rw + x] == 255 && rmask[1 * rw + x] == 255; x += 1 }
            var y = Int(rr) + 2
            while Float(y) < Float(rh) - rr - 2 { edges = edges && rring[y * rw + 1] == 255 && rring[y * rw + rw - 2] == 255; y += 1 }
            t.check("rect bubble" + at + ": ring opaque along the straight edges", edges)
            var arc = true
            for deg in stride(from: 0, through: 90, by: 5) {
                let a = Double(deg) * Double.pi / 180, rad = Double(rr) - 0.5 - Double(ringW) / 2
                let px = Int((Double(rr) - cos(a) * rad).rounded(.down)), py = Int((Double(rr) - sin(a) * rad).rounded(.down))
                arc = arc && rring[py * rw + px] >= 200 && rmask[py * rw + px] >= 200
            }
            t.check("rect bubble" + at + ": ring follows the rounded corners", arc)
            var rsym = true, aa = false
            for i in 0..<(rw * rh) {
                let x = i % rw, y = i / rw
                if rmask[i] != rmask[y * rw + (rw - 1 - x)] || rring[i] != rring[(rh - 1 - y) * rw + x] { rsym = false }
                if rmask[i] > 0 && rmask[i] < 255 { aa = true }
            }
            t.check("rect bubble" + at + ": symmetric, anti-aliased edge", rsym && aa)
        }
        var cvr = [UInt8](repeating: 0, count: side * side)
        var cring = cvr
        BubbleSurface.geometry(side, side, 3, false, &cvr, &cring)
        t.check("bubble: circle geometry unchanged by the shape refactor", cvr == mask && cring == ring)
        // Compose: placeholder colour inside, transparent corners, mirror flips the camera picture.
        let s = BubbleSurface(ISize(8, 8), 2, false)
        var src = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for yy in 0..<8 { for xx in 0..<8 { let o = (yy * 8 + xx) * 4; src[o] = UInt8(xx * 30); src[o + 1] = 0; src[o + 2] = 0; src[o + 3] = 255 } }
        src.withUnsafeBufferPointer { s.compose($0.baseAddress, ISize(8, 8), 32, false) }
        let plain = s.pixels
        src.withUnsafeBufferPointer { s.compose($0.baseAddress, ISize(8, 8), 32, true) }
        let mirrored = s.pixels
        let c = (4 * 8 + 3) * 4, cm = (4 * 8 + 4) * 4
        t.check("bubble compose (macOS BGRA): corners clear, camera inside, mirror flips", plain[3] == 0 && plain[c + 3] == 255 && plain[c] == 90
                && mirrored[c] == plain[cm] && mirrored[cm] == plain[c])
    }

    static func fakeDisplay(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ dpi: Int, _ taskbar: String) -> DisplayInfo {
        let t = Int(NetFormat.round(Double(48 * Float(dpi) / 96)))
        let b = IRect(x, y, w, h)
        let wa = taskbar == "top" ? IRect.fromLTRB(x, y + t, x + w, y + h) : taskbar == "left" ? IRect.fromLTRB(x + t, y, x + w, y + h)
            : taskbar == "right" ? IRect.fromLTRB(x, y, x + w - t, y + h) : IRect.fromLTRB(x, y, x + w, y + h - t)
        return DisplayInfo(deviceName: "\\\\.\\DISPLAY\(dpi)" + taskbar, bounds: b, workArea: wa, primary: false)
    }

    /// nil when the controls for this bubble are fully inside the monitor's work area and clear of the bubble (or the
    /// bubble leaves no room on any side: counted in crowded); else "outside" / "overlap".
    static func placementProblem(_ l: ControlLayout, _ bubble: IRect, _ d: DisplayInfo, _ crowded: inout Int) -> String? {
        let at = IRect(l.place(bubble, d.workArea), l.size)
        if !d.workArea.contains(at) || !d.bounds.contains(at) { return "outside" }
        let wa = d.workArea
        let room = wa.right - (bubble.right + l.gap) >= l.size.width || (bubble.left - l.gap) - wa.left >= l.size.width
            || wa.bottom - (bubble.bottom + l.gap) >= l.size.height || (bubble.top - l.gap) - wa.top >= l.size.height
        if !room { crowded += 1; return nil }
        return at.intersectsWith(bubble.inflated(l.gap, l.gap)) ? "overlap" : nil
    }

    static func controls(_ t: SelfTest) {
        let sizes = [WebcamSize.minPx, 180, WebcamSize.defaultPx, 300, 360, 420, WebcamSize.maxPx]
        for dpi in [96, 120, 144, 168, 192] {
            let pct = " @\(dpi * 100 / 96)%"
            let l = ControlLayout(dpi)
            let client = IRect(IPoint.zero, l.size)
            let inner = client.inflated(-l.corner / 2, -l.corner / 2)
            let visible = [l.track, l.thumb(WebcamSize.minPx), l.thumb(WebcamSize.maxPx), l.value, l.divider, l.mirrorLabel, l.toggle, l.divider2, l.shapeLabel, l.shapeSwitch]
            var inside = client.contains(l.trackHit) && client.contains(l.mirrorHit) && client.contains(l.shapeHit)
            for r in visible { inside = inside && inner.contains(r) && r.width > 0 && r.height > 0 }
            t.check("controls" + pct + ": every element inside the rounded window", inside)
            let row1 = IRect.union(IRect.union(l.track, l.thumb(WebcamSize.minPx)), IRect.union(l.thumb(WebcamSize.maxPx), l.value))
            let row2 = IRect.union(l.mirrorLabel, l.toggle)
            let apart = !row1.intersectsWith(row2) && !row1.intersectsWith(l.divider) && !row2.intersectsWith(l.divider) && row1.bottom <= l.divider.top
                && l.divider.bottom <= row2.top && !l.thumb(WebcamSize.maxPx).intersectsWith(l.value) && !l.mirrorLabel.intersectsWith(l.toggle)
                && !l.trackHit.intersectsWith(l.mirrorHit) && !l.trackHit.intersectsWith(l.value) && l.mirrorHit.contains(l.toggle) && l.mirrorHit.contains(l.mirrorLabel)
            t.check("controls" + pct + ": slider row above mirror row, no overlap (drawn or clickable)", apart)
            let row3 = IRect.union(l.shapeLabel, l.shapeSwitch)
            let apart3 = l.divider.bottom <= row2.top && row2.bottom <= l.divider2.top && l.divider2.bottom <= row3.top && !row3.intersectsWith(row2)
                && !row3.intersectsWith(row1) && !l.shapeLabel.intersectsWith(l.shapeSwitch) && !l.shapeHit.intersectsWith(l.mirrorHit)
                && !l.shapeHit.intersectsWith(l.trackHit) && l.shapeHit.contains(l.shapeSwitch) && l.shapeHit.contains(l.shapeLabel)
                && !l.circleSeg.intersectsWith(l.rectSeg) && l.shapeSwitch.contains(l.circleSeg) && l.shapeSwitch.contains(l.rectSeg)
                && l.circleSeg.width >= l.size.width / 10
            t.check("controls" + pct + ": shape row below mirror row, circle and rectangle segments apart", apart3)
            let cmid = IPoint(l.circleSeg.x + l.circleSeg.width / 2, l.circleSeg.y + l.circleSeg.height / 2)
            let rmid = IPoint(l.rectSeg.x + l.rectSeg.width / 2, l.rectSeg.y + l.rectSeg.height / 2)
            let lmid = IPoint(l.shapeLabel.x + 4, l.shapeLabel.y + l.shapeLabel.height / 2)
            t.check("controls" + pct + ": shape switch hits (segment = that shape, label = toggle)", !l.shapeFor(cmid, true) && !l.shapeFor(cmid, false)
                    && l.shapeFor(rmid, false) && l.shapeFor(rmid, true) && l.shapeFor(lmid, false) && !l.shapeFor(lmid, true))
            let step = Int((Double(WebcamSize.maxPx - WebcamSize.minPx) / Double(l.track.width)).rounded(.up))
            var map = l.valueAt(l.thumbX(WebcamSize.minPx)) == WebcamSize.minPx && l.valueAt(l.thumbX(WebcamSize.maxPx)) == WebcamSize.maxPx
                && l.valueAt(-50) == WebcamSize.minPx && l.valueAt(l.size.width + 50) == WebcamSize.maxPx
            for v in WebcamSize.minPx...WebcamSize.maxPx { map = map && abs(l.valueAt(l.thumbX(v)) - v) <= step }
            t.check("controls" + pct + ": slider maps x <-> size both ways", map)

            var cases = 0, bad = 0, crowded = 0, overlapWithRoom = 0
            for mon in [ISize(1920, 1080), ISize(2560, 1440), ISize(3840, 2160)] {
                for tb in ["bottom", "top", "left", "right"] {
                    let d = fakeDisplay(-mon.width / 2, 300, mon.width, mon.height, dpi, tb)
                    for px in sizes {
                        for rectShape in [false, true] {
                            let bs = WebcamSize.sizeFor(px, dpi, rectShape)
                            for fx in 0...2 {
                                for fy in 0...2 {
                                    let bubble = IRect(d.bounds.left + fx * (d.bounds.width - bs.width) / 2, d.bounds.top + fy * (d.bounds.height - bs.height) / 2, bs.width, bs.height)
                                    cases += 1
                                    let why = placementProblem(l, bubble, d, &crowded)
                                    if why == "overlap" { overlapWithRoom += 1 } else if why != nil { bad += 1 }
                                }
                            }
                        }
                    }
                }
            }
            t.check("controls" + pct + ": \(cases) bubble spots (both shapes), window fully inside the monitor work area", bad == 0)
            t.check("controls" + pct + ": beside the bubble whenever there is room (\(crowded) spots with no room on any side)", overlapWithRoom == 0)
        }
        let l96 = ControlLayout(96)
        let m = fakeDisplay(0, 0, 1920, 1080, 96, "bottom")
        t.check("controls placement: right of a bubble at the left edge, centred on it", l96.place(IRect(0, 400, 240, 240), m.workArea) == IPoint(250, 520 - 59))
        t.check("controls placement: flips left at the right edge", l96.place(IRect(1680, 400, 240, 240), m.workArea) == IPoint(1680 - 10 - 232, 520 - 59))
        t.check("controls placement: bottom-right corner over the taskbar = left, lifted into the work area",
                l96.place(IRect(1800, 960, 120, 120), m.workArea) == IPoint(1800 - 10 - 232, 1032 - 118))
        t.check("controls placement: beside a rectangle bubble, centred on it", l96.place(IRect(1600, 400, 320, 180), m.workArea) == IPoint(1600 - 10 - 232, 490 - 59))
        let desk = [fakeDisplay(0, 0, 2560, 1440, 96, "bottom"), fakeDisplay(2560, -300, 3840, 2160, 192, "bottom"), fakeDisplay(-1920, 400, 1920, 1080, 144, "left")]
        let deskDpi = [96, 192, 144]
        var mixed = 0, mixedBad = 0, mixedCrowded = 0
        for (i, d) in desk.enumerated() {
            let l = ControlLayout(deskDpi[i])
            for px in sizes {
                for rectShape in [false, true] {
                    let bs = WebcamSize.sizeFor(px, deskDpi[i], rectShape)
                    for fx in 0...2 {
                        for fy in 0...2 {
                            let bubble = IRect(d.bounds.left + fx * (d.bounds.width - bs.width) / 2, d.bounds.top + fy * (d.bounds.height - bs.height) / 2, bs.width, bs.height)
                            mixed += 1
                            if Displays.nearest(desk, Displays.center(bubble)) != d || placementProblem(l, bubble, d, &mixedCrowded) != nil { mixedBad += 1; continue }
                            let at = IRect(l.place(bubble, d.workArea), l.size)
                            for o in desk where o != d && o.bounds.intersectsWith(at) { mixedBad += 1 }
                        }
                    }
                }
            }
        }
        t.check("controls placement, mixed DPI (100/200/150 %): \(mixed) spots on the bubble's own monitor, sized for it, beside the bubble",
                mixedBad == 0 && mixedCrowded == 0)
        t.check("controls: texts and value format", ControlLayout.mirrorText == "Mirror" && ControlLayout.shapeText == "Shape"
                && ControlLayout.valueText(240) == "240 px" && ControlLayout.w == 232 && ControlLayout.h == 118)

        let g = ClickGesture()
        g.down(IPoint(1000, 500))
        let c3 = g.up(IPoint(1004, 500))
        t.check("stop: exactly 4 px is a drag", !c3 && g.dragging)
        g.down(IPoint(1000, 500))
        let c4 = g.up(IPoint(1003, 502))
        t.check("stop: 3.6 px is still a click", c4 && !g.dragging)
        g.down(IPoint(1000, 500)); g.move(IPoint(1040, 520)); g.move(IPoint(1001, 500))
        let c2 = g.up(IPoint(1000, 500))
        t.check("gesture: drag away and back is never a click", !c2 && g.dragging)
        t.check("gesture: move without press is not a drag", !ClickGesture().move(IPoint(50, 50)))
    }

    static func trimIs(_ r: (trim: Double, capped: Bool), _ trim: Double, _ capped: Bool) -> Bool { return r.trim == trim && r.capped == capped }

    static func near(_ s: Span, _ a: Double, _ b: Double) -> Bool { return abs(s.start - a) < 1e-6 && abs(s.end - b) < 1e-6 }
    static func op(_ o: AudioMath.SliceOp, _ delay: Int64, _ start: Double, _ dur: Double) -> Bool {
        return o.delayMs == delay && abs(o.start - start) < 1e-6 && abs(o.duration - dur) < 1e-6
    }

    static func audio(_ t: SelfTest) {
        let ml = MuteLog()
        t.check("mute log: toggles", ml.set(true, 2) && !ml.set(true, 3) && ml.muted && ml.set(false, 5) && !ml.muted && ml.set(true, 8))
        let sp = ml.allSpans()
        t.check("mute log: closed + open span", sp.count == 2 && sp[0].start == 2 && sp[0].end == 5 && sp[1].start == 8 && sp[1].end == .infinity)
        var rs = AudioMath.mutedRanges([Span(1, 2)], 47000, 2000, 48000)
        t.check("muted frames: span start inside a block", rs.count == 1 && rs[0].0 == 1000 && rs[0].1 == 1000)
        rs = AudioMath.mutedRanges([Span(1, 1.5), Span(1.25, 2), Span(0, 0)], 0, 200000, 48000)
        t.check("muted frames: overlapping spans merge, empty ones vanish", rs.count == 1 && rs[0].0 == 48000 && rs[0].1 == 48000)
        rs = AudioMath.mutedRanges([Span(3, .infinity)], 144000 - 10, 100, 48000)
        t.check("muted frames: open span mutes to the end", rs.count == 1 && rs[0].0 == 10 && rs[0].1 == 90 && AudioMath.mutedRanges(sp, 0, 1000, 48000).isEmpty)
        let segs = [Segment(100, 10), Segment(112, 5)]
        let tl = AudioMath.toTimeline([Span(105, 106), Span(109.5, 113), Span(116, .infinity)], segs, 0, 0)
        t.check("timeline: spans map through joined segments, gaps dropped", tl.count == 3 && near(tl[0], 5, 6) && near(tl[1], 9.5, 11) && near(tl[2], 14, 15))
        let padded = AudioMath.toTimeline([Span(105, 106)], segs, 0.1, 0.05)
        t.check("timeline: padding, clamped to the segment", near(padded[0], 4.9, 6.05) && near(AudioMath.toTimeline([Span(99, 100.5)], segs, 0.1, 0)[0], 0, 0.5))
        let slices = AudioMath.slices(segs, 99.25)
        t.check("wav slices per segment", slices.count == 2 && near(slices[0], 0.75, 10.75) && near(slices[1], 12.75, 17.75))
        // The mix plan: the same slices MixFilter turns into atrim/adelay.
        let both = AudioMath.sliceOps([Span(0.5, 10.5)]), sysBoth = AudioMath.sliceOps([Span(0.75, 10.75)])
        t.check("mix plan: mic + system (atrim=start=0.5:duration=10, atrim=start=0.75:duration=10, system 0.6 under the mic)",
                op(both[0], 0, 0.5, 10) && op(sysBoth[0], 0, 0.75, 10)
                && MixPlan(micMuted: [], micSlices: both, sysSlices: sysBoth).sysGain == 0.6 && MixPlan(micMuted: [], micSlices: nil, sysSlices: sysBoth).sysGain == 1)
        let two = AudioMath.sliceOps(slices)
        t.check("mix plan: system only, two segments joined, full gain", two.count == 2 && op(two[0], 0, 0.75, 10) && op(two[1], 0, 12.75, 5))
        t.check("mix plan: late system audio or mic is delayed", op(AudioMath.sliceOps([Span(-0.25, 9.75)])[0], 250, 0, 10)
                && op(AudioMath.sliceOps([Span(-0.1, 9.9)])[0], 100, 0, 10))
        t.check("mix plan: cut times as the filter writes them (\"0.###\", half away from zero)",
                op(AudioMath.sliceOps([Span(0.12345, 10.12345)])[0], 0, 0.123, 10) && AudioMath.filterValue(0.0005) == 0.001
                && AudioMath.filterValue(2.0004) == 2 && AudioMath.filterValue(.infinity) == .infinity)
        let micOnly = MixPlan(micMuted: [], micSlices: AudioMath.sliceOps([Span(0.25, 8.25)]), sysSlices: nil)
        t.check("mix plan: mic only, nothing muted (atrim=start=0.25:duration=8, no system input)", micOnly.micSlices?.count == 1
                && op(micOnly.micSlices![0], 0, 0.25, 8) && micOnly.micMuted.isEmpty && micOnly.sysSlices == nil)
        let micTwo = AudioMath.sliceOps(slices)
        t.check("mix plan: mic over two segments, joined (atrim 0.75+10, 12.75+5; muting on the video timeline: \"mix: …\")",
                micTwo.count == 2 && op(micTwo[0], 0, 0.75, 10) && op(micTwo[1], 0, 12.75, 5))

        // Late mic (the 2026-11-16 10-minute run: mic t0 235 ms after the video's): the video is trimmed to a keyframe,
        // the mic is not delayed, and the output does not open with padded silence. Keyframes: every 3rd frame for 2 s at
        // 30 fps (VideoChain.EarlyKeys), then the GOP's: 0, 0.1, ..., 1.9, 2.0.
        // The C# framecrc fixture: 70 frames at 30 fps (pts n*512 in 1/15360), forced keys per EarlyKeys, then the GOP's at 2 s.
        let every30 = EarlyKeys.every(30)
        let keys = (0..<70).compactMap { n -> Double? in
            let t = Double(n * 512) / 15360.0
            return EarlyKeys.forced(n, t, every30) || n == 60 ? t : nil
        }
        t.check("early keyframes: every 3rd frame for 2 s at 30 fps", keys.count == 21 && keys[0] == 0 && abs(keys[1] - 0.1) < 1e-9 && abs(keys[3] - 0.3) < 1e-9
                && abs(keys[20] - 2.0) < 1e-9 && EarlyKeys.every(30) == 3 && EarlyKeys.every(60) == 6 && EarlyKeys.every(5) == 1)
        let vT0 = 1000.0, micT0 = 1000.235
        let longSegs = [Segment(vT0, 600.0)]
        let r235 = AudioMath.startTrim(vT0, micT0, keys)
        let trimmed = AudioMath.trimStart(longSegs, r235.trim)
        let lateOps = AudioMath.sliceOps(AudioMath.slices(trimmed, micT0))
        t.check("late mic 235 ms: video trimmed to the keyframe at 0.3 s, mic cut 65 ms in (not delayed)", abs(r235.trim - 0.3) < 1e-9 && !r235.capped
                && trimmed.count == 1 && abs(trimmed[0].wallStart - 1000.3) < 1e-9 && abs(trimmed[0].duration - 599.7) < 1e-9
                && lateOps[0].delayMs == 0 && abs(lateOps[0].start - 0.065) < 1e-6 && abs(lateOps[0].duration - 599.7) < 1e-6)
        let untrimmed = AudioMath.slices(longSegs, micT0)
        t.check("late mic 235 ms: the output does not open with padded silence (untrimmed it would: " + NetFormat.fixed(untrimmed[0].start * 1000, 0) + " ms)",
                !lateOps.contains { $0.delayMs > 0 } && untrimmed[0].start < 0)
        t.check("start trim: none when the mic starts first or there is none, the keyframe itself when exact, 0 without keyframes (capped)",
                trimIs(AudioMath.startTrim(vT0, vT0 - 0.2, keys), 0, false) && trimIs(AudioMath.startTrim(vT0, vT0, keys), 0, false)
                && trimIs(AudioMath.startTrim(vT0, .nan, keys), 0, false) && trimIs(AudioMath.startTrim(vT0, vT0 + 0.3, keys), 0.3, false)
                && trimIs(AudioMath.startTrim(vT0, vT0 + 0.2, []), 0, true))

        // Every source sliced on the trimmed timeline (a late one delayed): duration_s, the AAC track and the
        // transcription WAV are all the trimmed length.
        func onTrimmed(_ untrimmedSegs: [Segment], _ trim: Double, _ cut: [Segment], _ ops: [[AudioMath.SliceOp]]) -> Bool {
            let len = AudioMath.length(cut)
            let sum = ops.flatMap { $0 }.reduce(0.0) { $0 + $1.duration }
            return abs(len - (AudioMath.length(untrimmedSegs) - trim)) < 1e-6 && abs(sum - Double(ops.count) * len) < 1e-3
        }
        let rA = AudioMath.startTrim(vT0, vT0 + 0.23, keys)
        let segsA = AudioMath.trimStart(longSegs, rA.trim)
        let micA = AudioMath.sliceOps(AudioMath.slices(segsA, vT0 + 0.23)), sysA = AudioMath.sliceOps(AudioMath.slices(segsA, vT0 + 3.0))
        t.check("late system audio 3 s + mic 230 ms: 300 ms trim, mic cut 70 ms in, system audio delayed 2.7 s", abs(rA.trim - 0.3) < 1e-9 && !rA.capped
                && op(micA[0], 0, 0.07, 599.7) && op(sysA[0], 2700, 0, 599.7) && onTrimmed(longSegs, rA.trim, segsA, [micA, sysA]))
        let rB = AudioMath.startTrim(vT0, .nan, keys)
        let segsB = AudioMath.trimStart(longSegs, rB.trim)
        let sysB = AudioMath.sliceOps(AudioMath.slices(segsB, vT0 + 3.0))
        let twoSegs = [Segment(vT0, 2), Segment(vT0 + 5, 10)]
        let sysB2 = AudioMath.sliceOps(AudioMath.slices(twoSegs, vT0 + 3.0))
        t.check("late system audio only 3 s: no trim, delayed 3 s (a segment before it all silence)", rB.trim == 0 && !rB.capped
                && op(sysB[0], 3000, 0, 600) && onTrimmed(longSegs, rB.trim, segsB, [sysB])
                && op(sysB2[0], 3000, 0, 2) && op(sysB2[1], 0, 2, 10) && onTrimmed(twoSegs, 0, twoSegs, [sysB2]))
        let rC = AudioMath.startTrim(vT0, vT0 + 1.2, keys)
        let segsC = AudioMath.trimStart(longSegs, rC.trim)
        let micC = AudioMath.sliceOps(AudioMath.slices(segsC, vT0 + 1.2))
        t.check("late mic 1.2 s: trim capped at 500 ms, mic delayed 700 ms", rC.capped && rC.trim <= AudioMath.maxTrim && abs(rC.trim - 0.5) < 1e-9
                && op(micC[0], 700, 0, 599.5) && onTrimmed(longSegs, rC.trim, segsC, [micC]))
        t.check("late mic 235 ms: duration_s and the WAV on the trimmed timeline (599.7 s)", onTrimmed(longSegs, r235.trim, trimmed, [lateOps]))
        let twoCut = AudioMath.trimStart([Segment(100, 0.2), Segment(112, 5)], 0.5)
        t.check("start trim: a short first segment is dropped, the rest cut", twoCut.count == 1 && abs(twoCut[0].wallStart - 112.3) < 1e-9
                && abs(twoCut[0].duration - 4.7) < 1e-9)

        let tg = Toggles.parse("sys@6.5, mic@5,bogus@1,mic@-1,mic@x")
        t.check("--toggle parsing", tg.count == 2 && tg[0].0 == "mic" && tg[0].1 == 5 && tg[1].0 == "sys" && tg[1].1 == 6.5)

        let st = StartTimes(10.0)
        st.mark("t_pill", 10.012)
        st.mark("t_pill", 10.5)
        st.mark("t_first_frame", 10.4004)
        t.equal("start timing line: first mark wins, missing steps are -", st.line(),
                "t_cmd=0 t_pill=12 t_encoder=- t_ffmpeg_launch=- t_first_frame=400 t_started=- t_bubble=-")
        t.check("number formats (invariant, .NET custom formats)", NetFormat.upTo(2.0, 2) == "2" && NetFormat.upTo(1.25, 2) == "1.25"
                && NetFormat.upTo(0.065, 3) == "0.065" && NetFormat.fixed(599.7, 3) == "599.700" && NetFormat.fixed(235.4, 0) == "235"
                && NetFormat.fixed(-1.5, 1) == "-1.5" && NetFormat.upTo(1.0 / 3, 3) == "0.333" && Span(0.5, 10).description == "0.500-10.000")
    }

    static func tempPath(_ ext: String) -> String {
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("agent-recorder-selftest-" + UUID().uuidString + ext)
    }

    /// The system audio timeline without a device: silence fill, packets placed by timestamp, another sample rate (a
    /// device switch on Windows), a late packet overlapping what is already written, and a muted span.
    static func wav(_ t: SelfTest) {
        let path = tempPath(".wav")
        defer { try? FileManager.default.removeItem(atPath: path) }
        func tone(_ n: Int) -> [Float] { return [Float](repeating: 0.5, count: n * 2) }
        let lc = PcmTimeline(path: path)
        do {
            try lc.open(start: 100.0)
            lc.padTo(100.5)                                                   // nothing playing: frames 0-24000 silence
            lc.place(tone(4800), frames: 4800, srcRate: 48000, at: 100.5)   // 24000-28800 tone
            lc.place(tone(4800), frames: 4800, srcRate: 48000, at: 100.6)   // 28800-33600 tone (continuous)
            lc.place(tone(4410), frames: 4410, srcRate: 44100, at: 101.0)   // 44.1 kHz: gap 33600-48000 silence, then tone
            lc.place(tone(4410), frames: 4410, srcRate: 44100, at: 101.05)  // late: overlaps by 0.05 s, only the new part
            lc.mutes.set(true, 1.2)
            lc.mutes.set(false, 1.3)
            lc.place(tone(9600), frames: 9600, srcRate: 48000, at: 101.2)   // 57600-67200: muted until 62400, then tone
            try lc.finish()
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            func i32(_ o: Int) -> Int { return Int(Int32(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24)) }
            func i16(_ o: Int) -> Int { return Int(Int16(bitPattern: UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8)) }
            func l(_ frame: Int) -> Int { return 44 + frame * 4 + 1 < bytes.count ? i16(44 + frame * 4) : Int.min }
            let dataLen = i32(40)
            let header = String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF" && i32(4) == bytes.count - 8 && dataLen == bytes.count - 44
                && i16(22) == 2 && i32(24) == 48000
            t.check("system audio wav: header, continuous 67200 frames", header && dataLen / 4 == 67200)
            t.check("system audio wav: silence until the first packet, packet at its timestamp", l(0) == 0 && l(23999) == 0 && l(24000) == 16384 && l(33599) == 16384)
            t.check("system audio wav: device switch gap is silence, 44.1 kHz resampled in place", l(33600) == 0 && l(47999) == 0 && l(48000) == 16384 && l(55000) == 16384)
            t.check("system audio wav: late overlapping packet trimmed, not shifted", lc.seconds > 1.39 && lc.seconds < 1.41 && l(56000) == 0 && l(57599) == 0)
            var mutedZero = true
            for i in 57600..<62400 { mutedZero = mutedZero && l(i) == 0 }
            t.check("system audio wav: muted span written as zeros, sound resumes after it", mutedZero && l(62400) == 16384 && l(67199) == 16384)
        } catch {
            t.check("system audio wav", false, Config.message(error))
        }
    }

    /// The native mix on small WAVs: mute blocks, a delayed slice, gains, the 16 kHz copy (the mic only).
    static func mix(_ t: SelfTest) {
        let micPath = tempPath(".mic.wav"), sysPath = tempPath(".sys.wav")
        defer { try? FileManager.default.removeItem(atPath: micPath); try? FileManager.default.removeItem(atPath: sysPath) }
        do {
            let mic = PcmTimeline(path: micPath, rate: 48000, channels: 1)
            try mic.open(start: 0)
            mic.place([Float](repeating: 0.25, count: 48000), frames: 48000, srcRate: 48000, at: 0)
            try mic.finish()
            let sys = PcmTimeline(path: sysPath, rate: 48000, channels: 2)
            try sys.open(start: 0)
            sys.place([Float](repeating: 0.5, count: 96000), frames: 48000, srcRate: 48000, at: 0)
            try sys.finish()
            func all(_ m: AudioMixer) -> [Float] { var o: [Float] = []; while let b = m.next(1000) { o += b }; return o }

            let muted = all(try AudioMixer(plan: MixPlan(micMuted: [Span(0.5, 0.6)], micSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)], sysSlices: nil),
                                           micWav: micPath, sysWav: nil))
            var zero = true
            for f in 24000..<29280 { zero = zero && muted[2 * f] == 0 && muted[2 * f + 1] == 0 }
            t.check("mix: mic to stereo, 10 ms blocks from t=0.5 through the one starting at 0.6 silenced", muted.count == 96000 && muted[0] == 0.25 && muted[1] == 0.25
                    && muted[2 * 23999] == 0.25 && zero && muted[2 * 29280] == 0.25)
            let late = all(try AudioMixer(plan: MixPlan(micMuted: [], micSlices: [AudioMath.SliceOp(delayMs: 250, start: 0, duration: 1)], sysSlices: nil),
                                          micWav: micPath, sysWav: nil))
            t.check("mix: a late mic is delayed with leading silence, the slice keeps its length", late.count == 96000 && late[2 * 11999] == 0 && late[2 * 12000] == 0.25)
            let sysOnly = all(try AudioMixer(plan: MixPlan(micMuted: [], micSlices: nil, sysSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)]),
                                             micWav: nil, sysWav: sysPath))
            t.check("mix: system audio alone at full gain", sysOnly.count == 96000 && sysOnly[0] == 0.5 && sysOnly[95999] == 0.5)
            let silentMic = [Float](repeating: 0, count: 48000)
            let quietPath = tempPath(".quiet.wav")
            defer { try? FileManager.default.removeItem(atPath: quietPath) }
            let quiet = PcmTimeline(path: quietPath, rate: 48000, channels: 1)
            try quiet.open(start: 0)
            quiet.place(silentMic, frames: 48000, srcRate: 48000, at: 0)
            try quiet.finish()
            let under = all(try AudioMixer(plan: MixPlan(micMuted: [], micSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)],
                                                         sysSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)]), micWav: quietPath, sysWav: sysPath))
            t.check("mix: system audio at 0.6 under a silent mic (no ducking, no limiting)", under.count == 96000 && abs(under[1000] - 0.3) < 1e-6 && abs(under[95000] - 0.3) < 1e-6)
            let loud = all(try AudioMixer(plan: MixPlan(micMuted: [], micSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)],
                                                        sysSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)]), micWav: micPath, sysWav: sysPath))
            t.check("mix: a talking mic ducks the system audio, the sum stays under the limit", loud.count == 96000 && loud[48000] < 0.25 + 0.3 && loud[48000] > 0.25
                    && loud.allSatisfy { abs($0) <= 0.97 })
            let down = Downsampler16k().process([Float](repeating: 0.25, count: 9600))
            t.check("mix: 16 kHz mono downsampler (aresample=16000, -ac 1)", down.count == 1600 && abs(Int(down[800]) - 8192) <= 2)
            // Transcripts are mic-only: the copy of a mic + system mix is the mic alone (0.25 -> 8192), not the mix
            // (0.25 + the ducked 0.3); taking it does not change the mix itself (the same samples as `loud`).
            let both = try AudioMixer(plan: MixPlan(micMuted: [], micSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)],
                                                    sysSlices: [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 1)]), micWav: micPath, sysWav: sysPath)
            let ds = Downsampler16k()
            var copy: [Int16] = [], mixed: [Float] = []
            while let b = both.next(1000) { mixed += b; copy += ds.process(both.takeTranscription()) }
            copy += ds.process(both.takeTranscription())
            t.check("mix: 16 kHz mono transcription copy is the mic only (split off before the system mix; the mix unchanged)",
                    both.transcribes && copy.count == 16000 && abs(Int(copy[8000]) - 8192) <= 2 && mixed == loud)
        } catch {
            t.check("mix", false, Config.message(error))
        }
    }

    /// Transcripts are mic-only, on the native mixer: a 440 Hz mic and a 1000 Hz system tone mixed; the 16 kHz copy has
    /// the mic tone, ~none of the system tone, and is silent while the mic is muted, while the mix still has both. System
    /// audio alone: no transcription copy at all (AudioMux then writes no WAV).
    static func transcript(_ t: SelfTest) {
        let micPath = tempPath(".mic.wav"), sysPath = tempPath(".sys.wav")
        defer { try? FileManager.default.removeItem(atPath: micPath); try? FileManager.default.removeItem(atPath: sysPath) }
        func sine(_ hz: Double, _ channels: Int) -> [Float] {
            var s = [Float](repeating: 0, count: 96000 * channels)
            for i in 0..<96000 {
                let v = Float(0.3 * sin(2 * Double.pi * hz * Double(i) / 48000))
                for c in 0..<channels { s[i * channels + c] = v }
            }
            return s
        }
        do {
            let mic = PcmTimeline(path: micPath, rate: 48000, channels: 1)
            try mic.open(start: 0)
            mic.place(sine(440, 1), frames: 96000, srcRate: 48000, at: 0)
            try mic.finish()
            let sys = PcmTimeline(path: sysPath, rate: 48000, channels: 2)
            try sys.open(start: 0)
            sys.place(sine(1000, 2), frames: 96000, srcRate: 48000, at: 0)
            try sys.finish()
            let whole = [AudioMath.SliceOp(delayMs: 0, start: 0, duration: 2)]
            let m = try AudioMixer(plan: MixPlan(micMuted: [Span(1.0, 1.5)], micSlices: whole, sysSlices: whole), micWav: micPath, sysWav: sysPath)
            let ds = Downsampler16k()
            var copy: [Int16] = [], mixed: [Float] = []
            while let b = m.next(1024) { mixed += b; copy += ds.process(m.takeTranscription()) }
            copy += ds.process(m.takeTranscription())
            let c = copy.map { Float($0) / 32768 }
            let micAmp = goertzel(c, 1, 16000, 440, 0.2, 0.9), sysAmp = goertzel(c, 1, 16000, 1000, 0.2, 0.9)
            let mixSys = goertzel(mixed, 2, 48000, 1000, 0.2, 0.9), muted = rmsOf(c, 16000, 1.1, 1.4)
            var detail = "mic tone " + NetFormat.fixed(micAmp, 3) + ", system tone " + NetFormat.fixed(sysAmp, 5)
            detail += " (in the mix " + NetFormat.fixed(mixSys, 3) + "), muted rms " + NetFormat.fixed(muted, 5) + ", " + String(copy.count) + " samples"
            t.check("transcript (mic + system): 16 kHz copy has the mic tone, ~none of the system tone, silent while muted",
                    copy.count == 32000 && micAmp > 0.25 && micAmp < 0.35 && sysAmp < 0.001 && mixSys > 0.02 && muted < 0.001, detail)
            let sysOnly = try AudioMixer(plan: MixPlan(micMuted: [], micSlices: nil, sysSlices: whole), micWav: nil, sysWav: sysPath)
            var tapped = 0, frames = 0
            while let b = sysOnly.next(1024) { frames += b.count / 2; tapped += sysOnly.takeTranscription().count }
            t.check("transcript (system only): no transcription copy (no WAV), the mix is the system audio",
                    !sysOnly.transcribes && tapped == 0 && frames == 96000)
        } catch {
            t.check("transcript", false, Config.message(error))
        }
    }

    /// Amplitude (0..1) of a sine at hz in [from, to) seconds of channel 0 (Goertzel).
    static func goertzel(_ s: [Float], _ channels: Int, _ rate: Int, _ hz: Double, _ from: Double, _ to: Double) -> Double {
        let a = Int(from * Double(rate)), b = min(Int(to * Double(rate)), s.count / channels)
        if b <= a { return 0 }
        let w = 2 * Double.pi * hz / Double(rate), k = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in a..<b {
            let s0 = Double(s[i * channels]) + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        let re = s1 - s2 * cos(w), im = s2 * sin(w)
        return 2 * (re * re + im * im).squareRoot() / Double(b - a)
    }

    static func rmsOf(_ s: [Float], _ rate: Int, _ from: Double, _ to: Double) -> Double {
        let a = Int(from * Double(rate)), b = min(Int(to * Double(rate)), s.count)
        if b <= a { return 0 }
        var sum = 0.0
        for i in a..<b { sum += Double(s[i]) * Double(s[i]) }
        return (sum / Double(b - a)).squareRoot()
    }
}
