import Darwin
import Foundation

/// The data dir (Windows: the install dir holding config.dat / agent.log / nonce.txt / agent.pid) and its file modes:
/// directory 0700, files 0600, so the plain base64 secrets in config.dat are readable by this user only.
public enum DataDir {
    /// ~/Library/Application Support/Recitbot (override with --data DIR, as on Windows).
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Recitbot").path
    }

    /// Path.GetFullPath: absolute against the working directory, "." and ".." removed.
    public static func fullPath(_ p: String) -> String {
        return URL(fileURLWithPath: p).standardizedFileURL.path
    }

    /// Directory.CreateDirectory, then 0700 on the leaf.
    public static func create(_ dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(dir, 0o700)
    }
}

public enum SecureFile {
    /// File.WriteAllText with mode 0600 (created 0600; an existing file is tightened to 0600).
    public static func write(_ path: String, _ text: String) throws {
        try writeData(path, Data(text.utf8))
    }

    public static func writeData(_ path: String, _ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if fd < 0 { throw posixError("open", path) }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var off = 0
            while off < b.count {
                let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; throw posixError("write", path) }
                off += n
            }
        }
    }

    /// Writes path.tmp (0600) and renames it over path: a crash mid-write never leaves a half-written file.
    /// parity: AgentRecorder.cs Config.SetPrefs (File.WriteAllLines(tmp) + File.Replace).
    public static func replace(_ path: String, _ text: String) throws {
        let tmp = path + ".tmp"
        try write(tmp, text)
        if rename(tmp, path) != 0 { let e = posixError("rename", path); unlink(tmp); throw e }
    }

    /// File.AppendAllText with mode 0600 on create.
    public static func append(_ path: String, _ text: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if fd < 0 { throw posixError("open", path) }
        defer { close(fd) }
        let d = Data(text.utf8)
        _ = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, d.count) }
    }

    /// File.ReadAllLines: lines split at \r\n, \n or \r; a final line break does not add an empty line.
    public static func readLines(_ path: String) throws -> [String] {
        return lines(try readText(path))
    }

    public static func readText(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "Recitbot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not find file '" + path + "'."])
        }
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        var s = String(decoding: d, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() } // File.ReadAllLines drops a UTF-8 BOM
        return s
    }

    public static func lines(_ s: String) -> [String] {
        var out = [String]()
        var cur = [UInt16]()
        let u = Array(s.utf16)
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == 0x0D || c == 0x0A {
                out.append(String(decoding: cur, as: UTF16.self))
                cur.removeAll()
                if c == 0x0D && i + 1 < u.count && u[i + 1] == 0x0A { i += 1 }
            } else { cur.append(c) }
            i += 1
        }
        if !cur.isEmpty { out.append(String(decoding: cur, as: UTF16.self)) }
        return out
    }

    /// Runs body while holding an exclusive flock on lockPath (created 0600): the running agent and an `--enroll` run of
    /// another process never interleave their read-modify-write of the same file. Without a usable lock file the body
    /// still runs (the in-process gate of the caller remains).
    public static func withLock<T>(_ lockPath: String, _ body: () throws -> T) rethrows -> T {
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 {
            while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }

    /// Modification time and size, nil when the file is not there (the agent's cheap "did config.dat change" check).
    public static func stamp(_ path: String) -> String? {
        var st = stat()
        if stat(path, &st) != 0 { return nil }
        return String(st.st_mtimespec.tv_sec) + "." + String(st.st_mtimespec.tv_nsec) + "/" + String(st.st_size) + "/" + String(st.st_ino)
    }

    public static func exists(_ path: String) -> Bool { return FileManager.default.fileExists(atPath: path) }

    /// File.Delete: no error when the file is not there.
    public static func delete(_ path: String) { unlink(path) }

    static func posixError(_ op: String, _ path: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: op + " " + path + ": " + String(cString: strerror(code))])
    }
}
