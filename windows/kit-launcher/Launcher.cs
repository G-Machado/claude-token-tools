// start-claude.exe - open Claude Code in a new console, in this exe's folder, with a prompt
// already typed into the input box but NOT sent: the user reads it and presses Enter.
//
// How: start claude in its own console, poll that console's screen (AttachConsole +
// ReadConsoleOutputCharacter) until the input box is up, then write the prompt into the
// console INPUT BUFFER as key events (WriteConsoleInputW) - no Enter. Same technique as
// token-poke.ps1 -NoEnter. Keys are only written once the screen shows the prompt box and
// no trust/permission dialog, because injected characters could answer such a dialog.
// If the box never shows up, the prompt goes to the clipboard and a message box says so.
//
//   start-claude.exe                 prompt from start-claude.txt beside the exe, else built-in
//   start-claude.exe "some prompt"   that prompt
//   start-claude.exe --probe         start claude, log screen snapshots, type nothing
// Log: %TEMP%\start-claude.log (fresh per run).
// Build: build.cmd (csc from .NET Framework 4, present on every Windows 10/11).
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

static class Launcher
{
    const string DefaultPrompt =
        "Read README.md and docs/workflow-kit/README.md in this folder, explain in a few lines what this kit " +
        "would change on my machine, then help me choose and set up a level. Install nothing until I say so.";

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len, COORD at, out uint read);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, uint n, out uint written);

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; public COORD(short x, short y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct CSBI { public COORD Size, Cursor; public ushort Attr; public SMALL_RECT Window; public COORD MaxSize; }
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct KEY_EVENT_RECORD
    {
        [FieldOffset(0)] public int KeyDown;
        [FieldOffset(4)] public ushort RepeatCount;
        [FieldOffset(6)] public ushort VirtualKeyCode;
        [FieldOffset(8)] public ushort VirtualScanCode;
        [FieldOffset(10)] public char UnicodeChar;
        [FieldOffset(12)] public uint ControlKeyState;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_RECORD { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD Key; }

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, SHARE_RW = 3, OPEN_EXISTING = 3;
    static StreamWriter log;

    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        bool probe = args.Length > 0 && args[0] == "--probe";
        string prompt = !probe && args.Length > 0 ? string.Join(" ", args) : LoadPrompt(dir);
        prompt = prompt.Replace("\r", " ").Replace("\n", " ").Trim(); // a newline would be Enter

        log = new StreamWriter(Path.Combine(Path.GetTempPath(), "start-claude.log"), false, new UTF8Encoding(false));
        log.AutoFlush = true;
        Log("dir=" + dir + " probe=" + probe + " promptChars=" + prompt.Length);

        string claude = FindClaude();
        if (claude == null)
        {
            Fail("Claude Code was not found on PATH (claude.exe / claude.cmd).\n\nInstall it, run it once, then try again.", prompt);
            return 2;
        }
        Log("claude=" + claude);

        ClearInheritedSessionEnv();
        var psi = new ProcessStartInfo(claude) { UseShellExecute = true, WorkingDirectory = dir };
        Process p;
        try { p = Process.Start(psi); }
        catch (Exception e) { Fail("Could not start Claude Code:\n" + e.Message, prompt); return 3; }
        uint pid = (uint)p.Id;
        Log("started pid=" + pid);

        // Poll the console screen until the input box is up (or give up after ~90 s;
        // a first-run trust dialog waits for the user, so the budget is generous).
        DateTime until = DateTime.Now.AddSeconds(probe ? 25 : 90);
        string lastState = "";
        while (DateTime.Now < until)
        {
            Thread.Sleep(probe ? 2000 : 700);
            if (p.HasExited) { Log("claude exited early, code " + SafeExit(p)); break; }
            string screen = ReadScreen(pid);
            if (screen == null) { Log("screen unreadable yet"); continue; }
            if (probe) { Log("---- snapshot ----\n" + screen); continue; }
            string state = Classify(screen);
            if (state != lastState) { Log("state=" + state); lastState = state; }
            if (state != "ready") continue;
            Thread.Sleep(600); // let the TUI settle into the box
            if (Classify(ReadScreen(pid) ?? "") != "ready") continue;
            if (TypeInto(pid, prompt)) { Log("typed, no Enter"); return 0; }
            break;
        }
        if (probe) { Log("probe done"); return 0; }
        Fail("Claude Code started, but the prompt could not be typed into it.\n\n" +
             "It has been copied to the clipboard: click the Claude window, press Ctrl+V, then Enter.", prompt);
        return 4;
    }

    // ready = an input box is visible and no dialog is asking a question.
    static string Classify(string s)
    {
        string l = s.ToLowerInvariant();
        if (l.Contains("do you trust") || l.Contains("trust the files") || l.Contains("trust this folder")) return "trust-dialog";
        if (l.Contains("select login") || l.Contains("login method") || l.Contains("choose the text style") || l.Contains("press enter to continue")) return "setup-dialog";
        if (l.Contains("safety check") || l.Contains("yes, proceed") || l.Contains("yes, i trust")) return "trust-dialog";
        // The input box: a line starting with ">" (or "❯", or "│ >" in older builds) directly under a
        // horizontal rule of "─". Measured on v2.1.316: "────…" / "> Try \"how does <filepath> work?\"" / "────…".
        // "? for shortcuts" is not reliable - a custom status line replaces it.
        string[] lines = s.Split('\n');
        for (int i = 1; i < lines.Length; i++)
        {
            string t = lines[i].TrimStart();
            bool caret = t.StartsWith(">") || t.StartsWith("❯") || t.StartsWith("│ >");
            if (caret && IsRule(lines[i - 1])) return "ready";
        }
        return "starting";
    }

    static bool IsRule(string line)
    {
        string t = line.Trim();
        if (t.Length < 20) return false;
        foreach (char c in t) if (c != '─' && c != '━' && c != '╭' && c != '╮') return false;
        return true;
    }

    // Started from inside another Claude session (or TokenChat), the child would inherit markers that
    // switch transcript saving off; a double-click from Explorer has none of these, so clearing is a no-op there.
    static void ClearInheritedSessionEnv()
    {
        foreach (string v in new[] { "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
                                     "CLAUDE_CODE_SSE_PORT", "AI_AGENT", "TOKEN_CHAT" })
            Environment.SetEnvironmentVariable(v, null);
    }

    static string LoadPrompt(string dir)
    {
        string f = Path.Combine(dir, "start-claude.txt");
        try { if (File.Exists(f)) { string t = File.ReadAllText(f, Encoding.UTF8).Trim(); if (t.Length > 0) return t; } }
        catch { }
        return DefaultPrompt;
    }

    static string FindClaude()
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] extra = { Path.Combine(home, ".local\\bin"), Path.Combine(home, "AppData\\Roaming\\npm") };
        foreach (string name in new[] { "claude.exe", "claude.cmd" })
        {
            foreach (string d in (path + ";" + string.Join(";", extra)).Split(';'))
            {
                if (d.Trim().Length == 0) continue;
                try { string c = Path.Combine(d.Trim().Trim('"'), name); if (File.Exists(c)) return c; } catch { }
            }
        }
        return null;
    }

    static string ReadScreen(uint pid)
    {
        FreeConsole();
        if (!AttachConsole(pid)) return null;
        try
        {
            IntPtr h = CreateFileW("CONOUT$", GENERIC_READ | GENERIC_WRITE, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == new IntPtr(-1)) return null;
            try
            {
                CSBI i;
                if (!GetConsoleScreenBufferInfo(h, out i)) return null;
                int w = i.Size.X, top = i.Window.Top, rows = i.Window.Bottom - i.Window.Top + 1;
                if (w <= 0 || rows <= 0) return null;
                var sb = new StringBuilder();
                char[] line = new char[w];
                for (int y = top; y < top + rows; y++)
                {
                    uint n;
                    if (ReadConsoleOutputCharacterW(h, line, (uint)w, new COORD(0, (short)y), out n))
                        sb.Append(new string(line, 0, (int)n).TrimEnd()).Append('\n');
                }
                return sb.ToString();
            }
            finally { CloseHandle(h); }
        }
        finally { FreeConsole(); }
    }

    // One key-down/key-up pair per character, written one character per call: a single
    // multi-character write arrives as a paste (token-poke.ps1 notes), which is harmless
    // without Enter but can collapse into "[Pasted text]" for long prompts.
    static bool TypeInto(uint pid, string text)
    {
        FreeConsole();
        if (!AttachConsole(pid)) { Log("attach for typing failed " + Marshal.GetLastWin32Error()); return false; }
        try
        {
            IntPtr h = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == new IntPtr(-1)) { Log("CONIN$ open failed " + Marshal.GetLastWin32Error()); return false; }
            try
            {
                foreach (char c in text)
                {
                    var recs = new INPUT_RECORD[2];
                    for (int k = 0; k < 2; k++)
                    {
                        recs[k].EventType = 1; // KEY_EVENT
                        recs[k].Key.KeyDown = k == 0 ? 1 : 0;
                        recs[k].Key.RepeatCount = 1;
                        recs[k].Key.UnicodeChar = c;
                    }
                    uint wrote;
                    if (!WriteConsoleInputW(h, recs, 2, out wrote) || wrote != 2)
                    { Log("WriteConsoleInputW failed " + Marshal.GetLastWin32Error()); return false; }
                    Thread.Sleep(2);
                }
                return true;
            }
            finally { CloseHandle(h); }
        }
        finally { FreeConsole(); }
    }

    static void Fail(string msg, string prompt)
    {
        Log("FAIL " + msg.Replace("\n", " "));
        try { Clipboard.SetText(prompt); } catch { }
        MessageBox.Show(msg, "start-claude", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    static string SafeExit(Process p) { try { return p.ExitCode.ToString(); } catch { return "?"; } }
    static void Log(string s) { if (log != null) log.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + " " + s); }
}
