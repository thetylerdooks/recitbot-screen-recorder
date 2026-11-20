// Agent Recorder — tiny resident Windows agent. C# 5 / .NET Framework 4.8, built with the in-box csc.exe.
// Idle: one process holding one outbound WebSocket (no listening ports, no timers faster than 45 s).
// Recording: spawns ffmpeg only while recording and shows a control pill (timer, mic/speaker, Stop) excluded from capture.
// Capture and device enumeration sit behind ICaptureBackend / IDeviceCatalog (WindowsFfmpegBackend) so another
// platform can be added without touching the agent, command or UI logic.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Agent Recorder")]
[assembly: System.Reflection.AssemblyVersion("0.6.1.0")]

namespace AgentRecorder
{
    static class Native
    {
        public const uint WDA_NONE = 0x0, WDA_MONITOR = 0x1, WDA_EXCLUDEFROMCAPTURE = 0x11;
        public const int WM_DPICHANGED = 0x02E0, WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
        [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll", SetLastError = true)] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
        [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
        [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
        [DllImport("user32.dll")] static extern uint GetMessagePos();
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
        [DllImport("kernel32.dll")] public static extern bool SetProcessWorkingSetSize(IntPtr proc, IntPtr min, IntPtr max);

        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int CX, CY; }
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
            public Rectangle ToRectangle() { return Rectangle.FromLTRB(Left, Top, Right, Bottom); }
        }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION { public byte Op, Flags, Alpha, Format; }
        [StructLayout(LayoutKind.Sequential)]
        public struct BITMAPINFOHEADER
        {
            public int Size, Width, Height;
            public short Planes, BitCount;
            public int Compression, SizeImage, XPelsPerMeter, YPelsPerMeter, ClrUsed, ClrImportant;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT dst, ref SIZE size, IntPtr hdcSrc, ref POINT src, int key, ref BLENDFUNCTION blend, int flags);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

        /// Screen position of the mouse message being handled. Cursor.Position is where the pointer is *now*: when the UI
        /// thread is busy (camera frames), a click whose pointer has already moved on would look like a drag.
        public static Point MessagePos()
        {
            uint p = GetMessagePos();
            return new Point((short)(p & 0xFFFF), (short)(p >> 16));
        }

        /// Left, right or middle button held anywhere on the desktop (not just over our windows).
        public static bool AnyMouseButtonDown()
        {
            return ((GetAsyncKeyState(0x01) | GetAsyncKeyState(0x02) | GetAsyncKeyState(0x04)) & 0x8000) != 0;
        }

        public static string DpiMode = "unknown";

        /// Per-monitor-v2 DPI awareness so window positions and sizes are physical pixels on every monitor, also with mixed
        /// scaling. The exe manifest asks for it already (Win10 1703+); the calls cover hosts that ignore the manifest and
        /// fall back to per-monitor (8.1+) and then system awareness.
        public static void EnableDpiAwareness()
        {
            try
            {
                if (SetProcessDpiAwarenessContext((IntPtr)(-4))) { DpiMode = "per-monitor-v2"; return; }
                if (AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(), (IntPtr)(-4))) { DpiMode = "per-monitor-v2 (manifest)"; return; }
            }
            catch (EntryPointNotFoundException) { }
            try { if (SetProcessDpiAwareness(2) == 0) { DpiMode = "per-monitor"; return; } }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
            DpiMode = SetProcessDPIAware() ? "system" : "unchanged";
        }

        /// Effective DPI of the monitor nearest to a point (96 = 100 %).
        public static int DpiAt(Point p)
        {
            try
            {
                uint x, y;
                IntPtr m = MonitorFromPoint(new POINT(p.X, p.Y), 2 /* MONITOR_DEFAULTTONEAREST */);
                if (m != IntPtr.Zero && GetDpiForMonitor(m, 0, out x, out y) == 0 && x > 0) return (int)x;
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) return (int)g.DpiX;
        }

        public static int DpiForWindow(IntPtr hwnd, Point fallbackAt)
        {
            try { uint d = GetDpiForWindow(hwnd); if (d > 0) return (int)d; }
            catch (EntryPointNotFoundException) { }
            return DpiAt(fallbackAt);
        }

        static bool affinityLogged;

        /// Keeps a window out of screen captures. WDA_EXCLUDEFROMCAPTURE needs Windows 10 2004+; older builds get
        /// WDA_MONITOR (the window shows as a black box in captures instead of its contents). Returns the mode used.
        public static string ExcludeFromCapture(IntPtr hwnd)
        {
            if (SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)) return "exclude";
            int err = Marshal.GetLastWin32Error();
            bool mon = SetWindowDisplayAffinity(hwnd, WDA_MONITOR);
            if (!affinityLogged)
            {
                affinityLogged = true;
                Log.Write("WDA_EXCLUDEFROMCAPTURE unavailable (error " + err + ", Windows " + Environment.OSVersion.Version + "); "
                    + (mon ? "using WDA_MONITOR" : "WDA_MONITOR failed too: UI may appear in recordings"));
            }
            return mon ? "monitor" : "none";
        }

        /// Test-only (--pill-preview --shot): lets screen captures see the window again, for a screenshot of the pill.
        public static bool IncludeInCapture(IntPtr hwnd) { return SetWindowDisplayAffinity(hwnd, WDA_NONE); }

        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);

        /// The window's extended style (GWL_EXSTYLE).
        public static int ExStyle(IntPtr hwnd) { return GetWindowLong(hwnd, -20); }

        /// Quotes one argument for the Windows command line (CommandLineToArgvW / MSVCRT rules).
        public static string QuoteArg(string s)
        {
            var sb = new StringBuilder("\"");
            int bs = 0;
            foreach (char c in s)
            {
                if (c == '\\') { bs++; continue; }
                if (c == '"') { sb.Append('\\', bs * 2 + 1).Append('"'); bs = 0; continue; }
                sb.Append('\\', bs).Append(c);
                bs = 0;
            }
            return sb.Append('\\', bs * 2).Append('"').ToString();
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits
        {
            public BasicLimits Basic;
            public ulong R0, W0, O0, R1, W1, O1; // IO_COUNTERS
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, ref ExtendedLimits info, uint len);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);

        static IntPtr job;

        /// ffmpeg children live in a kill-on-close job: if the agent dies, ffmpeg dies with it.
        public static void AddToKillJob(Process p)
        {
            try
            {
                if (job == IntPtr.Zero)
                {
                    job = CreateJobObject(IntPtr.Zero, null);
                    var info = new ExtendedLimits();
                    info.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                    SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(typeof(ExtendedLimits)));
                }
                AssignProcessToJobObject(job, p.Handle);
            }
            catch (Exception e) { Log.Write("job object: " + e.Message); }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo
        {
            public int cb;
            public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string app, StringBuilder cmdLine, IntPtr procAttrs, IntPtr threadAttrs, bool inherit, uint flags,
            IntPtr env, string cwd, ref StartupInfo si, out ProcessInformation pi);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        /// Starts a console program with no window and outside this process's job (CREATE_BREAKAWAY_FROM_JOB, e.g. the
        /// logon task's job), so it outlives this process; without breakaway when the job does not allow it. No handles
        /// inherited, not waited for. Returns the pid; throws Win32Exception when it did not start.
        public static int StartDetachedHidden(string commandLine)
        {
            const uint CreateNoWindow = 0x08000000, CreateBreakawayFromJob = 0x01000000, CreateNewProcessGroup = 0x00000200;
            int err = 0;
            foreach (uint extra in new[] { CreateBreakawayFromJob, 0u })
            {
                var si = new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfo)), dwFlags = 0x1 /* STARTF_USESHOWWINDOW */, wShowWindow = 0 /* SW_HIDE */ };
                ProcessInformation pi;
                if (CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, CreateNoWindow | CreateNewProcessGroup | extra,
                    IntPtr.Zero, Path.GetTempPath(), ref si, out pi))
                {
                    CloseHandle(pi.hThread);
                    CloseHandle(pi.hProcess);
                    return pi.dwProcessId;
                }
                err = Marshal.GetLastWin32Error();
            }
            throw new System.ComponentModel.Win32Exception(err);
        }

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_Interface_List_Size(out int len, ref Guid cls, string deviceId, int flags);
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_Interface_List(ref Guid cls, string deviceId, char[] buffer, int len, int flags);

        /// Paths of the present device interfaces of one class, sorted and joined (a few ms, no child process), or null.
        public static string DeviceInterfaces(Guid cls)
        {
            try
            {
                int len;
                if (CM_Get_Device_Interface_List_Size(out len, ref cls, null, 0 /* PRESENT */) != 0) return null;
                var buf = new char[Math.Max(1, len)];
                if (CM_Get_Device_Interface_List(ref cls, null, buf, buf.Length, 0) != 0) return null;
                var l = new List<string>(new string(buf).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries));
                l.Sort(StringComparer.OrdinalIgnoreCase);
                return string.Join("|", l);
            }
            catch { return null; }
        }

        public static void TrimWorkingSet()
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            SetProcessWorkingSetSize(Process.GetCurrentProcess().Handle, (IntPtr)(-1), (IntPtr)(-1));
        }
    }

    static class Log
    {
        static readonly object Gate = new object();
        public static string PathName;

        // Never pass secrets here. Tokens/keys are never formatted into messages.
        public static void Write(string msg)
        {
            if (PathName == null) return;
            lock (Gate)
            {
                try
                {
                    var fi = new FileInfo(PathName);
                    if (fi.Exists && fi.Length > 1024 * 1024) fi.Delete();
                    File.AppendAllText(PathName, DateTime.UtcNow.ToString("o") + " " + msg + Environment.NewLine);
                }
                catch { }
            }
        }
    }

    /// Test hooks, active only when AGENT_RECORDER_E2E_DIR is set: window rectangles and self-renders for the e2e checks.
    static class E2e
    {
        static readonly string Dir = Environment.GetEnvironmentVariable("AGENT_RECORDER_E2E_DIR");

        public static bool On { get { return !string.IsNullOrEmpty(Dir); } }

        public static void Write(string name, string text)
        {
            if (!On) return;
            try { Directory.CreateDirectory(Dir); File.WriteAllText(Path.Combine(Dir, name), text); }
            catch (Exception e) { Log.Write("e2e: " + e.Message); }
        }

        public static void Save(Bitmap bmp, string name)
        {
            if (!On || bmp == null) return;
            try { Directory.CreateDirectory(Dir); bmp.Save(Path.Combine(Dir, name), System.Drawing.Imaging.ImageFormat.Png); }
            catch (Exception e) { Log.Write("e2e save: " + e.Message); }
        }

        public static void Snapshot(Control c, string name)
        {
            if (!On) return;
            try
            {
                Directory.CreateDirectory(Dir);
                using (var bmp = new Bitmap(c.Width, c.Height))
                {
                    c.DrawToBitmap(bmp, new Rectangle(0, 0, c.Width, c.Height));
                    bmp.Save(Path.Combine(Dir, name), System.Drawing.Imaging.ImageFormat.Png);
                }
            }
            catch (Exception e) { Log.Write("e2e snapshot: " + e.Message); }
        }
    }

    /// Minimal flat JSON object reader/writer (strings, numbers, booleans, null).
    static class Json
    {
        public static Dictionary<string, string> ParseFlat(string s)
        {
            var d = new Dictionary<string, string>();
            int i = 0;
            Ws(s, ref i);
            Expect(s, ref i, '{');
            Ws(s, ref i);
            if (Peek(s, i) == '}') return d;
            while (true)
            {
                Ws(s, ref i);
                string k = Str(s, ref i);
                Ws(s, ref i);
                Expect(s, ref i, ':');
                Ws(s, ref i);
                string v;
                char c = Peek(s, i);
                if (c == '"') v = Str(s, ref i);
                else
                {
                    int st = i;
                    while (i < s.Length && ",} \t\r\n".IndexOf(s[i]) < 0) i++;
                    v = s.Substring(st, i - st);
                    if (v.Length == 0 || v[0] == '{' || v[0] == '[') throw new FormatException("nested json");
                    if (v == "null") v = null;
                }
                d[k] = v;
                Ws(s, ref i);
                if (Peek(s, i) == ',') { i++; continue; }
                Expect(s, ref i, '}');
                return d;
            }
        }

        static char Peek(string s, int i) { if (i >= s.Length) throw new FormatException("eof"); return s[i]; }
        static void Ws(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }
        static void Expect(string s, ref int i, char c) { if (Peek(s, i) != c) throw new FormatException("expected " + c); i++; }

        static string Str(string s, ref int i)
        {
            Expect(s, ref i, '"');
            var sb = new StringBuilder();
            while (true)
            {
                char c = Peek(s, i++);
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                char e = Peek(s, i++);
                switch (e)
                {
                    case 'n': sb.Append('\n'); break;
                    case 't': sb.Append('\t'); break;
                    case 'r': sb.Append('\r'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'u': sb.Append((char)Convert.ToInt32(s.Substring(i, 4), 16)); i += 4; break;
                    default: sb.Append(e); break;
                }
            }
        }

        public static string Esc(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (char c in s ?? "")
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                else sb.Append(c);
            }
            return sb.Append('"').ToString();
        }
    }

    /// Persisted config. Secrets (device token, command key) are DPAPI-protected for the current user.
    /// v2 (0.6.0): `config_version=2` first, the machine-wide settings, then one block per paired account
    /// (`account.<n>.server/account_id/device_id/device_token/device_secret`). A v1 file (one account in the top-level
    /// server/account_id/device_id/device_token/device_secret keys) is read as one account and written back as v2.
    /// parity: mac/Sources/RecitbotCore/Config.swift
    class Config
    {
        /// One Recitbot account this install is paired with: to that account it is its own device (own id, token and
        /// command key, own WebSocket). parity: mac Account
        public class Account
        {
            public string Server, AccountId, DeviceId, DeviceToken, DeviceSecret;

            public bool Same(Account o)
            {
                return o != null && Server == o.Server && AccountId == o.AccountId && DeviceId == o.DeviceId && DeviceToken == o.DeviceToken
                    && DeviceSecret == o.DeviceSecret;
            }
        }

        static readonly byte[] Entropy = Encoding.UTF8.GetBytes("AgentRecorder.v1");
        public List<Account> Accounts = new List<Account>();
        public string Ffmpeg, Encoder;
        public int Fps = 30;
        /// VideoChain path: "auto" (default), or "gpu" / "cpu" to force one (config video_path, --video-path).
        public string VideoPath = "auto";
        public string Dir;
        // UI preferences (non-secret), changed from the bubble/pill and persisted with SetPrefs.
        public bool Webcam, Mirror = true;
        /// "circle" or "rect" (the bubble's shape, chosen in its controls).
        public string Shape = "circle";
        public string Camera;
        public int WebcamPx = WebcamBubble.DefaultPx;
        public int? BubbleX, BubbleY;
        /// Where the control pill was dropped, per monitor id: offset of the pill from the monitor's top-left (pill_at_<id>=x,y).
        public Dictionary<string, Point> PillAt = new Dictionary<string, Point>();
        static readonly object FileGate = new object();

        public const string VersionLine = "config_version=2";
        /// The per-account keys: top-level in a v1 file, `account.<n>.<key>` in v2.
        public static readonly string[] AccountKeys = { "server", "account_id", "device_id", "device_token", "device_secret" };
        const string AccountPrefix = "account.";

        public string FilePath { get { return ConfigPath(Dir); } }

        static string ConfigPath(string dir) { return Path.Combine(dir, "config.dat"); }

        public static string Protect(string s)
        {
            return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(s ?? ""), Entropy, DataProtectionScope.CurrentUser));
        }

        static string Unprotect(string s)
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(s), Entropy, DataProtectionScope.CurrentUser));
        }

        /// Every read-modify-write of config.dat: the in-process gate, then config.lock opened exclusively (the running
        /// agent and an --enroll run of another process both rewrite the file). Without a usable lock file the body still
        /// runs under the in-process gate.
        static T Locked<T>(string dir, Func<T> body)
        {
            lock (FileGate)
            {
                FileStream held = null;
                if (Directory.Exists(dir))
                {
                    string lockPath = Path.Combine(dir, "config.lock");
                    for (int i = 0; i < 400 && held == null; i++)
                    {
                        try { held = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
                        catch (IOException e)
                        {
                            int code = e.HResult & 0xFFFF;
                            if (code != 32 && code != 33) break; // only a sharing violation means "someone else holds it"
                            Thread.Sleep(25);
                        }
                        catch (UnauthorizedAccessException) { break; }
                    }
                }
                try { return body(); }
                finally { if (held != null) held.Dispose(); }
            }
        }

        /// Writes path.tmp and swaps it in (File.Replace): a crash mid-write never leaves a half-written file.
        static void Replace(string path, IEnumerable<string> lines)
        {
            string tmp = path + ".tmp";
            File.WriteAllLines(tmp, lines);
            if (File.Exists(path)) File.Replace(tmp, path, null);
            else File.Move(tmp, path);
        }

        /// The machine-wide lines of a new file (same keys and order as the v1 file had).
        static List<string> DefaultLines(string ffmpeg)
        {
            return new List<string>
            {
                "ffmpeg=" + ffmpeg, "encoder=", "fps=30", "webcam=0", "camera=", "webcam_px=" + WebcamBubble.DefaultPx, "mirror=1",
                "webcam_shape=circle", "auto_open_link=true",
            };
        }

        public static string Key(string line)
        {
            int eq = line.IndexOf('=');
            return eq < 0 ? line : line.Substring(0, eq);
        }

        /// A line that belongs to an account (v1 top-level account keys, v2 account blocks) or the version marker.
        static bool IsAccountLine(string line)
        {
            string k = Key(line);
            return k == "config_version" || k.StartsWith(AccountPrefix) || Array.IndexOf(AccountKeys, k) >= 0;
        }

        static List<string> AccountLines(List<Account> accounts)
        {
            var o = new List<string>();
            for (int i = 0; i < accounts.Count; i++)
            {
                var a = accounts[i];
                string p = AccountPrefix + i + ".";
                o.Add(p + "server=" + a.Server);
                o.Add(p + "account_id=" + a.AccountId);
                o.Add(p + "device_id=" + a.DeviceId);
                o.Add(p + "device_token=" + Protect(a.DeviceToken));
                o.Add(p + "device_secret=" + Protect(a.DeviceSecret));
            }
            return o;
        }

        /// The v2 file: the version line, every machine-wide line of `lines` byte-for-byte, then the accounts.
        static List<string> V2Lines(IEnumerable<string> lines, List<Account> accounts)
        {
            var o = new List<string> { VersionLine };
            foreach (var l in lines) if (!IsAccountLine(l)) o.Add(l);
            o.AddRange(AccountLines(accounts));
            return o;
        }

        /// The accounts in config.dat's lines, in file order: the v2 blocks, else (v1) the top-level keys. An entry missing
        /// a field, or whose secret does not decrypt for this user, is skipped (logged; it could never connect).
        static List<Account> ParseAccounts(IList<string> lines)
        {
            var v1 = new Dictionary<string, string>();
            var blocks = new SortedDictionary<int, Dictionary<string, string>>();
            foreach (var line in lines)
            {
                int eq = line.IndexOf('=');
                if (eq < 0) continue;
                string k = line.Substring(0, eq), v = line.Substring(eq + 1);
                if (Array.IndexOf(AccountKeys, k) >= 0) { v1[k] = v; continue; }
                if (!k.StartsWith(AccountPrefix)) continue;
                string rest = k.Substring(AccountPrefix.Length);
                int dot = rest.IndexOf('.'), n;
                if (dot < 0 || !int.TryParse(rest.Substring(0, dot), out n) || n < 0) continue;
                string field = rest.Substring(dot + 1);
                if (Array.IndexOf(AccountKeys, field) < 0) continue;
                if (!blocks.ContainsKey(n)) blocks[n] = new Dictionary<string, string>();
                blocks[n][field] = v;
            }
            var raw = new List<Dictionary<string, string>>();
            if (lines.Contains(VersionLine)) raw.AddRange(blocks.Values);
            else if (v1.Count > 0) raw.Add(v1);
            var o = new List<Account>();
            for (int i = 0; i < raw.Count; i++)
            {
                var b = raw[i];
                string s, a, d, t, x;
                if (!b.TryGetValue("server", out s) || !b.TryGetValue("account_id", out a) || !b.TryGetValue("device_id", out d)
                    || !b.TryGetValue("device_token", out t) || !b.TryGetValue("device_secret", out x) || a.Length == 0 || d.Length == 0)
                {
                    Log.Write("config: account " + i + " incomplete; skipped");
                    continue;
                }
                try
                {
                    var acct = new Account { Server = s, AccountId = a, DeviceId = d, DeviceToken = Unprotect(t), DeviceSecret = Unprotect(x) };
                    if (acct.DeviceToken.Length == 0 || o.Exists(e => e.AccountId == a)) continue;
                    o.Add(acct);
                }
                catch (Exception e) { Log.Write("config: account " + a + " unreadable; skipped: " + e.GetType().Name); }
            }
            return o;
        }

        /// nonce-<device id>.txt: each account's last accepted command nonce (its DeviceHub signs with its own counter).
        public static string NoncePath(string dir, string deviceId)
        {
            return Path.Combine(dir, "nonce-" + System.Text.RegularExpressions.Regex.Replace(deviceId ?? "", "[^A-Za-z0-9]", "") + ".txt");
        }

        /// The v1 nonce.txt belongs to the v1 account: it moves with the migration so a replay is still refused.
        static void MigrateNonce(string dir, List<Account> accounts)
        {
            string old = Path.Combine(dir, "nonce.txt");
            if (accounts.Count == 0 || !File.Exists(old)) return;
            string to = NoncePath(dir, accounts[0].DeviceId);
            try { if (File.Exists(to)) File.Delete(to); File.Move(old, to); }
            catch { try { File.Delete(old); } catch { } }
        }

        static void DeleteQuietly(string path) { try { File.Delete(path); } catch { } }

        /// Adds the account an enroll returned (true), or refreshes the entry of the same account (false): every other
        /// account and every machine-wide line stay as they are. A new file gets the default settings. ffmpeg (the
        /// install's ffmpeg) replaces the machine-wide value when given.
        public static bool UpsertAccount(string dir, Account a, string ffmpeg)
        {
            return Locked(dir, () =>
            {
                string path = ConfigPath(dir);
                var lines = File.Exists(path) ? new List<string>(File.ReadAllLines(path)) : DefaultLines(ffmpeg ?? "");
                if (ffmpeg != null)
                {
                    int at = lines.FindIndex(l => Key(l) == "ffmpeg");
                    if (at >= 0) lines[at] = "ffmpeg=" + ffmpeg; else lines.Add("ffmpeg=" + ffmpeg);
                }
                var accounts = ParseAccounts(lines);
                if (!lines.Contains(VersionLine)) MigrateNonce(dir, accounts);
                int i = accounts.FindIndex(e => e.AccountId == a.AccountId);
                if (i >= 0)
                {
                    if (accounts[i].DeviceId != a.DeviceId) DeleteQuietly(NoncePath(dir, accounts[i].DeviceId));
                    accounts[i] = a;
                }
                else accounts.Add(a);
                DeleteQuietly(NoncePath(dir, a.DeviceId));
                Replace(path, V2Lines(lines, accounts));
                return i < 0;
            });
        }

        /// Drops one account (its entry and nonce file); the accounts left. Only the entry of that device: an entry the
        /// same account got from a newer pairing (another device id) stays. Nothing changes when it is not listed.
        public static List<Account> RemoveAccount(string dir, string accountId, string deviceId)
        {
            return Locked(dir, () =>
            {
                string path = ConfigPath(dir);
                if (!File.Exists(path)) return new List<Account>();
                var lines = File.ReadAllLines(path);
                var accounts = ParseAccounts(lines);
                int i = accounts.FindIndex(e => e.AccountId == accountId && e.DeviceId == deviceId);
                if (i < 0) return accounts;
                var gone = accounts[i];
                accounts.RemoveAt(i);
                Replace(path, V2Lines(lines, accounts));
                DeleteQuietly(NoncePath(dir, gone.DeviceId));
                return accounts;
            });
        }

        /// The device_token an enroll sends: only the token held for the account the installer names (--account), so one
        /// account's token never goes out with another account's pairing code. null = pair without a token.
        public static string EnrollToken(List<Account> accounts, string account)
        {
            if (string.IsNullOrEmpty(account) || accounts == null) return null;
            var a = accounts.Find(e => e.AccountId == account);
            return a == null ? null : a.DeviceToken;
        }

        /// Updates non-secret keys in place. Every other line (including the accounts and their DPAPI blobs) is kept
        /// byte-for-byte, and the file is swapped atomically so a crash mid-write cannot lose the device credentials.
        public void SetPrefs(params string[] kv)
        {
            if (Dir == null) return;
            try
            {
                Locked(Dir, () =>
                {
                    var lines = new List<string>(File.ReadAllLines(FilePath));
                    for (int i = 0; i + 1 < kv.Length; i += 2)
                    {
                        if (IsAccountLine(kv[i] + "=")) continue; // never rewritten from here
                        string line = kv[i] + "=" + (kv[i + 1] ?? "").Replace("\r", "").Replace("\n", "");
                        int at = lines.FindIndex(l => l.StartsWith(kv[i] + "="));
                        if (at >= 0) lines[at] = line; else lines.Add(line);
                    }
                    Replace(FilePath, lines);
                    return true;
                });
            }
            catch (Exception e) { Log.Write("config prefs not saved: " + e.Message); }
        }

        /// null when config.dat does not exist. A v1 file is migrated: its one account is written back as v2 (same account,
        /// device id, token and secret: it stays paired) and nonce.txt moves to that account's nonce file.
        public static Config Load(string dir)
        {
            return Locked(dir, () =>
            {
                var c = new Config { Dir = dir };
                if (!File.Exists(c.FilePath)) return null;
                var lines = File.ReadAllLines(c.FilePath);
                c.Parse(lines);
                if (Array.IndexOf(lines, VersionLine) < 0 && c.Accounts.Count > 0)
                {
                    try
                    {
                        MigrateNonce(dir, c.Accounts);
                        Replace(c.FilePath, V2Lines(lines, c.Accounts));
                        Log.Write("config: migrated to v2 (" + c.Accounts.Count + " account)");
                    }
                    catch (Exception e) { Log.Write("config: v2 migration not written: " + e.Message); }
                }
                return c;
            });
        }

        /// The accounts and the machine-wide settings of config.dat's lines.
        void Parse(string[] lines)
        {
            Accounts = ParseAccounts(lines);
            bool havePx = false;
            int legacyPx = -1;
            foreach (var line in lines)
            {
                int eq = line.IndexOf('=');
                if (eq < 0) continue;
                string k = line.Substring(0, eq), v = line.Substring(eq + 1);
                int n;
                if (k == "ffmpeg") Ffmpeg = v;
                else if (k == "encoder" && v.Length > 0) Encoder = v;
                else if (k == "fps") { if (int.TryParse(v, out n)) Fps = Math.Max(15, Math.Min(60, n)); }
                else if (k == "video_path") VideoPath = VideoChain.Normalize(v);
                else if (k == "webcam") Webcam = v == "1" || v == "true";
                else if (k == "camera" && v.Length > 0) Camera = v;
                else if (k == "webcam_px") { if (int.TryParse(v, out n)) { WebcamPx = WebcamBubble.ClampPx(n); havePx = true; } }
                else if (k == "webcam_size") legacyPx = WebcamBubble.PxForName(v); // pre-0.2 configs: small/medium/large
                else if (k == "mirror") Mirror = v != "0" && v != "false";
                else if (k == "webcam_shape") Shape = v == "rect" ? "rect" : "circle";
                else if (k == "bubble_x") { if (int.TryParse(v, out n)) BubbleX = n; }
                else if (k == "bubble_y") { if (int.TryParse(v, out n)) BubbleY = n; }
                else if (k.StartsWith("pill_at_") && k.Length > 8)
                {
                    var xy = v.Split(',');
                    int py;
                    if (xy.Length == 2 && int.TryParse(xy[0], out n) && int.TryParse(xy[1], out py)) PillAt[k.Substring(8)] = new Point(n, py);
                }
            }
            if (!havePx && legacyPx > 0) WebcamPx = legacyPx;
        }

        /// Settings changeable with `AgentRecorder.exe --set key=value` (non-secret, read when used, so a running agent
        /// picks them up without a restart).
        public static readonly string[] Settable = { "auto_open_link" };

        /// Normalized value for a settable key, or null when the key or value is not allowed.
        public static string NormalizeSetting(string key, string value)
        {
            if (Array.IndexOf(Settable, key) < 0 || value == null) return null;
            string v = value.Trim().ToLowerInvariant();
            if (v == "true" || v == "1" || v == "on" || v == "yes") return "true";
            if (v == "false" || v == "0" || v == "off" || v == "no") return "false";
            return null;
        }

        /// A boolean setting straight from config.dat (default when absent or unreadable).
        public bool ReadBool(string key, bool def)
        {
            if (Dir == null) return def;
            try
            {
                var lines = Locked(Dir, () => File.ReadAllLines(FilePath));
                foreach (var line in lines)
                    if (line.StartsWith(key + "=")) return NormalizeSetting(key, line.Substring(key.Length + 1)) != "false";
            }
            catch (Exception e) { Log.Write("config read: " + e.Message); }
            return def;
        }
    }

    /// Verifies signed commands: HMAC, account/device binding, expiry and a monotonic nonce (replay protection).
    class CommandVerifier
    {
        readonly string accountId, deviceId, secret, noncePath;
        long lastNonce;

        public CommandVerifier(string accountId, string deviceId, string secret, string noncePath)
        {
            this.accountId = accountId; this.deviceId = deviceId; this.secret = secret; this.noncePath = noncePath;
            long n;
            if (noncePath != null && File.Exists(noncePath) && long.TryParse(File.ReadAllText(noncePath).Trim(), out n)) lastNonce = n;
        }

        public static string Canonical(Dictionary<string, string> f)
        {
            string s = string.Join("|", new[]
            {
                "v1", Get(f, "type"), Get(f, "recording_id"), Get(f, "max_seconds"), Get(f, "mic") == "true" ? "1" : "0",
                Get(f, "nonce"), Get(f, "exp"), Get(f, "account_id"), Get(f, "device_id"), Get(f, "upload_token"),
            });
            // Optional blocks are signed only when present, so commands without them keep the original v1 form.
            if (f.ContainsKey("webcam") || f.ContainsKey("camera") || f.ContainsKey("webcam_size"))
            {
                string w = Get(f, "webcam");
                s += "|cam|" + (w == "true" ? "1" : w == "false" ? "0" : "") + "|" + Get(f, "camera") + "|" + Get(f, "webcam_size");
            }
            if (f.ContainsKey("monitor") || f.ContainsKey("mic_device"))
                s += "|dev|" + Get(f, "monitor") + "|" + Get(f, "mic_device");
            if (f.ContainsKey("window")) s += "|win|" + Get(f, "window");
            // 0.4 blocks (the Worker sends them only to recorders whose hello announced the feature).
            if (f.ContainsKey("system_audio")) s += "|sa|" + (Get(f, "system_audio") == "true" ? "1" : "0");
            if (f.ContainsKey("webcam_shape")) s += "|shape|" + Get(f, "webcam_shape");
            if (f.ContainsKey("url")) s += "|url|" + Get(f, "url");
            // Chunked upload (hello "chunked_upload"): the part size for files larger than one PUT.
            if (f.ContainsKey("upload_part_bytes")) s += "|mp|" + Get(f, "upload_part_bytes");
            // Self-update (hello "self_update"), only on "update" commands; the download link is the url block.
            if (f.ContainsKey("version") || f.ContainsKey("sha256")) s += "|upd|" + Get(f, "version") + "|" + Get(f, "sha256");
            // Uninstall scope (hello "multi_account"), only on "uninstall" commands that carry one.
            if (f.ContainsKey("scope")) s += "|scope|" + Get(f, "scope");
            return s;
        }

        static string Get(Dictionary<string, string> f, string k)
        {
            string v;
            return f.TryGetValue(k, out v) && v != null ? v : "";
        }

        public static string HmacHex(string key, string msg)
        {
            using (var h = new HMACSHA256(Encoding.UTF8.GetBytes(key)))
            {
                var b = h.ComputeHash(Encoding.UTF8.GetBytes(msg));
                var sb = new StringBuilder();
                foreach (var x in b) sb.Append(x.ToString("x2"));
                return sb.ToString();
            }
        }

        static bool FixedTimeEquals(string a, string b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int diff = 0;
            for (int i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
            return diff == 0;
        }

        /// Returns null when valid, otherwise the rejection reason.
        public string Verify(Dictionary<string, string> f, long nowUnix)
        {
            if (!FixedTimeEquals(Get(f, "mac"), HmacHex(secret, Canonical(f)))) return "bad mac";
            if (Get(f, "account_id") != accountId) return "wrong account";
            if (Get(f, "device_id") != deviceId) return "wrong device";
            long exp, nonce;
            if (!long.TryParse(Get(f, "exp"), out exp) || exp < nowUnix) return "expired";
            if (!long.TryParse(Get(f, "nonce"), out nonce) || nonce <= lastNonce) return "replayed nonce";
            lastNonce = nonce;
            if (noncePath != null) File.WriteAllText(noncePath, nonce.ToString());
            return null;
        }
    }

    // ---------------------------------------------------------------- displays and devices

    /// A monitor as Windows reports it (physical pixels; the process is per-monitor DPI aware).
    class Display
    {
        public string DeviceName;
        public Rectangle Bounds, WorkArea;
        public bool Primary;
    }

    static class Displays
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct MONITORINFOEX
        {
            public int Size;
            public Native.RECT Monitor, Work;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
        }

        delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);

        /// Live list (not cached like Screen.AllScreens, which needs a SystemEvents window to notice changes).
        public static List<Display> All()
        {
            var list = new List<Display>();
            MonitorEnumProc proc = delegate (IntPtr m, IntPtr hdc, IntPtr r, IntPtr d)
            {
                var mi = new MONITORINFOEX();
                mi.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
                if (GetMonitorInfo(m, ref mi))
                    list.Add(new Display { DeviceName = mi.Device, Bounds = mi.Monitor.ToRectangle(), WorkArea = mi.Work.ToRectangle(), Primary = (mi.Flags & 1) != 0 });
                return true;
            };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
            GC.KeepAlive(proc);
            return list;
        }

        /// GDI device name (\\.\DISPLAY1) of a monitor handle, or null.
        public static string DeviceNameOf(IntPtr monitor)
        {
            var mi = new MONITORINFOEX();
            mi.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
            return monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref mi) ? mi.Device : null;
        }

        public static List<Rectangle> Bounds()
        {
            var r = new List<Rectangle>();
            foreach (var d in All()) r.Add(d.Bounds);
            return r;
        }

        public static Point Center(Rectangle r) { return new Point(r.X + r.Width / 2, r.Y + r.Height / 2); }

        /// Moves r inside area (top-left wins when r is larger than area).
        public static Point KeepInside(Rectangle r, Rectangle area)
        {
            int x = Math.Max(area.Left, Math.Min(area.Right - r.Width, r.X));
            int y = Math.Max(area.Top, Math.Min(area.Bottom - r.Height, r.Y));
            return new Point(x, y);
        }

        /// A saved window position is used only while its centre is on a connected monitor (then kept fully inside that
        /// monitor); otherwise (monitor unplugged, resolution changed) the caller's default is used.
        public static Point Restore(List<Rectangle> screens, int? x, int? y, Size size, Point fallback)
        {
            if (!x.HasValue || !y.HasValue) return fallback;
            var r = new Rectangle(x.Value, y.Value, size.Width, size.Height);
            foreach (var s in screens) if (s.Contains(Center(r))) return KeepInside(r, s);
            return fallback;
        }

        /// Same relative spot on another monitor (keeps "bottom-left" bottom-left when the recorded monitor changes).
        public static Point Remap(Point p, Size size, Rectangle from, Rectangle to)
        {
            double fx = from.Width > size.Width ? (p.X - from.Left) / (double)(from.Width - size.Width) : 0;
            double fy = from.Height > size.Height ? (p.Y - from.Top) / (double)(from.Height - size.Height) : 0;
            fx = Math.Max(0, Math.Min(1, fx));
            fy = Math.Max(0, Math.Min(1, fy));
            return new Point(to.Left + (int)Math.Round(fx * Math.Max(0, to.Width - size.Width)), to.Top + (int)Math.Round(fy * Math.Max(0, to.Height - size.Height)));
        }

        /// The monitor holding a point, else the one whose centre is nearest; null only when the list is empty.
        public static Display Nearest(List<Display> all, Point c)
        {
            Display best = null;
            long bestD = long.MaxValue;
            foreach (var d in all)
            {
                if (d.Bounds.Contains(c)) return d;
                var dc = Center(d.Bounds);
                long dist = (long)(dc.X - c.X) * (dc.X - c.X) + (long)(dc.Y - c.Y) * (dc.Y - c.Y);
                if (dist < bestD) { bestD = dist; best = d; }
            }
            return best;
        }

        /// Keeps a window rectangle fully on the monitor holding its centre (or the nearest one).
        public static Point OnScreen(Rectangle r) { return OnScreen(All(), r); }

        public static Point OnScreen(List<Display> all, Rectangle r)
        {
            var best = Nearest(all, Center(r));
            return best == null ? r.Location : KeepInside(r, best.Bounds);
        }
    }

    /// DXGI outputs in the order ffmpeg's ddagrab indexes them (output_idx = output index on the default adapter 0).
    static class Dxgi
    {
        [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IDXGIFactory1
        {
            void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
            void EnumAdapters(); void MakeWindowAssociation(); void GetWindowAssociation(); void CreateSwapChain(); void CreateSoftwareAdapter();
            [PreserveSig] int EnumAdapters1(uint index, out IDXGIAdapter1 adapter);
        }

        [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IDXGIAdapter1
        {
            void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
            [PreserveSig] int EnumOutputs(uint index, out IDXGIOutput output);
        }

        [ComImport, Guid("ae02eedb-c735-4690-8d52-5a8dc20213aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IDXGIOutput
        {
            void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
            [PreserveSig] int GetDesc(out OutputDesc desc);
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct OutputDesc
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            public Native.RECT Desktop;
            public int Attached, Rotation;
            public IntPtr Monitor;
        }

        [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1([In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 factory);

        public class Output { public int Adapter, Index; public string DeviceName; }

        public static List<Output> Outputs()
        {
            var list = new List<Output>();
            try
            {
                var iid = typeof(IDXGIFactory1).GUID;
                IDXGIFactory1 f;
                if (CreateDXGIFactory1(ref iid, out f) != 0 || f == null) return list;
                try
                {
                    for (uint a = 0; a < 16; a++)
                    {
                        IDXGIAdapter1 ad;
                        if (f.EnumAdapters1(a, out ad) != 0 || ad == null) break;
                        try
                        {
                            for (uint o = 0; o < 16; o++)
                            {
                                IDXGIOutput op;
                                if (ad.EnumOutputs(o, out op) != 0 || op == null) break;
                                try
                                {
                                    OutputDesc d;
                                    if (op.GetDesc(out d) == 0) list.Add(new Output { Adapter = (int)a, Index = (int)o, DeviceName = d.DeviceName });
                                }
                                finally { Marshal.ReleaseComObject(op); }
                            }
                        }
                        finally { Marshal.ReleaseComObject(ad); }
                    }
                }
                finally { Marshal.ReleaseComObject(f); }
            }
            catch (Exception e) { Log.Write("dxgi enumeration: " + e.Message); }
            return list;
        }
    }

    /// Monitor model names ("DELL U2720Q") and device paths from the display configuration API (Windows 7+).
    static class MonitorNames
    {
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, IntPtr pathInfo, ref uint modes, IntPtr modeInfo, IntPtr topology);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr packet);

        const int PathSize = 72, ModeSize = 64, SourceNameSize = 84, TargetNameSize = 420;

        /// GDI device name (\\.\DISPLAY1) -> { friendly name, monitor device path }. Empty on any failure.
        public static Dictionary<string, string[]> Query()
        {
            var map = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
            IntPtr paths = IntPtr.Zero, modes = IntPtr.Zero, pkt = IntPtr.Zero;
            try
            {
                uint np, nm;
                if (GetDisplayConfigBufferSizes(2 /* QDC_ONLY_ACTIVE_PATHS */, out np, out nm) != 0) return map;
                paths = Marshal.AllocHGlobal((int)Math.Max(1, np) * PathSize);
                modes = Marshal.AllocHGlobal((int)Math.Max(1, nm) * ModeSize);
                if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return map;
                pkt = Marshal.AllocHGlobal(TargetNameSize);
                var zero = new byte[TargetNameSize];
                for (int i = 0; i < np; i++)
                {
                    IntPtr p = paths + i * PathSize;
                    long srcAdapter = Marshal.ReadInt64(p, 0), tgtAdapter = Marshal.ReadInt64(p, 20);
                    int srcId = Marshal.ReadInt32(p, 8), tgtId = Marshal.ReadInt32(p, 28);
                    Marshal.Copy(zero, 0, pkt, TargetNameSize);
                    Marshal.WriteInt32(pkt, 0, 1); // DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
                    Marshal.WriteInt32(pkt, 4, SourceNameSize);
                    Marshal.WriteInt64(pkt, 8, srcAdapter);
                    Marshal.WriteInt32(pkt, 16, srcId);
                    if (DisplayConfigGetDeviceInfo(pkt) != 0) continue;
                    string gdi = Marshal.PtrToStringUni(pkt + 20);
                    Marshal.Copy(zero, 0, pkt, TargetNameSize);
                    Marshal.WriteInt32(pkt, 0, 2); // DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
                    Marshal.WriteInt32(pkt, 4, TargetNameSize);
                    Marshal.WriteInt64(pkt, 8, tgtAdapter);
                    Marshal.WriteInt32(pkt, 16, tgtId);
                    if (map.ContainsKey(gdi)) continue; // duplicated/cloned display: first target wins
                    if (DisplayConfigGetDeviceInfo(pkt) != 0) { map[gdi] = new string[2]; continue; }
                    map[gdi] = new[] { Marshal.PtrToStringUni(pkt + 36), Marshal.PtrToStringUni(pkt + 164) };
                }
            }
            catch (Exception e) { Log.Write("display config: " + e.Message); }
            finally
            {
                if (paths != IntPtr.Zero) Marshal.FreeHGlobal(paths);
                if (modes != IntPtr.Zero) Marshal.FreeHGlobal(modes);
                if (pkt != IntPtr.Zero) Marshal.FreeHGlobal(pkt);
            }
            return map;
        }
    }

    /// Core Audio (MMDevice + WASAPI) via COM interop: the Windows default recording device (Sound settings > Input) and
    /// loopback capture of the default output device (system audio).
    static class AudioEndpoints
    {
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int flow, int stateMask, out IMMDeviceCollection devices);
            [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
        }

        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int Item(uint index, out IMMDevice device);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
            [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        }

        [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPropertyStore
        {
            void GetCount(); void GetAt();
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        }

        [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient
        {
            [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long latency);
            [PreserveSig] int GetCurrentPadding(out uint padding);
            [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr format);
            [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr handle);
            [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
        }

        [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioCaptureClient
        {
            [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
            [PreserveSig] int ReleaseBuffer(uint frames);
            [PreserveSig] int GetNextPacketSize(out uint frames);
        }

        [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid Fmt; public int Pid; }

        [StructLayout(LayoutKind.Explicit)]
        struct PropVariant
        {
            [FieldOffset(0)] public ushort Vt;
            [FieldOffset(8)] public IntPtr Ptr;
            [FieldOffset(16)] public IntPtr Pad; // 24 bytes on x64/ARM64 (16 on x86; the extra space is harmless)
        }

        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant v);

        const int ERender = 0, ECapture = 1, EConsole = 0;

        static string FriendlyName(IMMDevice dev)
        {
            IPropertyStore ps = null;
            try
            {
                if (dev.OpenPropertyStore(0 /* STGM_READ */, out ps) != 0 || ps == null) return null;
                var key = new PropertyKey { Fmt = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), Pid = 14 }; // PKEY_Device_FriendlyName
                PropVariant v;
                if (ps.GetValue(ref key, out v) != 0) return null;
                try { return v.Vt == 31 /* VT_LPWSTR */ ? Marshal.PtrToStringUni(v.Ptr) : null; }
                finally { PropVariantClear(ref v); }
            }
            finally { if (ps != null) Marshal.ReleaseComObject(ps); }
        }

        /// The default endpoint for a flow, or null (hr says why: E_NOTFOUND 0x80070490 = there is none).
        static IMMDevice Default(int flow, out int hr)
        {
            object en = new MMDeviceEnumerator();
            try
            {
                IMMDevice dev;
                hr = ((IMMDeviceEnumerator)en).GetDefaultAudioEndpoint(flow, EConsole, out dev);
                return hr == 0 ? dev : null;
            }
            finally { Marshal.ReleaseComObject(en); }
        }

        /// Friendly name of the default capture endpoint, e.g. "Microphone (HyperX Cloud Alpha Wireless)", or null.
        public static string DefaultMicName()
        {
            IMMDevice dev = null;
            try
            {
                int hr;
                dev = Default(ECapture, out hr);
                return dev == null ? null : FriendlyName(dev);
            }
            catch (Exception e) { Log.Write("default mic lookup: " + e.Message); return null; }
            finally { if (dev != null) Marshal.ReleaseComObject(dev); }
        }

        /// Ids and names of the active capture endpoints, sorted and joined, or null. Changes when a mic is plugged in,
        /// removed, enabled, disabled or renamed (what dshow lists as audio devices).
        public static string CaptureSignature()
        {
            object en = null;
            IMMDeviceCollection col = null;
            try
            {
                en = new MMDeviceEnumerator();
                uint n;
                if (((IMMDeviceEnumerator)en).EnumAudioEndpoints(ECapture, 1 /* DEVICE_STATE_ACTIVE */, out col) != 0 || col == null || col.GetCount(out n) != 0) return null;
                var l = new List<string>();
                for (uint i = 0; i < n; i++)
                {
                    IMMDevice dev;
                    if (col.Item(i, out dev) != 0 || dev == null) return null;
                    try
                    {
                        string id;
                        if (dev.GetId(out id) != 0) return null;
                        l.Add(id + "=" + FriendlyName(dev));
                    }
                    finally { Marshal.ReleaseComObject(dev); }
                }
                l.Sort(StringComparer.Ordinal);
                return string.Join("|", l);
            }
            catch (Exception e) { Log.Write("capture endpoints: " + e.Message); return null; }
            finally
            {
                if (col != null) Marshal.ReleaseComObject(col);
                if (en != null) Marshal.ReleaseComObject(en);
            }
        }

        /// One WASAPI loopback session on the default render endpoint (shared mode, its mix format, 200 ms buffer, polled).
        public sealed class Loopback : IDisposable
        {
            static readonly Guid SubFloat = new Guid("00000003-0000-0010-8000-00aa00389b71"), SubPcm = new Guid("00000001-0000-0010-8000-00aa00389b71");
            const int StreamFlagsLoopback = 0x00020000, BufferEmpty = 0x08890001;
            IMMDevice dev;
            IAudioClient client;
            IAudioCaptureClient cap;
            public string Id, Name;
            public int Rate, Channels, Bits, Block;
            public bool Float;
            byte[] raw = new byte[0];
            float[] st = new float[0];

            /// Id of the current default output device, or null when there is none.
            public static string DefaultId()
            {
                IMMDevice d = null;
                try
                {
                    int hr;
                    d = Default(ERender, out hr);
                    string id = null;
                    if (d != null) d.GetId(out id);
                    return id;
                }
                catch { return null; }
                finally { if (d != null) Marshal.ReleaseComObject(d); }
            }

            /// Opens loopback capture on the default output device; null (and why) when there is none or it fails.
            public static Loopback OpenDefault(out string why)
            {
                why = null;
                Loopback l = null;
                try
                {
                    int hr;
                    var d = Default(ERender, out hr);
                    if (d == null) { why = hr == unchecked((int)0x80070490) ? "none" : "0x" + hr.ToString("x8"); return null; }
                    l = new Loopback { dev = d };
                    d.GetId(out l.Id);
                    l.Name = FriendlyName(d) ?? "output device";
                    Guid iid = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
                    object o;
                    Check(d.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out o), "Activate");
                    l.client = (IAudioClient)o;
                    IntPtr fmt;
                    Check(l.client.GetMixFormat(out fmt), "GetMixFormat");
                    try
                    {
                        l.ParseFormat(fmt);
                        Check(l.client.Initialize(0 /* shared */, StreamFlagsLoopback, 2000000, 0, fmt, IntPtr.Zero), "Initialize");
                    }
                    finally { Marshal.FreeCoTaskMem(fmt); }
                    Guid ci = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
                    Check(l.client.GetService(ref ci, out o), "GetService");
                    l.cap = (IAudioCaptureClient)o;
                    Check(l.client.Start(), "Start");
                    return l;
                }
                catch (Exception e)
                {
                    why = e.Message;
                    if (l != null) l.Dispose();
                    return null;
                }
            }

            static void Check(int hr, string what) { if (hr < 0) throw new Exception(what + " 0x" + hr.ToString("x8")); }

            void ParseFormat(IntPtr p)
            {
                int tag = (ushort)Marshal.ReadInt16(p, 0);
                Channels = Marshal.ReadInt16(p, 2);
                Rate = Marshal.ReadInt32(p, 4);
                Block = Marshal.ReadInt16(p, 12);
                Bits = Marshal.ReadInt16(p, 14);
                Guid sub = tag == 0xFFFE ? (Guid)Marshal.PtrToStructure(IntPtr.Add(p, 24), typeof(Guid)) : Guid.Empty;
                Float = tag == 3 || sub == SubFloat;
                bool pcm = tag == 1 || sub == SubPcm;
                if (Channels < 1 || Rate < 8000 || Block < Channels * 2 || (!Float && !pcm) || (Float && Bits != 32) || (!Float && Bits != 16 && Bits != 24 && Bits != 32))
                    throw new Exception("unsupported mix format (tag " + tag + ", " + Bits + " bit, " + Channels + " ch)");
            }

            public string Describe() { return Rate + " Hz, " + Channels + " ch, " + Bits + "-bit " + (Float ? "float" : "PCM"); }

            /// Reads every waiting packet and hands it on as stereo float at the device rate with its QPC time (100 ns
            /// units; 0 when the device flags it as unreliable). Throws when the device is gone.
            public void Drain(Action<float[], int, int, ulong> sink)
            {
                uint next;
                Check(cap.GetNextPacketSize(out next), "GetNextPacketSize");
                while (next > 0)
                {
                    IntPtr data;
                    uint frames, flags;
                    ulong pos, qpc;
                    int hr = cap.GetBuffer(out data, out frames, out flags, out pos, out qpc);
                    Check(hr, "GetBuffer");
                    if (hr == BufferEmpty || frames == 0) { if (hr == 0) cap.ReleaseBuffer(frames); break; }
                    Convert(data, (int)frames, (flags & 2 /* SILENT */) != 0);
                    cap.ReleaseBuffer(frames);
                    sink(st, (int)frames, Rate, (flags & 4 /* TIMESTAMP_ERROR */) != 0 ? 0 : qpc);
                    Check(cap.GetNextPacketSize(out next), "GetNextPacketSize");
                }
            }

            /// Any channel layout -> stereo (centre and surrounds folded in at -3 dB).
            void Convert(IntPtr data, int frames, bool silent)
            {
                if (st.Length < frames * 2) st = new float[frames * 2];
                if (silent) { Array.Clear(st, 0, frames * 2); return; }
                int bytes = frames * Block;
                if (raw.Length < bytes) raw = new byte[bytes];
                Marshal.Copy(data, raw, 0, bytes);
                for (int i = 0; i < frames; i++)
                {
                    int o = i * Block;
                    float l = Sample(o, 0), r = Channels > 1 ? Sample(o, 1) : l;
                    if (Channels >= 3) { float c = Sample(o, 2) * 0.707f; l += c; r += c; }
                    if (Channels >= 6) { l += Sample(o, 4) * 0.707f; r += Sample(o, 5) * 0.707f; }
                    st[2 * i] = l;
                    st[2 * i + 1] = r;
                }
            }

            float Sample(int o, int ch)
            {
                int b = o + ch * (Bits / 8);
                if (Float) return BitConverter.ToSingle(raw, b);
                if (Bits == 16) return BitConverter.ToInt16(raw, b) / 32768f;
                if (Bits == 24) return ((raw[b] | raw[b + 1] << 8 | raw[b + 2] << 16) << 8 >> 8) / 8388608f;
                return BitConverter.ToInt32(raw, b) / 2147483648f;
            }

            public void Dispose()
            {
                try { if (client != null) client.Stop(); } catch { }
                if (cap != null) { Marshal.ReleaseComObject(cap); cap = null; }
                if (client != null) { Marshal.ReleaseComObject(client); client = null; }
                if (dev != null) { Marshal.ReleaseComObject(dev); dev = null; }
            }
        }
    }

    /// An open top-level window. Bounds are DWM extended frame bounds in physical pixels (what is visible on screen;
    /// the restored rectangle while minimized). Id = hash of hwnd + pid + exe: stable for the window's lifetime.
    class WindowInfo
    {
        public string Id, App, Exe, Title, MonitorId;
        public IntPtr Hwnd;
        public int Pid;
        public bool Minimized;
        public Rectangle Bounds;
    }

    struct WindowState
    {
        public bool Alive, Minimized;
        public Rectangle Bounds;
    }

    /// Win32 window enumeration and control (only used for window recordings and the inventory).
    static class WindowsApi
    {
        delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Native.RECT r);
        [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT wp);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint to, bool on);
        [DllImport("user32.dll")] static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out Native.RECT r, int size);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr proc, int flags, StringBuilder sb, ref int size);

        [StructLayout(LayoutKind.Sequential)]
        struct WINDOWPLACEMENT
        {
            public int Length, Flags, ShowCmd;
            public Native.POINT Min, Max;
            public Native.RECT Normal;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MSG { public IntPtr Hwnd; public uint Message; public IntPtr W, L; public uint Time; public Native.POINT Pt; }

        const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000;
        const int DWMWA_EXTENDED_FRAME_BOUNDS = 9, DWMWA_CLOAKED = 14;
        static readonly string[] ShellClasses = { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd" };
        static readonly Dictionary<string, string> AppNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        static string Text(IntPtr h)
        {
            int n = GetWindowTextLength(h);
            if (n <= 0) return "";
            var sb = new StringBuilder(Math.Min(n, 1024) + 1);
            GetWindowText(h, sb, sb.Capacity);
            return sb.ToString();
        }

        static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        static int PidOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid; }

        static bool Cloaked(IntPtr h)
        {
            int v;
            try { return DwmGetWindowAttribute(h, DWMWA_CLOAKED, out v, 4) == 0 && v != 0; }
            catch (DllNotFoundException) { return false; }
        }

        /// What the user sees: DWM extended frame bounds (no invisible resize borders), else GetWindowRect.
        static Rectangle FrameBounds(IntPtr h)
        {
            Native.RECT r;
            try { if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(Native.RECT))) == 0) return r.ToRectangle(); }
            catch (DllNotFoundException) { }
            return GetWindowRect(h, out r) ? r.ToRectangle() : Rectangle.Empty;
        }

        static Rectangle RestoredBounds(IntPtr h)
        {
            var wp = new WINDOWPLACEMENT { Length = Marshal.SizeOf(typeof(WINDOWPLACEMENT)) };
            return GetWindowPlacement(h, ref wp) ? wp.Normal.ToRectangle() : Rectangle.Empty;
        }

        static string ImagePath(int pid)
        {
            IntPtr p = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, pid);
            if (p == IntPtr.Zero) return null; // elevated or protected process
            try
            {
                var sb = new StringBuilder(1024);
                int n = sb.Capacity;
                return QueryFullProcessImageName(p, 0, sb, ref n) ? sb.ToString() : null;
            }
            finally { CloseHandle(p); }
        }

        /// "Google Chrome" from the exe's version info (FileDescription, else ProductName), else the exe name.
        static string AppName(string path, string exe)
        {
            if (path == null) return exe.Length > 0 ? Path.GetFileNameWithoutExtension(exe) : "";
            string name;
            if (AppNames.TryGetValue(path, out name)) return name;
            try
            {
                var v = FileVersionInfo.GetVersionInfo(path);
                name = !string.IsNullOrWhiteSpace(v.FileDescription) ? v.FileDescription.Trim() : !string.IsNullOrWhiteSpace(v.ProductName) ? v.ProductName.Trim() : null;
            }
            catch { name = null; }
            if (string.IsNullOrEmpty(name)) name = Path.GetFileNameWithoutExtension(exe);
            AppNames[path] = name;
            return name;
        }

        /// Alt-Tab style list in z-order (topmost first): visible, not cloaked (other virtual desktops, suspended UWP),
        /// not tool windows, unowned (or app windows), with a title, not the shell and not this process (pill, bubble).
        public static List<WindowInfo> List(List<MonitorInfo> monitors, int max)
        {
            var list = new List<WindowInfo>();
            int self = Process.GetCurrentProcess().Id;
            EnumWindowsProc proc = delegate (IntPtr h, IntPtr d)
            {
                if (list.Count >= max) return false;
                try
                {
                    if (!IsWindowVisible(h)) return true;
                    int ex = GetWindowLong(h, GWL_EXSTYLE);
                    if ((ex & WS_EX_TOOLWINDOW) != 0) return true;
                    if (GetWindow(h, 4 /* GW_OWNER */) != IntPtr.Zero && (ex & WS_EX_APPWINDOW) == 0) return true;
                    int pid = PidOf(h);
                    if (pid == self || Cloaked(h)) return true;
                    string title = Text(h);
                    if (title.Trim().Length == 0 || Array.IndexOf(ShellClasses, ClassOf(h)) >= 0) return true;
                    // UWP apps live in ApplicationFrameHost: name them after the hosted app's process.
                    string path = ImagePath(pid);
                    if (path != null && Path.GetFileName(path).Equals("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase))
                    {
                        IntPtr core = FindWindowEx(h, IntPtr.Zero, "Windows.UI.Core.CoreWindow", null);
                        string inner = core != IntPtr.Zero ? ImagePath(PidOf(core)) : null;
                        if (inner != null) path = inner;
                    }
                    string exe = path != null ? Path.GetFileName(path) : "";
                    bool min = IsIconic(h);
                    var w = new WindowInfo
                    {
                        Hwnd = h, Pid = pid, Exe = exe, App = AppName(path, exe), Title = title, Minimized = min,
                        Bounds = min ? RestoredBounds(h) : FrameBounds(h),
                    };
                    w.Id = DeviceMatch.WindowId(h, pid, exe);
                    string dev = Displays.DeviceNameOf(MonitorFromWindow(h, 2 /* MONITOR_DEFAULTTONEAREST; restored rect when minimized */));
                    var mon = dev == null ? null : monitors.Find(m => string.Equals(m.DeviceName, dev, StringComparison.OrdinalIgnoreCase));
                    w.MonitorId = mon != null ? mon.Id : "";
                    list.Add(w);
                }
                catch (Exception e) { Log.Write("window enumeration: " + e.Message); }
                return true;
            };
            EnumWindows(proc, IntPtr.Zero);
            GC.KeepAlive(proc);
            return list;
        }

        /// Live state of a listed window. Not alive once it is closed or its handle was reused by another process.
        public static WindowState Probe(WindowInfo w)
        {
            var s = new WindowState();
            if (!IsWindow(w.Hwnd) || PidOf(w.Hwnd) != w.Pid) return s;
            s.Alive = true;
            s.Minimized = IsIconic(w.Hwnd) || !IsWindowVisible(w.Hwnd) || Cloaked(w.Hwnd);
            s.Bounds = s.Minimized ? RestoredBounds(w.Hwnd) : FrameBounds(w.Hwnd);
            return s;
        }

        /// Restores a minimized window and brings it to the front. Windows only lets the foreground process change the
        /// foreground window, so this attaches to the foreground thread's input first; if that is refused the window is at
        /// least raised above the other windows (no activation). No input is injected.
        public static string BringToFront(WindowInfo w)
        {
            IntPtr h = w.Hwnd;
            if (IsIconic(h))
            {
                ShowWindowAsync(h, 9 /* SW_RESTORE */);
                for (int i = 0; i < 20 && IsIconic(h); i++) Thread.Sleep(50);
            }
            IntPtr fg = Native.GetForegroundWindow();
            if (fg == h) return "already in front";
            MSG m;
            PeekMessage(out m, IntPtr.Zero, 0, 0, 0); // give this thread an input queue so it can attach
            uint dummy, fgThread = fg != IntPtr.Zero ? GetWindowThreadProcessId(fg, out dummy) : 0, me = GetCurrentThreadId();
            bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
            try
            {
                BringWindowToTop(h);
                Native.SetForegroundWindow(h);
            }
            finally { if (attached) AttachThreadInput(me, fgThread, false); }
            if (Native.GetForegroundWindow() == h) return "foreground";
            const uint flags = 0x0001 | 0x0002 | 0x0010; // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
            SetWindowPos(h, (IntPtr)(-1) /* HWND_TOPMOST */, 0, 0, 0, 0, flags);
            SetWindowPos(h, (IntPtr)(-2) /* HWND_NOTOPMOST */, 0, 0, 0, 0, flags);
            return "raised (foreground refused)";
        }
    }

    /// A monitor the agent can record. Index is the inventory position: DXGI order (adapter-major), so for monitors on
    /// the default adapter it equals ddagrab's output_idx. OutputIdx is -1 when ddagrab cannot reach it (gdigrab is used).
    class MonitorInfo
    {
        public string Id, DeviceName, FriendlyName, Label;
        public int Index, OutputIdx = -1, Rank, Dpi = 96;
        public bool Primary;
        public Rectangle Bounds, WorkArea;
    }

    /// A DirectShow microphone or camera. Path is the unique device moniker ("Alternative name"), used for ffmpeg.
    class AvDevice
    {
        public string Id, Name, Path;
        public bool IsDefault;
        public string FfmpegName { get { return Path ?? Name; } }
    }

    class AvDevices
    {
        public readonly List<AvDevice> Mics = new List<AvDevice>(), Cameras = new List<AvDevice>();
    }

    /// Device ids, labels, matching and the inventory report. Pure logic (no OS calls) so the selftest covers it;
    /// worker/src/devices.ts implements the same matching rules for the server-side check.
    static class DeviceMatch
    {
        public static string StableId(string prefix, string key)
        {
            using (var sha = SHA256.Create())
            {
                var h = sha.ComputeHash(Encoding.UTF8.GetBytes((key ?? "").ToLowerInvariant()));
                var sb = new StringBuilder(prefix).Append('_');
                for (int i = 0; i < 5; i++) sb.Append(h[i].ToString("x2"));
                return sb.ToString();
            }
        }

        /// Left-to-right rank and a left/center/right label (one monitor = center).
        public static void Label(List<MonitorInfo> ms)
        {
            var order = new List<MonitorInfo>(ms);
            order.Sort((a, b) => a.Bounds.Left != b.Bounds.Left ? a.Bounds.Left.CompareTo(b.Bounds.Left) : a.Bounds.Top.CompareTo(b.Bounds.Top));
            for (int i = 0; i < order.Count; i++)
            {
                order[i].Rank = i;
                order[i].Label = order.Count == 1 ? "center" : i == 0 ? "left" : i == order.Count - 1 ? "right" : "center";
            }
        }

        static readonly string[] PrimaryWords = { "primary", "main", "default" };
        static readonly string[] SecondaryWords = { "secondary", "second", "2nd", "other", "external", "non-primary" };

        /// Resolves "primary", an index, an id, a device name, left/right/center, "second"/"other" (the only non-primary
        /// monitor) or a unique part of the model name. Null when unknown or ambiguous.
        public static MonitorInfo Monitor(List<MonitorInfo> ms, string query)
        {
            string q = (query ?? "").Trim().ToLowerInvariant();
            if (q.Length == 0 || Array.IndexOf(PrimaryWords, q) >= 0) return ms.Find(m => m.Primary) ?? (ms.Count > 0 ? ms[0] : null);
            int n;
            if (int.TryParse(q, out n)) return ms.Find(m => m.Index == n);
            var hit = ms.Find(m => m.Id == q);
            if (hit != null) return hit;
            hit = ms.Find(m => string.Equals(m.DeviceName, query.Trim(), StringComparison.OrdinalIgnoreCase) || m.DeviceName.ToLowerInvariant().TrimStart('\\', '.') == q);
            if (hit != null) return hit;
            if (q == "middle") q = "center";
            if (q == "left" || q == "right" || q == "center") return Unique(ms.FindAll(m => m.Label == q));
            if (Array.IndexOf(SecondaryWords, q) >= 0) return Unique(ms.FindAll(m => !m.Primary));
            return Unique(ms.FindAll(m => !string.IsNullOrEmpty(m.FriendlyName) && m.FriendlyName.ToLowerInvariant().Contains(q)));
        }

        /// Resolves an id, exact name, device path, "default" or a unique part of the name ("HyperX"). Null otherwise.
        public static AvDevice Av(List<AvDevice> ds, string query)
        {
            string q = (query ?? "").Trim().ToLowerInvariant();
            if (q.Length == 0) return null;
            var hit = ds.Find(d => d.Id == q || d.Name.ToLowerInvariant() == q || (d.Path != null && d.Path.ToLowerInvariant() == q));
            if (hit != null) return hit;
            if (q == "default") return ds.Find(d => d.IsDefault);
            return Unique(ds.FindAll(d => d.Name.ToLowerInvariant().Contains(q)));
        }

        static T Unique<T>(List<T> l) where T : class { return l.Count == 1 ? l[0] : null; }

        public const int MaxWindows = 40;

        public static string WindowId(IntPtr hwnd, int pid, string exe)
        {
            return StableId("win", hwnd.ToInt64() + "|" + pid + "|" + (exe ?? ""));
        }

        static readonly string[] WindowFiller = { "the", "my", "a", "an", "this", "that", "window", "app", "application", "tab", "open", "opened", "with", "and", "of", "on", "in" };

        public static List<string> WindowTokens(string query)
        {
            var l = new List<string>();
            foreach (var t in (query ?? "").Trim().ToLowerInvariant().Split((char[])null, StringSplitOptions.RemoveEmptyEntries))
                if (Array.IndexOf(WindowFiller, t) < 0) l.Add(t);
            return l;
        }

        /// An id, an exact title, or tokens that must all appear in "app exe title" ("chrome youtube"). Null when no
        /// window or more than one matches: the recorder never guesses (the server already asked the user).
        public static WindowInfo Window(List<WindowInfo> ws, string query)
        {
            string q = (query ?? "").Trim().ToLowerInvariant();
            if (q.Length == 0) return null;
            var hit = ws.Find(w => w.Id == q);
            if (hit != null) return hit;
            var exact = ws.FindAll(w => (w.Title ?? "").ToLowerInvariant() == q);
            if (exact.Count == 1) return exact[0];
            var tokens = WindowTokens(q);
            if (tokens.Count == 0) return null;
            return Unique(ws.FindAll(w =>
            {
                string hay = ((w.App ?? "") + " " + (w.Exe ?? "") + " " + (w.Title ?? "")).ToLowerInvariant();
                return tokens.TrueForAll(t => hay.Contains(t));
            }));
        }

        /// Parses `ffmpeg -list_devices true -f dshow -i dummy` output. "(none)" entries are usually virtual cameras
        /// (OBS) and are listed after the real ones. Each device's "Alternative name" line becomes its Path.
        public static AvDevices ParseDshow(string err)
        {
            var d = new AvDevices();
            var other = new List<AvDevice>();
            var current = new List<AvDevice>();
            foreach (var line in err.Split('\n'))
            {
                int a = line.IndexOf('"'), b = line.LastIndexOf('"');
                if (a < 0 || b <= a) continue;
                string val = line.Substring(a + 1, b - a - 1);
                if (line.Contains("Alternative name"))
                {
                    foreach (var c in current) if (c.Path == null) c.Path = val;
                    continue;
                }
                current.Clear();
                string tail = line.Substring(b + 1);
                bool audio = tail.Contains("audio"), video = tail.Contains("video"), none = tail.Contains("(none)");
                if (audio) { var m = new AvDevice { Name = val }; d.Mics.Add(m); current.Add(m); }
                if (video) { var v = new AvDevice { Name = val }; d.Cameras.Add(v); current.Add(v); }
                if (none && !audio && !video) { var o = new AvDevice { Name = val }; other.Add(o); current.Add(o); }
            }
            d.Cameras.AddRange(other);
            foreach (var m in d.Mics) m.Id = StableId("mic", m.FfmpegName);
            foreach (var c in d.Cameras) c.Id = StableId("cam", c.FfmpegName);
            return d;
        }

        /// Marks the dshow microphone matching the Windows default endpoint. dshow can cut names at 31 characters.
        public static void MarkDefaultMic(List<AvDevice> mics, string friendly)
        {
            if (string.IsNullOrEmpty(friendly)) return;
            var hit = mics.Find(m => string.Equals(m.Name, friendly, StringComparison.OrdinalIgnoreCase))
                ?? Unique(mics.FindAll(m => m.Name.Length >= 16 && (friendly.StartsWith(m.Name, StringComparison.OrdinalIgnoreCase) || m.Name.StartsWith(friendly, StringComparison.OrdinalIgnoreCase))));
            if (hit != null) hit.IsDefault = true;
        }

        static string Cut(string s, int max = 128) { s = s ?? ""; return s.Length > max ? s.Substring(0, max) : s; }

        /// The device-inventory report sent over the device WebSocket ({"type":"devices",...}).
        public static string InventoryJson(string requestId, List<MonitorInfo> ms, AvDevices av, List<WindowInfo> windows)
        {
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            var sb = new StringBuilder("{\"type\":\"devices\",\"request_id\":").Append(Json.Esc(requestId ?? "")).Append(",\"monitors\":[");
            for (int i = 0; i < ms.Count && i < 16; i++)
            {
                var m = ms[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"id\":").Append(Json.Esc(m.Id)).Append(",\"index\":").Append(m.Index).Append(",\"output_idx\":").Append(m.OutputIdx)
                    .Append(",\"name\":").Append(Json.Esc(Cut(m.DeviceName))).Append(",\"friendly_name\":").Append(Json.Esc(Cut(m.FriendlyName)))
                    .Append(",\"primary\":").Append(m.Primary ? "true" : "false")
                    .Append(",\"x\":").Append(m.Bounds.X).Append(",\"y\":").Append(m.Bounds.Y)
                    .Append(",\"width\":").Append(m.Bounds.Width).Append(",\"height\":").Append(m.Bounds.Height)
                    .Append(",\"scale\":").Append((m.Dpi / 96.0).ToString("0.##", inv))
                    .Append(",\"position\":").Append(m.Rank).Append(",\"label\":").Append(Json.Esc(m.Label)).Append('}');
            }
            sb.Append("],\"mics\":[");
            AppendAv(sb, av == null ? null : av.Mics, true);
            sb.Append("],\"cameras\":[");
            AppendAv(sb, av == null ? null : av.Cameras, false);
            sb.Append("],\"windows\":[");
            for (int i = 0; windows != null && i < windows.Count && i < MaxWindows; i++)
            {
                var w = windows[i];
                if (i > 0) sb.Append(',');
                // Titles are cut to keep the report small (40 windows stay well under the server's 32 KB frame limit).
                sb.Append("{\"id\":").Append(Json.Esc(w.Id)).Append(",\"app\":").Append(Json.Esc(Cut(w.App, 64)))
                    .Append(",\"exe\":").Append(Json.Esc(Cut(w.Exe, 64))).Append(",\"title\":").Append(Json.Esc(Cut(w.Title, 120)))
                    .Append(",\"monitor\":").Append(Json.Esc(w.MonitorId ?? "")).Append(",\"minimized\":").Append(w.Minimized ? "true" : "false")
                    .Append(",\"x\":").Append(w.Bounds.X).Append(",\"y\":").Append(w.Bounds.Y)
                    .Append(",\"width\":").Append(Math.Max(0, w.Bounds.Width)).Append(",\"height\":").Append(Math.Max(0, w.Bounds.Height)).Append('}');
            }
            return sb.Append("]}").ToString();
        }

        static void AppendAv(StringBuilder sb, List<AvDevice> l, bool withDefault)
        {
            if (l == null) return;
            for (int i = 0; i < l.Count && i < 32; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"id\":").Append(Json.Esc(l[i].Id)).Append(",\"name\":").Append(Json.Esc(Cut(l[i].Name)));
                if (withDefault) sb.Append(",\"default\":").Append(l[i].IsDefault ? "true" : "false");
                sb.Append('}');
            }
        }
    }

    /// Enumerates what can be recorded. Monitors are cheap (no child process); audio/video devices may be slow.
    interface IDeviceCatalog
    {
        List<MonitorInfo> Monitors();
        /// Lists the mics and cameras now (about 0.5 s) and caches the result for CachedAudioVideo.
        AvDevices AudioVideo();
        /// The cached list while the capture devices have not changed since it was made (checked in a few ms), else
        /// AudioVideo(). The default mic is marked at each call.
        AvDevices CachedAudioVideo();
        /// Open top-level windows in z-order (topmost first), at most DeviceMatch.MaxWindows.
        List<WindowInfo> Windows(List<MonitorInfo> monitors);
        WindowState Probe(WindowInfo w);
        /// Restores and raises the window; returns what happened (for the log).
        string BringToFront(WindowInfo w);
    }

    class CaptureSpec
    {
        public MonitorInfo Monitor;
        public string Video, Encoder;
        public int MaxSeconds, Fps;
        public long MaxBytes;
        /// Receives ffmpeg's -progress lines (segment timing for the system audio and the mute spans).
        public FfProgress Progress;
        /// Window recordings: the part of Monitor to show (monitor-relative pixels), letterboxed into Output.
        public WindowView? Region;
        public Size Output;
        /// VideoChain path (gpu / gpu-scale / cpu) for this segment.
        public string Path = VideoChain.Cpu;
    }

    /// What a window recording shows: a crop of the recorded monitor (monitor-relative physical pixels), or black.
    struct WindowView
    {
        public Rectangle Crop;
        public bool Blank;
    }

    /// Pure geometry and command logic for window recordings (no OS calls; covered by the selftest).
    static class WindowTrack
    {
        /// Fixed video size for a window: its size scaled to fit 1920x1080 (never up), even, at least 2x2.
        public static Size OutputSize(Size s)
        {
            double k = Math.Min(1.0, Math.Min(1920.0 / Math.Max(1, s.Width), 1080.0 / Math.Max(1, s.Height)));
            return new Size(Math.Max(2, (int)(s.Width * k) / 2 * 2), Math.Max(2, (int)(s.Height * k) / 2 * 2));
        }

        static long Area(Rectangle r) { return r.Width <= 0 || r.Height <= 0 ? 0 : (long)r.Width * r.Height; }

        /// Fraction of r that lies on the monitor.
        public static double Share(Rectangle r, Rectangle monitor)
        {
            long a = Area(r);
            return a == 0 ? 0 : Area(Rectangle.Intersect(r, monitor)) / (double)a;
        }

        /// The monitor holding most of r (null when r is on none).
        public static MonitorInfo MostlyOn(List<MonitorInfo> ms, Rectangle r)
        {
            MonitorInfo best = null;
            long bestA = 0;
            foreach (var m in ms)
            {
                long a = Area(Rectangle.Intersect(r, m.Bounds));
                if (a > bestA) { bestA = a; best = m; }
            }
            return best;
        }

        /// The view for the window's current state on the recorded monitor: the visible part of the window, or black
        /// (keeping the last crop) while it is minimized, closed or off this monitor.
        public static WindowView View(Rectangle window, bool minimized, bool alive, Rectangle monitor, WindowView last)
        {
            var vis = Rectangle.Intersect(window, monitor);
            if (!alive || minimized || vis.Width < 16 || vis.Height < 16) return new WindowView { Crop = last.Crop, Blank = true };
            vis.Offset(-monitor.X, -monitor.Y);
            return new WindowView { Crop = vis, Blank = false };
        }

        /// ffmpeg filter commands that turn view a into b, changed parameters only. Hiding comes first and showing last,
        /// so a half-applied update never shows the wrong region.
        public static List<string> Commands(WindowView a, WindowView b)
        {
            var c = new List<string>();
            if (b.Blank && !a.Blank) c.Add("drawbox@hide -1 x 0");
            if (b.Crop.Width != a.Crop.Width) c.Add("crop@win -1 w " + b.Crop.Width);
            if (b.Crop.Height != a.Crop.Height) c.Add("crop@win -1 h " + b.Crop.Height);
            if (b.Crop.X != a.Crop.X) c.Add("crop@win -1 x " + b.Crop.X);
            if (b.Crop.Y != a.Crop.Y) c.Add("crop@win -1 y " + b.Crop.Y);
            if (!b.Blank && a.Blank) c.Add("drawbox@hide -1 x iw");
            return c;
        }

        /// Filter chain for a window recording: crop (updated live), pad to the output aspect (re-evaluated per frame,
        /// so a resized window is letterboxed, not stretched), scale to the fixed size, and a full-frame black box that
        /// sits off-frame (x=iw) until the window is minimized or closed.
        public static string Filter(WindowView v, Size output)
        {
            var c = v.Crop;
            // ih*W/H and iw*H/W evaluate exactly for integers (iw/(W/H) can round up one pixel too many).
            return "crop@win=w=" + c.Width + ":h=" + c.Height + ":x=" + c.X + ":y=" + c.Y
                + ",pad=w='max(iw\\,ceil(ih*" + output.Width + "/" + output.Height + "))':h='max(ih\\,ceil(iw*" + output.Height + "/" + output.Width + "))'"
                + ":x='(ow-iw)/2':y='(oh-ih)/2':eval=frame"
                + ",scale=" + output.Width + ":" + output.Height + ":flags=fast_bilinear,format=nv12"
                + ",drawbox@hide=x=" + (v.Blank ? "0" : "iw") + ":y=0:w=iw:h=ih:color=black:t=fill";
        }
    }

    /// What the GPU (with the chosen encoder) can do with Desktop Duplication's D3D11 frames, probed once.
    struct GpuCaps
    {
        /// The encoder takes D3D11 frames directly (zero-copy, no download).
        public bool Native;
        /// scale_d3d11 can resize them for that encoder.
        public bool Scale;
    }

    /// How screen frames reach the encoder. Pure (no OS calls; covered by the selftest), chosen per source size, never
    /// per resolution name. Desktop Duplication hands out D3D11 textures:
    ///   gpu        straight into a hardware encoder at the source size: zero-copy, nothing touches the CPU;
    ///   gpu-scale  resized on the GPU (scale_d3d11) to fit 1920x1080 first, then the hardware encoder;
    ///   cpu        downloaded to system memory and cropped/scaled/converted by ffmpeg (any encoder, window crops,
    ///              gdigrab). The last fallback everywhere.
    /// Measured on an RTX 4060 Ti (real time, synthetic D3D11 frames): gpu keeps 30 fps from 720p to 3840x2160 for ~0 CPU;
    /// cpu keeps 30 fps up to 5120x1440 for ~0.4-1 core at 1440p and above.
    /// scale_d3d11 in ffmpeg 9.0.2 fails to create its output texture on NVIDIA, so there 1440p and 4K go out at their
    /// own size (gpu) and only sources wider or taller than the encoder's limit fall back to cpu.
    static class VideoChain
    {
        public const string Gpu = "gpu", GpuScale = "gpu-scale", Cpu = "cpu";
        /// Largest frame side the hardware H.264 encoders accept (NVENC, Quick Sync and AMF all stop at 4096).
        public const int MaxHwSide = 4096;

        public static bool HardwareEncoder(string encoder)
        {
            return encoder == "h264_nvenc" || encoder == "h264_qsv" || encoder == "h264_amf";
        }

        /// "auto" (default), "gpu" or "cpu" (config video_path / --video-path); anything else is auto.
        public static string Normalize(string v)
        {
            v = (v ?? "").Trim().ToLowerInvariant();
            return v == Gpu || v == Cpu ? v : "auto";
        }

        /// Paths to try for one segment, best first; cpu is always last. Window recordings follow the window with live
        /// crop commands, which only the cpu chain has (a crop on D3D11 frames is ignored by the encoders).
        public static List<string> Candidates(Size source, bool window, bool desktopDuplication, string encoder, string forced, GpuCaps caps)
        {
            var l = new List<string>();
            if (desktopDuplication && !window && Normalize(forced) != Cpu && HardwareEncoder(encoder) && caps.Native)
            {
                if (WindowTrack.OutputSize(source) != source && caps.Scale) l.Add(GpuScale);
                if (source.Width <= MaxHwSide && source.Height <= MaxHwSide) l.Add(Gpu);
            }
            l.Add(Cpu);
            return l;
        }

        /// Video size a path produces from a whole-monitor source: the source itself for gpu, else fitted into 1920x1080.
        public static Size Output(string path, Size source)
        {
            return path == Gpu ? source : WindowTrack.OutputSize(source);
        }

        /// What hands D3D11 frames to the encoder: NVENC and AMF take them as they are, Quick Sync needs them mapped to
        /// its own surfaces (same GPU memory, no copy). Not tried on an Intel GPU yet; ProbeGpu gates it.
        public static string NativeInput(string encoder)
        {
            return encoder == "h264_qsv" ? "hwmap=derive_device=qsv,format=qsv" : "";
        }

        /// The -vf chain for a whole-monitor capture ("" = none: frames go to the encoder as they are).
        public static string Filter(string path, Size output, bool desktopDuplication, string encoder)
        {
            string native = NativeInput(encoder);
            if (path == Gpu) return native;
            if (path == GpuScale) return "scale_d3d11=width=" + output.Width + ":height=" + output.Height + ":format=nv12" + (native.Length > 0 ? "," + native : "");
            return (desktopDuplication ? "hwdownload,format=bgra," : "")
                + "scale=" + output.Width + ":" + output.Height + ":flags=fast_bilinear,format=nv12";
        }

        /// Encoder options for an output size: above 1920x1080 the bitrate cap rises from 4.5 to 5 Mbps (still under the
        /// 80 MB upload cap for 2 min with audio), so 1440p/4K text stays sharp.
        /// A keyframe about every 100 ms in a segment's first 2 s (the GOP is 2 s): the mix cuts the video's head off at
        /// the first keyframe after the mic starts (at most 500 ms in), as a stream copy (AudioMath.StartTrim). nvenc marks a forced frame as
        /// a keyframe only when it is an IDR.
        public static string EarlyKeys(int fps, string encoder)
        {
            int every = Math.Max(1, (int)Math.Round(fps / 10.0));
            return "-force_key_frames \"expr:lt(t,2)*not(mod(n," + every + "))\"" + (encoder == "h264_nvenc" ? " -forced-idr 1" : "");
        }

        public static string EncoderOptions(string options, Size output)
        {
            if ((long)output.Width * output.Height <= 1920L * 1080) return options;
            return options.Replace("-b:v 3500k", "-b:v 4500k").Replace("-maxrate 4500k", "-maxrate 5000k").Replace("-bufsize 9000k", "-bufsize 10000k");
        }
    }

    /// Screen and camera capture. The returned processes stop gracefully on "q" written to stdin.
    interface ICaptureBackend
    {
        /// The encoder for the next capture: the pinned one (`encoder=`), else the cached probe result (probing now if none).
        string PickEncoder(string preference);
        /// Probes the encoders and caches the first that works. Without force, only when nothing is cached yet or the
        /// display adapters changed since (agent start, device reports); force after a capture that failed.
        string ProbeEncoder(bool force);
        /// Whether the encoder takes Desktop Duplication's GPU frames as they are, and whether the GPU can scale them.
        /// Cached per encoder while the display adapters stay the same (probed with the encoder, ahead of any start).
        GpuCaps ProbeGpu(string encoder);
        /// Desktop Duplication can capture this monitor (otherwise only the compatibility path is used).
        bool CanUseFastPath(MonitorInfo m);
        Process StartScreen(CaptureSpec spec, bool fastPath);
        /// The mic, in its own process for the whole recording, to a 48 kHz mono WAV through a named volume filter (muting
        /// sends "volume@mic ... 0"). Its -progress lines go to progress (when sample 0 was on the shared clock).
        Process StartMic(AvDevice mic, string wav, bool muted, int maxSeconds, FfProgress progress);
        /// Live filter commands to a running capture (WindowTrack.Commands, the mic's volume). Each takes about 100 ms to apply.
        void SendCommands(Process capture, List<string> commands);
        /// Muxes the video with its audio: inputs video, then mic and system WAVs (null = absent), through
        /// AudioMath.MixFilter; writes the final MP4 (video copied from `seek` seconds, a keyframe; AAC) and, only with a mic,
        /// the 16 kHz mono WAV for transcription (the mic alone).
        void MixAudio(string video, double seek, string mic, string sys, string filter, string outVideo, string outWav);
        /// Keyframe times in the first `seconds` of a video (seconds from its first packet).
        List<double> Keyframes(string video, double seconds);
        /// ffmpeg -i's listing of a file (duration, streams), for Stills.Probe.
        string MediaInfo(string video);
        /// One still for Stills: the frame at `ms` as a JPEG (quality Stills.Quality), at most Stills.MaxWidth wide.
        void Still(string video, long ms, string jpg);
        /// Joins recordings made with identical settings (window moved to another monitor) without re-encoding.
        void Concat(List<string> parts, string output);
        /// A process writing bgr24 frames (width x height, centre-cropped to that aspect) of the camera to stdout at 30 fps.
        ProcessStartInfo CameraProcess(AvDevice camera, int width, int height, bool sized);
        /// An idle ffmpeg kept resident between recordings (WarmKeeper): no device, no file, blocked on its stdin.
        WarmKeeper.IHandle StartWarm();
    }

    /// Windows: ddagrab (Desktop Duplication) with a gdigrab fallback, DirectShow mic/camera, DXGI + Win32 monitor lists.
    class WindowsFfmpegBackend : ICaptureBackend, IDeviceCatalog
    {
        readonly string ffmpeg;
        /// Dev only (--test-camera, also on the agent): the bubble shows a moving test pattern instead of the camera.
        public bool TestCamera;
        /// Dev only (--no-front, also on the agent): a recorded window is left where it is, never activated.
        public bool NoFront;
        /// Screen and camera ffmpeg run above normal so a busy desktop cannot starve them into dropped frames. Dev runs
        /// beside someone's game lower it (--record-local --below-normal).
        public static ProcessPriorityClass CapturePriority = ProcessPriorityClass.AboveNormal;

        public WindowsFfmpegBackend(string ffmpeg) { this.ffmpeg = ffmpeg; }

        public List<MonitorInfo> Monitors()
        {
            var displays = Displays.All();
            var names = MonitorNames.Query();
            var list = new List<MonitorInfo>();
            Action<Display, int> add = delegate (Display d, int outputIdx)
            {
                string[] nm;
                names.TryGetValue(d.DeviceName, out nm);
                list.Add(new MonitorInfo
                {
                    DeviceName = d.DeviceName, Primary = d.Primary, Bounds = d.Bounds, WorkArea = d.WorkArea, OutputIdx = outputIdx,
                    FriendlyName = nm != null && !string.IsNullOrEmpty(nm[0]) ? nm[0] : null,
                    Id = DeviceMatch.StableId("mon", nm != null && !string.IsNullOrEmpty(nm[1]) ? nm[1] : d.DeviceName),
                    Dpi = Native.DpiAt(Displays.Center(d.Bounds)),
                });
            };
            foreach (var o in Dxgi.Outputs())
            {
                var d = displays.Find(x => string.Equals(x.DeviceName, o.DeviceName, StringComparison.OrdinalIgnoreCase));
                if (d == null || list.Exists(m => m.DeviceName == d.DeviceName)) continue;
                add(d, o.Adapter == 0 ? o.Index : -1);
            }
            foreach (var d in displays) if (!list.Exists(m => m.DeviceName == d.DeviceName)) add(d, -1);
            for (int i = 0; i < list.Count; i++) list[i].Index = i;
            DeviceMatch.Label(list);
            return list;
        }

        readonly object avGate = new object();
        AvDevices avCache;
        string avKey;

        /// What changes when a mic or camera is added, removed, enabled or disabled; null when it cannot be read.
        static string DeviceSignature()
        {
            string mics = AudioEndpoints.CaptureSignature();
            string ks = Native.DeviceInterfaces(new Guid("65E8773D-8F56-11D0-A3B9-00A0C9223196")); // KSCATEGORY_CAPTURE
            string cams = Native.DeviceInterfaces(new Guid("E5323777-F976-4F5B-9B55-B94699C46E44")); // KSCATEGORY_VIDEO_CAMERA
            return mics == null || ks == null || cams == null ? null : mics + "#" + ks + "#" + cams;
        }

        public AvDevices CachedAudioVideo()
        {
            string key = DeviceSignature();
            AvDevices d;
            lock (avGate) d = key != null && key == avKey ? avCache : null;
            return d != null ? Marked(d) : AudioVideo();
        }

        /// A copy of the list with the Windows default mic marked now (it changes without any device change).
        static AvDevices Marked(AvDevices src)
        {
            var d = new AvDevices();
            foreach (var m in src.Mics) d.Mics.Add(new AvDevice { Id = m.Id, Name = m.Name, Path = m.Path });
            foreach (var c in src.Cameras) d.Cameras.Add(new AvDevice { Id = c.Id, Name = c.Name, Path = c.Path });
            DeviceMatch.MarkDefaultMic(d.Mics, AudioEndpoints.DefaultMicName());
            return d;
        }

        public AvDevices AudioVideo()
        {
            string key = DeviceSignature(); // read first: a change during the listing then misses the cache next time
            var psi = new ProcessStartInfo(ffmpeg, "-hide_banner -list_devices true -f dshow -i dummy")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            string err;
            using (var p = Process.Start(psi))
            {
                Native.AddToKillJob(p);
                err = p.StandardError.ReadToEnd();
                p.WaitForExit(5000);
            }
            var d = DeviceMatch.ParseDshow(err);
            lock (avGate) { avCache = d; avKey = key; }
            return Marked(d);
        }

        public List<WindowInfo> Windows(List<MonitorInfo> monitors) { return WindowsApi.List(monitors, DeviceMatch.MaxWindows); }
        public WindowState Probe(WindowInfo w) { return WindowsApi.Probe(w); }
        public string BringToFront(WindowInfo w) { return NoFront ? "left in place (--no-front)" : WindowsApi.BringToFront(w); }

        // 15 fps read as choppy (Tyler, 2026-11-15). Default is now 30 fps with a hardware encoder when present
        // (motion test on RTX 4060 Ti: NVENC 30 fps = 240/240 unique frames, 0 drops). Bitrate is capped at
        // ~4.5 Mbps so a 2-min video stays under the 80 MB upload cap. `encoder=<name>` pins one; `fps=` 15-60.
        static readonly string[][] Encoders =
        {
            new[] { "h264_nvenc", "-preset p4 -tune ll -rc vbr -cq 28 -b:v 3500k -maxrate 4500k -bufsize 9000k" },
            new[] { "h264_qsv", "-preset veryfast -b:v 3500k -maxrate 4500k -bufsize 9000k" },
            new[] { "h264_amf", "-quality speed -rc vbr_peak -b:v 3500k -maxrate 4500k -bufsize 9000k" },
            new[] { "h264_mf", "-b:v 3500k" },
            new[] { "libx264", "-preset veryfast -tune zerolatency -crf 26 -maxrate 4500k -bufsize 9000k -threads 4" },
        };

        readonly object probeGate = new object();
        volatile string encoderCache;
        /// The display adapters present when encoderCache was probed (a GPU or driver change can change what works).
        string probedFor;

        public string PickEncoder(string preference)
        {
            string want = preference ?? "auto";
            if (want != "auto") return want;
            var cached = encoderCache;
            if (cached != null) return cached;
            lock (probeGate) return encoderCache ?? Probe(); // waits for a probe already under way
        }

        public string ProbeEncoder(bool force)
        {
            lock (probeGate)
            {
                if (!force && encoderCache != null && probedFor != null && probedFor == Adapters()) return encoderCache;
                return Probe();
            }
        }

        static string Adapters() { return Native.DeviceInterfaces(new Guid("5B45201D-F2F2-4F3B-85BB-30FF1F953599")); } // GUID_DEVINTERFACE_DISPLAY_ADAPTER

        string Probe()
        {
            probedFor = Adapters();
            var sw = Stopwatch.StartNew();
            string picked = "libx264";
            foreach (var e in Encoders)
            {
                var p = Ffmpeg("-hide_banner -loglevel error -f lavfi -i color=c=black:s=320x240:r=15 -frames:v 5 -vf format=nv12 -c:v "
                    + e[0] + " " + e[1] + " -f null -");
                if (p.WaitForExit(15000) && p.ExitCode == 0)
                {
                    picked = e[0];
                    break;
                }
                try { if (!p.HasExited) p.Kill(); } catch { }
            }
            Log.Write("encoder: " + picked + " (probed in " + sw.ElapsedMilliseconds + " ms)");
            encoderCache = picked;
            return picked;
        }

        public static string Options(string encoder)
        {
            foreach (var e in Encoders) if (e[0] == encoder) return e[1];
            return "";
        }

        readonly object gpuGate = new object();
        GpuCaps gpuCache;
        /// The encoder and display adapters gpuCache was probed for.
        string gpuKey;

        public GpuCaps ProbeGpu(string encoder)
        {
            if (!VideoChain.HardwareEncoder(encoder)) return new GpuCaps();
            string key = encoder + "#" + Adapters();
            lock (gpuGate) // waits for a probe already under way
            {
                if (key != gpuKey)
                {
                    gpuCache = ProbeD3D11(encoder);
                    gpuKey = key;
                }
                return gpuCache;
            }
        }

        /// Synthetic D3D11 frames (uploaded, as Desktop Duplication hands them out: BGRA textures) into the encoder, then
        /// through scale_d3d11 too, both at once (~1.1-1.5 s, mostly device start-up); hardware encoders only.
        GpuCaps ProbeD3D11(string encoder)
        {
            var caps = new GpuCaps();
            var sw = Stopwatch.StartNew();
            Func<string, Process> start = delegate (string path)
            {
                string vf = VideoChain.Filter(path, path == VideoChain.Gpu ? new Size(640, 360) : new Size(320, 180), true, encoder);
                return Ffmpeg("-hide_banner -loglevel error -init_hw_device d3d11va=g -filter_hw_device g -f lavfi -i color=c=black:s=640x360:r=15 -frames:v 3 -vf \"format=bgra,hwupload"
                    + (vf.Length > 0 ? "," + vf : "") + "\" -c:v " + encoder + " " + Options(encoder) + " -f null -");
            };
            Func<Process, bool> ok = delegate (Process p)
            {
                if (p.WaitForExit(15000)) return p.ExitCode == 0;
                try { p.Kill(); } catch { }
                return false;
            };
            Process native = start(VideoChain.Gpu), scale = start(VideoChain.GpuScale);
            caps.Native = ok(native);
            caps.Scale = ok(scale) && caps.Native;
            Log.Write("gpu: " + encoder + " takes D3D11 frames " + (caps.Native ? "yes" : "no") + ", scale_d3d11 " + (caps.Scale ? "yes" : "no") + " (probed in " + sw.ElapsedMilliseconds + " ms)");
            return caps;
        }

        /// Dev bench (--chain-bench): a synthetic source of `size` (a cheap solid colour, so its own cost stays small), uploaded
        /// as D3D11 BGRA textures (what Desktop Duplication hands out), through the path the recorder would pick (falling
        /// through failures as it does), in real time (30 fps, like a recording, not a stress test). speed is ffmpeg's own
        /// (1.00 = keeps up with 30 fps); the source and upload alone are run first and their CPU time subtracted. One JSON
        /// object.
        public string Bench(Size size, string encoder, GpuCaps caps, string forced, int frames)
        {
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            string src = "-hide_banner -loglevel error -filter_threads 1 -stats_period 0.25 -progress pipe:1 -init_hw_device d3d11va=g -filter_hw_device g -re -f lavfi -i color=c=0x336699:s="
                + size.Width + "x" + size.Height + ":r=30 -frames:v " + frames + " -vf \"format=bgra,hwupload";
            // [cpu seconds, exit code, last speed]
            Func<string, double[]> time = delegate (string a)
            {
                double speed = 0;
                var p = Ffmpeg(a, delegate (string line)
                {
                    double v;
                    if (line.StartsWith("speed=") && double.TryParse(line.Substring(6).Trim().TrimEnd('x'), System.Globalization.NumberStyles.Float, inv, out v)) speed = v;
                });
                try { p.PriorityClass = CapturePriority; } catch { }
                if (!p.WaitForExit(300000)) { try { p.Kill(); } catch { } return null; }
                p.WaitForExit();
                return new[] { p.TotalProcessorTime.TotalSeconds, p.ExitCode, speed };
            };
            var baseline = time(src + "\" -f null -");
            string tmp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "agent-recorder-bench-" + Guid.NewGuid().ToString("N") + ".mp4");
            try
            {
                foreach (var path in VideoChain.Candidates(size, false, true, encoder, forced, caps))
                {
                    var output = VideoChain.Output(path, size);
                    string vf = VideoChain.Filter(path, output, true, encoder);
                    var r = time(src + (vf.Length > 0 ? "," + vf : "") + "\" -c:v " + encoder + " " + VideoChain.EncoderOptions(Options(encoder), output) + " -y \"" + tmp + "\"");
                    if (r == null || r[1] != 0) continue;
                    double net = Math.Max(0, r[0] - (baseline != null ? baseline[0] : 0));
                    return string.Format(inv, "{{\"source\":\"{0}x{1}\",\"path\":\"{2}\",\"output\":\"{3}x{4}\",\"encoder\":\"{5}\",\"frames\":{6},\"speed\":{7:0.00},\"fps\":{8:0.0},\"source_only_speed\":{9:0.00},\"chain_cpu_ms_per_frame\":{10:0.00},\"chain_cpu_pct_of_core_at_30fps\":{11:0.0}}}",
                        size.Width, size.Height, path, output.Width, output.Height, encoder, frames, r[2], Math.Min(30, 30 * r[2]), baseline != null ? baseline[2] : 0, net * 1000 / frames, net / frames * 30 * 100);
                }
                return "{\"source\":\"" + size.Width + "x" + size.Height + "\",\"error\":\"every path failed\"}";
            }
            finally { try { File.Delete(tmp); } catch { } }
        }

        public bool CanUseFastPath(MonitorInfo m) { return m.OutputIdx >= 0; }

        public Process StartScreen(CaptureSpec s, bool fast)
        {
            string opts = VideoChain.EncoderOptions(Options(s.Encoder), s.Output);
            var b = s.Monitor.Bounds;
            var a = new StringBuilder("-hide_banner -loglevel error -y -filter_threads 1 ");
            // Live commands (window crop, mic mute) arrive on stdin and ffmpeg polls stdin once per stats period (default
            // 0.5 s); the same period paces -progress, whose timing places the system audio and mute spans.
            if (s.Region.HasValue || s.Progress != null) a.Append("-stats_period 0.05 ");
            if (s.Progress != null) a.Append("-progress pipe:1 ");
            // The screen is this process's only input. With the mic as a second input ffmpeg paces the two against each
            // other and pulls ddagrab in bursts that see the same desktop image several times: 1920x1080 + mic was 11 unique
            // fps (DirectShow's ~500 ms audio packets) or 20 (20 ms packets); alone it is 30. The mic runs in StartMic.
            if (fast) a.Append("-f lavfi -i ddagrab=output_idx=" + s.Monitor.OutputIdx + ":framerate=" + s.Fps + ":draw_mouse=1 ");
            else a.Append("-f gdigrab -framerate " + s.Fps + " -draw_mouse 1 -offset_x " + b.X + " -offset_y " + b.Y + " -video_size " + b.Width + "x" + b.Height + " -i desktop ");
            string vf = s.Region.HasValue
                ? (fast ? "hwdownload,format=bgra," : "") + WindowTrack.Filter(s.Region.Value, s.Output)
                : VideoChain.Filter(s.Path, s.Output, fast, s.Encoder);
            a.Append("-map 0:v -t " + s.MaxSeconds + " " + (vf.Length > 0 ? "-vf \"" + vf + "\" " : ""));
            a.Append("-c:v " + s.Encoder + " " + opts + " -r " + s.Fps + " -g " + (s.Fps * 2) + " " + VideoChain.EarlyKeys(s.Fps, s.Encoder) + " ");
            a.Append("-movflags +faststart -fs " + Math.Max(1000000, s.MaxBytes) + " \"" + s.Video + "\"");
            var progress = s.Progress;
            var cap = Ffmpeg(a.ToString(), progress == null ? null : (Action<string>)delegate (string line) { progress.Line(line, Clock.Now()); });
            try { cap.PriorityClass = CapturePriority; } catch { }
            return cap;
        }

        public Process StartMic(AvDevice mic, string wav, bool muted, int maxSeconds, FfProgress progress)
        {
            // 20 ms packets (DirectShow's default is ~500 ms), so -progress places sample 0 closely on the shared clock.
            var p = Ffmpeg("-hide_banner -loglevel error -y -stats_period 0.05 -progress pipe:1 -audio_buffer_size 20 -f dshow -i "
                + Native.QuoteArg("audio=" + mic.FfmpegName) + " -t " + maxSeconds + " -af volume@mic=volume=" + (muted ? "0" : "1")
                + " -ac 1 -ar 48000 -c:a pcm_s16le \"" + wav + "\"", delegate (string line) { progress.Line(line, Clock.Now()); });
            try { p.PriorityClass = CapturePriority; } catch { }
            return p;
        }

        /// ffmpeg's interactive "C" key: "C<target> <time> <command> <arg>\n" sends a command to the filter graph
        /// (no zmq/sendcmd needed; the pinned essentials build has no zmq). Writes are serialized with "q" (StopProcess).
        public void SendCommands(Process p, List<string> commands)
        {
            if (p == null || commands.Count == 0) return;
            var sb = new StringBuilder();
            foreach (var c in commands) sb.Append('C').Append(c).Append('\n');
            try
            {
                lock (p)
                {
                    if (p.HasExited) return;
                    p.StandardInput.Write(sb.ToString());
                    p.StandardInput.Flush();
                }
            }
            catch (Exception e) { Log.Write("window: command not delivered: " + e.Message); }
        }

        public void Concat(List<string> parts, string output)
        {
            string list = output + ".txt";
            var lines = new List<string>();
            foreach (var part in parts) lines.Add("file '" + part.Replace('\\', '/').Replace("'", "'\\''") + "'");
            File.WriteAllLines(list, lines);
            try
            {
                var p = Ffmpeg("-hide_banner -loglevel error -y -f concat -safe 0 -i \"" + list + "\" -c copy "
                    + (output.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase) ? "-movflags +faststart " : "") + "\"" + output + "\"");
                if (!p.WaitForExit(120000)) { try { p.Kill(); } catch { } throw new Exception("concat timed out"); }
                if (p.ExitCode != 0) throw new Exception("concat failed (" + p.ExitCode + ")");
            }
            finally { try { File.Delete(list); } catch { } }
        }

        /// Keyframe times (seconds from the first packet) in the first `seconds` of a video, read as a stream copy (no decoding).
        public List<double> Keyframes(string video, double seconds)
        {
            var sb = new StringBuilder();
            var p = Ffmpeg("-hide_banner -loglevel error -t " + seconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture) + " -i \"" + video
                + "\" -map 0:v:0 -c copy -f framecrc -", delegate (string line) { lock (sb) sb.Append(line).Append('\n'); });
            if (!p.WaitForExit(60000)) { try { p.Kill(); } catch { } throw new Exception("keyframe scan timed out"); }
            p.WaitForExit(); // drains the redirected output
            lock (sb) return AudioMath.KeyframeTimes(sb.ToString());
        }

        /// ffmpeg -i with no output: it prints the listing to stderr and exits 1 ("At least one output file must be specified").
        public string MediaInfo(string video)
        {
            var psi = new ProcessStartInfo(ffmpeg, "-hide_banner -i \"" + video + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            using (var p = Process.Start(psi))
            {
                Native.AddToKillJob(p);
                try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                p.StandardInput.Close();
                var err = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } throw new Exception("probe timed out"); }
                return err.Result;
            }
        }

        /// The frame at `ms` (an accurate input seek), scaled down to Stills.MaxWidth when wider, as a PNG; then JPEG at
        /// Stills.Quality through System.Drawing (the same quality setting as the Mac's ImageIO 0.75).
        public void Still(string video, long ms, string jpg)
        {
            string png = jpg + ".png";
            try
            {
                var p = Ffmpeg(StillArgs(video, ms, png));
                if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } throw new Exception("frame grab timed out"); }
                if (p.ExitCode != 0 || !File.Exists(png)) throw new Exception("frame grab failed (" + p.ExitCode + ")");
                Stills.Encode(png, jpg);
            }
            finally { try { File.Delete(png); } catch { } }
        }

        /// Still's ffmpeg arguments: one frame at `ms`, width min(MaxWidth, source) (never scaled up), aspect kept.
        public static string StillArgs(string video, long ms, string png)
        {
            return "-hide_banner -loglevel error -y -ss " + (ms / 1000.0).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture) + " -i \"" + video
                + "\" -map 0:v:0 -frames:v 1 -vf \"scale='min(" + Stills.MaxWidth + ",iw)':-1\" -f image2 -c:v png \"" + png + "\"";
        }

        /// One pass: the joined video from `seek` (a keyframe, so the stream copy starts exactly there) with the mixed AAC
        /// track, and with a mic the transcription WAV (the mic only; none without one).
        public void MixAudio(string video, double seek, string mic, string sys, string filter, string outVideo, string outWav)
        {
            var p = Ffmpeg(MixArgs(video, seek, mic, sys, filter, outVideo, outWav));
            if (!p.WaitForExit(180000)) { try { p.Kill(); } catch { } throw new Exception("audio mix timed out"); }
            if (p.ExitCode != 0) throw new Exception("audio mix failed (" + p.ExitCode + ")");
        }

        /// MixAudio's ffmpeg arguments. The WAV output ([t]) only with a mic: MixFilter has no [t] without one.
        public static string MixArgs(string video, double seek, string mic, string sys, string filter, string outVideo, string outWav)
        {
            var a = new StringBuilder("-hide_banner -loglevel error -y ");
            // Rounded up to the microsecond: rounding down would seek to the keyframe before.
            if (seek > 0) a.Append("-ss " + (Math.Ceiling(seek * 1e6) / 1e6).ToString("0.######", System.Globalization.CultureInfo.InvariantCulture) + " ");
            a.Append("-i \"" + video + "\" ");
            if (mic != null) a.Append("-i \"" + mic + "\" ");
            if (sys != null) a.Append("-i \"" + sys + "\" ");
            a.Append("-filter_complex \"" + filter + "\" -map 0:v -map [a] -c:v copy -c:a aac -b:a 128k -shortest -movflags +faststart \"" + outVideo + "\"");
            if (mic != null) a.Append(" -map [t] -ac 1 -c:a pcm_s16le \"" + outWav + "\"");
            return a.ToString();
        }

        public ProcessStartInfo CameraProcess(AvDevice camera, int width, int height, bool sized)
        {
            // Mirroring happens in the bubble (it can change mid-recording without restarting the camera). The crop keeps
            // the centre of the camera image at the bubble's aspect (square, or 16:9 for the rectangle).
            string vf = "crop='min(iw,ih*" + width + "/" + height + ")':'min(ih,iw*" + height + "/" + width + ")',scale=" + width + ":" + height + ":flags=bilinear";
            // Test camera (--record-local --test-camera): a 640x480 30 fps pattern whose colours change in every frame, in
            // real time, through the same crop/scale/pipe and bubble, so the bubble's frame rate in a video is measurable.
            string input = TestCamera
                ? "-re -f lavfi -i \"testsrc2=size=640x480:rate=30,hue=H=2*PI*t/4\""
                : "-f dshow " + (sized ? "-video_size 640x480 -framerate 30 " : "") + "-rtbufsize 16M -i " + Native.QuoteArg("video=" + camera.FfmpegName);
            string args = "-hide_banner -loglevel error " + input + " -an -vf \"" + vf + "\" -r 30 -pix_fmt bgr24 -f rawvideo pipe:1";
            return new ProcessStartInfo(ffmpeg, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
        }

        /// The warm ffmpeg's command line: raw PCM read from its own stdin (which is never written, so it blocks there with
        /// no CPU) into the null muxer. No capture device (no dshow, ddagrab, gdigrab or WASAPI), no output file, no
        /// encoder: it only keeps ffmpeg's image and DLLs mapped so the next real launch does not load them cold.
        public const string WarmArgs = "-hide_banner -loglevel quiet -f s16le -ar 8000 -ac 1 -i pipe:0 -f null -";

        public WarmKeeper.IHandle StartWarm()
        {
            var p = Ffmpeg(WarmArgs);
            try { p.PriorityClass = ProcessPriorityClass.Idle; } catch { }
            return new WarmFfmpeg(p);
        }

        /// Ends when its stdin closes (end of input: ffmpeg exits by itself), killed if it has not within 3 s. In the
        /// kill-on-close job like every ffmpeg here, so it never outlives the agent.
        sealed class WarmFfmpeg : WarmKeeper.IHandle
        {
            readonly Process p;
            public WarmFfmpeg(Process p) { this.p = p; }
            public bool Alive { get { try { return !p.HasExited; } catch { return false; } } }
            public void Dispose()
            {
                try { p.StandardInput.Close(); } catch { }
                ThreadPool.QueueUserWorkItem(delegate
                {
                    try { if (!p.WaitForExit(3000)) p.Kill(); } catch { }
                    p.Dispose();
                });
            }
        }

        Process Ffmpeg(string args, Action<string> stdout = null)
        {
            var psi = new ProcessStartInfo(ffmpeg, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = stdout != null,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            var p = Process.Start(psi);
            Native.AddToKillJob(p);
            if (stdout != null)
            {
                p.OutputDataReceived += delegate (object sender, DataReceivedEventArgs e) { if (e.Data != null) stdout(e.Data); };
                p.BeginOutputReadLine();
            }
            try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            return p;
        }
    }

    // ---------------------------------------------------------------- audio: mute spans, mixing, system audio

    /// A time span in seconds (End may be +Infinity while it is still open).
    struct Span
    {
        public double Start, End;
        public Span(double s, double e) { Start = s; End = e; }
        public override string ToString() { return Start.ToString("0.000", System.Globalization.CultureInfo.InvariantCulture) + "-" + End.ToString("0.000", System.Globalization.CultureInfo.InvariantCulture); }
    }

    /// One recorded segment on the shared clock (Clock.Now seconds): where its video starts and how long it is. Segments
    /// are joined back to back, so segment i starts at the sum of the earlier durations in the uploaded video.
    struct Segment
    {
        public double WallStart, Duration;
        public Segment(double w, double d) { WallStart = w; Duration = d; }
    }

    /// The clock every audio/video timestamp in a recording uses: QPC seconds (Stopwatch), also what WASAPI stamps packets with.
    static class Clock
    {
        public static double Now() { return Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency; }
    }

    /// Mute on/off history of one source. Toggling only appends; spans are read at any time (thread-safe).
    class MuteLog
    {
        readonly object gate = new object();
        readonly List<Span> spans = new List<Span>();
        double openSince = double.NaN;

        public bool Muted { get { lock (gate) return !double.IsNaN(openSince); } }

        /// Returns false when nothing changed.
        public bool Set(bool muted, double t)
        {
            lock (gate)
            {
                if (muted == !double.IsNaN(openSince)) return false;
                if (muted) openSince = t;
                else { spans.Add(new Span(openSince, Math.Max(openSince, t))); openSince = double.NaN; }
                return true;
            }
        }

        /// Closed spans, plus the open one (to +Infinity) while muted.
        public List<Span> Spans()
        {
            lock (gate)
            {
                var l = new List<Span>(spans);
                if (!double.IsNaN(openSince)) l.Add(new Span(openSince, double.PositiveInfinity));
                return l;
            }
        }
    }

    /// Pure audio timeline math (covered by the selftest): mute spans, frame ranges to zero, the mixing filter.
    static class AudioMath
    {
        static readonly System.Globalization.CultureInfo Inv = System.Globalization.CultureInfo.InvariantCulture;

        /// Sorted, overlaps and touching spans merged, empty spans dropped.
        public static List<Span> Merge(List<Span> spans)
        {
            var l = spans.FindAll(s => s.End > s.Start);
            l.Sort((a, b) => a.Start.CompareTo(b.Start));
            var o = new List<Span>();
            foreach (var s in l)
            {
                if (o.Count > 0 && s.Start <= o[o.Count - 1].End) o[o.Count - 1] = new Span(o[o.Count - 1].Start, Math.Max(o[o.Count - 1].End, s.End));
                else o.Add(s);
            }
            return o;
        }

        /// Frames [from, from+count) at `rate` that fall in a span: (offset into the block, length) pairs. A frame is muted
        /// when its start time is inside [Start, End).
        public static List<int[]> MutedRanges(List<Span> spans, long from, int count, int rate)
        {
            var r = new List<int[]>();
            foreach (var s in Merge(spans))
            {
                long a = (long)Math.Ceiling(s.Start * rate), b = double.IsPositiveInfinity(s.End) ? long.MaxValue : (long)Math.Ceiling(s.End * rate);
                long lo = Math.Max(a, from), hi = Math.Min(b, from + count);
                if (hi > lo) r.Add(new[] { (int)(lo - from), (int)(hi - lo) });
            }
            return r;
        }

        /// Wall-clock spans (Clock.Now seconds) -> spans in the joined video, widened by padBefore/padAfter (clamped to
        /// each segment) and merged. Parts outside every segment (between segments, after the end) are dropped.
        public static List<Span> ToTimeline(List<Span> wall, List<Segment> segs, double padBefore, double padAfter)
        {
            var o = new List<Span>();
            double at = 0;
            foreach (var g in segs)
            {
                foreach (var w in wall)
                {
                    double a = Math.Max(w.Start - padBefore, g.WallStart), b = Math.Min(w.End + padAfter, g.WallStart + g.Duration);
                    if (b > a) o.Add(new Span(at + a - g.WallStart, at + b - g.WallStart));
                }
                at += g.Duration;
            }
            return Merge(o);
        }

        /// ffmpeg timeline expression that is non-zero inside any span ("between(t,a,b)+...").
        public static string Enable(List<Span> spans)
        {
            var parts = new List<string>();
            foreach (var s in Merge(spans)) parts.Add("between(t," + s.Start.ToString("0.###", Inv) + "," + s.End.ToString("0.###", Inv) + ")");
            return string.Join("+", parts);
        }

        /// Slices (seconds in a WAV whose sample 0 was at `wavStart` on the shared clock) for each segment: segment i plays
        /// the WAV from its video start. Mic and system audio are both continuous WAVs cut this way.
        public static List<Span> Slices(List<Segment> segs, double wavStart)
        {
            var l = new List<Span>();
            foreach (var g in segs) l.Add(new Span(g.WallStart - wavStart, g.WallStart - wavStart + g.Duration));
            return l;
        }

        /// The most the video's head is ever cut off at the start (StartTrim).
        public const double MaxTrim = 0.5;

        /// Where the uploaded video starts (seconds into the joined video) so that it does not open before the mic does: 0
        /// when the mic's first sample (`micStart`, shared clock) is at or before the video's (`videoStart`), else the first
        /// keyframe at or after the difference (the cut is a stream copy), at most MaxTrim. A mic later than that is
        /// `capped`: the last keyframe at or below MaxTrim (0 at worst), and the mix delays the mic for the rest. Only the
        /// mic decides (NaN = no mic: 0): system audio (loopback delivers nothing until something plays) never trims, it is
        /// delayed.
        public static double StartTrim(double videoStart, double micStart, List<double> keyframes, out bool capped)
        {
            capped = false;
            double late = micStart - videoStart;
            if (!(late > 0)) return 0;
            double best = -1, floor = 0;
            foreach (var k in keyframes)
            {
                if (k > MaxTrim) continue;
                if (k >= late && (best < 0 || k < best)) best = k;
                if (k > floor) floor = k;
            }
            if (best >= 0) return best;
            capped = true;
            return floor;
        }

        /// The segments with the first `trim` seconds of the joined video cut off (segments wholly inside it dropped).
        public static List<Segment> TrimStart(List<Segment> segs, double trim)
        {
            var o = new List<Segment>();
            foreach (var g in segs)
            {
                double cut = Math.Min(Math.Max(trim, 0), g.Duration);
                trim -= cut;
                if (g.Duration - cut > 0) o.Add(new Segment(g.WallStart + cut, g.Duration - cut));
            }
            return o;
        }

        /// The joined video's length: the stored duration_s, and the length of the mixed track and transcription WAV.
        public static double Length(List<Segment> segs)
        {
            double l = 0;
            foreach (var g in segs) l += g.Duration;
            return l;
        }

        /// Keyframe times (seconds from the first packet) from ffmpeg's framecrc output of a video stream: "#tb 0: num/den",
        /// then "0, dts, pts, duration, size, crc[, F=0x..]" per packet; keyframes have no F= field (or F with bit 1 set).
        public static List<double> KeyframeTimes(string framecrc)
        {
            long num = 0, den = 0;
            var pts = new List<long>();
            var keys = new List<long>();
            foreach (var raw in framecrc.Split('\n'))
            {
                string line = raw.Trim();
                if (line.StartsWith("#tb 0:"))
                {
                    var r = line.Substring(6).Trim().Split('/');
                    if (r.Length == 2) { long.TryParse(r[0], out num); long.TryParse(r[1], out den); }
                    continue;
                }
                if (line.Length == 0 || line[0] == '#') continue;
                var f = line.Split(',');
                long p;
                if (f.Length < 6 || f[0].Trim() != "0" || !long.TryParse(f[2].Trim(), out p)) continue;
                pts.Add(p);
                bool key = true;
                for (int i = 6; i < f.Length; i++)
                {
                    string x = f[i].Trim();
                    int flags;
                    if (x.StartsWith("F=0x") && int.TryParse(x.Substring(4), System.Globalization.NumberStyles.HexNumber, Inv, out flags)) key = (flags & 1) != 0;
                }
                if (key) keys.Add(p);
            }
            var t = new List<double>();
            if (num <= 0 || den <= 0 || pts.Count == 0) return t;
            long first = long.MaxValue;
            foreach (var p in pts) first = Math.Min(first, p);
            foreach (var k in keys) t.Add((k - first) * (double)num / den);
            t.Sort();
            return t;
        }

        public const double SystemGain = 0.6;

        /// filter_complex for the final audio: mic (input micIn, mono WAV, its slices joined; muted spans silenced) and
        /// system audio (input sysIn, its slices joined, at SystemGain under the mic with light ducking while the mic is
        /// loud), mixed and limited. Outputs [a] (padded: the MP4 track, cut to the video by -shortest) and, with a mic,
        /// [t] (16 kHz, made mono by -ac 1; transcription): the mic alone after its muted spans are silenced, never the
        /// system audio (transcripts are mic-only). No mic = no [t] (no transcription WAV). Indexes < 0 = that source is
        /// absent.
        public static string MixFilter(int micIn, List<Span> micMuted, List<Span> micSlices, int sysIn, List<Span> sysSlices)
        {
            var f = new List<string>();
            string mix;
            if (micIn >= 0)
            {
                // `enable` is evaluated once per frame, and the WAV comes in ~85 ms frames: 10 ms frames first, so a span
                // starts within 10 ms of its time instead of up to a whole frame late.
                string mute = micMuted != null && micMuted.Count > 0 ? ",asetnsamples=n=480:p=0,volume=0:enable='" + Enable(micMuted) + "'" : "";
                Sliced(f, micIn, micSlices, "m", "aresample=48000,pan=stereo|c0=c0|c1=c0" + mute);
            }
            if (sysIn >= 0)
            {
                double gain = micIn >= 0 ? SystemGain : 1.0;
                Sliced(f, sysIn, sysSlices, "s", "aresample=48000,aformat=channel_layouts=stereo,volume=" + gain.ToString("0.##", Inv));
            }
            // The mic's transcription copy [mt] is split off [m] (muted spans already silent) before any mixing.
            if (micIn >= 0 && sysIn >= 0)
            {
                f.Add("[m]asplit=3[mm][mk][mt]");
                f.Add("[s][mk]sidechaincompress=threshold=0.05:ratio=3:attack=10:release=300[sd]");
                f.Add("[mm][sd]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.97:level=0:latency=1[x]");
                mix = "[x]";
            }
            else if (micIn >= 0)
            {
                f.Add("[m]asplit=2[mm][mt]");
                mix = "[mm]";
            }
            else mix = "[s]";
            f.Add(mix + "apad[a]");
            if (micIn >= 0) f.Add("[mt]aresample=16000[t]");
            return string.Join(";", f);
        }

        /// Input `input` cut to its slices and joined, then `tail`, as [name] (parts [name0].., split copies [namew0]..).
        static void Sliced(List<string> f, int input, List<Span> slices, string name, string tail)
        {
            int k = slices.Count;
            if (k > 1) f.Add("[" + input + ":a]asplit=" + k + string.Concat(Labels(name + "w", k)));
            var parts = new List<string>();
            for (int i = 0; i < k; i++)
            {
                var s = slices[i];
                string src = k > 1 ? "[" + name + "w" + i + "]" : "[" + input + ":a]";
                // A slice that starts before the WAV does (system audio that started late, a mic later than MaxTrim) is
                // delayed with leading silence, so every slice is exactly its segment's length.
                string delay = s.Start < 0 ? "adelay=delays=" + Math.Round(-s.Start * 1000).ToString(Inv) + ":all=1," : "";
                double start = Math.Max(0, s.Start), dur = s.End - s.Start;
                f.Add(src + delay + "atrim=start=" + start.ToString("0.###", Inv) + ":duration=" + dur.ToString("0.###", Inv) + ",asetpts=PTS-STARTPTS[" + name + i + "]");
                parts.Add("[" + name + i + "]");
            }
            f.Add(string.Concat(parts) + (k > 1 ? "concat=n=" + k + ":v=0:a=1," : "") + tail + "[" + name + "]");
        }

        static IEnumerable<string> Labels(string p, int k) { for (int i = 0; i < k; i++) yield return "[" + p + i + "]"; }
    }

    /// Reads ffmpeg's `-progress` lines for one capture segment. T0 = when that segment's timeline 0 was on the shared
    /// clock: the smallest (arrival time - out_time) seen, i.e. the sample with the least pipeline latency. Last = the
    /// segment's length so far.
    class FfProgress
    {
        readonly object gate = new object();
        double t0 = double.PositiveInfinity, last;
        int samples;

        /// Set by the first progress block that counts an encoded frame (ffmpeg prints one with frame=0 on start-up).
        public readonly ManualResetEventSlim FirstFrame = new ManualResetEventSlim(false);
        /// Called once, on the reader thread, when FirstFrame is set.
        public Action OnFirstFrame;

        public void Line(string line, double now)
        {
            if (line != null && line.StartsWith("frame=") && !FirstFrame.IsSet)
            {
                long n;
                if (long.TryParse(line.Substring(6).Trim(), out n) && n > 0)
                {
                    FirstFrame.Set();
                    var f = OnFirstFrame;
                    if (f != null) f();
                }
                return;
            }
            if (line == null || !line.StartsWith("out_time_us=")) return;
            long us;
            if (!long.TryParse(line.Substring(12), out us) || us <= 0) return;
            lock (gate)
            {
                double o = us / 1e6, lag = now - o, m;
                t0 = Math.Min(t0, lag);
                last = Math.Max(last, o);
                samples++;
                int b = (int)(o / 10);
                if (!lags.TryGetValue(b, out m) || lag < m) lags[b] = lag;
            }
        }

        /// Smallest (arrival - out_time) per 10 s of the timeline: how far the timeline and the shared clock moved apart.
        readonly SortedDictionary<int, double> lags = new SortedDictionary<int, double>();

        public bool Valid { get { lock (gate) return samples > 0; } }
        public double T0 { get { lock (gate) return t0; } }
        public double Last { get { lock (gate) return last; } }

        /// (arrival - out_time) in the first and the last 10 s of the timeline, relative to T0 (both 0 when they agree).
        public double[] EdgeLags()
        {
            lock (gate)
            {
                if (lags.Count == 0) return new double[] { 0, 0 };
                double first = double.NaN, end = 0;
                foreach (var kv in lags) { if (double.IsNaN(first)) first = kv.Value; end = kv.Value; }
                return new[] { first - t0, end - t0 };
            }
        }

        /// For the log: "t0 T, lag start/end a/b ms, out_time O s".
        public string Describe()
        {
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            var e = EdgeLags();
            return "t0 " + T0.ToString("0.000", inv) + ", lag start/end " + (e[0] * 1000).ToString("0", inv) + "/" + (e[1] * 1000).ToString("0", inv)
                + " ms, out_time " + Last.ToString("0.000", inv) + " s";
        }
    }

    /// System audio: WASAPI loopback of the default render device (what plays in the speakers or headset), written to a
    /// 48 kHz stereo 16-bit WAV that covers the whole recording without gaps. Sample 0 is StartTime on the shared clock;
    /// every packet goes where its QPC timestamp says, and silence fills the rest (nothing playing, no device, a device
    /// switch). Muted spans are written as zeros: muted sound never reaches the disk. Runs on its own MTA thread; COM
    /// interop only (no NuGet). Any device problem degrades to silence; it never stops the recording.
    sealed class LoopbackCapture
    {
        public const int Rate = 48000, Channels = 2;
        const int Tolerance = Rate / 50; // 20 ms: smaller timestamp jitter is not corrected
        public readonly string PathName;
        public readonly MuteLog Mutes = new MuteLog();
        readonly ManualResetEvent started = new ManualResetEvent(false);
        volatile bool stop;
        Thread thread;
        FileStream file;
        long written;
        double startTime;
        float prevL, prevR, phase;
        byte[] outBuf = new byte[0];
        public string Device = "", Format = "";
        public int Switches, Losses;
        public double NoDeviceSeconds;

        public LoopbackCapture(string path) { PathName = path; }

        public double StartTime { get { return startTime; } }
        public double Seconds { get { return Interlocked.Read(ref written) / (double)Rate; } }

        public void Start()
        {
            OpenFile();
            thread = new Thread(Loop) { IsBackground = true, Name = "system audio" };
            thread.Start();
            started.WaitOne(3000);
        }

        void OpenFile()
        {
            file = new FileStream(PathName, FileMode.Create, FileAccess.Write, FileShare.Read, 65536);
            file.Write(new byte[44], 0, 44);
        }

        // Selftest hooks: the same timeline code without a device or the capture thread.
        public void TestOpen(double start) { OpenFile(); startTime = start; }
        /// One packet whose first frame played at clock time `at` (0 = no timestamp).
        public void TestFeed(float[] stereo, int frames, int rate, double at) { Place(stereo, frames, rate, at <= 0 ? 0 : (ulong)Math.Round(at * 1e7)); }
        public void TestPadTo(double t) { long target = (long)Math.Round((t - startTime) * Rate); if (target > written) WriteGap(target - written); }
        public void TestClose() { Finish(); }

        /// Mute or unmute from now on (frames at or after this instant on the shared clock are written as zeros).
        public void SetMuted(bool muted) { Mutes.Set(muted, Clock.Now() - startTime); }

        /// Stops, pads to now and finalizes the WAV header. Safe to call twice.
        public void Stop()
        {
            stop = true;
            if (thread != null && !thread.Join(5000)) Log.Write("system audio: capture thread did not stop");
        }

        void Loop()
        {
            startTime = Clock.Now();
            started.Set();
            AudioEndpoints.Loopback dev = null;
            double nextOpen = 0, nextCheck = 0, lostAt = Clock.Now();
            try
            {
                while (!stop)
                {
                    double now = Clock.Now();
                    if (dev == null && now >= nextOpen)
                    {
                        string why;
                        dev = AudioEndpoints.Loopback.OpenDefault(out why);
                        if (dev == null)
                        {
                            if (Device != "-") Log.Write("system audio: no output device (" + why + "); recording silence until one appears");
                            Device = "-";
                            nextOpen = now + 1;
                        }
                        else
                        {
                            NoDeviceSeconds += now - lostAt;
                            if (Device.Length > 0 && Device != "-") Switches++;
                            Device = dev.Name;
                            Format = dev.Describe();
                            phase = 0; prevL = prevR = 0;
                            Log.Write("system audio: capturing \"" + dev.Name + "\" (" + Format + ")");
                            nextCheck = now + 0.5;
                        }
                    }
                    if (dev != null)
                    {
                        try
                        {
                            dev.Drain(Place);
                            if (now >= nextCheck)
                            {
                                nextCheck = now + 0.5;
                                string id = AudioEndpoints.Loopback.DefaultId();
                                if (id != null && id != dev.Id)
                                {
                                    Log.Write("system audio: default output changed; switching");
                                    dev.Dispose();
                                    dev = null;
                                    lostAt = now;
                                    nextOpen = now;
                                }
                            }
                        }
                        catch (Exception e)
                        {
                            // Unplugged headset (AUDCLNT_E_DEVICE_INVALIDATED) and friends: silence, then the new default.
                            Log.Write("system audio: device lost (" + e.Message + "); continuing with silence");
                            Losses++;
                            try { dev.Dispose(); } catch { }
                            dev = null;
                            lostAt = now;
                            nextOpen = now + 0.2;
                        }
                    }
                    // Keep the file continuous. While a device is open its packets arrive a little late, so stay 100 ms
                    // behind real time and let them land in place.
                    long target = (long)((Clock.Now() - startTime) * Rate) - (dev != null ? Rate / 10 : 0);
                    if (target > written) WriteFrames(null, 0, (int)Math.Min(target - written, Rate));
                    Thread.Sleep(10);
                }
                if (dev != null) { try { dev.Drain(Place); } catch { } }
                long end = (long)((Clock.Now() - startTime) * Rate);
                while (written < end) WriteFrames(null, 0, (int)Math.Min(end - written, Rate));
            }
            catch (Exception e) { Log.Write("system audio: " + e.Message); }
            finally
            {
                if (dev == null) NoDeviceSeconds += Clock.Now() - lostAt;
                if (dev != null) try { dev.Dispose(); } catch { }
                Finish();
            }
        }

        /// One packet (stereo float at the device rate, null = silence) stamped with its QPC time (100 ns units, 0 = unknown).
        void Place(float[] st, int frames, int srcRate, ulong qpc)
        {
            float[] o = Resample(st, frames, srcRate);
            int n = o.Length / 2;
            int skip = 0;
            if (qpc != 0)
            {
                long idx = (long)Math.Round((qpc / 1e7 - startTime) * Rate);
                if (idx > written + Tolerance) WriteGap(idx - written);
                else if (idx < written - Tolerance) skip = (int)Math.Min(n, written - idx); // already covered by silence
            }
            if (n > skip) WriteFrames(o, skip, n - skip);
        }

        void WriteGap(long frames) { while (frames > 0) { int k = (int)Math.Min(frames, Rate); WriteFrames(null, 0, k); frames -= k; } }

        /// Linear resampling to 48 kHz, continuous across packets (the previous packet's last frame is kept).
        float[] Resample(float[] st, int frames, int srcRate)
        {
            if (st == null) { var z = new float[2 * (int)Math.Round(frames * (double)Rate / srcRate)]; return z; }
            if (srcRate == Rate) { var c = new float[frames * 2]; Array.Copy(st, c, frames * 2); return c; }
            float step = srcRate / (float)Rate;
            var o = new List<float>(frames * 2 * Rate / srcRate + 4);
            while (phase < frames - 1)
            {
                int i = (int)Math.Floor(phase);
                float f = phase - i;
                float l0 = i < 0 ? prevL : st[2 * i], r0 = i < 0 ? prevR : st[2 * i + 1];
                float l1 = st[2 * (i + 1)], r1 = st[2 * (i + 1) + 1];
                o.Add(l0 + (l1 - l0) * f);
                o.Add(r0 + (r1 - r0) * f);
                phase += step;
            }
            phase -= frames;
            if (frames > 0) { prevL = st[2 * (frames - 1)]; prevR = st[2 * (frames - 1) + 1]; }
            return o.ToArray();
        }

        /// Appends frames (null = silence) as 16-bit PCM, zeroing whatever falls in a muted span.
        void WriteFrames(float[] src, int offset, int count)
        {
            if (count <= 0) return;
            int bytes = count * 4;
            if (outBuf.Length < bytes) outBuf = new byte[bytes];
            Array.Clear(outBuf, 0, bytes);
            if (src != null)
            {
                for (int i = 0; i < count; i++)
                {
                    for (int ch = 0; ch < 2; ch++)
                    {
                        float v = src[2 * (offset + i) + ch];
                        int s = (int)Math.Round(Math.Max(-1f, Math.Min(1f, v)) * 32767);
                        outBuf[i * 4 + ch * 2] = (byte)s;
                        outBuf[i * 4 + ch * 2 + 1] = (byte)(s >> 8);
                    }
                }
                foreach (var r in AudioMath.MutedRanges(Mutes.Spans(), written, count, Rate)) Array.Clear(outBuf, r[0] * 4, r[1] * 4);
            }
            file.Write(outBuf, 0, bytes);
            Interlocked.Add(ref written, count);
        }

        void Finish()
        {
            try
            {
                long data = written * 4;
                file.Position = 0;
                var w = new BinaryWriter(file);
                w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write((int)(36 + data)); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
                w.Write(16); w.Write((short)1); w.Write((short)Channels); w.Write(Rate); w.Write(Rate * 4); w.Write((short)4); w.Write((short)16);
                w.Write(Encoding.ASCII.GetBytes("data")); w.Write((int)data);
                w.Flush();
                file.Dispose();
                Log.Write("system audio: " + Seconds.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " s written, "
                    + Switches + " device switches, " + Losses + " losses, " + Mutes.Spans().Count + " muted spans");
            }
            catch (Exception e) { Log.Write("system audio: wav not finalized: " + e.Message); }
        }
    }

    // ---------------------------------------------------------------- share link auto-open

    /// Which ready links may be opened: https, our own viewer page for that very recording, on the server this PC talks
    /// to or recitbot.com (the Worker's PUBLIC_BASE_URL; older installs talk to the workers.dev host). http only when
    /// the server itself is a loopback dev server. Pure, covered by the selftest; the Worker applies the same rule.
    static class LinkPolicy
    {
        public const string PublicHost = "recitbot.com";

        public static bool Allowed(string url, string server, string recordingId)
        {
            Uri u, s;
            if (string.IsNullOrEmpty(url) || recordingId == null || !System.Text.RegularExpressions.Regex.IsMatch(recordingId, "^[A-Za-z0-9]{20,30}$")) return false;
            if (!Uri.TryCreate(url, UriKind.Absolute, out u) || !Uri.TryCreate(server ?? "", UriKind.Absolute, out s)) return false;
            bool dev = s.IsLoopback && u.IsLoopback && u.Scheme == "http";
            if (u.Scheme != "https" && !dev) return false;
            if (u.UserInfo.Length > 0 || u.Fragment.Length > 0) return false;
            string host = u.Host.ToLowerInvariant();
            if (host != s.Host.ToLowerInvariant() && host != PublicHost) return false;
            if (!u.IsDefaultPort && !dev) return false;
            if (u.AbsolutePath != "/v/" + recordingId) return false;
            if (!System.Text.RegularExpressions.Regex.IsMatch(u.Query, "^(\\?[A-Za-z0-9_=&.-]*)?$")) return false;
            return u.AbsoluteUri == url; // nothing the parser had to normalize
        }
    }

    /// Recordings this PC uploaded and may open once. A ready frame opens a link only for a recording that is waiting
    /// (upload started here, at most 30 min ago) and only the first time: a failed or never-uploaded recording, a
    /// duplicate frame or one replayed after a reconnect opens nothing.
    class ReadyLinks
    {
        public static readonly TimeSpan MaxWait = TimeSpan.FromMinutes(30);
        readonly object gate = new object();
        readonly Dictionary<string, DateTime> waiting = new Dictionary<string, DateTime>();
        readonly HashSet<string> claimed = new HashSet<string>();

        public void Expect(string id, DateTime now) { lock (gate) if (!claimed.Contains(id)) waiting[id] = now; }

        public void Forget(string id) { lock (gate) waiting.Remove(id); }

        public bool Claim(string id, DateTime now)
        {
            lock (gate)
            {
                DateTime at;
                if (id == null || claimed.Contains(id) || !waiting.TryGetValue(id, out at)) return false;
                waiting.Remove(id);
                if (now - at > MaxWait) return false;
                claimed.Add(id);
                return true;
            }
        }
    }

    /// Opens a link in the user's default browser through the shell (ShellExecute of the https URL: a new tab in the
    /// browser that is already open; no browser exe is ever started by name). With AGENT_RECORDER_OPEN_LOG set (tests)
    /// the URL is appended to that file instead, so no tab pops up.
    static class LinkOpener
    {
        public static void Open(string url)
        {
            string stub = Environment.GetEnvironmentVariable("AGENT_RECORDER_OPEN_LOG");
            if (!string.IsNullOrEmpty(stub))
            {
                try { File.AppendAllText(stub, url + Environment.NewLine); } catch (Exception e) { Log.Write("open link stub: " + e.Message); }
                Log.Write("share link: opener stubbed (AGENT_RECORDER_OPEN_LOG)");
                return;
            }
            var t = new Thread(delegate ()
            {
                try
                {
                    using (Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })) { }
                    Log.Write("share link opened in the default browser");
                }
                catch (Exception e) { Log.Write("share link not opened: " + e.Message); }
            });
            t.SetApartmentState(ApartmentState.STA); // ShellExecute wants an STA thread
            t.IsBackground = true;
            t.Start();
        }
    }

    // ---------------------------------------------------------------- self-update

    /// The Worker's signed "update" command (hello "self_update"): downloads install.ps1 from the signed link, checks its
    /// SHA-256 and runs it hidden with -Update, which keeps this PC's pairing, stops this process once the new files are
    /// verified, swaps them and starts the new recorder (whose hello then reports the new version). Only for a newer
    /// version, only from the server this PC talks to (or recitbot.com), never while recording, one at a time. The
    /// result goes back as {"type":"update","status":"installing"|"failed","version":...,"error"?}.
    /// 0.6.1 (hello "update_defer_rollback"): an update that arrives while recording is held (newest version wins) and
    /// reported "deferred"; it runs once that recording is uploaded (RunDeferred), or fails when its link has expired by
    /// then. install.ps1 -Update keeps the previous files and rolls back when the new recorder never reports healthy
    /// (UpdateHealth); the restored recorder then reports "rolled_back".
    /// parity: mac/Sources/RecitbotCore/SelfUpdater.swift
    static class SelfUpdater
    {
        public const int MaxScriptBytes = 1024 * 1024;
        /// The update held while a recording runs (at most one: the newest).
        public static readonly DeferredUpdates Deferred = new DeferredUpdates();
        static readonly TimeSpan Cooldown = TimeSpan.FromMinutes(10);
        static readonly object Gate = new object();
        static DateTime startedAt = DateTime.MinValue;

        /// Strictly greater x.y.z. Anything that is not x.y.z is never newer.
        public static bool IsNewer(string version, string current)
        {
            int[] a = Parse(version), b = Parse(current);
            if (a == null || b == null) return false;
            for (int i = 0; i < 3; i++) if (a[i] != b[i]) return a[i] > b[i];
            return false;
        }

        static int[] Parse(string v)
        {
            if (v == null || !System.Text.RegularExpressions.Regex.IsMatch(v, "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$")) return null;
            var p = v.Split('.');
            return new[] { int.Parse(p[0]), int.Parse(p[1]), int.Parse(p[2]) };
        }

        /// The signed download link: https (http only against a loopback dev server), the server's host or recitbot.com,
        /// path /i/<token>, no query, nothing the parser had to normalize.
        public static bool UrlAllowed(string url, string server)
        {
            Uri u, s;
            if (string.IsNullOrEmpty(url) || !Uri.TryCreate(url, UriKind.Absolute, out u) || !Uri.TryCreate(server ?? "", UriKind.Absolute, out s)) return false;
            bool dev = s.IsLoopback && u.IsLoopback && u.Scheme == "http";
            if (u.Scheme != "https" && !dev) return false;
            if (u.UserInfo.Length > 0 || u.Fragment.Length > 0 || u.Query.Length > 0) return false;
            string host = u.Host.ToLowerInvariant();
            if (host != s.Host.ToLowerInvariant() && host != LinkPolicy.PublicHost) return false;
            if (!u.IsDefaultPort && !dev) return false;
            if (!System.Text.RegularExpressions.Regex.IsMatch(u.AbsolutePath, "^/i/[A-Za-z0-9._-]{20,400}$")) return false;
            return u.AbsoluteUri == url;
        }

        public static bool HashMatches(byte[] data, string sha256)
        {
            if (sha256 == null || !System.Text.RegularExpressions.Regex.IsMatch(sha256, "^[0-9A-Fa-f]{64}$")) return false;
            using (var h = SHA256.Create())
            {
                var sb = new StringBuilder();
                foreach (var x in h.ComputeHash(data)) sb.Append(x.ToString("X2"));
                return string.Equals(sb.ToString(), sha256, StringComparison.OrdinalIgnoreCase);
            }
        }

        /// powershell.exe arguments: no profile, no prompts, hidden, keep the pairing. noAutostart keeps an install that
        /// has no logon entry without one (else install.ps1 registers the AgentRecorder logon task for this exe);
        /// deviceName is the name the installer recorded (CleanDeviceName), passed only when there is one.
        public static string Arguments(string script, string server, string installDir, bool noAutostart = false, string deviceName = null)
        {
            string name = CleanDeviceName(deviceName);
            return "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Native.QuoteArg(script)
                + " -Server " + Native.QuoteArg(server) + " -Update -InstallDir " + Native.QuoteArg(installDir)
                + (noAutostart ? " -NoAutostart" : "") + (name == null ? "" : " -DeviceName " + Native.QuoteArg(name));
        }

        /// install.ps1 writes this next to the exe: "autostart=logon|none" and, when it was given one,
        /// "device_name=<name>". Not secret; never config.dat (Config.Save rewrites that with a fixed key set).
        public const string OptionsFile = "install-options.txt";

        /// The options file's autostart ("logon", "none", or null when absent/unknown) and device name (or null).
        public static void ParseOptions(string text, out string autostart, out string deviceName)
        {
            autostart = null;
            deviceName = null;
            foreach (var raw in (text ?? "").Split('\n'))
            {
                string line = raw.Trim().TrimStart('﻿');
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string k = line.Substring(0, eq).Trim(), v = line.Substring(eq + 1).Trim();
                if (k == "autostart" && (v == "logon" || v == "none")) autostart = v;
                else if (k == "device_name") deviceName = CleanDeviceName(v);
            }
        }

        /// A recorded device name as it may go on the installer's command line: no control characters or double quotes,
        /// trimmed, at most 64 characters, not starting with '-' (PowerShell would read it as a parameter). null when
        /// nothing is left: no name is ever made up.
        public static string CleanDeviceName(string s)
        {
            if (s == null) return null;
            var sb = new StringBuilder();
            foreach (char c in s) if (!char.IsControl(c) && c != '"') sb.Append(c);
            string n = sb.ToString().Trim();
            if (n.Length > 64) n = n.Substring(0, 64).Trim();
            return n.Length == 0 || n[0] == '-' ? null : n;
        }

        /// Whether the update passes -NoAutostart: only when the installer did not record "logon" and no scheduled task,
        /// HKCU Run value or Startup shortcut starts this exe. An install from before the options file has only the live
        /// check, so a throwaway installed with -NoAutostart stays without a logon task.
        public static bool NoAutostart(string recordedAutostart, bool startsThisExe)
        {
            return recordedAutostart != "logon" && !startsThisExe;
        }

        /// p (a path, maybe quoted or with %VARS%) is exe: both rooted, full paths equal ignoring case and a trailing '\'.
        public static bool SameExe(string p, string exe)
        {
            if (string.IsNullOrEmpty(p) || string.IsNullOrEmpty(exe)) return false;
            try
            {
                string a = Environment.ExpandEnvironmentVariables(p).Trim().Trim('"');
                if (a.Length == 0 || !Path.IsPathRooted(a) || !Path.IsPathRooted(exe)) return false;
                return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(exe).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        /// The program of a command line (same rule as the uninstall helper's Get-CmdExe): a quoted path, else the text
        /// through ".exe", else the first token.
        public static string CmdExe(string cmd)
        {
            if (string.IsNullOrEmpty(cmd)) return null;
            string c = cmd.Trim();
            if (c.StartsWith("\""))
            {
                int e = c.IndexOf('"', 1);
                return e < 0 ? c.Substring(1) : c.Substring(1, e - 1);
            }
            var m = System.Text.RegularExpressions.Regex.Match(c, "(?i)^.*?\\.exe(?=\\s|$)");
            return m.Success ? m.Value : System.Text.RegularExpressions.Regex.Split(c, "\\s+")[0];
        }

        /// Whether a scheduled task in the root folder (every action runs exe), a value of runSubKey under HKCU (its
        /// program is exe) or a shortcut in startupDir (its target is exe) starts this exe. Read-only; any error counts as
        /// "no entry". The selftest points it at throwaway task names, a throwaway key and a %TEMP% folder.
        public static bool StartsThisExe(string exe, string[] taskNames, string runSubKey, string[] runValues, string startupDir, string[] links)
        {
            foreach (var n in taskNames ?? new string[0]) if (TaskRunsExe(n, exe)) return true;
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(runSubKey ?? ""))
                    if (k != null) foreach (var n in runValues ?? new string[0]) if (SameExe(CmdExe(k.GetValue(n) as string), exe)) return true;
            }
            catch { }
            if (string.IsNullOrEmpty(startupDir)) return false;
            foreach (var n in links ?? new string[0])
            {
                string f = Path.Combine(startupDir, n);
                if (File.Exists(f) && SameExe(ShortcutTarget(f), exe)) return true;
            }
            return false;
        }

        /// The live check for this install: the AgentRecorder task, the AgentRecorder/Recitbot Run values and Startup
        /// shortcuts (the names the uninstall helper knows).
        public static bool StartsThisExe(string exe)
        {
            return StartsThisExe(exe, SelfUninstaller.TaskNames, "Software\\Microsoft\\Windows\\CurrentVersion\\Run", SelfUninstaller.RunValues,
                Environment.GetFolderPath(Environment.SpecialFolder.Startup), SelfUninstaller.StartupLinks);
        }

        static object Com(object o, string member, System.Reflection.BindingFlags how, params object[] args)
        {
            return o.GetType().InvokeMember(member, how, null, o, args);
        }

        /// Task Scheduler COM (late-bound, read-only): the task \name exists and every action is an exec action of exe.
        static bool TaskRunsExe(string name, string exe)
        {
            object svc = null;
            try
            {
                Type t = Type.GetTypeFromProgID("Schedule.Service", false);
                if (t == null) return false;
                svc = Activator.CreateInstance(t);
                const System.Reflection.BindingFlags call = System.Reflection.BindingFlags.InvokeMethod, get = System.Reflection.BindingFlags.GetProperty;
                Com(svc, "Connect", call);
                object folder = Com(svc, "GetFolder", call, "\\");
                object task;
                try { task = Com(folder, "GetTask", call, name); }
                catch { return false; }
                object actions = Com(Com(task, "Definition", get), "Actions", get);
                int count = (int)Com(actions, "Count", get);
                if (count == 0) return false;
                for (int i = 1; i <= count; i++)
                {
                    object a = Com(actions, "Item", get, i);
                    if ((int)Com(a, "Type", get) != 0 || !SameExe(Com(a, "Path", get) as string, exe)) return false;
                }
                return true;
            }
            catch { return false; }
            finally { if (svc != null) try { Marshal.FinalReleaseComObject(svc); } catch { } }
        }

        static string ShortcutTarget(string lnk)
        {
            object shell = null;
            try
            {
                Type t = Type.GetTypeFromProgID("WScript.Shell", false);
                if (t == null) return null;
                shell = Activator.CreateInstance(t);
                object sc = Com(shell, "CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, lnk);
                return Com(sc, "TargetPath", System.Reflection.BindingFlags.GetProperty) as string;
            }
            catch { return null; }
            finally { if (shell != null) try { Marshal.FinalReleaseComObject(shell); } catch { } }
        }

        /// The update report frame; error text is cut to what the Worker accepts.
        public static string ReportJson(string version, string error)
        {
            return StatusJson(error == null ? "installing" : "failed", version, error);
        }

        /// {"type":"update","status":...,"version":...,"error"?}: "installing" / "failed" (ReportJson), "deferred" (held
        /// until the recording is uploaded) or "rolled_back" (UpdateHealth: the installer put the previous version back).
        public static string StatusJson(string status, string version, string error)
        {
            string e = error == null ? null : System.Text.RegularExpressions.Regex.Replace(error, "[^A-Za-z0-9_ .:,()'/-]", "");
            if (e != null && e.Length > 200) e = e.Substring(0, 200);
            return "{\"type\":\"update\",\"status\":" + Json.Esc(status) + ",\"version\":" + Json.Esc(version)
                + (string.IsNullOrEmpty(e) ? "" : ",\"error\":" + Json.Esc(e)) + "}";
        }

        /// Seconds before its expiry a held link counts as expired (the download still has to happen).
        public const long ExpiryMarginSeconds = 15;

        /// The expiry (unix s) inside a Worker update link /i/v1.<purpose>.<account>.<expires>.<random>.<code>.<sig>
        /// (worker/src/installer.ts installerUrl); 0 when the link has no readable one.
        public static long LinkExpiry(string url)
        {
            Uri u;
            if (string.IsNullOrEmpty(url) || !Uri.TryCreate(url, UriKind.Absolute, out u) || !u.AbsolutePath.StartsWith("/i/")) return 0;
            var p = u.AbsolutePath.Substring(3).Split('.');
            long exp;
            return p.Length >= 4 && p[0] == "v1" && p[3].Length > 0 && p[3].Length <= 12 && long.TryParse(p[3], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out exp) ? exp : 0;
        }

        /// When a held update can no longer run: the link's own expiry, else the command's signed exp.
        public static long Expiry(string url, long commandExp)
        {
            long l = LinkExpiry(url);
            return l > 0 ? l : commandExp;
        }

        /// null while p can still run at nowUnix, else the error its "failed" report carries (the server sends it again).
        public static string Expired(PendingUpdate p, long nowUnix)
        {
            return p.Expires > 0 && nowUnix >= p.Expires - ExpiryMarginSeconds ? "update link expired while deferred (send the update again)" : null;
        }

        /// server: the server of the account whose connection sent the command; exp: the command's signed exp.
        public static void Run(Config cfg, string server, bool busy, string version, string sha256, string url, long exp, Action<string> send)
        {
            Handle(new PendingUpdate(version, sha256, url, server, Expiry(url, exp), send), busy, Deferred,
                delegate (PendingUpdate p) { return Install(cfg, p.Server, p.Sha256, p.Url); });
        }

        /// A verified update command: ignored unless newer than this recorder; while recording, held (the newest one) and
        /// reported "deferred" with nothing downloaded or started; else installed now. install: null once the installer
        /// started, else the error.
        public static void Handle(PendingUpdate p, bool busy, DeferredUpdates held, Func<PendingUpdate, string> install)
        {
            if (!IsNewer(p.Version, Program.Version)) { Log.Write("update to " + (p.Version ?? "?") + " ignored: not newer than " + Program.Version); return; }
            if (!busy) { Apply(p, install); return; }
            if (!UrlAllowed(p.Url, p.Server)) { Log.Write("update to " + p.Version + " failed: update link rejected"); p.Send(ReportJson(p.Version, "update link rejected")); return; }
            var kept = held.Offer(p);
            Log.Write("update to " + p.Version + ": recording in progress; deferred until it is uploaded" + (kept == p ? "" : " (" + kept.Version + " is held)"));
            p.Send(StatusJson("deferred", kept.Version, null));
        }

        /// After a recording is uploaded (Recorder.Finished): the held update, unless a recording is running again (then
        /// it stays held for that one). A link that expired meanwhile fails without a download (the server resends).
        public static void RunDeferred(Func<bool> busy, DeferredUpdates held, long nowUnix, Func<PendingUpdate, string> install)
        {
            if (busy()) return;
            var p = held.Take();
            if (p == null) return;
            if (busy()) { held.Offer(p); return; }
            if (!IsNewer(p.Version, Program.Version)) return;
            string expired = Expired(p, nowUnix);
            if (expired != null) { Log.Write("update to " + p.Version + " failed: " + expired); p.Send(ReportJson(p.Version, expired)); return; }
            Log.Write("update to " + p.Version + ": recording uploaded; running the deferred update");
            Apply(p, install);
        }

        static void Apply(PendingUpdate p, Func<PendingUpdate, string> install)
        {
            string error;
            try { error = install(p); }
            catch (Exception e) { error = "installer not started: " + e.GetType().Name; }
            Log.Write("update to " + p.Version + (error == null ? ": installer started" : " failed: " + error));
            p.Send(ReportJson(p.Version, error));
        }

        /// Never called while recording (Handle / RunDeferred hold the update instead).
        public static string Install(Config cfg, string server, string sha256, string url)
        {
            string installDir = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\');
            if (!string.Equals(installDir, (cfg.Dir ?? "").TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return "not an installed recorder (data folder is not the install folder)";
            if (!UrlAllowed(url, server)) return "update link rejected";
            lock (Gate)
            {
                if (DateTime.UtcNow - startedAt < Cooldown) return "an update is already in progress";
                startedAt = DateTime.UtcNow;
            }
            byte[] data;
            try { data = Download(url); }
            catch (Exception e) { lock (Gate) startedAt = DateTime.MinValue; return "download failed: " + e.GetType().Name; }
            if (!HashMatches(data, sha256)) { lock (Gate) startedAt = DateTime.MinValue; return "sha256 mismatch"; }
            string recorded = null, name = null;
            try
            {
                string opts = Path.Combine(installDir, OptionsFile);
                if (File.Exists(opts)) ParseOptions(File.ReadAllText(opts), out recorded, out name);
            }
            catch (Exception e) { Log.Write("update: " + OptionsFile + " unreadable (" + e.GetType().Name + "); using the live autostart check"); }
            string exe = Path.Combine(installDir, "AgentRecorder.exe");
            bool noAutostart = NoAutostart(recorded, recorded == "logon" || StartsThisExe(exe));
            Log.Write("update: autostart " + (noAutostart ? "none (-NoAutostart)" : "logon") + (name == null ? "" : ", recorded device name kept"));
            string script = Path.Combine(Path.GetTempPath(), "recitbot-update-" + Guid.NewGuid().ToString("N") + ".ps1");
            File.WriteAllBytes(script, data);
            var psi = new ProcessStartInfo("powershell.exe", Arguments(script, server, installDir, noAutostart, name))
            {
                UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
            };
            using (Process.Start(psi)) { }
            return null;
        }

        static byte[] Download(string url)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = 30000;
            req.ReadWriteTimeout = 30000;
            req.AllowAutoRedirect = false;
            using (var res = (HttpWebResponse)req.GetResponse())
            using (var s = res.GetResponseStream())
            using (var m = new MemoryStream())
            {
                var buf = new byte[16384];
                int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0)
                {
                    m.Write(buf, 0, n);
                    if (m.Length > MaxScriptBytes) throw new InvalidDataException("installer too large");
                }
                return m.ToArray();
            }
        }
    }

    /// One verified update command: what to install, until when its link works (unix s; 0 = unknown) and where its
    /// report goes (the connection it came in on).
    sealed class PendingUpdate
    {
        public readonly string Version, Sha256, Url, Server;
        public readonly long Expires;
        public readonly Action<string> Send;

        public PendingUpdate(string version, string sha256, string url, string server, long expires, Action<string> send)
        {
            Version = version; Sha256 = sha256; Url = url; Server = server; Expires = expires; Send = send;
        }
    }

    /// The update held while recording: at most one, the newest version (the same version again replaces it: a later
    /// command has a fresher link). parity: mac/Sources/RecitbotCore/SelfUpdater.swift DeferredUpdates
    sealed class DeferredUpdates
    {
        readonly object gate = new object();
        PendingUpdate held;

        /// Holds p unless a newer version is held; returns the one held afterwards.
        public PendingUpdate Offer(PendingUpdate p)
        {
            lock (gate)
            {
                if (held == null || !SelfUpdater.IsNewer(held.Version, p.Version)) held = p;
                return held;
            }
        }

        public PendingUpdate Take()
        {
            lock (gate) { var p = held; held = null; return p; }
        }

        public PendingUpdate Held { get { lock (gate) return held; } }
    }

    /// The rollback of install.ps1 -Update (hello "update_defer_rollback"): it keeps the previous files in BackupDir,
    /// swaps, starts the new recorder and waits up to WindowSeconds for MarkerFile naming the new version, which the
    /// recorder writes once a connection is up and its hello went out. Missing by then (or the recorder gone): the
    /// backup goes back, RollbackFile records the attempted version and the previous recorder starts again; it reports
    /// {"type":"update","status":"rolled_back","version":<attempted>} on each account's next connect. config.dat is never
    /// part of the backup or the swap. Decide is the template's Get-UpdateHealth (the selftest runs both on one table).
    /// parity: mac/Sources/RecitbotCore/SelfUpdater.swift UpdateHealth, mac/installer/install.template.sh update_health
    static class UpdateHealth
    {
        public const string MarkerFile = "update-health.txt", RollbackFile = "update-rollback.txt", BackupDir = "update-backup";
        public const int WindowSeconds = 90;

        public enum Verdict { Wait, Healthy, RollBack }

        public static string MarkerText(string version) { return "version=" + version + "\r\n"; }

        /// The x.y.z of the first "version=" line, or null.
        public static string VersionIn(string text)
        {
            foreach (var raw in (text ?? "").Split('\n'))
            {
                string line = raw.Trim().TrimStart('﻿');
                if (!line.StartsWith("version=")) continue;
                string v = line.Substring(8).Trim();
                return System.Text.RegularExpressions.Regex.IsMatch(v, "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$") ? v : null;
            }
            return null;
        }

        /// The installer's check after the swap: the marker names the new version = healthy; else, once the window is
        /// over or the new recorder is gone, roll back; else keep waiting.
        public static Verdict Decide(string marker, string version, bool running, double elapsedSeconds, double windowSeconds)
        {
            if (version != null && VersionIn(marker) == version) return Verdict.Healthy;
            if (!running || elapsedSeconds >= windowSeconds) return Verdict.RollBack;
            return Verdict.Wait;
        }

        public static string RolledBackJson(string version) { return SelfUpdater.StatusJson("rolled_back", version, null); }

        /// Written once per run, after the first hello went out. Never throws.
        public static void WriteMarker(string dir, string version)
        {
            try { File.WriteAllText(Path.Combine(dir, MarkerFile), MarkerText(version)); }
            catch (Exception e) { Log.Write("update health marker not written: " + e.GetType().Name); }
        }

        /// The version a rollback put this recorder back from, or null (none recorded, or this recorder is that version
        /// or newer: then the record is stale and goes).
        public static string RolledBack(string dir, string current)
        {
            string f = Path.Combine(dir ?? "", RollbackFile), v;
            try { v = File.Exists(f) ? VersionIn(File.ReadAllText(f)) : null; }
            catch { return null; }
            if (v != null && SelfUpdater.IsNewer(v, current)) return v;
            if (File.Exists(f)) Clear(dir);
            return null;
        }

        public static void Clear(string dir)
        {
            try { File.Delete(Path.Combine(dir ?? "", RollbackFile)); } catch { }
        }
    }

    // ---------------------------------------------------------------- self-uninstall

    /// When the server has revoked this device ("uninstall Recitbot"): the device WebSocket upgrade answers 410
    /// {"error":"device_revoked","scope":...}. Only that exact answer counts; 401/403/404/409/426/5xx, a 410 with any other body,
    /// timeouts, offline, DNS and TLS errors keep the agent reconnecting as before. Pure except Probe.
    /// parity: mac/Sources/RecitbotCore/SelfUninstaller.swift Revocation
    static class Revocation
    {
        public const int ProbeTimeoutMs = 15000;
        const int MaxBodyChars = 4096;

        /// status 410 and a JSON body whose "error" is exactly "device_revoked".
        public static bool IsRevoked(int status, string body) { return RevokedScope(status, body) != null; }

        /// What a revocation removes (null = not revoked): the body's "scope" (2026.11, {"error":"device_revoked",
        /// "scope":"account"|"all"}). "account" drops only that account's pairing; "all", or no scope at all (a server from
        /// before scopes, whose uninstall always removed everything), removes the install. Any other value counts as
        /// "account": the token is dead either way, and a 410 for one account says nothing about the others.
        /// parity: mac Revocation.revokedScope
        public static SelfUninstaller.Scope? RevokedScope(int status, string body)
        {
            if (status != 410 || string.IsNullOrEmpty(body)) return null;
            try
            {
                var f = Json.ParseFlat(body);
                string e, v;
                if (!f.TryGetValue("error", out e) || e != "device_revoked") return null;
                if (!f.TryGetValue("scope", out v) || v == null) return SelfUninstaller.Scope.All;
                return v == "all" ? SelfUninstaller.Scope.All : SelfUninstaller.Scope.Account;
            }
            catch { return null; }
        }

        /// The HTTP status of a refused WebSocket handshake, from the exception chain: WebException.Response, or the
        /// WebSocketException text "The server returned status code '410' when status code '101' was expected.".
        /// 0 = unknown (no response: network, DNS, TLS, timeout).
        public static int HandshakeStatus(Exception e)
        {
            for (var x = e; x != null; x = x.InnerException)
            {
                var we = x as WebException;
                if (we != null)
                {
                    var res = we.Response as HttpWebResponse;
                    if (res != null) { try { return (int)res.StatusCode; } catch { } }
                }
                var m = System.Text.RegularExpressions.Regex.Match(x.Message ?? "", "status code '([0-9]{3})' when status code '101' was expected");
                if (m.Success) return int.Parse(m.Groups[1].Value);
            }
            return 0;
        }

        /// The reconnect loop's log line: "connection error: <type> <message>", plus " (handshake HTTP <status>)" when the
        /// handshake was refused with a status, and for 401 a hint that the device is no longer paired (an unknown token
        /// otherwise reads like a network outage). 403 gets no hint: it may come from the Cloudflare edge, not the Worker.
        /// Pure; covered by the selftest.
        public static string ConnectionErrorLine(Exception e, int status)
        {
            string line = "connection error: " + (e == null ? "" : e.GetType().Name + " " + e.Message);
            if (status == 0) return line;
            line += " (handshake HTTP " + status + ")";
            if (status == 401) line += " - this device is no longer paired; pair again (get_installer)";
            return line;
        }

        /// The exceptions behind a connection error, outermost first ("inner: Type message <- Type message"), or null
        /// when there are none. .NET's "An internal WebSocket error occurred" says what actually failed only there.
        public static string InnerErrorLine(Exception e)
        {
            var parts = new List<string>();
            for (var x = e == null ? null : e.InnerException; x != null && parts.Count < 5; x = x.InnerException)
                parts.Add(x.GetType().Name + " " + x.Message);
            return parts.Count == 0 ? null : "inner: " + string.Join(" <- ", parts);
        }

        public enum Next { Retry, Stop, Uninstall }

        /// What the reconnect loop does after a connection error. A refused handshake: Uninstall when revoked() (410 +
        /// device_revoked, AccountLink.Revoked, asked first; Agent.Revoked then applies its scope); Stop for 401 only (the Worker's /device/ws answers 401
        /// for an unknown token: retrying cannot fix that, only a new pairing can, so /device/ws is not hit every 5
        /// minutes); Retry with the backoff for everything else (network errors are 0, 403, 5xx, other statuses) and for
        /// any error after the socket was connected. 403 retries because the Worker's only device 403 is the DeviceHub
        /// account mismatch and a 403 can also come from the Cloudflare edge (WAF, bot rules, rate limits); stopping on it
        /// could strand a paired PC until reinstall. Pure; covered by the selftest.
        public static Next AfterError(bool connected, int status, Func<bool> revoked)
        {
            if (connected) return Next.Retry;
            if (revoked()) return Next.Uninstall;
            return status == 401 ? Next.Stop : Next.Retry;
        }

        /// Seconds a session must last before another fast reconnect is allowed right after a fast one (a server that
        /// accepts and drops at once then gets the 5 s backoff every other attempt instead of a ~1 s loop).
        public const double StableSessionSeconds = 30;

        /// Whether the next /device/ws attempt uses the fast first delay: only after the socket connected (a clean close
        /// or a drop of a live session, e.g. a Durable Object restart on deploy), and not twice in a row for sessions
        /// shorter than StableSessionSeconds. A socket that never connected (403, 5xx, network) keeps the backoff.
        public static bool FastReconnect(bool connected, bool previousWasFast, double sessionSeconds)
        {
            return connected && (!previousWasFast || sessionSeconds >= StableSessionSeconds);
        }

        /// The wait before the next attempt, null for Stop (401: no more attempts). fast: 0.5 s + unit (0..1) seconds,
        /// i.e. 0.5-1.5 s. Otherwise the backoff (5 s doubling to 300 s) plus jitter (0-2 whole seconds). Pure.
        public static TimeSpan? ReconnectDelay(Next next, bool fast, int backoff, double unit, int jitter)
        {
            if (next == Next.Stop) return null;
            if (fast) return TimeSpan.FromSeconds(0.5 + Math.Max(0, Math.Min(1, unit)));
            return TimeSpan.FromSeconds(backoff + jitter);
        }

        /// Logged once when the reconnect loop stops on 401.
        public const string StoppedLine = "not paired: reconnecting stopped (no more /device/ws retries); the recorder stays running, idle, until it is paired again (get_installer) or restarted";

        /// The refused handshake's response body when the exception still carries a readable one, else null.
        public static string HandshakeBody(Exception e)
        {
            for (var x = e; x != null; x = x.InnerException)
            {
                var we = x as WebException;
                if (we == null || !(we.Response is HttpWebResponse)) continue;
                try { return ReadBody((HttpWebResponse)we.Response); }
                catch { return null; }
            }
            return null;
        }

        /// The confirming probe's code: never a real pairing code (the server checks the token before the code anyway).
        public const string ProbeCode = "0000000000";

        /// The probe's POST /device/enroll body: {"code":"0000000000","name":"revocation-check","platform":<platform>,
        /// "device_token":<token>}. Pure; covered by the selftest.
        /// parity: mac Revocation.probeBody
        public static string ProbeBody(string token, string platform)
        {
            return "{\"code\":" + Json.Esc(ProbeCode) + ",\"name\":\"revocation-check\",\"platform\":" + Json.Esc(platform)
                + ",\"device_token\":" + Json.Esc(token) + "}";
        }

        /// The confirming probe after a 410 handshake: one POST <server>/device/enroll with ProbeBody (a dummy code and the
        /// device token), 15 s, no redirects, no cookies, no cache. The server's pairDevice checks isRevokedDeviceToken
        /// before it looks the code up, so a revoked token gets 410 {"error":"device_revoked","scope":...} and no code is
        /// touched; a live token gets 401 (invalid code). The revocation's scope (RevokedScope) only for 410
        /// device_revoked; anything else (401, no response, ...) is null. The token is never logged.
        public static SelfUninstaller.Scope? Probe(string server, string token)
        {
            try
            {
                var body = Encoding.UTF8.GetBytes(ProbeBody(token, "windows"));
                var req = (HttpWebRequest)WebRequest.Create((server ?? "").TrimEnd('/') + "/device/enroll");
                req.Method = "POST";
                req.ContentType = "application/json";
                req.ContentLength = body.Length;
                req.Timeout = ProbeTimeoutMs;
                req.ReadWriteTimeout = ProbeTimeoutMs;
                req.AllowAutoRedirect = false;
                req.CookieContainer = null;
                req.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
                using (var s = req.GetRequestStream()) s.Write(body, 0, body.Length);
                HttpWebResponse res;
                try { res = (HttpWebResponse)req.GetResponse(); }
                catch (WebException e) { res = e.Response as HttpWebResponse; }
                if (res == null) return null;
                using (res) return RevokedScope((int)res.StatusCode, ReadBody(res));
            }
            catch { return null; }
        }

        static string ReadBody(HttpWebResponse res)
        {
            using (var s = res.GetResponseStream())
            using (var r = new StreamReader(s, Encoding.UTF8))
            {
                var buf = new char[MaxBodyChars];
                int n = r.ReadBlock(buf, 0, buf.Length);
                return new string(buf, 0, n);
            }
        }
    }

    /// Removes this install when the server says so (hello "self_uninstall"): a verified "uninstall" command (answered
    /// first with uninstall_ack) or a revoked device token (Revocation). A hidden, detached powershell.exe helper waits for
    /// this process to exit, stops stray ffmpeg from the install folder, removes the logon task, the HKCU Run values and
    /// Startup shortcuts that start this exe (never those of another copy, see Script), deletes the install folder (app,
    /// config, logs) and then itself. Only an installed recorder (InstalledCheck) deletes anything; a dev run just stops
    /// connecting.
    /// parity: mac/Sources/RecitbotCore/SelfUninstaller.swift SelfUninstaller, mac/Sources/Recitbot/SelfUninstall.swift
    static class SelfUninstaller
    {
        public static readonly string[] TaskNames = { "AgentRecorder" };
        public static readonly string[] RunValues = { "AgentRecorder", "Recitbot" };
        public static readonly string[] StartupLinks = { "AgentRecorder.lnk", "Recitbot.lnk" };
        static int started;

        /// A verified (rejection == null) command of type "uninstall". A rejected one (bad mac, expired, replayed, wrong
        /// account/device) never uninstalls.
        public static bool Commanded(string rejection, Dictionary<string, string> f)
        {
            string type;
            return rejection == null && f != null && f.TryGetValue("type", out type) && type == "uninstall";
        }

        /// {"type":"uninstall_ack","request_id":"<recording_id>","accounts_remaining":<n>} (0 when the whole install goes).
        /// requestId null: {"type":"uninstall_ack","accounts_remaining":0} with no request_id at all, the full-removal
        /// notice on the other accounts' sockets (the server revokes that connection's device and closes it).
        public static string AckJson(string requestId, int accountsRemaining)
        {
            return "{\"type\":\"uninstall_ack\"" + (requestId == null ? "" : ",\"request_id\":" + Json.Esc(requestId))
                + ",\"accounts_remaining\":" + Math.Max(0, accountsRemaining) + "}";
        }

        /// The signed command's `scope`: "account" removes only the account whose connection sent it; "all" removes the
        /// whole install. null = an unknown value (or null): the command is rejected (ScopeRejection).
        public enum Scope { Account, All }

        /// No scope at all (a server from before scopes, whose uninstall always removed everything) = All.
        public static Scope? ScopeOf(Dictionary<string, string> f)
        {
            string v;
            if (f == null || !f.ContainsKey("scope")) return Scope.All;
            f.TryGetValue("scope", out v);
            if (v == "account") return Scope.Account;
            if (v == "all") return Scope.All;
            return null;
        }

        /// The rejection of a verified "uninstall" command with an unknown scope (handled like any rejected command:
        /// logged, nothing removed); null for every other frame.
        public static string ScopeRejection(Dictionary<string, string> f)
        {
            string t;
            return f != null && f.TryGetValue("type", out t) && t == "uninstall" && ScopeOf(f) == null ? "unknown uninstall scope" : null;
        }

        /// How long the commanding connection's ack is waited for, and the other accounts' acks (sent at the same time).
        public const int AckWaitMs = 5000, OtherAcksWaitMs = 2000;

        /// The acks a removal sends as (account id, frame), the commanding connection's first. requestId (the command's
        /// recording_id; null for a revocation, which has no socket to answer on): AckJson(requestId, all ? 0 :
        /// accountsRemaining) on account's socket. all: AckJson(null, 0) on every other account in connected (accounts
        /// whose sockets are not connected get nothing). Scope "account" with accounts left: nothing to the others. Pure.
        /// parity: mac SelfUninstaller.acks
        public static List<KeyValuePair<string, string>> Acks(string account, string requestId, bool all, int accountsRemaining, IEnumerable<string> connected)
        {
            var o = new List<KeyValuePair<string, string>>();
            if (requestId != null) o.Add(new KeyValuePair<string, string>(account, AckJson(requestId, all ? 0 : accountsRemaining)));
            if (all)
                foreach (var c in connected)
                    if (c != account && !o.Exists(x => x.Key == c)) o.Add(new KeyValuePair<string, string>(c, AckJson(null, 0)));
            return o;
        }

        /// Whether the whole install goes: scope "all", or no account would be left (the last one is today's full removal).
        public static bool RemovesAll(Scope scope, int accountsRemaining) { return scope == Scope.All || accountsRemaining <= 0; }

        /// A PowerShell single-quoted literal. PowerShell also ends single-quoted strings at the typographic quotes
        /// U+2018..U+201B, so those are doubled too.
        public static string PsQuote(string s)
        {
            var sb = new StringBuilder("'");
            foreach (char c in s ?? "")
            {
                if (c == '\'' || (c >= '\u2018' && c <= '\u201B')) sb.Append(c);
                sb.Append(c);
            }
            return sb.Append('\'').ToString();
        }

        static string Trim(string p) { return (p ?? "").TrimEnd('\\'); }

        static bool Same(string a, string b) { return string.Equals(Trim(a), Trim(b), StringComparison.OrdinalIgnoreCase); }

        /// null when installDir is an installed recorder this process may delete, else why not. Same folder rule as
        /// SelfUpdater.Install (the exe's folder is the data folder), plus: it holds AgentRecorder.exe and config.dat, is
        /// not a drive root, and is neither %LOCALAPPDATA%, %USERPROFILE%, %TEMP% nor a folder above one of them.
        public static string InstalledCheck(string installDir, string dataDir, string localAppData, string userProfile, string temp, Func<string, bool> fileExists)
        {
            string dir = Trim(installDir);
            if (dir.Length == 0 || !Path.IsPathRooted(dir)) return "install folder unknown";
            if (!Same(dir, dataDir)) return "not an installed recorder (data folder is not the install folder)";
            string root = Path.GetPathRoot(dir);
            if (string.IsNullOrEmpty(root) || Same(dir, root)) return "refusing to delete a drive root";
            foreach (var keep in new[] { localAppData, userProfile, temp })
            {
                string k = Trim(keep);
                if (k.Length == 0) continue;
                if (Same(dir, k) || k.StartsWith(dir + "\\", StringComparison.OrdinalIgnoreCase)) return "refusing to delete " + k;
            }
            if (!fileExists(Path.Combine(dir, "AgentRecorder.exe")) || !fileExists(Path.Combine(dir, "config.dat")))
                return "not an installed recorder (no AgentRecorder.exe and config.dat)";
            return null;
        }

        static string List(string[] items)
        {
            var q = new List<string>();
            foreach (var i in items ?? new string[0]) q.Add(PsQuote(i));
            return "@(" + string.Join(", ", q) + ")";
        }

        /// The helper script (pure). Every literal is single-quoted (PsQuote); errors are silent. Startup entries are
        /// scoped to this install: a task goes only when every one of its actions runs exe, a Run value only when its
        /// command line's program is exe, a Startup shortcut only when its target is exe (full paths, case-insensitive).
        /// Entries of another copy with the same names are left alone. runKey / startupDir point the selftest at a
        /// sandbox; null means the real HKCU Run key / the user's Startup folder.
        public static string Script(string installDir, string exe, int agentPid, string[] taskNames, string[] runValueNames, string[] startupLinkNames,
            string runKey = "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", string startupDir = null)
        {
            var s = new StringBuilder();
            Action<string> L = delegate (string line) { s.Append(line).Append("\r\n"); };
            L("# Recitbot self-uninstall, written by the recorder; deletes itself when done.");
            L("$ErrorActionPreference = 'SilentlyContinue'");
            L("$ProgressPreference = 'SilentlyContinue'");
            L("$dir = " + PsQuote(Trim(installDir)));
            L("$exe = " + PsQuote(Trim(exe)));
            L("$agent = " + agentPid);
            L("function Resolve-Exe([string]$p) {");
            L("  if ([string]::IsNullOrEmpty($p)) { return $null }");
            L("  try {");
            L("    $p = [Environment]::ExpandEnvironmentVariables($p).Trim().Trim('\"')");
            L("    if ($p.Length -eq 0 -or -not [IO.Path]::IsPathRooted($p)) { return $null }");
            L("    return [IO.Path]::GetFullPath($p).TrimEnd('\\')");
            L("  } catch { return $null }");
            L("}");
            L("# The program of a command line: a quoted path, else the text through '.exe', else the first token.");
            L("function Get-CmdExe([string]$cmd) {");
            L("  if ([string]::IsNullOrEmpty($cmd)) { return $null }");
            L("  $c = $cmd.Trim()");
            L("  if ($c.StartsWith('\"')) { $e = $c.IndexOf('\"', 1); if ($e -lt 0) { $c = $c.Substring(1) } else { $c = $c.Substring(1, $e - 1) } }");
            L("  else {");
            L("    $m = [regex]::Match($c, '(?i)^.*?\\.exe(?=\\s|$)')");
            L("    if ($m.Success) { $c = $m.Value } else { $c = ($c -split '\\s+')[0] }");
            L("  }");
            L("  return Resolve-Exe $c");
            L("}");
            L("function Test-Self([string]$p) { return ($null -ne $p -and $p.Length -gt 0 -and [string]::Equals($p, $exe, [StringComparison]::OrdinalIgnoreCase)) }");
            L("# The agent exits right after starting this; wait up to 30 s, then stop it only if it is still the recorder.");
            L("for ($i = 0; $i -lt 120 -and (Get-Process -Id $agent -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }");
            L("$p = Get-Process -Id $agent -ErrorAction SilentlyContinue");
            L("if ($p -and $p.ProcessName -eq 'AgentRecorder') { Stop-Process -Id $agent -Force; $p.WaitForExit(5000) | Out-Null }");
            L("Get-CimInstance Win32_Process -Filter \"Name='ffmpeg.exe'\" | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($dir, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |");
            L("  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }");
            L("# Only this install's own startup entries: another copy may use the same names.");
            L("foreach ($n in " + List(taskNames) + ") {");
            L("  foreach ($t in @(Get-ScheduledTask -TaskName $n)) {");
            L("    $acts = @($t.Actions)");
            L("    $own = $acts.Count -gt 0");
            L("    foreach ($a in $acts) { if (-not (Test-Self (Resolve-Exe $a.Execute))) { $own = $false } }");
            L("    if ($own) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false }");
            L("  }");
            L("}");
            L("$run = " + PsQuote(runKey));
            L("foreach ($n in " + List(runValueNames) + ") {");
            L("  $v = (Get-ItemProperty -LiteralPath $run -Name $n).$n");
            L("  if (Test-Self (Get-CmdExe $v)) { Remove-ItemProperty -LiteralPath $run -Name $n }");
            L("}");
            L(startupDir == null ? "$startup = [Environment]::GetFolderPath('Startup')" : "$startup = " + PsQuote(startupDir));
            L("$shell = New-Object -ComObject WScript.Shell");
            L("foreach ($n in " + List(startupLinkNames) + ") {");
            L("  if (-not $startup -or -not $shell) { break }");
            L("  $f = Join-Path $startup $n");
            L("  if (Test-Path -LiteralPath $f) {");
            L("    $sc = $shell.CreateShortcut($f)");
            L("    if (Test-Self (Resolve-Exe $sc.TargetPath)) { Remove-Item -LiteralPath $f -Force }");
            L("  }");
            L("}");
            L("# Files can stay locked for a moment after the processes exit.");
            L("for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $dir); $i++) {");
            L("  Remove-Item -LiteralPath $dir -Recurse -Force");
            L("  if (Test-Path -LiteralPath $dir) { Start-Sleep -Milliseconds 500 }");
            L("}");
            L("Remove-Item -LiteralPath $PSCommandPath -Force");
            return s.ToString();
        }

        /// powershell.exe command line for the helper: no profile, no prompts, hidden.
        public static string CommandLine(string script)
        {
            return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Native.QuoteArg(script);
        }

        /// Writes the script to %TEMP%\recitbot-uninstall-<guid>.ps1 (UTF-8 with BOM, so Windows PowerShell reads any
        /// path right) and starts it hidden and detached. Returns the script path; throws when it could not start.
        public static string Launch(string script)
        {
            string path = Path.Combine(Path.GetTempPath(), "recitbot-uninstall-" + Guid.NewGuid().ToString("N") + ".ps1");
            File.WriteAllText(path, script, new UTF8Encoding(true));
            try { Native.StartDetachedHidden(CommandLine(path)); }
            catch { try { File.Delete(path); } catch { } throw; }
            return path;
        }

        /// Removes this install and exits the process (never returns). why goes to the log.
        public static void Run(Config cfg, string why)
        {
            if (Interlocked.Exchange(ref started, 1) == 1) return;
            string dir = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\');
            string refusal = InstalledCheck(dir, cfg.Dir, Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.GetTempPath(), File.Exists);
            if (refusal != null)
            {
                Log.Write("uninstall (" + why + "): " + refusal + "; nothing deleted, agent exiting");
                Environment.Exit(0);
            }
            try
            {
                string exe = Path.GetFullPath(System.Reflection.Assembly.GetEntryAssembly().Location);
                Launch(Script(dir, exe, Process.GetCurrentProcess().Id, TaskNames, RunValues, StartupLinks));
                Log.Write("uninstall (" + why + "): helper started; removing " + dir + " after this process exits");
            }
            catch (Exception e)
            {
                Log.Write("uninstall (" + why + "): helper not started (" + e.GetType().Name + "); deleting config.dat so this PC does not reconnect");
                try { File.Delete(Path.Combine(dir, "config.dat")); }
                catch (Exception e2) { Log.Write("uninstall: config.dat not deleted: " + e2.GetType().Name); }
            }
            Environment.Exit(0);
        }
    }

    // ---------------------------------------------------------------- UI

    /// Click vs drag for one left-button gesture, in screen pixels. The pointer moving Threshold px or more (straight-line
    /// distance from the mouse-down point, at any time during the gesture) makes it a drag, and a drag is never a click.
    class ClickGesture
    {
        public const int Threshold = 4;
        Point down;
        double travel;
        public bool Active { get; private set; }
        public bool Dragging { get; private set; }
        public int Dx { get; private set; }
        public int Dy { get; private set; }

        public void Down(Point screen)
        {
            down = screen;
            travel = 0;
            Dx = Dy = 0;
            Active = true;
            Dragging = false;
        }

        /// True while the gesture is a drag.
        public bool Move(Point screen)
        {
            if (!Active) return false;
            Dx = screen.X - down.X;
            Dy = screen.Y - down.Y;
            travel = Math.Max(travel, Math.Sqrt((double)Dx * Dx + (double)Dy * Dy));
            if (travel >= Threshold) Dragging = true;
            return Dragging;
        }

        /// Ends the gesture. True only for a click.
        public bool Up(Point screen)
        {
            if (!Active) return false;
            Move(screen);
            Active = false;
            return !Dragging;
        }
    }

    /// Geometry and drawing of the recording control pill at one DPI, in physical px (window coordinates). One row in a
    /// capsule: REC dot and timer, mic toggle, PC-sound toggle, Stop (the homepage demo's order). The window is the pill plus a transparent margin that
    /// holds its shadow. Every rectangle is a 96-dpi design rectangle with each edge scaled and rounded on its own (as
    /// ControlLayout), so elements apart at 100 % stay apart at any scale. Pure (no OS calls), covered by the selftest.
    class PillLayout
    {
        public const int W = 222, H = 40, Margin = 12, TopGap = 12;
        public const float TimerPx = 13.5f, StopPx = 12.5f, TipPx = 12f;
        public const double PulseSeconds = 1.6;
        public const string Mic = "mic", Sys = "sys", Stop = "stop";
        // Brand: Ink pill, Paper icons and text, Tally Red only on the REC dot and Stop.
        public static readonly Color Ink = Color.FromArgb(0x11, 0x13, 0x18), Paper = Color.FromArgb(0xF5, 0xF3, 0xEE), Red = Color.FromArgb(0xF2, 0x46, 0x3A);
        static readonly Color Graphite = Color.FromArgb(0x5B, 0x60, 0x6B);
        public readonly int Dpi;
        public readonly float Scale;
        /// The window: the pill plus Margin on every side.
        public readonly Size Size;
        public readonly Rectangle Pill, Dot, Timer, StopButton, MicButton, SysButton;

        public PillLayout(int dpi)
        {
            Dpi = dpi > 0 ? dpi : 96;
            Scale = Dpi / 96f;
            Size = new Size(S(W + 2 * Margin), S(H + 2 * Margin));
            Pill = R(0, 0, W, H);
            Dot = R(16, 15, 10, 10);
            Timer = R(32, 8, 58, 24);
            MicButton = R(94, 6, 28, 28);
            SysButton = R(126, 6, 28, 28);
            StopButton = R(162, 7, 54, 26);
        }

        public int S(float v) { return (int)Math.Round(v * Scale); }
        Rectangle R(int x, int y, int w, int h) { return Rectangle.FromLTRB(S(Margin + x), S(Margin + y), S(Margin + x + w), S(Margin + y + h)); }

        public Rectangle Of(string target) { return target == Mic ? MicButton : target == Sys ? SysButton : target == Stop ? StopButton : Rectangle.Empty; }

        public string HitTest(Point p)
        {
            foreach (var t in new[] { Stop, Mic, Sys }) if (Of(t).Contains(p)) return t;
            return null;
        }

        /// Inside the capsule (the shadow around it is not part of the pill).
        public bool InPill(Point p)
        {
            float r = Pill.Height / 2f, x = p.X + 0.5f, y = p.Y + 0.5f, cy = Pill.Y + r;
            float cx = Math.Max(Pill.X + r, Math.Min(Pill.Right - r, x));
            return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r;
        }

        /// The pill's body: the part that drags it (inside the capsule, not on a button).
        public bool IsBody(Point p) { return InPill(p) && HitTest(p) == null; }

        /// The button a finished gesture clicked (client coordinates), or null: it must be a click (under the drag
        /// threshold) that went down and up on the same button.
        public string ClickTarget(bool wasClick, Point downClient, Point upClient)
        {
            if (!wasClick) return null;
            string t = HitTest(downClient);
            return t != null && t == HitTest(upClient) ? t : null;
        }

        /// The timer: mm:ss, h:mm:ss from one hour on.
        public static string Elapsed(TimeSpan t)
        {
            long s = Math.Max(0, (long)Math.Floor(t.TotalSeconds));
            return s < 3600 ? string.Format("{0:00}:{1:00}", s / 60, s % 60) : string.Format("{0}:{1:00}:{2:00}", s / 3600, s / 60 % 60, s % 60);
        }

        public static string Tip(string target, bool available, bool on)
        {
            if (target == Stop) return "Stop recording";
            string what = target == Mic ? "mic" : "PC sound";
            if (!available) return "No " + what + " in this recording";
            return (on ? "Mute " : "Unmute ") + what;
        }

        public static readonly string[] AllTips =
        {
            Tip(Stop, true, true), Tip(Mic, true, true), Tip(Mic, true, false), Tip(Mic, false, false),
            Tip(Sys, true, true), Tip(Sys, true, false), Tip(Sys, false, false),
        };

        /// Where the pill (not its window) goes on a monitor: the spot saved for that monitor (offset from its top-left),
        /// else centred at the top of the work area, TopGap px down; always fully inside the monitor.
        public Point Place(Rectangle bounds, Rectangle workArea, Point? saved)
        {
            var p = saved.HasValue ? new Point(bounds.X + saved.Value.X, bounds.Y + saved.Value.Y)
                : new Point(workArea.X + (workArea.Width - Pill.Width) / 2, workArea.Top + S(TopGap));
            return Displays.KeepInside(new Rectangle(p, Pill.Size), bounds);
        }

        /// The tooltip under the pill, centred on its button; above the pill when there is no room below on the monitor.
        public Point TipAt(Rectangle button, Rectangle pill, Size tip, Rectangle screen)
        {
            int x = button.X + button.Width / 2 - tip.Width / 2, y = pill.Bottom + S(6);
            if (y + tip.Height > screen.Bottom) y = pill.Top - S(6) - tip.Height;
            return Displays.KeepInside(new Rectangle(new Point(x, y), tip), screen);
        }

        public Size TipSize(Graphics g, Font f, string text) { return new Size((int)Math.Ceiling(MeasureTypo(g, f, text)) + S(20), S(26)); }

        static string uiFamily, tipFamily;

        /// Inter (the brand face) when installed, else Segoe UI.
        public static string UiFamily { get { if (uiFamily == null) uiFamily = Installed("Inter SemiBold", "Inter Semi Bold", "Inter Medium", "Inter") ?? "Segoe UI Semibold"; return uiFamily; } }
        public static string TipFamily { get { if (tipFamily == null) tipFamily = Installed("Inter") ?? "Segoe UI"; return tipFamily; } }

        static string Installed(params string[] names)
        {
            try
            {
                using (var c = new System.Drawing.Text.InstalledFontCollection())
                    foreach (var n in names)
                        foreach (var f in c.Families)
                            if (string.Equals(f.Name, n, StringComparison.OrdinalIgnoreCase)) return f.Name;
            }
            catch { }
            return null;
        }

        public sealed class Fonts : IDisposable
        {
            public readonly Font Timer, Button, Tip;

            public Fonts(float scale)
            {
                Timer = new Font(UiFamily, TimerPx * scale, FontStyle.Regular, GraphicsUnit.Pixel);
                Button = new Font(UiFamily, StopPx * scale, FontStyle.Regular, GraphicsUnit.Pixel);
                Tip = new Font(TipFamily, TipPx * scale, FontStyle.Regular, GraphicsUnit.Pixel);
            }

            public void Dispose() { Timer.Dispose(); Button.Dispose(); Tip.Dispose(); }
        }

        static StringFormat Typo()
        {
            var f = (StringFormat)StringFormat.GenericTypographic.Clone();
            f.FormatFlags |= StringFormatFlags.NoWrap | StringFormatFlags.MeasureTrailingSpaces;
            return f;
        }

        public static float MeasureTypo(Graphics g, Font f, string s) { using (var fmt = Typo()) return g.MeasureString(s, f, PointF.Empty, fmt).Width; }

        /// Tabular figures: every digit gets the widest digit's advance, so the timer never jitters. Segoe UI's figures are
        /// tabular already; Inter's are not by default and GDI+ cannot turn on its tnum feature.
        static void Advances(Graphics g, Font f, out float digit, out float colon)
        {
            digit = 0;
            for (char c = '0'; c <= '9'; c++) digit = Math.Max(digit, MeasureTypo(g, f, c.ToString()));
            colon = MeasureTypo(g, f, ":");
        }

        public static float TabularWidth(Graphics g, Font f, string s)
        {
            float digit, colon, w = 0;
            Advances(g, f, out digit, out colon);
            foreach (char c in s) w += char.IsDigit(c) ? digit : colon;
            return w;
        }

        static void DrawTabular(Graphics g, Font f, Brush b, Rectangle area, string s)
        {
            float digit, colon;
            Advances(g, f, out digit, out colon);
            float h = f.GetHeight(g), x = area.X, y = area.Y + (area.Height - h) / 2f;
            using (var fmt = Typo())
            {
                fmt.Alignment = StringAlignment.Center;
                foreach (char c in s)
                {
                    float w = char.IsDigit(c) ? digit : colon;
                    g.DrawString(c.ToString(), f, b, new RectangleF(x, y, w, h), fmt);
                    x += w;
                }
            }
        }

        static Color Mix(Color a, Color b, float t)
        {
            return Color.FromArgb((int)Math.Round(a.R + (b.R - a.R) * t), (int)Math.Round(a.G + (b.G - a.G) * t), (int)Math.Round(a.B + (b.B - a.B) * t));
        }

        /// Fully rounded ends (a circle when square).
        public static GraphicsPath Capsule(RectangleF r)
        {
            var p = new GraphicsPath();
            float d = Math.Min(r.Width, r.Height);
            p.AddArc(r.X, r.Y, d, d, 90, 180);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 270, 180);
            p.CloseFigure();
            return p;
        }

        public static GraphicsPath RoundRect(Rectangle r, int d)
        {
            var p = new GraphicsPath();
            d = Math.Max(1, Math.Min(d, Math.Min(r.Width, r.Height)));
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static GraphicsPath RoundRectF(RectangleF r, float d)
        {
            var p = new GraphicsPath();
            d = Math.Max(1, Math.Min(d, Math.Min(r.Width, r.Height)));
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static void Quality(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        }

        /// The whole window on a transparent surface: shadow, capsule, dot, timer, Stop, toggles. pulse: 1 = dot fully lit.
        public void Draw(Graphics g, Fonts f, TimeSpan t, double pulse, bool stopping, bool micAvailable, bool micOn, bool sysAvailable, bool sysOn,
            string hover, string pressed)
        {
            Quality(g);
            // Soft shadow: stacked translucent capsules, widest first, 2 px below the pill (~30 % black at its edge).
            int n = S(9);
            int layer = Math.Max(1, (int)Math.Round(255 * (1 - Math.Pow(0.7, 1.0 / n))));
            using (var b = new SolidBrush(Color.FromArgb(layer, 0, 0, 0)))
                for (int i = n; i >= 1; i--)
                    using (var p = Capsule(new RectangleF(Pill.X - i, Pill.Y - i + S(2), Pill.Width + 2 * i, Pill.Height + 2 * i))) g.FillPath(b, p);
            var body = new RectangleF(Pill.X, Pill.Y, Pill.Width, Pill.Height);
            using (var p = Capsule(body))
            using (var b = new SolidBrush(Ink))
                g.FillPath(b, p);
            float bw = Math.Max(1, S(1));
            using (var p = Capsule(RectangleF.Inflate(body, -bw / 2, -bw / 2)))
            using (var pen = new Pen(Color.FromArgb(38, Paper), bw))
                g.DrawPath(pen, p);
            // REC dot: a gentle opacity pulse (100 % -> 45 %), as on the homepage demo.
            using (var b = new SolidBrush(Color.FromArgb((int)Math.Round(255 * (0.45 + 0.55 * pulse)), Red))) g.FillEllipse(b, Dot);
            using (var b = new SolidBrush(Paper)) DrawTabular(g, f.Timer, b, Timer, Elapsed(t));
            Color sc = stopping ? Mix(Red, Ink, 0.45f) : pressed == Stop ? Mix(Red, Ink, 0.15f) : hover == Stop ? Mix(Red, Paper, 0.12f) : Red;
            using (var p = Capsule(StopButton))
            using (var b = new SolidBrush(sc))
                g.FillPath(b, p);
            using (var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (var b = new SolidBrush(stopping ? Color.FromArgb(150, Paper) : Paper))
                g.DrawString("Stop", f.Button, b, StopButton, center);
            DrawToggle(g, Mic, micAvailable, micOn, hover == Mic, pressed == Mic);
            DrawToggle(g, Sys, sysAvailable, sysOn, hover == Sys, pressed == Sys);
        }

        /// One toggle: a lucide-style mic or speaker (the homepage demo's icons) in Paper. Muted: a slash and a faint fill;
        /// not in this recording: dimmed with a slash.
        void DrawToggle(Graphics g, string target, bool available, bool on, bool hover, bool down)
        {
            var r = Of(target);
            int fill = !available ? 0 : (on ? 0 : 24) + (hover ? 22 : 0) + (down ? 14 : 0);
            Color bg = Mix(Ink, Paper, fill / 255f), fg = available ? Paper : Graphite;
            if (fill > 0)
                using (var p = Capsule(r))
                using (var b = new SolidBrush(bg))
                    g.FillPath(b, p);
            float size = 16 * Scale, k = size / 24f, ox = r.X + (r.Width - size) / 2f, oy = r.Y + (r.Height - size) / 2f;
            using (var path = new GraphicsPath())
            using (var pen = new Pen(fg, 2.25f * k) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            {
                // 24x24 grid, the demo's SVG paths.
                if (target == Mic)
                {
                    path.AddArc(9, 3, 6, 6, 180, 180);
                    path.AddArc(9, 8, 6, 6, 0, 180);
                    path.CloseFigure();
                    path.StartFigure();
                    path.AddArc(5, 4, 14, 14, 0, 180);
                    path.StartFigure();
                    path.AddLine(12, 18, 12, 21);
                }
                else
                {
                    path.AddPolygon(new[] { new PointF(4, 9), new PointF(4, 15), new PointF(8, 15), new PointF(13, 19), new PointF(13, 5), new PointF(8, 9) });
                    if (on && available)
                    {
                        path.StartFigure();
                        path.AddArc(9.354f, 8, 8, 8, -48.59f, 97.18f);
                        path.StartFigure();
                        path.AddArc(5.709f, 4, 16, 16, -48.59f, 97.18f);
                    }
                }
                using (var m = new Matrix(k, 0, 0, k, ox, oy)) path.Transform(m);
                g.DrawPath(pen, path);
                if (!on || !available)
                {
                    // Slash with a background-coloured edge so it reads on top of the icon.
                    PointF a = new PointF(ox + 3 * k, oy + 3 * k), z = new PointF(ox + 21 * k, oy + 21 * k);
                    using (var edge = new Pen(bg, 5.5f * k) { StartCap = LineCap.Round, EndCap = LineCap.Round }) g.DrawLine(edge, a, z);
                    g.DrawLine(pen, a, z);
                }
            }
        }

        /// The tooltip, filling its whole surface: Ink, 1 px border, Paper text.
        public void DrawTip(Graphics g, Font f, Size size, string text)
        {
            Quality(g);
            var r = new RectangleF(0, 0, size.Width, size.Height);
            float bw = Math.Max(1, S(1));
            using (var p = RoundRectF(r, S(12)))
            using (var b = new SolidBrush(Ink))
                g.FillPath(b, p);
            using (var p = RoundRectF(RectangleF.Inflate(r, -bw / 2, -bw / 2), S(12) - bw))
            using (var pen = new Pen(Color.FromArgb(38, Paper), bw))
                g.DrawPath(pen, p);
            using (var center = new StringFormat(StringFormatFlags.NoWrap) { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (var b = new SolidBrush(Paper))
                g.DrawString(text, f, b, r, center);
        }

        /// Offscreen render of the window (transparent outside the pill and its shadow), for --controls-shots and the selftest.
        public Bitmap Render(bool micAvailable, bool micOn, bool sysAvailable, bool sysOn, string hover)
        {
            var bmp = new Bitmap(Size.Width, Size.Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(bmp))
            using (var f = new Fonts(Scale))
            {
                g.Clear(Color.Transparent);
                Draw(g, f, TimeSpan.FromSeconds(83), 1, false, micAvailable, micOn, sysAvailable, sysOn, hover, null);
            }
            return bmp;
        }
    }

    /// A premultiplied 32-bit DIB that GDI+ draws into and UpdateLayeredWindow presents in one atomic update: per-pixel
    /// alpha (antialiased rounded ends, a soft shadow) and never a half-painted frame. Used by the pill and its tooltip.
    sealed class LayeredCanvas : IDisposable
    {
        public readonly Size Size;
        public readonly Bitmap Bitmap;
        readonly IntPtr dc, bmp, old;

        public LayeredCanvas(Size size)
        {
            Size = size;
            var bi = new Native.BITMAPINFOHEADER { Size = 40, Width = size.Width, Height = -size.Height, Planes = 1, BitCount = 32 };
            dc = Native.CreateCompatibleDC(IntPtr.Zero);
            IntPtr bits;
            bmp = Native.CreateDIBSection(dc, ref bi, 0, out bits, IntPtr.Zero, 0);
            if (bmp == IntPtr.Zero) { Native.DeleteDC(dc); throw new Exception("CreateDIBSection failed"); }
            old = Native.SelectObject(dc, bmp);
            Bitmap = new Bitmap(size.Width, size.Height, size.Width * 4, System.Drawing.Imaging.PixelFormat.Format32bppPArgb, bits);
        }

        /// A cleared surface to draw on; dispose it before Present.
        public Graphics Begin()
        {
            var g = Graphics.FromImage(Bitmap);
            g.Clear(Color.Transparent);
            return g;
        }

        public bool Present(IntPtr hwnd, Point at)
        {
            var dst = new Native.POINT(at.X, at.Y);
            var src = new Native.POINT(0, 0);
            var size = new Native.SIZE { CX = Size.Width, CY = Size.Height };
            var blend = new Native.BLENDFUNCTION { Op = 0 /* AC_SRC_OVER */, Alpha = 255, Format = 1 /* AC_SRC_ALPHA */ };
            return Native.UpdateLayeredWindow(hwnd, IntPtr.Zero, ref dst, ref size, dc, ref src, 0, ref blend, 2 /* ULW_ALPHA */);
        }

        public void Dispose()
        {
            Bitmap.Dispose();
            Native.SelectObject(dc, old);
            Native.DeleteObject(bmp);
            Native.DeleteDC(dc);
        }
    }

    /// The recording's only always-visible UI: one capsule centred at the top of the recorded monitor (12 px below its work
    /// area's top) with the REC dot and timer, the mic and PC-sound toggles, and Stop. A layered window drawn at its
    /// monitor's DPI, excluded from capture, never activated (clicks included), no taskbar entry. Dragged by its body (not
    /// the buttons), kept on the monitor it is dropped on, and its spot remembered per monitor (config pill_at_<monitor
    /// id>). A button acts only on a real click: pressed and released on it with < 4 px of movement. The toggles
    /// mute/unmute mid-recording and never stop it.
    class ControlPill : Form
    {
        readonly Config cfg;
        readonly MonitorInfo target;
        readonly List<MonitorInfo> monitors;
        readonly System.Windows.Forms.Timer tick = new System.Windows.Forms.Timer();
        readonly Stopwatch clock = new Stopwatch(), hoverClock = new Stopwatch();
        readonly ClickGesture gesture = new ClickGesture();
        PillLayout layout;
        PillLayout.Fonts fonts;
        LayeredCanvas canvas;
        PillTip tip;
        /// Window position (the pill sits layout.Pill.Location inside it). UpdateLayeredWindow moves the window.
        Point at;
        bool stopping, micAvailable, micOn, sysAvailable, sysOn, dragBody;
        string hover, pressed;
        Point windowStart, downAt;
        public string CaptureMode = "none";
        public event Action StopClicked;
        /// (PillLayout.Mic or .Sys, muted) after a toggle click or Toggle().
        public event Action<string, bool> MuteChanged;

        public ControlPill(Config cfg, MonitorInfo target, List<MonitorInfo> monitors)
        {
            this.cfg = cfg;
            this.target = target;
            this.monitors = monitors ?? new List<MonitorInfo> { target };
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            Text = "Recitbot recording";
            AccessibleName = "Recording controls: timer, mic, PC sound, Stop";
            var wa = target.WorkArea;
            SetScale(Native.DpiAt(new Point(wa.X + wa.Width / 2, wa.Top + 1)));
            Place();
            tick.Interval = 80;
            tick.Tick += delegate { OnTick(); };
        }

        public PillLayout Geometry { get { return layout; } }
        /// The pill on screen (without the shadow margin).
        public Rectangle PillBounds { get { return new Rectangle(at.X + layout.Pill.X, at.Y + layout.Pill.Y, layout.Pill.Width, layout.Pill.Height); } }
        public Point WindowAt { get { return at; } }
        public PillTip Tip { get { return tip; } }
        public bool MicOn { get { return micOn; } }
        public bool SysOn { get { return sysOn; } }

        void Place()
        {
            Point saved;
            var p = layout.Place(target.Bounds, target.WorkArea, cfg.PillAt.TryGetValue(target.Id ?? "", out saved) ? saved : (Point?)null);
            at = new Point(p.X - layout.Pill.X, p.Y - layout.Pill.Y);
            Bounds = new Rectangle(at, layout.Size);
        }

        void SetScale(int dpi)
        {
            layout = new PillLayout(dpi);
            if (fonts != null) fonts.Dispose();
            fonts = new PillLayout.Fonts(layout.Scale);
            if (canvas != null) canvas.Dispose();
            canvas = new LayeredCanvas(layout.Size);
            Size = layout.Size;
        }

        /// What this recording has: each toggle starts ON when its source is recorded, and is dimmed when it is not.
        public void SetSources(bool mic, bool sys)
        {
            micAvailable = micOn = mic;
            sysAvailable = sysOn = sys;
            Repaint();
            E2eRect();
        }

        /// The toggle action itself (the click handler calls this, and so does the e2e hook). Never stops the recording.
        public void Toggle(string target)
        {
            bool muted;
            if (target == PillLayout.Mic && micAvailable) { micOn = !micOn; muted = !micOn; }
            else if (target == PillLayout.Sys && sysAvailable) { sysOn = !sysOn; muted = !sysOn; }
            else return;
            HideTip();
            hoverClock.Restart(); // the tooltip comes back with the new state
            Repaint();
            Log.Write((target == PillLayout.Mic ? "mic" : "system audio") + (muted ? " muted" : " unmuted") + " from the pill");
            var h = MuteChanged;
            if (h != null) h(target, muted);
            E2eRect();
        }

        /// Dev preview only: shows the hover state and tooltip of one button without moving the mouse.
        public void PreviewHover(string target)
        {
            hover = target;
            hoverClock.Restart();
            Repaint();
            ShowTip();
        }

        public void Repaint()
        {
            if (!IsHandleCreated || canvas == null) return;
            using (var g = canvas.Begin())
                layout.Draw(g, fonts, clock.Elapsed, Pulse(), stopping, micAvailable, micOn, sysAvailable, sysOn,
                    gesture.Active ? null : hover, gesture.Active && !gesture.Dragging ? pressed : null);
            canvas.Present(Handle, at);
        }

        /// The current frame as a bitmap (e2e snapshot), cropped to the pill.
        public Bitmap Snapshot() { return canvas.Bitmap.Clone(layout.Pill, System.Drawing.Imaging.PixelFormat.Format32bppArgb); }

        double Pulse() { return 0.5 + 0.5 * Math.Cos(2 * Math.PI * clock.Elapsed.TotalSeconds / PillLayout.PulseSeconds); }

        void OnTick()
        {
            Repaint();
            if (hover != null && !gesture.Active && hoverClock.ElapsedMilliseconds >= 450 && (tip == null || !tip.Visible)) ShowTip();
        }

        void ShowTip()
        {
            if (hover == null || !IsHandleCreated) return;
            if (tip == null) tip = new PillTip();
            var b = layout.Of(hover);
            var pill = PillBounds;
            var d = Displays.Nearest(Displays.All(), Displays.Center(pill));
            tip.ShowTip(PillLayout.Tip(hover, hover == PillLayout.Mic ? micAvailable : sysAvailable, hover == PillLayout.Mic ? micOn : sysOn),
                new Rectangle(at.X + b.X, at.Y + b.Y, b.Width, b.Height), pill, d != null ? d.Bounds : pill, layout, fonts);
        }

        void HideTip() { if (tip != null && tip.Visible) tip.Hide(); }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x80 /* TOOLWINDOW */ | 0x8 /* TOPMOST */ | 0x08000000 /* NOACTIVATE */ | 0x80000 /* LAYERED */;
                return cp;
            }
        }

        // Layered window: all pixels come from UpdateLayeredWindow, never from WM_PAINT / WM_ERASEBKGND.
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            CaptureMode = Native.ExcludeFromCapture(Handle);
            int dpi = Native.DpiForWindow(Handle, Displays.Center(PillBounds));
            if (dpi != layout.Dpi) { SetScale(dpi); Place(); }
            Repaint(); // on screen with its pixels from the first frame Show makes it visible
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            clock.Start();
            tick.Start();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_MOUSEACTIVATE)
            {
                m.Result = (IntPtr)Native.MA_NOACTIVATE;
                return;
            }
            if (m.Msg == Native.WM_DPICHANGED)
            {
                // Dragged onto a monitor with another scale: redraw at its DPI in place (the drag drives the position).
                SetScale((int)((long)m.WParam & 0xFFFF));
                Repaint();
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left || stopping) return;
            string h = layout.HitTest(e.Location);
            if (h == null && !layout.InPill(e.Location)) return; // the shadow
            HideTip();
            gesture.Down(Native.MessagePos());
            windowStart = at;
            downAt = e.Location;
            dragBody = h == null;
            pressed = h;
            Capture = true;
            Repaint();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!gesture.Active)
            {
                string h = layout.HitTest(e.Location);
                Cursor = h != null ? Cursors.Hand : layout.InPill(e.Location) ? Cursors.SizeAll : Cursors.Default;
                if (h != hover) { hover = h; hoverClock.Restart(); HideTip(); Repaint(); }
                return;
            }
            bool dragging = gesture.Move(Native.MessagePos());
            if (dragging && dragBody) at = new Point(windowStart.X + gesture.Dx, windowStart.Y + gesture.Dy);
            if (dragging) Repaint();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hover != null && !gesture.Active) { hover = null; HideTip(); Repaint(); }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left || !gesture.Active) return;
            bool click = gesture.Up(Native.MessagePos());
            Capture = false;
            pressed = null;
            if (dragBody && gesture.Dragging) { Drop(); return; }
            string t = layout.ClickTarget(click, downAt, e.Location);
            Repaint();
            if (t == PillLayout.Mic || t == PillLayout.Sys) { Toggle(t); return; }
            if (t != PillLayout.Stop || stopping) return;
            stopping = true;
            Repaint();
            if (StopClicked != null) StopClicked();
        }

        /// End of a drag: the pill goes fully onto the monitor holding its centre, and that monitor remembers the spot.
        void Drop()
        {
            var r = PillBounds;
            var d = Displays.Nearest(Displays.All(), Displays.Center(r));
            var bounds = d != null ? d.Bounds : r;
            var p = Displays.KeepInside(r, bounds);
            at = new Point(p.X - layout.Pill.X, p.Y - layout.Pill.Y);
            Repaint();
            var m = monitors.Find(x => x.Bounds == bounds);
            if (m != null && m.Id != null)
            {
                var off = new Point(p.X - bounds.X, p.Y - bounds.Y);
                cfg.PillAt[m.Id] = off;
                cfg.SetPrefs("pill_at_" + m.Id, off.X + "," + off.Y);
            }
            Log.Write("pill moved to " + p.X + "," + p.Y + (m != null ? " on monitor " + m.Index : ""));
            E2eRect();
        }

        public void E2eRect()
        {
            if (!E2e.On || !IsHandleCreated) return;
            var p = PillBounds;
            Func<Rectangle, Rectangle> s = r => new Rectangle(at.X + r.X, at.Y + r.Y, r.Width, r.Height);
            Rectangle d = s(layout.Dot), st = s(layout.StopButton), mi = s(layout.MicButton), sy = s(layout.SysButton), tm = s(layout.Timer);
            E2e.Write("pill-rect.json", string.Format(
                "{{\"x\":{0},\"y\":{1},\"w\":{2},\"h\":{3},\"window_x\":{4},\"window_y\":{5},\"window_w\":{6},\"window_h\":{7},\"dpi\":{8},"
                + "\"dot_x\":{9},\"dot_y\":{10},\"dot_w\":{11},\"stop_x\":{12},\"stop_y\":{13},\"stop_w\":{14},\"stop_h\":{15},"
                + "\"mic_x\":{16},\"mic_y\":{17},\"sys_x\":{18},\"sys_y\":{19},\"toggle_w\":{20},\"capture_excluded\":{21},\"capture_mode\":\"{22}\","
                + "\"mic_available\":{23},\"mic_on\":{24},\"sys_available\":{25},\"sys_on\":{26},\"body_x\":{27},\"body_y\":{28}}}",
                p.X, p.Y, p.Width, p.Height, at.X, at.Y, layout.Size.Width, layout.Size.Height, layout.Dpi,
                d.X, d.Y, d.Width, st.X, st.Y, st.Width, st.Height,
                mi.X, mi.Y, sy.X, sy.Y, mi.Width, CaptureMode == "exclude" ? "true" : "false", CaptureMode,
                B(micAvailable), B(micOn), B(sysAvailable), B(sysOn), tm.X + tm.Width / 2, tm.Y + tm.Height / 2));
        }

        static string B(bool v) { return v ? "true" : "false"; }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            tick.Stop();
            if (tip != null) { tip.Close(); tip = null; }
            Log.Write("pill closed");
            base.OnFormClosed(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                tick.Dispose();
                if (tip != null) tip.Dispose();
                if (fonts != null) fonts.Dispose();
                if (canvas != null) canvas.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    /// The pill's tooltip: a small layered window like the pill (excluded from capture, never activated, click-through),
    /// under the hovered button, or above the pill when the pill sits at the bottom of its monitor. A stock ToolTip would
    /// be a separate window that shows up in the video.
    class PillTip : Form
    {
        LayeredCanvas canvas;
        Point at;

        public PillTip()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x80 /* TOOLWINDOW */ | 0x8 /* TOPMOST */ | 0x08000000 /* NOACTIVATE */ | 0x80000 /* LAYERED */ | 0x20 /* TRANSPARENT */;
                return cp;
            }
        }

        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.ExcludeFromCapture(Handle);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_MOUSEACTIVATE) { m.Result = (IntPtr)Native.MA_NOACTIVATE; return; }
            base.WndProc(ref m);
        }

        public void ShowTip(string text, Rectangle button, Rectangle pill, Rectangle screen, PillLayout l, PillLayout.Fonts f)
        {
            Size size;
            using (var probe = new Bitmap(1, 1))
            using (var g = Graphics.FromImage(probe))
                size = l.TipSize(g, f.Tip, text);
            if (canvas == null || canvas.Size != size)
            {
                if (canvas != null) canvas.Dispose();
                canvas = new LayeredCanvas(size);
            }
            using (var g = canvas.Begin()) l.DrawTip(g, f.Tip, size, text);
            at = l.TipAt(button, pill, size, screen);
            Bounds = new Rectangle(at, size);
            canvas.Present(Handle, at);
            if (!Visible) Show();
        }

        /// Dev preview only: where the tooltip is on screen.
        public Rectangle ScreenRect { get { return canvas == null ? Rectangle.Empty : new Rectangle(at, canvas.Size); } }

        protected override void Dispose(bool disposing)
        {
            if (disposing && canvas != null) canvas.Dispose();
            base.Dispose(disposing);
        }
    }

    /// A separate ffmpeg reading one camera as bgr24 frames (the bubble's size and aspect) on stdout.
    /// One background thread reads into a back buffer and swaps it with the front buffer: no per-frame allocations.
    class CameraFeed
    {
        readonly ICaptureBackend backend;
        readonly AvDevice camera;
        public readonly Size Size;
        readonly int frameBytes;
        byte[] front, back;
        readonly object gate = new object();
        bool fresh;
        volatile bool stopped;
        Process proc;
        string lastError = "";
        /// Frames read from the camera since Start (the bubble's redraw stats).
        public int Frames;
        public event Action Frame;
        public event Action<string> Failed;

        public CameraFeed(ICaptureBackend backend, AvDevice camera, Size size)
        {
            this.backend = backend; this.camera = camera; Size = size;
            frameBytes = size.Width * size.Height * 3;
            front = new byte[frameBytes];
            back = new byte[frameBytes];
        }

        public void Start()
        {
            var t = new Thread(Run);
            t.IsBackground = true;
            t.Name = "camera";
            // Above normal like the screen capture, so a busy desktop (a build on every core) cannot stall the bubble.
            t.Priority = ThreadPriority.AboveNormal;
            t.Start();
        }

        void Run()
        {
            // 640x480 keeps the camera's decode cheap; some cameras refuse it, so retry with the device default.
            foreach (bool sized in new[] { true, false })
            {
                if (stopped) return;
                Process p;
                try { p = Launch(sized); }
                catch (Exception e) { lastError = e.Message; break; }
                lock (gate) proc = p;
                if (stopped) { Kill(p); return; }
                bool got = Pump(p.StandardOutput.BaseStream);
                Kill(p);
                if (stopped) return;
                if (got) { Fail("camera stopped: " + lastError); return; }
                Log.Write("webcam: ffmpeg " + (sized ? "640x480" : "default size") + " failed: " + lastError);
            }
            Fail(lastError);
        }

        void Fail(string why) { var f = Failed; if (f != null && !stopped) f(why); }

        Process Launch(bool sized)
        {
            var p = Process.Start(backend.CameraProcess(camera, Size.Width, Size.Height, sized));
            Native.AddToKillJob(p);
            try { p.PriorityClass = WindowsFfmpegBackend.CapturePriority; } catch { }
            p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (!string.IsNullOrEmpty(e.Data)) lastError = e.Data.Trim(); };
            p.BeginErrorReadLine();
            return p;
        }

        bool Pump(Stream s)
        {
            bool any = false;
            try
            {
                while (!stopped)
                {
                    int off = 0;
                    while (off < frameBytes)
                    {
                        int n = s.Read(back, off, frameBytes - off);
                        if (n <= 0) return any;
                        off += n;
                    }
                    lock (gate) { var t = front; front = back; back = t; fresh = true; }
                    Interlocked.Increment(ref Frames);
                    any = true;
                    var f = Frame;
                    if (f != null) f();
                }
            }
            catch (Exception e) { if (!stopped) lastError = e.Message; }
            return any;
        }

        /// Copies the newest frame into dst (resized when needed). Returns false when nothing new arrived.
        public bool CopyLatest(ref byte[] dst, ref Size dstSize)
        {
            lock (gate)
            {
                if (!fresh) return false;
                fresh = false;
                if (dst == null || dst.Length != frameBytes) dst = new byte[frameBytes];
                Buffer.BlockCopy(front, 0, dst, 0, frameBytes);
                dstSize = Size;
                return true;
            }
        }

        static void Kill(Process p)
        {
            try { if (!p.HasExited) p.Kill(); } catch { }
            try { p.Dispose(); } catch { }
        }

        public void Stop()
        {
            stopped = true;
            Process p;
            lock (gate) { p = proc; proc = null; }
            if (p != null) Kill(p);
        }
    }

    /// The bubble's pixels: a premultiplied 32bpp DIB holding the camera frame inside an anti-aliased circle (or 16:9
    /// rounded rectangle) with a white ring that follows the shape. Mask and ring coverage are computed once per size and
    /// shape, so the ring's pixels are identical in every frame.
    sealed class BubbleSurface : IDisposable
    {
        public readonly int W, H;
        readonly byte[] mask, ring, pixels;
        int[] xmap;
        Size mapSrc;
        bool mapMirror;
        readonly IntPtr dc, bmp, old, bits;

        public BubbleSurface(Size size, float ringWidth, bool rect)
        {
            W = size.Width;
            H = size.Height;
            mask = new byte[W * H];
            ring = new byte[W * H];
            pixels = new byte[W * H * 4];
            Geometry(W, H, ringWidth, rect, mask, ring);
            var bi = new Native.BITMAPINFOHEADER { Size = 40, Width = W, Height = -H, Planes = 1, BitCount = 32 };
            dc = Native.CreateCompatibleDC(IntPtr.Zero);
            IntPtr b;
            bmp = Native.CreateDIBSection(dc, ref bi, 0, out b, IntPtr.Zero, 0);
            bits = b;
            if (bmp == IntPtr.Zero) throw new Exception("CreateDIBSection failed");
            old = Native.SelectObject(dc, bmp);
        }

        /// Corner radius of the rectangle shape: 12 % of its height (the shorter side).
        public static float CornerRadius(int height) { return 0.12f * height; }

        /// Analytic coverage (no GDI+) for either shape: mask = shape coverage per pixel, ring = share of that coverage that
        /// is ring. Both come from the shape's signed distance d (negative inside): mask = clamp(0.5 - d), inner =
        /// clamp(0.5 - (d + ringWidth)). The circle keeps its original closed form.
        public static void Geometry(int w, int h, float ringWidth, bool rect, byte[] mask, byte[] ring)
        {
            if (!rect && w == h) { Geometry(w, ringWidth, mask, ring); return; }
            float cx = w / 2f, cy = h / 2f, hx = cx - 0.5f, hy = cy - 0.5f, rr = Math.Min(CornerRadius(h), Math.Min(hx, hy));
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    float qx = Math.Abs(x + 0.5f - cx) - (hx - rr), qy = Math.Abs(y + 0.5f - cy) - (hy - rr);
                    float ox = Math.Max(qx, 0f), oy = Math.Max(qy, 0f);
                    float d = (float)Math.Sqrt(ox * ox + oy * oy) + Math.Min(Math.Max(qx, qy), 0f) - rr;
                    float m = Math.Max(0f, Math.Min(1f, 0.5f - d));
                    float inner = Math.Max(0f, Math.Min(1f, 0.5f - (d + ringWidth)));
                    int i = y * w + x;
                    mask[i] = (byte)Math.Round(m * 255);
                    ring[i] = m > 0 ? (byte)Math.Round((m - inner) / m * 255) : (byte)0;
                }
            }
        }

        /// Analytic coverage (no GDI+): mask = disc coverage per pixel, ring = share of that coverage that is ring.
        public static void Geometry(int side, float ringWidth, byte[] mask, byte[] ring)
        {
            float c = side / 2f, rOut = c - 0.5f, rIn = rOut - ringWidth;
            for (int y = 0; y < side; y++)
            {
                for (int x = 0; x < side; x++)
                {
                    float dx = x + 0.5f - c, dy = y + 0.5f - c;
                    float d = (float)Math.Sqrt(dx * dx + dy * dy);
                    float m = Math.Max(0f, Math.Min(1f, rOut - d + 0.5f));
                    float inner = Math.Max(0f, Math.Min(1f, rIn - d + 0.5f));
                    int i = y * side + x;
                    mask[i] = (byte)Math.Round(m * 255);
                    ring[i] = m > 0 ? (byte)Math.Round((m - inner) / m * 255) : (byte)0;
                }
            }
        }

        /// Composites one camera frame (bgr24, src size; null = placeholder) and mirrors it if asked. A frame of another
        /// size (camera not yet re-opened after a resize or shape change) is scaled to fit.
        public void Compose(byte[] src, Size srcSize, bool mirror)
        {
            int sw = srcSize.Width, sh = srcSize.Height;
            bool cam = src != null && sw > 0 && sh > 0 && src.Length >= sw * sh * 3;
            if (cam && (xmap == null || mapSrc != srcSize || mapMirror != mirror))
            {
                xmap = new int[W];
                for (int x = 0; x < W; x++)
                {
                    int sx = (int)((long)x * sw / W);
                    xmap[x] = (mirror ? sw - 1 - sx : sx) * 3;
                }
                mapSrc = srcSize;
                mapMirror = mirror;
            }
            for (int y = 0; y < H; y++)
            {
                int row = cam ? (int)((long)y * sh / H) * sw * 3 : 0;
                for (int x = 0; x < W; x++)
                {
                    int i = y * W + x, o = i * 4, a = mask[i];
                    if (a == 0) { pixels[o] = pixels[o + 1] = pixels[o + 2] = pixels[o + 3] = 0; continue; }
                    int b, g, r;
                    if (cam) { int s = row + xmap[x]; b = src[s]; g = src[s + 1]; r = src[s + 2]; }
                    else { b = 27; g = 24; r = 24; }
                    int k = ring[i];
                    if (k != 0)
                    {
                        b = (b * (255 - k) + 255 * k + 127) / 255;
                        g = (g * (255 - k) + 255 * k + 127) / 255;
                        r = (r * (255 - k) + 255 * k + 127) / 255;
                    }
                    if (a != 255)
                    {
                        b = (b * a + 127) / 255;
                        g = (g * a + 127) / 255;
                        r = (r * a + 127) / 255;
                    }
                    pixels[o] = (byte)b; pixels[o + 1] = (byte)g; pixels[o + 2] = (byte)r; pixels[o + 3] = (byte)a;
                }
            }
            Marshal.Copy(pixels, 0, bits, pixels.Length);
        }

        /// One atomic update of position, size and pixels.
        public bool Present(IntPtr hwnd, Point at)
        {
            var dst = new Native.POINT(at.X, at.Y);
            var src = new Native.POINT(0, 0);
            var size = new Native.SIZE { CX = W, CY = H };
            var blend = new Native.BLENDFUNCTION { Op = 0 /* AC_SRC_OVER */, Alpha = 255, Format = 1 /* AC_SRC_ALPHA */ };
            return Native.UpdateLayeredWindow(hwnd, IntPtr.Zero, ref dst, ref size, dc, ref src, 0, ref blend, 2 /* ULW_ALPHA */);
        }

        public void Dispose()
        {
            Native.SelectObject(dc, old);
            Native.DeleteObject(bmp);
            Native.DeleteDC(dc);
        }
    }

    /// Draggable webcam preview, round or a 16:9 rounded rectangle. A normal on-screen window (NOT capture-excluded) so the
    /// screen capture records it, and it never takes focus. Click: size slider, mirror and shape toggles (separate,
    /// capture-excluded window). Drag: move. Right-click: camera, mirror, shape, hide.
    ///
    /// Flicker fix: the bubble is a per-pixel-alpha layered window. Each frame is composited into one premultiplied DIB
    /// (BubbleSurface) and handed to DWM with a single UpdateLayeredWindow call, so the screen and the capture never see a
    /// half-painted frame. The old bubble blitted the camera frame and then drew the ring into an unbuffered window clipped
    /// by a hard-edged Region; DWM regularly composed between the two steps, so ~8 % of recorded frames lost the ring.
    class WebcamBubble : Form
    {
        public const int MinPx = 120, MaxPx = 480, DefaultPx = 240;
        static readonly string[] SizeNames = { "small", "medium", "large" };
        static readonly int[] SizeNamePx = { 160, 240, 360 };

        /// small/medium/large (the MCP webcam_size enum) as a diameter in px at 100 % scale; -1 when unknown.
        public static int PxForName(string name)
        {
            int i = name == null ? -1 : Array.IndexOf(SizeNames, name);
            return i < 0 ? -1 : SizeNamePx[i];
        }

        public static int ClampPx(int px) { return Math.Max(MinPx, Math.Min(MaxPx, px)); }

        /// start_recording webcam_size as a number: the bubble's height (the circle's diameter) as a percent of the
        /// monitor's shorter side, as a size on the slider's scale (px at 100 %), clamped to its range.
        public static int PxForPercent(int pct, Size monitor, int dpi, bool rect)
        {
            double h = Math.Max(1, Math.Min(100, pct)) / 100.0 * Math.Min(monitor.Width, monitor.Height) * 96.0 / Math.Max(1, dpi);
            return ClampPx((int)Math.Round(rect ? h / RectHeight : h));
        }

        /// The rectangle is 16:9 and 3/4 of the size value high (240 -> 320x180 at 100 %): about the circle's visual weight.
        public const double RectHeight = 0.75;

        readonly Config cfg;
        readonly ICaptureBackend backend;
        readonly List<AvDevice> cameras;
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly ClickGesture gesture = new ClickGesture();
        readonly System.Windows.Forms.Timer refeed = new System.Windows.Forms.Timer();
        readonly Action render;
        public readonly ManualResetEvent ShownEvent = new ManualResetEvent(false), FailedEvent = new ManualResetEvent(false);
        public string LastError = "";
        AvDevice camera;
        CameraFeed feed;
        BubbleSurface surface;
        ControlStrip strip;
        byte[] lastFrame;
        Size lastSize;
        int px, dpi, renderPending;
        bool mirror, rect, everShown, closing;
        Point formStart;
        IntPtr prevForeground;

        /// home = bounds of the recorded monitor: the bubble starts there so it is in the video. inside = the recorded
        /// window's visible rectangle (window recordings): the bubble starts at its saved spot only if that is inside the
        /// window, else at the window's bottom-left.
        public WebcamBubble(Config cfg, ICaptureBackend backend, List<AvDevice> cameras, AvDevice camera, int px, bool rect, Rectangle homeBounds, Rectangle homeWork, Rectangle? inside = null)
        {
            this.cfg = cfg; this.backend = backend; this.cameras = cameras; this.camera = camera;
            this.px = ClampPx(px);
            this.rect = rect;
            mirror = cfg.Mirror;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            MaximizeBox = MinimizeBox = false;
            StartPosition = FormStartPosition.Manual;
            Text = "Agent Recorder webcam";
            Cursor = Cursors.SizeAll;
            render = Render;
            refeed.Interval = 600;
            refeed.Tick += delegate { refeed.Stop(); if (!closing && (feed == null || feed.Size != Dims)) StartCamera(); };

            dpi = Native.DpiAt(Displays.Center(homeWork));
            var dims = Dims;
            int margin = (int)Math.Round(24 * dpi / 96f);
            var def = new Point(homeWork.Left + margin, homeWork.Bottom - dims.Height - margin);
            Point at = def;
            if (inside.HasValue)
            {
                var w = inside.Value;
                at = new Point(w.Left + margin, w.Bottom - dims.Height - margin);
                if (cfg.BubbleX.HasValue && cfg.BubbleY.HasValue && w.Contains(new Rectangle(new Point(cfg.BubbleX.Value, cfg.BubbleY.Value), dims)))
                    at = new Point(cfg.BubbleX.Value, cfg.BubbleY.Value);
            }
            else if (cfg.BubbleX.HasValue && cfg.BubbleY.HasValue)
            {
                var saved = new Rectangle(new Point(cfg.BubbleX.Value, cfg.BubbleY.Value), dims);
                Display on = Displays.All().Find(d => d.Bounds.Contains(Displays.Center(saved)));
                if (on != null && on.Bounds == homeBounds) at = Displays.KeepInside(saved, homeBounds);
                else if (on != null) at = Displays.Remap(saved.Location, saved.Size, on.Bounds, homeBounds);
            }
            Size = dims;
            Location = at;
            BuildMenu();
            var _ = Handle; // feed callbacks marshal through this handle before the first Show
            int real = Native.DpiForWindow(Handle, Displays.Center(Bounds));
            if (real != dpi) dpi = real;
            Rebuild(Displays.KeepInside(new Rectangle(at, Dims), inside.HasValue ? Rectangle.Intersect(inside.Value, homeBounds) : homeBounds));
        }

        /// Window recordings: when the recorded window moves or resizes, a bubble sitting on it moves along, keeping its
        /// offset from the window's bottom-left corner (where it starts), unless the user is dragging it.
        public void FollowWindow(Rectangle from, Rectangle to)
        {
            if (closing || gesture.Active || !IsHandleCreated) return;
            var b = Bounds;
            if (!from.Contains(Displays.Center(b))) return;
            var p = new Point(to.Left + (b.Left - from.Left), to.Bottom - (from.Bottom - b.Top));
            Location = Displays.KeepInside(new Rectangle(p, b.Size), to);
            E2eRect();
        }

        /// Bubble diameter in physical px for a size at a DPI (even, so the centre stays put when it changes).
        public static int SideFor(int px, int dpi) { return Math.Max(2, (int)Math.Round(px * dpi / 96f / 2) * 2); }

        /// Window size in physical px for a size value at a DPI: the circle's diameter, or a 16:9 rectangle RectHeight of
        /// it high. Even sides keep the centre in place on resize.
        public static Size SizeFor(int px, int dpi, bool rect)
        {
            if (!rect) { int s = SideFor(px, dpi); return new Size(s, s); }
            int h = Math.Max(2, (int)Math.Round(px * RectHeight * dpi / 96f / 2) * 2);
            return new Size(Math.Max(2, (int)Math.Round(h * 16 / 9f / 2) * 2), h);
        }

        Size Dims { get { return SizeFor(px, dpi, rect); } }
        public bool IsRect { get { return rect; } }
        float RingWidth { get { return Math.Max(2f, (float)Math.Round(3 * dpi / 96f)); } }
        public int Px { get { return px; } }
        public bool Mirrored { get { return mirror; } }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x80 /* TOOLWINDOW */ | 0x8 /* TOPMOST */ | 0x08000000 /* NOACTIVATE */ | 0x80000 /* LAYERED */;
                return cp;
            }
        }

        // Layered window: all pixels come from UpdateLayeredWindow, never from WM_PAINT / WM_ERASEBKGND.
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        /// New surface for the current size, positioned at `at`, presented with the last frame (no blank flash).
        void Rebuild(Point at)
        {
            var old = surface;
            surface = new BubbleSurface(Dims, RingWidth, rect);
            surface.Compose(lastFrame, lastSize, mirror);
            surface.Present(Handle, at);
            if (old != null) old.Dispose();
        }

        void Render()
        {
            Interlocked.Exchange(ref renderPending, 0);
            if (closing || surface == null) return;
            if (feed != null && feed.CopyLatest(ref lastFrame, ref lastSize)) stats.Frame();
            surface.Compose(lastFrame, lastSize, mirror);
            surface.Present(Handle, Location);
        }

        /// Redraw rate of the bubble: camera frames presented, the longest wait between two, and how many waits were
        /// longer than two camera frames (each one is a visible stutter in the bubble).
        sealed class RenderStats
        {
            readonly Stopwatch clock = Stopwatch.StartNew();
            long last = -1;
            public int Presented, Late;
            public double MaxGapMs;

            public void Frame()
            {
                long now = clock.ElapsedTicks;
                if (last >= 0)
                {
                    double ms = (now - last) * 1000.0 / Stopwatch.Frequency;
                    if (ms > MaxGapMs) MaxGapMs = ms;
                    if (ms > 67) Late++;
                }
                last = now;
                Presented++;
            }

            public string Report(int cameraFrames)
            {
                var inv = System.Globalization.CultureInfo.InvariantCulture;
                double s = Math.Max(0.001, clock.Elapsed.TotalSeconds);
                return string.Format(inv, "{{\"seconds\":{0:0.00},\"camera_frames\":{1},\"presented\":{2},\"camera_fps\":{3:0.0},\"present_fps\":{4:0.0},\"max_gap_ms\":{5:0.0},\"late\":{6}}}",
                    s, cameraFrames, Presented, cameraFrames / s, Presented / s, MaxGapMs, Late);
            }
        }

        RenderStats stats = new RenderStats();

        void ReportStats()
        {
            if (feed == null) return;
            string r = stats.Report(feed.Frames);
            Log.Write("webcam: redraw " + r);
            E2e.Write("bubble-stats.json", r);
        }

        public void StartCamera()
        {
            if (feed != null) { ReportStats(); feed.Stop(); }
            stats = new RenderStats();
            var f = new CameraFeed(backend, camera, Dims);
            f.Frame += delegate
            {
                if (f != feed || closing) return;
                if (Interlocked.Exchange(ref renderPending, 1) == 0) Post(render);
                if (!everShown) Post(delegate { if (!everShown && !closing && f == feed) { everShown = true; Show(); } });
            };
            f.Failed += delegate (string why)
            {
                if (f != feed) return;
                LastError = why;
                Log.Write("webcam: " + camera.Name + " failed (" + why + "); continuing without the bubble");
                FailedEvent.Set();
                Post(Shutdown);
            };
            feed = f;
            f.Start();
        }

        void Post(Action a) { try { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); } catch { } }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            ShownEvent.Set();
            E2eRect();
        }

        void E2eRect()
        {
            if (!E2e.On) return;
            var d = Dims;
            E2e.Write("bubble-rect.json", string.Format("{{\"x\":{0},\"y\":{1},\"side\":{2},\"w\":{2},\"h\":{3},\"shape\":\"{4}\",\"radius\":{5},\"ring_width\":{6},\"px\":{7},\"mirror\":{8}}}",
                Left, Top, d.Width, d.Height, rect ? "rect" : "circle", (rect ? BubbleSurface.CornerRadius(d.Height) : d.Width / 2f).ToString("0.###", System.Globalization.CultureInfo.InvariantCulture),
                RingWidth, px, mirror ? "true" : "false"));
        }

        /// Stops the camera and closes. Safe to call more than once, before or after the first Show.
        public void Shutdown()
        {
            if (closing) return;
            closing = true;
            refeed.Stop();
            if (strip != null) strip.Close();
            ReportStats();
            if (feed != null) feed.Stop();
            if (Visible) Close(); else Dispose();
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            closing = true;
            if (feed != null) feed.Stop();
            base.OnFormClosed(e);
            Dispose();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_DPICHANGED)
            {
                // Moved onto a monitor with another scale: same logical size, re-centred, camera re-opened at the new size.
                var c = Displays.Center(Bounds);
                dpi = (int)((long)m.WParam & 0xFFFF);
                var d = Dims;
                Rebuild(new Point(c.X - d.Width / 2, c.Y - d.Height / 2));
                refeed.Stop(); refeed.Start();
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }

        /// Live resize from the slider (keeps the centre; the camera is re-opened at the new size once the slider rests).
        public void PreviewPx(int v)
        {
            v = ClampPx(v);
            if (v == px || closing) return;
            px = v;
            Reshape();
        }

        /// New size or shape around the same centre, kept on screen; the camera re-opens at the new size once it rests.
        void Reshape()
        {
            var c = Displays.Center(Bounds);
            var d = Dims;
            Rebuild(Displays.OnScreen(new Rectangle(new Point(c.X - d.Width / 2, c.Y - d.Height / 2), d)));
            refeed.Stop(); refeed.Start();
        }

        /// Circle or 16:9 rounded rectangle; persisted like size and mirror.
        public void SetShape(bool toRect)
        {
            if (toRect == rect || closing) return;
            rect = toRect;
            cfg.Shape = rect ? "rect" : "circle";
            Reshape();
            cfg.BubbleX = Left; cfg.BubbleY = Top;
            cfg.SetPrefs("webcam_shape", cfg.Shape, "bubble_x", Left.ToString(), "bubble_y", Top.ToString());
            Log.Write("webcam: shape " + cfg.Shape);
            if (strip != null && strip.Visible) strip.ShowNear(Bounds);
            E2eRect();
        }

        public void CommitPx()
        {
            cfg.WebcamPx = px;
            cfg.BubbleX = Left; cfg.BubbleY = Top;
            cfg.SetPrefs("webcam_px", px.ToString(), "bubble_x", Left.ToString(), "bubble_y", Top.ToString());
            if (strip != null && strip.Visible) strip.ShowNear(Bounds);
            E2eRect();
        }

        public void SetMirror(bool on)
        {
            if (on == mirror || closing) return;
            mirror = on;
            cfg.Mirror = on;
            cfg.SetPrefs("mirror", on ? "1" : "0");
            Render();
            E2eRect();
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            gesture.Down(Native.MessagePos());
            formStart = Location;
            Capture = true;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!gesture.Active) return;
            bool was = gesture.Dragging;
            if (!gesture.Move(Native.MessagePos())) return;
            if (!was) HideStrip();
            Location = new Point(formStart.X + gesture.Dx, formStart.Y + gesture.Dy);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button == MouseButtons.Right) { ShowMenu(e.Location); return; }
            if (e.Button != MouseButtons.Left || !gesture.Active) return;
            bool click = gesture.Up(Native.MessagePos());
            Capture = false;
            if (gesture.Dragging)
            {
                Location = Displays.OnScreen(new Rectangle(formStart.X + gesture.Dx, formStart.Y + gesture.Dy, Width, Height));
                cfg.BubbleX = Left; cfg.BubbleY = Top;
                cfg.SetPrefs("bubble_x", Left.ToString(), "bubble_y", Top.ToString());
                Log.Write("webcam: bubble moved to " + Left + "," + Top);
                E2eRect();
            }
            else if (click) ToggleStrip();
        }

        void ToggleStrip()
        {
            if (closing) return;
            if (strip != null && strip.Visible) { HideStrip(); return; }
            if (strip == null) strip = new ControlStrip(this);
            strip.ShowNear(Bounds);
            Log.Write("webcam: controls shown");
        }

        void HideStrip()
        {
            if (strip != null && strip.Visible) strip.Hide();
        }

        void SetCamera(AvDevice dev)
        {
            if (dev.Id == camera.Id || closing) return;
            camera = dev;
            cfg.Camera = dev.Name;
            cfg.SetPrefs("camera", dev.Name);
            Log.Write("webcam: switched to " + dev.Name);
            StartCamera();
        }

        void BuildMenu()
        {
            var cams = new ToolStripMenuItem("Camera");
            foreach (var c in cameras)
            {
                var dev = c;
                var it = new ToolStripMenuItem(dev.Name) { Tag = dev.Id };
                it.Click += delegate { SetCamera(dev); };
                cams.DropDownItems.Add(it);
            }
            var mir = new ToolStripMenuItem("Mirror");
            mir.Click += delegate { SetMirror(!mirror); };
            var round = new ToolStripMenuItem("Round");
            round.Click += delegate { SetShape(false); };
            var box = new ToolStripMenuItem("Rectangle");
            box.Click += delegate { SetShape(true); };
            var hide = new ToolStripMenuItem("Hide bubble");
            hide.Click += delegate { Log.Write("webcam: bubble hidden by user"); Shutdown(); };
            menu.Items.AddRange(new ToolStripItem[] { cams, mir, new ToolStripSeparator(), round, box, new ToolStripSeparator(), hide });
            menu.Opening += delegate
            {
                mir.Checked = mirror;
                round.Checked = !rect;
                box.Checked = rect;
                foreach (ToolStripMenuItem it in cams.DropDownItems) it.Checked = (string)it.Tag == camera.Id;
            };
            // The menu is UI chrome, not content: keep it out of the video like the control pill.
            ToolStripDropDown[] drops = { menu, cams.DropDown };
            foreach (var d in drops)
            {
                var dd = d;
                dd.Opened += delegate { Native.ExcludeFromCapture(dd.Handle); };
            }
            // The bubble never activates, so the menu would not see clicks elsewhere. Take the foreground only while
            // the menu is open (the user just right-clicked us) and hand it back when it closes.
            menu.Closed += delegate
            {
                var prev = prevForeground;
                prevForeground = IntPtr.Zero;
                if (prev != IntPtr.Zero) Native.SetForegroundWindow(prev);
            };
        }

        void ShowMenu(Point at)
        {
            if (closing) return;
            HideStrip();
            prevForeground = Native.GetForegroundWindow();
            Native.SetForegroundWindow(Handle);
            menu.Show(this, at);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                closing = true;
                if (feed != null) feed.Stop();
                refeed.Dispose();
                menu.Dispose();
                if (strip != null) strip.Dispose();
                if (surface != null) { surface.Dispose(); surface = null; }
            }
            base.Dispose(disposing);
        }
    }

    /// Geometry of the webcam controls at one DPI, in physical px (client coordinates): row 1 is the size slider and its
    /// value, row 2 the "Mirror" label and toggle, row 3 the "Shape" label and a two-segment circle / rectangle switch.
    /// Every rectangle is a 96-dpi design rectangle with each edge scaled and rounded on its own, so rows and columns
    /// that do not touch at 100 % never touch at any scale. Pure (no OS calls), covered by the selftest, shared by the
    /// window and --controls-shots.
    class ControlLayout
    {
        public const int W = 232, H = 118;
        public const float FontPx = 12f;
        public const string MirrorText = "Mirror", ShapeText = "Shape";
        public readonly int Dpi;
        public readonly float Scale;
        public readonly Size Size;
        public readonly Rectangle Track, TrackHit, Value, MirrorLabel, Toggle, MirrorHit, Divider;
        public readonly Rectangle Divider2, ShapeLabel, ShapeSwitch, CircleSeg, RectSeg, ShapeHit;
        public readonly int ThumbR, Corner, Gap;

        public ControlLayout(int dpi)
        {
            Dpi = dpi > 0 ? dpi : 96;
            Scale = Dpi / 96f;
            Size = new Size(S(W), S(H));
            Track = R(16, 20, 140, 4);       // row 1, centred on y 22
            TrackHit = R(8, 6, 160, 32);
            Value = R(170, 12, 48, 20);
            Divider = R(14, 40, W - 28, 1);
            MirrorLabel = R(16, 48, 150, 20);  // row 2, centred on y 58
            Toggle = R(W - 14 - 34, 49, 34, 18);
            MirrorHit = R(8, 42, W - 16, 34);
            Divider2 = R(14, 78, W - 28, 1);
            ShapeLabel = R(16, 87, 120, 20);   // row 3, centred on y 97
            ShapeSwitch = R(W - 14 - 64, 86, 64, 22);
            CircleSeg = R(W - 14 - 64, 86, 32, 22);
            RectSeg = R(W - 14 - 32, 86, 32, 22);
            ShapeHit = R(8, 80, W - 16, 34);
            ThumbR = S(7);
            Corner = S(14);
            Gap = S(10);
        }

        int S(float v) { return (int)Math.Round(v * Scale); }
        Rectangle R(int x, int y, int w, int h) { return Rectangle.FromLTRB(S(x), S(y), S(x + w), S(y + h)); }

        public float FontSize { get { return FontPx * Scale; } }

        public int ThumbX(int px)
        {
            px = WebcamBubble.ClampPx(px);
            return Track.Left + (int)Math.Round((px - WebcamBubble.MinPx) * (double)Track.Width / (WebcamBubble.MaxPx - WebcamBubble.MinPx));
        }

        public Rectangle Thumb(int px)
        {
            int cy = Track.Top + Track.Height / 2;
            return new Rectangle(ThumbX(px) - ThumbR, cy - ThumbR, 2 * ThumbR, 2 * ThumbR);
        }

        public int ValueAt(int x)
        {
            return WebcamBubble.ClampPx(WebcamBubble.MinPx + (int)Math.Round((x - Track.Left) * (double)(WebcamBubble.MaxPx - WebcamBubble.MinPx) / Track.Width));
        }

        public static string ValueText(int px) { return px + " px"; }

        /// Where the controls go: beside the bubble (right, else left), else below, else above, slid along that side to
        /// stay fully inside the work area of the bubble's monitor and at least `Gap` away from the bubble. When the bubble
        /// leaves no room on any side, the controls still stay fully inside the work area (over the bubble).
        public Point Place(Rectangle bubble, Rectangle work)
        {
            var c = Displays.Center(bubble);
            Point[] tries =
            {
                new Point(bubble.Right + Gap, c.Y - Size.Height / 2),
                new Point(bubble.Left - Gap - Size.Width, c.Y - Size.Height / 2),
                new Point(c.X - Size.Width / 2, bubble.Bottom + Gap),
                new Point(c.X - Size.Width / 2, bubble.Top - Gap - Size.Height),
            };
            var keepOff = Rectangle.Inflate(bubble, Gap, Gap);
            foreach (var p in tries)
            {
                var at = Displays.KeepInside(new Rectangle(p, Size), work);
                if (!new Rectangle(at, Size).IntersectsWith(keepOff)) return at;
            }
            return Displays.KeepInside(new Rectangle(tries[0], Size), work);
        }

        public static readonly Color Bg = Color.FromArgb(24, 24, 27), Accent = Color.FromArgb(59, 130, 246);

        /// Shape for a press in row 3: the segment under it, or the other shape for a press on the label (toggle).
        public bool ShapeFor(Point p, bool current)
        {
            if (CircleSeg.Contains(p)) return false;
            if (RectSeg.Contains(p)) return true;
            return !current;
        }

        /// Paints the controls (background excluded: the window's BackColor / the caller fills it).
        public void Draw(Graphics g, Font font, int value, bool mirror, bool rect)
        {
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            // Pixel-aligned rectangles crisp (anti-aliasing would bleed them half a pixel into the next row), curves smooth.
            g.SmoothingMode = SmoothingMode.None;
            var t = Track;
            int tx = ThumbX(value);
            using (var b = new SolidBrush(Color.FromArgb(63, 63, 70))) g.FillRectangle(b, t);
            using (var b = new SolidBrush(Accent)) g.FillRectangle(b, t.Left, t.Top, tx - t.Left, t.Height);
            using (var b = new SolidBrush(Color.FromArgb(39, 39, 42))) { g.FillRectangle(b, Divider); g.FillRectangle(b, Divider2); }
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.FillEllipse(Brushes.White, Thumb(value));
            using (var fmt = new StringFormat(StringFormatFlags.NoWrap) { LineAlignment = StringAlignment.Center, Trimming = StringTrimming.None })
            {
                using (var b = new SolidBrush(Color.FromArgb(161, 161, 170))) g.DrawString(ValueText(value), font, b, Value, fmt);
                using (var b = new SolidBrush(Color.FromArgb(228, 228, 231))) { g.DrawString(MirrorText, font, b, MirrorLabel, fmt); g.DrawString(ShapeText, font, b, ShapeLabel, fmt); }
            }
            // Shape switch: two segments, the chosen one filled; icons = a circle and a 16:9 rounded rectangle.
            int sr = (int)Math.Round(6 * Scale);
            using (var path = PillLayout.RoundRect(ShapeSwitch, sr * 2))
            using (var b = new SolidBrush(Color.FromArgb(63, 63, 70)))
                g.FillPath(b, path);
            using (var path = PillLayout.RoundRect(rect ? RectSeg : CircleSeg, sr * 2))
            using (var b = new SolidBrush(Accent))
                g.FillPath(b, path);
            using (var on = new SolidBrush(Color.White))
            using (var off = new SolidBrush(Color.FromArgb(161, 161, 170)))
            {
                int d = (int)Math.Round(11 * Scale);
                var cc = new Point(CircleSeg.X + CircleSeg.Width / 2, CircleSeg.Y + CircleSeg.Height / 2);
                g.FillEllipse(rect ? off : on, cc.X - d / 2, cc.Y - d / 2, d, d);
                int rw = (int)Math.Round(16 * Scale), rh = (int)Math.Round(9 * Scale);
                var rc = new Point(RectSeg.X + RectSeg.Width / 2, RectSeg.Y + RectSeg.Height / 2);
                using (var path = PillLayout.RoundRect(new Rectangle(rc.X - rw / 2, rc.Y - rh / 2, rw, rh), Math.Max(2, (int)Math.Round(4 * Scale))))
                    g.FillPath(rect ? on : off, path);
            }
            var tg = Toggle;
            using (var path = new GraphicsPath())
            {
                path.AddArc(tg.X, tg.Y, tg.Height, tg.Height, 90, 180);
                path.AddArc(tg.Right - tg.Height, tg.Y, tg.Height, tg.Height, 270, 180);
                path.CloseFigure();
                using (var b = new SolidBrush(mirror ? Accent : Color.FromArgb(82, 82, 91))) g.FillPath(b, path);
            }
            int k = tg.Height - (int)Math.Round(4 * Scale), m = (int)Math.Round(2 * Scale);
            g.FillEllipse(Brushes.White, mirror ? tg.Right - m - k : tg.X + m, tg.Y + m, k, k);
        }

        /// Offscreen render with the window's rounded shape (transparent outside), for review and the selftest.
        public Bitmap Render(int value, bool mirror, bool rect = false)
        {
            var bmp = new Bitmap(Size.Width, Size.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            using (var font = new Font("Segoe UI", FontSize, GraphicsUnit.Pixel))
            using (var path = new GraphicsPath())
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                int d = Corner;
                path.AddArc(0, 0, d, d, 180, 90);
                path.AddArc(Size.Width - d, 0, d, d, 270, 90);
                path.AddArc(Size.Width - d, Size.Height - d, d, d, 0, 90);
                path.AddArc(0, Size.Height - d, d, d, 90, 90);
                path.CloseFigure();
                using (var b = new SolidBrush(Bg)) g.FillPath(b, path);
                Draw(g, font, value, mirror, rect);
            }
            return bmp;
        }
    }

    /// Size slider, mirror toggle and shape switch shown next to the bubble after a click. Its own small window, excluded from capture,
    /// so the controls never appear in the video. Like the bubble and the pill it never takes focus (the user's app keeps
    /// the keyboard, and Windows' foreground lock cannot get in the way); instead, while open, it polls the mouse buttons
    /// and hides on a press anywhere outside itself and the bubble, or when the foreground window changes.
    class ControlStrip : Form
    {
        readonly WebcamBubble owner;
        readonly System.Windows.Forms.Timer watch = new System.Windows.Forms.Timer();
        Font font;
        ControlLayout layout;
        int value;
        bool mirror, rect, sliding, buttonWasDown;
        IntPtr foregroundAtOpen;
        public string CaptureMode = "none";

        public ControlStrip(WebcamBubble owner)
        {
            this.owner = owner;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = ControlLayout.Bg;
            Text = "Agent Recorder webcam controls";
            DoubleBuffered = true;
            SetScale(96);
            watch.Interval = 50;
            watch.Tick += delegate { Watch(); };
        }

        /// Click-away detection without focus: a new press outside the strip and the bubble, or another window coming to
        /// the foreground (Alt+Tab, taskbar), closes the strip.
        void Watch()
        {
            if (!Visible) { watch.Stop(); return; }
            bool down = Native.AnyMouseButtonDown();
            if (down && !buttonWasDown && !sliding)
            {
                var p = Cursor.Position;
                if (!Bounds.Contains(p) && !owner.Bounds.Contains(p)) { Hide(); return; }
            }
            buttonWasDown = down;
            if (Native.GetForegroundWindow() != foregroundAtOpen && !sliding) Hide();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (!Visible)
            {
                watch.Stop();
                if (sliding) { sliding = false; Capture = false; owner.CommitPx(); }
            }
        }

        /// Sizes the window, its rounded shape and the font for a DPI (no-op when already at that DPI).
        void SetScale(int dpi)
        {
            if (layout != null && layout.Dpi == dpi) return;
            layout = new ControlLayout(dpi);
            Size = layout.Size;
            var old = Region;
            Region = Region.FromHrgn(Native.CreateRoundRectRgn(0, 0, Width + 1, Height + 1, layout.Corner, layout.Corner));
            if (old != null) old.Dispose();
            if (font != null) font.Dispose();
            font = new Font("Segoe UI", layout.FontSize, GraphicsUnit.Pixel);
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x80 /* TOOLWINDOW */ | 0x8 /* TOPMOST */ | 0x08000000 /* NOACTIVATE */;
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            CaptureMode = Native.ExcludeFromCapture(Handle);
        }

        /// Sizes the strip for the DPI of the bubble's monitor, places it beside the bubble fully inside that monitor's
        /// work area (ControlLayout.Place) and shows it.
        public void ShowNear(Rectangle bubble)
        {
            value = owner.Px;
            mirror = owner.Mirrored;
            rect = owner.IsRect;
            Place(bubble, true);
            Invalidate();
            if (!Visible)
            {
                foregroundAtOpen = Native.GetForegroundWindow();
                buttonWasDown = Native.AnyMouseButtonDown();
                Show();
                watch.Start();
            }
            if (E2e.On)
            {
                E2e.Snapshot(this, "controls.png");
                E2e.Write("controls-rect.json", string.Format("{{\"x\":{0},\"y\":{1},\"w\":{2},\"h\":{3},\"capture_excluded\":{4},\"capture_mode\":\"{5}\"}}",
                    Left, Top, Width, Height, CaptureMode == "exclude" ? "true" : "false", CaptureMode));
            }
        }

        /// Monitor = the one holding the bubble's centre (else the nearest); DPI = that monitor's, so the strip, placed
        /// fully inside it, gets no further WM_DPICHANGED. rescale = false keeps the current size (DPI-change re-place).
        void Place(Rectangle bubble, bool rescale)
        {
            Display mon = Displays.Nearest(Displays.All(), Displays.Center(bubble));
            Rectangle wa = mon != null ? mon.WorkArea : bubble;
            if (rescale || layout == null) SetScale(Native.DpiAt(Displays.Center(mon != null ? mon.Bounds : bubble)));
            Location = layout.Place(bubble, wa);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_DPICHANGED)
            {
                // Scale changed under the open strip (display settings) or it straddled monitors: resize, then re-place
                // so the new size still fits the work area beside the bubble.
                int dpi = (int)((long)m.WParam & 0xFFFF);
                if (layout == null || dpi != layout.Dpi)
                {
                    SetScale(dpi);
                    if (Visible && !sliding) Place(owner.Bounds, false);
                    Invalidate();
                }
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            layout.Draw(e.Graphics, font, value, mirror, rect);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            if (layout.TrackHit.Contains(e.Location)) { sliding = true; Capture = true; SetFromX(e.X); return; }
            if (layout.MirrorHit.Contains(e.Location))
            {
                mirror = !mirror;
                Invalidate();
                owner.SetMirror(mirror);
                return;
            }
            if (layout.ShapeHit.Contains(e.Location))
            {
                bool want = layout.ShapeFor(e.Location, rect);
                if (want == rect) return;
                rect = want;
                Invalidate();
                owner.SetShape(rect); // resizes the bubble and re-places this strip beside it
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (sliding) SetFromX(e.X);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (!sliding) return;
            sliding = false;
            Capture = false;
            owner.CommitPx();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            value = WebcamBubble.ClampPx(value + (e.Delta > 0 ? 10 : -10));
            Invalidate();
            owner.PreviewPx(value);
            owner.CommitPx();
        }

        void SetFromX(int x)
        {
            int v = layout.ValueAt(x);
            if (v == value) return;
            value = v;
            Invalidate();
            owner.PreviewPx(v);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                watch.Dispose();
                if (font != null) font.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    // ---------------------------------------------------------------- recording

    /// What the recorder needs from its host: the agent (server commands, upload) or the local dev CLI (--record-local).
    interface IRecorderHost
    {
        Config Cfg { get; }
        ICaptureBackend Capture { get; }
        IDeviceCatalog Catalog { get; }
        string WorkDir { get; }
        void SendStatus(string id, string status, string error);
        /// Hands over the finished files: upload to the server, or keep them (dev CLI). hasTranscript: the transcription WAV
        /// `audio` was made (a mic was recorded); without it there is no WAV to send.
        void Deliver(string id, string video, string audio, bool hasTranscript, bool hasSystemAudio, string token, double duration, long partBytes);
    }

    /// Follows a recorded window while ffmpeg runs (polls every 100 ms, only during window recordings): live crop
    /// updates for moves and resizes, black while minimized, a monitor switch once the window has been mostly on another
    /// monitor for 0.6 s, and a stop once it has been closed for 1 s. Commands are paced to ffmpeg's ~100 ms per command,
    /// always sending the latest state, so a long drag never builds a backlog.
    class WindowFollower
    {
        readonly IRecorderHost host;
        readonly WindowInfo win;
        readonly List<MonitorInfo> monitors;
        readonly object gate = new object();
        Process proc;
        MonitorInfo mon;
        WindowView sent;
        DateTime busyUntil, otherSince, goneSince;
        MonitorInfo other;
        Rectangle lastBounds;
        volatile bool stopped;
        public event Action<MonitorInfo> MonitorChanged;
        public event Action Closed;
        public event Action<Rectangle, Rectangle> Moved;

        public WindowFollower(IRecorderHost host, WindowInfo win, List<MonitorInfo> monitors)
        {
            this.host = host; this.win = win; this.monitors = monitors;
            lastBounds = win.Bounds;
        }

        public void Attach(Process p, MonitorInfo m, WindowView view)
        {
            lock (gate) { proc = p; mon = m; sent = view; busyUntil = DateTime.MinValue; other = null; }
        }

        public void Detach() { lock (gate) proc = null; }

        public void Start()
        {
            var t = new Thread(Loop);
            t.IsBackground = true;
            t.Name = "window follower";
            t.Start();
        }

        public void Stop() { stopped = true; Detach(); }

        /// The window's view on monitor m right now (used to start the next segment after a monitor switch).
        public WindowView ViewOn(MonitorInfo m)
        {
            var s = host.Catalog.Probe(win);
            return WindowTrack.View(s.Bounds, s.Minimized, s.Alive, m.Bounds, new WindowView { Crop = new Rectangle(0, 0, m.Bounds.Width, m.Bounds.Height) });
        }

        void Loop()
        {
            while (!stopped)
            {
                Thread.Sleep(100);
                try { Tick(); }
                catch (Exception e) { Log.Write("window follower: " + e.Message); }
            }
        }

        void Tick()
        {
            Process p;
            MonitorInfo m;
            WindowView last;
            lock (gate) { p = proc; m = mon; last = sent; }
            if (p == null) return;
            var now = DateTime.UtcNow;
            var s = host.Catalog.Probe(win);
            if (!s.Alive)
            {
                if (goneSince == DateTime.MinValue) goneSince = now;
                else if ((now - goneSince).TotalMilliseconds > 1000) { Log.Write("window: closed; stopping"); stopped = true; Fire(Closed); return; }
            }
            else goneSince = DateTime.MinValue;
            if (s.Alive && !s.Minimized && s.Bounds != lastBounds)
            {
                var from = lastBounds;
                lastBounds = s.Bounds;
                var moved = Moved;
                if (moved != null) moved(from, s.Bounds);
            }
            if (s.Alive && !s.Minimized)
            {
                var on = WindowTrack.MostlyOn(monitors, s.Bounds);
                if (on != null && on != m && WindowTrack.Share(s.Bounds, m.Bounds) < 0.5)
                {
                    if (other != on) { other = on; otherSince = now; }
                    else if ((now - otherSince).TotalMilliseconds >= 600)
                    {
                        Detach();
                        var h = MonitorChanged;
                        if (h != null) h(on);
                        return;
                    }
                }
                else other = null;
            }
            if (now < busyUntil) return;
            var view = WindowTrack.View(s.Bounds, s.Minimized, s.Alive, m.Bounds, last);
            var cmds = WindowTrack.Commands(last, view);
            if (cmds.Count == 0) return;
            lock (gate) { if (proc != p) return; sent = view; }
            host.Capture.SendCommands(p, cmds);
            busyUntil = now.AddMilliseconds(110 * cmds.Count);
            if (view.Blank != last.Blank) Log.Write("window: " + (view.Blank ? "hidden (minimized, closed or off the monitor): video is black" : "visible again"));
        }

        static void Fire(Action a) { if (a != null) a(); }
    }

    /// One idle ffmpeg kept resident while the agent is online and idle (ICaptureBackend.StartWarm), so a start command
    /// launches the screen (and mic) ffmpeg with its image and DLLs already mapped instead of loading them cold. It holds
    /// no device and writes nothing: the mic is never opened while idle (that would show the mic-in-use indicator).
    /// Paused from the start command, released once the capture is up, and back after the recording. Thread-safe.
    sealed class WarmKeeper
    {
        public interface IHandle : IDisposable { bool Alive { get; } }

        readonly Func<IHandle> spawn;
        readonly object gate = new object();
        IHandle held;
        bool wanted, paused, closed;

        public WarmKeeper(Func<IHandle> spawn) { this.spawn = spawn; }

        public bool Holding { get { lock (gate) return held != null; } }

        /// The agent is online and idle: keep one from now on (a dead one is replaced).
        public void Want() { lock (gate) wanted = true; Fill(); }

        /// A recording is starting: none is spawned until Resume.
        public void Pause() { lock (gate) paused = true; }

        /// The warm one goes (its stdin closes and it exits).
        public void Release()
        {
            IHandle h;
            lock (gate) { h = held; held = null; }
            if (h != null) try { h.Dispose(); } catch { }
        }

        /// The recording is over (Fill then starts a new one if still wanted).
        public void Resume() { lock (gate) paused = false; }

        /// For good (the agent stops working: no longer paired, exiting).
        public void Close()
        {
            lock (gate) { closed = true; wanted = false; }
            Release();
        }

        /// One warm ffmpeg when wanted, not paused and not closed (a dead one is replaced).
        public void Fill()
        {
            IHandle dead = null;
            lock (gate)
            {
                if (!wanted || paused || closed) return;
                if (held != null && held.Alive) return;
                dead = held;
                held = null;
                try { held = spawn(); }
                catch (Exception e) { wanted = false; Log.Write("warm: ffmpeg not kept ready (" + e.Message + ")"); }
            }
            if (dead != null) try { dead.Dispose(); } catch { }
        }
    }

    /// Start path of one recording, in ms after the start command: pill on screen, encoder known, screen ffmpeg launched,
    /// its first encoded frame (ffmpeg's -progress frame count), capture declared started ("recording" sent), webcam
    /// bubble on screen. Logged once as one "start timing" line when the first frame, the start and the bubble (if one was
    /// asked for) are all settled, or when the recording ends; a missing step is "-".
    class StartTimes
    {
        public static readonly string[] Names = { "t_cmd", "t_pill", "t_encoder", "t_ffmpeg_launch", "t_first_frame", "t_started", "t_bubble" };
        readonly object gate = new object();
        readonly double[] at = new double[Names.Length];
        bool bubbleOpen, logged;
        /// Fired once, right after the line is logged.
        public event Action<StartTimes> Logged;

        public StartTimes(double cmd)
        {
            for (int i = 0; i < at.Length; i++) at[i] = double.NaN;
            at[0] = cmd;
        }

        /// A bubble was asked for: the line waits for it (Mark("t_bubble") or BubbleSettled).
        public void ExpectBubble() { lock (gate) bubbleOpen = true; }

        /// First time only; later marks of the same step (a fallback, a new segment) are ignored.
        public void Mark(string name)
        {
            double now = Clock.Now();
            lock (gate)
            {
                int i = Array.IndexOf(Names, name);
                if (double.IsNaN(at[i])) at[i] = now;
                if (name == "t_bubble") bubbleOpen = false;
            }
            TryLog();
        }

        /// The bubble failed or was abandoned: t_bubble stays "-".
        public void BubbleSettled() { lock (gate) bubbleOpen = false; TryLog(); }

        /// ms after the command, NaN when the step was not reached.
        public double Ms(string name) { lock (gate) return (at[Array.IndexOf(Names, name)] - at[0]) * 1000; }

        public string Line()
        {
            var sb = new StringBuilder();
            lock (gate)
                for (int i = 0; i < at.Length; i++)
                    sb.Append(i > 0 ? " " : "").Append(Names[i]).Append('=').Append(double.IsNaN(at[i]) ? "-" : ((long)Math.Round((at[i] - at[0]) * 1000)).ToString());
            return sb.ToString();
        }

        /// Logs whatever was reached (the recording ended or failed first).
        public void Flush() { TryLog(true); }

        void TryLog(bool force = false)
        {
            lock (gate)
            {
                if (logged) return;
                if (!force && (bubbleOpen || double.IsNaN(at[Array.IndexOf(Names, "t_first_frame")]) || double.IsNaN(at[Array.IndexOf(Names, "t_started")]))) return;
                logged = true;
            }
            Log.Write("start timing (ms after the start command): " + Line());
            var h = Logged;
            if (h != null) h(this);
        }
    }

    /// One recording at a time: control pill first, then ffmpeg, then streamed upload. A window recording that moves to another
    /// monitor continues in a new segment there; segments are joined without re-encoding before the upload.
    class Recorder
    {
        readonly IRecorderHost agent;
        readonly object gate = new object();
        Process ff, micProc;
        ControlPill pill;
        WebcamBubble bubble;
        string currentId;
        /// The GPU's abilities for the current recording's encoder (ICaptureBackend.ProbeGpu, cached there).
        GpuCaps gpu;
        /// Video paths that failed to start, per source size and encoder ("gpu 2560x1440 h264_nvenc"): not tried again.
        readonly HashSet<string> failedPaths = new HashSet<string>();
        /// Bumped by CloseBubble: a bubble still opening for an earlier recording closes itself instead of showing.
        int bubbleGen;
        bool stopRequested;
        MonitorInfo switchTo;
        LoopbackCapture sys;
        MuteLog micMutes;
        /// Fired once the first capture segment is running (the dev CLI times its scripted toggles from here).
        public event Action Recording;
        /// Fired once a recording is over: uploaded (or failed), its files gone and Busy false again. The agent runs a
        /// deferred update from here (SelfUpdater.RunDeferred).
        public event Action Finished;
        /// Fired when a recording's "start timing" line is logged (the start-latency test reads it).
        public event Action<StartTimes> Timed;

        readonly WarmKeeper keeper;

        public Recorder(IRecorderHost host)
        {
            agent = host;
            keeper = new WarmKeeper(delegate { return agent.Capture.StartWarm(); });
        }

        /// The one-time probes a start would otherwise wait for (~1 s each): the encoder (unless pinned) and what the GPU
        /// does with that encoder. Both are cached in the backend and probed again only when the display adapters change.
        public static void Warm(ICaptureBackend capture, string pinnedEncoder)
        {
            bool auto = pinnedEncoder == null || pinnedEncoder == "auto";
            capture.ProbeGpu(auto ? capture.ProbeEncoder(false) : pinnedEncoder);
        }

        /// After Warm, while online and idle: an idle ffmpeg stays resident between recordings (WarmKeeper).
        public void KeepWarm() { keeper.Want(); }

        /// No more recordings are coming (no longer paired): the warm ffmpeg goes and is not replaced.
        public void Cool() { keeper.Close(); }

        public bool Busy { get { lock (gate) return currentId != null; } }
        public string CurrentId { get { lock (gate) return currentId; } }

        /// Per-recording webcam choice: null camera / 0 px fall back to the device config.
        public class WebcamOpts
        {
            public bool On;
            public string Camera;
            public int Px;
            /// Percent of the monitor's short side (start_recording webcam_size as a number); 0 = use Px / the config.
            public int Pct;
            /// "circle" / "rect"; null = the shape last chosen on the PC.
            public string Shape;
        }

        /// What to record. Monitor/mic/camera are ids or names from the inventory; anything not in the inventory is
        /// logged and replaced by the default, and only inventory entries ever reach ffmpeg.
        public class StartOpts
        {
            public bool Mic;
            /// Record the default output device (WASAPI loopback). The pill can mute either source mid-recording.
            public bool SystemAudio;
            /// Window: an id (or words) resolved against this PC's live window list only; never a whole monitor instead.
            public string MicDevice, Monitor, Window;
            public WebcamOpts Cam = new WebcamOpts();
            /// The start command's upload_part_bytes: files larger than this go up in parts (Uploader); 0 = one PUT each.
            public long PartBytes;
        }

        /// Longest recording any account may ask for: 4 h, the recorder's own ceiling (Pro "no time limit"). The start
        /// command's max_seconds still governs; the Worker holds each account to its own limit (Free 300 s).
        public const int MaxSeconds = 14400;

        /// The start command's max_seconds clamped to 1..MaxSeconds: a shorter limit from the server always wins.
        public static int ClampSeconds(int maxSeconds) { return Math.Max(1, Math.Min(MaxSeconds, maxSeconds)); }

        /// The video's ffmpeg -fs cap. One PUT takes 80 MiB (82 MB here, less room for the AAC track). With the chunked
        /// upload, recordings over the free 120 s may be long ones: up to 8 GiB (4 h at MaxSeconds). A free account (120 s at
        /// most) keeps the single-PUT cap even when it uploads in parts, since the Worker holds it to 80 MiB of video.
        public static long VideoCap(long partBytes, int maxSeconds, bool hasAudio)
        {
            long audio = hasAudio ? 17500L * maxSeconds : 0; // AAC 128 kb/s (16 KB/s) plus container overhead
            return (partBytes > 0 && maxSeconds > 120 ? 8L * 1024 * 1024 * 1024 : 82000000) - audio;
        }

        /// received = when the start command arrived (Clock.Now), the zero of the start timing; NaN = now.
        public void Start(string id, int maxSeconds, StartOpts o, string uploadToken, double received = double.NaN)
        {
            var times = new StartTimes(double.IsNaN(received) ? Clock.Now() : received);
            lock (gate)
            {
                if (currentId != null) { agent.SendStatus(id, "failed", "BUSY"); return; }
                currentId = id;
                keeper.Pause();
            }
            times.Logged += delegate (StartTimes x) { var h = Timed; if (h != null) h(x); };
            var t = new Thread(delegate () { Run(id, ClampSeconds(maxSeconds), o, uploadToken, times); });
            t.IsBackground = true;
            t.Start();
        }

        public void Stop(string id)
        {
            Process p;
            lock (gate) { if (id != currentId) return; stopRequested = true; p = ff; }
            StopProcess(p);
        }

        /// Ends the current segment so Run continues on another monitor (unless a stop is already under way).
        void SwitchMonitor(MonitorInfo m)
        {
            Process p;
            lock (gate) { if (stopRequested || currentId == null) return; switchTo = m; p = ff; }
            ThreadPool.QueueUserWorkItem(delegate { StopProcess(p); });
        }

        /// A toggle on the pill (or Toggle below): mute/unmute one source without stopping. System audio is zeroed by the
        /// capture itself from this instant; the mic is silenced live in ffmpeg (volume@mic) and its spans again exactly
        /// when the audio is mixed.
        void SetMute(string source, bool muted)
        {
            double now = Clock.Now();
            LoopbackCapture s;
            MuteLog m;
            Process p;
            lock (gate) { s = sys; m = micMutes; p = micProc; }
            if (source == PillLayout.Sys) { if (s != null) s.SetMuted(muted); return; }
            if (m == null || !m.Set(muted, now)) return;
            var cmd = new List<string> { "volume@mic -1 volume " + (muted ? "0" : "1") };
            ThreadPool.QueueUserWorkItem(delegate { agent.Capture.SendCommands(p, cmd); });
        }

        /// Presses a pill toggle through the pill itself (same code path as a click). Used by --record-local --toggle.
        public void Toggle(string source)
        {
            ControlPill f;
            lock (gate) f = pill;
            if (f != null) try { f.BeginInvoke(new Action(delegate { f.Toggle(source); })); } catch { }
        }

        void SetPillSources(bool mic, bool system)
        {
            ControlPill f;
            lock (gate) f = pill;
            if (f != null) try { f.Invoke(new Action(delegate { f.SetSources(mic, system); })); } catch { }
        }

        static LoopbackCapture StartSystemAudio(string path)
        {
            try
            {
                var c = new LoopbackCapture(path);
                c.Start();
                return c;
            }
            catch (Exception e) { Log.Write("system audio: not recorded (" + e.Message + ")"); return null; }
        }

        static void StopProcess(Process p)
        {
            if (p == null) return;
            try
            {
                lock (p)
                {
                    if (p.HasExited) return;
                    p.StandardInput.Write("q");
                    p.StandardInput.Flush();
                }
                if (!p.WaitForExit(8000)) p.Kill();
            }
            catch (Exception e) { Log.Write("stop: " + e.Message); }
        }

        void Run(string id, int maxSeconds, StartOpts o, string uploadToken, StartTimes times)
        {
            string dir = agent.WorkDir;
            Directory.CreateDirectory(dir);
            string video = Path.Combine(dir, id + ".mp4"), audio = Path.Combine(dir, id + ".wav");
            var temps = new List<string>();
            WindowFollower follower = null;
            LoopbackCapture system = null;
            Process micP = null;
            System.Threading.Tasks.Task audioUp = null;
            try
            {
                var monitors = agent.Catalog.Monitors();
                WindowInfo win = null;
                MonitorInfo mon;
                if (o.Window != null)
                {
                    // Only a window from this PC's own live list is recorded (found again by its handle). If it is gone,
                    // fail instead of recording a whole monitor the user did not ask for.
                    win = DeviceMatch.Window(agent.Catalog.Windows(monitors), o.Window);
                    if (win == null) throw new Exception("WINDOW_NOT_FOUND");
                    Log.Write("window " + win.Id + " (" + win.App + "): " + agent.Catalog.BringToFront(win));
                    var st = agent.Catalog.Probe(win);
                    if (!st.Alive) throw new Exception("WINDOW_NOT_FOUND");
                    win.Bounds = st.Bounds;
                    mon = WindowTrack.MostlyOn(monitors, win.Bounds);
                    if (mon == null) throw new Exception("WINDOW_OFF_SCREEN");
                }
                else
                {
                    mon = DeviceMatch.Monitor(monitors, o.Monitor);
                    if (mon == null)
                    {
                        mon = DeviceMatch.Monitor(monitors, "primary");
                        Log.Write("monitor \"" + o.Monitor + "\" is not in the inventory; recording the primary");
                    }
                    if (mon == null) throw new Exception("NO_MONITOR");
                }
                ShowPill(mon, monitors);
                Log.Write("pill shown");
                times.Mark("t_pill");
                string encoder = agent.Capture.PickEncoder(agent.Cfg.Encoder);
                times.Mark("t_encoder");
                // Nothing else runs on this thread between the encoder and the screen's launch: the GPU probe (cached since
                // agent start, Warm), the device list, the bubble, system audio and the mic all start beside it.
                var gpuProbe = System.Threading.Tasks.Task.Factory.StartNew(() => agent.Capture.ProbeGpu(encoder));
                var avLookup = o.Mic || o.Cam.On ? System.Threading.Tasks.Task.Factory.StartNew(() => agent.Catalog.CachedAudioVideo()) : null;
                // The camera takes 1-2 s to open, so it opens on its own thread and the screen capture does not wait: the
                // bubble is in the video from the moment it appears. It is optional: any camera problem is logged and the
                // recording goes on without it.
                if (o.Cam.On)
                {
                    times.ExpectBubble();
                    StartBubble(delegate { return avLookup.Result.Cameras; }, o.Cam, mon, win == null ? (Rectangle?)null : Rectangle.Intersect(win.Bounds, mon.Bounds), times);
                }
                string sysWav = Path.Combine(dir, id + ".sys.wav"), micWav = Path.Combine(dir, id + ".mic.wav");
                if (o.SystemAudio) temps.Add(sysWav);
                if (o.Mic) temps.Add(micWav);
                var mutes = new MuteLog();
                var micProgress = new FfProgress();
                double micLaunched = Clock.Now();
                AvDevice mic = null;
                // System audio and the mic start on their own thread, launched together with the screen capture. Loopback
                // is up within ~0.1 s, well before the screen's first frame (~0.35 s after its launch); when it is not, the
                // mix delays it (loopback may deliver nothing until something plays anyway). The mic runs in its own
                // ffmpeg (see StartScreen) for the whole recording; a mic can take ~1 s to deliver its first packet, and the
                // mix cuts the video's head off up to the mic's first sample (AudioMath.StartTrim). Checked once the screen
                // is up. Run waits for this before it uses system, mic or micP.
                if (o.SystemAudio || o.Mic) audioUp = System.Threading.Tasks.Task.Factory.StartNew(() =>
                {
                    if (o.SystemAudio) system = StartSystemAudio(sysWav);
                    if (o.Mic)
                    {
                        try
                        {
                            var av = avLookup.Result;
                            if (o.MicDevice != null)
                            {
                                mic = DeviceMatch.Av(av.Mics, o.MicDevice);
                                if (mic == null) Log.Write("mic \"" + o.MicDevice + "\" is not in the inventory; using the default");
                            }
                            if (mic == null) mic = av.Mics.Find(m => m.IsDefault) ?? (av.Mics.Count > 0 ? av.Mics[0] : null);
                            if (mic == null) Log.Write("mic requested but no dshow audio device found");
                            micLaunched = Clock.Now();
                            if (mic != null) micP = agent.Capture.StartMic(mic, micWav, false, maxSeconds + 30, micProgress);
                        }
                        catch (Exception e) { mic = null; micP = null; Log.Write("mic: not recorded (" + e.GetBaseException().Message + ")"); }
                    }
                    lock (gate) { sys = system; micMutes = micP != null ? mutes : null; micProc = micP; }
                    SetPillSources(micP != null, system != null);
                }, System.Threading.Tasks.TaskCreationOptions.LongRunning);
                Action audioJoin = delegate { JoinAudio(audioUp); };
                try { gpu = gpuProbe.Result; }
                catch (Exception e) { gpu = new GpuCaps(); Log.Write("gpu probe failed (" + e.GetBaseException().Message + "); cpu video path"); }
                var spec = new CaptureSpec { Fps = agent.Cfg.Fps, Encoder = encoder };
                if (win != null)
                {
                    var view = WindowTrack.View(win.Bounds, false, true, mon.Bounds, new WindowView());
                    // Even size: a window that fits 1920x1080 is then recorded 1:1 (no pad, no resampling).
                    view.Crop.Width &= ~1;
                    view.Crop.Height &= ~1;
                    spec.Region = view;
                    spec.Output = WindowTrack.OutputSize(view.Crop.Size);
                    follower = new WindowFollower(agent, win, monitors);
                    follower.MonitorChanged += SwitchMonitor;
                    follower.Closed += delegate { string cur = CurrentId; if (cur != null) Stop(cur); };
                    follower.Moved += delegate (Rectangle from, Rectangle to)
                    {
                        WebcamBubble bb;
                        lock (gate) bb = bubble;
                        if (bb != null) try { bb.BeginInvoke(new Action(delegate { bb.FollowWindow(from, to); })); } catch { }
                    };
                    follower.Start();
                    var c = view.Crop;
                    E2e.Write("window-capture.json", string.Format("{{\"monitor_x\":{0},\"monitor_y\":{1},\"crop_x\":{2},\"crop_y\":{3},\"crop_w\":{4},\"crop_h\":{5},\"out_w\":{6},\"out_h\":{7}}}",
                        mon.Bounds.X, mon.Bounds.Y, c.X, c.Y, c.Width, c.Height, spec.Output.Width, spec.Output.Height));
                }
                var clock = Stopwatch.StartNew();
                double recorded = 0;
                // Room for the audio track as soon as audio was asked for (the sources may still be starting).
                long cap = VideoCap(o.PartBytes, maxSeconds, o.Mic || o.SystemAudio), bytes = 0;
                var videos = new List<string>();
                var segs = new List<Segment>();
                for (int seg = 0; ; seg++)
                {
                    int left = maxSeconds - (int)Math.Floor(clock.Elapsed.TotalSeconds);
                    if (left < 1) break;
                    spec.Monitor = mon;
                    spec.MaxSeconds = left;
                    spec.MaxBytes = cap - bytes;
                    spec.Video = Path.Combine(dir, id + ".s" + seg + ".mp4");
                    spec.Progress = new FfProgress();
                    spec.Progress.OnFirstFrame = delegate { times.Mark("t_first_frame"); };
                    temps.Add(spec.Video);
                    var segClock = Stopwatch.StartNew();
                    double launched = Clock.Now();
                    times.Mark("t_ffmpeg_launch");
                    bool fast;
                    Process p = StartSegment(spec, follower, segClock, out fast);
                    if (seg == 0)
                    {
                        times.Mark("t_started");
                        agent.SendStatus(id, "recording", null);
                        var r = Recording;
                        if (r != null) ThreadPool.QueueUserWorkItem(delegate { r(); });
                        keeper.Release(); // the capture is up: the warm ffmpeg is no longer needed until the next recording
                        audioJoin();
                        if (micP != null && !MicRunning(mic, micP, micProgress, micLaunched))
                        {
                            micP = null;
                            lock (gate) { micProc = null; micMutes = null; }
                            SetPillSources(false, system != null);
                        }
                    }
                    p.WaitForExit(); // the parameterless wait also drains the redirected -progress output
                    // Desktop Duplication that fails within 2 s of its launch after its first frame: the next video path
                    // (StartSegment skips the failed one), or gdigrab when the cpu path was the one that failed.
                    if (fast && p.ExitCode != 0 && (p.ExitTime - p.StartTime).TotalSeconds < 2)
                    {
                        Log.Write("video path " + spec.Path + " failed after its first frame (" + p.ExitCode + ")");
                        segClock.Restart();
                        spec.Progress = Fresh(spec.Progress);
                        if (spec.Path != VideoChain.Cpu)
                        {
                            failedPaths.Add(PathKey(spec.Path, spec.Monitor.Bounds.Size, spec.Encoder));
                            p = StartSegment(spec, follower, segClock, out fast);
                        }
                        else
                        {
                            Log.Write("ddagrab failed, falling back to gdigrab");
                            p = LaunchGdi(spec, follower);
                        }
                        p.WaitForExit();
                    }
                    recorded += segClock.Elapsed.TotalSeconds;
                    lock (gate) ff = null;
                    if (follower != null) follower.Detach();
                    if (File.Exists(spec.Video) && new FileInfo(spec.Video).Length >= 1024)
                    {
                        videos.Add(spec.Video);
                        bytes += new FileInfo(spec.Video).Length;
                        var pr = spec.Progress;
                        segs.Add(pr.Valid ? new Segment(pr.T0, pr.Last) : new Segment(launched, segClock.Elapsed.TotalSeconds));
                        if (!pr.Valid) Log.Write("no ffmpeg progress for segment " + seg + "; audio timing estimated from the launch");
                        else Log.Write("timing: segment " + seg + " " + pr.Describe() + ", " + new FileInfo(spec.Video).Length + " bytes");
                    }
                    MonitorInfo next;
                    lock (gate) { next = stopRequested ? null : switchTo; switchTo = null; }
                    if (next == null || follower == null) break;
                    mon = next;
                    spec.Region = follower.ViewOn(mon);
                    Log.Write("window: moved to monitor " + mon.Index + " (" + mon.Label + "); recording continues there");
                }
                if (follower != null) follower.Stop();
                audioJoin();
                if (system != null) system.Stop();
                lock (gate) micProc = null;
                StopProcess(micP);
                var micSpans = mutes.Spans();
                ClosePill();
                if (videos.Count == 0) throw new Exception("CAPTURE_FAILED");
                bool hasMic = micP != null && File.Exists(micWav) && new FileInfo(micWav).Length > 1024, hasSys = system != null && system.Seconds > 0;
                if (!hasMic && !hasSys) Join(videos, video);
                else
                {
                    string silentVideo = Path.Combine(dir, id + ".v.mp4");
                    temps.Add(silentVideo);
                    Join(videos, silentVideo);
                    if (hasMic && !micProgress.Valid) Log.Write("no ffmpeg progress for the mic; its timing estimated from the launch");
                    // The WAV's own length (its samples at 48 kHz mono s16) against the mic's out_time: a mic whose clock
                    // runs off 48 kHz shows here as a difference that grows with the recording's length.
                    if (hasMic && micProgress.Valid) Log.Write("timing: mic " + micProgress.Describe() + ", samples " + ((new FileInfo(micWav).Length - 44) / 96000.0).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture) + " s");
                    double micStart = micProgress.Valid ? micProgress.T0 : micLaunched;
                    // The video does not open before the mic: when the mic's first sample came after the first frame (its
                    // ffmpeg is launched first but takes longer to deliver), the video's head is cut off at the first
                    // keyframe after it (StartScreen forces one every ~100 ms early on), at most AudioMath.MaxTrim. System
                    // audio never trims (loopback can start seconds late when nothing plays): the mix delays it instead.
                    var inv = System.Globalization.CultureInfo.InvariantCulture;
                    double micAt = hasMic ? micStart : double.NaN, late = micAt - segs[0].WallStart, trim = 0;
                    if (late > 0)
                    {
                        bool capped;
                        trim = AudioMath.StartTrim(segs[0].WallStart, micAt, agent.Capture.Keyframes(silentVideo, AudioMath.MaxTrim + 0.5), out capped);
                        if (trim >= AudioMath.Length(segs)) trim = 0; // a recording shorter than the trim keeps its frames
                        Log.Write(capped
                            ? "timing: mic late " + (late * 1000).ToString("0", inv) + " ms, capped; video starts at its keyframe at " + (trim * 1000).ToString("0", inv)
                                + " ms, mic delayed " + ((late - trim) * 1000).ToString("0", inv) + " ms"
                            : "timing: mic starts " + (late * 1000).ToString("0", inv) + " ms after the first frame; video starts at its keyframe at " + (trim * 1000).ToString("0", inv) + " ms");
                    }
                    segs = AudioMath.TrimStart(segs, trim);
                    if (hasSys && system.StartTime > segs[0].WallStart)
                        Log.Write("timing: system audio starts " + ((system.StartTime - segs[0].WallStart) * 1000).ToString("0", inv) + " ms after the video; delayed");
                    MixAudio(silentVideo, trim, hasMic ? micWav : null, micStart, hasSys ? system : null, micSpans, segs, video, audio);
                    // The transcription WAV (16 kHz mono s16) is on the trimmed timeline: as long as the stored duration.
                    if (File.Exists(audio))
                        Log.Write("timing: trimmed length " + AudioMath.Length(segs).ToString("0.000", inv) + " s, transcription WAV " + ((new FileInfo(audio).Length - 44) / 32000.0).ToString("0.000", inv) + " s");
                }
                if (videos.Count > 1) Log.Write("joined " + videos.Count + " segments");
                agent.SendStatus(id, "uploading", null);
                // Video length from ffmpeg's own progress (the stopwatch also counts ffmpeg's start-up).
                double length = AudioMath.Length(segs);
                // The transcription WAV exists only with a mic (transcripts are mic-only); system audio alone is in the video.
                agent.Deliver(id, video, audio, hasMic, hasSys, uploadToken, Math.Min(length > 0 ? length : recorded, maxSeconds), o.PartBytes);
            }
            catch (Exception e)
            {
                Log.Write("recording failed: " + e.Message);
                agent.SendStatus(id, "failed", e.Message.Length > 100 ? e.Message.Substring(0, 100) : e.Message);
            }
            finally
            {
                if (follower != null) follower.Stop();
                JoinAudio(audioUp); // a failure before the capture was up: the sources may still be starting
                if (system != null) system.Stop();
                StopProcess(micP);
                ClosePill();
                // Raw mic/system WAVs (temps) and the mixed files never outlive the recording.
                TryDelete(video);
                TryDelete(audio);
                foreach (var f in temps) TryDelete(f);
                keeper.Release();
                lock (gate) { currentId = null; ff = null; micProc = null; stopRequested = false; switchTo = null; sys = null; micMutes = null; keeper.Resume(); }
                times.Flush();
                Native.TrimWorkingSet();
                keeper.Fill(); // none when a new recording has paused it meanwhile
                var done = Finished;
                if (done != null) try { done(); } catch (Exception e) { Log.Write("after recording: " + e.Message); }
            }
        }

        /// Waits for the system audio / mic start (Run); its own failures are logged there, so this only logs the unexpected.
        static void JoinAudio(System.Threading.Tasks.Task audioUp)
        {
            if (audioUp == null) return;
            try { audioUp.Wait(); }
            catch (Exception e) { Log.Write("audio start: " + e.GetBaseException().Message); }
        }

        /// Mixes mic and system audio into the video's single AAC track (and, with a mic, the mic-only transcription WAV).
        /// The mic's muted spans are silenced exactly (100 ms early, 50 ms late, on top of the live mute); the system WAV is already zero there.
        void MixAudio(string silentVideo, double trim, string micWav, double micStart, LoopbackCapture system, List<Span> micMuted, List<Segment> segs, string video, string audio)
        {
            var spans = AudioMath.ToTimeline(micMuted, segs, 0.1, 0.05);
            var micSlices = micWav != null ? AudioMath.Slices(segs, micStart) : null;
            var slices = system != null ? AudioMath.Slices(segs, system.StartTime) : null;
            int micIn = micWav != null ? 1 : -1, sysIn = system != null ? (micWav != null ? 2 : 1) : -1;
            string filter = AudioMath.MixFilter(micIn, spans, micSlices, sysIn, slices);
            var sw = Stopwatch.StartNew();
            agent.Capture.MixAudio(silentVideo, trim, micWav, system != null ? system.PathName : null, filter, video, audio);
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            Log.Write("audio mixed in " + sw.ElapsedMilliseconds + " ms (" + (micWav != null ? "mic, offset " + micSlices[0].Start.ToString("0.000", inv) + " s" : "")
                + (micWav != null && system != null ? " + " : "")
                + (system != null ? "system audio, offset " + (slices[0].Start).ToString("0.000", inv) + " s" : "") + ", mic muted spans " + spans.Count + ")");
            if (E2e.On)
            {
                // Where the mutes landed in the video (seconds), for the e2e level checks.
                var sysWall = system != null ? system.Mutes.Spans().ConvertAll(x => new Span(x.Start + system.StartTime, x.End + system.StartTime)) : new List<Span>();
                var sysSpans = AudioMath.ToTimeline(sysWall, segs, 0, 0);
                var micExact = AudioMath.ToTimeline(micMuted, segs, 0, 0);
                E2e.Write("audio-mix.json", "{\"filter\":" + Json.Esc(filter) + ",\"mic_muted\":" + Json.Esc(string.Join(",", micExact.ConvertAll(x => x.ToString())))
                    + ",\"sys_muted\":" + Json.Esc(string.Join(",", sysSpans.ConvertAll(x => x.ToString())))
                    + ",\"sys_device\":" + Json.Esc(system != null ? system.Device : "") + ",\"sys_format\":" + Json.Esc(system != null ? system.Format : "")
                    + ",\"sys_switches\":" + (system != null ? system.Switches : 0) + ",\"sys_losses\":" + (system != null ? system.Losses : 0) + "}");
            }
        }

        /// Starts ffmpeg for one segment and returns once it has encoded its first frame (or exited, or run 2 s without
        /// one). Desktop Duplication through each VideoChain path in turn (GPU first), gdigrab when all of them exit with an
        /// error before that (Run also falls back when one fails later within 2 s). A path that failed is not tried again
        /// for that source size and encoder. When gdigrab fails too and the encoder came from the probe, the encoders are
        /// probed again and the segment starts over once with the new pick.
        Process StartSegment(CaptureSpec spec, WindowFollower follower, Stopwatch segClock, out bool fast)
        {
            var mon = spec.Monitor;
            var src = mon.Bounds.Size;
            Process p = null;
            for (int attempt = 0; ; attempt++)
            {
                fast = agent.Capture.CanUseFastPath(mon);
                bool failed = true;
                if (fast)
                {
                    foreach (var path in VideoChain.Candidates(src, spec.Region.HasValue, true, spec.Encoder, agent.Cfg.VideoPath, gpu))
                    {
                        string key = PathKey(path, src, spec.Encoder);
                        if (path != VideoChain.Cpu && failedPaths.Contains(key)) continue;
                        spec.Path = path;
                        if (!spec.Region.HasValue) spec.Output = VideoChain.Output(path, src);
                        p = Launch(spec, true, follower);
                        failed = FailedEarly(p, spec.Progress);
                        if (!failed) break;
                        Log.Write("video path " + path + " failed (" + p.ExitCode + ")");
                        if (path != VideoChain.Cpu) failedPaths.Add(key);
                        segClock.Restart();
                        spec.Progress = Fresh(spec.Progress);
                    }
                    if (failed)
                    {
                        Log.Write("ddagrab failed, falling back to gdigrab");
                        fast = false;
                    }
                }
                if (!fast)
                {
                    p = LaunchGdi(spec, follower);
                    failed = FailedEarly(p, spec.Progress);
                }
                string pinned = agent.Cfg.Encoder;
                if (!failed || attempt > 0 || (pinned != null && pinned != "auto")) break;
                string next = agent.Capture.ProbeEncoder(true);
                if (next == spec.Encoder) break;
                Log.Write("capture failed (" + p.ExitCode + ") with " + spec.Encoder + "; starting over with " + next);
                spec.Encoder = next;
                gpu = agent.Capture.ProbeGpu(next);
                segClock.Restart();
                spec.Progress = Fresh(spec.Progress);
            }
            Log.Write("video path: " + spec.Path + " (" + src.Width + "x" + src.Height + " -> " + spec.Output.Width + "x" + spec.Output.Height + ")");
            var b = mon.Bounds;
            string region = "";
            if (spec.Region.HasValue)
            {
                var c = spec.Region.Value.Crop;
                region = ", window crop " + c.Width + "x" + c.Height + "+" + c.X + "+" + c.Y + " -> " + spec.Output.Width + "x" + spec.Output.Height;
            }
            Log.Write("capture started (" + (fast ? "ddagrab output_idx=" + mon.OutputIdx : "gdigrab " + b.Width + "x" + b.Height + "+" + b.X + "+" + b.Y)
                + ", " + spec.Encoder + ", monitor " + mon.Index + " " + mon.Label + region + ")");
            var cr = spec.Region.HasValue ? spec.Region.Value.Crop : new Rectangle(Point.Empty, b.Size);
            E2e.Write("capture.json", string.Format("{{\"monitor_x\":{0},\"monitor_y\":{1},\"monitor_w\":{2},\"monitor_h\":{3},\"crop_x\":{4},\"crop_y\":{5},\"crop_w\":{6},\"crop_h\":{7},\"fast\":{8},\"encoder\":{9},\"path\":{10}}}",
                b.X, b.Y, b.Width, b.Height, cr.X, cr.Y, cr.Width, cr.Height, fast ? "true" : "false", Json.Esc(spec.Encoder), Json.Esc(spec.Path)));
            return p;
        }

        /// Waits for the capture's first encoded frame, at most 2 s. True when ffmpeg exited with an error before it.
        /// Desktop Duplication delivers its first frame only once the screen is presented again, so the pill repaints
        /// meanwhile (no visible change); on a still screen the wait would otherwise last until its next 80 ms frame.
        bool FailedEarly(Process p, FfProgress progress)
        {
            var sw = Stopwatch.StartNew();
            while (!progress.FirstFrame.Wait(30))
            {
                if (p.HasExited) return p.ExitCode != 0 && !progress.FirstFrame.IsSet;
                if (sw.ElapsedMilliseconds >= 2000) return false;
                ControlPill f;
                lock (gate) f = pill;
                if (f != null) try { f.BeginInvoke(new Action(f.Repaint)); } catch { }
            }
            return false;
        }

        Process Launch(CaptureSpec spec, bool fast, WindowFollower follower)
        {
            var p = agent.Capture.StartScreen(spec, fast);
            bool stop;
            lock (gate) { ff = p; stop = stopRequested; }
            if (follower != null) follower.Attach(p, spec.Monitor, spec.Region.Value);
            if (stop) StopProcess(p); // Stop arrived while ffmpeg was starting
            return p;
        }

        /// Waits until the mic's ffmpeg is running (its first progress line), at most 2 s after its launch. False when it
        /// exited instead (the recording goes on without it).
        static bool MicRunning(AvDevice mic, Process p, FfProgress progress, double launched)
        {
            while (!progress.Valid && !p.HasExited && Clock.Now() - launched < 2) Thread.Sleep(50);
            if (p.HasExited)
            {
                Log.Write("mic " + mic.Name + " failed to start (" + p.ExitCode + "); recording without it");
                return false;
            }
            Log.Write("mic " + mic.Name + " started (own process, " + (progress.Valid ? "first audio " + Math.Round((progress.T0 - launched) * 1000) + " ms after its launch" : "no audio yet") + ")");
            return true;
        }

        /// gdigrab, the compatibility path (always the cpu chain).
        Process LaunchGdi(CaptureSpec spec, WindowFollower follower)
        {
            spec.Path = VideoChain.Cpu;
            if (!spec.Region.HasValue) spec.Output = VideoChain.Output(VideoChain.Cpu, spec.Monitor.Bounds.Size);
            return Launch(spec, false, follower);
        }

        static string PathKey(string path, Size source, string encoder) { return path + " " + source.Width + "x" + source.Height + " " + encoder; }

        /// A new progress reader for a relaunch, still reporting the recording's first frame.
        static FfProgress Fresh(FfProgress old) { return new FfProgress { OnFirstFrame = old.OnFirstFrame }; }

        void Join(List<string> parts, string output)
        {
            if (parts.Count == 1) File.Move(parts[0], output);
            else agent.Capture.Concat(parts, output);
        }

        static void TryDelete(string f) { try { if (File.Exists(f)) File.Delete(f); } catch { } }

        // One long-lived STA thread hosts every pill and bubble. WinForms binds SystemEvents to the first UI thread;
        // letting that thread exit makes the next window hang, so it is created once (on first recording) and kept.
        static Control ui;

        static Control UiThread()
        {
            if (ui != null) return ui;
            var ready = new ManualResetEvent(false);
            var t = new Thread(delegate ()
            {
                ui = new Control();
                ui.CreateControl();
                ready.Set();
                Application.Run();
            });
            t.SetApartmentState(ApartmentState.STA);
            t.IsBackground = true;
            t.Start();
            ready.WaitOne();
            return ui;
        }

        /// The pill goes on the recorded monitor (for a window, the monitor holding most of it).
        void ShowPill(MonitorInfo mon, List<MonitorInfo> monitors)
        {
            var shown = new ManualResetEvent(false);
            UiThread().BeginInvoke(new Action(delegate
            {
                var f = new ControlPill(agent.Cfg, mon, monitors);
                f.StopClicked += delegate { string id = CurrentId; if (id != null) ThreadPool.QueueUserWorkItem(delegate { Stop(id); }); };
                f.MuteChanged += SetMute;
                f.Shown += delegate
                {
                    lock (gate) pill = f;
                    f.Repaint();
                    if (E2e.On) using (var b = f.Snapshot()) E2e.Save(b, "pill.png");
                    f.E2eRect();
                    shown.Set();
                };
                f.FormClosed += delegate { f.Dispose(); };
                f.Show();
            }));
            // The indicator must be visible before capture starts. It is shown and painted now, and ffmpeg (launched next)
            // takes several hundred ms to create its process and open its inputs before it grabs a frame, so capture
            // still starts after it is on screen without the 150 ms pause this used to add.
            if (!shown.WaitOne(10000)) throw new Exception("PILL_FAILED");
        }

        /// Closes the pill (and the bubble) however the recording ended: Stop on the pill, stop_recording, max length,
        /// a closed window or a failure. Run calls it on every path.
        void ClosePill()
        {
            CloseBubble();
            ControlPill f;
            lock (gate) { f = pill; pill = null; }
            if (f == null) return;
            try { f.BeginInvoke(new Action(f.Close)); } catch { }
        }

        /// Opens the camera and shows the bubble on a thread of its own, right away: the camera's ffmpeg starts together
        /// with the screen capture, no longer after its first frame (it used to wait for that, or 3 s), so the bubble is
        /// up about one camera-open after the start command instead of first frame + camera-open. The tradeoff: the two
        /// ffmpeg processes opening DirectShow and Desktop Duplication at once slow each other's start by ~0.3 s. The
        /// screen path still never waits for the camera. Marks t_bubble (or settles it) when done.
        void StartBubble(Func<List<AvDevice>> cameras, WebcamOpts cam, MonitorInfo mon, Rectangle? inside, StartTimes times)
        {
            int gen;
            lock (gate) gen = bubbleGen;
            BubbleThread(delegate { return ShowBubble(cameras, cam, mon, inside, gen); }, times);
        }

        /// The bubble's own thread: show() at once (nothing awaited first), then t_bubble when it showed, else settled.
        internal static Thread BubbleThread(Func<bool> show, StartTimes times)
        {
            var t = new Thread(delegate ()
            {
                bool shown = false;
                try { shown = show(); }
                catch (Exception e) { Log.Write("webcam: " + e.GetBaseException().Message + "; recording without the bubble"); }
                if (shown) times.Mark("t_bubble");
                else times.BubbleSettled();
            });
            t.IsBackground = true;
            t.Name = "bubble";
            t.Start();
            return t;
        }

        /// Shows the webcam bubble on the recorded monitor and waits until it is on screen. Returns false when it was not
        /// shown; a bubble whose recording ended meanwhile (bubbleGen moved on) is closed instead.
        bool ShowBubble(Func<List<AvDevice>> camerasOf, WebcamOpts cam, MonitorInfo mon, Rectangle? inside, int gen)
        {
            WebcamBubble b = null;
            try
            {
                var cameras = camerasOf(); // the device list (Run looks it up beside the screen's launch)
                if (cameras.Count == 0) { Log.Write("webcam: no dshow video device; recording without the bubble"); return false; }
                AvDevice want = cam.Camera != null ? DeviceMatch.Av(cameras, cam.Camera) : null;
                AvDevice dev = want ?? DeviceMatch.Av(cameras, agent.Cfg.Camera) ?? cameras[0];
                if (cam.Camera != null && want == null) Log.Write("webcam: camera \"" + cam.Camera + "\" is not in the inventory, using " + dev.Name);
                // Per-recording shape/size from start_recording, else what was last chosen on the PC.
                bool rect = (cam.Shape ?? agent.Cfg.Shape) == "rect";
                int px = cam.Pct > 0 ? WebcamBubble.PxForPercent(cam.Pct, mon.Bounds.Size, mon.Dpi, rect) : cam.Px > 0 ? cam.Px : agent.Cfg.WebcamPx;
                lock (gate) if (gen != bubbleGen) return false;
                UiThread().Invoke(new Action(delegate
                {
                    b = new WebcamBubble(agent.Cfg, agent.Capture, cameras, dev, px, rect, mon.Bounds, mon.WorkArea, inside);
                    b.StartCamera();
                }));
                bool current;
                lock (gate) { current = gen == bubbleGen; if (current) bubble = b; }
                if (!current) { CloseOwnBubble(b); return false; }
                int got = WaitHandle.WaitTimeout;
                for (int waited = 0; waited < 8000 && got == WaitHandle.WaitTimeout; waited += 100)
                {
                    lock (gate) if (gen != bubbleGen) return false; // the recording ended; CloseBubble closed it
                    got = WaitHandle.WaitAny(new WaitHandle[] { b.ShownEvent, b.FailedEvent }, 100);
                }
                if (got != 0)
                {
                    Log.Write("webcam: bubble not shown (" + (b.LastError.Length > 0 ? b.LastError : "camera timeout") + "); recording without it");
                    CloseOwnBubble(b);
                    return false;
                }
                Log.Write("webcam bubble shown (" + dev.Name + ", " + px + " px, " + (rect ? "rect" : "circle") + ", mirror " + (agent.Cfg.Mirror ? "on" : "off") + ")");
                return true;
            }
            catch (Exception e)
            {
                Log.Write("webcam: " + e.Message + "; recording without the bubble");
                if (b != null) CloseOwnBubble(b);
                return false;
            }
        }

        void CloseBubble()
        {
            WebcamBubble b;
            lock (gate) { b = bubble; bubble = null; bubbleGen++; }
            if (b == null) return;
            try { ui.BeginInvoke(new Action(b.Shutdown)); } catch { }
        }

        /// Closes this bubble only (a later recording may already have its own).
        void CloseOwnBubble(WebcamBubble b)
        {
            lock (gate) if (bubble == b) bubble = null;
            try { ui.BeginInvoke(new Action(b.Shutdown)); } catch { }
        }

        public static void Upload(string server, string id, string video, string audio, bool hasTranscript, bool hasSystemAudio, string token, double duration, long partBytes)
        {
            string baseUrl = server.TrimEnd('/') + "/upload/" + id + "/";
            var up = new Uploader(delegate (string method, string path, string file, long offset, long count, string json)
            {
                return Http(baseUrl + path, method, token, file, offset, count, json);
            }, partBytes);
            Send(up, video, audio, hasTranscript, hasSystemAudio, duration);
            Log.Write("uploaded " + id);
        }

        /// The requests of one upload: the video, the transcription WAV (the mic only) when there is one, then complete. No
        /// mic = no WAV: no audio request at all, and complete as always (the server stores it without a transcript).
        public static void Send(Uploader up, string video, string audio, bool hasTranscript, bool hasSystemAudio, double duration)
        {
            up.File("video", video, new FileInfo(video).Length);
            if (hasTranscript && audio != null && File.Exists(audio) && new FileInfo(audio).Length > 44) up.File("audio", audio, new FileInfo(audio).Length);
            else Log.Write("upload: no transcription audio (" + (hasTranscript ? "the WAV is empty or missing" : "no mic") + "); video only");
            up.Complete("{\"duration_s\":" + duration.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)
                + ",\"has_system_audio\":" + (hasSystemAudio ? "true" : "false") + "}");
        }

        /// One keyframe JPEG (Stills) to /upload/<id>/{path}, with the recording's upload token. 30 s at most, no retries.
        public static int PutStill(string server, string id, string token, string path, string jpg)
        {
            return Http(server.TrimEnd('/') + "/upload/" + id + "/" + path, "PUT", token, jpg, 0, new FileInfo(jpg).Length, null, 30000);
        }

        /// The request's Content-Type: JSON bodies application/json; files image/jpeg under /keyframes/, video/mp4 when the
        /// URL has "/video", else audio/wav. parity: mac Uploader.contentType
        public static string ContentType(string url, bool hasFile)
        {
            if (!hasFile) return "application/json";
            if (url.Contains("/keyframes/")) return "image/jpeg";
            return url.Contains("/video") ? "video/mp4" : "audio/wav";
        }

        /// One request: bytes [offset, offset + count) of file streamed from disk (never buffered), else the json body.
        /// Returns the HTTP status, 0 when there was no response (logged).
        static int Http(string url, string method, string token, string file, long offset, long count, string json, int timeoutMs = 600000)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = method;
                req.ContentType = ContentType(url, file != null);
                req.AllowWriteStreamBuffering = false;
                req.SendChunked = false;
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.Headers["Authorization"] = "Bearer " + token;
                byte[] body = file == null ? Encoding.UTF8.GetBytes(json ?? "") : null;
                req.ContentLength = file == null ? body.Length : count;
                using (var s = req.GetRequestStream())
                {
                    if (file == null) s.Write(body, 0, body.Length);
                    else
                        using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 65536))
                        {
                            fs.Seek(offset, SeekOrigin.Begin);
                            var buf = new byte[65536];
                            for (long left = count; left > 0; )
                            {
                                int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left));
                                if (n <= 0) throw new IOException("file shorter than expected");
                                s.Write(buf, 0, n);
                                left -= n;
                            }
                        }
                }
                using (var res = (HttpWebResponse)req.GetResponse()) return (int)res.StatusCode;
            }
            catch (WebException e)
            {
                var res = e.Response as HttpWebResponse;
                if (res != null) using (res) return (int)res.StatusCode;
                Log.Write("upload " + method + " " + url.Substring(url.IndexOf("/upload/")) + ": " + e.Message);
                return 0;
            }
        }
    }

    /// The upload policy of one recording's files (pure: HTTP goes through Send, waits through Sleep; the selftest drives it
    /// with failures). A file up to the part size (or any file when the server sent none) is one PUT. A larger one goes
    /// up in parts through the Worker's R2 multipart upload: create, PUT parts 1..N in order (a failed part is sent again
    /// with the same number), complete {parts: N}. A 502 means the Worker aborted the multipart upload: start over from
    /// create.
    /// One install, several Recitbot accounts (hello "multi_account", 0.6.0): which account each recording belongs to, and
    /// the one-recording-per-machine rule across accounts. parity: mac/Sources/RecitbotCore/MultiAccount.swift
    class RecordingOwners
    {
        readonly object gate = new object();
        /// recording id -> account id, newest last (only the last Keep are remembered).
        readonly List<KeyValuePair<string, string>> owners = new List<KeyValuePair<string, string>>();
        public const int Keep = 64;

        /// Ties a recording id to the account whose connection sent it. false when the id already belongs to another
        /// account (that account's recording is never touched from here).
        public bool Claim(string id, string account)
        {
            string rid = id ?? "";
            lock (gate)
            {
                int i = owners.FindIndex(o => o.Key == rid);
                if (i >= 0) return owners[i].Value == account;
                owners.Add(new KeyValuePair<string, string>(rid, account));
                if (owners.Count > Keep) owners.RemoveRange(0, owners.Count - Keep);
                return true;
            }
        }

        public string Owner(string id)
        {
            string rid = id ?? "";
            lock (gate)
            {
                int i = owners.FindLastIndex(o => o.Key == rid);
                return i < 0 ? null : owners[i].Value;
            }
        }

        /// stop / a status for this recording from account: only the account that started it.
        public bool Owns(string id, string account) { return account != null && Owner(id) == account; }

        /// A start from account is refused (the existing "BUSY" status) while any recording runs on this machine, or when
        /// its id is another account's. The id is claimed for account either way.
        public bool Refuses(string id, string account, bool recording) { return !Claim(id, account) || recording; }
    }

    /// The connections the agent runs against the accounts in config.dat (read again whenever the file changes).
    /// parity: mac AccountSet
    static class AccountSet
    {
        /// What to change: accounts to connect, and account ids whose connection ends. An account whose device id, token,
        /// secret or server changed (a refresh) is ended and connected again with the new entry.
        public class Diff
        {
            public List<Config.Account> Start = new List<Config.Account>();
            public List<string> Stop = new List<string>();
        }

        public static Diff Compare(List<Config.Account> running, List<Config.Account> wanted)
        {
            var d = new Diff();
            foreach (var r in running) if (!wanted.Exists(w => w.Same(r))) d.Stop.Add(r.AccountId);
            foreach (var w in wanted) if (!running.Exists(r => r.Same(w))) d.Start.Add(w);
            return d;
        }
    }

    /// Calls Changed (on a pool thread, once per 300 ms burst) after config.dat in a folder was replaced or written:
    /// FileSystemWatcher events, plus a check every 60 s in case an event was missed. Only a real change (time, size)
    /// counts; a missing file (an uninstall in progress) does not. parity: mac Agent.watchConfig
    sealed class ConfigWatch : IDisposable
    {
        readonly string path;
        readonly Action changed;
        readonly object gate = new object();
        readonly FileSystemWatcher watcher;
        readonly System.Threading.Timer debounce, fallback;
        string stamp;
        public const int DebounceMs = 300, FallbackMs = 60000;

        public ConfigWatch(string dir, Action changed)
        {
            path = Path.Combine(dir, "config.dat");
            this.changed = changed;
            stamp = Stamp(path);
            debounce = new System.Threading.Timer(delegate { Check(); }, null, Timeout.Infinite, Timeout.Infinite);
            fallback = new System.Threading.Timer(delegate { Check(); }, null, FallbackMs, FallbackMs);
            try
            {
                watcher = new FileSystemWatcher(dir)
                {
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime,
                    IncludeSubdirectories = false,
                };
                FileSystemEventHandler h = delegate (object o, FileSystemEventArgs e) { if (Ours(e.Name)) Soon(); };
                watcher.Changed += h;
                watcher.Created += h;
                watcher.Renamed += delegate (object o, RenamedEventArgs e) { if (Ours(e.Name) || Ours(e.OldName)) Soon(); };
                watcher.Error += delegate { Soon(); };
                watcher.EnableRaisingEvents = true;
            }
            catch (Exception e) { Log.Write("config watch not available (" + e.GetType().Name + "); config.dat is checked every 60 s"); }
        }

        static bool Ours(string name) { return string.Equals(name, "config.dat", StringComparison.OrdinalIgnoreCase); }

        void Soon() { try { debounce.Change(DebounceMs, Timeout.Infinite); } catch (ObjectDisposedException) { } }

        public static string Stamp(string file)
        {
            var fi = new FileInfo(file);
            return fi.Exists ? fi.LastWriteTimeUtc.Ticks + "/" + fi.Length : null;
        }

        void Check()
        {
            lock (gate)
            {
                string s = Stamp(path);
                if (s == stamp) return;
                stamp = s;
                if (s == null) return;
            }
            try { changed(); }
            catch (Exception e) { Log.Write("config reload failed: " + e.Message); }
        }

        public void Dispose()
        {
            if (watcher != null) watcher.Dispose();
            debounce.Dispose();
            fallback.Dispose();
        }
    }

    class Uploader
    {
        /// One request to /upload/:id/{path}. Body: bytes [offset, offset + count) of file, else json. Returns the HTTP
        /// status, 0 when there was no response.
        public delegate int SendFn(string method, string path, string file, long offset, long count, string json);

        /// Tries of one request (after no response or a 5xx), and multipart uploads started per file.
        public const int Attempts = 3, Restarts = 3;
        readonly SendFn send;
        readonly long partBytes;
        public Action<int> Sleep = Thread.Sleep;

        public Uploader(SendFn send, long partBytes) { this.send = send; this.partBytes = partBytes; }

        /// [offset, count] of each part: every part but the last is partBytes, the last holds the rest (1..partBytes).
        public static List<long[]> Parts(long length, long partBytes)
        {
            var l = new List<long[]>();
            for (long o = 0; o < length; o += partBytes) l.Add(new[] { o, Math.Min(partBytes, length - o) });
            return l;
        }

        /// kind = "video" | "audio".
        public void File(string kind, string file, long length)
        {
            if (partBytes <= 0 || length <= partBytes) { Call("PUT", kind, file, 0, length, null, false); return; }
            var parts = Parts(length, partBytes);
            for (int r = 0; r < Restarts; r++)
            {
                if (r > 0) Log.Write(kind + ": the server aborted the multipart upload; starting it again");
                if (Call("POST", kind + "/mp", null, 0, 0, "{\"total_bytes\":" + length + "}", true) == 502) continue;
                bool aborted = false;
                for (int i = 0; i < parts.Count && !aborted; i++)
                    aborted = Call("PUT", kind + "/mp/" + (i + 1), file, parts[i][0], parts[i][1], null, true) == 502;
                if (aborted || Call("POST", kind + "/mp/complete", null, 0, 0, "{\"parts\":" + parts.Count + "}", true) == 502) continue;
                Log.Write(kind + ": " + length + " bytes in " + parts.Count + " parts of up to " + partBytes);
                return;
            }
            throw new Exception("UPLOAD_FAILED: " + kind + " multipart upload aborted " + Restarts + " times");
        }

        public void Complete(string json) { Call("POST", "complete", null, 0, 0, json, false); }

        /// Sends one request, again (the same request) after no response or a 5xx. A 4xx is final (thrown); a 502 is
        /// returned when abortable (the multipart upload is gone).
        int Call(string method, string path, string file, long offset, long count, string json, bool abortable)
        {
            int st = 0;
            for (int a = 0; a < Attempts; a++)
            {
                if (a > 0) Sleep(2000 * a);
                st = send(method, path, file, offset, count, json);
                if (st >= 200 && st < 300) return st;
                if (abortable && st == 502) return st;
                if (st >= 400 && st < 500) throw new Exception("UPLOAD_REJECTED_" + st);
            }
            throw new Exception("UPLOAD_FAILED: " + method + " " + path + " (" + (st == 0 ? "no response" : st.ToString()) + ")");
        }
    }

    /// End-of-recording keyframes (hello "keyframes", docs/keyframes.md): once the MP4 upload has succeeded, up to Count
    /// evenly spaced JPEG stills of the final MP4 go up one PUT each, /upload/<id>/keyframes/<n>?t=<ms>. Best effort: a
    /// skipped, bad or refused still is logged and never fails the recording (Run never throws). The policy is pure; the
    /// ffmpeg probe, the frame grab and the PUT come in as delegates. parity: mac/Sources/RecitbotCore/Keyframes.swift
    static class Stills
    {
        public const int Count = 6, MaxWidth = 1280, Quality = 75;
        public const long MaxBytes = 1024 * 1024;
        public const double MinSeconds = 2.0;

        /// Frame times in ms from the start of the video: the centres of Count equal buckets, duration * (2i - 1) / (2 * Count)
        /// for i = 1..Count, floored to the ms. Never 0 (often a blank first frame) and never the exact end (a seek there
        /// returns no frame). None for a video shorter than MinSeconds (or of unknown length).
        public static List<long> Times(double seconds)
        {
            var l = new List<long>();
            if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < MinSeconds) return l;
            for (int i = 1; i <= Count; i++) l.Add((long)Math.Floor(seconds * 1000 * (2 * i - 1) / (2 * Count)));
            return l;
        }

        /// Why no stills are taken, or null to take them: no video track (audio only) or shorter than MinSeconds.
        public static string Skip(double seconds, bool hasVideo)
        {
            if (!hasVideo) return "audio only";
            if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < MinSeconds) return "shorter than 2 s";
            return null;
        }

        /// Reads ffmpeg -i's listing: the container duration ("Duration: 00:01:02.50", NaN when N/A or missing) and
        /// whether there is a video stream (a cover picture, "(attached pic)", is not one).
        public static void Probe(string info, out double seconds, out bool hasVideo)
        {
            seconds = double.NaN;
            hasVideo = false;
            foreach (var raw in (info ?? "").Split('\n'))
            {
                string line = raw.Trim();
                if (line.StartsWith("Duration: "))
                {
                    string v = line.Substring(10);
                    int comma = v.IndexOf(',');
                    if (comma >= 0) v = v.Substring(0, comma);
                    var p = v.Split(':');
                    double h, m, s;
                    var inv = System.Globalization.CultureInfo.InvariantCulture;
                    if (p.Length == 3 && double.TryParse(p[0], System.Globalization.NumberStyles.Float, inv, out h)
                        && double.TryParse(p[1], System.Globalization.NumberStyles.Float, inv, out m)
                        && double.TryParse(p[2], System.Globalization.NumberStyles.Float, inv, out s))
                        seconds = h * 3600 + m * 60 + s;
                }
                else if (line.StartsWith("Stream #") && line.Contains(": Video: ") && !line.Contains("(attached pic)")) hasVideo = true;
            }
        }

        public enum Result { Stored, Unsupported, Failed }

        /// 2xx stored; 404 / 501 = this server has no keyframes route (yet): the rest are skipped without an error;
        /// anything else (no response = 0, other 4xx, 5xx) is a failure: logged, the rest skipped.
        public static Result Outcome(int status)
        {
            if (status >= 200 && status < 300) return Result.Stored;
            if (status == 404 || status == 501) return Result.Unsupported;
            return Result.Failed;
        }

        /// One still: its slot n (1..Count, kept when another slot's frame was bad), time and JPEG file.
        public class Frame
        {
            public int N;
            public long Ms;
            public string File;
        }

        /// One PUT of a JPEG to /upload/<id>/{path}. Returns the HTTP status, 0 when there was no response.
        public delegate int PutFn(string path, string file);

        /// The PUT's path under /upload/<id>/.
        public static string Route(Frame f) { return "keyframes/" + f.N + "?t=" + f.Ms; }

        /// The PUTs, in order, once each (no retries: the stills are a nice-to-have). Stops at the first one that is not
        /// stored. Returns the log line.
        public static string Send(PutFn put, List<Frame> frames)
        {
            int sent = 0;
            foreach (var f in frames)
            {
                int st;
                try { st = put(Route(f), f.File); }
                catch (Exception e) { Log.Write("keyframes: " + e.GetType().Name + " " + e.Message); st = 0; }
                var r = Outcome(st);
                if (r == Result.Stored) { sent++; continue; }
                if (r == Result.Unsupported) return "keyframes: not supported by this server (" + st + "); skipped";
                return "keyframes: " + sent + " of " + frames.Count + " sent; stopped at " + f.N + " (" + (st == 0 ? "no response" : "HTTP " + st) + ")";
            }
            return "keyframes: " + sent + " of " + frames.Count + " sent";
        }

        /// A file the PUT may carry: a JPEG (FF D8 FF) of 1 byte .. MaxBytes.
        public static bool Usable(string file)
        {
            try
            {
                var fi = new FileInfo(file);
                if (!fi.Exists || fi.Length < 3 || fi.Length > MaxBytes) return false;
                using (var s = fi.OpenRead()) return s.ReadByte() == 0xFF && s.ReadByte() == 0xD8 && s.ReadByte() == 0xFF;
            }
            catch { return false; }
        }

        /// The whole step for one uploaded recording: probe (info: ffmpeg -i's listing of video), skip or grab the stills
        /// (grab: video, ms, jpg; a frame that throws or is not Usable is logged and left out), PUT them, delete them.
        /// fallbackSeconds: the recording's own length when the probe shows none. Never throws; returns the log line.
        public static string Run(Func<string, string> info, Action<string, long, string> grab, PutFn put, string video, double fallbackSeconds, string dir, string id)
        {
            var frames = new List<Frame>();
            try
            {
                double seconds;
                bool hasVideo;
                Probe(info(video), out seconds, out hasVideo);
                if (double.IsNaN(seconds)) seconds = fallbackSeconds;
                string why = Skip(seconds, hasVideo);
                if (why != null) return "keyframes: skipped (" + why + ")";
                var times = Times(seconds);
                for (int i = 0; i < times.Count; i++)
                {
                    var f = new Frame { N = i + 1, Ms = times[i], File = Path.Combine(dir, id + ".k" + (i + 1) + ".jpg") };
                    try
                    {
                        grab(video, f.Ms, f.File);
                        if (Usable(f.File)) frames.Add(f);
                        else { Log.Write("keyframes: frame " + f.N + " at " + f.Ms + " ms is not a usable JPEG; left out"); TryDelete(f.File); }
                    }
                    catch (Exception e) { Log.Write("keyframes: frame " + f.N + " at " + f.Ms + " ms: " + e.Message + "; left out"); TryDelete(f.File); }
                }
                if (frames.Count == 0) return "keyframes: no usable frame; nothing sent";
                return Send(put, frames);
            }
            catch (Exception e) { return "keyframes: skipped (" + e.GetType().Name + " " + e.Message + ")"; }
            finally { foreach (var f in frames) TryDelete(f.File); }
        }

        /// An image file to a baseline JPEG at Quality.
        public static void Encode(string image, string jpg)
        {
            System.Drawing.Imaging.ImageCodecInfo codec = null;
            foreach (var c in System.Drawing.Imaging.ImageCodecInfo.GetImageEncoders()) if (c.FormatID == System.Drawing.Imaging.ImageFormat.Jpeg.Guid) codec = c;
            if (codec == null) throw new Exception("no JPEG encoder");
            using (var bmp = new Bitmap(image))
            using (var ps = new System.Drawing.Imaging.EncoderParameters(1))
            {
                ps.Param[0] = new System.Drawing.Imaging.EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Quality);
                bmp.Save(jpg, codec, ps);
            }
        }

        static void TryDelete(string file) { try { if (File.Exists(file)) File.Delete(file); } catch { } }
    }

    /// The resident agent: one outbound WebSocket per paired account (AccountLink), verified commands in, status /
    /// inventory / update frames out on the connection the command came in on. One recording per machine across accounts
    /// (RecordingOwners). config.dat is watched (ConfigWatch): an account added by --enroll, refreshed or removed is
    /// connected / reconnected / dropped without a restart. parity: mac/Sources/Recitbot/Agent.swift
    class Agent : IRecorderHost
    {
        public Config Cfg { get; private set; }
        public ICaptureBackend Capture { get; private set; }
        public IDeviceCatalog Catalog { get; private set; }
        public string WorkDir { get { return Path.Combine(Cfg.Dir, "tmp"); } }
        readonly Recorder recorder;
        readonly ReadyLinks links = new ReadyLinks();
        /// Which account each recording belongs to (its statuses, upload and stop go through that account only).
        readonly RecordingOwners owners = new RecordingOwners();
        readonly object accountsGate = new object();
        /// The running connections, by account id.
        readonly Dictionary<string, AccountLink> accounts = new Dictionary<string, AccountLink>();
        readonly object applyGate = new object();
        ConfigWatch watch;
        /// 1 once a full removal started (RemoveAll): later revocations and uninstall commands change nothing.
        int removing;
        /// 1 once UpdateHealth's marker is written (after the first hello of this run).
        int healthy;
        /// The update the installer rolled back from (UpdateHealth.RolledBack), reported once per account; null = none.
        readonly string rolledBack;
        readonly HashSet<string> rolledBackSent = new HashSet<string>();

        public Agent(Config cfg)
        {
            Cfg = cfg;
            var backend = new WindowsFfmpegBackend(cfg.Ffmpeg);
            Capture = backend;
            Catalog = backend;
            recorder = new Recorder(this);
            recorder.Finished += delegate
            {
                ThreadPool.QueueUserWorkItem(delegate
                {
                    SelfUpdater.RunDeferred(() => recorder.Busy, SelfUpdater.Deferred, UnixNow(),
                        delegate (PendingUpdate p) { return SelfUpdater.Install(Cfg, p.Server, p.Sha256, p.Url); });
                });
            };
            rolledBack = UpdateHealth.RolledBack(cfg.Dir, Program.Version);
            if (rolledBack != null) Log.Write("update to " + rolledBack + " was rolled back by the installer; this is " + Program.Version);
        }

        /// A connection is up and its hello went out: the installer's health marker (once per run) and, after a rollback,
        /// the "rolled_back" report on this account (once per account; the record goes after the first one is sent).
        public void Connected(AccountLink l)
        {
            if (!l.Connected) return; // the hello did not get out: the next connect tries again
            if (Interlocked.Exchange(ref healthy, 1) == 0) UpdateHealth.WriteMarker(Cfg.Dir, Program.Version);
            if (rolledBack == null) return;
            lock (rolledBackSent) if (!rolledBackSent.Add(l.Account.AccountId)) return;
            l.SendText(UpdateHealth.RolledBackJson(rolledBack)).Wait(15000);
            Log.Write("update to " + rolledBack + ": rolled_back reported (account " + l.Account.AccountId + ")");
            UpdateHealth.Clear(Cfg.Dir);
        }

        public static long UnixNow() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }

        /// Connects every account in config.dat, watches the file, and never returns.
        public void Run()
        {
            watch = new ConfigWatch(Cfg.Dir, Reload);
            try { Reload(); }
            catch (Exception e) { Log.Write("config reload failed: " + e.Message); Apply(Cfg.Accounts); }
            Thread.Sleep(Timeout.Infinite);
        }

        void Reload()
        {
            var c = Config.Load(Cfg.Dir);
            if (c != null) Apply(c.Accounts);
        }

        /// Connects the accounts that are new or changed, ends the ones that are gone or changed.
        void Apply(List<Config.Account> wanted)
        {
            lock (applyGate)
            {
                var stopped = new List<AccountLink>();
                var started = new List<AccountLink>();
                lock (accountsGate)
                {
                    var running = new List<Config.Account>();
                    foreach (var l in accounts.Values) running.Add(l.Account);
                    var d = AccountSet.Compare(running, wanted);
                    foreach (var id in d.Stop)
                    {
                        AccountLink l;
                        if (accounts.TryGetValue(id, out l)) { accounts.Remove(id); stopped.Add(l); }
                    }
                    foreach (var a in d.Start)
                    {
                        var l = new AccountLink(this, a);
                        accounts[a.AccountId] = l;
                        started.Add(l);
                    }
                }
                foreach (var l in stopped)
                {
                    Log.Write("account " + l.Account.AccountId + ": connection ended (removed or paired again)");
                    l.Stop();
                }
                foreach (var l in started)
                {
                    Log.Write("account " + l.Account.AccountId + ": device " + l.Account.DeviceId);
                    l.Start();
                }
            }
        }

        AccountLink LinkOf(string accountId)
        {
            if (accountId == null) return null;
            lock (accountsGate)
            {
                AccountLink l;
                return accounts.TryGetValue(accountId, out l) ? l : null;
            }
        }

        /// How many accounts would be left without this one.
        int Others(AccountLink l)
        {
            lock (accountsGate)
            {
                int n = 0;
                foreach (var id in accounts.Keys) if (id != l.Account.AccountId) n++;
                return n;
            }
        }

        /// Removes one account from this install: its recording ends, its entry and nonce file leave config.dat, its
        /// connection closes. The other accounts keep running.
        void Drop(AccountLink l, string why)
        {
            var a = l.Account;
            string rid = recorder.CurrentId;
            if (rid != null && owners.Owns(rid, a.AccountId))
            {
                Log.Write("account " + a.AccountId + " removed while recording " + rid + "; recording stopped");
                recorder.Stop(rid);
            }
            try
            {
                var left = Config.RemoveAccount(Cfg.Dir, a.AccountId, a.DeviceId);
                Log.Write("account " + a.AccountId + " removed (" + why + "); " + left.Count + " left");
            }
            catch (Exception e) { Log.Write("account " + a.AccountId + " not removed from config.dat (" + why + "): " + e.Message); }
            lock (accountsGate)
            {
                AccountLink cur;
                if (accounts.TryGetValue(a.AccountId, out cur) && cur == l) accounts.Remove(a.AccountId);
            }
            l.Stop();
        }

        /// The account ids whose sockets are connected now.
        List<string> ConnectedAccounts()
        {
            lock (accountsGate)
            {
                var c = new List<string>();
                foreach (var x in accounts.Values) if (x.Connected) c.Add(x.Account.AccountId);
                return c;
            }
        }

        /// Sends SelfUninstaller.Acks, all at once: the commanding connection's ack (waited for up to 5 s) and, for a full
        /// removal, {"type":"uninstall_ack","accounts_remaining":0} (no request_id) on every other connected account
        /// (waited for up to 2 s in all). Accounts that are not connected get nothing.
        void SendAcks(AccountLink l, string requestId, bool all, int left)
        {
            var clock = Stopwatch.StartNew();
            Task own = null;
            var others = new List<Task>();
            string me = l.Account.AccountId;
            foreach (var ack in SelfUninstaller.Acks(me, requestId, all, left, ConnectedAccounts()))
            {
                if (ack.Key == me) { own = l.SendText(ack.Value); continue; }
                var o = LinkOf(ack.Key);
                if (o != null) others.Add(o.SendText(ack.Value));
            }
            if (own != null && !own.Wait(SelfUninstaller.AckWaitMs)) Log.Write("uninstall: ack not sent within 5 s");
            int rest = Math.Max(0, SelfUninstaller.OtherAcksWaitMs - (int)clock.ElapsedMilliseconds);
            if (others.Count > 0 && !Task.WaitAll(others.ToArray(), rest)) Log.Write("uninstall: acks to the other accounts not all sent within 2 s");
        }

        /// Removes this install for every account: the acks first (SendAcks), then SelfUninstaller.Run (exits). Once only.
        void RemoveAll(AccountLink l, string requestId, string why)
        {
            if (Interlocked.Exchange(ref removing, 1) == 1) return;
            if (recorder.Busy) Log.Write("uninstall: recording " + recorder.CurrentId + " abandoned");
            SendAcks(l, requestId, true, 0);
            SelfUninstaller.Run(Cfg, why);
        }

        /// A revoked device (410 device_revoked): scope "account" removes only its account (the last one removes the
        /// install); scope "all" (or none: a server from before scopes) removes the install for every account.
        public void Revoked(AccountLink l, SelfUninstaller.Scope scope)
        {
            if (Volatile.Read(ref removing) == 1) return;
            string why = "device revoked, scope " + (scope == SelfUninstaller.Scope.All ? "all" : "account");
            if (SelfUninstaller.RemovesAll(scope, Others(l))) { RemoveAll(l, null, why); return; }
            Drop(l, why);
        }

        /// A connection the server answered 401 (no longer paired) stopped retrying. When none is left running, the warm
        /// ffmpeg goes (no more recordings are coming).
        public void Unpaired(AccountLink l)
        {
            Log.Write(Revocation.StoppedLine + " (account " + l.Account.AccountId + ")");
            lock (accountsGate) foreach (var x in accounts.Values) if (!x.Unpaired) return;
            recorder.Cool();
        }

        /// The verified "uninstall" command: uninstall_ack first, before anything is removed. Scope "account" with other
        /// accounts left: the ack says how many, then only the account that sent it goes (its socket closes, the others
        /// keep running). Scope "all" (or none), or the last account: RemoveAll. A recording in progress is not uploaded
        /// (the server already failed it); its ffmpeg ends with the agent's kill-on-close job, and the helper stops any
        /// stray one from the install folder.
        void OnUninstall(string id, SelfUninstaller.Scope scope, AccountLink l)
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                if (Volatile.Read(ref removing) == 1) return;
                int left = Others(l);
                if (SelfUninstaller.RemovesAll(scope, left)) { RemoveAll(l, id ?? "", "command " + id); return; }
                SendAcks(l, id ?? "", false, left);
                Drop(l, "uninstall command " + id);
            });
        }

        /// Sends the monitor/mic/camera inventory on one connection (on connect and when its server asks for it).
        public void ReportDevices(string requestId, AccountLink l)
        {
            if (!l.BeginReport()) return;
            try
            {
                var mons = Catalog.Monitors();
                var wins = Catalog.Windows(mons);
                var av = Catalog.AudioVideo();
                l.SendText(DeviceMatch.InventoryJson(requestId, mons, av, wins)).Wait(15000);
                Log.Write("devices reported: " + mons.Count + " monitors, " + av.Mics.Count + " mics, " + av.Cameras.Count + " cameras, " + wins.Count + " windows");
                // Probed here (on connect, i.e. at agent start, and again on a device request when the display adapters
                // changed) so a start command never waits for it; the device list just made is cached the same way
                // (CachedAudioVideo).
                if (!recorder.Busy)
                {
                    Recorder.Warm(Capture, Cfg.Encoder);
                    recorder.KeepWarm();
                }
            }
            catch (Exception e) { Log.Write("device inventory failed: " + e.Message); }
            finally
            {
                l.EndReport();
                if (!recorder.Busy) Native.TrimWorkingSet();
            }
        }

        static string Opt(Dictionary<string, string> f, string k)
        {
            string v;
            return f.TryGetValue(k, out v) && !string.IsNullOrEmpty(v) ? v : null;
        }

        /// One frame from l: verified with l's command key and handled for l's account only.
        public void Handle(string text, AccountLink l)
        {
            double received = Clock.Now();
            Dictionary<string, string> f;
            try { f = Json.ParseFlat(text); }
            catch { Log.Write("ignored malformed frame"); return; }
            // An uninstall with an unknown scope is rejected like a bad command (nothing removed).
            string reason = l.Verifier.Verify(f, UnixNow()) ?? SelfUninstaller.ScopeRejection(f);
            bool uninstall = SelfUninstaller.Commanded(reason, f);
            if (reason != null) { Log.Write("rejected command: " + reason); return; }
            string type = f["type"], id = f["recording_id"], acct = l.Account.AccountId;
            Log.Write("command " + type + " " + id);
            if (uninstall) OnUninstall(id, SelfUninstaller.ScopeOf(f) ?? SelfUninstaller.Scope.Account, l);
            else if (type == "start")
            {
                if (owners.Refuses(id, acct, recorder.Busy))
                {
                    Log.Write("start " + id + " refused: another recording is in progress on this computer");
                    l.SendStatus(id, "failed", "BUSY");
                    return;
                }
                int max;
                int.TryParse(f["max_seconds"], out max);
                string webcam = Opt(f, "webcam"), size = Opt(f, "webcam_size"), shape = Opt(f, "webcam_shape");
                int px = WebcamBubble.PxForName(size), pct;
                if (px > 0 || !int.TryParse(size ?? "", out pct) || pct < 1 || pct > 100) pct = 0;
                long partBytes;
                if (!long.TryParse(Opt(f, "upload_part_bytes") ?? "", out partBytes) || partBytes < 0) partBytes = 0;
                var o = new Recorder.StartOpts
                {
                    Mic = f["mic"] == "true",
                    SystemAudio = Opt(f, "system_audio") == "true",
                    MicDevice = Opt(f, "mic_device"),
                    Monitor = Opt(f, "monitor"),
                    Window = Opt(f, "window"),
                    PartBytes = partBytes,
                    Cam = new Recorder.WebcamOpts
                    {
                        On = webcam == null ? Cfg.Webcam : webcam == "true", Camera = Opt(f, "camera"), Px = px > 0 ? px : 0, Pct = pct,
                        Shape = shape == "rect" || shape == "circle" ? shape : null,
                    },
                };
                recorder.Start(id, max, o, f["upload_token"], received);
            }
            // Another account's recording is not this connection's: the same silence as "not recording".
            else if (type == "stop") { if (owners.Owns(id, acct)) recorder.Stop(id); }
            else if (type == "devices") ThreadPool.QueueUserWorkItem(delegate { ReportDevices(id, l); });
            else if (type == "ready") OnReady(id, Opt(f, "url"), l);
            else if (type == "update")
            {
                bool busy = recorder.Busy;
                string server = l.Account.Server;
                long exp;
                long.TryParse(f["exp"], out exp); // verified above
                ThreadPool.QueueUserWorkItem(delegate { SelfUpdater.Run(Cfg, server, busy, Opt(f, "version"), Opt(f, "sha256"), Opt(f, "url"), exp, delegate (string s) { l.SendText(s).Wait(15000); }); });
            }
        }

        /// The Worker's signed "ready" frame: open the owner's share link once, if this PC uploaded that recording for this
        /// connection's account, the link passes LinkPolicy and auto_open_link is on. The URL is never written to the log
        /// (it is a bearer link).
        void OnReady(string id, string url, AccountLink l)
        {
            if (!owners.Owns(id, l.Account.AccountId) || !links.Claim(id, DateTime.UtcNow)) { Log.Write("ready " + id + ": not waiting for it here (or already handled); nothing opened"); return; }
            if (!LinkPolicy.Allowed(url, l.Account.Server, id)) { Log.Write("ready " + id + ": link rejected (not our viewer on an allowed host)"); return; }
            if (!Cfg.ReadBool("auto_open_link", true)) { Log.Write("ready " + id + ": auto_open_link is off; not opening"); return; }
            LinkOpener.Open(url);
        }

        /// Uploads with the server of the account that started the recording (and that recording's upload token).
        public void Deliver(string id, string video, string audio, bool hasTranscript, bool hasSystemAudio, string token, double duration, long partBytes)
        {
            var l = LinkOf(owners.Owner(id));
            if (l == null) throw new Exception("UPLOAD_FAILED: the account of this recording is no longer paired here");
            // Expected before the upload completes: the ready frame can arrive before /complete's response does.
            links.Expect(id, DateTime.UtcNow);
            try { Recorder.Upload(l.Account.Server, id, video, audio, hasTranscript, hasSystemAudio, token, duration, partBytes); }
            catch { links.Forget(id); throw; }
            // Only after the MP4 is up; never fails the recording (Stills.Run does not throw; docs/keyframes.md).
            string server = l.Account.Server;
            try
            {
                Log.Write(Stills.Run(Capture.MediaInfo, Capture.Still, delegate (string path, string jpg) { return Recorder.PutStill(server, id, token, path, jpg); },
                    video, duration, Path.GetDirectoryName(Path.GetFullPath(video)), id));
            }
            catch (Exception e) { Log.Write("keyframes: skipped (" + e.Message + ")"); }
        }

        /// A recording's status goes to the account that started it (dropped when that account is not connected).
        public void SendStatus(string id, string status, string error)
        {
            var l = LinkOf(owners.Owner(id));
            if (l != null) l.SendStatus(id, status, error);
        }
    }

    /// One account's device connection: its own socket, send lock, reconnect backoff, ping and command key (verifier and
    /// nonce file). Ends for good with Stop() (account removed, revoked, or paired again).
    class AccountLink
    {
        public readonly Config.Account Account;
        public readonly CommandVerifier Verifier;
        readonly Agent agent;
        readonly SemaphoreSlim sendLock = new SemaphoreSlim(1, 1);
        readonly CancellationTokenSource stop = new CancellationTokenSource();
        ClientWebSocket ws;
        int reporting;
        public bool Unpaired { get; private set; }

        public AccountLink(Agent agent, Config.Account account)
        {
            this.agent = agent;
            Account = account;
            Verifier = new CommandVerifier(account.AccountId, account.DeviceId, account.DeviceSecret, Config.NoncePath(agent.Cfg.Dir, account.DeviceId));
        }

        public bool Stopped { get { return stop.IsCancellationRequested; } }

        /// Whether this account's socket is up now.
        public bool Connected { get { var w = ws; return !Stopped && w != null && w.State == WebSocketState.Open; } }

        public void Start() { Task.Run(() => RunAsync()); }

        public void Stop()
        {
            stop.Cancel();
            var w = ws;
            if (w != null) { try { w.Abort(); } catch { } }
        }

        public bool BeginReport() { return Interlocked.Exchange(ref reporting, 1) == 0; }

        public void EndReport() { Interlocked.Exchange(ref reporting, 0); }

        async Task RunAsync()
        {
            int backoff = 5;
            bool lastFast = false;
            var rng = new Random();
            while (!Stopped)
            {
                bool connected = false;
                var next = Revocation.Next.Retry;
                var session = new Stopwatch();
                try
                {
                    using (var socket = new ClientWebSocket())
                    {
                        socket.Options.SetRequestHeader("Authorization", "Bearer " + Account.DeviceToken);
                        socket.Options.KeepAliveInterval = TimeSpan.Zero;
                        var uri = new Uri(Account.Server.TrimEnd('/').Replace("https://", "wss://").Replace("http://", "ws://") + "/device/ws");
                        await socket.ConnectAsync(uri, stop.Token);
                        ws = socket;
                        if (Stopped) return;
                        connected = true;
                        session.Start();
                        backoff = 5;
                        Log.Write("connected (account " + Account.AccountId + ")");
                        await SendText(Program.HelloJson());
                        ThreadPool.QueueUserWorkItem(delegate { agent.Connected(this); });
                        ThreadPool.QueueUserWorkItem(delegate { agent.ReportDevices("", this); });
                        var cts = new CancellationTokenSource();
                        var pinger = PingLoop(cts.Token);
                        try { await ReceiveLoop(socket); }
                        finally { cts.Cancel(); ws = null; }
                    }
                }
                catch (Exception e)
                {
                    if (Stopped) return;
                    int status = Revocation.HandshakeStatus(e);
                    Log.Write(Revocation.ConnectionErrorLine(e, status) + " (account " + Account.AccountId + ")");
                    if (Revocation.InnerErrorLine(e) != null) Log.Write(Revocation.InnerErrorLine(e) + " (account " + Account.AccountId + ")");
                    SelfUninstaller.Scope? scope = null;
                    next = Revocation.AfterError(connected, status, () => (scope = Revoked(e)) != null);
                    if (next == Revocation.Next.Uninstall) { agent.Revoked(this, scope.Value); return; }
                }
                if (Stopped) return;
                if (connected) Log.Write("disconnected (account " + Account.AccountId + ")");
                if (next == Revocation.Next.Stop)
                {
                    // No server route takes an "I am unpaired" report (the only /device routes are POST /device/enroll and
                    // /device/ws), so nothing is sent: the log says it; reporting is left to the server's device status.
                    Unpaired = true;
                    agent.Unpaired(this);
                    return;
                }
                // A clean close or a drop after a connection (e.g. a deploy restarting the Durable Object) comes back in
                // 0.5-1.5 s; a socket that never connected keeps the backoff.
                bool fast = Revocation.FastReconnect(connected, lastFast, session.Elapsed.TotalSeconds);
                try { await Task.Delay(Revocation.ReconnectDelay(next, fast, backoff, rng.NextDouble(), rng.Next(0, 3)).Value, stop.Token); }
                catch (OperationCanceledException) { return; }
                lastFast = fast;
                if (!fast) backoff = Math.Min(backoff * 2, 300);
            }
        }

        /// A refused handshake means "revoked" only for 410 plus device_revoked: from the handshake's own body when the
        /// exception still has it, else from one confirming probe (Revocation.Probe); either body carries the scope.
        /// null (not revoked) for every other failure.
        SelfUninstaller.Scope? Revoked(Exception e)
        {
            int status = Revocation.HandshakeStatus(e);
            if (status != 410) return null;
            var own = Revocation.RevokedScope(status, Revocation.HandshakeBody(e));
            if (own != null) { Log.Write("handshake: 410 device_revoked, scope " + ScopeName(own.Value)); return own; }
            var probe = Revocation.Probe(Account.Server, Account.DeviceToken);
            Log.Write("handshake: 410; probe " + (probe != null ? "says device_revoked, scope " + ScopeName(probe.Value) : "does not confirm a revocation; reconnecting as usual"));
            return probe;
        }

        static string ScopeName(SelfUninstaller.Scope s) { return s == SelfUninstaller.Scope.All ? "all" : "account"; }

        /// Application-level ping answered by the Durable Object's auto-response (no wake-up).
        async Task PingLoop(CancellationToken ct)
        {
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    await Task.Delay(45000, ct);
                    await SendText("ping");
                }
            }
            catch { }
        }

        async Task ReceiveLoop(ClientWebSocket socket)
        {
            var buf = new byte[8192];
            var msg = new MemoryStream();
            while (socket.State == WebSocketState.Open && !Stopped)
            {
                var r = await socket.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None);
                if (r.MessageType == WebSocketMessageType.Close) return;
                if (msg.Length + r.Count > 16384) { msg.SetLength(0); continue; }
                msg.Write(buf, 0, r.Count);
                if (!r.EndOfMessage) continue;
                string text = Encoding.UTF8.GetString(msg.ToArray());
                msg.SetLength(0);
                if (text == "pong") continue;
                agent.Handle(text, this);
            }
        }

        public void SendStatus(string id, string status, string error)
        {
            string json = "{\"type\":\"status\",\"recording_id\":" + Json.Esc(id) + ",\"status\":" + Json.Esc(status)
                + (error != null ? ",\"error\":" + Json.Esc(error) : "") + "}";
            SendText(json).Wait(15000);
        }

        /// Dropped when this account is not connected.
        public async Task SendText(string s)
        {
            await sendLock.WaitAsync();
            try
            {
                var w = ws;
                if (w == null || w.State != WebSocketState.Open) return;
                var b = Encoding.UTF8.GetBytes(s);
                await w.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, CancellationToken.None);
            }
            catch (Exception e) { Log.Write("send failed: " + e.Message); }
            finally { sendLock.Release(); }
        }
    }

    static class Program
    {
        public const string Version = "0.6.1";
        /// What this recorder understands beyond the v1 command (the Worker only sends what is listed here).
        public static readonly string[] Features = { "system_audio", "webcam_shape", "webcam_pct", "ready_push", "chunked_upload", "self_update", "self_uninstall", "multi_account", "update_defer_rollback", "keyframes" };

        public static string HelloJson()
        {
            var f = new List<string>();
            foreach (var x in Features) f.Add(Json.Esc(x));
            return "{\"type\":\"hello\",\"version\":" + Json.Esc(Version) + ",\"features\":[" + string.Join(",", f) + "]}";
        }

        static string Arg(string[] args, string name)
        {
            for (int i = 0; i < args.Length - 1; i++) if (args[i] == name) return args[i + 1];
            return null;
        }

        [STAThread]
        static int Main(string[] args)
        {
            if (Array.IndexOf(args, "--selftest") >= 0) return SelfTest();
            if (Array.IndexOf(args, "--controls-shots") >= 0) return ControlsShots(args);
            Native.EnableDpiAwareness();
            if (Array.IndexOf(args, "--webcam-preview") >= 0) return WebcamPreview(args);
            if (Array.IndexOf(args, "--list-devices") >= 0) return ListDevices(args);
            if (Array.IndexOf(args, "--pill-preview") >= 0) return PillPreview(args);
            if (Array.IndexOf(args, "--record-local") >= 0) return RecordLocal(args);
            if (Array.IndexOf(args, "--chain-bench") >= 0) return ChainBench(args);
            if (Array.IndexOf(args, "--start-latency") >= 0) return StartLatency(args);
            string dir = Arg(args, "--data") ?? AppDomain.CurrentDomain.BaseDirectory;
            dir = Path.GetFullPath(dir);
            Directory.CreateDirectory(dir);
            Log.PathName = Path.Combine(dir, "agent.log");
            if (Array.IndexOf(args, "--enroll") >= 0) return Enroll(args, dir);
            if (Array.IndexOf(args, "--set") >= 0) return SetSetting(Arg(args, "--set"), dir);

            bool created;
            string mutexName = "Local\\AgentRecorder-" + CommandVerifier.HmacHex("mutex", dir.ToLowerInvariant()).Substring(0, 16);
            using (var mutex = new Mutex(true, mutexName, out created))
            {
                if (!created) { Log.Write("already running"); return 2; }
                Config cfg;
                try { cfg = Config.Load(dir); }
                catch (Exception e) { Log.Write("config unreadable: " + e.Message); return 3; }
                if (cfg == null || cfg.Accounts.Count == 0) { Log.Write("not enrolled"); return 3; }
                File.WriteAllText(Path.Combine(dir, "agent.pid"), Process.GetCurrentProcess().Id.ToString());
                Log.Write("starting agent (Windows " + Environment.OSVersion.Version + ", " + (Environment.Is64BitProcess ? "64" : "32") + "-bit, "
                    + RuntimeArch() + ", DPI awareness " + Native.DpiMode + ", version " + Version + ")");
                var agent = new Agent(cfg);
                // Dev runs against a local Worker beside someone using the PC: the same flags as --record-local.
                var backend = (WindowsFfmpegBackend)agent.Capture;
                backend.TestCamera = Array.IndexOf(args, "--test-camera") >= 0;
                backend.NoFront = Array.IndexOf(args, "--no-front") >= 0;
                if (Array.IndexOf(args, "--below-normal") >= 0) WindowsFfmpegBackend.CapturePriority = ProcessPriorityClass.BelowNormal;
                agent.Run();
                return 0;
            }
        }

        /// --set key=value [--data DIR]: changes one setting in config.dat (Config.Settable, e.g. auto_open_link=false).
        /// Works while the agent runs; it reads these settings when it uses them. Exit 0 = saved, 6 = bad key/value,
        /// 3 = not installed/enrolled here.
        static int SetSetting(string kv, string dir)
        {
            int eq = kv == null ? -1 : kv.IndexOf('=');
            string key = eq > 0 ? kv.Substring(0, eq).Trim() : null, value = key != null ? Config.NormalizeSetting(key, kv.Substring(eq + 1)) : null;
            if (value == null) { Log.Write("--set: unknown setting or value (allowed: " + string.Join(", ", Config.Settable) + " = true|false)"); return 6; }
            if (!File.Exists(Path.Combine(dir, "config.dat"))) { Log.Write("--set: not enrolled in " + dir); return 3; }
            new Config { Dir = dir }.SetPrefs(key, value);
            Log.Write("setting " + key + " = " + value);
            return 0;
        }

        static string RuntimeArch()
        {
            string a = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") ?? "?";
            return a.ToLowerInvariant();
        }

        /// --enroll --server URL [--ffmpeg PATH] [--name NAME] [--account ID]; the pairing code is read from stdin. The
        /// account the code pairs is added to config.dat, or its entry refreshed when it is already there; the other accounts
        /// stay. Prints `device=<id>` (the paired device id) on success.
        static int Enroll(string[] args, string dir)
        {
            try
            {
                string server = Arg(args, "--server");
                // The install's ffmpeg is machine-wide; a first pairing without --ffmpeg uses the one on PATH.
                string ffmpeg = Arg(args, "--ffmpeg") ?? (File.Exists(Path.Combine(dir, "config.dat")) ? null : "ffmpeg.exe");
                // The account the installer says the code is for: only its token is sent (Config.EnrollToken).
                string account = Arg(args, "--account");
                string name = Arg(args, "--name") ?? Environment.MachineName;
                string code = System.Text.RegularExpressions.Regex.Replace(Console.In.ReadLine() ?? "", "[^A-Za-z0-9]", ""); // codes are alphanumeric; a UTF-8 parent shell can prepend a BOM that decodes as OEM junk
                if (server == null || code.Length == 0) { Log.Write("enroll: missing server or code"); return 4; }
                var u = new Uri(server);
                if (u.Scheme != "https" && !u.IsLoopback) { Log.Write("enroll: server must be https"); return 4; }

                // A re-pair sends the token held for that account only, so the server matches it by token; anything else (no
                // --account, an account not paired here, no config or an unreadable one) pairs without a token.
                string held = null;
                try { var old = Config.Load(dir); if (old != null) held = Config.EnrollToken(old.Accounts, account); }
                catch (Exception e) { Log.Write("enroll: existing config unreadable, pairing as new: " + e.Message); }
                string text;
                try { text = PostEnroll(server, EnrollBody(code, name, held)); }
                catch (WebException e)
                {
                    // The token held here was revoked (the PC was uninstalled from the account): an install is running, so
                    // this is not an uninstall; pair once more as a new device. Anything else fails as before.
                    var res = e.Response as HttpWebResponse;
                    string retry = res == null ? null : EnrollRetryBody((int)res.StatusCode, ReadAll(res), code, name, held);
                    if (retry == null) throw;
                    Log.Write("enroll: the pairing held here was revoked; pairing as a new device");
                    text = PostEnroll(server, retry);
                }
                var f = Json.ParseFlat(text);
                var a = new Config.Account
                {
                    Server = server.TrimEnd('/'), AccountId = f["account_id"], DeviceId = f["device_id"], DeviceToken = f["device_token"], DeviceSecret = f["device_secret"],
                };
                bool added = Config.UpsertAccount(dir, a, ffmpeg);
                Log.Write("enrolled device " + a.DeviceId + " (account " + a.AccountId + (added ? " added)" : " paired again)"));
                Console.WriteLine("device=" + a.DeviceId);
                return 0;
            }
            catch (WebException e)
            {
                var res = e.Response as HttpWebResponse;
                Log.Write("enroll failed: " + (res != null ? ((int)res.StatusCode).ToString() : e.Message));
                return 5;
            }
            catch (Exception e)
            {
                Log.Write("enroll failed: " + e.Message);
                return 5;
            }
        }

        /// POST <server>/device/enroll; the response text. Throws WebException on a non-2xx answer or no answer.
        static string PostEnroll(string server, string json)
        {
            var body = Encoding.UTF8.GetBytes(json);
            var req = (HttpWebRequest)WebRequest.Create(server.TrimEnd('/') + "/device/enroll");
            req.Method = "POST";
            req.ContentType = "application/json";
            req.ContentLength = body.Length;
            using (var s = req.GetRequestStream()) s.Write(body, 0, body.Length);
            using (var res = (HttpWebResponse)req.GetResponse()) return ReadAll(res);
        }

        static string ReadAll(HttpWebResponse res)
        {
            try { using (var r = new StreamReader(res.GetResponseStream())) return r.ReadToEnd(); }
            catch (Exception) { return ""; }
        }

        /// The body of the one retry after enrolling with a held token got 410 {"error":"device_revoked"}: the same pairing
        /// without device_token (a fresh pairing). null = no retry (other answers, or no token was sent). Pure.
        /// parity: mac Frames.enrollRetryBody
        static string EnrollRetryBody(int status, string responseBody, string code, string name, string held)
        {
            if (string.IsNullOrEmpty(held) || !Revocation.IsRevoked(status, responseBody)) return null;
            return EnrollBody(code, name, null);
        }

        /// The POST /device/enroll body: code, name (cut to 64), platform, and device_token only when one is already held
        /// (a re-pair). Pure; covered by the selftest.
        static string EnrollBody(string code, string name, string deviceToken)
        {
            if (name.Length > 64) name = name.Substring(0, 64);
            string body = "{\"code\":" + Json.Esc(code) + ",\"name\":" + Json.Esc(name) + ",\"platform\":\"windows\"";
            if (!string.IsNullOrEmpty(deviceToken)) body += ",\"device_token\":" + Json.Esc(deviceToken);
            return body + "}";
        }

        /// Dev check: --list-devices [--ffmpeg PATH]. Prints the inventory report the agent would send.
        static int ListDevices(string[] args)
        {
            var backend = new WindowsFfmpegBackend(Arg(args, "--ffmpeg") ?? "ffmpeg.exe");
            var mons = backend.Monitors();
            Console.WriteLine(DeviceMatch.InventoryJson("cli", mons, backend.AudioVideo(), backend.Windows(mons)));
            return 0;
        }

        /// The dev CLI's recorder host: no server; status lines go to stdout and the finished files stay in a folder.
        class LocalHost : IRecorderHost
        {
            readonly string outDir;
            public readonly ManualResetEvent Done = new ManualResetEvent(false);
            public bool Ok;
            public Config Cfg { get; private set; }
            public ICaptureBackend Capture { get; private set; }
            public IDeviceCatalog Catalog { get; private set; }
            public string WorkDir { get { return Path.Combine(outDir, "tmp"); } }

            public LocalHost(string ffmpeg, string outDir, bool testCamera)
            {
                this.outDir = outDir;
                Cfg = new Config { Ffmpeg = ffmpeg }; // Dir stays null: UI preference writes are skipped
                var b = new WindowsFfmpegBackend(ffmpeg) { TestCamera = testCamera };
                Capture = b;
                Catalog = b;
            }

            public void SendStatus(string id, string status, string error)
            {
                Console.WriteLine("{\"status\":" + Json.Esc(status) + (error != null ? ",\"error\":" + Json.Esc(error) : "") + "}");
                if (status == "failed") Done.Set();
            }

            public void Deliver(string id, string video, string audio, bool hasTranscript, bool hasSystemAudio, string token, double duration, long partBytes)
            {
                string v = Path.Combine(outDir, id + ".mp4");
                File.Copy(video, v, true);
                // has_audio = a transcription WAV was kept (the server's has_audio: the mic only).
                bool wav = hasTranscript && File.Exists(audio);
                if (wav) File.Copy(audio, Path.Combine(outDir, id + ".wav"), true);
                Console.WriteLine("{\"status\":\"done\",\"video\":" + Json.Esc(v) + ",\"duration_s\":" + duration.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)
                    + ",\"has_audio\":" + (wav ? "true" : "false") + ",\"has_system_audio\":" + (hasSystemAudio ? "true" : "false") + "}");
                Ok = true;
                Done.Set();
            }
        }

        /// Dev check: --record-local SECONDS --out DIR [--window ID|WORDS | --monitor Q] [--webcam] [--camera Q]
        /// [--size small|medium|large|PCT] [--shape circle|rect] [--mic [NAME]] [--system-audio] [--toggle mic@5,sys@6.5]
        /// [--ffmpeg PATH] [--encoder NAME] [--video-path auto|gpu|cpu] [--test-camera] [--no-front] [--below-normal].
        /// Records exactly as a server command would (control pill, bubble, window following,
        /// monitor switches, audio mixing) but keeps the MP4 (and the transcription WAV) in DIR instead of uploading; writes
        /// no config. --toggle presses the pill's mic / PC-sound toggles (same code path as a click) at those seconds after
        /// capture starts. Lines on stdin: "stop", "toggle mic", "toggle sys". Prints JSON status lines.
        static int RecordLocal(string[] args)
        {
            int seconds;
            if (!int.TryParse(Arg(args, "--record-local") ?? "", out seconds)) seconds = 10;
            string outDir = Path.GetFullPath(Arg(args, "--out") ?? ".");
            Directory.CreateDirectory(outDir);
            Log.PathName = Path.Combine(outDir, "agent.log");
            var host = new LocalHost(Arg(args, "--ffmpeg") ?? "ffmpeg.exe", outDir, Array.IndexOf(args, "--test-camera") >= 0);
            ((WindowsFfmpegBackend)host.Capture).NoFront = Array.IndexOf(args, "--no-front") >= 0;
            if (Array.IndexOf(args, "--below-normal") >= 0) WindowsFfmpegBackend.CapturePriority = ProcessPriorityClass.BelowNormal;
            host.Cfg.Encoder = Arg(args, "--encoder");
            host.Cfg.VideoPath = VideoChain.Normalize(Arg(args, "--video-path"));
            string mic = Arg(args, "--mic"), size = Arg(args, "--size"), shape = Arg(args, "--shape");
            int pct;
            if (!int.TryParse(size ?? "", out pct)) pct = 0;
            var o = new Recorder.StartOpts
            {
                Window = Arg(args, "--window"),
                Monitor = Arg(args, "--monitor"),
                Mic = Array.IndexOf(args, "--mic") >= 0,
                MicDevice = mic != null && !mic.StartsWith("--") ? mic : null,
                SystemAudio = Array.IndexOf(args, "--system-audio") >= 0,
                Cam = new Recorder.WebcamOpts
                {
                    On = Array.IndexOf(args, "--webcam") >= 0, Camera = Arg(args, "--camera"), Px = Math.Max(0, WebcamBubble.PxForName(size)),
                    Pct = Math.Max(0, Math.Min(100, pct)), Shape = shape == "rect" || shape == "circle" ? shape : null,
                },
            };
            string id = "local" + DateTime.Now.ToString("yyyyMMddHHmmss");
            var rec = new Recorder(host);
            var toggles = Toggles(Arg(args, "--toggle"));
            rec.Recording += delegate
            {
                var started = Stopwatch.StartNew();
                foreach (var t in toggles)
                {
                    int wait = (int)(t.Value * 1000 - started.ElapsedMilliseconds);
                    if (wait > 0) Thread.Sleep(wait);
                    Console.WriteLine("{\"toggle\":" + Json.Esc(t.Key) + ",\"at_s\":" + t.Value.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture) + "}");
                    rec.Toggle(t.Key);
                }
            };
            var stdin = new Thread(delegate ()
            {
                string line;
                try
                {
                    while ((line = Console.In.ReadLine()) != null)
                    {
                        line = line.Trim();
                        if (line == "stop") rec.Stop(id);
                        else if (line == "toggle mic") rec.Toggle(PillLayout.Mic);
                        else if (line == "toggle sys") rec.Toggle(PillLayout.Sys);
                    }
                }
                catch { }
            });
            stdin.IsBackground = true;
            stdin.Start();
            Log.Write("record-local " + seconds + " s, window " + (o.Window ?? "-") + ", monitor " + (o.Monitor ?? "-"));
            rec.Start(id, seconds, o, "");
            host.Done.WaitOne();
            for (int i = 0; i < 50 && rec.Busy; i++) Thread.Sleep(100); // temp files cleaned up
            return host.Ok ? 0 : 1;
        }

        /// Dev check: --chain-bench WxH[,WxH...] [--encoder NAME] [--video-path auto|gpu|cpu] [--frames N] [--ffmpeg PATH]
        /// [--below-normal]. Any source size (4K, ultrawide, odd) through the recorder's own path choice, filter and encoder
        /// without such a display (WindowsFfmpegBackend.Bench). Prints one JSON line per size.
        static int ChainBench(string[] args)
        {
            if (Array.IndexOf(args, "--below-normal") >= 0) WindowsFfmpegBackend.CapturePriority = ProcessPriorityClass.BelowNormal;
            var b = new WindowsFfmpegBackend(Arg(args, "--ffmpeg") ?? "ffmpeg.exe");
            string enc = b.PickEncoder(Arg(args, "--encoder"));
            var caps = b.ProbeGpu(enc);
            string forced = VideoChain.Normalize(Arg(args, "--video-path"));
            int frames;
            if (!int.TryParse(Arg(args, "--frames") ?? "", out frames)) frames = 300;
            Console.WriteLine("{\"encoder\":" + Json.Esc(enc) + ",\"d3d11_frames\":" + (caps.Native ? "true" : "false") + ",\"scale_d3d11\":" + (caps.Scale ? "true" : "false") + ",\"video_path\":" + Json.Esc(forced) + "}");
            foreach (var s in (Arg(args, "--chain-bench") ?? "").Split(','))
            {
                var wh = s.Trim().Split('x');
                int w, h;
                if (wh.Length != 2 || !int.TryParse(wh[0], out w) || !int.TryParse(wh[1], out h) || w < 16 || h < 16) continue;
                Console.WriteLine(b.Bench(new Size(w, h), enc, caps, forced, frames));
            }
            return 0;
        }

        /// Start-latency test: --start-latency RUNS --out DIR [--seconds S] [--monitor Q] [--webcam] [--camera Q] [--mic [NAME]]
        /// [--system-audio] [--ffmpeg PATH] [--encoder NAME] [--video-path auto|gpu|cpu] [--test-camera] [--below-normal].
        /// Makes RUNS short recordings one after another in one process,
        /// like the agent does (the same Recorder code as a server command; no server, no mouse or keyboard input), and
        /// reads each one's start timing. Prints a JSON line per run, then the command -> first frame median and max. Exit 1
        /// when a run fails, the median is 1.0 s or more or the max 1.5 s or more.
        static int StartLatency(string[] args)
        {
            int runs, seconds;
            if (!int.TryParse(Arg(args, "--start-latency") ?? "", out runs) || runs < 1) runs = 5;
            if (!int.TryParse(Arg(args, "--seconds") ?? "", out seconds) || seconds < 1) seconds = 3;
            string outDir = Path.GetFullPath(Arg(args, "--out") ?? ".");
            Directory.CreateDirectory(outDir);
            Log.PathName = Path.Combine(outDir, "agent.log");
            var host = new LocalHost(Arg(args, "--ffmpeg") ?? "ffmpeg.exe", outDir, Array.IndexOf(args, "--test-camera") >= 0);
            if (Array.IndexOf(args, "--below-normal") >= 0) WindowsFfmpegBackend.CapturePriority = ProcessPriorityClass.BelowNormal;
            host.Cfg.Encoder = Arg(args, "--encoder");
            host.Cfg.VideoPath = VideoChain.Normalize(Arg(args, "--video-path"));
            string mic = Arg(args, "--mic");
            var rec = new Recorder(host);
            StartTimes last = null;
            var timed = new ManualResetEvent(false);
            rec.Timed += delegate (StartTimes t) { last = t; timed.Set(); };
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            var firsts = new List<double>();
            bool allOk = true;
            Log.Write("start-latency " + runs + " runs of " + seconds + " s");
            // What an agent has done long before its first command (Agent.ReportDevices on connect).
            host.Catalog.AudioVideo();
            Recorder.Warm(host.Capture, host.Cfg.Encoder);
            rec.KeepWarm();
            for (int i = 0; i < runs; i++)
            {
                // Idle first, as an agent waiting for its next command.
                Thread.Sleep(2000);
                var o = new Recorder.StartOpts
                {
                    Monitor = Arg(args, "--monitor"),
                    Mic = Array.IndexOf(args, "--mic") >= 0,
                    MicDevice = mic != null && !mic.StartsWith("--") ? mic : null,
                    SystemAudio = Array.IndexOf(args, "--system-audio") >= 0,
                    Cam = new Recorder.WebcamOpts { On = Array.IndexOf(args, "--webcam") >= 0, Camera = Arg(args, "--camera") },
                };
                host.Done.Reset();
                host.Ok = false;
                timed.Reset();
                last = null;
                rec.Start("latency" + (i + 1) + "-" + DateTime.Now.ToString("HHmmss"), seconds, o, "");
                host.Done.WaitOne();
                timed.WaitOne(10000);
                for (int k = 0; k < 100 && rec.Busy; k++) Thread.Sleep(100);
                double ff = last != null ? last.Ms("t_first_frame") : double.NaN;
                bool ok = host.Ok && !double.IsNaN(ff);
                allOk &= ok;
                if (ok) firsts.Add(ff);
                Console.WriteLine("{\"run\":" + (i + 1) + ",\"ok\":" + (ok ? "true" : "false") + ",\"timing\":" + Json.Esc(last != null ? last.Line() : "") + "}");
            }
            firsts.Sort();
            int c = firsts.Count;
            double median = c == 0 ? double.NaN : c % 2 == 1 ? firsts[c / 2] : (firsts[c / 2 - 1] + firsts[c / 2]) / 2, max = c == 0 ? double.NaN : firsts[c - 1];
            bool pass = allOk && median < 1000 && max < 1500;
            string summary = "{\"runs\":" + runs + ",\"cmd_to_first_frame_ms\":[" + string.Join(",", firsts.ConvertAll(x => x.ToString("0", inv))) + "],\"median_ms\":"
                + (c == 0 ? "null" : median.ToString("0", inv)) + ",\"max_ms\":" + (c == 0 ? "null" : max.ToString("0", inv)) + ",\"target\":\"median < 1000, max < 1500\",\"pass\":" + (pass ? "true" : "false") + "}";
            Console.WriteLine(summary);
            Log.Write("start-latency " + summary);
            return pass ? 0 : 1;
        }

        /// "mic@5,sys@6.5" -> [(mic, 5), (sys, 6.5)] in time order; unknown entries are skipped.
        public static List<KeyValuePair<string, double>> Toggles(string spec)
        {
            var l = new List<KeyValuePair<string, double>>();
            foreach (var part in (spec ?? "").Split(','))
            {
                var kv = part.Trim().Split('@');
                double t;
                if (kv.Length == 2 && (kv[0] == PillLayout.Mic || kv[0] == PillLayout.Sys)
                    && double.TryParse(kv[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out t) && t >= 0)
                    l.Add(new KeyValuePair<string, double>(kv[0], t));
            }
            l.Sort((a, b) => a.Value.CompareTo(b.Value));
            return l;
        }

        /// Dev check: --pill-preview SECONDS [--monitor ID|INDEX|primary] [--sources mic,sys|none] [--toggle mic,sys]
        /// [--hover mic|sys|stop] [--shot FILE] [--shot-excluded FILE]. Shows the control pill without a server or recording
        /// (no config written): --toggle presses those toggles once shown (their own code path), --hover shows that
        /// button's hover state and tooltip without moving the mouse. Prints a JSON line once shown (rectangles, capture
        /// mode, window styles, whether the foreground window changed), "stop" if Stop fires, and a last line when it closes.
        /// --shot (test only): turns the capture exclusion off for the screenshot, grabs the pill and its surroundings from
        /// the screen into FILE (PNG), then excludes it again. --shot-excluded grabs the same area first, exclusion on.
        static int PillPreview(string[] args)
        {
            int seconds;
            if (!int.TryParse(Arg(args, "--pill-preview") ?? "", out seconds)) seconds = 10;
            var monitors = new WindowsFfmpegBackend("ffmpeg.exe").Monitors();
            var mon = DeviceMatch.Monitor(monitors, Arg(args, "--monitor")) ?? DeviceMatch.Monitor(monitors, "primary");
            string sources = Arg(args, "--sources") ?? "mic,sys", toggles = Arg(args, "--toggle") ?? "", hover = Arg(args, "--hover");
            string shot = Arg(args, "--shot"), shotOff = Arg(args, "--shot-excluded");
            // A dev tool: errors are printed, never shown as a dialog.
            Application.ThreadException += delegate (object s, ThreadExceptionEventArgs e) { Console.WriteLine("{\"error\":" + Json.Esc(e.Exception.ToString()) + "}"); };
            var p = new ControlPill(new Config(), mon, monitors);
            IntPtr fgBefore = Native.GetForegroundWindow();
            bool stopped = false;
            Func<string> state = delegate
            {
                var r = p.PillBounds;
                var s = p.Geometry.StopButton;
                int ex = Native.ExStyle(p.Handle);
                IntPtr fg = Native.GetForegroundWindow();
                return "\"monitor\":" + Json.Esc(mon.Id) + ",\"x\":" + r.X + ",\"y\":" + r.Y + ",\"w\":" + r.Width + ",\"h\":" + r.Height + ",\"dpi\":" + p.Geometry.Dpi
                    + ",\"work_area\":[" + mon.WorkArea.X + "," + mon.WorkArea.Y + "," + mon.WorkArea.Width + "," + mon.WorkArea.Height + "]"
                    + ",\"stop\":[" + (p.WindowAt.X + s.X) + "," + (p.WindowAt.Y + s.Y) + "," + s.Width + "," + s.Height + "]"
                    + ",\"capture_mode\":" + Json.Esc(p.CaptureMode) + ",\"noactivate\":" + ((ex & 0x08000000) != 0 ? "true" : "false")
                    + ",\"toolwindow\":" + ((ex & 0x80) != 0 ? "true" : "false") + ",\"topmost\":" + ((ex & 0x8) != 0 ? "true" : "false")
                    + ",\"layered\":" + ((ex & 0x80000) != 0 ? "true" : "false") + ",\"is_foreground\":" + (fg == p.Handle ? "true" : "false")
                    + ",\"foreground_unchanged\":" + (fg == fgBefore ? "true" : "false") + ",\"mic_on\":" + (p.MicOn ? "true" : "false") + ",\"sys_on\":" + (p.SysOn ? "true" : "false");
            };
            Func<Rectangle> area = delegate
            {
                var r = Rectangle.Inflate(new Rectangle(p.WindowAt, p.Geometry.Size), 24, 24);
                if (p.Tip != null && p.Tip.Visible) r = Rectangle.Union(r, Rectangle.Inflate(p.Tip.ScreenRect, 12, 12));
                return Rectangle.Intersect(r, mon.Bounds);
            };
            Action<string> grab = delegate (string file)
            {
                var r = area();
                using (var bmp = new Bitmap(r.Width, r.Height))
                {
                    using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.Location, Point.Empty, r.Size, CopyPixelOperation.SourceCopy);
                    bmp.Save(Path.GetFullPath(file), System.Drawing.Imaging.ImageFormat.Png);
                }
            };
            Action<int, Action> after = delegate (int ms, Action a)
            {
                var t = new System.Windows.Forms.Timer { Interval = ms };
                t.Tick += delegate { t.Stop(); t.Dispose(); a(); };
                t.Start();
            };
            p.StopClicked += delegate { stopped = true; Console.WriteLine("stop"); p.Close(); };
            p.Shown += delegate
            {
                p.SetSources(sources.Contains("mic"), sources.Contains("sys"));
                foreach (var t in toggles.Split(',')) if (t == PillLayout.Mic || t == PillLayout.Sys) p.Toggle(t);
                if (hover == PillLayout.Mic || hover == PillLayout.Sys || hover == PillLayout.Stop) p.PreviewHover(hover);
                Console.WriteLine("{\"shown\":true," + state() + "}");
                if (shot != null)
                    after(1500, delegate
                    {
                        if (shotOff != null) grab(shotOff);
                        Native.IncludeInCapture(p.Handle);
                        if (p.Tip != null) Native.IncludeInCapture(p.Tip.Handle);
                        after(300, delegate
                        {
                            grab(shot);
                            string back = Native.ExcludeFromCapture(p.Handle);
                            if (p.Tip != null) Native.ExcludeFromCapture(p.Tip.Handle);
                            Console.WriteLine("{\"shot\":" + Json.Esc(Path.GetFullPath(shot)) + ",\"area\":" + Json.Esc(area().ToString())
                                + ",\"method\":\"test-only --shot: WDA_NONE for the screenshot (CopyFromScreen), then WDA_EXCLUDEFROMCAPTURE again\",\"restored\":" + Json.Esc(back) + "}");
                        });
                    });
                after(seconds * 1000, p.Close);
            };
            p.FormClosing += delegate { Console.WriteLine("{\"closing\":true,\"stopped\":" + (stopped ? "true" : "false") + "," + state() + "}"); };
            p.FormClosed += delegate { Application.ExitThread(); };
            p.Show();
            Application.Run();
            return 0;
        }

        /// Dev check: --webcam-preview SECONDS [--ffmpeg PATH] [--camera NAME|ID] [--size small|medium|large] [--px N]
        /// [--shape circle|rect] [--monitor ID|INDEX|primary] [--no-mirror]. Shows the bubble without a server or recording and without writing
        /// any config. Prints a JSON result line including the bubble's screen rectangle.
        static int WebcamPreview(string[] args)
        {
            int seconds;
            if (!int.TryParse(Arg(args, "--webcam-preview") ?? "", out seconds)) seconds = 10;
            var backend = new WindowsFfmpegBackend(Arg(args, "--ffmpeg") ?? "ffmpeg.exe");
            int px = WebcamBubble.PxForName(Arg(args, "--size"));
            int n;
            if (int.TryParse(Arg(args, "--px") ?? "", out n)) px = WebcamBubble.ClampPx(n);
            var cfg = new Config { Ffmpeg = Arg(args, "--ffmpeg") ?? "ffmpeg.exe", WebcamPx = px > 0 ? px : WebcamBubble.DefaultPx, Mirror = Array.IndexOf(args, "--no-mirror") < 0 };
            var devs = backend.AudioVideo();
            if (devs.Cameras.Count == 0) { Console.WriteLine("{\"ok\":false,\"error\":\"no camera\"}"); return 1; }
            var cam = DeviceMatch.Av(devs.Cameras, Arg(args, "--camera")) ?? devs.Cameras[0];
            var monitors = backend.Monitors();
            var mon = DeviceMatch.Monitor(monitors, Arg(args, "--monitor")) ?? DeviceMatch.Monitor(monitors, "primary");
            var b = new WebcamBubble(cfg, backend, devs.Cameras, cam, cfg.WebcamPx, Arg(args, "--shape") == "rect", mon.Bounds, mon.WorkArea);
            var sw = Stopwatch.StartNew();
            long firstMs = -1;
            Rectangle rect = Rectangle.Empty;
            b.Shown += delegate
            {
                firstMs = sw.ElapsedMilliseconds;
                rect = b.Bounds;
                var t = new System.Windows.Forms.Timer { Interval = seconds * 1000 };
                t.Tick += delegate { t.Stop(); rect = b.Bounds; b.Shutdown(); };
                t.Start();
            };
            b.FormClosed += delegate { Application.ExitThread(); };
            b.StartCamera();
            var watchdog = new System.Windows.Forms.Timer { Interval = 10000 };
            watchdog.Tick += delegate { watchdog.Stop(); if (firstMs < 0) { b.Shutdown(); Application.ExitThread(); } };
            watchdog.Start();
            Application.Run();
            Console.WriteLine("{\"ok\":" + (firstMs >= 0 ? "true" : "false") + ",\"camera\":" + Json.Esc(cam.Name) + ",\"first_frame_ms\":" + firstMs
                + ",\"monitor\":" + mon.Index + ",\"x\":" + rect.X + ",\"y\":" + rect.Y + ",\"side\":" + rect.Width + ",\"w\":" + rect.Width + ",\"h\":" + rect.Height
                + ",\"shape\":" + Json.Esc(b.IsRect ? "rect" : "circle") + ",\"dpi_awareness\":" + Json.Esc(Native.DpiMode)
                + (b.LastError.Length > 0 ? ",\"error\":" + Json.Esc(b.LastError) : "") + "}");
            return firstMs >= 0 ? 0 : 1;
        }

        static MonitorInfo FakeMonitor(int index, string name, string friendly, bool primary, int x, int w, int h)
        {
            return new MonitorInfo
            {
                Index = index, OutputIdx = index, DeviceName = name, FriendlyName = friendly, Primary = primary,
                Bounds = new Rectangle(x, 0, w, h), WorkArea = new Rectangle(x, 0, w, h - 40), Id = DeviceMatch.StableId("mon", name),
            };
        }

        /// Offline checks: command verification (shared vectors with the worker tests), click-vs-drag, device matching,
        /// placement, bubble geometry and argument quoting.
        static int SelfTest()
        {
            int fails = 0;
            Action<string, bool> check = delegate (string name, bool ok) { Console.WriteLine((ok ? "ok   " : "FAIL ") + name); if (!ok) fails++; };
            var f = new Dictionary<string, string>
            {
                { "type", "start" }, { "recording_id", "AAAAAAAAAAAAAAAAAAAAAA" }, { "max_seconds", "30" }, { "mic", "false" },
                { "nonce", "1731650000000" }, { "exp", "1731650060" }, { "account_id", "BBBBBBBBBBBBBBBBBBBBBB" },
                { "device_id", "CCCCCCCCCCCCCCCCCCCCCC" }, { "upload_token", "1731651800.tok" },
            };
            const string vector = "91b21b4b501c2352952e2591e8c7d738ae9d653f27672744673c47e824d1adfc";
            check("canonical hmac matches worker vector", CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(f)) == vector);
            f["mac"] = vector;
            var v = new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null);
            check("valid command accepted", v.Verify(f, 1731650000) == null);
            check("replayed command rejected", v.Verify(f, 1731650000) == "replayed nonce");
            var v2 = new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null);
            check("expired command rejected", v2.Verify(f, 1731650061) == "expired");
            var v3 = new CommandVerifier("OTHERACCOUNTxxxxxxxxxx", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null);
            check("other account rejected", v3.Verify(f, 1731650000) == "wrong account");
            var forged = new Dictionary<string, string>(f);
            forged["max_seconds"] = "120";
            check("tampered command rejected", v2.Verify(forged, 1731650000) == "bad mac");
            var v4 = new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "wrong-secret", null);
            check("wrong key rejected", v4.Verify(f, 1731650000) == "bad mac");
            var cam = new Dictionary<string, string>(f);
            cam.Remove("mac");
            cam["webcam"] = "true"; cam["camera"] = "Full HD webcam"; cam["webcam_size"] = "large";
            check("webcam canonical hmac matches worker vector",
                CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(cam)) == "21d8fbbc60cf22ee8ddb9d83b5cf0664f021b7e099c36cd17384af0974311809");
            var stripped = new Dictionary<string, string>(cam);
            stripped["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(cam));
            stripped.Remove("webcam");
            var v5 = new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null);
            check("tampered webcam field rejected", v5.Verify(stripped, 1731650000) == "bad mac");

            // Device parameters (monitor, mic_device) are signed in their own block, only when present.
            var dev = new Dictionary<string, string>(cam);
            dev["monitor"] = "mon_0123456789"; dev["mic_device"] = "Microphone (HyperX Cloud Alpha Wireless)";
            check("device-param canonical form", CommandVerifier.Canonical(dev).EndsWith("|cam|1|Full HD webcam|large|dev|mon_0123456789|Microphone (HyperX Cloud Alpha Wireless)"));
            check("device-param canonical hmac matches worker vector",
                CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(dev)) == "7973edc38381ad4e225e490d13e4cfd498e6ec3ebd84ed027f3c603aabbe2d73");
            var devOnly = new Dictionary<string, string>(f);
            devOnly.Remove("mac");
            devOnly["monitor"] = "1";
            check("device block without webcam block", CommandVerifier.Canonical(devOnly).EndsWith("|1731651800.tok|dev|1|"));
            dev["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(dev));
            var v6 = new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null);
            var swapped = new Dictionary<string, string>(dev);
            swapped["monitor"] = "0";
            check("tampered monitor rejected", v6.Verify(swapped, 1731650000) == "bad mac");
            var dropped = new Dictionary<string, string>(dev);
            dropped.Remove("mic_device");
            check("dropped mic_device rejected", v6.Verify(dropped, 1731650000) == "bad mac");
            check("signed device params accepted", v6.Verify(dev, 1731650000) == null);

            // Control pill: drag threshold vs Stop.
            var pl = new PillLayout(96);
            var stop = pl.StopButton;
            Point sIn = new Point(stop.X + stop.Width / 2, stop.Y + stop.Height / 2), timer = new Point(pl.Timer.X + 4, pl.Timer.Y + pl.Timer.Height / 2);
            var g = new ClickGesture();
            g.Down(new Point(1000, 500)); g.Move(new Point(1002, 501));
            bool c1 = g.Up(new Point(1002, 501));
            check("stop: click on Stop (2 px jitter) stops", pl.ClickTarget(c1, sIn, new Point(sIn.X + 2, sIn.Y + 1)) == PillLayout.Stop);
            g.Down(new Point(1000, 500)); g.Move(new Point(1040, 520)); g.Move(new Point(1001, 500));
            bool c2 = g.Up(new Point(1000, 500));
            check("stop: drag away and back onto Stop never stops", !c2 && g.Dragging && pl.ClickTarget(c2, sIn, sIn) == null);
            g.Down(new Point(1000, 500));
            bool c3 = g.Up(new Point(1004, 500));
            check("stop: exactly 4 px is a drag", !c3 && g.Dragging);
            g.Down(new Point(1000, 500));
            bool c4 = g.Up(new Point(1003, 502));
            check("stop: 3.6 px is still a click", c4 && !g.Dragging);
            g.Down(new Point(1000, 500));
            bool c5 = g.Up(new Point(1000, 500));
            check("stop: press outside Stop, release on it does not stop", pl.ClickTarget(c5, timer, sIn) == null);
            check("stop: press on Stop, release outside does not stop", pl.ClickTarget(c5, sIn, timer) == null);
            check("gesture: move without press is not a drag", !new ClickGesture().Move(new Point(50, 50)));

            // Device matching (same rules as worker/src/devices.ts).
            var ms = new List<MonitorInfo>
            {
                FakeMonitor(0, "\\\\.\\DISPLAY2", "LG ULTRAGEAR", true, 0, 2560, 1440),
                FakeMonitor(1, "\\\\.\\DISPLAY1", "DELL S2421H", false, 2560, 1920, 1080),
            };
            DeviceMatch.Label(ms);
            check("monitor labels", ms[0].Label == "left" && ms[1].Label == "right" && ms[1].Rank == 1);
            check("monitor: primary / main / empty", DeviceMatch.Monitor(ms, "primary") == ms[0] && DeviceMatch.Monitor(ms, "Main") == ms[0] && DeviceMatch.Monitor(ms, null) == ms[0]);
            check("monitor: index", DeviceMatch.Monitor(ms, "1") == ms[1] && DeviceMatch.Monitor(ms, "7") == null);
            check("monitor: id", DeviceMatch.Monitor(ms, ms[1].Id) == ms[1]);
            check("monitor: device name", DeviceMatch.Monitor(ms, "\\\\.\\DISPLAY1") == ms[1] && DeviceMatch.Monitor(ms, "display2") == ms[0]);
            check("monitor: left/right", DeviceMatch.Monitor(ms, "RIGHT") == ms[1] && DeviceMatch.Monitor(ms, "left") == ms[0]);
            check("monitor: second/other", DeviceMatch.Monitor(ms, "second") == ms[1] && DeviceMatch.Monitor(ms, "other") == ms[1]);
            check("monitor: model name part", DeviceMatch.Monitor(ms, "dell") == ms[1] && DeviceMatch.Monitor(ms, "samsung") == null);
            var three = new List<MonitorInfo>
            {
                FakeMonitor(0, "\\\\.\\DISPLAY1", null, true, 0, 1920, 1080),
                FakeMonitor(1, "\\\\.\\DISPLAY2", null, false, -1920, 1920, 1080),
                FakeMonitor(2, "\\\\.\\DISPLAY3", null, false, 1920, 1920, 1080),
            };
            DeviceMatch.Label(three);
            check("three monitors: left/center/right", three[1].Label == "left" && three[0].Label == "center" && three[2].Label == "right");
            check("three monitors: 'second' is ambiguous", DeviceMatch.Monitor(three, "second") == null);
            var dshow = "[in#0 @ 0] \"Full HD webcam\" (video)\r\n[in#0 @ 0]   Alternative name \"@device_pnp_\\\\?\\usb#vid_1bcf\\global\"\r\n"
                + "[in#0 @ 0] \"OBS Virtual Camera\" (none)\r\n[in#0 @ 0]   Alternative name \"@device_sw_{860BB310}\\{A3FCE0F5}\"\r\n"
                + "[in#0 @ 0] \"Microphone (HyperX Cloud Alpha Wireless)\" (audio)\r\n[in#0 @ 0]   Alternative name \"@device_cm_{33D9}\\wave_{E8E2}\"\r\n"
                + "[in#0 @ 0] \"Microphone (Realtek(R) Audio)\" (audio)\r\n[in#0 @ 0] \"Capture card\" (audio, video)\r\n";
            var av = DeviceMatch.ParseDshow(dshow);
            check("dshow parse", av.Cameras.Count == 3 && av.Mics.Count == 3 && av.Cameras[0].Path == "@device_pnp_\\\\?\\usb#vid_1bcf\\global"
                && av.Cameras[2].Name == "OBS Virtual Camera" && av.Mics[1].Path == null && av.Mics[0].Id.StartsWith("mic_") && av.Cameras[0].Id.StartsWith("cam_"));
            DeviceMatch.MarkDefaultMic(av.Mics, "Microphone (HyperX Cloud Alpha Wireless)");
            check("default mic marked", av.Mics[0].IsDefault && !av.Mics[1].IsDefault);
            DeviceMatch.MarkDefaultMic(av.Mics, "Microphone (Realtek(R) Audio) with a long name");
            check("default mic matches a 31-char dshow name", av.Mics[1].IsDefault);
            check("mic: brand part", DeviceMatch.Av(av.Mics, "hyperx") == av.Mics[0] && DeviceMatch.Av(av.Mics, "HyperX Cloud") == av.Mics[0]);
            check("mic: ambiguous part", DeviceMatch.Av(av.Mics, "microphone") == null);
            check("mic: id / exact name / unknown", DeviceMatch.Av(av.Mics, av.Mics[1].Id) == av.Mics[1]
                && DeviceMatch.Av(av.Mics, "microphone (realtek(r) audio)") == av.Mics[1] && DeviceMatch.Av(av.Mics, "Blue Yeti") == null && DeviceMatch.Av(av.Mics, "") == null);
            check("camera: injected name is not in the inventory", DeviceMatch.Av(av.Cameras, "x\" -f lavfi -i \"evil") == null);
            check("stable ids", DeviceMatch.StableId("cam", "ABC") == DeviceMatch.StableId("cam", "abc") && DeviceMatch.StableId("cam", "a").Length == 14);
            // Windows: same fixture and rules as worker/test/devices.test.ts ("matching windows").
            Func<int, string, string, string, WindowInfo> W = delegate (int hwnd, string app, string exe, string title)
            {
                return new WindowInfo
                {
                    Hwnd = (IntPtr)hwnd, Pid = 100 + hwnd, App = app, Exe = exe, Title = title, MonitorId = ms[0].Id,
                    Id = DeviceMatch.WindowId((IntPtr)hwnd, 100 + hwnd, exe), Bounds = new Rectangle(100, 100, 1280, 800),
                };
            };
            var wins = new List<WindowInfo>
            {
                W(0x10, "Google Chrome", "chrome.exe", "YouTube - Google Chrome"),
                W(0x20, "Google Chrome", "chrome.exe", "Inbox (3) - Gmail - Google Chrome"),
                W(0x30, "Notepad", "Notepad.exe", "notes.txt - Notepad"),
                W(0x40, "Notepad", "Notepad.exe", "todo.txt - Notepad"),
                W(0x50, "Zoom Workplace", "Zoom.exe", "Zoom Meeting"),
            };
            check("window: 'chrome youtube' = app AND title", DeviceMatch.Window(wins, "chrome youtube") == wins[0] && DeviceMatch.Window(wins, "the youtube window") == wins[0]);
            check("window: 'chrome' / 'that notepad' are ambiguous", DeviceMatch.Window(wins, "chrome") == null && DeviceMatch.Window(wins, "that notepad") == null);
            check("window: 'notepad todo' / 'zoom' / exe + title", DeviceMatch.Window(wins, "notepad todo") == wins[3] && DeviceMatch.Window(wins, "Zoom") == wins[4]
                && DeviceMatch.Window(wins, "Chrome.EXE gmail") == wins[1]);
            check("window: id and exact title", DeviceMatch.Window(wins, wins[2].Id) == wins[2] && DeviceMatch.Window(wins, "NOTES.TXT - NOTEPAD") == wins[2]);
            check("window: unknown / filler only / empty", DeviceMatch.Window(wins, "slack") == null && DeviceMatch.Window(wins, "chrome slack") == null
                && DeviceMatch.Window(wins, "the window") == null && DeviceMatch.Window(wins, "") == null);
            check("window ids", wins[0].Id.StartsWith("win_") && wins[0].Id.Length == 14 && wins[0].Id != wins[1].Id
                && DeviceMatch.WindowId((IntPtr)0x10, 116, "CHROME.EXE") == wins[0].Id && DeviceMatch.WindowId((IntPtr)0x10, 117, "chrome.exe") != wins[0].Id);
            var wf = new Dictionary<string, string>(f);
            wf.Remove("mac");
            wf["webcam"] = "true"; wf["window"] = "win_0123456789";
            check("window canonical form", CommandVerifier.Canonical(wf).EndsWith("|1731651800.tok|cam|1|||win|win_0123456789"));
            check("window canonical hmac matches worker vector",
                CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(wf)) == "19642c756a0de3d60eb9372be9fd332f66affe9ec189c7d198d64e4f773770fa");
            wf["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(wf));
            var v7 = new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null);
            var otherWin = new Dictionary<string, string>(wf);
            otherWin["window"] = "win_9999999999";
            var noWin = new Dictionary<string, string>(wf);
            noWin.Remove("window");
            check("tampered / dropped window rejected", v7.Verify(otherWin, 1731650000) == "bad mac" && v7.Verify(noWin, 1731650000) == "bad mac");
            check("signed window accepted", v7.Verify(wf, 1731650000) == null);

            check("window output size", WindowTrack.OutputSize(new Size(1280, 800)) == new Size(1280, 800)
                && WindowTrack.OutputSize(new Size(2560, 1400)) == new Size(1920, 1050) && WindowTrack.OutputSize(new Size(1001, 333)) == new Size(1000, 332));
            check("window: mostly on", WindowTrack.MostlyOn(ms, new Rectangle(2400, 100, 800, 600)) == ms[1]
                && Math.Abs(WindowTrack.Share(new Rectangle(2400, 100, 800, 600), ms[1].Bounds) - 0.8) < 1e-9 && WindowTrack.MostlyOn(ms, new Rectangle(-900, 0, 800, 600)) == null);
            var monR = new Rectangle(2560, 218, 1920, 1080);
            var v0 = WindowTrack.View(new Rectangle(2660, 318, 800, 600), false, true, monR, new WindowView());
            var vPart = WindowTrack.View(new Rectangle(4000, 318, 800, 600), false, true, monR, v0);
            var vMin = WindowTrack.View(new Rectangle(2660, 318, 800, 600), true, true, monR, v0);
            var vMoved = WindowTrack.View(new Rectangle(2670, 323, 800, 600), false, true, monR, v0);
            check("window view: monitor-relative crop", !v0.Blank && v0.Crop == new Rectangle(100, 100, 800, 600));
            check("window view: partly off the monitor = visible part", !vPart.Blank && vPart.Crop == new Rectangle(1440, 100, 480, 600));
            check("window view: minimized = black, crop kept", vMin.Blank && vMin.Crop == v0.Crop);
            check("window view: off this monitor / closed = black", WindowTrack.View(new Rectangle(0, 0, 800, 600), false, true, monR, v0).Blank
                && WindowTrack.View(new Rectangle(2660, 318, 800, 600), false, false, monR, v0).Blank);
            Func<WindowView, WindowView, string> cmds = delegate (WindowView a, WindowView b) { return string.Join(";", WindowTrack.Commands(a, b)); };
            check("window commands: move sends x,y only", cmds(v0, vMoved) == "crop@win -1 x 110;crop@win -1 y 105");
            check("window commands: resize at the edge", cmds(v0, vPart) == "crop@win -1 w 480;crop@win -1 x 1440");
            check("window commands: hide first, show last, nothing when unchanged", cmds(v0, vMin) == "drawbox@hide -1 x 0" && cmds(vMin, v0) == "drawbox@hide -1 x iw"
                && cmds(vMin, vPart) == "crop@win -1 w 480;crop@win -1 x 1440;drawbox@hide -1 x iw" && cmds(v0, v0) == "");
            string wfilter = WindowTrack.Filter(v0, new Size(800, 600));
            check("window filter", wfilter.StartsWith("crop@win=w=800:h=600:x=100:y=100,pad=w='max(iw\\,ceil(ih*800/600))':h='max(ih\\,ceil(iw*600/800))'")
                && wfilter.Contains(":eval=frame,scale=800:600:")
                && wfilter.EndsWith("drawbox@hide=x=iw:y=0:w=iw:h=ih:color=black:t=fill"));

            // Video path per source size: GPU first, cpu always last; never a fixed resolution.
            var nv = new GpuCaps { Native = true, Scale = false };
            var all = new GpuCaps { Native = true, Scale = true };
            Func<Size, bool, bool, string, string, GpuCaps, string> paths = delegate (Size s, bool win, bool dd, string enc, string forced, GpuCaps c)
            { return string.Join(",", VideoChain.Candidates(s, win, dd, enc, forced, c)); };
            check("video path: fits 1080p = gpu as is, then cpu", paths(new Size(1920, 1080), false, true, "h264_nvenc", "auto", all) == "gpu,cpu"
                && paths(new Size(1280, 720), false, true, "h264_qsv", "auto", all) == "gpu,cpu");
            check("video path: bigger than 1080p = gpu-scale, then gpu at its own size, then cpu",
                paths(new Size(2560, 1440), false, true, "h264_amf", "auto", all) == "gpu-scale,gpu,cpu" && paths(new Size(3840, 2160), false, true, "h264_nvenc", "gpu", all) == "gpu-scale,gpu,cpu");
            check("video path: no GPU scaler (NVIDIA, ffmpeg 9.0.2) = gpu at its own size up to 4096",
                paths(new Size(2560, 1440), false, true, "h264_nvenc", "auto", nv) == "gpu,cpu" && paths(new Size(3440, 1440), false, true, "h264_nvenc", "auto", nv) == "gpu,cpu"
                && paths(new Size(3840, 2160), false, true, "h264_nvenc", "auto", nv) == "gpu,cpu" && paths(new Size(5120, 1440), false, true, "h264_nvenc", "auto", nv) == "cpu");
            check("video path: ultrawide past 4096 scales on the GPU when it can", paths(new Size(5120, 1440), false, true, "h264_nvenc", "auto", all) == "gpu-scale,cpu");
            check("video path: cpu for window crops, gdigrab, software encoders, no D3D11 input, or video_path=cpu",
                paths(new Size(2560, 1440), true, true, "h264_nvenc", "auto", all) == "cpu" && paths(new Size(2560, 1440), false, false, "h264_nvenc", "auto", all) == "cpu"
                && paths(new Size(2560, 1440), false, true, "libx264", "auto", all) == "cpu" && paths(new Size(2560, 1440), false, true, "h264_mf", "auto", all) == "cpu"
                && paths(new Size(2560, 1440), false, true, "h264_nvenc", "auto", new GpuCaps()) == "cpu" && paths(new Size(2560, 1440), false, true, "h264_nvenc", "cpu", all) == "cpu");
            check("video path: setting values", VideoChain.Normalize(" GPU ") == "gpu" && VideoChain.Normalize("cpu") == "cpu" && VideoChain.Normalize("fast") == "auto" && VideoChain.Normalize(null) == "auto");
            check("video path: output sizes", VideoChain.Output("gpu", new Size(5120, 1440)) == new Size(5120, 1440) && VideoChain.Output("gpu-scale", new Size(5120, 1440)) == new Size(1920, 540)
                && VideoChain.Output("cpu", new Size(3840, 2160)) == new Size(1920, 1080) && VideoChain.Output("cpu", new Size(3440, 1440)) == new Size(1920, 802)
                && VideoChain.Output("cpu", new Size(1366, 768)) == new Size(1366, 768) && VideoChain.Output("cpu", new Size(1281, 721)) == new Size(1280, 720));
            check("video path: filters", VideoChain.Filter("gpu", new Size(2560, 1440), true, "h264_nvenc") == ""
                && VideoChain.Filter("gpu", new Size(2560, 1440), true, "h264_amf") == ""
                && VideoChain.Filter("gpu", new Size(2560, 1440), true, "h264_qsv") == "hwmap=derive_device=qsv,format=qsv"
                && VideoChain.Filter("gpu-scale", new Size(1920, 1080), true, "h264_nvenc") == "scale_d3d11=width=1920:height=1080:format=nv12"
                && VideoChain.Filter("gpu-scale", new Size(1920, 1080), true, "h264_qsv") == "scale_d3d11=width=1920:height=1080:format=nv12,hwmap=derive_device=qsv,format=qsv"
                && VideoChain.Filter("cpu", new Size(1920, 1080), true, "h264_qsv") == "hwdownload,format=bgra,scale=1920:1080:flags=fast_bilinear,format=nv12"
                && VideoChain.Filter("cpu", new Size(1920, 1080), false, "libx264") == "scale=1920:1080:flags=fast_bilinear,format=nv12");
            string nvOpts = WindowsFfmpegBackend.Options("h264_nvenc");
            check("video path: bitrate cap rises above 1080p only", VideoChain.EncoderOptions(nvOpts, new Size(1920, 1080)) == nvOpts
                && VideoChain.EncoderOptions(nvOpts, new Size(2560, 1440)).Contains("-b:v 4500k -maxrate 5000k -bufsize 10000k")
                && VideoChain.EncoderOptions(WindowsFfmpegBackend.Options("libx264"), new Size(2560, 1440)).Contains("-maxrate 5000k -bufsize 10000k"));

            string json = DeviceMatch.InventoryJson("r1", ms, av, wins);
            check("inventory json", json.StartsWith("{\"type\":\"devices\",\"request_id\":\"r1\",\"monitors\":[{\"id\":\"mon_")
                && json.Contains("\"name\":\"\\\\\\\\.\\\\DISPLAY2\"") && json.Contains("\"label\":\"right\"") && json.Contains("\"default\":true") && json.EndsWith("}]}")
                && json.Contains(",\"windows\":[{\"id\":\"win_") && json.Contains("\"app\":\"Google Chrome\",\"exe\":\"chrome.exe\",\"title\":\"YouTube - Google Chrome\",\"monitor\":\"mon_"));

            // Webcam sizes and placement.
            check("webcam sizes", WebcamBubble.PxForName("small") == 160 && WebcamBubble.PxForName("medium") == 240 && WebcamBubble.PxForName("large") == 360
                && WebcamBubble.PxForName("huge") < 0 && WebcamBubble.PxForName(null) < 0);
            check("webcam px clamp", WebcamBubble.ClampPx(1000) == 480 && WebcamBubble.ClampPx(10) == 120 && WebcamBubble.ClampPx(300) == 300);
            var screens = new List<Rectangle> { new Rectangle(0, 0, 2560, 1440), new Rectangle(2560, 218, 1920, 1080) };
            var def = new Point(2300, 1350);
            check("placement: saved spot on a connected monitor", Displays.Restore(screens, 3000, 600, new Size(236, 52), def) == new Point(3000, 600));
            check("placement: half off-screen is pulled inside", Displays.Restore(screens, 4300, 600, new Size(236, 52), def) == new Point(4480 - 236, 600));
            check("placement: unplugged monitor falls back to default", Displays.Restore(screens, 6000, 600, new Size(236, 52), def) == def);
            check("placement: nothing saved uses default", Displays.Restore(screens, null, 5, new Size(236, 52), def) == def);
            check("placement: remap keeps the relative corner",
                Displays.Remap(new Point(24, 1440 - 240 - 24), new Size(240, 240), screens[0], screens[1]) == new Point(2560 + 17, 218 + 823));

            // Bubble geometry: hard-coded expectations of the anti-aliased mask and the opaque ring.
            int side = 240;
            var mask = new byte[side * side];
            var ring = new byte[side * side];
            BubbleSurface.Geometry(side, 3f, mask, ring);
            check("bubble: corners transparent, centre opaque camera", mask[0] == 0 && mask[side * side - 1] == 0 && mask[120 * side + 120] == 255 && ring[120 * side + 120] == 0);
            check("bubble: ring opaque across its width", ring[120 * side + 1] == 255 && ring[120 * side + 2] == 255 && mask[120 * side + 1] == 255);
            check("bubble: edge anti-aliased", mask[120 * side + 0] > 0 && mask[120 * side + 0] < 255);
            bool sym = true;
            for (int i = 0; i < side * side; i++) { int x = i % side, y = i / side; if (mask[i] != mask[y * side + (side - 1 - x)] || ring[i] != ring[(side - 1 - y) * side + x]) sym = false; }
            check("bubble: mask and ring symmetric", sym);

            // Rectangle shape: 16:9, 12 % corner radius, ring along the whole outline (straight edges and corner arcs).
            check("bubble sizes: circle diameter / 16:9 rectangle 3/4 of the size high", WebcamBubble.SizeFor(240, 96, false) == new Size(240, 240)
                && WebcamBubble.SizeFor(240, 96, true) == new Size(320, 180) && WebcamBubble.SizeFor(240, 192, true) == new Size(640, 360)
                && WebcamBubble.SizeFor(WebcamBubble.MinPx, 120, true) == new Size(200, 112) && WebcamBubble.SizeFor(WebcamBubble.MaxPx, 96, true) == new Size(640, 360));
            check("webcam_size percent of the monitor's short side", WebcamBubble.PxForPercent(25, new Size(2560, 1440), 96, false) == 360
                && WebcamBubble.PxForPercent(25, new Size(2560, 1440), 96, true) == 480 && WebcamBubble.PxForPercent(25, new Size(3840, 2160), 192, false) == 270
                && WebcamBubble.PxForPercent(1, new Size(1920, 1080), 96, false) == WebcamBubble.MinPx && WebcamBubble.PxForPercent(100, new Size(1920, 1080), 96, false) == WebcamBubble.MaxPx);
            foreach (int rdpi in new[] { 96, 144, 192 })
            {
                var rs = WebcamBubble.SizeFor(240, rdpi, true);
                int rw = rs.Width, rh = rs.Height;
                float ringW = Math.Max(2f, (float)Math.Round(3 * rdpi / 96f)), rr = BubbleSurface.CornerRadius(rh);
                var rmask = new byte[rw * rh];
                var rring = new byte[rw * rh];
                BubbleSurface.Geometry(rw, rh, ringW, true, rmask, rring);
                string at = " @" + (rdpi * 100 / 96) + "% (" + rw + "x" + rh + ")";
                check("rect bubble" + at + ": corners transparent, centre opaque camera", rmask[0] == 0 && rmask[rw - 1] == 0 && rmask[(rh - 1) * rw] == 0 && rmask[rw * rh - 1] == 0
                    && rmask[2 * rw + 2] == 0 && rmask[(rh / 2) * rw + rw / 2] == 255 && rring[(rh / 2) * rw + rw / 2] == 0);
                bool edges = true;
                for (int x = (int)rr + 2; x < rw - rr - 2; x++) edges &= rring[1 * rw + x] == 255 && rring[(rh - 2) * rw + x] == 255 && rmask[1 * rw + x] == 255;
                for (int y = (int)rr + 2; y < rh - rr - 2; y++) edges &= rring[y * rw + 1] == 255 && rring[y * rw + rw - 2] == 255;
                check("rect bubble" + at + ": ring opaque along the straight edges", edges);
                bool arc = true;
                for (int deg = 0; deg <= 90; deg += 5)
                {
                    double a = deg * Math.PI / 180, ccx = rr, ccy = rr, rad = rr - 0.5 - ringW / 2;
                    int x = (int)Math.Floor(ccx - Math.Cos(a) * rad), y = (int)Math.Floor(ccy - Math.Sin(a) * rad);
                    arc &= rring[y * rw + x] >= 200 && rmask[y * rw + x] >= 200;
                }
                check("rect bubble" + at + ": ring follows the rounded corners", arc);
                bool rsym = true, aa = false;
                for (int i = 0; i < rw * rh; i++)
                {
                    int x = i % rw, y = i / rw;
                    if (rmask[i] != rmask[y * rw + (rw - 1 - x)] || rring[i] != rring[(rh - 1 - y) * rw + x]) rsym = false;
                    if (rmask[i] > 0 && rmask[i] < 255) aa = true;
                }
                check("rect bubble" + at + ": symmetric, anti-aliased edge", rsym && aa);
            }
            var circleViaRect = new byte[side * side];
            var circleRing = new byte[side * side];
            BubbleSurface.Geometry(side, side, 3f, false, circleViaRect, circleRing);
            bool same = true;
            for (int i = 0; i < side * side; i++) same &= circleViaRect[i] == mask[i] && circleRing[i] == ring[i];
            check("bubble: circle geometry unchanged by the shape refactor", same);

            ControlsSelfTest(check);
            AudioSelfTest(check, f);
            ChunkedSelfTest(check, f);
            SelfUpdateSelfTest(check);
            SelfUninstallSelfTest(check);
            MultiAccountSelfTest(check);
            FastStartSelfTest(check);
            StillsSelfTest(check);

            check("quote arg", Native.QuoteArg("audio=@device_cm_{33}\\wave_{E8}") == "\"audio=@device_cm_{33}\\wave_{E8}\""
                && Native.QuoteArg("a\"b") == "\"a\\\"b\"" && Native.QuoteArg("c:\\dir\\") == "\"c:\\dir\\\\\"");
            var parsed = Json.ParseFlat("{\"a\":\"x\\\"y\",\"b\":12,\"c\":true,\"d\":null}");
            check("json parse", parsed["a"] == "x\"y" && parsed["b"] == "12" && parsed["c"] == "true" && parsed["d"] == null);

            // Enroll body: platform always, device_token only on a re-pair (placeholder token, never a real one).
            foreach (var none in new string[] { null, "" })
            {
                var first = Json.ParseFlat(EnrollBody("ABCD1234", "Office PC", none));
                check("enroll body first pair (" + (none == null ? "null" : "empty") + " token): code, name, platform windows, no device_token key",
                    first["code"] == "ABCD1234" && first["name"] == "Office PC" && first["platform"] == "windows" && !first.ContainsKey("device_token")
                    && !EnrollBody("ABCD1234", "Office PC", none).Contains("device_token"));
            }
            var repair = Json.ParseFlat(EnrollBody("ABCD1234", "Office PC", "fake-token-placeholder"));
            check("enroll body re-pair: device_token and platform windows",
                repair["device_token"] == "fake-token-placeholder" && repair["platform"] == "windows" && repair["code"] == "ABCD1234");
            check("enroll body: name cut to 64", Json.ParseFlat(EnrollBody("ABCD1234", new string('n', 80), null))["name"] == new string('n', 64));
            return fails == 0 ? 0 : 1;
        }

        /// ffmpeg -i listings (trimmed from ffmpeg 9 output) for Stills.Probe.
        const string ProbeVideo = "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'v.mp4':\n  Duration: 00:01:02.50, start: 0.000000, bitrate: 6530 kb/s\n"
            + "  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1920x1080, 30 fps (default)\n"
            + "  Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, mono, fltp, 69 kb/s (default)\nAt least one output file must be specified\n";
        const string ProbeAudio = "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'a.m4a':\n  Duration: 00:00:30.00, start: 0.000000, bitrate: 73 kb/s\n"
            + "  Stream #0:0[0x1](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, mono, fltp, 69 kb/s (default)\n"
            + "  Stream #0:1: Video: mjpeg (Baseline), yuvj420p, 600x600, 90k tbn (attached pic)\nAt least one output file must be specified\n";

        /// End-of-recording keyframes (Stills, hello "keyframes"): frame times, the skips (short, audio only), the PUT
        /// policy (404/501 = not supported, quietly; other failures logged; never throws), with fake probes, grabs and
        /// PUTs. With an ffmpeg on PATH (or AGENT_RECORDER_SELFTEST_FFMPEG), the real grab on sandbox MP4s too.
        static void StillsSelfTest(Action<string, bool> check)
        {
            var t60 = Stills.Times(60);
            check("keyframes: times are the centres of 6 equal buckets (60 s -> 5, 15, 25, 35, 45, 55 s)", string.Join(",", t60) == "5000,15000,25000,35000,45000,55000");
            bool spaced = true;
            foreach (double d in new[] { 2.0, 2.5, 7.3, 61.25, 119.9, 1800 })
            {
                var t = Stills.Times(d);
                long ms = (long)Math.Floor(d * 1000), step = (long)Math.Floor(d * 1000 / 6);
                spaced &= t.Count == 6 && t[0] > 0 && t[5] < ms;
                for (int i = 1; i < t.Count; i++) spaced &= Math.Abs(t[i] - t[i - 1] - d * 1000 / 6) <= 1;
                spaced &= Math.Abs(t[0] - d * 1000 / 12) <= 1 && Math.Abs(ms - t[5] - d * 1000 / 12) <= 1 && step > 0;
            }
            check("keyframes: 6 times, evenly spaced (duration / 6), in range, never 0 and never the exact end (half a bucket from each)", spaced);
            check("keyframes: 2.0 s exactly -> 166, 500, 833, 1166, 1500, 1833 ms", string.Join(",", Stills.Times(2.0)) == "166,500,833,1166,1500,1833");
            check("keyframes: shorter than 2 s (or unknown) -> no times, skipped",
                Stills.Times(1.999).Count == 0 && Stills.Times(0).Count == 0 && Stills.Times(double.NaN).Count == 0
                && Stills.Skip(1.999, true) == "shorter than 2 s" && Stills.Skip(double.NaN, true) != null && Stills.Skip(2.0, true) == null);

            double s; bool v;
            Stills.Probe(ProbeVideo, out s, out v);
            check("keyframes: probe reads the duration and the video stream", v && Math.Abs(s - 62.5) < 1e-9);
            Stills.Probe(ProbeAudio, out s, out v);
            check("keyframes: probe of an audio-only file (a cover picture is not video) -> audio only, skipped", !v && Math.Abs(s - 30) < 1e-9 && Stills.Skip(s, v) == "audio only");
            Stills.Probe("Duration: N/A, bitrate: N/A\n  Stream #0:0: Video: h264\n", out s, out v);
            check("keyframes: probe with no duration -> NaN (the recording's length is used)", v && double.IsNaN(s));

            check("keyframes: 2xx stored, 404 and 501 not supported, the rest (no response, 401, 409, 413, 500, 503) failed",
                Stills.Outcome(200) == Stills.Result.Stored && Stills.Outcome(201) == Stills.Result.Stored && Stills.Outcome(204) == Stills.Result.Stored
                && Stills.Outcome(404) == Stills.Result.Unsupported && Stills.Outcome(501) == Stills.Result.Unsupported
                && Stills.Outcome(0) == Stills.Result.Failed && Stills.Outcome(401) == Stills.Result.Failed && Stills.Outcome(409) == Stills.Result.Failed
                && Stills.Outcome(413) == Stills.Result.Failed && Stills.Outcome(500) == Stills.Result.Failed && Stills.Outcome(503) == Stills.Result.Failed);
            check("keyframes: content type image/jpeg; video, audio and JSON unchanged",
                Recorder.ContentType("https://x/upload/AAAAAAAAAAAAAAAAAAAAAA/keyframes/3?t=25000", true) == "image/jpeg"
                && Recorder.ContentType("https://x/upload/AAAAAAAAAAAAAAAAAAAAAA/video/mp/2", true) == "video/mp4"
                && Recorder.ContentType("https://x/upload/AAAAAAAAAAAAAAAAAAAAAA/audio", true) == "audio/wav"
                && Recorder.ContentType("https://x/upload/AAAAAAAAAAAAAAAAAAAAAA/complete", false) == "application/json");

            // The whole step on fakes: grabs write a tiny JPEG header, PUTs answer from a script. Sandbox folder only.
            string dir = Path.Combine(Path.GetTempPath(), "agent-recorder-selftest-stills-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                const string id = "AAAAAAAAAAAAAAAAAAAAAA";
                var grabs = new List<long>();
                Action<string, long, string> grab = delegate (string video, long ms, string jpg) { grabs.Add(ms); File.WriteAllBytes(jpg, new byte[] { 0xFF, 0xD8, 0xFF, 0xE0, 0, 0 }); };
                Func<string, Func<int, int>, Tuple<string, List<string>>> run = delegate (string info, Func<int, int> answer)
                {
                    var puts = new List<string>();
                    string line = Stills.Run(x => info, grab, delegate (string path, string jpg)
                    {
                        puts.Add(path + (File.Exists(jpg) ? "" : " (no file)"));
                        return answer(puts.Count);
                    }, "v.mp4", 10, dir, id);
                    return Tuple.Create(line, puts);
                };

                var ok = run(ProbeVideo, n => 200);
                check("keyframes: all stored -> 6 PUTs keyframes/1..6?t=<ms>, files gone after",
                    ok.Item1 == "keyframes: 6 of 6 sent" && string.Join("|", ok.Item2) == "keyframes/1?t=5208|keyframes/2?t=15625|keyframes/3?t=26041|keyframes/4?t=36458|keyframes/5?t=46875|keyframes/6?t=57291"
                    && Directory.GetFiles(dir).Length == 0);
                foreach (int code in new[] { 404, 501 })
                {
                    var r = run(ProbeVideo, n => code);
                    check("keyframes: " + code + " (no route on this server yet) -> one PUT, the rest skipped quietly, no throw, files gone",
                        r.Item1 == "keyframes: not supported by this server (" + code + "); skipped" && r.Item2.Count == 1 && Directory.GetFiles(dir).Length == 0);
                }
                var mid = run(ProbeVideo, n => n == 3 ? 500 : 200);
                check("keyframes: a 500 on the 3rd -> stops there, logged (2 of 6 sent)", mid.Item1 == "keyframes: 2 of 6 sent; stopped at 3 (HTTP 500)" && mid.Item2.Count == 3);
                var net = run(ProbeVideo, n => 0);
                check("keyframes: no response -> stops, logged, no throw", net.Item1 == "keyframes: 0 of 6 sent; stopped at 1 (no response)" && net.Item2.Count == 1);
                string thrown = Stills.Run(x => ProbeVideo, grab, delegate (string path, string jpg) { throw new WebException("boom"); }, "v.mp4", 10, dir, id);
                check("keyframes: a PUT that throws -> stops, no throw", thrown == "keyframes: 0 of 6 sent; stopped at 1 (no response)");

                grabs.Clear();
                var audioOnly = run(ProbeAudio, n => 200);
                check("keyframes: audio only -> skipped: no grab, no PUT", audioOnly.Item1 == "keyframes: skipped (audio only)" && grabs.Count == 0 && audioOnly.Item2.Count == 0);
                var shortOne = run(ProbeVideo.Replace("00:01:02.50", "00:00:01.90"), n => 200);
                check("keyframes: 1.9 s video -> skipped: no grab, no PUT", shortOne.Item1 == "keyframes: skipped (shorter than 2 s)" && grabs.Count == 0 && shortOne.Item2.Count == 0);
                var fallback = run("Duration: N/A\n  Stream #0:0: Video: h264\n", n => 200);
                check("keyframes: no duration in the probe -> the recording's own length (10 s)", fallback.Item2.Count == 6 && fallback.Item2[0] == "keyframes/1?t=833");

                // A bad frame (grab throws, or writes something that is not a JPEG) is left out; the others keep their slot.
                var puts2 = new List<string>();
                string bad = Stills.Run(x => ProbeVideo, delegate (string video, long ms, string jpg)
                {
                    if (ms == 15625) throw new Exception("decode error");
                    File.WriteAllBytes(jpg, ms == 36458 ? new byte[] { 1, 2, 3, 4 } : new byte[] { 0xFF, 0xD8, 0xFF, 0xDB });
                }, delegate (string path, string jpg) { puts2.Add(path); return 200; }, "v.mp4", 10, dir, id);
                check("keyframes: bad frames (grab error, not a JPEG) left out, the rest sent with their own slot and time",
                    bad == "keyframes: 4 of 4 sent" && string.Join("|", puts2) == "keyframes/1?t=5208|keyframes/3?t=26041|keyframes/5?t=46875|keyframes/6?t=57291"
                    && Directory.GetFiles(dir).Length == 0);
                string probeFails = Stills.Run(x => { throw new Exception("ffmpeg missing"); }, grab, (p, j) => 200, "v.mp4", 10, dir, id);
                check("keyframes: probe failure -> skipped, no throw", probeFails == "keyframes: skipped (Exception ffmpeg missing)");
                var big = Path.Combine(dir, "big.jpg");
                var bytes = new byte[Stills.MaxBytes + 1]; bytes[0] = 0xFF; bytes[1] = 0xD8; bytes[2] = 0xFF;
                File.WriteAllBytes(big, bytes);
                check("keyframes: a JPEG over 1 MiB is not usable", !Stills.Usable(big) && !Stills.Usable(Path.Combine(dir, "none.jpg")));
                File.Delete(big);
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
            check("keyframes: grab args seek to the ms, one frame of the first video stream, at most 1280 wide (never scaled up), aspect kept",
                WindowsFfmpegBackend.StillArgs("v.mp4", 5208, "o.png") == "-hide_banner -loglevel error -y -ss 5.208 -i \"v.mp4\" -map 0:v:0 -frames:v 1 -vf \"scale='min(1280,iw)':-1\" -f image2 -c:v png \"o.png\"");

            string ff = SelfTestFfmpeg();
            if (ff == null) { Console.WriteLine("skip keyframes ffmpeg: no ffmpeg on PATH (fake grabs above only)"); return; }
            string sand = Path.Combine(Path.GetTempPath(), "agent-recorder-selftest-stills-ff-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(sand);
            try
            {
                var be = new WindowsFfmpegBackend(ff);
                string wide = Path.Combine(sand, "wide.mp4"), small = Path.Combine(sand, "small.mp4"), shortV = Path.Combine(sand, "short.mp4"), m4a = Path.Combine(sand, "a.m4a");
                int e1 = RunSelfTestFfmpeg(ff, "-hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1920x1080:rate=30 -f lavfi -i sine=f=440:sample_rate=48000 -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \"" + wide + "\"");
                int e2 = RunSelfTestFfmpeg(ff, "-hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -t 3 -c:v libx264 -pix_fmt yuv420p \"" + small + "\"");
                int e3 = RunSelfTestFfmpeg(ff, "-hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -t 1.5 -c:v libx264 -pix_fmt yuv420p \"" + shortV + "\"");
                int e4 = RunSelfTestFfmpeg(ff, "-hide_banner -loglevel error -y -f lavfi -i sine=f=440 -t 3 -c:a aac \"" + m4a + "\"");
                if (e1 != 0 || e2 != 0 || e3 != 0 || e4 != 0) { check("keyframes ffmpeg: sandbox media made (" + e1 + ", " + e2 + ", " + e3 + ", " + e4 + ")", false); return; }
                Func<string, List<string>> sizes = delegate (string video)
                {
                    var got = new List<string>();
                    string line = Stills.Run(be.MediaInfo, be.Still, delegate (string path, string jpg)
                    {
                        using (var img = Image.FromFile(jpg)) got.Add(path + " " + img.Width + "x" + img.Height + (img.RawFormat.Guid == System.Drawing.Imaging.ImageFormat.Jpeg.Guid && Stills.Usable(jpg) ? " jpeg" : " ?"));
                        return 200;
                    }, video, 0, sand, "AAAAAAAAAAAAAAAAAAAAAA");
                    got.Insert(0, line);
                    return got;
                };
                var w = sizes(wide);
                check("keyframes ffmpeg: 1920x1080 4 s MP4 -> 6 JPEGs in slots 1..6, 1280x720",
                    w.Count == 7 && w[0] == "keyframes: 6 of 6 sent" && w[1].StartsWith("keyframes/1?t=33") && w[6].StartsWith("keyframes/6?t=36")
                    && w.FindAll(x => x.EndsWith(" 1280x720 jpeg")).Count == 6);
                var sm = sizes(small);
                check("keyframes ffmpeg: 640x360 is not scaled up", sm.Count == 7 && sm.FindAll(x => x.EndsWith(" 640x360 jpeg")).Count == 6);
                var sh = sizes(shortV);
                check("keyframes ffmpeg: 1.5 s MP4 -> skipped", sh.Count == 1 && sh[0] == "keyframes: skipped (shorter than 2 s)");
                var au = sizes(m4a);
                check("keyframes ffmpeg: audio-only file -> skipped", au.Count == 1 && au[0] == "keyframes: skipped (audio only)");
                check("keyframes ffmpeg: nothing left in the folder but the sandbox media", Directory.GetFiles(sand).Length == 4);
            }
            finally { try { Directory.Delete(sand, true); } catch { } }
        }

        /// A WarmKeeper handle that is not a process: counts its ends.
        sealed class FakeWarm : WarmKeeper.IHandle
        {
            public bool Alive { get; set; }
            public int Disposed;
            public FakeWarm() { Alive = true; }
            public void Dispose() { Disposed++; Alive = false; }
        }

        /// Fast start: the warm ffmpeg's command line and the keeper's lifecycle (fake handles, no process), the bubble
        /// starting without the screen's first frame (a fake show, no camera), and the reconnect loop's stop on 401
        /// (synthetic exceptions and statuses, no network).
        static void FastStartSelfTest(Action<string, bool> check)
        {
            string wa = WindowsFfmpegBackend.WarmArgs;
            check("warm ffmpeg: no capture device (no dshow, mic, camera, ddagrab, gdigrab, wasapi, lavfi source)",
                !wa.Contains("dshow") && !wa.Contains("audio=") && !wa.Contains("video=") && !wa.Contains("ddagrab")
                && !wa.Contains("gdigrab") && !wa.Contains("wasapi") && !wa.Contains("lavfi"));
            check("warm ffmpeg: one input, its own stdin; null muxer, no file, no encoder",
                wa.Split(new[] { " -i " }, StringSplitOptions.None).Length == 2 && wa.Contains(" -i pipe:0 ") && wa.EndsWith(" -f null -")
                && !wa.Contains(".wav") && !wa.Contains(".mp4") && !wa.Contains(" -y") && !wa.Contains("-c:") && !wa.Contains("\""));

            var made = new List<FakeWarm>();
            Func<WarmKeeper.IHandle> spawn = delegate { var h = new FakeWarm(); made.Add(h); return h; };
            var k = new WarmKeeper(spawn);
            k.Fill();
            check("warm keeper: nothing until wanted", made.Count == 0 && !k.Holding);
            k.Want();
            k.Want();
            k.Fill();
            check("warm keeper: wanted keeps exactly one", made.Count == 1 && k.Holding && made[0].Alive);
            k.Pause();
            k.Release();
            k.Want();
            k.Fill();
            check("warm keeper: a recording pauses it: released, none spawned while paused", made.Count == 1 && !k.Holding && made[0].Disposed == 1);
            k.Resume();
            k.Fill();
            check("warm keeper: back after the recording", made.Count == 2 && k.Holding);
            made[1].Alive = false;
            k.Want();
            check("warm keeper: a dead one is ended and replaced", made.Count == 3 && made[1].Disposed == 1 && made[2].Alive);
            k.Close();
            k.Want();
            k.Resume();
            k.Fill();
            check("warm keeper: closed for good, every handle ended exactly once", made.Count == 3 && !k.Holding && made.TrueForAll(h => h.Disposed == 1));
            var bad = new WarmKeeper(delegate { throw new InvalidOperationException("no ffmpeg"); });
            bool threw = false;
            try { bad.Want(); bad.Fill(); } catch { threw = true; }
            check("warm keeper: a spawn failure is logged, not thrown, and not retried", !threw && !bad.Holding);

            var sb = typeof(Recorder).GetMethod("StartBubble", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            check("bubble: StartBubble takes no first-frame wait handle", sb != null
                && !Array.Exists(sb.GetParameters(), p => typeof(WaitHandle).IsAssignableFrom(p.ParameterType)));
            var bt = new StartTimes(Clock.Now());
            bt.ExpectBubble();
            var called = new ManualResetEvent(false);
            var th = Recorder.BubbleThread(delegate { called.Set(); return true; }, bt);
            bool ran = th.Join(5000);
            check("bubble: shown at once, t_bubble marked with no first frame yet", ran && called.WaitOne(0)
                && !double.IsNaN(bt.Ms("t_bubble")) && double.IsNaN(bt.Ms("t_first_frame")) && double.IsNaN(bt.Ms("t_ffmpeg_launch")));
            var ft = new StartTimes(Clock.Now());
            ft.ExpectBubble();
            string line = null;
            ft.Logged += delegate (StartTimes x) { line = x.Line(); };
            ran = Recorder.BubbleThread(delegate { throw new InvalidOperationException("no camera"); }, ft).Join(5000);
            ft.Mark("t_first_frame");
            ft.Mark("t_started");
            check("bubble: a failed show settles (logged, no crash): the timing line has t_bubble=-", ran && line != null && line.EndsWith(" t_bubble=-"));
            var nt = new StartTimes(Clock.Now());
            nt.ExpectBubble();
            ran = Recorder.BubbleThread(delegate { return false; }, nt).Join(5000);
            check("bubble: not shown leaves t_bubble unset", ran && double.IsNaN(nt.Ms("t_bubble")));

            int asked = 0;
            Func<bool> notRevoked = delegate { asked++; return false; };
            check("unpaired: 401 stops retrying", Revocation.AfterError(false, 401, notRevoked) == Revocation.Next.Stop);
            check("unpaired: 403 keeps the backoff (edge WAF / account mismatch, not unpaired)", Revocation.AfterError(false, 403, notRevoked) == Revocation.Next.Retry);
            bool keeps = true;
            foreach (int st in new[] { 0, 400, 404, 409, 410, 426, 429, 500, 502, 503 }) keeps &= Revocation.AfterError(false, st, notRevoked) == Revocation.Next.Retry;
            check("unpaired: network errors (0), 500 and other statuses keep the backoff", keeps);
            check("unpaired: revoked() is asked on every refusal before the stop", asked == 12);
            check("unpaired: 410 + device_revoked still uninstalls through Revoked()", Revocation.AfterError(false, 410, delegate { return true; }) == Revocation.Next.Uninstall);
            asked = 0;
            check("unpaired: errors after the socket connected keep the backoff, revoked() not asked",
                Revocation.AfterError(true, 401, notRevoked) == Revocation.Next.Retry && Revocation.AfterError(true, 0, notRevoked) == Revocation.Next.Retry && asked == 0);
            const string refusal = "The server returned status code '{0}' when status code '101' was expected.";
            Func<Exception, Revocation.Next> after = delegate (Exception e) { return Revocation.AfterError(false, Revocation.HandshakeStatus(e), notRevoked); };
            check("unpaired: synthetic refused handshakes: 401 stops, 403, 500 and network errors retry",
                after(new WebSocketException(string.Format(refusal, 401))) == Revocation.Next.Stop
                && after(new AggregateException("x", new WebSocketException(string.Format(refusal, 401)))) == Revocation.Next.Stop
                && after(new AggregateException("x", new WebSocketException(string.Format(refusal, 403)))) == Revocation.Next.Retry
                && after(new WebSocketException(string.Format(refusal, 500))) == Revocation.Next.Retry
                && after(new WebSocketException("Unable to connect to the remote server", new WebException("The remote name could not be resolved", WebExceptionStatus.NameResolutionFailure))) == Revocation.Next.Retry
                && after(new IOException("Unable to read data from the transport connection")) == Revocation.Next.Retry);
            check("unpaired: the stop is logged once, clearly", Revocation.StoppedLine.StartsWith("not paired: reconnecting stopped")
                && Revocation.StoppedLine.Contains("/device/ws") && Revocation.StoppedLine.Contains("stays running"));

            // The reconnect wait (pure: no sleeping). unit is the loop's rng.NextDouble(), jitter its rng.Next(0, 3).
            Func<bool, bool, double, double, int, double> wait = delegate (bool conn, bool prevFast, double sessionS, double unit, int jitter)
            {
                var next = Revocation.AfterError(conn, conn ? 0 : 500, notRevoked);
                return Revocation.ReconnectDelay(next, Revocation.FastReconnect(conn, prevFast, sessionS), 5, unit, jitter).Value.TotalSeconds;
            };
            bool fastOk = true;
            foreach (double u in new[] { 0.0, 0.25, 0.5, 0.999999, 1.0, -1.0, 2.0 })
            {
                double clean = Revocation.ReconnectDelay(Revocation.Next.Retry, Revocation.FastReconnect(true, false, 3600), 5, u, 2).Value.TotalSeconds;
                double drop = wait(true, false, 0.2, u, 2);
                fastOk &= clean >= 0.5 && clean <= 1.5 && drop >= 0.5 && drop <= 1.5;
            }
            check("reconnect: first delay after a clean close or a post-connect drop is 0.5-1.5 s (jitter ignored)", fastOk
                && Revocation.FastReconnect(true, false, 0) && wait(true, false, 0, 0, 2) == 0.5 && wait(true, false, 0, 1, 0) == 1.5);
            check("reconnect: after that fast attempt the backoff is 5 s + jitter (never-connected failure)",
                wait(false, true, 0, 0.3, 0) == 5 && wait(false, true, 0, 0.3, 2) == 7);
            check("reconnect: a session that drops again within 30 s of a fast retry gets the backoff, a longer one the fast delay again",
                !Revocation.FastReconnect(true, true, 29.9) && wait(true, true, 5, 0.5, 1) == 6 && Revocation.FastReconnect(true, true, 30) && wait(true, true, 600, 0.5, 1) == 1.0);
            bool slow = true;
            foreach (int st in new[] { 0, 403, 500, 502, 503 })
            {
                var n = Revocation.AfterError(false, st, notRevoked);
                slow &= n == Revocation.Next.Retry && !Revocation.FastReconnect(false, false, 0)
                    && Revocation.ReconnectDelay(n, Revocation.FastReconnect(false, false, 0), 5, 0.0, 0).Value.TotalSeconds == 5
                    && Revocation.ReconnectDelay(n, false, 5, 0.9, 2).Value.TotalSeconds == 7
                    && Revocation.ReconnectDelay(n, false, 300, 0.9, 2).Value.TotalSeconds == 302;
            }
            check("reconnect: never-connected 403 / 5xx / network errors keep the 5 s backoff (no fast first delay)", slow);
            var s401 = Revocation.AfterError(false, 401, notRevoked);
            check("reconnect: 401 still stops, no reconnect delay (also when the fast path would apply)", s401 == Revocation.Next.Stop
                && Revocation.ReconnectDelay(s401, false, 5, 0.5, 1) == null && Revocation.ReconnectDelay(s401, true, 5, 0.5, 1) == null);
        }

        /// Self-update: the signed update block (shared vector with worker/test/installer.test.ts), version order, link
        /// policy, hash check, the installer command line and the report frame.
        static void SelfUpdateSelfTest(Action<string, bool> check)
        {
            const string sha = "6685944C4FFFC4F5B140100CEEB4BD6BC9663578062018C2E8B0756C7ECE7D9D";
            string link = "https://recitbot.com/i/v1.update.BBBBBBBBBBBBBBBBBBBBBB.1731650600.NNNNNNNNNNNN.." + new string('M', 43);
            var upd = new Dictionary<string, string>
            {
                { "type", "update" }, { "recording_id", "AAAAAAAAAAAAAAAAAAAAAA" }, { "max_seconds", "0" }, { "mic", "false" },
                { "nonce", "1731650000000" }, { "exp", "1731650060" }, { "account_id", "BBBBBBBBBBBBBBBBBBBBBB" },
                { "device_id", "CCCCCCCCCCCCCCCCCCCCCC" }, { "upload_token", "" }, { "url", link }, { "version", "0.5.0" }, { "sha256", sha },
            };
            check("update canonical form", CommandVerifier.Canonical(upd).EndsWith("|CCCCCCCCCCCCCCCCCCCCCC||url|" + link + "|upd|0.5.0|" + sha));
            check("update canonical hmac matches worker vector",
                CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(upd)) == "4ac3acc3df0b6942ada285bcfa62250587b5ac25235ce107902e07c422ceb5fb");
            upd["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(upd));
            foreach (var field in new[] { "version", "sha256", "url" })
            {
                var t = new Dictionary<string, string>(upd);
                t[field] = field == "url" ? "https://evil.example/i/x" : field == "version" ? "9.9.9" : new string('0', 64);
                check("update: tampered " + field + " rejected", new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null).Verify(t, 1731650000) == "bad mac");
            }
            check("signed update accepted", new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null).Verify(upd, 1731650000) == null);

            check("update: newer versions only", SelfUpdater.IsNewer("0.5.0", "0.4.0") && SelfUpdater.IsNewer("0.10.0", "0.9.9") && SelfUpdater.IsNewer("1.0.0", "0.99.99")
                && !SelfUpdater.IsNewer("0.4.0", "0.4.0") && !SelfUpdater.IsNewer("0.3.9", "0.4.0") && !SelfUpdater.IsNewer("1.0", "0.4.0")
                && !SelfUpdater.IsNewer(null, "0.4.0") && !SelfUpdater.IsNewer("0.5.0-beta", "0.4.0"));
            const string server = "https://agent-recorder-demo.example.workers.dev";
            check("update link: recitbot.com or the server, https, /i/<token>", SelfUpdater.UrlAllowed(link, server)
                && SelfUpdater.UrlAllowed("https://agent-recorder-demo.example.workers.dev/i/" + new string('t', 40), server));
            check("update link: other hosts, http, ports, queries, other paths rejected",
                !SelfUpdater.UrlAllowed("https://evil.example/i/" + new string('t', 40), server)
                && !SelfUpdater.UrlAllowed("http://recitbot.com/i/" + new string('t', 40), server)
                && !SelfUpdater.UrlAllowed("https://recitbot.com:8443/i/" + new string('t', 40), server)
                && !SelfUpdater.UrlAllowed(link + "?x=1", server)
                && !SelfUpdater.UrlAllowed("https://recitbot.com/install.ps1", server)
                && !SelfUpdater.UrlAllowed("https://user@recitbot.com/i/" + new string('t', 40), server)
                && !SelfUpdater.UrlAllowed(null, server));
            check("update link: http only against a loopback dev server",
                SelfUpdater.UrlAllowed("http://127.0.0.1:8787/i/" + new string('t', 40), "http://127.0.0.1:8787")
                && !SelfUpdater.UrlAllowed("http://127.0.0.1:8787/i/" + new string('t', 40), server));
            var abc = Encoding.ASCII.GetBytes("abc");
            check("update: sha256 checked (any case), malformed refused",
                SelfUpdater.HashMatches(abc, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
                && SelfUpdater.HashMatches(abc, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                && !SelfUpdater.HashMatches(abc, sha) && !SelfUpdater.HashMatches(abc, "BA78") && !SelfUpdater.HashMatches(abc, null));
            check("update: hidden, no-prompt installer command line that keeps the pairing",
                SelfUpdater.Arguments("C:\\Users\\u\\AppData\\Local\\Temp\\recitbot-update-1.ps1", "https://recitbot.com", "C:\\Users\\u\\AppData\\Local\\AgentRecorder")
                == "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\\Users\\u\\AppData\\Local\\Temp\\recitbot-update-1.ps1\" "
                + "-Server \"https://recitbot.com\" -Update -InstallDir \"C:\\Users\\u\\AppData\\Local\\AgentRecorder\""
                && SelfUpdater.Arguments("C:\\T\\recitbot-update-1.ps1", "https://recitbot.com", "C:\\L\\AgentRecorder", false, null)
                == SelfUpdater.Arguments("C:\\T\\recitbot-update-1.ps1", "https://recitbot.com", "C:\\L\\AgentRecorder"));
            const string upPrefix = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\\T\\u.ps1\" -Server \"https://recitbot.com\" -Update -InstallDir \"C:\\T\\box\"";
            string sideNone, nameNone, sideLogon, nameLogon;
            SelfUpdater.ParseOptions("\uFEFFautostart=none\r\ndevice_name=Selftest Box 7\r\n", out sideNone, out nameNone);
            SelfUpdater.ParseOptions("autostart=logon\r\n", out sideLogon, out nameLogon);
            string throwaway = SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", SelfUpdater.NoAutostart(sideNone, false), nameNone);
            check("update of a no-autostart install passes -NoAutostart (options file says none, no entry starts the exe)",
                sideNone == "none" && SelfUpdater.NoAutostart(sideNone, false) && throwaway.StartsWith(upPrefix + " -NoAutostart"));
            check("update of a no-autostart install without an options file (pre-0.5.5) passes -NoAutostart when no task/Run/Startup entry starts the exe",
                SelfUpdater.NoAutostart(null, false)
                && SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", SelfUpdater.NoAutostart(null, false), null) == upPrefix + " -NoAutostart");
            check("update passes a recorded device name", nameNone == "Selftest Box 7" && throwaway == upPrefix + " -NoAutostart -DeviceName \"Selftest Box 7\"");
            check("update of an autostart install (options say logon, or an entry starts the exe) has no -NoAutostart",
                sideLogon == "logon" && !SelfUpdater.NoAutostart(sideLogon, false) && !SelfUpdater.NoAutostart(null, true) && !SelfUpdater.NoAutostart("none", true)
                && SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", SelfUpdater.NoAutostart(sideLogon, false), nameLogon) == upPrefix
                && SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", SelfUpdater.NoAutostart(null, true), null) == upPrefix);
            string noName, unk;
            SelfUpdater.ParseOptions("autostart=sometimes\r\ndevice_name=\r\nfoo=bar", out unk, out noName);
            check("update: an unrecorded device name is not passed, none is made up", nameLogon == null && noName == null && unk == null
                && !SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", true, nameLogon).Contains("-DeviceName")
                && !SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", true, "   ").Contains("-DeviceName")
                && !SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", true, "\"\r\n").Contains("-DeviceName"));
            check("update: recorded device names are cleaned (quotes, control chars, leading '-', 64 chars)",
                SelfUpdater.CleanDeviceName("a\"b\tc") == "abc" && SelfUpdater.CleanDeviceName("-Server x") == null
                && SelfUpdater.CleanDeviceName(new string('n', 80)) == new string('n', 64) && SelfUpdater.CleanDeviceName(null) == null
                && SelfUpdater.Arguments("C:\\T\\u.ps1", "https://recitbot.com", "C:\\T\\box", false, "O'Brien \"PC\"") == upPrefix + " -DeviceName \"O'Brien PC\"");
            check("update: same-exe rule (full rooted paths, case, quotes, %VARS%) and the Run command-line program",
                SelfUpdater.SameExe("\"C:\\X\\Y\\AgentRecorder.exe\"", "c:\\x\\y\\agentrecorder.EXE") && SelfUpdater.SameExe("C:\\X\\.\\Y\\..\\Y\\AgentRecorder.exe", "C:\\X\\Y\\AgentRecorder.exe")
                && SelfUpdater.SameExe("%SystemRoot%\\notepad.exe", Path.Combine(Environment.GetEnvironmentVariable("SystemRoot") ?? "C:\\Windows", "notepad.exe"))
                && !SelfUpdater.SameExe("AgentRecorder.exe", "C:\\X\\AgentRecorder.exe") && !SelfUpdater.SameExe("C:\\X\\AgentRecorder.exe.bak", "C:\\X\\AgentRecorder.exe")
                && !SelfUpdater.SameExe(null, "C:\\X\\AgentRecorder.exe") && !SelfUpdater.SameExe("C:\\Other\\AgentRecorder.exe", "C:\\X\\AgentRecorder.exe")
                && SelfUpdater.CmdExe("\"C:\\A B\\AgentRecorder.exe\" --data \"C:\\A B\"") == "C:\\A B\\AgentRecorder.exe"
                && SelfUpdater.CmdExe("C:\\A B\\AgentRecorder.exe --data x") == "C:\\A B\\AgentRecorder.exe" && SelfUpdater.CmdExe("C:\\x\\run.bat arg") == "C:\\x\\run.bat"
                && SelfUpdater.CmdExe(null) == null);

            UpdateAutostartSandboxSelfTest(check);
            InstallerAutostartSelfTest(check);
            check("update report frames", SelfUpdater.ReportJson("0.5.0", null) == "{\"type\":\"update\",\"status\":\"installing\",\"version\":\"0.5.0\"}"
                && SelfUpdater.ReportJson("0.5.0", "bad \"x\" <y>") == "{\"type\":\"update\",\"status\":\"failed\",\"version\":\"0.5.0\",\"error\":\"bad x y\"}");
            UpdateDeferRollbackSelfTest(check);
        }

        /// 0.6.1 (hello "update_defer_rollback"): an update during a recording is held and reported "deferred" (newest
        /// version wins, no installer), and runs once the recording is uploaded; one whose link expired by then fails
        /// without an installer; the installer's health decision (here and the template's Get-UpdateHealth, on one
        /// table), its backup/restore against a throwaway folder in %TEMP%, and the restored recorder's "rolled_back".
        /// parity: mac/Sources/RecitbotCore/SelfTestUpdate.swift (same case names)
        static void UpdateDeferRollbackSelfTest(Action<string, bool> check)
        {
            const string server = "https://recitbot.com", sha = "6685944C4FFFC4F5B140100CEEB4BD6BC9663578062018C2E8B0756C7ECE7D9D";
            const long now = 1731650000;
            Func<long, string> link = delegate (long exp) { return "https://recitbot.com/i/v1.update.BBBBBBBBBBBBBBBBBBBBBB." + exp + ".NNNNNNNNNNNN.." + new string('M', 43); };
            var sent = new List<string>();
            var installs = new List<string>();
            Func<PendingUpdate, string> install = delegate (PendingUpdate p) { installs.Add(p.Version); return null; };
            Func<string, string, long, PendingUpdate> upd = delegate (string v, string url, long cmdExp)
            {
                return new PendingUpdate(v, sha, url, server, SelfUpdater.Expiry(url, cmdExp), delegate (string s) { sent.Add(s); });
            };
            Func<string> last = delegate { return sent.Count == 0 ? null : sent[sent.Count - 1]; };
            Func<string, string> deferred = delegate (string v) { return "{\"type\":\"update\",\"status\":\"deferred\",\"version\":\"" + v + "\"}"; };

            var q = new DeferredUpdates();
            SelfUpdater.Handle(upd("0.7.0", link(now + 600), now + 60), true, q, install);
            check("update defer: while recording the update is held, reported deferred, no installer started",
                sent.Count == 1 && last() == deferred("0.7.0") && SelfUpdater.StatusJson("deferred", "0.7.0", null) == deferred("0.7.0")
                && installs.Count == 0 && q.Held != null && q.Held.Version == "0.7.0");
            SelfUpdater.Handle(upd("0.7.2", link(now + 600), now + 60), true, q, install);
            SelfUpdater.Handle(upd("0.7.1", link(now + 600), now + 60), true, q, install);
            check("update defer: the newest pending version is kept (an older one reports the held version)",
                q.Held.Version == "0.7.2" && sent.Count == 3 && sent[1] == deferred("0.7.2") && sent[2] == deferred("0.7.2") && installs.Count == 0);
            SelfUpdater.Handle(upd("0.7.2", link(now + 900), now + 60), true, q, install);
            check("update defer: the same version again replaces the held one (fresher link)", q.Held.Version == "0.7.2" && q.Held.Expires == now + 900);
            int before = sent.Count;
            SelfUpdater.Handle(upd(Program.Version, link(now + 600), now + 60), true, q, install);
            SelfUpdater.Handle(upd("0.7.3", "https://evil.example/i/" + new string('t', 40), now + 60), true, q, install);
            check("update defer: not newer is ignored, a rejected link fails at once; neither is held",
                sent.Count == before + 1 && last() == SelfUpdater.ReportJson("0.7.3", "update link rejected") && q.Held.Version == "0.7.2" && installs.Count == 0);
            SelfUpdater.RunDeferred(() => true, q, now + 100, install);
            check("update defer: a recording running again at upload time keeps it held", installs.Count == 0 && q.Held != null);
            before = sent.Count;
            SelfUpdater.RunDeferred(() => false, q, now + 100, install);
            check("update defer: after the recording is uploaded the held update runs (installing)",
                installs.Count == 1 && installs[0] == "0.7.2" && sent.Count == before + 1 && last() == SelfUpdater.ReportJson("0.7.2", null) && q.Held == null);
            SelfUpdater.RunDeferred(() => false, q, now + 100, install);
            check("update defer: nothing held, nothing runs", installs.Count == 1 && sent.Count == before + 1);
            SelfUpdater.Handle(upd("0.7.0", link(now + 600), now + 60), false, q, install);
            check("update defer: not recording installs at once (nothing held)", installs.Count == 2 && last() == SelfUpdater.ReportJson("0.7.0", null) && q.Held == null);
            int thrown = sent.Count;
            SelfUpdater.Handle(upd("0.7.0", link(now + 600), now + 60), false, q, delegate (PendingUpdate p) { throw new IOException("x"); });
            check("update defer: an installer that cannot start reports failed", sent.Count == thrown + 1 && last() == SelfUpdater.ReportJson("0.7.0", "installer not started: IOException"));

            check("update expiry: read from the Worker link, the command exp when the link has none",
                SelfUpdater.LinkExpiry(link(1731650600)) == 1731650600 && SelfUpdater.LinkExpiry("https://recitbot.com/i/" + new string('t', 40)) == 0
                && SelfUpdater.LinkExpiry(null) == 0 && SelfUpdater.LinkExpiry("https://recitbot.com/i/v1.update.B.12x4.N.." + new string('M', 43)) == 0
                && SelfUpdater.Expiry(link(1731650600), 1731650060) == 1731650600 && SelfUpdater.Expiry("https://recitbot.com/i/" + new string('t', 40), 1731650060) == 1731650060);
            const string expiredError = "update link expired while deferred (send the update again)";
            var qe = new DeferredUpdates();
            int n = installs.Count;
            SelfUpdater.Handle(upd("0.7.0", link(now + 600), now + 60), true, qe, install);
            SelfUpdater.RunDeferred(() => false, qe, now + 600, install);
            check("update expiry: a deferred update whose link expired by the upload reports failed and starts no installer",
                installs.Count == n && last() == SelfUpdater.ReportJson("0.7.0", expiredError) && last().Contains("\"status\":\"failed\"") && qe.Held == null);
            SelfUpdater.Handle(upd("0.7.0", link(now + 600), now + 60), true, qe, install);
            SelfUpdater.RunDeferred(() => false, qe, now + 600 - SelfUpdater.ExpiryMarginSeconds, install);
            bool margin = installs.Count == n && last() == SelfUpdater.ReportJson("0.7.0", expiredError);
            SelfUpdater.Handle(upd("0.7.0", link(now + 600), now + 60), true, qe, install);
            SelfUpdater.RunDeferred(() => false, qe, now + 600 - SelfUpdater.ExpiryMarginSeconds - 1, install);
            check("update expiry: 15 s of margin for the download; before that it runs", margin && installs.Count == n + 1);
            SelfUpdater.Handle(upd("0.7.0", "https://recitbot.com/i/" + new string('t', 40), now + 60), true, qe, install);
            SelfUpdater.RunDeferred(() => false, qe, now + 60, install);
            check("update expiry: an expired command exp (no expiry in the link) fails too", installs.Count == n + 1 && last() == SelfUpdater.ReportJson("0.7.0", expiredError));

            var V = UpdateHealth.Verdict.Healthy;
            check("update rollback: health marker naming the new version within the window = success (no rollback)",
                UpdateHealth.Decide(UpdateHealth.MarkerText("0.7.0"), "0.7.0", true, 10, 90) == V
                && UpdateHealth.Decide("﻿version=0.7.0\r\n", "0.7.0", true, 89.9, 90) == V
                && UpdateHealth.Decide(UpdateHealth.MarkerText("0.7.0"), "0.7.0", false, 95, 90) == V);
            check("update rollback: no marker yet within the window = keep waiting",
                UpdateHealth.Decide(null, "0.7.0", true, 0, 90) == UpdateHealth.Verdict.Wait && UpdateHealth.Decide("", "0.7.0", true, 89.9, 90) == UpdateHealth.Verdict.Wait);
            check("update rollback: marker missing after the window, the old version's marker, or the recorder gone = rollback",
                UpdateHealth.Decide(null, "0.7.0", true, 90, 90) == UpdateHealth.Verdict.RollBack
                && UpdateHealth.Decide(UpdateHealth.MarkerText("0.6.1"), "0.7.0", true, 95, 90) == UpdateHealth.Verdict.RollBack
                && UpdateHealth.Decide("version=0.7.0x", "0.7.0", true, 95, 90) == UpdateHealth.Verdict.RollBack
                && UpdateHealth.Decide(null, "0.7.0", false, 3, 90) == UpdateHealth.Verdict.RollBack);
            check("update rollback: rolled_back report frame",
                UpdateHealth.RolledBackJson("0.7.0") == "{\"type\":\"update\",\"status\":\"rolled_back\",\"version\":\"0.7.0\"}");
            UpdateRollbackSandboxSelfTest(check);
        }

        /// The template's update health block (# --- update health) in a hidden powershell.exe: Get-UpdateHealth on the
        /// same table as UpdateHealth.Decide, Backup-Install / Restore-Install / Write-Rollback against a throwaway folder
        /// in %TEMP% (config.dat untouched), and the recorder side of the files (marker, rollback record).
        static void UpdateRollbackSandboxSelfTest(Action<string, bool> check)
        {
            string template = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", "recorder", "install.template.ps1"));
            if (!File.Exists(template)) { check("update rollback: recorder\\install.template.ps1 next to the build (" + template + ")", false); return; }
            string text = File.ReadAllText(template).Replace("\r\n", "\n");
            int a = text.IndexOf("# --- update health"), b = text.IndexOf("# --- end update health");
            int backupAt = text.IndexOf("$backedUp = (Backup-Install $InstallDir $backup) -gt 0"), stopAt = text.IndexOf("  Stop-Recorder\n"), swapAt = text.IndexOf("Expand-Archive");
            int startAt = text.IndexOf("  Start-Recorder\n  if ($backedUp) {"), waitAt = text.IndexOf("if ((Wait-UpdateHealth) -ne 'healthy')");
            check("update rollback: install.ps1 -Update backs up before stopping, waits for the marker after the start, restores on failure (not on a failed pairing)",
                backupAt > 0 && stopAt > backupAt && swapAt > stopAt && startAt > swapAt && waitAt > startAt
                && text.Contains("if ($backedUp -and $swapped -and $exitCode -ne 4) {") && text.Contains("Write-Rollback $InstallDir $RecorderVersion")
                && text.Contains("Remove-Item -LiteralPath (Join-Path $InstallDir '" + UpdateHealth.MarkerFile + "')")
                && text.Contains("$backup = Join-Path $InstallDir '" + UpdateHealth.BackupDir + "'") && text.Contains("'" + UpdateHealth.RollbackFile + "'")
                && text.Contains("$HealthSeconds = " + UpdateHealth.WindowSeconds + "\n"));
            if (a < 0 || b < a) { check("update rollback: block markers", false); return; }
            string block = text.Substring(a, b - a);
            check("update rollback: config.dat is never part of the payload", !block.Contains("config.dat'") && block.Contains("@('AgentRecorder.exe', 'AgentRecorder.exe.config', 'uninstall.ps1')"));
            var table = new[]
            {
                new object[] { "0.7.0", "0.7.0", true, 10.0, 90.0 }, new object[] { "0.7.0", "0.7.0", false, 95.0, 90.0 },
                new object[] { null, "0.7.0", true, 0.0, 90.0 }, new object[] { null, "0.7.0", true, 89.9, 90.0 },
                new object[] { null, "0.7.0", true, 90.0, 90.0 }, new object[] { "0.6.1", "0.7.0", true, 95.0, 90.0 }, new object[] { null, "0.7.0", false, 3.0, 90.0 },
            };
            string dir = Path.Combine(Path.GetTempPath(), "recitbot-update-rollback-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(dir);
                string bk = Path.Combine(dir, UpdateHealth.BackupDir);
                File.WriteAllText(Path.Combine(dir, "AgentRecorder.exe"), "old-exe");
                File.WriteAllText(Path.Combine(dir, "AgentRecorder.exe.config"), "old-config");
                File.WriteAllText(Path.Combine(dir, "config.dat"), "config_version=2\r\naccount.0.device_id=keep\r\n");
                UpdateHealth.WriteMarker(dir, Program.Version);
                var inv = System.Globalization.CultureInfo.InvariantCulture;
                var ps = new StringBuilder(block + "\r\n$ErrorActionPreference = 'Stop'\r\n");
                for (int i = 0; i < table.Length; i++)
                {
                    var r = table[i];
                    ps.Append("'h" + i + "=' + (Get-UpdateHealth " + (r[0] == null ? "$null" : "'" + r[0] + "'") + " '" + r[1] + "' $" + ((bool)r[2] ? "true" : "false")
                        + " " + ((double)r[3]).ToString(inv) + " " + ((double)r[4]).ToString(inv) + ")\r\n");
                }
                string d = SelfUninstaller.PsQuote(dir), bq = SelfUninstaller.PsQuote(bk);
                ps.Append("'marker=' + [string](Get-MarkerVersion (Join-Path " + d + " '" + UpdateHealth.MarkerFile + "'))\r\n");
                ps.Append("'nomarker=' + [string](Get-MarkerVersion (Join-Path " + d + " 'missing.txt'))\r\n");
                ps.Append("'backed=' + (Backup-Install " + d + " " + bq + ")\r\n");
                ps.Append("[IO.File]::WriteAllText((Join-Path " + d + " 'AgentRecorder.exe'), 'new-exe')\r\n");
                ps.Append("[IO.File]::WriteAllText((Join-Path " + d + " 'uninstall.ps1'), 'new-uninstall')\r\n");
                ps.Append("'restored=' + (Restore-Install " + d + " " + bq + ")\r\n");
                ps.Append("Write-Rollback " + d + " '0.7.0'\r\n");
                string err, output;
                int rc = HiddenPowerShell(ps.ToString(), out err, out output);
                var res = new Dictionary<string, string>();
                foreach (var line in (output ?? "").Split('\n'))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) res[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
                Func<string, string> v = delegate (string k) { string x; return res.TryGetValue(k, out x) ? x : null; };
                if (rc != 0) check("update rollback sandbox: script ran (exit " + rc + ": " + (err ?? "").Trim() + ")", false);
                bool same = true;
                for (int i = 0; i < table.Length; i++)
                {
                    var r = table[i];
                    var want = UpdateHealth.Decide(r[0] == null ? null : UpdateHealth.MarkerText((string)r[0]), (string)r[1], (bool)r[2], (double)r[3], (double)r[4]);
                    same &= v("h" + i) == (want == UpdateHealth.Verdict.Healthy ? "healthy" : want == UpdateHealth.Verdict.Wait ? "wait" : "rollback");
                }
                check("update rollback: the installer's Get-UpdateHealth decides like UpdateHealth.Decide", same);
                check("update rollback: the installer reads the recorder's health marker", v("marker") == Program.Version && v("nomarker") == "");
                check("update rollback: backup and restore of the payload put the previous files back, config.dat untouched and not copied",
                    v("backed") == "2" && v("restored") == "2" && File.ReadAllText(Path.Combine(dir, "AgentRecorder.exe")) == "old-exe"
                    && File.ReadAllText(Path.Combine(dir, "AgentRecorder.exe.config")) == "old-config"
                    && File.ReadAllText(Path.Combine(dir, "config.dat")) == "config_version=2\r\naccount.0.device_id=keep\r\n"
                    && !File.Exists(Path.Combine(bk, "config.dat")));
                string rolled = UpdateHealth.RolledBack(dir, Program.Version);
                string still = File.Exists(Path.Combine(dir, UpdateHealth.RollbackFile)) ? UpdateHealth.RolledBack(dir, "0.7.0") : "missing";
                check("update rollback: the restored recorder reads the attempted version; a record for its own (or an older) version is stale and goes",
                    rolled == "0.7.0" && still == null && !File.Exists(Path.Combine(dir, UpdateHealth.RollbackFile)));
            }
            catch (Exception e) { check("update rollback sandbox: " + e.GetType().Name + " " + e.Message, false); }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        /// Self-uninstall: the signed uninstall command and its ack, the revocation decision (410 + device_revoked only),
        /// the revocation probe body, the handshake status parser, the enroll retry, the install guard and the helper script, which also runs for
        /// real against a throwaway folder in %TEMP% with fake task / Run value / shortcut names and a pid that cannot exist.
        /// parity: mac/Sources/RecitbotCore/SelfTestUninstall.swift (same case names)
        /// Multi-account (0.6.0, hello "multi_account"): the v1 -> v2 config.dat migration of a file exactly as 0.5.5 wrote it
        /// (real DPAPI blobs), adding and refreshing accounts, the enroll token rule, per-account command routing and the
        /// machine-wide busy rule, the uninstall scope and its ack, removing one account (uninstall or revocation) vs the
        /// last one, the agent's account diff, the config.dat watch and the installer's add-account path. Sandbox folders
        /// in %TEMP% only. parity: mac SelfTestAccounts (same case names)
        static void MultiAccountSelfTest(Action<string, bool> check)
        {
            const string acctA = "AAAAAAAAAAAAAAAAAAAAAA", devA = "DAAAAAAAAAAAAAAAAAAAAA", acctB = "BBBBBBBBBBBBBBBBBBBBBB", devB = "DBBBBBBBBBBBBBBBBBBBBB";
            const string tokenA = "ardt_DAAAAAAAAAAAAAAAAAAAAA_tokenAtokenAtokenAtokenAtokenAtokenA";
            const string tokenB = "ardt_DBBBBBBBBBBBBBBBBBBBBB_tokenBtokenBtokenBtokenBtokenBtokenB";
            var a = new Config.Account { Server = "https://recitbot.com", AccountId = acctA, DeviceId = devA, DeviceToken = tokenA, DeviceSecret = "secret-A" };
            var b = new Config.Account { Server = "https://recitbot.com", AccountId = acctB, DeviceId = devB, DeviceToken = tokenB, DeviceSecret = "secret-B" };
            Func<List<Config.Account>, Config.Account[], bool> same = delegate (List<Config.Account> got, Config.Account[] want)
            {
                if (got == null || got.Count != want.Length) return false;
                for (int i = 0; i < want.Length; i++) if (!got[i].Same(want[i])) return false;
                return true;
            };
            string dir = Path.Combine(Path.GetTempPath(), "recitbot-multiacct-selftest-" + Guid.NewGuid().ToString("N"));
            string path = Path.Combine(dir, "config.dat");
            try
            {
                Directory.CreateDirectory(dir);
                // config.dat exactly as 0.5.5 writes it (Config.Save, then SetPrefs from the pill and --set), plus its nonce.txt.
                File.WriteAllLines(path, new[]
                {
                    "server=https://recitbot.com", "account_id=" + acctA, "device_id=" + devA, "ffmpeg=C:\\Rec\\ffmpeg\\ffmpeg.exe", "encoder=", "fps=30",
                    "device_token=" + Config.Protect(tokenA), "device_secret=" + Config.Protect("secret-A"),
                    "webcam=1", "camera=Full HD webcam", "webcam_px=360", "mirror=0", "webcam_shape=rect", "auto_open_link=false",
                    "pill_at_mon_f7b81f0c95=12,-3",
                });
                File.WriteAllText(Path.Combine(dir, "nonce.txt"), "1731650000000");
                var m = Config.Load(dir);
                check("accounts: v1 config.dat (0.5.5) loads as one account, same ids, token and secret", m != null && same(m.Accounts, new[] { a }));
                check("accounts: v1 machine-wide settings kept", m.Webcam && m.Camera == "Full HD webcam" && m.WebcamPx == 360 && !m.Mirror && m.Shape == "rect"
                    && m.PillAt.ContainsKey("mon_f7b81f0c95") && m.Ffmpeg == "C:\\Rec\\ffmpeg\\ffmpeg.exe" && !m.ReadBool("auto_open_link", true));
                string text = File.ReadAllText(path);
                var lines = File.ReadAllLines(path);
                bool topLevel = false;
                foreach (var l in lines) if (Array.IndexOf(Config.AccountKeys, Config.Key(l)) >= 0) topLevel = true;
                check("accounts: v1 written back as v2 (version line first, no top-level account keys, secrets protected)",
                    lines[0] == Config.VersionLine && !topLevel && Array.IndexOf(lines, "account.0.account_id=" + acctA) >= 0
                    && Array.IndexOf(lines, "account.0.device_id=" + devA) >= 0 && !text.Contains(tokenA) && !text.Contains("secret-A"));
                check("accounts: v1 nonce.txt moves to the account's nonce file", !File.Exists(Path.Combine(dir, "nonce.txt"))
                    && File.ReadAllText(Config.NoncePath(dir, devA)) == "1731650000000");
                var again = Config.Load(dir);
                check("accounts: v2 re-load gives the same account and settings, file unchanged", same(again.Accounts, new[] { a })
                    && again.Camera == "Full HD webcam" && File.ReadAllText(path) == text);
                var old = new Dictionary<string, string>
                {
                    { "type", "stop" }, { "recording_id", "R1R1R1R1R1R1" }, { "nonce", "1731650000000" }, { "exp", "1731650060" },
                    { "account_id", acctA }, { "device_id", devA },
                };
                old["mac"] = CommandVerifier.HmacHex("secret-A", CommandVerifier.Canonical(old));
                check("accounts: migrated account still refuses a replay of its last nonce",
                    new CommandVerifier(acctA, devA, "secret-A", Config.NoncePath(dir, devA)).Verify(old, 1731650000) == "replayed nonce");

                // Adding a second account keeps the migrated one; pairing it again refreshes only its own entry.
                check("accounts: add account (pairing code of another account)", Config.UpsertAccount(dir, b, null));
                var two = Config.Load(dir);
                check("accounts: add account keeps the migrated entry first and unchanged", same(two.Accounts, new[] { a, b })
                    && two.Camera == "Full HD webcam" && two.Ffmpeg == "C:\\Rec\\ffmpeg\\ffmpeg.exe" && !two.ReadBool("auto_open_link", true));
                var b2 = new Config.Account { Server = b.Server, AccountId = acctB, DeviceId = devB, DeviceToken = "ardt_DBBBBBBBBBBBBBBBBBBBBB_newtokennewtokennewtokennewtokennewtok", DeviceSecret = "secret-B2" };
                check("accounts: refresh account (same account paired again)", !Config.UpsertAccount(dir, b2, null));
                check("accounts: refresh replaces only that entry", same(Config.Load(dir).Accounts, new[] { a, b2 }));

                // The enroll token rule: only the token of the account the installer names.
                var held = new List<Config.Account> { a, b2 };
                check("accounts: enroll sends the token of the named account only",
                    Config.EnrollToken(held, acctA) == tokenA && Config.EnrollToken(held, acctB) == b2.DeviceToken);
                check("accounts: enroll without --account, or for an account not paired here, sends no token",
                    Config.EnrollToken(held, null) == null && Config.EnrollToken(held, "") == null && Config.EnrollToken(held, "CCCCCCCCCCCCCCCCCCCCCC") == null
                    && Config.EnrollToken(new List<Config.Account>(), acctA) == null);
                string body = EnrollBody("ABCDEFGHIJ12", "PC", Config.EnrollToken(held, acctA));
                check("accounts: enroll body for account A never carries account B's token", body.Contains(tokenA) && !body.Contains(b2.DeviceToken));

                // Secrets that do not decrypt for this user skip only their entry.
                var withBad = new List<string>(File.ReadAllLines(path));
                int bt = withBad.FindIndex(l => l.StartsWith("account.1.device_token="));
                withBad[bt] = "account.1.device_token=AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA";
                File.WriteAllLines(path, withBad);
                check("accounts: an account whose DPAPI blob does not decrypt is skipped, the others load", same(Config.Load(dir).Accounts, new[] { a }));
                check("accounts: pairing again replaces the unreadable entry", Config.UpsertAccount(dir, b2, null) && same(Config.Load(dir).Accounts, new[] { a, b2 }));

                // Removing one account (scoped uninstall or a revoked device) keeps the others.
                File.WriteAllText(Config.NoncePath(dir, devB), "5");
                check("accounts: remove of another device of the account changes nothing", same(Config.RemoveAccount(dir, acctB, devA), new[] { a, b2 }));
                check("accounts: remove one account keeps the other", same(Config.RemoveAccount(dir, acctB, devB), new[] { a })
                    && same(Config.Load(dir).Accounts, new[] { a }) && !File.Exists(Config.NoncePath(dir, devB)) && Config.Load(dir).Camera == "Full HD webcam");
                check("accounts: removing the last account leaves no account", Config.RemoveAccount(dir, acctA, devA).Count == 0
                    && Config.Load(dir).Accounts.Count == 0 && File.Exists(path));

                // Concurrent enrolls (the agent and an --enroll run share config.lock): no account is lost.
                var threads = new List<Thread>();
                for (int i = 0; i < 6; i++)
                {
                    string n = "C" + i + "CCCCCCCCCCCCCCCCCCCC";
                    var t = new Thread(delegate () { Config.UpsertAccount(dir, new Config.Account { Server = "https://recitbot.com", AccountId = n, DeviceId = "D" + n, DeviceToken = "t" + n, DeviceSecret = "s" }, null); });
                    threads.Add(t);
                    t.Start();
                }
                foreach (var t in threads) t.Join();
                check("accounts: concurrent enrolls keep every account", Config.Load(dir).Accounts.Count == 6);

                // The running agent's watch: config.dat replaced by an enroll is seen; other files are not.
                var seen = new ManualResetEvent(false);
                using (var w = new ConfigWatch(dir, delegate { seen.Set(); }))
                {
                    File.WriteAllText(Path.Combine(dir, "agent.log"), "x");
                    bool quiet = !seen.WaitOne(1500);
                    Config.UpsertAccount(dir, a, null);
                    check("accounts: the agent sees an account added while it runs (config.dat watch)", quiet && seen.WaitOne(5000));
                }
            }
            catch (Exception e) { check("accounts: config " + e.GetType().Name + " " + e.Message, false); }
            finally { try { Directory.Delete(dir, true); } catch { } }

            // Routing: every recording belongs to the account that started it.
            var o = new RecordingOwners();
            check("accounts: per-account routing (a recording's owner is the account that started it)",
                o.Claim("RECA00000001", acctA) && o.Claim("RECB00000001", acctB) && o.Owner("RECA00000001") == acctA
                && o.Owner("RECB00000001") == acctB && o.Owner("RECX00000001") == null);
            check("accounts: another account cannot claim, stop or see a recording", !o.Claim("RECA00000001", acctB)
                && !o.Owns("RECA00000001", acctB) && o.Owns("RECA00000001", acctA) && o.Owner("RECA00000001") == acctA);
            for (int i = 0; i < 70; i++) o.Claim("RECZ" + i.ToString("D8"), acctB);
            check("accounts: only the recent recordings are remembered", o.Owner("RECA00000001") == null && o.Owner("RECZ00000069") == acctB);
            var r = new RecordingOwners();
            check("accounts: machine-wide busy (a recording of any account refuses every start)",
                !r.Refuses("RECA00000002", acctA, false) && r.Refuses("RECB00000002", acctB, true) && r.Refuses("RECA00000003", acctA, true));
            check("accounts: a start with another account's recording id is refused", r.Refuses("RECA00000002", acctB, false));
            var startA = new Dictionary<string, string>
            {
                { "type", "start" }, { "recording_id", "RECA00000004" }, { "max_seconds", "30" }, { "mic", "false" }, { "nonce", "1731650000000" },
                { "exp", "1731650060" }, { "account_id", acctA }, { "device_id", devA }, { "upload_token", "1731651800.tok" },
            };
            startA["mac"] = CommandVerifier.HmacHex("secret-A", CommandVerifier.Canonical(startA));
            check("accounts: a command signed for one account is refused on another account's connection",
                new CommandVerifier(acctB, devB, "secret-B", null).Verify(startA, 1731650000) == "bad mac"
                && new CommandVerifier(acctA, devA, "secret-A", null).Verify(startA, 1731650000) == null);

            // The uninstall scope (signed) and the ack.
            const string sa = "BBBBBBBBBBBBBBBBBBBBBB", sd = "CCCCCCCCCCCCCCCCCCCCCC";
            var un = new Dictionary<string, string>
            {
                { "type", "uninstall" }, { "recording_id", "Unin5tall01" }, { "nonce", "1731650000000" }, { "exp", "1731650060" }, { "account_id", sa }, { "device_id", sd },
            };
            check("accounts: uninstall without scope = all (a server from before scopes: full removal)",
                SelfUninstaller.ScopeOf(un) == SelfUninstaller.Scope.All && SelfUninstaller.ScopeRejection(un) == null);
            un["scope"] = "account";
            check("accounts: scope is a signed block", CommandVerifier.Canonical(un) == "v1|uninstall|Unin5tall01||0|1731650000000|1731650060|" + sa + "|" + sd + "||scope|account");
            check("accounts: scope account = only this account", SelfUninstaller.ScopeOf(un) == SelfUninstaller.Scope.Account && SelfUninstaller.ScopeRejection(un) == null);
            un["scope"] = "all";
            un["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(un));
            check("accounts: signed scope all verifies", new CommandVerifier(sa, sd, "test-device-secret", null).Verify(un, 1731650000) == null
                && SelfUninstaller.ScopeOf(un) == SelfUninstaller.Scope.All);
            var forged = new Dictionary<string, string>(un);
            forged["scope"] = "account";
            check("accounts: scope changed in transit rejected", new CommandVerifier(sa, sd, "test-device-secret", null).Verify(forged, 1731650000) == "bad mac");
            var odd = new Dictionary<string, string>(un);
            odd["scope"] = "device";
            odd["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(odd));
            string oddReason = new CommandVerifier(sa, sd, "test-device-secret", null).Verify(odd, 1731650000) ?? SelfUninstaller.ScopeRejection(odd);
            check("accounts: unknown scope (signed) rejected as an invalid command, nothing removed", SelfUninstaller.ScopeOf(odd) == null
                && oddReason == "unknown uninstall scope" && !SelfUninstaller.Commanded(oddReason, odd));
            var nul = new Dictionary<string, string>(un);
            nul["scope"] = null;
            check("accounts: null or empty scope rejected; the scope check is for uninstall commands only", SelfUninstaller.ScopeOf(nul) == null
                && SelfUninstaller.ScopeRejection(nul) != null
                && SelfUninstaller.ScopeRejection(new Dictionary<string, string> { { "type", "uninstall" }, { "scope", "" } }) != null
                && SelfUninstaller.ScopeRejection(new Dictionary<string, string> { { "type", "start" }, { "scope", "device" } }) == null);
            check("accounts: scoped uninstall removes one account while others remain",
                !SelfUninstaller.RemovesAll(SelfUninstaller.Scope.Account, 1) && !SelfUninstaller.RemovesAll(SelfUninstaller.Scope.Account, 3));
            check("accounts: last account (or scope all) = full removal", SelfUninstaller.RemovesAll(SelfUninstaller.Scope.Account, 0)
                && SelfUninstaller.RemovesAll(SelfUninstaller.Scope.All, 2));
            check("accounts: ack carries accounts_remaining", SelfUninstaller.AckJson("Unin5tall01", 1)
                == "{\"type\":\"uninstall_ack\",\"request_id\":\"Unin5tall01\",\"accounts_remaining\":1}");
            var ackf = Json.ParseFlat(SelfUninstaller.AckJson("Unin5tall01", 0));
            check("accounts: full-removal ack says 0 accounts remaining", ackf["accounts_remaining"] == "0" && ackf["type"] == "uninstall_ack");
            const string bare = "{\"type\":\"uninstall_ack\",\"accounts_remaining\":0}";
            check("accounts: full-removal ack on the other sockets has no request_id", SelfUninstaller.AckJson(null, 0) == bare);
            check("accounts: revoke of one account keeps the rest (last one = full removal)",
                !SelfUninstaller.RemovesAll(SelfUninstaller.Scope.Account, 1) && SelfUninstaller.RemovesAll(SelfUninstaller.Scope.Account, 0));

            // Which sockets get an ack: the commanding one always; for a full removal also every other connected account.
            const string acctC = "EEEEEEEEEEEEEEEEEEEEEE";
            string ridAck = SelfUninstaller.AckJson("Unin5tall01", 0);
            Func<List<KeyValuePair<string, string>>, string> acks = delegate (List<KeyValuePair<string, string>> l)
            {
                var sb = new StringBuilder();
                foreach (var x in l) sb.Append(x.Key).Append(" <- ").Append(x.Value).Append("\n");
                return sb.ToString();
            };
            check("accounts: scope all acks the command, then request_id-less acks on every other connected socket",
                acks(SelfUninstaller.Acks(acctA, "Unin5tall01", true, 2, new[] { acctB, acctA, acctC }))
                == acctA + " <- " + ridAck + "\n" + acctB + " <- " + bare + "\n" + acctC + " <- " + bare + "\n");
            check("accounts: scope account with accounts left acks the commanding socket only (no acks on the others)",
                acks(SelfUninstaller.Acks(acctA, "Unin5tall01", false, 2, new[] { acctA, acctB, acctC }))
                == acctA + " <- " + SelfUninstaller.AckJson("Unin5tall01", 2) + "\n");
            check("accounts: full removal: accounts whose sockets are not connected get nothing",
                acks(SelfUninstaller.Acks(acctA, "Unin5tall01", true, 0, new[] { acctA })) == acctA + " <- " + ridAck + "\n");
            check("accounts: 410 full removal sends request_id-less acks on the other connected sockets only",
                acks(SelfUninstaller.Acks(acctB, null, true, 0, new[] { acctA, acctC })) == acctA + " <- " + bare + "\n" + acctC + " <- " + bare + "\n");
            check("accounts: 410 for one account (others left) sends no ack", SelfUninstaller.Acks(acctB, null, false, 1, new[] { acctA, acctC }).Count == 0);

            // 410 device_revoked: its scope says what goes.
            Func<string, SelfUninstaller.Scope?> r410 = delegate (string body) { return Revocation.RevokedScope(410, body); };
            check("accounts: 410 scope account removes only that account (others left)",
                r410("{\"error\":\"device_revoked\",\"scope\":\"account\"}") == SelfUninstaller.Scope.Account && !SelfUninstaller.RemovesAll(SelfUninstaller.Scope.Account, 1));
            check("accounts: 410 scope account for the last account = full removal",
                SelfUninstaller.RemovesAll(r410("{\"error\":\"device_revoked\",\"scope\":\"account\"}") ?? SelfUninstaller.Scope.All, 0));
            check("accounts: 410 scope all removes everything", r410("{\"error\":\"device_revoked\",\"scope\":\"all\"}") == SelfUninstaller.Scope.All
                && SelfUninstaller.RemovesAll(SelfUninstaller.Scope.All, 2));
            check("accounts: 410 without scope (a server from before scopes) removes everything",
                r410("{\"error\":\"device_revoked\"}") == SelfUninstaller.Scope.All && r410("{\"error\":\"device_revoked\",\"scope\":null}") == SelfUninstaller.Scope.All);
            check("accounts: 410 with an unknown scope removes only that account",
                r410("{\"error\":\"device_revoked\",\"scope\":\"device\"}") == SelfUninstaller.Scope.Account);
            check("accounts: 410 scope parsing needs device_revoked", r410("{\"error\":\"gone\",\"scope\":\"all\"}") == null
                && Revocation.RevokedScope(401, "{\"error\":\"device_revoked\",\"scope\":\"all\"}") == null);

            // Cross-check with the Worker: the frame exactly as DeviceHub.signAndSend serializes it, and the string
            // worker/src/device-hub.ts canonicalCommand builds for those fields (literals read off that function).
            string wire = "{\"type\":\"uninstall\",\"recording_id\":\"Un1nstallRq\",\"max_seconds\":0,\"mic\":false,\"nonce\":1731650000000,"
                + "\"exp\":1731650060,\"account_id\":\"" + sa + "\",\"device_id\":\"" + sd + "\",\"upload_token\":\"\"";
            const string workerAccount = "v1|uninstall|Un1nstallRq|0|0|1731650000000|1731650060|BBBBBBBBBBBBBBBBBBBBBB|CCCCCCCCCCCCCCCCCCCCCC||scope|account";
            const string workerNone = "v1|uninstall|Un1nstallRq|0|0|1731650000000|1731650060|BBBBBBBBBBBBBBBBBBBBBB|CCCCCCCCCCCCCCCCCCCCCC|";
            foreach (var c in new[]
            {
                new { Name = "scope account", Json = wire + ",\"scope\":\"account\"}", Want = workerAccount, Scope = SelfUninstaller.Scope.Account },
                new { Name = "no scope", Json = wire + "}", Want = workerNone, Scope = SelfUninstaller.Scope.All },
            })
            {
                var wf = Json.ParseFlat(c.Json);
                check("accounts: canonical uninstall (" + c.Name + ") = worker canonicalCommand", CommandVerifier.Canonical(wf) == c.Want);
                wf["mac"] = CommandVerifier.HmacHex("test-device-secret", c.Want);
                string wr = new CommandVerifier(sa, sd, "test-device-secret", null).Verify(wf, 1731650000) ?? SelfUninstaller.ScopeRejection(wf);
                check("accounts: uninstall (" + c.Name + ") signed over the worker's string verifies", wr == null && SelfUninstaller.Commanded(wr, wf)
                    && SelfUninstaller.ScopeOf(wf) == c.Scope);
            }

            // The agent's connections follow config.dat.
            var b3 = new Config.Account { Server = b.Server, AccountId = acctB, DeviceId = devB, DeviceToken = "ardt_DBBBBBBBBBBBBBBBBBBBBB_othertokenothertokenothertokenothertoke", DeviceSecret = "secret-B" };
            Func<AccountSet.Diff, string> show = delegate (AccountSet.Diff d)
            {
                var st = new List<string>();
                foreach (var x in d.Start) st.Add(x.AccountId + ":" + x.DeviceToken.Substring(x.DeviceToken.Length - 4));
                return string.Join(",", st) + "|" + string.Join(",", d.Stop);
            };
            check("accounts: account added while running is connected", show(AccountSet.Compare(new List<Config.Account> { a }, new List<Config.Account> { a, b })) == acctB + ":kenB|");
            check("accounts: removed account is disconnected", show(AccountSet.Compare(new List<Config.Account> { a, b }, new List<Config.Account> { a })) == "|" + acctB);
            check("accounts: refreshed account reconnects with its new token",
                show(AccountSet.Compare(new List<Config.Account> { a, b }, new List<Config.Account> { a, b3 })) == acctB + ":toke|" + acctB);
            check("accounts: unchanged list changes nothing", show(AccountSet.Compare(new List<Config.Account> { a, b }, new List<Config.Account> { b, a })) == "|");

            InstallerAddAccountSelfTest(check);
        }

        /// install.template.ps1 on a PC that already has the recorder: a code only adds its account when the installed exe
        /// is this version or newer (nothing stopped or replaced), an older one is updated in place, a failed pairing
        /// restarts the recorder with the accounts it had. The version check block runs in a hidden powershell.exe against
        /// copies of this exe in %TEMP%; the rest is checked in the template's text (running the installer itself would
        /// touch the real AgentRecorder task).
        static void InstallerAddAccountSelfTest(Action<string, bool> check)
        {
            string template = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", "recorder", "install.template.ps1"));
            if (!File.Exists(template)) { check("installer add account: recorder\\install.template.ps1 next to the build (" + template + ")", false); return; }
            string text = File.ReadAllText(template).Replace("\r\n", "\n");
            int a = text.IndexOf("# --- add account"), b = text.IndexOf("# --- end add account");
            int skip = text.IndexOf("  if (-not $addOnly) {"), stop = text.IndexOf("  Stop-Recorder\n"), swap = text.IndexOf("Expand-Archive"), enroll = text.IndexOf("--enroll --server");
            check("installer: a code on a same or newer install skips download, stop and swap; pairs with --account; prints the paired device",
                skip > 0 && stop > skip && swap > stop && enroll > swap && text.IndexOf("  }\n\n  if ($Code) {") > swap
                && text.Contains("if ($Account) { $psi.Arguments += \" --account $Account\" }") && text.Contains("$psi.RedirectStandardOutput = $true")
                && text.Contains("$_ -like 'device=*'") && text.Contains("$addOnly = $Code -and (Test-AddAccountOnly $current $RecorderVersion ([bool]$Update))")
                && text.Contains("if ($addOnly -and @(Get-Recorder).Count) {"));
            check("installer: a failed pairing on a PC with paired accounts restarts the recorder",
                text.Contains("if (($Update -or $hadAccounts) -and $swapped -and $exe") && text.Contains("$hadAccounts = Test-Path -LiteralPath $config"));
            if (a < 0 || b < a) { check("installer add account: block markers", false); return; }
            string block = text.Substring(a, b - a);
            string dir = Path.Combine(Path.GetTempPath(), "recitbot-multiacct-installer-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(dir);
                string self = Path.Combine(dir, "AgentRecorder.exe"), fake = Path.Combine(dir, "fake.exe");
                File.Copy(System.Reflection.Assembly.GetEntryAssembly().Location, self);
                File.WriteAllBytes(fake, new byte[] { 0x4d, 0x5a });
                string ps = block + "\r\n$ErrorActionPreference = 'Stop'\r\n"
                    + "'self=' + (Get-InstalledVersion " + SelfUninstaller.PsQuote(self) + ")\r\n"
                    + "'fake=' + [string](Get-InstalledVersion " + SelfUninstaller.PsQuote(fake) + ")\r\n"
                    + "'none=' + [string](Get-InstalledVersion " + SelfUninstaller.PsQuote(Path.Combine(dir, "missing.exe")) + ")\r\n"
                    + "'same=' + (Test-AddAccountOnly '" + Version + "' '" + Version + "' $false)\r\n"
                    + "'newer=' + (Test-AddAccountOnly '9.0.0' '" + Version + "' $false)\r\n"
                    + "'older=' + (Test-AddAccountOnly '0.5.5' '" + Version + "' $false)\r\n"
                    + "'missing=' + (Test-AddAccountOnly $null '" + Version + "' $false)\r\n"
                    + "'garbage=' + (Test-AddAccountOnly 'x.y' '" + Version + "' $false)\r\n"
                    + "'update=' + (Test-AddAccountOnly '" + Version + "' '" + Version + "' $true)\r\n";
                string err, output;
                int rc = HiddenPowerShell(ps, out err, out output);
                var res = new Dictionary<string, string>();
                foreach (var line in (output ?? "").Split('\n'))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) res[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
                Func<string, string> v = delegate (string k) { string x; return res.TryGetValue(k, out x) ? x : null; };
                if (rc != 0) check("installer add account sandbox: script ran (exit " + rc + ": " + (err ?? "").Trim() + ")", false);
                check("installer: installed version read from the exe (this build = " + Version + "); none for a non-.NET or missing exe",
                    v("self") == Version && v("fake") == "" && v("none") == "");
                check("installer adds the account to a same or newer install", v("same") == "True" && v("newer") == "True");
                check("installer updates an older install in place (or installs when there is none)",
                    v("older") == "False" && v("missing") == "False" && v("garbage") == "False" && v("update") == "False");
            }
            catch (Exception e) { check("installer add account sandbox: " + e.GetType().Name + " " + e.Message, false); }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void SelfUninstallSelfTest(Action<string, bool> check)
        {
            const string acct = "BBBBBBBBBBBBBBBBBBBBBB", dev = "CCCCCCCCCCCCCCCCCCCCCC", rid = "Unin5tall01";
            var un = new Dictionary<string, string>
            {
                { "type", "uninstall" }, { "recording_id", rid }, { "nonce", "1731650000000" }, { "exp", "1731650060" },
                { "account_id", acct }, { "device_id", dev },
            };
            check("uninstall canonical form", CommandVerifier.Canonical(un) == "v1|uninstall|" + rid + "||0|1731650000000|1731650060|" + acct + "|" + dev + "|");
            un["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(un));
            var uv = new CommandVerifier(acct, dev, "test-device-secret", null);
            string ur = uv.Verify(un, 1731650000);
            check("uninstall command verifies and uninstalls", ur == null && SelfUninstaller.Commanded(ur, un));
            check("uninstall ack frame", SelfUninstaller.AckJson(rid, 0) == "{\"type\":\"uninstall_ack\",\"request_id\":\"" + rid + "\",\"accounts_remaining\":0}");
            string replay = uv.Verify(un, 1731650000);
            check("uninstall: replayed command rejected, no uninstall", replay == "replayed nonce" && !SelfUninstaller.Commanded(replay, un));
            var tampered = new Dictionary<string, string>(un);
            tampered["recording_id"] = "Unin5tall02";
            string tr = new CommandVerifier(acct, dev, "test-device-secret", null).Verify(tampered, 1731650000);
            check("uninstall: tampered command rejected, no uninstall", tr == "bad mac" && !SelfUninstaller.Commanded(tr, tampered));
            var asStart = new Dictionary<string, string>(un);
            asStart["type"] = "start";
            check("uninstall: type swapped to start rejected", new CommandVerifier(acct, dev, "test-device-secret", null).Verify(asStart, 1731650000) == "bad mac");
            string ex = new CommandVerifier(acct, dev, "test-device-secret", null).Verify(un, 1731650061);
            string wd = new CommandVerifier(acct, "DDDDDDDDDDDDDDDDDDDDDD", "test-device-secret", null).Verify(un, 1731650000);
            string wk = new CommandVerifier(acct, dev, "wrong-secret", null).Verify(un, 1731650000);
            check("uninstall: expired / wrong device / wrong key rejected, no uninstall", ex == "expired" && wd == "wrong device" && wk == "bad mac"
                && !SelfUninstaller.Commanded(ex, un) && !SelfUninstaller.Commanded(wd, un) && !SelfUninstaller.Commanded(wk, un));
            var start = new Dictionary<string, string>(un);
            start["type"] = "start";
            check("uninstall: other verified commands never uninstall", !SelfUninstaller.Commanded(null, start) && !SelfUninstaller.Commanded(null, new Dictionary<string, string>())
                && !SelfUninstaller.Commanded(null, null));

            const string revoked = "{\"error\":\"device_revoked\"}";
            check("revoked: 410 + device_revoked", Revocation.IsRevoked(410, revoked) && Revocation.IsRevoked(410, " { \"error\" : \"device_revoked\", \"x\": 1 } "));
            bool other = false;
            foreach (int st in new[] { 0, 200, 401, 403, 404, 409, 426, 500, 502, 503 }) other |= Revocation.IsRevoked(st, revoked);
            check("revoked: 0, 200, 401, 403, 404, 409, 426, 500, 502, 503 with the same body are not", !other);
            check("revoked: 410 with another, empty, null, non-JSON or nested body is not", !Revocation.IsRevoked(410, "{\"error\":\"gone\"}")
                && !Revocation.IsRevoked(410, "") && !Revocation.IsRevoked(410, null) && !Revocation.IsRevoked(410, "device_revoked")
                && !Revocation.IsRevoked(410, "<html>410 Gone</html>") && !Revocation.IsRevoked(410, "{\"error\":{\"code\":\"device_revoked\"}}")
                && !Revocation.IsRevoked(410, "{\"error\":\"DEVICE_REVOKED\"}") && !Revocation.IsRevoked(410, "{\"err\":\"device_revoked\"}"));
            check("revoked: 410 + device_revoked with a scope (account, all) is revoked", Revocation.IsRevoked(410, "{\"error\":\"device_revoked\",\"scope\":\"account\"}")
                && Revocation.IsRevoked(410, "{\"error\":\"device_revoked\",\"scope\":\"all\"}"));

            string pb = Revocation.ProbeBody("fake-token-placeholder", "windows");
            Dictionary<string, string> pf = null;
            try { pf = Json.ParseFlat(pb); } catch { }
            check("revocation probe body: JSON with exactly the dummy code, name, platform windows and the device_token", pf != null && pf.Count == 4
                && pf["code"] == "0000000000" && pf["name"] == "revocation-check" && pf["platform"] == "windows" && pf["device_token"] == "fake-token-placeholder");
            Dictionary<string, string> pm = null;
            try { pm = Json.ParseFlat(Revocation.ProbeBody("a\"b\\c", "macos")); } catch { }
            check("revocation probe body: platform macos, token escaped", pm != null && pm["platform"] == "macos" && pm["device_token"] == "a\"b\\c"
                && pm["code"] == "0000000000");

            const string m410 = "The server returned status code '410' when status code '101' was expected.";
            check("handshake status: 410 and 401 from the WebSocketException text, also when wrapped",
                Revocation.HandshakeStatus(new WebSocketException(m410)) == 410
                && Revocation.HandshakeStatus(new WebSocketException(m410.Replace("410", "401"))) == 401
                && Revocation.HandshakeStatus(new AggregateException("x", new WebSocketException(m410))) == 410);
            check("handshake status: network errors are 0", Revocation.HandshakeStatus(new WebSocketException("Unable to connect to the remote server",
                    new WebException("The remote name could not be resolved: 'recitbot.com'", WebExceptionStatus.NameResolutionFailure))) == 0
                && Revocation.HandshakeStatus(new WebException("The operation has timed out", WebExceptionStatus.Timeout)) == 0
                && Revocation.HandshakeStatus(new IOException("Unable to read data from the transport connection")) == 0
                && Revocation.HandshakeStatus(null) == 0 && Revocation.HandshakeBody(new WebSocketException(m410)) == null);

            // The reconnect loop's log line (synthetic exceptions shaped like .NET's refused handshake; no network).
            var refused = new WebSocketException("Unable to connect to the remote server",
                new WebException("The remote server returned an error: (401) Unauthorized.", WebExceptionStatus.ProtocolError));
            const string plain = "connection error: WebSocketException Unable to connect to the remote server";
            string l401 = Revocation.ConnectionErrorLine(refused, 401);
            check("connection error line: 401 names the handshake status and says not paired", l401.StartsWith(plain)
                && l401.Contains("(handshake HTTP 401)") && l401.Contains("no longer paired")
                && Revocation.ConnectionErrorLine(new WebSocketException(m410.Replace("410", "401")),
                    Revocation.HandshakeStatus(new WebSocketException(m410.Replace("410", "401")))).Contains("(handshake HTTP 401)"));
            string l403 = Revocation.ConnectionErrorLine(refused, 403);
            check("connection error line: 403 names the status, not unpaired", l403 == plain + " (handshake HTTP 403)" && !l403.Contains("no longer paired"));
            check("connection error line: status 0 unchanged", Revocation.ConnectionErrorLine(refused, 0) == plain);
            check("inner error line: the inner exception's type and message, null without one",
                Revocation.InnerErrorLine(refused) == "inner: WebException The remote server returned an error: (401) Unauthorized."
                && Revocation.InnerErrorLine(new WebSocketException("x")) == null && Revocation.InnerErrorLine(null) == null);
            string l500 = Revocation.ConnectionErrorLine(refused, 500);
            check("connection error line: 500 names the status, not unpaired", l500 == plain + " (handshake HTTP 500)" && !l500.Contains("no longer paired"));

            string retry = EnrollRetryBody(410, revoked, "ABCD1234", "Office PC", "fake-token-placeholder");
            check("enroll 410 retry body has no device_token key", retry != null && !retry.Contains("device_token")
                && Json.ParseFlat(retry)["code"] == "ABCD1234" && Json.ParseFlat(retry)["platform"] == "windows");
            check("enroll: no retry for other answers or without a held token", EnrollRetryBody(401, revoked, "ABCD1234", "Office PC", "t") == null
                && EnrollRetryBody(410, "{\"error\":\"gone\"}", "ABCD1234", "Office PC", "t") == null && EnrollRetryBody(410, revoked, "ABCD1234", "Office PC", null) == null);

            check("ps quote: quotes doubled, typographic ones too", SelfUninstaller.PsQuote("C:\\Users\\O'Brien\\x") == "'C:\\Users\\O''Brien\\x'"
                && SelfUninstaller.PsQuote("a\u2019b") == "'a\u2019\u2019b'" && SelfUninstaller.PsQuote("$env:x `n") == "'$env:x `n'" && SelfUninstaller.PsQuote(null) == "''");
            string plan = SelfUninstaller.Script("C:\\Users\\O'Brien\\AppData\\Local\\AgentRecorder\\", "C:\\Users\\O'Brien\\AppData\\Local\\AgentRecorder\\AgentRecorder.exe",
                4242, SelfUninstaller.TaskNames, SelfUninstaller.RunValues, SelfUninstaller.StartupLinks);
            check("uninstall plan: silent, waits for the agent pid, stops only AgentRecorder",
                plan.Contains("$ErrorActionPreference = 'SilentlyContinue'") && plan.Contains("$agent = 4242\r\n") && plan.Contains("$i -lt 120 -and (Get-Process -Id $agent")
                && plan.Contains("if ($p -and $p.ProcessName -eq 'AgentRecorder') { Stop-Process -Id $agent -Force"));
            check("uninstall plan: stray ffmpeg of the install folder, task, Run values, Startup links",
                plan.Contains("Name='ffmpeg.exe'") && plan.Contains("$_.CommandLine.IndexOf($dir")
                && plan.Contains("foreach ($n in @('AgentRecorder')) {\r\n  foreach ($t in @(Get-ScheduledTask -TaskName $n)) {")
                && plan.Contains("foreach ($n in @('AgentRecorder', 'Recitbot')) {\r\n  $v = (Get-ItemProperty -LiteralPath $run -Name $n).$n")
                && plan.Contains("$run = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'\r\n")
                && plan.Contains("$startup = [Environment]::GetFolderPath('Startup')\r\n")
                && plan.Contains("foreach ($n in @('AgentRecorder.lnk', 'Recitbot.lnk')) {"));
            check("uninstall plan: task, Run values and Startup links removed only when they start this exe",
                plan.Contains("$exe = 'C:\\Users\\O''Brien\\AppData\\Local\\AgentRecorder\\AgentRecorder.exe'\r\n")
                && plan.Contains("function Resolve-Exe([string]$p)") && plan.Contains("function Get-CmdExe([string]$cmd)")
                && plan.Contains("[string]::Equals($p, $exe, [StringComparison]::OrdinalIgnoreCase)")
                && plan.Contains("    $own = $acts.Count -gt 0\r\n    foreach ($a in $acts) { if (-not (Test-Self (Resolve-Exe $a.Execute))) { $own = $false } }\r\n"
                    + "    if ($own) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false }")
                && plan.Contains("  if (Test-Self (Get-CmdExe $v)) { Remove-ItemProperty -LiteralPath $run -Name $n }")
                && plan.Contains("    if (Test-Self (Resolve-Exe $sc.TargetPath)) { Remove-Item -LiteralPath $f -Force }")
                && !plan.Contains("Unregister-ScheduledTask -TaskName 'AgentRecorder'") && !plan.Contains("-Name 'AgentRecorder'"));
            string boxPlan = SelfUninstaller.Script("C:\\X", "C:\\X\\AgentRecorder.exe", 1, new string[0], null, null, "HKCU:\\Software\\T'x\\Run", "C:\\T\u2019s");
            check("uninstall plan: sandbox Run key and Startup folder quoted, empty lists",
                boxPlan.Contains("$run = 'HKCU:\\Software\\T''x\\Run'\r\n") && boxPlan.Contains("$startup = 'C:\\T\u2019\u2019s'\r\n")
                && boxPlan.Contains("foreach ($n in @()) {") && !boxPlan.Contains("GetFolderPath('Startup')"));
            check("uninstall plan: folder removed with retries, then the script itself, quotes escaped",
                plan.Contains("$dir = 'C:\\Users\\O''Brien\\AppData\\Local\\AgentRecorder'\r\n") && plan.Contains("Remove-Item -LiteralPath $dir -Recurse -Force")
                && plan.Contains("$i -lt 20 -and (Test-Path -LiteralPath $dir)") && plan.EndsWith("Remove-Item -LiteralPath $PSCommandPath -Force\r\n")
                && plan.IndexOf("Remove-Item -LiteralPath $dir") > plan.IndexOf("Unregister-ScheduledTask"));
            check("uninstall helper command line: hidden, no profile, no prompts",
                SelfUninstaller.CommandLine("C:\\T\\recitbot-uninstall-1.ps1") == "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\\T\\recitbot-uninstall-1.ps1\"");

            const string lad = "C:\\Users\\u\\AppData\\Local", up = "C:\\Users\\u", tmp = "C:\\Users\\u\\AppData\\Local\\Temp\\";
            string inst = lad + "\\AgentRecorder";
            Func<string, bool> all = delegate (string p) { return true; };
            Func<string, string, string> guard = delegate (string d, string data) { return SelfUninstaller.InstalledCheck(d, data, lad, up, tmp, all); };
            check("install guard: accepts the installed folder", guard(inst, inst) == null && guard(inst + "\\", inst) == null && guard(inst, inst.ToUpperInvariant() + "\\") == null);
            check("install guard: refuses drive roots", guard("C:\\", "C:\\") != null && guard("D:", "D:") != null && guard("\\\\srv\\share", "\\\\srv\\share") != null);
            check("install guard: refuses LOCALAPPDATA / USERPROFILE / TEMP and folders above them", guard(lad, lad) != null && guard(up, up) != null
                && guard(tmp, tmp) != null && guard("C:\\Users", "C:\\Users") != null && guard("C:\\Users\\u\\AppData", "C:\\Users\\u\\AppData") != null);
            check("install guard: refuses a data folder that is not the exe folder, relative or empty paths", guard(inst, lad + "\\Other") != null
                && guard(inst, null) != null && guard("AgentRecorder", "AgentRecorder") != null && guard("", "") != null);
            check("install guard: refuses a folder without AgentRecorder.exe or config.dat",
                SelfUninstaller.InstalledCheck(inst, inst, lad, up, tmp, delegate (string p) { return !p.EndsWith("config.dat"); }) != null
                && SelfUninstaller.InstalledCheck(inst, inst, lad, up, tmp, delegate (string p) { return !p.EndsWith("AgentRecorder.exe"); }) != null);

            UninstallSandboxSelfTest(check);
        }

        /// The real helper (SelfUninstaller.Launch: hidden, detached) against a throwaway install in %TEMP% whose name has
        /// both kinds of quote. Proves the scoping with fake names in sandbox places only (a throwaway HKCU key instead of
        /// Run, a %TEMP% folder instead of Startup, tasks named RecitbotSelftest<guid>a/b): entries starting the fake
        /// install's exe go, entries starting anything else stay. Nothing real is touched.
        static void UninstallSandboxSelfTest(Action<string, bool> check)
        {
            string g = Guid.NewGuid().ToString("N");
            string dir = Path.Combine(Path.GetTempPath(), "recitbot-uninst-selftest-" + g + " O'Brien\u2019s");
            string exe = Path.Combine(dir, "AgentRecorder.exe");
            string boxKey = "Software\\RecitbotSelftest-" + g;
            string runSub = boxKey + "\\Run";
            string startup = Path.Combine(Path.GetTempPath(), "recitbot-startup-selftest-" + g);
            string taskSelf = "RecitbotSelftest" + g + "a", taskOther = "RecitbotSelftest" + g + "b";
            const string notepad = "C:\\Windows\\System32\\notepad.exe";
            // Not a multiple of 4: never a Windows process id, so the helper waits for nothing and stops nothing.
            const int deadPid = 2147483645;
            string script = null;
            bool gone = false, tasks = false;
            try
            {
                Directory.CreateDirectory(Path.Combine(dir, "ffmpeg"));
                File.WriteAllBytes(exe, new byte[] { 0x4d, 0x5a });
                File.WriteAllText(Path.Combine(dir, "config.dat"), "server=https://example.invalid\r\n");
                File.WriteAllText(Path.Combine(dir, "ffmpeg", "readme.txt"), "x");
                check("uninstall sandbox: install guard accepts the fake install",
                    SelfUninstaller.InstalledCheck(dir, dir + "\\", Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.GetTempPath(), File.Exists) == null);

                using (var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(runSub))
                {
                    k.SetValue("selfQ", "\"" + exe + "\" --data \"" + dir + "\"");
                    k.SetValue("selfCase", exe.ToUpperInvariant());
                    k.SetValue("other", "\"C:\\Elsewhere\\AgentRecorder.exe\" --data x");
                    k.SetValue("otherPrefix", "\"" + exe + ".bak\"");
                }
                Directory.CreateDirectory(startup);
                MakeShortcut(Path.Combine(startup, "self.lnk"), exe);
                MakeShortcut(Path.Combine(startup, "other.lnk"), notepad);
                string err;
                int rc = HiddenPowerShell("$ErrorActionPreference = 'Stop'\r\n"
                    + "$s = New-ScheduledTaskSettingsSet -Hidden\r\n"
                    + "Register-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskSelf) + " -Action (New-ScheduledTaskAction -Execute "
                    + SelfUninstaller.PsQuote(exe) + ") -Settings $s | Out-Null\r\n"
                    + "Register-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskOther) + " -Action (New-ScheduledTaskAction -Execute "
                    + SelfUninstaller.PsQuote(notepad) + ") -Settings $s | Out-Null\r\n", out err);
                tasks = rc == 0 && TaskExists(taskSelf) && TaskExists(taskOther);
                if (!tasks) check("uninstall sandbox: fake tasks registered (exit " + rc + ": " + (err ?? "").Trim() + ")", false);

                script = SelfUninstaller.Launch(SelfUninstaller.Script(dir, exe, deadPid, new[] { taskSelf, taskOther },
                    new[] { "selfQ", "selfCase", "other", "otherPrefix" }, new[] { "self.lnk", "other.lnk" }, "HKCU:\\" + runSub, startup));
                var sw = Stopwatch.StartNew();
                while (sw.Elapsed.TotalSeconds < 60 && (Directory.Exists(dir) || File.Exists(script))) Thread.Sleep(250);
                gone = !Directory.Exists(dir);
                check("uninstall sandbox: helper removed the folder (" + sw.Elapsed.TotalSeconds.ToString("0.0") + " s)", gone);
                check("uninstall sandbox: helper deleted its own script", !File.Exists(script));

                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(runSub))
                {
                    check("uninstall sandbox: run value pointing at self removed", k != null && k.GetValue("selfQ") == null && k.GetValue("selfCase") == null);
                    check("uninstall sandbox: run value pointing elsewhere kept", k != null && k.GetValue("other") != null && k.GetValue("otherPrefix") != null);
                }
                check("uninstall sandbox: shortcut pointing at self removed", !File.Exists(Path.Combine(startup, "self.lnk")));
                check("uninstall sandbox: shortcut pointing elsewhere kept", File.Exists(Path.Combine(startup, "other.lnk")));
                if (tasks)
                {
                    check("uninstall sandbox: task pointing at self removed", !TaskExists(taskSelf));
                    check("uninstall sandbox: task pointing elsewhere kept", TaskExists(taskOther));
                }
            }
            catch (Exception e) { check("uninstall sandbox: " + e.GetType().Name + " " + e.Message, false); }
            finally
            {
                try { Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(boxKey, false); } catch { }
                try { if (Directory.Exists(startup)) Directory.Delete(startup, true); } catch { }
                try
                {
                    string ignored;
                    HiddenPowerShell("Unregister-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskSelf) + " -Confirm:$false -ErrorAction SilentlyContinue\r\n"
                        + "Unregister-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskOther) + " -Confirm:$false -ErrorAction SilentlyContinue\r\n", out ignored);
                }
                catch { }
                try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
                try { if (script != null && File.Exists(script)) File.Delete(script); } catch { }
            }
        }

        /// The update's live autostart check (SelfUpdater.StartsThisExe) against a throwaway install in %TEMP%, a throwaway
        /// HKCU key, a %TEMP% folder for Startup and tasks named RecitbotSelftestUpdate<guid>a/b. Read-only on everything
        /// else; the real AgentRecorder task, Run key and Startup folder are never looked at.
        static void UpdateAutostartSandboxSelfTest(Action<string, bool> check)
        {
            string g = Guid.NewGuid().ToString("N");
            string dir = Path.Combine(Path.GetTempPath(), "recitbot-update-noautostart-" + g);
            string exe = Path.Combine(dir, "AgentRecorder.exe");
            string boxKey = "Software\\RecitbotSelftestUpdate-" + g;
            string runSub = boxKey + "\\Run";
            string startup = dir + "-startup";
            string taskSelf = "RecitbotSelftestUpdate" + g + "a", taskOther = "RecitbotSelftestUpdate" + g + "b";
            const string notepad = "C:\\Windows\\System32\\notepad.exe";
            var tasks = new[] { taskSelf, taskOther };
            var runs = new[] { "self", "other", "otherPrefix" };
            var links = new[] { "self.lnk", "other.lnk" };
            Func<bool> live = delegate { return SelfUpdater.StartsThisExe(exe, tasks, runSub, runs, startup, links); };
            try
            {
                Directory.CreateDirectory(dir);
                File.WriteAllBytes(exe, new byte[] { 0x4d, 0x5a });
                using (var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(runSub))
                {
                    k.SetValue("other", "\"C:\\Elsewhere\\AgentRecorder.exe\" --data x");
                    k.SetValue("otherPrefix", "\"" + exe + ".bak\"");
                }
                Directory.CreateDirectory(startup);
                MakeShortcut(Path.Combine(startup, "other.lnk"), notepad);
                string err;
                int rc = HiddenPowerShell("$ErrorActionPreference = 'Stop'\r\n"
                    + "Register-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskOther) + " -Action (New-ScheduledTaskAction -Execute "
                    + SelfUninstaller.PsQuote(notepad) + ") -Settings (New-ScheduledTaskSettingsSet -Hidden) | Out-Null\r\n", out err);
                bool other = rc == 0 && TaskExists(taskOther);
                if (!other) check("update autostart sandbox: fake task registered (exit " + rc + ": " + (err ?? "").Trim() + ")", false);
                bool none = live();
                check("update autostart sandbox: entries of another exe only (task, Run, Startup) -> nothing starts this exe -> -NoAutostart",
                    other && !none && SelfUpdater.NoAutostart(null, none));

                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(runSub, true)) k.SetValue("self", "\"" + exe.ToUpperInvariant() + "\" --data \"" + dir + "\"");
                bool viaRun = live();
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(runSub, true)) k.DeleteValue("self");
                MakeShortcut(Path.Combine(startup, "self.lnk"), exe);
                bool viaLink = live();
                File.Delete(Path.Combine(startup, "self.lnk"));
                rc = HiddenPowerShell("$ErrorActionPreference = 'Stop'\r\n"
                    + "Register-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskSelf) + " -Action (New-ScheduledTaskAction -Execute "
                    + SelfUninstaller.PsQuote(exe) + ") -Settings (New-ScheduledTaskSettingsSet -Hidden) | Out-Null\r\n", out err);
                bool viaTask = rc == 0 && live();
                check("update autostart sandbox: a Run value, a Startup shortcut or a task starting this exe -> autostart kept (no -NoAutostart)",
                    viaRun && viaLink && viaTask && !SelfUpdater.NoAutostart(null, viaTask));
            }
            catch (Exception e) { check("update autostart sandbox: " + e.GetType().Name + " " + e.Message, false); }
            finally
            {
                try { Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(boxKey, false); } catch { }
                try
                {
                    string ignored;
                    HiddenPowerShell("Unregister-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskSelf) + " -Confirm:$false -ErrorAction SilentlyContinue\r\n"
                        + "Unregister-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(taskOther) + " -Confirm:$false -ErrorAction SilentlyContinue\r\n", out ignored);
                }
                catch { }
                try { if (Directory.Exists(startup)) Directory.Delete(startup, true); } catch { }
                try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
            }
        }

        /// install.template.ps1's autostart block (Get-TaskOwner / Set-Autostart), loaded from the source next to the
        /// build and run in a hidden powershell.exe against tasks named RecitbotSelftestUpdate<guid>f/n/o and a fake exe in
        /// %TEMP%. Never the AgentRecorder task: the template's own name is not used here.
        static void InstallerAutostartSelfTest(Action<string, bool> check)
        {
            string template = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", "recorder", "install.template.ps1"));
            if (!File.Exists(template)) { check("installer autostart: recorder\\install.template.ps1 next to the build (" + template + ")", false); return; }
            string text = File.ReadAllText(template);
            int a = text.IndexOf("# --- autostart"), b = text.IndexOf("# --- end autostart");
            check("installer: the AgentRecorder task is only touched through Set-Autostart / Get-TaskOwner (no hard-coded register or unregister)",
                a >= 0 && b > a && !text.Contains("-TaskName 'AgentRecorder'") && text.Contains("$TaskName = 'AgentRecorder'")
                && text.Contains("$autostart = Set-Autostart ([bool]$NoAutostart) $TaskName $exe $InstallDir")
                && text.Contains("if ((Get-TaskOwner $TaskName $Exe) -eq 'foreign') { return 'none' }")
                && text.Contains("if ((Get-TaskOwner $TaskName $Exe) -eq 'ours') { Unregister-ScheduledTask -TaskName $TaskName")
                && text.Contains("if ($autostart -eq 'logon' -and (Get-TaskOwner $TaskName $exe) -eq 'ours') {"));
            check("installer: records autostart and the device name in install-options.txt",
                text.Contains("'install-options.txt'") && text.Contains("\"autostart=$autostart`r`n\"") && text.Contains("\"device_name=$DeviceName`r`n\""));
            if (a < 0 || b < a) return;
            string block = text.Substring(a, b - a);

            string g = Guid.NewGuid().ToString("N");
            string dir = Path.Combine(Path.GetTempPath(), "recitbot-update-noautostart-" + g + "-inst");
            string exe = Path.Combine(dir, "AgentRecorder.exe");
            string tF = "RecitbotSelftestUpdate" + g + "f", tN = "RecitbotSelftestUpdate" + g + "n", tO = "RecitbotSelftestUpdate" + g + "o";
            string F = SelfUninstaller.PsQuote(tF), N = SelfUninstaller.PsQuote(tN), O = SelfUninstaller.PsQuote(tO);
            const string notepad = "C:\\Windows\\System32\\notepad.exe";
            try
            {
                Directory.CreateDirectory(dir);
                File.WriteAllBytes(exe, new byte[] { 0x4d, 0x5a });
                string ps = block + "\r\n"
                    + "$ErrorActionPreference = 'Stop'\r\n"
                    + "$exe = " + SelfUninstaller.PsQuote(exe) + "\r\n"
                    + "$dir = " + SelfUninstaller.PsQuote(dir) + "\r\n"
                    + "function Act([string]$n) { (@(Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | ForEach-Object { $_.Actions } | ForEach-Object { $_.Execute }) -join '|') }\r\n"
                    + "Register-ScheduledTask -TaskName " + F + " -Action (New-ScheduledTaskAction -Execute " + SelfUninstaller.PsQuote(notepad)
                    + ") -Settings (New-ScheduledTaskSettingsSet -Hidden) | Out-Null\r\n"
                    + "'owner_foreign=' + (Get-TaskOwner " + F + " $exe)\r\n"
                    + "'update_foreign=' + (Set-Autostart $false " + F + " $exe $dir)\r\n"
                    + "'after_foreign=' + (Act " + F + ")\r\n"
                    + "'noauto_foreign=' + (Set-Autostart $true " + F + " $exe $dir)\r\n"
                    + "'after_noauto_foreign=' + (Act " + F + ")\r\n"
                    + "'owner_missing=' + (Get-TaskOwner " + N + " $exe)\r\n"
                    + "'noauto_missing=' + (Set-Autostart $true " + N + " $exe $dir)\r\n"
                    + "'exists_missing=' + [bool](Get-ScheduledTask -TaskName " + N + " -ErrorAction SilentlyContinue)\r\n"
                    + "'failed_missing=' + (Set-Autostart $false " + N + " '' $dir)\r\n"
                    + "'exists_failed=' + [bool](Get-ScheduledTask -TaskName " + N + " -ErrorAction SilentlyContinue)\r\n"
                    + "'install_new=' + (Set-Autostart $false " + O + " $exe $dir)\r\n"
                    + "'owner_new=' + (Get-TaskOwner " + O + " $exe)\r\n"
                    + "'update_ours=' + (Set-Autostart $false " + O + " $exe $dir)\r\n"
                    + "'after_ours=' + (Act " + O + ")\r\n";
                string err, output;
                int rc = HiddenPowerShell(ps, out err, out output);
                var r = new Dictionary<string, string>();
                foreach (var line in (output ?? "").Split('\n'))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) r[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
                Func<string, string> v = delegate (string k) { string x; return r.TryGetValue(k, out x) ? x : null; };
                if (rc != 0) check("installer autostart sandbox: script ran (exit " + rc + ": " + (err ?? "").Trim() + ")", false);
                check("installer -Update never re-points, overwrites or unregisters a task whose exe is different (autostart=none)",
                    v("owner_foreign") == "foreign" && v("update_foreign") == "none" && string.Equals(v("after_foreign"), notepad, StringComparison.OrdinalIgnoreCase));
                check("installer: a no-autostart update registers no task (throwaway name) and leaves another exe's task alone",
                    v("owner_missing") == "none" && v("noauto_missing") == "none" && v("exists_missing") == "False"
                    && v("noauto_foreign") == "none" && string.Equals(v("after_noauto_foreign"), notepad, StringComparison.OrdinalIgnoreCase));
                check("installer: a failed register reports none and leaves no task behind", v("failed_missing") == "none" && v("exists_failed") == "False");
                check("installer: no task yet -> registered for this exe (logon); its own task is re-registered on update",
                    v("install_new") == "logon" && v("owner_new") == "ours" && v("update_ours") == "logon"
                    && string.Equals(v("after_ours"), exe, StringComparison.OrdinalIgnoreCase));
            }
            catch (Exception e) { check("installer autostart sandbox: " + e.GetType().Name + " " + e.Message, false); }
            finally
            {
                try
                {
                    string ignored;
                    HiddenPowerShell("foreach ($n in @(" + F + ", " + N + ", " + O + ")) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }\r\n", out ignored);
                }
                catch { }
                try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
            }
        }

        /// A .lnk via the WScript.Shell COM object (late-bound: the build references no COM interop assembly).
        static void MakeShortcut(string lnk, string target)
        {
            Type t = Type.GetTypeFromProgID("WScript.Shell", true);
            object shell = Activator.CreateInstance(t), sc = null;
            try
            {
                sc = t.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
                sc.GetType().InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { target });
                sc.GetType().InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, sc, null);
            }
            finally
            {
                if (sc != null) Marshal.ReleaseComObject(sc);
                Marshal.ReleaseComObject(shell);
            }
        }

        /// Runs a PowerShell script in a hidden powershell.exe child (no window), waits up to 60 s. Exit code, stderr in err.
        static int HiddenPowerShell(string ps, out string err)
        {
            string ignored;
            return HiddenPowerShell(ps, out err, out ignored);
        }

        static int HiddenPowerShell(string ps, out string err, out string output)
        {
            output = null;
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand "
                + Convert.ToBase64String(Encoding.Unicode.GetBytes(ps)));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.RedirectStandardError = true;
            psi.RedirectStandardOutput = true;
            using (var p = Process.Start(psi))
            {
                var e = p.StandardError.ReadToEndAsync();
                var o = p.StandardOutput.ReadToEndAsync();
                if (!p.WaitForExit(60000)) { try { p.Kill(); } catch { } err = "timed out"; return -1; }
                p.WaitForExit();
                err = e.Result;
                output = o.Result;
                return p.ExitCode;
            }
        }

        /// Whether a task of that (fake) name exists, asked in a hidden powershell.exe child.
        static bool TaskExists(string name)
        {
            string err;
            return HiddenPowerShell("if (Get-ScheduledTask -TaskName " + SelfUninstaller.PsQuote(name) + " -ErrorAction SilentlyContinue) { exit 0 } else { exit 3 }", out err) == 0;
        }

        /// Long recordings: the signed part size, the -fs cap, part slicing and the upload's retry/restart policy (Uploader
        /// against a scripted server: no network, no waits).
        static void ChunkedSelfTest(Action<string, bool> check, Dictionary<string, string> f)
        {
            var mp = new Dictionary<string, string>(f);
            mp.Remove("mac");
            mp["system_audio"] = "true";
            mp["upload_part_bytes"] = "33554432";
            check("mp canonical form", CommandVerifier.Canonical(mp).EndsWith("|1731651800.tok|sa|1|mp|33554432"));
            check("mp canonical hmac matches worker vector",
                CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(mp)) == "42de4f6cf95fd36b4eb8fdf59766dcabacb6091155c448a6b767f4477005a7a4");
            mp["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(mp));
            var stripped = new Dictionary<string, string>(mp);
            stripped.Remove("upload_part_bytes");
            check("mp: part size stripped -> rejected", new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null).Verify(stripped, 1731650000) == "bad mac");
            var changed = new Dictionary<string, string>(mp);
            changed["upload_part_bytes"] = "1048576";
            check("mp: part size changed -> rejected", new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null).Verify(changed, 1731650000) == "bad mac");

            check("video cap: one PUT (no part size, or 120 s)", Recorder.VideoCap(0, 1800, false) == 82000000 && Recorder.VideoCap(33554432, 120, true) == 82000000 - 17500 * 120);
            check("video cap: one PUT stays at 82 MB even at 4 h", Recorder.VideoCap(0, 14400, true) == 82000000 - 17500L * 14400);
            check("video cap: chunked long recording (30 min with audio) under 8 GiB", Recorder.VideoCap(33554432, 1800, true) == 8L * 1024 * 1024 * 1024 - 17500L * 1800);
            check("video cap: chunked 4 h with audio = 8 GiB less audio", Recorder.VideoCap(33554432, 14400, true) == 8L * 1024 * 1024 * 1024 - 17500L * 14400);
            check("length cap: MaxSeconds is 4 h (14400)", Recorder.MaxSeconds == 14400);
            check("length cap: clamp 1..14400", Recorder.ClampSeconds(99999) == 14400 && Recorder.ClampSeconds(14400) == 14400 && Recorder.ClampSeconds(0) == 1 && Recorder.ClampSeconds(-5) == 1);
            check("length cap: the server's max_seconds still governs (300 runs 300, 1800 runs 1800)", Recorder.ClampSeconds(300) == 300 && Recorder.ClampSeconds(1800) == 1800);

            const long P = 32L * 1024 * 1024;
            Func<List<long[]>, string> show = delegate (List<long[]> ps) { return string.Join(",", ps.ConvertAll(x => x[0] + "+" + x[1])); };
            check("parts: exact multiple", show(Uploader.Parts(2 * P, P)) == "0+" + P + "," + P + "+" + P);
            check("parts: remainder in a short last part", show(Uploader.Parts(2 * P + 5, P)) == "0+" + P + "," + P + "+" + P + "," + 2 * P + "+5");
            check("parts: one byte over", Uploader.Parts(P + 1, P).Count == 2 && Uploader.Parts(P + 1, P)[1][1] == 1);
            var big = Uploader.Parts(1536L * 1024 * 1024 - 1, P);
            long sum = 0;
            bool even = true;
            for (int i = 0; i < big.Count; i++) { sum += big[i][1]; even &= big[i][0] == i * P && (i == big.Count - 1 || big[i][1] == P); }
            check("parts: 1.5 GiB in 48 parts, contiguous, all full but the last", big.Count == 48 && sum == 1536L * 1024 * 1024 - 1 && even);
            var huge = Uploader.Parts(8L * 1024 * 1024 * 1024, P);
            check("parts: 8 GiB in 256 full parts, the last ending at 8 GiB", huge.Count == 256 && huge[255][0] == 255 * P && huge[255][1] == P && huge[255][0] + huge[255][1] == 8L * 1024 * 1024 * 1024);

            // Scripted server: answers each request from a queue of statuses per path (default 200), logs the requests.
            Func<Dictionary<string, Queue<int>>, long, Tuple<Uploader, List<string>, List<int>>> server = delegate (Dictionary<string, Queue<int>> script, long part)
            {
                var log = new List<string>();
                var sleeps = new List<int>();
                var u = new Uploader(delegate (string method, string path, string file, long offset, long count, string json)
                {
                    log.Add(method + " " + path + (file != null ? " " + file + " " + offset + "+" + count : "") + (json != null ? " " + json : ""));
                    Queue<int> q;
                    return script.TryGetValue(path, out q) && q.Count > 0 ? q.Dequeue() : 200;
                }, part);
                u.Sleep = sleeps.Add;
                return Tuple.Create(u, log, sleeps);
            };
            Func<int[], Queue<int>> q_ = delegate (int[] a) { return new Queue<int>(a); };
            Func<Action, string> error = delegate (Action a) { try { a(); return null; } catch (Exception e) { return e.Message; } };

            var s = server(new Dictionary<string, Queue<int>>(), 0);
            s.Item1.File("video", "v.mp4", 3 * P);
            check("upload: no part size -> one PUT of the whole file", string.Join("|", s.Item2) == "PUT video v.mp4 0+" + 3 * P);
            s = server(new Dictionary<string, Queue<int>>(), P);
            s.Item1.File("audio", "a.wav", P);
            check("upload: file of exactly the part size -> one PUT", string.Join("|", s.Item2) == "PUT audio a.wav 0+" + P);

            s = server(new Dictionary<string, Queue<int>>(), P);
            s.Item1.File("video", "v.mp4", 2 * P + 7);
            check("upload: chunked happy path (create with total, parts in order, complete with N)", string.Join("|", s.Item2) ==
                "POST video/mp {\"total_bytes\":" + (2 * P + 7) + "}|PUT video/mp/1 v.mp4 0+" + P + "|PUT video/mp/2 v.mp4 " + P + "+" + P
                + "|PUT video/mp/3 v.mp4 " + 2 * P + "+7|POST video/mp/complete {\"parts\":3}");

            s = server(new Dictionary<string, Queue<int>> { { "video/mp/2", q_(new[] { 0, 503 }) } }, P);
            s.Item1.File("video", "v.mp4", 2 * P + 7);
            check("upload: a failed part is sent again with the same number and range", string.Join("|", s.Item2) ==
                "POST video/mp {\"total_bytes\":" + (2 * P + 7) + "}|PUT video/mp/1 v.mp4 0+" + P + "|PUT video/mp/2 v.mp4 " + P + "+" + P
                + "|PUT video/mp/2 v.mp4 " + P + "+" + P + "|PUT video/mp/2 v.mp4 " + P + "+" + P + "|PUT video/mp/3 v.mp4 " + 2 * P + "+7|POST video/mp/complete {\"parts\":3}"
                && string.Join(",", s.Item3) == "2000,4000");

            s = server(new Dictionary<string, Queue<int>> { { "video/mp/2", q_(new[] { 502 }) } }, P);
            s.Item1.File("video", "v.mp4", 2 * P + 7);
            check("upload: 502 on a part -> start over from create, all parts again", string.Join("|", s.Item2) ==
                "POST video/mp {\"total_bytes\":" + (2 * P + 7) + "}|PUT video/mp/1 v.mp4 0+" + P + "|PUT video/mp/2 v.mp4 " + P + "+" + P
                + "|POST video/mp {\"total_bytes\":" + (2 * P + 7) + "}|PUT video/mp/1 v.mp4 0+" + P + "|PUT video/mp/2 v.mp4 " + P + "+" + P
                + "|PUT video/mp/3 v.mp4 " + 2 * P + "+7|POST video/mp/complete {\"parts\":3}" && s.Item3.Count == 0);

            s = server(new Dictionary<string, Queue<int>> { { "video/mp/complete", q_(new[] { 502 }) } }, P);
            s.Item1.File("video", "v.mp4", P + 1);
            check("upload: 502 on complete -> start over", s.Item2.Count == 8 && s.Item2[4] == "POST video/mp {\"total_bytes\":" + (P + 1) + "}" && s.Item2[7] == "POST video/mp/complete {\"parts\":2}");

            s = server(new Dictionary<string, Queue<int>> { { "video/mp/1", q_(new[] { 502, 502, 502 }) } }, P);
            string e1 = error(delegate { s.Item1.File("video", "v.mp4", P + 1); });
            check("upload: aborted on every restart -> UPLOAD_FAILED after " + Uploader.Restarts + " creates",
                e1 != null && e1.StartsWith("UPLOAD_FAILED") && s.Item2.FindAll(x => x == "POST video/mp {\"total_bytes\":" + (P + 1) + "}").Count == Uploader.Restarts);

            s = server(new Dictionary<string, Queue<int>> { { "video/mp/2", q_(new[] { 0, 0, 0 }) } }, P);
            string e2 = error(delegate { s.Item1.File("video", "v.mp4", P + 1); });
            check("upload: a part with no response " + Uploader.Attempts + " times -> UPLOAD_FAILED, no complete",
                e2 == "UPLOAD_FAILED: PUT video/mp/2 (no response)" && !s.Item2.Exists(x => x.Contains("complete")));

            s = server(new Dictionary<string, Queue<int>> { { "video/mp/2", q_(new[] { 409 }) } }, P);
            string e3 = error(delegate { s.Item1.File("video", "v.mp4", P + 1); });
            check("upload: 4xx on a part is final (no retry)", e3 == "UPLOAD_REJECTED_409" && s.Item2.Count == 3);

            s = server(new Dictionary<string, Queue<int>> { { "video", q_(new[] { 502, 200 }) } }, P);
            s.Item1.File("video", "v.mp4", 100);
            check("upload: single PUT retries a 502 (no multipart to restart)", s.Item2.Count == 2 && s.Item2[1] == "PUT video v.mp4 0+100");

            s = server(new Dictionary<string, Queue<int>> { { "video/mp", q_(new[] { 413 }) } }, P);
            string e4 = error(delegate { s.Item1.File("video", "v.mp4", P + 1); });
            check("upload: create refused (over the account's size) -> UPLOAD_REJECTED_413, no parts", e4 == "UPLOAD_REJECTED_413" && s.Item2.Count == 1);

            // Transcripts are mic-only: the whole upload plan (Recorder.Send) with and without a mic's WAV. Sandbox files.
            string tmp = Path.Combine(Path.GetTempPath(), "agent-recorder-selftest-up-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tmp);
            try
            {
                string mp4 = Path.Combine(tmp, "v.mp4"), wavT = Path.Combine(tmp, "v.wav"), none = Path.Combine(tmp, "absent.wav");
                const long Q = 1000; // a small part size: the 2007-byte video goes up in 3 parts, the WAV in one PUT
                File.WriteAllBytes(mp4, new byte[2 * Q + 7]);
                File.WriteAllBytes(wavT, new byte[44 + 800]);
                const string done = "POST complete {\"duration_s\":12.5,\"has_system_audio\":true}";
                s = server(new Dictionary<string, Queue<int>>(), Q);
                Recorder.Send(s.Item1, mp4, wavT, true, true, 12.5);
                check("upload plan: mic + system -> video (3 parts), the mic's WAV, complete", s.Item2.Count == 7 && s.Item2[4] == "POST video/mp/complete {\"parts\":3}"
                    && s.Item2[5] == "PUT audio " + wavT + " 0+844" && s.Item2[6] == done);
                // System audio only: Run passes hasTranscript false (no [t], no WAV file at all).
                s = server(new Dictionary<string, Queue<int>>(), Q);
                Recorder.Send(s.Item1, mp4, none, false, true, 12.5);
                check("upload plan: system audio only (no mic) -> no audio request at all, the same complete", s.Item2.Count == 6
                    && !s.Item2.Exists(x => x.StartsWith("POST audio") || x.StartsWith("PUT audio")) && s.Item2[4] == "POST video/mp/complete {\"parts\":3}" && s.Item2[5] == done);
                // The chunked audio path never starts either, and retries of the video do not bring it back.
                s = server(new Dictionary<string, Queue<int>> { { "video/mp/2", q_(new[] { 0, 503 }) } }, Q);
                Recorder.Send(s.Item1, mp4, none, false, false, 3);
                check("upload plan: no mic, video part retried -> still no audio, complete has_system_audio false", s.Item2.Count == 8
                    && !s.Item2.Exists(x => x.StartsWith("POST audio") || x.StartsWith("PUT audio")) && s.Item2[7] == "POST complete {\"duration_s\":3.0,\"has_system_audio\":false}");
                // A mic whose WAV came out empty (header only) is skipped the same way rather than sending 44 bytes.
                File.WriteAllBytes(wavT, new byte[44]);
                s = server(new Dictionary<string, Queue<int>>(), Q);
                Recorder.Send(s.Item1, mp4, wavT, true, false, 3);
                check("upload plan: header-only WAV is not sent", !s.Item2.Exists(x => x.StartsWith("PUT audio")) && s.Item2[s.Item2.Count - 1].StartsWith("POST complete"));
            }
            finally { try { Directory.Delete(tmp, true); } catch { } }
        }

        static readonly int[] ControlDpis = { 96, 120, 144, 168, 192 };

        /// Recorder 0.4: signed blocks, the control pill's layout and buttons, mute/mix math, progress timing, link policy.
        static void AudioSelfTest(Action<string, bool> check, Dictionary<string, string> f)
        {
            // Shared vectors with worker/test/audio-open.test.ts.
            var sa = new Dictionary<string, string>(f);
            sa.Remove("mac");
            sa["webcam_size"] = "25"; sa["system_audio"] = "true"; sa["webcam_shape"] = "rect";
            check("0.4 canonical form", CommandVerifier.Canonical(sa).EndsWith("|1731651800.tok|cam|||25|sa|1|shape|rect"));
            check("0.4 canonical hmac matches worker vector",
                CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(sa)) == "8e45f1383fe538cc386058f75c74e978b26829b996f637d51f838e17eb8e3c05");
            sa["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(sa));
            var vs = new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null);
            var noSys = new Dictionary<string, string>(sa);
            noSys["system_audio"] = "false";
            var dropSys = new Dictionary<string, string>(sa);
            dropSys.Remove("system_audio");
            var square = new Dictionary<string, string>(sa);
            square["webcam_shape"] = "circle";
            check("tampered / dropped system_audio or shape rejected", vs.Verify(noSys, 1731650000) == "bad mac" && vs.Verify(dropSys, 1731650000) == "bad mac"
                && vs.Verify(square, 1731650000) == "bad mac");
            check("signed 0.4 start accepted", vs.Verify(sa, 1731650000) == null);
            var ready = new Dictionary<string, string>
            {
                { "type", "ready" }, { "recording_id", "AAAAAAAAAAAAAAAAAAAAAA" }, { "max_seconds", "0" }, { "mic", "false" },
                { "nonce", "1731650000000" }, { "exp", "1731650060" }, { "account_id", "BBBBBBBBBBBBBBBBBBBBBB" },
                { "device_id", "CCCCCCCCCCCCCCCCCCCCCC" }, { "upload_token", "" },
                { "url", "https://recitbot.com/v/AAAAAAAAAAAAAAAAAAAAAA?e=1731736400&s=sig&o=own" },
            };
            check("ready canonical hmac matches worker vector",
                CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(ready)) == "5249a2d1308a0d5ab5e6ec4805c9ed1d2b2841e94585e0cccd2908f747f195bc");
            ready["mac"] = CommandVerifier.HmacHex("test-device-secret", CommandVerifier.Canonical(ready));
            var swapped = new Dictionary<string, string>(ready);
            swapped["url"] = "https://evil.example/v/AAAAAAAAAAAAAAAAAAAAAA?e=1731736400&s=sig&o=own";
            check("ready with a swapped url rejected", new CommandVerifier("BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC", "test-device-secret", null).Verify(swapped, 1731650000) == "bad mac");
            check("hello frame", HelloJson() == "{\"type\":\"hello\",\"version\":\"0.6.1\",\"features\":[\"system_audio\",\"webcam_shape\",\"webcam_pct\",\"ready_push\",\"chunked_upload\",\"self_update\",\"self_uninstall\",\"multi_account\",\"update_defer_rollback\",\"keyframes\"]}");

            // Control pill: timer, tooltips, layout matrix at 100-200 % (inside the capsule, apart, text fits, Tally Red only on
            // the dot and Stop), placement on the monitor and of the tooltip.
            check("pill: timer mm:ss, h:mm:ss from one hour", PillLayout.Elapsed(TimeSpan.Zero) == "00:00" && PillLayout.Elapsed(TimeSpan.FromSeconds(83.9)) == "01:23"
                && PillLayout.Elapsed(TimeSpan.FromSeconds(3599.9)) == "59:59" && PillLayout.Elapsed(TimeSpan.FromSeconds(3600)) == "1:00:00"
                && PillLayout.Elapsed(TimeSpan.FromSeconds(36061)) == "10:01:01" && PillLayout.Elapsed(TimeSpan.FromSeconds(-1)) == "00:00");
            check("pill: tooltips", PillLayout.Tip(PillLayout.Mic, true, true) == "Mute mic" && PillLayout.Tip(PillLayout.Mic, true, false) == "Unmute mic"
                && PillLayout.Tip(PillLayout.Sys, true, true) == "Mute PC sound" && PillLayout.Tip(PillLayout.Sys, true, false) == "Unmute PC sound"
                && PillLayout.Tip(PillLayout.Mic, false, false) == "No mic in this recording" && PillLayout.Tip(PillLayout.Stop, true, true) == "Stop recording");
            using (var probe = new Bitmap(1, 1))
            using (var mg = Graphics.FromImage(probe))
            {
                foreach (int dpi in ControlDpis)
                {
                    string pct = " @" + (dpi * 100 / 96) + "%";
                    var l = new PillLayout(dpi);
                    Func<Rectangle, Point> mid = r => new Point(r.X + r.Width / 2, r.Y + r.Height / 2);
                    Rectangle[] els = { l.Dot, l.Timer, l.MicButton, l.SysButton, l.StopButton };
                    bool ok = new Rectangle(Point.Empty, l.Size).Contains(l.Pill) && l.Pill.Height % 2 == 0;
                    for (int i = 0; i < els.Length; i++)
                    {
                        var e = els[i];
                        ok &= e.Width > 0 && l.InPill(mid(e)) && l.InPill(new Point(e.X, e.Y + e.Height / 2)) && l.InPill(new Point(e.Right - 1, e.Y + e.Height / 2))
                            && l.InPill(new Point(e.X + e.Width / 2, e.Y)) && l.InPill(new Point(e.X + e.Width / 2, e.Bottom - 1));
                        for (int j = i + 1; j < els.Length; j++) ok &= !els[i].IntersectsWith(els[j]);
                    }
                    ok &= l.InPill(new Point(l.Timer.X, l.Timer.Y)) && l.InPill(new Point(l.Timer.Right - 1, l.Timer.Bottom - 1));
                    // A visible gap between the buttons, so a click is never ambiguous.
                    ok &= l.MicButton.Left - l.Timer.Right >= 3 && l.SysButton.Left - l.MicButton.Right >= 3 && l.StopButton.Left - l.SysButton.Right >= 3;
                    check("pill" + pct + ": dot, timer, mic, PC sound, Stop inside the capsule, apart and in that order", ok);
                    bool fits = true;
                    using (var pf = new PillLayout.Fonts(l.Scale))
                    using (var fmt = new StringFormat(StringFormatFlags.NoWrap))
                    {
                        fits &= PillLayout.TabularWidth(mg, pf.Timer, "9:59:59") <= l.Timer.Width && pf.Timer.GetHeight(mg) <= l.Timer.Height;
                        fits &= PillLayout.TabularWidth(mg, pf.Timer, "00:00") == PillLayout.TabularWidth(mg, pf.Timer, "11:11");
                        var s = mg.MeasureString("Stop", pf.Button, PointF.Empty, fmt);
                        fits &= s.Width <= l.StopButton.Width && s.Height <= l.StopButton.Height;
                        foreach (var t in PillLayout.AllTips)
                        {
                            var ts = l.TipSize(mg, pf.Tip, t);
                            fits &= pf.Tip.GetHeight(mg) <= ts.Height && ts.Width <= l.S(260);
                        }
                    }
                    check("pill" + pct + ": timer (to 9:59:59, tabular), Stop and every tooltip fit", fits);
                    var gap = new Point((l.MicButton.Right + l.SysButton.Left) / 2, mid(l.MicButton).Y);
                    check("pill" + pct + ": hit-test", l.HitTest(mid(l.MicButton)) == PillLayout.Mic && l.HitTest(mid(l.SysButton)) == PillLayout.Sys
                        && l.HitTest(mid(l.StopButton)) == PillLayout.Stop && l.HitTest(gap) == null && l.HitTest(mid(l.Timer)) == null && l.HitTest(mid(l.Dot)) == null);
                    // Dragged by the body only: never from a button, never from the shadow around the capsule.
                    check("pill" + pct + ": body drags, buttons and shadow do not", l.IsBody(mid(l.Timer)) && l.IsBody(mid(l.Dot)) && l.IsBody(gap)
                        && !l.IsBody(mid(l.StopButton)) && !l.IsBody(mid(l.MicButton)) && !l.IsBody(mid(l.SysButton))
                        && !l.InPill(new Point(l.Pill.X + 1, l.Pill.Y + 1)) && !l.InPill(new Point(l.Pill.Right - 2, l.Pill.Bottom - 2)) && !l.InPill(new Point(1, 1))
                        && !l.InPill(new Point(mid(l.Pill).X, l.Pill.Bottom + 1)) && !l.InPill(new Point(mid(l.Pill).X, l.Pill.Y - 1)));
                    check("pill" + pct + ": click = down and up on the same button", l.ClickTarget(true, mid(l.MicButton), mid(l.MicButton)) == PillLayout.Mic
                        && l.ClickTarget(true, mid(l.SysButton), mid(l.SysButton)) == PillLayout.Sys && l.ClickTarget(true, mid(l.StopButton), mid(l.StopButton)) == PillLayout.Stop
                        && l.ClickTarget(true, mid(l.MicButton), mid(l.SysButton)) == null && l.ClickTarget(true, mid(l.StopButton), mid(l.MicButton)) == null
                        && l.ClickTarget(false, mid(l.MicButton), mid(l.MicButton)) == null && l.ClickTarget(true, mid(l.Timer), mid(l.MicButton)) == null);
                    // Rendered pixels: inside the capsule nothing but Ink outside the elements, Tally Red only in the dot and
                    // Stop; outside it only the (black) shadow, which fades out inside the margin.
                    int stray = 0, red = 0, shadow = 0, edge = 0;
                    int inset = l.S(1) + 2;
                    foreach (var state in new[] { new[] { true, true, true, true }, new[] { true, false, true, false }, new[] { false, false, false, false } })
                        foreach (string hover in new[] { null, PillLayout.Mic, PillLayout.Sys, PillLayout.Stop })
                            using (var bmp = l.Render(state[0], state[1], state[2], state[3], hover))
                            {
                                Rectangle[] slots = { Rectangle.Inflate(l.Dot, 1, 1), l.Timer, Rectangle.Inflate(l.StopButton, 1, 1), Rectangle.Inflate(l.MicButton, 1, 1), Rectangle.Inflate(l.SysButton, 1, 1) };
                                Rectangle[] redSlots = { Rectangle.Inflate(l.Dot, 1, 1), Rectangle.Inflate(l.StopButton, 1, 1) };
                                for (int y = 0; y < bmp.Height; y++)
                                    for (int x = 0; x < bmp.Width; x++)
                                    {
                                        var px = bmp.GetPixel(x, y);
                                        if ((x == 0 || y == 0 || x == bmp.Width - 1 || y == bmp.Height - 1) && px.A != 0) edge++;
                                        var p = new Point(x, y);
                                        bool interior = l.InPill(new Point(x - inset, y)) && l.InPill(new Point(x + inset, y)) && l.InPill(new Point(x, y - inset)) && l.InPill(new Point(x, y + inset));
                                        if (px.A > 0 && px.R > 180 && px.G < 110 && px.B < 110)
                                        {
                                            bool inRed = false;
                                            foreach (var r in redSlots) if (r.Contains(p)) { inRed = true; break; }
                                            if (!inRed) red++;
                                        }
                                        if (!l.InPill(p) && !l.InPill(new Point(x - 1, y)) && !l.InPill(new Point(x + 1, y)) && !l.InPill(new Point(x, y - 1)) && !l.InPill(new Point(x, y + 1)))
                                        {
                                            if (px.A > 0 && (px.R > 8 || px.G > 8 || px.B > 8)) shadow++;
                                            continue;
                                        }
                                        if (!interior) continue;
                                        if (Math.Abs(px.R - PillLayout.Ink.R) < 6 && Math.Abs(px.G - PillLayout.Ink.G) < 6 && Math.Abs(px.B - PillLayout.Ink.B) < 6) continue;
                                        bool owned = false;
                                        foreach (var r in slots) if (r.Contains(p)) { owned = true; break; }
                                        if (!owned) stray++;
                                    }
                            }
                    check("pill" + pct + ": rendered pixels stay in their elements (" + stray + " stray)", stray == 0);
                    check("pill" + pct + ": Tally Red only on the dot and Stop (" + red + " elsewhere)", red == 0);
                    check("pill" + pct + ": only a black shadow outside the capsule, clear at the window's edge (" + shadow + ", " + edge + ")", shadow == 0 && edge == 0);
                    // Placement: centred, 12 px below the work area's top; saved spots (also off the monitor) kept fully on it.
                    int bad = 0, cases = 0;
                    foreach (var mon in new[] { new Rectangle(0, 0, 1920, 1080), new Rectangle(1920, -200, 2560, 1440), new Rectangle(-3840, 0, 3840, 2160) })
                        foreach (var wa in new[] { new Rectangle(mon.X, mon.Y, mon.Width, mon.Height - 48), new Rectangle(mon.X, mon.Y + 48, mon.Width, mon.Height - 48) })
                        {
                            var def = l.Place(mon, wa, null);
                            cases++;
                            if (def.Y != wa.Top + l.S(PillLayout.TopGap) || Math.Abs(def.X + l.Pill.Width / 2 - (wa.X + wa.Width / 2)) > 1) bad++;
                            foreach (int fx in new[] { -400, 0, 1, 2, 3, 50000 })
                                foreach (int fy in new[] { -400, 0, 1, 2, 3, 50000 })
                                {
                                    int x = fx <= 3 && fx >= 0 ? fx * (mon.Width - l.Pill.Width / 2) / 3 : fx, y = fy <= 3 && fy >= 0 ? fy * (mon.Height - l.Pill.Height / 2) / 3 : fy;
                                    var at = new Rectangle(l.Place(mon, wa, new Point(x, y)), l.Pill.Size);
                                    cases++;
                                    if (!mon.Contains(at)) bad++;
                                }
                            var kept = new Rectangle(l.Place(mon, wa, new Point(40, 300)), l.Pill.Size);
                            cases++;
                            if (kept.Location != new Point(mon.X + 40, mon.Y + 300)) bad++;
                        }
                    check("pill" + pct + ": top centre by default, " + cases + " placements incl. saved spots at edges and off-screen stay on the monitor", bad == 0);
                    var screen = new Rectangle(0, 0, 1920, 1080);
                    var tsz = new Size(l.S(140), l.S(26));
                    Func<Rectangle, string, Rectangle> btn = (pill, t) => { var r = l.Of(t); return new Rectangle(pill.X + r.X - l.Pill.X, pill.Y + r.Y - l.Pill.Y, r.Width, r.Height); };
                    var top = new Rectangle(l.Place(screen, screen, null), l.Pill.Size);
                    var t1 = new Rectangle(l.TipAt(btn(top, PillLayout.Mic), top, tsz, screen), tsz);
                    var low = new Rectangle(top.X, screen.Bottom - top.Height, top.Width, top.Height);
                    var t2 = new Rectangle(l.TipAt(btn(low, PillLayout.Mic), low, tsz, screen), tsz);
                    var corner = new Rectangle(screen.Right - top.Width, 0, top.Width, top.Height);
                    var t3 = new Rectangle(l.TipAt(btn(corner, PillLayout.Sys), corner, tsz, screen), tsz);
                    check("pill" + pct + ": tooltip under its button, above the pill at the bottom, always on the monitor",
                        t1.Top >= top.Bottom && Math.Abs(t1.X + t1.Width / 2 - mid(btn(top, PillLayout.Mic)).X) <= 1 && t2.Bottom <= low.Top
                        && screen.Contains(t1) && screen.Contains(t2) && screen.Contains(t3) && !t3.IntersectsWith(corner));
                }
            }
            // Drag vs click on the toggles: the same 4 px rule as Stop.
            var lp = new PillLayout(96);
            var g = new ClickGesture();
            var mic = new Point(lp.MicButton.X + lp.MicButton.Width / 2, lp.MicButton.Y + lp.MicButton.Height / 2);
            g.Down(new Point(500, 500)); g.Move(new Point(502, 501));
            check("toggle: click with 2 px jitter toggles", lp.ClickTarget(g.Up(new Point(502, 501)), mic, new Point(mic.X + 2, mic.Y + 1)) == PillLayout.Mic);
            g.Down(new Point(500, 500)); g.Move(new Point(520, 500)); g.Move(new Point(500, 500));
            check("toggle: drag away and back is never a toggle", lp.ClickTarget(g.Up(new Point(500, 500)), mic, mic) == null);
            g.Down(new Point(500, 500));
            check("toggle: exactly 4 px is a drag", lp.ClickTarget(g.Up(new Point(504, 500)), mic, new Point(mic.X + 4, mic.Y)) == null);
            // The pill's spot per monitor in config.dat (old popup_x/popup_y lines are ignored).
            string cdir = Path.Combine(Path.GetTempPath(), "agentrec-selftest-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(cdir);
            try
            {
                File.WriteAllLines(Path.Combine(cdir, "config.dat"), new[] { "server=https://x", "popup_x=5", "popup_y=6", "pill_at_mon_f7b81f0c95=12,-3", "pill_at_mon_bad=1", "pill_at_=4,4" });
                var pc = Config.Load(cdir);
                Point pp;
                check("config: pill_at_<monitor> parsed, malformed lines skipped", pc.PillAt.Count == 1 && pc.PillAt.TryGetValue("mon_f7b81f0c95", out pp) && pp == new Point(12, -3));
                pc.SetPrefs("pill_at_mon_f7b81f0c95", "40,8");
                check("config: pill spot saved in place", Config.Load(cdir).PillAt["mon_f7b81f0c95"] == new Point(40, 8));
            }
            finally { try { Directory.Delete(cdir, true); } catch { } }

            // Mute spans and timeline math.
            var ml = new MuteLog();
            check("mute log: toggles", ml.Set(true, 2) && !ml.Set(true, 3) && ml.Muted && ml.Set(false, 5) && !ml.Muted && ml.Set(true, 8));
            var sp = ml.Spans();
            check("mute log: closed + open span", sp.Count == 2 && sp[0].Start == 2 && sp[0].End == 5 && sp[1].Start == 8 && double.IsPositiveInfinity(sp[1].End));
            var rs = AudioMath.MutedRanges(new List<Span> { new Span(1, 2) }, 47000, 2000, 48000);
            check("muted frames: span start inside a block", rs.Count == 1 && rs[0][0] == 1000 && rs[0][1] == 1000);
            rs = AudioMath.MutedRanges(new List<Span> { new Span(1, 1.5), new Span(1.25, 2), new Span(0, 0) }, 0, 200000, 48000);
            check("muted frames: overlapping spans merge, empty ones vanish", rs.Count == 1 && rs[0][0] == 48000 && rs[0][1] == 48000);
            rs = AudioMath.MutedRanges(new List<Span> { new Span(3, double.PositiveInfinity) }, 144000 - 10, 100, 48000);
            check("muted frames: open span mutes to the end", rs.Count == 1 && rs[0][0] == 10 && rs[0][1] == 90 && AudioMath.MutedRanges(sp, 0, 1000, 48000).Count == 0);
            var segs = new List<Segment> { new Segment(100, 10), new Segment(112, 5) };
            var tl = AudioMath.ToTimeline(new List<Span> { new Span(105, 106), new Span(109.5, 113), new Span(116, double.PositiveInfinity) }, segs, 0, 0);
            check("timeline: spans map through joined segments, gaps dropped", tl.Count == 3 && Near(tl[0], 5, 6) && Near(tl[1], 9.5, 11) && Near(tl[2], 14, 15));
            var padded = AudioMath.ToTimeline(new List<Span> { new Span(105, 106) }, segs, 0.1, 0.05);
            check("timeline: padding, clamped to the segment", Near(padded[0], 4.9, 6.05) && Near(AudioMath.ToTimeline(new List<Span> { new Span(99, 100.5) }, segs, 0.1, 0)[0], 0, 0.5));
            check("timeline: enable expression", AudioMath.Enable(new List<Span> { new Span(2.5, 4), new Span(1, 1.25) }) == "between(t,1,1.25)+between(t,2.5,4)");
            var slices = AudioMath.Slices(segs, 99.25);
            check("wav slices per segment", slices.Count == 2 && Near(slices[0], 0.75, 10.75) && Near(slices[1], 12.75, 17.75));
            string both = AudioMath.MixFilter(1, new List<Span> { new Span(2, 3) }, new List<Span> { new Span(0.5, 10.5) }, 2, new List<Span> { new Span(0.75, 10.75) });
            check("mix filter: mic + system (transcript split off the muted mic before the mix)", both == "[1:a]atrim=start=0.5:duration=10,asetpts=PTS-STARTPTS[m0];[m0]aresample=48000,pan=stereo|c0=c0|c1=c0,asetnsamples=n=480:p=0,volume=0:enable='between(t,2,3)'[m];"
                + "[2:a]atrim=start=0.75:duration=10,asetpts=PTS-STARTPTS[s0];[s0]aresample=48000,aformat=channel_layouts=stereo,volume=0.6[s];"
                + "[m]asplit=3[mm][mk][mt];[s][mk]sidechaincompress=threshold=0.05:ratio=3:attack=10:release=300[sd];"
                + "[mm][sd]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.97:level=0:latency=1[x];"
                + "[x]apad[a];[mt]aresample=16000[t]");
            string sysOnly = AudioMath.MixFilter(-1, null, null, 1, slices);
            check("mix filter: system only, two segments joined, full gain, no transcription output", sysOnly.StartsWith("[1:a]asplit=2[sw0][sw1];[sw0]atrim=start=0.75:duration=10,")
                && sysOnly.Contains("[sw1]atrim=start=12.75:duration=5,") && sysOnly.EndsWith("[s0][s1]concat=n=2:v=0:a=1,aresample=48000,aformat=channel_layouts=stereo,volume=1[s];[s]apad[a]")
                && !sysOnly.Contains("[m]") && !sysOnly.Contains("[t]") && !sysOnly.Contains("16000"));
            string micOnly = AudioMath.MixFilter(1, new List<Span>(), new List<Span> { new Span(0.25, 8.25) }, -1, null);
            check("mix filter: mic only, nothing muted", micOnly == "[1:a]atrim=start=0.25:duration=8,asetpts=PTS-STARTPTS[m0];[m0]aresample=48000,pan=stereo|c0=c0|c1=c0[m];[m]asplit=2[mm][mt];[mm]apad[a];[mt]aresample=16000[t]");
            MicOnlyTranscriptSelfTest(check, both, sysOnly, micOnly);
            string micTwo = AudioMath.MixFilter(1, new List<Span> { new Span(4, 5) }, slices, -1, null);
            check("mix filter: mic over two segments (one process), joined, then muted on the video timeline",
                micTwo.StartsWith("[1:a]asplit=2[mw0][mw1];[mw0]atrim=start=0.75:duration=10,asetpts=PTS-STARTPTS[m0];[mw1]atrim=start=12.75:duration=5,")
                && micTwo.Contains("[m0][m1]concat=n=2:v=0:a=1,aresample=48000,pan=stereo|c0=c0|c1=c0,asetnsamples=n=480:p=0,volume=0:enable='between(t,4,5)'[m]"));

            check("mix filter: late system audio or mic is delayed", AudioMath.MixFilter(-1, null, null, 1, new List<Span> { new Span(-0.25, 9.75) }).StartsWith("[1:a]adelay=delays=250:all=1,atrim=start=0:duration=10,")
                && AudioMath.MixFilter(1, null, new List<Span> { new Span(-0.1, 9.9) }, -1, null).StartsWith("[1:a]adelay=delays=100:all=1,atrim=start=0:duration=10,"));

            // Late mic (the 2026-11-16 10-minute run: mic t0 235 ms after the video's): the video is trimmed to a keyframe,
            // the mic is not delayed, and the output does not open with padded silence.
            string earlyKeys = VideoChain.EarlyKeys(30, "h264_nvenc");
            check("early keyframes: every 3rd frame for 2 s at 30 fps, IDR on nvenc", earlyKeys == "-force_key_frames \"expr:lt(t,2)*not(mod(n,3))\" -forced-idr 1"
                && VideoChain.EarlyKeys(60, "libx264") == "-force_key_frames \"expr:lt(t,2)*not(mod(n,6))\"" && VideoChain.EarlyKeys(5, "h264_qsv").Contains("mod(n,1)"));
            var crc = "#tb 0: 1/15360\n#media_type 0: video\n";
            for (int i = 0; i < 70; i++) crc += "0, " + (i * 512) + ", " + (i * 512) + ", 512, 4000, 0x1234" + (i % 3 == 0 && i < 60 || i == 60 ? "" : ", F=0x0") + "\n";
            var keys = AudioMath.KeyframeTimes(crc);
            check("keyframes from framecrc: every 3rd frame, then the GOP's", keys.Count == 21 && keys[0] == 0 && Math.Abs(keys[1] - 0.1) < 1e-9 && Math.Abs(keys[3] - 0.3) < 1e-9
                && Math.Abs(keys[20] - 2.0) < 1e-9 && AudioMath.KeyframeTimes("0, 0, 0, 512, 1, 0x1\n").Count == 0);
            double vT0 = 1000.0, micT0 = 1000.235;
            var longSegs = new List<Segment> { new Segment(vT0, 600.0) };
            bool capped;
            double trim235 = AudioMath.StartTrim(vT0, micT0, keys, out capped);
            var trimmed = AudioMath.TrimStart(longSegs, trim235);
            var lateSlices = AudioMath.Slices(trimmed, micT0);
            string lateMix = AudioMath.MixFilter(1, new List<Span>(), lateSlices, -1, null);
            check("late mic 235 ms: video trimmed to the keyframe at 0.3 s, mic cut 65 ms in (not delayed)", Math.Abs(trim235 - 0.3) < 1e-9 && !capped
                && trimmed.Count == 1 && Math.Abs(trimmed[0].WallStart - 1000.3) < 1e-9 && Math.Abs(trimmed[0].Duration - 599.7) < 1e-9
                && lateMix.StartsWith("[1:a]atrim=start=0.065:duration=599.7,"));
            // What the output would start with: no front padding filter, and every slice inside the WAV.
            bool frontPad = lateMix.Contains("adelay") || lateSlices.Exists(x => x.Start < 0);
            var untrimmedSlices = AudioMath.Slices(longSegs, micT0);
            check("late mic 235 ms: the output does not open with padded silence (untrimmed it would: " + (untrimmedSlices[0].Start * 1000).ToString("0") + " ms)",
                !frontPad && untrimmedSlices[0].Start < 0);
            bool c0, c1, c2, c3;
            check("start trim: none when the mic starts first or there is none, the keyframe itself when exact, 0 without keyframes (capped)",
                AudioMath.StartTrim(vT0, vT0 - 0.2, keys, out c0) == 0 && AudioMath.StartTrim(vT0, vT0, keys, out c1) == 0 && AudioMath.StartTrim(vT0, double.NaN, keys, out c2) == 0
                && AudioMath.StartTrim(vT0, vT0 + 0.3, keys, out c3) == 0.3 && !c0 && !c1 && !c2 && !c3
                && AudioMath.StartTrim(vT0, vT0 + 0.2, new List<double>(), out c0) == 0 && c0);

            // Start plans as Run makes them: trim to the mic only, then every source sliced on the trimmed timeline (a late
            // one delayed). The stored duration_s (AudioMath.Length) and every source's slices, so the AAC track and the
            // transcription WAV, are all the trimmed length.
            Func<List<Segment>, double, List<Segment>, string, int, bool> onTrimmedTimeline = (untrimmed, trim, cut, filter, sources) =>
            {
                double sum = 0;
                foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(filter, @"atrim=start=[\d.]+:duration=([\d.]+)"))
                    sum += double.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
                double len = AudioMath.Length(cut);
                return Math.Abs(len - (AudioMath.Length(untrimmed) - trim)) < 1e-6 && Math.Abs(sum - sources * len) < 1e-3;
            };
            // (a) System audio 3 s late (nothing playing), mic 230 ms late: the mic alone trims (0.3 s), the system audio is
            // delayed by the rest, 2.7 s.
            double trimA = AudioMath.StartTrim(vT0, vT0 + 0.23, keys, out capped);
            var segsA = AudioMath.TrimStart(longSegs, trimA);
            var micA = AudioMath.Slices(segsA, vT0 + 0.23);
            var sysA = AudioMath.Slices(segsA, vT0 + 3.0);
            string mixA = AudioMath.MixFilter(1, new List<Span>(), micA, 2, sysA);
            check("late system audio 3 s + mic 230 ms: 300 ms trim, mic cut 70 ms in, system audio delayed 2.7 s", Math.Abs(trimA - 0.3) < 1e-9 && !capped
                && mixA.StartsWith("[1:a]atrim=start=0.07:duration=599.7,") && mixA.Contains("[2:a]adelay=delays=2700:all=1,atrim=start=0:duration=599.7,")
                && onTrimmedTimeline(longSegs, trimA, segsA, mixA, 2));
            // (b) System audio only, 3 s late: no trim, delayed 3 s; over two segments the first one (2 s) is all silence.
            double trimB = AudioMath.StartTrim(vT0, double.NaN, keys, out capped);
            var segsB = AudioMath.TrimStart(longSegs, trimB);
            string mixB = AudioMath.MixFilter(-1, null, null, 1, AudioMath.Slices(segsB, vT0 + 3.0));
            var twoSegs = new List<Segment> { new Segment(vT0, 2), new Segment(vT0 + 5, 10) };
            string mixB2 = AudioMath.MixFilter(-1, null, null, 1, AudioMath.Slices(twoSegs, vT0 + 3.0));
            check("late system audio only 3 s: no trim, delayed 3 s (a segment before it all silence)", trimB == 0 && !capped
                && mixB.StartsWith("[1:a]adelay=delays=3000:all=1,atrim=start=0:duration=600,") && onTrimmedTimeline(longSegs, trimB, segsB, mixB, 1)
                && mixB2.Contains("[sw0]adelay=delays=3000:all=1,atrim=start=0:duration=2,") && mixB2.Contains("[sw1]atrim=start=2:duration=10,")
                && onTrimmedTimeline(twoSegs, 0, twoSegs, mixB2, 1));
            // (c) Mic 1.2 s late: the trim stops at the last keyframe at or below 500 ms, the mic is delayed the rest (0.7 s).
            double trimC = AudioMath.StartTrim(vT0, vT0 + 1.2, keys, out capped);
            var segsC = AudioMath.TrimStart(longSegs, trimC);
            string mixC = AudioMath.MixFilter(1, new List<Span>(), AudioMath.Slices(segsC, vT0 + 1.2), -1, null);
            check("late mic 1.2 s: trim capped at 500 ms, mic delayed 700 ms", capped && trimC <= AudioMath.MaxTrim && Math.Abs(trimC - 0.5) < 1e-9
                && mixC.StartsWith("[1:a]adelay=delays=700:all=1,atrim=start=0:duration=599.5,") && onTrimmedTimeline(longSegs, trimC, segsC, mixC, 1));
            check("late mic 235 ms: duration_s and the WAV on the trimmed timeline (599.7 s)", onTrimmedTimeline(longSegs, trim235, trimmed, lateMix, 1));
            var two = AudioMath.TrimStart(new List<Segment> { new Segment(100, 0.2), new Segment(112, 5) }, 0.5);
            check("start trim: a short first segment is dropped, the rest cut", two.Count == 1 && Math.Abs(two[0].WallStart - 112.3) < 1e-9 && Math.Abs(two[0].Duration - 4.7) < 1e-9);

            // ffmpeg -progress timing: T0 = least-latency sample.
            var pr = new FfProgress();
            pr.Line("frame=1", 10.0); pr.Line("out_time_us=N/A", 10.0); pr.Line("out_time_us=0", 10.1);
            check("progress: nothing valid yet", !pr.Valid);
            pr.Line("out_time_us=500000", 10.62); pr.Line("out_time_us=1000000", 11.05); pr.Line("out_time_us=1500000", 11.58);
            check("progress: T0 is the smallest arrival - out_time", pr.Valid && Math.Abs(pr.T0 - 10.05) < 1e-9 && Math.Abs(pr.Last - 1.5) < 1e-9);
            // System audio timeline without a device: silence fill, packets placed by timestamp, a device switch (gap +
            // another sample rate), a late packet overlapping what is already written, and a muted span.
            string wav = Path.Combine(Path.GetTempPath(), "agent-recorder-selftest-" + Guid.NewGuid().ToString("N") + ".wav");
            try
            {
                Func<int, float[]> tone = n => { var a = new float[n * 2]; for (int i = 0; i < a.Length; i++) a[i] = 0.5f; return a; };
                var lc = new LoopbackCapture(wav);
                lc.TestOpen(100.0);
                lc.TestPadTo(100.5);                          // nothing playing: frames 0-24000 silence
                lc.TestFeed(tone(4800), 4800, 48000, 100.5);  // 24000-28800 tone
                lc.TestFeed(tone(4800), 4800, 48000, 100.6);  // 28800-33600 tone (continuous)
                lc.TestFeed(tone(4410), 4410, 44100, 101.0);  // new device at 44.1 kHz: gap 33600-48000 silence, then tone
                lc.TestFeed(tone(4410), 4410, 44100, 101.05); // late: overlaps by 0.05 s, only the new part is written
                lc.Mutes.Set(true, 1.2);
                lc.Mutes.Set(false, 1.3);
                lc.TestFeed(tone(9600), 9600, 48000, 101.2);  // 57600-67200: muted until 62400, then tone
                lc.TestClose();
                var bytes = File.ReadAllBytes(wav);
                int dataLen = BitConverter.ToInt32(bytes, 40);
                Func<int, short> L = frame => BitConverter.ToInt16(bytes, 44 + frame * 4);
                bool header = Encoding.ASCII.GetString(bytes, 0, 4) == "RIFF" && BitConverter.ToInt32(bytes, 4) == bytes.Length - 8 && dataLen == bytes.Length - 44
                    && BitConverter.ToInt16(bytes, 22) == 2 && BitConverter.ToInt32(bytes, 24) == 48000;
                check("system audio wav: header, continuous 67200 frames", header && dataLen / 4 == 67200);
                check("system audio wav: silence until the first packet, packet at its timestamp", L(0) == 0 && L(23999) == 0 && L(24000) == 16384 && L(33599) == 16384);
                check("system audio wav: device switch gap is silence, 44.1 kHz resampled in place", L(33600) == 0 && L(47999) == 0 && L(48000) == 16384 && L(55000) == 16384);
                check("system audio wav: late overlapping packet trimmed, not shifted", lc.Seconds > 1.39 && lc.Seconds < 1.41 && L(56000) == 0 && L(57599) == 0);
                bool mutedZero = true;
                for (int i = 57600; i < 62400; i++) mutedZero &= L(i) == 0;
                check("system audio wav: muted span written as zeros, sound resumes after it", mutedZero && L(62400) == 16384 && L(67199) == 16384);
            }
            finally { try { File.Delete(wav); } catch { } }
            var tg = Toggles("sys@6.5, mic@5,bogus@1,mic@-1,mic@x");
            check("--toggle parsing", tg.Count == 2 && tg[0].Key == "mic" && tg[0].Value == 5 && tg[1].Key == "sys" && tg[1].Value == 6.5);

            // Auto-open: link policy (same rules as worker/src/ready.ts) and once-per-recording.
            const string id = "AAAAAAAAAAAAAAAAAAAAAA";
            string ok1 = "https://recitbot.com/v/" + id + "?e=1731736400&s=ab-c_d&o=e_f";
            check("link: recitbot.com viewer link opens (any server)", LinkPolicy.Allowed(ok1, "https://agent-recorder-demo.x.workers.dev", id) && LinkPolicy.Allowed(ok1, "https://recitbot.com", id));
            check("link: the server's own host opens", LinkPolicy.Allowed("https://agent-recorder-demo.x.workers.dev/v/" + id + "?e=1", "https://agent-recorder-demo.x.workers.dev", id));
            string[] rejected =
            {
                "http://recitbot.com/v/" + id + "?e=1", "https://evil.example/v/" + id, "https://recitbot.com.evil.example/v/" + id,
                "https://user@recitbot.com/v/" + id, "https://recitbot.com:8443/v/" + id, "https://recitbot.com/v/BBBBBBBBBBBBBBBBBBBBBB",
                "https://recitbot.com/m/" + id, "https://recitbot.com/v/" + id + "#x", "https://recitbot.com/v/" + id + "?e=1&x=<script>",
                "https://recitbot.com/v/" + id + "/../../x", "file:///C:/Windows/notepad.exe", "javascript:alert(1)", "notepad.exe", "", null,
                "https://RECITBOT.com/v/" + id,
            };
            int allowed = 0;
            foreach (var u in rejected) if (LinkPolicy.Allowed(u, "https://recitbot.com", id)) allowed++;
            check("link: other hosts, schemes, paths, ports, userinfo, fragments, odd queries rejected (" + allowed + " let through)", allowed == 0);
            check("link: http only for a loopback dev server", LinkPolicy.Allowed("http://127.0.0.1:8787/v/" + id + "?e=1", "http://127.0.0.1:8787", id)
                && !LinkPolicy.Allowed("http://127.0.0.1:8787/v/" + id, "https://recitbot.com", id) && !LinkPolicy.Allowed(ok1, "https://recitbot.com", "bad id!"));
            var rl = new ReadyLinks();
            var t0 = new DateTime(2026, 11, 15, 12, 0, 0, DateTimeKind.Utc);
            check("ready: nothing opens for a recording this PC never uploaded", !rl.Claim(id, t0));
            rl.Expect(id, t0);
            check("ready: opens once, never twice (duplicate / replay after reconnect)", rl.Claim(id, t0.AddSeconds(5)) && !rl.Claim(id, t0.AddSeconds(6)));
            rl.Expect(id, t0.AddSeconds(7));
            check("ready: a second upload of the same id does not re-arm it", !rl.Claim(id, t0.AddSeconds(8)));
            rl.Expect("BBBBBBBBBBBBBBBBBBBBBB", t0);
            rl.Forget("BBBBBBBBBBBBBBBBBBBBBB");
            rl.Expect("CCCCCCCCCCCCCCCCCCCCCC", t0);
            check("ready: failed upload (forgotten) and stale (> 30 min) never open", !rl.Claim("BBBBBBBBBBBBBBBBBBBBBB", t0.AddSeconds(1)) && !rl.Claim("CCCCCCCCCCCCCCCCCCCCCC", t0.AddMinutes(31)));
            check("settings: auto_open_link values", Config.NormalizeSetting("auto_open_link", "FALSE") == "false" && Config.NormalizeSetting("auto_open_link", " on ") == "true"
                && Config.NormalizeSetting("auto_open_link", "maybe") == null && Config.NormalizeSetting("device_token", "x") == null && Config.NormalizeSetting("server", "https://x") == null);
            check("settings: missing config file reads the default", new Config { Dir = Path.Combine(Path.GetTempPath(), "agent-recorder-none-" + Guid.NewGuid().ToString("N")) }.ReadBool("auto_open_link", true));
        }

        static bool Near(Span s, double a, double b) { return Math.Abs(s.Start - a) < 1e-6 && Math.Abs(s.End - b) < 1e-6; }

        /// MixFilter before transcripts became mic-only (recorder 0.6.0 as first built): [t] was a copy of the final mix.
        const string OldMixBoth = "[1:a]atrim=start=0.5:duration=10,asetpts=PTS-STARTPTS[m0];[m0]aresample=48000,pan=stereo|c0=c0|c1=c0,asetnsamples=n=480:p=0,volume=0:enable='between(t,2,3)'[m];"
            + "[2:a]atrim=start=0.75:duration=10,asetpts=PTS-STARTPTS[s0];[s0]aresample=48000,aformat=channel_layouts=stereo,volume=0.6[s];"
            + "[m]asplit=2[mm][mk];[s][mk]sidechaincompress=threshold=0.05:ratio=3:attack=10:release=300[sd];"
            + "[mm][sd]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.97:level=0:latency=1[x];"
            + "[x]asplit=2[a0][t0];[a0]apad[a];[t0]aresample=16000[t]";
        const string OldMixSysOnly = "[1:a]asplit=2[sw0][sw1];[sw0]atrim=start=0.75:duration=10,asetpts=PTS-STARTPTS[s0];[sw1]atrim=start=12.75:duration=5,asetpts=PTS-STARTPTS[s1];"
            + "[s0][s1]concat=n=2:v=0:a=1,aresample=48000,aformat=channel_layouts=stereo,volume=1[s];[s]asplit=2[a0][t0];[a0]apad[a];[t0]aresample=16000[t]";
        const string OldMixMicOnly = "[1:a]atrim=start=0.25:duration=8,asetpts=PTS-STARTPTS[m0];[m0]aresample=48000,pan=stereo|c0=c0|c1=c0[m];[m]asplit=2[a0][t0];[a0]apad[a];[t0]aresample=16000[t]";

        /// What produces `label` in a filter graph, as one expression: each chain's filters applied to its rendered inputs;
        /// asplit is a plain copy (rendered as its input); a label no chain produces is an input stream ("1:a").
        static string FilterExpr(string filter, string label)
        {
            foreach (var chain in filter.Split(';'))
            {
                var m = System.Text.RegularExpressions.Regex.Match(chain, @"^((?:\[[^\]]+\])*)(.*?)((?:\[[^\]]+\])+)$");
                if (!m.Success || !m.Groups[3].Value.Contains("[" + label + "]")) continue;
                var ins = new List<string>();
                foreach (System.Text.RegularExpressions.Match x in System.Text.RegularExpressions.Regex.Matches(m.Groups[1].Value, @"\[([^\]]+)\]")) ins.Add(FilterExpr(filter, x.Groups[1].Value));
                string body = m.Groups[2].Value;
                if (body.StartsWith("asplit=") && ins.Count == 1) return ins[0];
                return body + "(" + string.Join(",", ins) + ")";
            }
            return label;
        }

        /// Transcripts are mic-only: [t] comes from the mic chain alone (after its muted spans), [a] is today's mix, and no
        /// mic means no [t]. With an ffmpeg on PATH (or AGENT_RECORDER_SELFTEST_FFMPEG), the same on real samples in a temp
        /// folder: a mic tone and a different system tone through the old and the new graph.
        static void MicOnlyTranscriptSelfTest(Action<string, bool> check, string both, string sysOnly, string micOnly)
        {
            check("mix filter: [a] unchanged from the old literal (mic + system, system only, mic only; asplit = copy)",
                FilterExpr(both, "a") == FilterExpr(OldMixBoth, "a") && FilterExpr(sysOnly, "a") == FilterExpr(OldMixSysOnly, "a") && FilterExpr(micOnly, "a") == FilterExpr(OldMixMicOnly, "a")
                && sysOnly == OldMixSysOnly.Replace("[s]asplit=2[a0][t0];[a0]apad[a];[t0]aresample=16000[t]", "[s]apad[a]")
                && both == OldMixBoth.Replace("[m]asplit=2[mm][mk]", "[m]asplit=3[mm][mk][mt]").Replace("[x]asplit=2[a0][t0];[a0]apad[a];[t0]aresample=16000[t]", "[x]apad[a];[mt]aresample=16000[t]"));
            string t = FilterExpr(both, "t"), mic = FilterExpr(both, "m");
            check("mix filter: [t] routes from the mic chain only (after the mute, before the system mix / sidechain)",
                t == "aresample=16000(" + mic + ")" && mic == FilterExpr(OldMixBoth, "m") && mic.Contains("1:a") && mic.Contains("volume=0:enable='between(t,2,3)'")
                && !t.Contains("2:a") && !t.Contains("amix") && !t.Contains("sidechaincompress") && !t.Contains("alimiter") && FilterExpr(OldMixBoth, "t").Contains("2:a"));
            check("mix filter: [t] from the mic in mic-only too; no [t] (no transcription WAV) without a mic",
                FilterExpr(micOnly, "t") == "aresample=16000(" + FilterExpr(micOnly, "m") + ")" && FilterExpr(sysOnly, "t") == "t"
                && FilterExpr(AudioMath.MixFilter(-1, null, null, 1, new List<Span> { new Span(-0.25, 9.75) }), "t") == "t");
            check("mix args: the WAV is mapped only with a mic", WindowsFfmpegBackend.MixArgs("v.mp4", 0, "m.wav", "s.wav", both, "o.mp4", "o.wav").EndsWith(" -map [t] -ac 1 -c:a pcm_s16le \"o.wav\"")
                && WindowsFfmpegBackend.MixArgs("v.mp4", 0.3, null, "s.wav", sysOnly, "o.mp4", "o.wav") == "-hide_banner -loglevel error -y -ss 0.3 -i \"v.mp4\" -i \"s.wav\" -filter_complex \"" + sysOnly
                    + "\" -map 0:v -map [a] -c:v copy -c:a aac -b:a 128k -shortest -movflags +faststart \"o.mp4\"");

            string ff = SelfTestFfmpeg();
            if (ff == null) { Console.WriteLine("skip mix tones: no ffmpeg on PATH (filter-graph checks above only)"); return; }
            string dir = Path.Combine(Path.GetTempPath(), "agent-recorder-selftest-mix-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                // Mic: 440 Hz mono (as the mic capture writes it); system: 1000 Hz stereo (as LoopbackCapture writes it).
                // 3 s each; the mic is muted 1.0-1.5 s.
                string micWav = Path.Combine(dir, "mic.wav"), sysWav = Path.Combine(dir, "sys.wav");
                WriteToneWav(micWav, 1, 440, 0.3, 3.0);
                WriteToneWav(sysWav, 2, 1000, 0.3, 3.0);
                var whole = new List<Span> { new Span(0, 3) };
                string nw = AudioMath.MixFilter(1, new List<Span> { new Span(1.0, 1.5) }, whole, 2, whole);
                string old = nw.Replace("[m]asplit=3[mm][mk][mt]", "[m]asplit=2[mm][mk]").Replace("[x]apad[a];[mt]aresample=16000[t]", "[x]asplit=2[a0][t0];[a0]apad[a];[t0]aresample=16000[t]");
                string aNew = Path.Combine(dir, "a-new.wav"), tNew = Path.Combine(dir, "t-new.wav"), aOld = Path.Combine(dir, "a-old.wav"), tOld = Path.Combine(dir, "t-old.wav");
                // Input 0 stands in for the video (unused by the graph); [a] as PCM so the comparison is exact (no AAC).
                Func<string, string, string, int> run = (g, a, tw) => RunSelfTestFfmpeg(ff, "-hide_banner -loglevel error -y -i \"" + sysWav + "\" -i \"" + micWav + "\" -i \"" + sysWav
                    + "\" -filter_complex \"" + g + "\" -map [a] -t 3 -c:a pcm_s16le \"" + a + "\" -map [t] -ac 1 -c:a pcm_s16le \"" + tw + "\"");
                int e1 = run(nw, aNew, tNew), e2 = run(old, aOld, tOld);
                if (e1 != 0 || e2 != 0) { check("mix tones: ffmpeg ran (" + e1 + ", " + e2 + ")", false); return; }
                var an = WavSamples(aNew); var ao = WavSamples(aOld); var tn = WavSamples(tNew); var to = WavSamples(tOld);
                // The last ~70 ms (the sources' end: amix / alimiter flush) differ from run to run even for the same graph in
                // ffmpeg itself, so the comparison stops 100 ms before the end.
                int upTo = an.Length - 2 * 4800;
                bool same = an.Length == ao.Length && upTo > 0;
                for (int i = 0; same && i < upTo; i++) same = an[i] == ao[i];
                check("mix tones: [a] (the video's track) is sample-identical to the old graph's (" + upTo / 2 + " frames, all but ffmpeg's end-of-stream flush)", same);
                double micAmp = Tone(tn, 16000, 440, 0.2, 0.9), sysAmp = Tone(tn, 16000, 1000, 0.2, 0.9), oldSys = Tone(to, 16000, 1000, 0.2, 0.9), muted = Rms(tn, 16000, 1.1, 1.4);
                var inv = System.Globalization.CultureInfo.InvariantCulture;
                check("mix tones: transcription is 16 kHz mono with the mic tone (" + micAmp.ToString("0.000", inv) + ") and ~none of the system tone (" + sysAmp.ToString("0.00000", inv)
                    + "; old mix " + oldSys.ToString("0.000", inv) + "), silent while muted (rms " + muted.ToString("0.00000", inv) + ")",
                    WavFormat(tNew) == "16000/1" && micAmp > 0.25 && micAmp < 0.35 && sysAmp < 0.001 && oldSys > 0.02 && muted < 0.001 && Math.Abs(tn.Length - 48000) < 400);
                // System audio only: the same command shape MixAudio uses makes no WAV at all.
                string aSys = Path.Combine(dir, "a-sys.wav"), noWav = Path.Combine(dir, "t-sys.wav");
                string sysGraph = AudioMath.MixFilter(-1, null, null, 1, whole);
                int e3 = RunSelfTestFfmpeg(ff, "-hide_banner -loglevel error -y -i \"" + micWav + "\" -i \"" + sysWav + "\" -filter_complex \"" + sysGraph + "\" -map [a] -t 3 -c:a pcm_s16le \"" + aSys + "\"");
                check("mix tones: system audio only -> the video track has the system tone, no transcription WAV", e3 == 0 && Tone(WavSamples(aSys), 48000, 1000, 0.2, 0.9, 2) > 0.25 && !File.Exists(noWav));
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        /// An ffmpeg for the selftest's own sandbox files: AGENT_RECORDER_SELFTEST_FFMPEG, else ffmpeg.exe on PATH. Never the
        /// installed recorder's copy (%LOCALAPPDATA%\AgentRecorder).
        static string SelfTestFfmpeg()
        {
            string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentRecorder");
            var candidates = new List<string>();
            string env = Environment.GetEnvironmentVariable("AGENT_RECORDER_SELFTEST_FFMPEG");
            if (!string.IsNullOrEmpty(env)) candidates.Add(env);
            foreach (var d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
                if (d.Trim().Length > 0) try { candidates.Add(Path.Combine(d.Trim().Trim('"'), "ffmpeg.exe")); } catch { }
            foreach (var c in candidates)
                if (File.Exists(c) && !Path.GetFullPath(c).StartsWith(installed, StringComparison.OrdinalIgnoreCase)) return c;
            return null;
        }

        static int RunSelfTestFfmpeg(string ff, string args)
        {
            var psi = new ProcessStartInfo(ff, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardInput = true };
            using (var p = Process.Start(psi))
            {
                p.StandardInput.Close();
                var err = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(60000)) { try { p.Kill(); } catch { } return -1; }
                p.WaitForExit();
                if (p.ExitCode != 0) Console.WriteLine("     ffmpeg: " + err.Result.Trim());
                return p.ExitCode;
            }
        }

        /// A 48 kHz s16 WAV of a sine (same on every channel).
        static void WriteToneWav(string path, int channels, double hz, double amp, double seconds)
        {
            int n = (int)(48000 * seconds), data = n * channels * 2;
            using (var w = new BinaryWriter(File.Create(path)))
            {
                w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + data); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
                w.Write(16); w.Write((short)1); w.Write((short)channels); w.Write(48000); w.Write(48000 * channels * 2); w.Write((short)(channels * 2)); w.Write((short)16);
                w.Write(Encoding.ASCII.GetBytes("data")); w.Write(data);
                for (int i = 0; i < n; i++)
                {
                    short v = (short)Math.Round(amp * 32767 * Math.Sin(2 * Math.PI * hz * i / 48000));
                    for (int c = 0; c < channels; c++) w.Write(v);
                }
            }
        }

        /// The "data" chunk of an s16 WAV (ffmpeg may write a LIST chunk before it).
        static short[] WavSamples(string path)
        {
            var b = File.ReadAllBytes(path);
            for (int i = 12; i + 8 <= b.Length; )
            {
                int len = BitConverter.ToInt32(b, i + 4);
                if (Encoding.ASCII.GetString(b, i, 4) == "data")
                {
                    len = Math.Min(len, b.Length - i - 8);
                    var s = new short[len / 2];
                    Buffer.BlockCopy(b, i + 8, s, 0, s.Length * 2);
                    return s;
                }
                i += 8 + len + (len & 1);
            }
            return new short[0];
        }

        /// "rate/channels" from a WAV's fmt chunk.
        static string WavFormat(string path)
        {
            var b = File.ReadAllBytes(path);
            for (int i = 12; i + 8 <= b.Length; )
            {
                int len = BitConverter.ToInt32(b, i + 4);
                if (Encoding.ASCII.GetString(b, i, 4) == "fmt ") return BitConverter.ToInt32(b, i + 12) + "/" + BitConverter.ToInt16(b, i + 10);
                i += 8 + len + (len & 1);
            }
            return "";
        }

        /// Amplitude (0..1) of a sine at hz in [from, to) seconds of channel 0 (Goertzel).
        static double Tone(short[] s, int rate, double hz, double from, double to, int channels = 1)
        {
            int a = (int)(from * rate), b = Math.Min((int)(to * rate), s.Length / channels);
            if (b <= a) return 0;
            double w = 2 * Math.PI * hz / rate, c = 2 * Math.Cos(w), s1 = 0, s2 = 0;
            for (int i = a; i < b; i++) { double s0 = s[i * channels] / 32768.0 + c * s1 - s2; s2 = s1; s1 = s0; }
            double re = s1 - s2 * Math.Cos(w), im = s2 * Math.Sin(w);
            return 2 * Math.Sqrt(re * re + im * im) / (b - a);
        }

        static double Rms(short[] s, int rate, double from, double to)
        {
            int a = (int)(from * rate), b = Math.Min((int)(to * rate), s.Length);
            double sum = 0;
            for (int i = a; i < b; i++) sum += (s[i] / 32768.0) * (s[i] / 32768.0);
            return b > a ? Math.Sqrt(sum / (b - a)) : 0;
        }


        static Display FakeDisplay(int x, int y, int w, int h, int dpi, string taskbar)
        {
            int t = (int)Math.Round(48 * dpi / 96f);
            var b = new Rectangle(x, y, w, h);
            var wa = taskbar == "top" ? Rectangle.FromLTRB(x, y + t, x + w, y + h) : taskbar == "left" ? Rectangle.FromLTRB(x + t, y, x + w, y + h)
                : taskbar == "right" ? Rectangle.FromLTRB(x, y, x + w - t, y + h) : Rectangle.FromLTRB(x, y, x + w, y + h - t);
            return new Display { DeviceName = "\\\\.\\DISPLAY" + dpi + taskbar, Bounds = b, WorkArea = wa };
        }

        /// Webcam controls: layout at each scale (no overlap, inside the rounded window, text fits, nothing painted outside
        /// its slot) and placement for every bubble size x 9 positions (corners, edge midpoints, centre) x monitor size x
        /// taskbar side x scale, plus a mixed-DPI three-monitor desktop.
        static void ControlsSelfTest(Action<string, bool> check)
        {
            int[] sizes = { WebcamBubble.MinPx, 180, WebcamBubble.DefaultPx, 300, 360, 420, WebcamBubble.MaxPx };
            using (var probe = new Bitmap(1, 1))
            using (var mg = Graphics.FromImage(probe))
            {
                foreach (int dpi in ControlDpis)
                {
                    string pct = " @" + (dpi * 100 / 96) + "%";
                    var l = new ControlLayout(dpi);
                    var client = new Rectangle(Point.Empty, l.Size);
                    var inner = Rectangle.Inflate(client, -l.Corner / 2, -l.Corner / 2);
                    Rectangle[] visible = { l.Track, l.Thumb(WebcamBubble.MinPx), l.Thumb(WebcamBubble.MaxPx), l.Value, l.Divider, l.MirrorLabel, l.Toggle, l.Divider2, l.ShapeLabel, l.ShapeSwitch };
                    bool inside = client.Contains(l.TrackHit) && client.Contains(l.MirrorHit) && client.Contains(l.ShapeHit);
                    foreach (var r in visible) inside &= inner.Contains(r) && r.Width > 0 && r.Height > 0;
                    check("controls" + pct + ": every element inside the rounded window", inside);

                    var row1 = Rectangle.Union(Rectangle.Union(l.Track, l.Thumb(WebcamBubble.MinPx)), Rectangle.Union(l.Thumb(WebcamBubble.MaxPx), l.Value));
                    var row2 = Rectangle.Union(l.MirrorLabel, l.Toggle);
                    bool apart = !row1.IntersectsWith(row2) && !row1.IntersectsWith(l.Divider) && !row2.IntersectsWith(l.Divider) && row1.Bottom <= l.Divider.Top && l.Divider.Bottom <= row2.Top
                        && !l.Thumb(WebcamBubble.MaxPx).IntersectsWith(l.Value) && !l.MirrorLabel.IntersectsWith(l.Toggle)
                        && !l.TrackHit.IntersectsWith(l.MirrorHit) && !l.TrackHit.IntersectsWith(l.Value) && l.MirrorHit.Contains(l.Toggle) && l.MirrorHit.Contains(l.MirrorLabel);
                    check("controls" + pct + ": slider row above mirror row, no overlap (drawn or clickable)", apart);
                    var row3 = Rectangle.Union(l.ShapeLabel, l.ShapeSwitch);
                    bool apart3 = l.Divider.Bottom <= row2.Top && row2.Bottom <= l.Divider2.Top && l.Divider2.Bottom <= row3.Top && !row3.IntersectsWith(row2) && !row3.IntersectsWith(row1)
                        && !l.ShapeLabel.IntersectsWith(l.ShapeSwitch) && !l.ShapeHit.IntersectsWith(l.MirrorHit) && !l.ShapeHit.IntersectsWith(l.TrackHit)
                        && l.ShapeHit.Contains(l.ShapeSwitch) && l.ShapeHit.Contains(l.ShapeLabel) && !l.CircleSeg.IntersectsWith(l.RectSeg)
                        && l.ShapeSwitch.Contains(l.CircleSeg) && l.ShapeSwitch.Contains(l.RectSeg) && l.CircleSeg.Width >= l.Size.Width / 10;
                    check("controls" + pct + ": shape row below mirror row, circle and rectangle segments apart", apart3);
                    var cmid = new Point(l.CircleSeg.X + l.CircleSeg.Width / 2, l.CircleSeg.Y + l.CircleSeg.Height / 2);
                    var rmid = new Point(l.RectSeg.X + l.RectSeg.Width / 2, l.RectSeg.Y + l.RectSeg.Height / 2);
                    var lmid = new Point(l.ShapeLabel.X + 4, l.ShapeLabel.Y + l.ShapeLabel.Height / 2);
                    check("controls" + pct + ": shape switch hits (segment = that shape, label = toggle)", !l.ShapeFor(cmid, true) && !l.ShapeFor(cmid, false)
                        && l.ShapeFor(rmid, false) && l.ShapeFor(rmid, true) && l.ShapeFor(lmid, false) && !l.ShapeFor(lmid, true));

                    bool fits = true;
                    using (var font = new Font("Segoe UI", l.FontSize, GraphicsUnit.Pixel))
                    using (var fmt = new StringFormat(StringFormatFlags.NoWrap))
                    {
                        for (int v = WebcamBubble.MinPx; v <= WebcamBubble.MaxPx; v++)
                        {
                            var s = mg.MeasureString(ControlLayout.ValueText(v), font, PointF.Empty, fmt);
                            fits &= s.Width <= l.Value.Width && s.Height <= l.Value.Height;
                        }
                        var ms = mg.MeasureString(ControlLayout.MirrorText, font, PointF.Empty, fmt);
                        fits &= ms.Width <= l.MirrorLabel.Width && ms.Height <= l.MirrorLabel.Height;
                        var ss = mg.MeasureString(ControlLayout.ShapeText, font, PointF.Empty, fmt);
                        fits &= ss.Width <= l.ShapeLabel.Width && ss.Height <= l.ShapeLabel.Height;
                    }
                    check("controls" + pct + ": value (120-480 px), Mirror and Shape labels fit unclipped", fits);

                    // Exact at the ends; in between within one pixel's worth of sizes (the track is narrower than 360 sizes).
                    int step = (int)Math.Ceiling((WebcamBubble.MaxPx - WebcamBubble.MinPx) / (double)l.Track.Width);
                    bool map = l.ValueAt(l.ThumbX(WebcamBubble.MinPx)) == WebcamBubble.MinPx && l.ValueAt(l.ThumbX(WebcamBubble.MaxPx)) == WebcamBubble.MaxPx
                        && l.ValueAt(-50) == WebcamBubble.MinPx && l.ValueAt(l.Size.Width + 50) == WebcamBubble.MaxPx;
                    for (int v = WebcamBubble.MinPx; v <= WebcamBubble.MaxPx; v++) map &= Math.Abs(l.ValueAt(l.ThumbX(v)) - v) <= step;
                    check("controls" + pct + ": slider maps x <-> size both ways", map);

                    // Every opaque pixel that is not background belongs to one element's slot.
                    int stray = 0;
                    foreach (bool mirrorOn in new[] { true, false })
                        foreach (bool rectOn in new[] { true, false })
                        using (var bmp = l.Render(WebcamBubble.MaxPx, mirrorOn, rectOn))
                        {
                            Rectangle[] slots = { Rectangle.Inflate(l.Track, 1, 1), Rectangle.Inflate(l.Thumb(WebcamBubble.MaxPx), 1, 1), l.Value, l.Divider, l.MirrorLabel, Rectangle.Inflate(l.Toggle, 1, 1),
                                l.Divider2, l.ShapeLabel, Rectangle.Inflate(l.ShapeSwitch, 1, 1) };
                            for (int y = 0; y < bmp.Height; y++)
                                for (int x = 0; x < bmp.Width; x++)
                                {
                                    var px = bmp.GetPixel(x, y);
                                    if (px.A < 255 || (Math.Abs(px.R - ControlLayout.Bg.R) < 6 && Math.Abs(px.G - ControlLayout.Bg.G) < 6 && Math.Abs(px.B - ControlLayout.Bg.B) < 6)) continue;
                                    bool owned = false;
                                    foreach (var r in slots) if (r.Contains(x, y)) { owned = true; break; }
                                    if (!owned) stray++;
                                }
                        }
                    check("controls" + pct + ": rendered pixels stay in their slots (" + stray + " stray)", stray == 0);

                    // Placement on one monitor: sizes x positions x monitor sizes x taskbar sides.
                    int cases = 0, bad = 0, crowded = 0, overlapWithRoom = 0;
                    foreach (var mon in new[] { new Size(1920, 1080), new Size(2560, 1440), new Size(3840, 2160) })
                        foreach (var tb in new[] { "bottom", "top", "left", "right" })
                        {
                            var d = FakeDisplay(-mon.Width / 2, 300, mon.Width, mon.Height, dpi, tb);
                            foreach (int px in sizes)
                            foreach (bool rectShape in new[] { false, true })
                            {
                                var bs = WebcamBubble.SizeFor(px, dpi, rectShape);
                                foreach (int fx in new[] { 0, 1, 2 })
                                    foreach (int fy in new[] { 0, 1, 2 })
                                    {
                                        var bubble = new Rectangle(d.Bounds.Left + fx * (d.Bounds.Width - bs.Width) / 2, d.Bounds.Top + fy * (d.Bounds.Height - bs.Height) / 2, bs.Width, bs.Height);
                                        cases++;
                                        string why = PlacementProblem(l, bubble, d, ref crowded);
                                        if (why == "overlap") overlapWithRoom++;
                                        else if (why != null) bad++;
                                    }
                            }
                        }
                    check("controls" + pct + ": " + cases + " bubble spots (both shapes), window fully inside the monitor work area", bad == 0);
                    check("controls" + pct + ": beside the bubble whenever there is room (" + crowded + " spots with no room on any side)", overlapWithRoom == 0);
                }

                // Preferred sides on a plain 1920x1080 at 100 %.
                var l96 = new ControlLayout(96);
                var m = FakeDisplay(0, 0, 1920, 1080, 96, "bottom");
                var pl = l96.Place(new Rectangle(0, 400, 240, 240), m.WorkArea);
                var pr = l96.Place(new Rectangle(1680, 400, 240, 240), m.WorkArea);
                var pc = l96.Place(new Rectangle(1800, 960, 120, 120), m.WorkArea);
                var pw = l96.Place(new Rectangle(1600, 400, 320, 180), m.WorkArea);
                check("controls placement: right of a bubble at the left edge, centred on it", pl == new Point(250, 520 - 59));
                check("controls placement: flips left at the right edge", pr == new Point(1680 - 10 - 232, 520 - 59));
                check("controls placement: bottom-right corner over the taskbar = left, lifted into the work area", pc == new Point(1800 - 10 - 232, 1032 - 118));
                check("controls placement: beside a rectangle bubble, centred on it", pw == new Point(1600 - 10 - 232, 490 - 59));

                // Mixed DPI: 100 % in the middle, 200 % above-right, 150 % left. Each spot uses its own monitor's scale and
                // never spills onto a neighbour, including bubbles against the shared edges.
                var desk = new List<Display> { FakeDisplay(0, 0, 2560, 1440, 96, "bottom"), FakeDisplay(2560, -300, 3840, 2160, 192, "bottom"), FakeDisplay(-1920, 400, 1920, 1080, 144, "left") };
                int[] deskDpi = { 96, 192, 144 };
                int mixed = 0, mixedBad = 0, mixedCrowded = 0;
                for (int i = 0; i < desk.Count; i++)
                {
                    var d = desk[i];
                    var l = new ControlLayout(deskDpi[i]);
                    foreach (int px in sizes)
                    foreach (bool rectShape in new[] { false, true })
                    {
                        var bs = WebcamBubble.SizeFor(px, deskDpi[i], rectShape);
                        foreach (int fx in new[] { 0, 1, 2 })
                            foreach (int fy in new[] { 0, 1, 2 })
                            {
                                var bubble = new Rectangle(d.Bounds.Left + fx * (d.Bounds.Width - bs.Width) / 2, d.Bounds.Top + fy * (d.Bounds.Height - bs.Height) / 2, bs.Width, bs.Height);
                                mixed++;
                                if (Displays.Nearest(desk, Displays.Center(bubble)) != d || PlacementProblem(l, bubble, d, ref mixedCrowded) != null) { mixedBad++; continue; }
                                var at = new Rectangle(l.Place(bubble, d.WorkArea), l.Size);
                                foreach (var o in desk) if (o != d && o.Bounds.IntersectsWith(at)) mixedBad++;
                            }
                    }
                }
                check("controls placement, mixed DPI (100/200/150 %): " + mixed + " spots on the bubble's own monitor, sized for it, beside the bubble", mixedBad == 0 && mixedCrowded == 0);
            }
        }

        /// null when the controls for this bubble are fully inside the monitor's work area and clear of the bubble (or
        /// the bubble leaves no room on any side: counted in crowded); else "outside" / "overlap".
        static string PlacementProblem(ControlLayout l, Rectangle bubble, Display d, ref int crowded)
        {
            var at = new Rectangle(l.Place(bubble, d.WorkArea), l.Size);
            if (!d.WorkArea.Contains(at) || !d.Bounds.Contains(at)) return "outside";
            var wa = d.WorkArea;
            bool room = wa.Right - (bubble.Right + l.Gap) >= l.Size.Width || (bubble.Left - l.Gap) - wa.Left >= l.Size.Width
                || wa.Bottom - (bubble.Bottom + l.Gap) >= l.Size.Height || (bubble.Top - l.Gap) - wa.Top >= l.Size.Height;
            if (!room) { crowded++; return null; }
            return at.IntersectsWith(Rectangle.Inflate(bubble, l.Gap, l.Gap)) ? "overlap" : null;
        }

        /// --controls-shots DIR: offscreen renders of the webcam controls and the control pill at every tested scale, for review.
        static int ControlsShots(string[] args)
        {
            string dir = Path.GetFullPath(Arg(args, "--controls-shots") ?? ".");
            Directory.CreateDirectory(dir);
            foreach (int dpi in ControlDpis)
            {
                var pl = new PillLayout(dpi);
                foreach (var st in new[] { new { Name = "on", A = true, M = true, S = true, Hover = (string)null }, new { Name = "muted", A = true, M = false, S = false, Hover = (string)null },
                    new { Name = "hover-mic", A = true, M = true, S = false, Hover = PillLayout.Mic }, new { Name = "no-sources", A = false, M = false, S = false, Hover = PillLayout.Sys } })
                    using (var bmp = pl.Render(st.A, st.M, st.A, st.S, st.Hover))
                    {
                        string file = Path.Combine(dir, "pill-" + (dpi * 100 / 96) + "pct-" + st.Name + ".png");
                        bmp.Save(file, System.Drawing.Imaging.ImageFormat.Png);
                        Console.WriteLine(file + " " + bmp.Width + "x" + bmp.Height);
                    }
                var l = new ControlLayout(dpi);
                int pct = dpi * 100 / 96;
                foreach (var state in new[] { new { Px = WebcamBubble.MinPx, Mirror = true, Rect = false }, new { Px = WebcamBubble.DefaultPx, Mirror = false, Rect = true }, new { Px = WebcamBubble.MaxPx, Mirror = true, Rect = true } })
                    using (var bmp = l.Render(state.Px, state.Mirror, state.Rect))
                    {
                        string file = Path.Combine(dir, "controls-" + pct + "pct-" + state.Px + "px-mirror-" + (state.Mirror ? "on" : "off") + "-" + (state.Rect ? "rect" : "circle") + ".png");
                        bmp.Save(file, System.Drawing.Imaging.ImageFormat.Png);
                        Console.WriteLine(file + " " + bmp.Width + "x" + bmp.Height);
                    }
            }
            return 0;
        }
    }
}
