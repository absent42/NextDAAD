using System;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;

namespace NextDAADDebug.Autopilot
{
    // Runs one script step at a time, Frame() once per OSTick. A failed wait aborts the run (rest SKIPPED);
    // any other failure continues. Never throws: host exceptions become FAIL lines.
    public sealed class Engine
    {
        const double StepAdvanceSeconds = 2;
        const string Unreadable = "(game screen not readable)";

        readonly List<Step> steps;
        readonly IAutopilotHost host;
        readonly ResultWriter writer;
        readonly Func<double> clock;
        readonly bool hasQuit;
        int index, phase, col, row, startOffset, startState;
        bool begun;
        double started;

        public bool Finished { get; private set; }
        public int Failures { get; private set; }

        public Engine(List<Step> steps, IAutopilotHost host, ResultWriter writer, Func<double> clockSeconds)
        {
            this.steps = steps ?? new List<Step>();
            this.host = host;
            this.writer = writer;
            clock = clockSeconds;
            hasQuit = this.steps.Exists(s => s.Kind == StepKind.Quit);
        }

        public void Frame()
        {
            if (Finished) return;
            try { Advance(); }
            catch (Exception)
            {
                // Only the writer can get here; stop rather than retry every frame.
                Finished = true;
                try { writer.Finish(Failures); } catch (Exception) { }
            }
        }

        // Host fault: the current step FAILs, the rest are SKIPPED, DONE is written. No-op once finished.
        public void Abort(string reason)
        {
            if (Finished) return;
            Finished = true;
            try
            {
                if (index < steps.Count)
                {
                    writer.Result(steps[index], "FAIL", Expected(steps[index]), "autopilot stopped: " + reason);
                    index++;
                }
                Failures++;
                for (; index < steps.Count; index++) writer.Result(steps[index], "SKIPPED", Expected(steps[index]), "not run");
                writer.Finish(Failures);
            }
            catch (Exception) { }
        }

        void Advance()
        {
            if (index >= steps.Count) { End(false); return; }
            Step s = steps[index];
            string verdict, actual = null;
            try
            {
                if (!begun) { begun = true; phase = 0; started = clock(); }
                verdict = Run(s, ref actual);
            }
            catch (Exception e) { verdict = "FAIL"; actual = "exception: " + e.Message; }
            if (verdict == null) return;

            writer.Result(s, verdict, Expected(s), actual);
            if (verdict == "FAIL") Failures++;
            index++;
            begun = false;
            DumpNow(index);
            bool wait = s.Kind == StepKind.WaitStatus || s.Kind == StepKind.WaitScreen || s.Kind == StepKind.WaitGame;
            if (wait && verdict == "FAIL") End(hasQuit);
            else if (s.Kind == StepKind.Quit) End(true);
            else if (index >= steps.Count) End(false);
        }

        void End(bool quit)
        {
            for (; index < steps.Count; index++) writer.Result(steps[index], "SKIPPED", Expected(steps[index]), "not run");
            writer.Finish(Failures);
            Finished = true;
            if (quit) try { host.Quit(); } catch (Exception) { }
        }

        void DumpNow(int n)
        {
            CellScreen screen = null;
            try { screen = host.Screen; } catch (Exception) { }
            writer.Dump(n, screen, SafeGame());
        }

        string[] SafeGame()
        {
            try { return host.GameRows(); } catch (Exception) { return null; }
        }

        bool TimedOut(Step s) => clock() - started >= s.Timeout;

