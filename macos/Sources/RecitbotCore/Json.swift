import Foundation

/// A flat JSON object as Json.ParseFlat returns it: every value as its raw text (strings unescaped, numbers and booleans
/// as written), JSON null as nil. `f[k] == nil` = key absent; `f[k] == .some(nil)` = key present with null.
public typealias JsonFields = [String: String?]

public struct JsonFormatError: Error, CustomStringConvertible {
    public let description: String
    init(_ s: String) { description = s }
}

/// Minimal flat JSON object reader/writer (strings, numbers, booleans, null).
/// parity: AgentRecorder.cs Json (same grammar, same failures; works on UTF-16 code units like the C# string).
public enum Json {
    public static func parseFlat(_ text: String) throws -> JsonFields {
        let s = Array(text.utf16)
        var d = JsonFields()
        var i = 0
        ws(s, &i)
        try expect(s, &i, 0x7B) // {
        ws(s, &i)
        if try peek(s, i) == 0x7D { return d }
        while true {
            ws(s, &i)
            let k = try str(s, &i)
            ws(s, &i)
            try expect(s, &i, 0x3A) // :
            ws(s, &i)
            let v: String?
            if try peek(s, i) == 0x22 { v = try str(s, &i) }
            else {
                let st = i
                while i < s.count && !isRawStop(s[i]) { i += 1 }
                let raw = String(decoding: s[st..<i], as: UTF16.self)
                if raw.isEmpty || s[st] == 0x7B || s[st] == 0x5B { throw JsonFormatError("nested json") }
                v = raw == "null" ? nil : raw
            }
            d[k] = .some(v)
            ws(s, &i)
            if try peek(s, i) == 0x2C { i += 1; continue }
            try expect(s, &i, 0x7D)
            return d
        }
    }

    /// ",} \t\r\n" ends an unquoted value.
    static func isRawStop(_ c: UInt16) -> Bool {
        return c == 0x2C || c == 0x7D || c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
    }

    static func peek(_ s: [UInt16], _ i: Int) throws -> UInt16 {
        if i >= s.count { throw JsonFormatError("eof") }
        return s[i]
    }

    static func ws(_ s: [UInt16], _ i: inout Int) { while i < s.count && NetParse.isWhiteSpace(s[i]) { i += 1 } }

    static func expect(_ s: [UInt16], _ i: inout Int, _ c: UInt16) throws {
        if try peek(s, i) != c { throw JsonFormatError("expected " + String(decoding: [c], as: UTF16.self)) }
        i += 1
    }

    static func str(_ s: [UInt16], _ i: inout Int) throws -> String {
        try expect(s, &i, 0x22)
        var out = [UInt16]()
        while true {
            let c = try peek(s, i); i += 1
            if c == 0x22 { return String(decoding: out, as: UTF16.self) }
            if c != 0x5C { out.append(c); continue }
            let e = try peek(s, i); i += 1
            switch e {
            case 0x6E: out.append(0x0A) // n
            case 0x74: out.append(0x09) // t
            case 0x72: out.append(0x0D) // r
            case 0x62: out.append(0x08) // b
            case 0x66: out.append(0x0C) // f
            case 0x75: // u: exactly four hex digits (Convert.ToInt32(s.Substring(i, 4), 16))
                guard i + 4 <= s.count, s[i..<(i + 4)].allSatisfy(isHex),
                      let n = UInt16(String(decoding: s[i..<(i + 4)], as: UTF16.self), radix: 16) else {
                    throw JsonFormatError("bad \\u escape")
                }
                out.append(n)
                i += 4
            default: out.append(e)
            }
        }
    }

    static func isHex(_ c: UInt16) -> Bool {
        return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    /// A JSON string literal: quotes and backslashes escaped, control characters as \u00xx (lowercase hex).
    public static func esc(_ s: String?) -> String {
        var out = "\""
        for c in (s ?? "").unicodeScalars {
            if c == "\"" || c == "\\" { out.append("\\"); out.unicodeScalars.append(c) }
            else if c.value < 0x20 { out += "\\u" + String(format: "%04x", c.value) }
            else { out.unicodeScalars.append(c) }
        }
        return out + "\""
    }
}

/// Field access with the C# helpers' semantics.
public enum Fields {
    /// CommandVerifier.Get: the value, "" when absent or null.
    public static func get(_ f: JsonFields, _ k: String) -> String {
        if let v = f[k], let s = v { return s }
        return ""
    }

    /// Agent.Opt: the value when present and non-empty, else nil.
    public static func opt(_ f: JsonFields, _ k: String) -> String? {
        if let v = f[k], let s = v, !s.isEmpty { return s }
        return nil
    }

    /// Dictionary.ContainsKey (true also for a null value).
    public static func has(_ f: JsonFields, _ k: String) -> Bool { return f.keys.contains(k) }
}
