import Foundation

/// .NET parsing/trimming semantics the C# relies on, so the same inputs give the same results on both platforms.
public enum NetParse {
    /// .NET NumberStyles.Integer white space: U+0009..U+000D and U+0020.
    static func isNumberWhite(_ u: UInt16) -> Bool { return u == 0x20 || (u >= 0x09 && u <= 0x0D) }

    /// int.TryParse / long.TryParse (NumberStyles.Integer, invariant): optional leading/trailing white space, an optional
    /// leading sign, ASCII digits only, nil on overflow or anything else.
    public static func int64(_ s: String?) -> Int64? {
        guard let s = s else { return nil }
        var u = Array(s.utf16)
        while let f = u.first, isNumberWhite(f) { u.removeFirst() }
        while let l = u.last, isNumberWhite(l) { u.removeLast() }
        var neg = false
        if let f = u.first, f == 0x2B || f == 0x2D { neg = f == 0x2D; u.removeFirst() }
        if u.isEmpty { return nil }
        var v: Int64 = 0
        for c in u {
            guard c >= 0x30 && c <= 0x39 else { return nil }
            let d = Int64(c - 0x30)
            let (m, o1) = v.multipliedReportingOverflow(by: 10)
            if o1 { return nil }
            let (n, o2) = neg ? m.subtractingReportingOverflow(d) : m.addingReportingOverflow(d)
            if o2 { return nil }
            v = n
        }
        return v
    }

    /// int.TryParse (32-bit range).
    public static func int32(_ s: String?) -> Int? {
        guard let v = int64(s), v >= Int64(Int32.min), v <= Int64(Int32.max) else { return nil }
        return Int(v)
    }

    /// string.Trim(): strips Unicode white space (char.IsWhiteSpace) from both ends.
    public static func trim(_ s: String) -> String {
        let u = Array(s.utf16)
        var a = 0, b = u.count
        while a < b && isWhiteSpace(u[a]) { a += 1 }
        while b > a && isWhiteSpace(u[b - 1]) { b -= 1 }
        return String(decoding: u[a..<b], as: UTF16.self)
    }

    /// char.IsWhiteSpace for one UTF-16 code unit.
    public static func isWhiteSpace(_ c: UInt16) -> Bool {
        if c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0x85 || c == 0xA0 { return true }
        if c < 0x100 { return false }
        guard let sc = Unicode.Scalar(c) else { return false } // surrogates are never white space
        return sc.properties.isWhitespace
    }

    /// ToLowerInvariant for the ASCII values these settings use (non-ASCII stays as Foundation lowercases it).
    public static func lowerInvariant(_ s: String) -> String { return s.lowercased(with: Locale(identifier: "en_US_POSIX")) }
}