        // Returns the verdict, or null while the step is still running.
        string Run(Step s, ref string actual)
        {
            switch (s.Kind)
            {
                case StepKind.WaitStatus:
                case StepKind.WaitScreen:
                case StepKind.WaitGame:
                {
                    int r = Check(s, out actual);
                    if (r == 1) return "PASS";
                    return TimedOut(s) ? "FAIL" : null;
                }
                case StepKind.ExpectStatus:
                case StepKind.ExpectScreen:
                case StepKind.ExpectGame:
                case StepKind.ExpectLog:
                {
                    int r = Check(s, out actual);
                    if (r < 0) return "FAIL";
                    return (r == 1) != s.Not ? "PASS" : "FAIL";
                }
                case StepKind.ExpectColour:
                {
                    byte want;
                    if (!TryTheme(s.Theme, out want)) { actual = "unknown theme colour '" + s.Theme + "'"; return "FAIL"; }
                    int x, y;
                    CellScreen sc = host.Screen;
                    if (!sc.Find(s.Text, out x, out y)) { actual = "not on screen"; return "FAIL"; }
                    byte fg = sc[x, y].Fg;
                    actual = ThemeName(fg) + " at @" + x + "," + y;
                    return fg == want ? "PASS" : "FAIL";
                }
                case StepKind.Click:
                case StepKind.ClickCell:
                case StepKind.Wheel:
                    return Pointer(s, ref actual);
                case StepKind.Type:
                    if (host.Type(s.Text)) return "PASS";
                    actual = "not accepted: " + s.Text;
                    return "FAIL";
                case StepKind.Key:
                    if (s.Text == "esc")
                    {
                        if (host.Cancel()) return "PASS";
                        actual = "no popup open";
                        return "FAIL";
                    }
                    if (host.Accept()) return "PASS";
                    actual = "nothing to accept";
                    return "FAIL";
                case StepKind.Hotkey:
                    host.Hotkey(s.Text[0]);
                    return "PASS";
                case StepKind.Game:
                    if (phase == 0)
                    {
                        // Keys only advance while running; typing into a halted game could never be read.
                        if (host.DebuggerState() != 0) { actual = "game typed while halted"; return "FAIL"; }
                        host.Keys.Enqueue(s.Text);
                        phase = 1;
                        return null;
                    }
                    if (host.Keys.Sent) return "PASS";
                    if (!TimedOut(s)) return null;
                    actual = "keys still queued";
                    return "FAIL";
                case StepKind.Dump:
                    actual = "dump " + s.Text + " " + (index + 1).ToString("D3");
                    return "PASS";
                case StepKind.Note:
                    actual = s.Text;
                    return "PASS";
                case StepKind.Measure:
                    return Measure(s, ref actual);
                case StepKind.Quit:
                    return "PASS";
            }
            actual = "unsupported step";
            return "FAIL";
        }

        // 1 found, 0 not found, -1 game text unreadable.
        int Check(Step s, out string actual)
        {
            switch (s.Kind)
            {
                case StepKind.WaitStatus:
                case StepKind.ExpectStatus:
                {
                    string st = host.Status ?? "";
                    actual = st;
                    return st.IndexOf(s.Text, StringComparison.Ordinal) >= 0 ? 1 : 0;
                }
                case StepKind.WaitScreen:
                case StepKind.ExpectScreen:
                {
                    int x, y;
                    CellScreen sc = host.Screen;
                    if (sc.Find(s.Text, out x, out y)) { actual = "row " + y + ": " + sc.RowText(y).TrimEnd(' ', '\0'); return 1; }
                    actual = "not on screen";
                    return 0;
                }
                case StepKind.ExpectLog:
                {
                    string log = host.LogText() ?? "";
                    if (log.IndexOf(s.Text, StringComparison.Ordinal) >= 0) { actual = "in log"; return 1; }
                    actual = "not in log";
                    return 0;
                }
                default:
                {
                    string[] rows = SafeGame();
                    if (rows == null) { actual = Unreadable; return -1; }
                    for (int i = 0; i < rows.Length; i++)
                        if (rows[i] != null && rows[i].IndexOf(s.Text, StringComparison.Ordinal) >= 0)
                        {
                            actual = "game row " + i + ": " + rows[i].TrimEnd();
                            return 1;
                        }
                    actual = "not in game text";
                    return 0;
                }
            }
        }

