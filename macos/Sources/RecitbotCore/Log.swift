import Foundation

/// agent.log in the data dir. One line per event: the UTC time in .NET round-trip form ("o":
/// 2026-11-16T16:40:00.1234567Z), a space, the message. Deleted and started again once it is over 1 MiB.
/// parity: AgentRecorder.cs Log (same format and rotation; line break is "\n" on macOS instead of "\r\n").
public enum Log {
    private static let gate = NSLock()
    private static var path: String?

    public static var pathName: String? {
        get { gate.lock(); defer { gate.unlock() }; return path }
        set { gate.lock(); path = newValue; gate.unlock() }
    }

    // Never pass secrets here. Tokens/keys/codes/links are never formatted into messages.
    public static func write(_ msg: String) {
        gate.lock()
        defer { gate.unlock() }
        guard let p = path else { return }
        var st = stat()
        if stat(p, &st) == 0 && st.st_size > 1024 * 1024 { unlink(p) }
        try? SecureFile.append(p, timestamp(Date()) + " " + msg + "\n")
    }

    /// DateTime.UtcNow.ToString("o"): yyyy-MM-ddTHH:mm:ss.fffffffZ (7 fractional digits, 100 ns ticks).
    public static func timestamp(_ d: Date) -> String {
        let t = d.timeIntervalSince1970
        var secs = time_t(floor(t))
        var ticks = Int((t - floor(t)) * 10_000_000)
        if ticks >= 10_000_000 { ticks = 9_999_999 }
        var tmv = tm()
        gmtime_r(&secs, &tmv)
        return String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%07ldZ", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1,
                      Int(tmv.tm_mday), Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec), ticks)
    }
}

/// Monotonic seconds (Stopwatch.GetTimestamp / Frequency). Mach host time (CLOCK_UPTIME_RAW), the clock CoreMedia
/// sample buffers use, so phase (b) can compare capture timestamps against it. parity: AgentRecorder.cs Clock.Now
public enum Clock {
    public static func now() -> Double {
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }
}
