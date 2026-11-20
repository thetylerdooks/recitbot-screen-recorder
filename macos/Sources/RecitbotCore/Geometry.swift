import Foundation

// System.Drawing.Point / Size / Rectangle with the same integer semantics: top-left origin, y down, Right/Bottom
// exclusive. On macOS every screen rectangle in the recorder is in global display points with that orientation (the
// CoreGraphics display space: origin at the top-left of the main display), the counterpart of the Windows virtual
// desktop in physical pixels. AppKit's bottom-left frames are converted at the window edge only (ScreenSpace).

public struct IPoint: Equatable, Sendable, CustomStringConvertible {
    public var x: Int, y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    public static let zero = IPoint(0, 0)
    public var description: String { return "{X=\(x),Y=\(y)}" }
}

public struct ISize: Equatable, Sendable, CustomStringConvertible {
    public var width: Int, height: Int
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    public var description: String { return "{Width=\(width), Height=\(height)}" }
}

public struct IRect: Equatable, Sendable, CustomStringConvertible {
    public var x: Int, y: Int, width: Int, height: Int
    public init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    public init(_ p: IPoint, _ s: ISize) { self.init(p.x, p.y, s.width, s.height) }
    public static let empty = IRect(0, 0, 0, 0)

    public static func fromLTRB(_ l: Int, _ t: Int, _ r: Int, _ b: Int) -> IRect { return IRect(l, t, r - l, b - t) }

    public var left: Int { return x }
    public var top: Int { return y }
    public var right: Int { return x + width }
    public var bottom: Int { return y + height }
    public var location: IPoint { return IPoint(x, y) }
    public var size: ISize { return ISize(width, height) }

    public func contains(_ p: IPoint) -> Bool { return x <= p.x && p.x < x + width && y <= p.y && p.y < y + height }
    public func contains(_ px: Int, _ py: Int) -> Bool { return contains(IPoint(px, py)) }
    public func contains(_ r: IRect) -> Bool { return x <= r.x && r.x + r.width <= x + width && y <= r.y && r.y + r.height <= y + height }

    /// Rectangle.Intersect: the overlap, or Empty.
    public static func intersect(_ a: IRect, _ b: IRect) -> IRect {
        let x1 = max(a.x, b.x), x2 = min(a.right, b.right), y1 = max(a.y, b.y), y2 = min(a.bottom, b.bottom)
        return x2 >= x1 && y2 >= y1 ? IRect(x1, y1, x2 - x1, y2 - y1) : .empty
    }

    public static func union(_ a: IRect, _ b: IRect) -> IRect {
        return fromLTRB(min(a.x, b.x), min(a.y, b.y), max(a.right, b.right), max(a.bottom, b.bottom))
    }

    public func intersectsWith(_ r: IRect) -> Bool { return r.x < right && x < r.right && r.y < bottom && y < r.bottom }

    public func offsetBy(_ dx: Int, _ dy: Int) -> IRect { return IRect(x + dx, y + dy, width, height) }

    /// Rectangle.Inflate(r, dx, dy).
    public func inflated(_ dx: Int, _ dy: Int) -> IRect { return IRect(x - dx, y - dy, width + 2 * dx, height + 2 * dy) }

    public var description: String { return "{X=\(x),Y=\(y),Width=\(width),Height=\(height)}" }
}

/// .NET number formatting the C# log lines and reports use, invariant culture.
public enum NetFormat {
    /// double.ToString("0.##") / ("0.###"): at most `decimals` fraction digits, trailing zeros dropped. Like .NET
    /// Framework it rounds the 15-significant-digit value half away from zero.
    public static func upTo(_ v: Double, _ decimals: Int) -> String {
        return format(v, decimals, trim: true)
    }

    /// double.ToString("0.000") / ("0.0") / ("0"): exactly `decimals` fraction digits.
    public static func fixed(_ v: Double, _ decimals: Int) -> String {
        return format(v, decimals, trim: false)
    }

    static func format(_ v: Double, _ decimals: Int, trim: Bool) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "Infinity" : "-Infinity" }
        var d = Decimal(string: String(format: "%.15g", v), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(v)
        var r = Decimal()
        NSDecimalRound(&r, &d, decimals, .plain)
        var s = NSDecimalNumber(decimal: r).description(withLocale: Locale(identifier: "en_US_POSIX"))
        if s.hasPrefix("-") && r.isZero { s.removeFirst() }
        var neg = false
        if s.hasPrefix("-") { neg = true; s.removeFirst() }
        var intPart = s, frac = ""
        if let dot = s.firstIndex(of: ".") { intPart = String(s[..<dot]); frac = String(s[s.index(after: dot)...]) }
        if trim {
            while frac.hasSuffix("0") { frac.removeLast() }
        } else {
            while frac.count < decimals { frac += "0" }
            if frac.count > decimals { frac = String(frac.prefix(decimals)) }
        }
        return (neg ? "-" : "") + intPart + (frac.isEmpty ? "" : "." + frac)
    }

    /// Math.Round(double): to nearest, ties to even (the C# default).
    public static func round(_ v: Double) -> Double { return v.rounded(.toNearestOrEven) }
}