        // One UiInput per frame: move, then press (or wheel), then release.
        string Pointer(Step s, ref string actual)
        {
            if (phase == 0)
            {
                if (s.Kind == StepKind.ClickCell || (s.Kind == StepKind.Wheel && s.Text == null)) { col = s.Col; row = s.Row; }
                else
                {
                    int x, y;
                    if (!host.Screen.Find(s.Text, out x, out y, s.FromRow, s.ToRow))
                    {
                        actual = "not on screen in rows " + s.FromRow + "-" + s.ToRow;
                        return "FAIL";
                    }
                    col = x + s.Text.Length / 2;
                    row = y;
                }
                host.Inject(new UiInput { Col = col, Row = row, HasEvent = true });
                phase = 1;
                return null;
            }
            if (phase == 1)
            {
                var u = new UiInput { Col = col, Row = row, HasEvent = true };
                if (s.Kind == StepKind.Wheel) u.Wheel = s.Amount; else u.LeftClick = true;
                host.Inject(u);
                phase = 2;
                return null;
            }
            host.Inject(new UiInput { Col = col, Row = row, HasEvent = true });
            actual = "@" + col + "," + row;
            return "PASS";
        }

        // step-advances: when halted (DebuggerState() != 0), press the step hotkey and watch CurrentOffset
        // for StepAdvanceSeconds; the fact carries the debugger state before and after.
        string Measure(Step s, ref string actual)
        {
            string v;
            switch (s.Text)
            {
                case "halted-state": v = host.DebuggerState().ToString(CultureInfo.InvariantCulture); break;
                case "ticks-while-halted": v = host.TicksWhileHalted.ToString(CultureInfo.InvariantCulture); break;
                case "step-advances":
                {
                    if (phase == 0)
                    {
                        startState = host.DebuggerState();
                        if (startState == 0) { v = "not halted"; break; }
                        startOffset = host.CurrentOffset;
                        host.Hotkey('n');
                        phase = 1;
                        return null;
                    }
                    int cur = host.CurrentOffset;
                    string halted = " halted=" + startState + "->" + host.DebuggerState();
                    if (cur != startOffset) v = "yes " + startOffset + "->" + cur + halted;
                    else if (clock() - started >= StepAdvanceSeconds) v = "no " + startOffset + halted;
                    else return null;
                    break;
                }
                default: actual = "unknown measure"; return "FAIL";
            }
            writer.Fact(s.Text, v);
            actual = s.Text + "=" + v;
            return "PASS";
        }

        static bool TryTheme(string name, out byte value)
        {
            value = 0;
            FieldInfo f = name == null ? null : typeof(Theme).GetField(name, BindingFlags.Public | BindingFlags.Static);
            if (f == null || !f.IsLiteral || f.FieldType != typeof(byte)) return false;
            value = (byte)f.GetRawConstantValue();
            return true;
        }

        static string ThemeName(byte v)
        {
            foreach (FieldInfo f in typeof(Theme).GetFields(BindingFlags.Public | BindingFlags.Static))
                if (f.IsLiteral && f.FieldType == typeof(byte) && (byte)f.GetRawConstantValue() == v) return f.Name;
            return "colour " + v;
        }

        static string Expected(Step s)
        {
            string q = "\"" + s.Text + "\"";
            switch (s.Kind)
            {
                case StepKind.WaitStatus: return "status contains " + q + " within " + s.Timeout + "s";
                case StepKind.WaitScreen: return "screen contains " + q + " within " + s.Timeout + "s";
                case StepKind.WaitGame: return "game contains " + q + " within " + s.Timeout + "s";
                case StepKind.ExpectStatus: return "status " + (s.Not ? "lacks " : "contains ") + q;
                case StepKind.ExpectScreen: return "screen " + (s.Not ? "lacks " : "contains ") + q;
                case StepKind.ExpectGame: return "game " + (s.Not ? "lacks " : "contains ") + q;
                case StepKind.ExpectLog: return "log " + (s.Not ? "lacks " : "contains ") + q;
                case StepKind.ExpectColour: return q + " in " + s.Theme;
                case StepKind.Click: return q + " on screen";
                case StepKind.ClickCell: return "click @" + s.Col + "," + s.Row;
                case StepKind.Wheel: return "wheel " + s.Amount;
                case StepKind.Game: return "keys sent within " + s.Timeout + "s";
                case StepKind.Measure: return "fact";
                default: return "-";
            }
        }
    }
}
