using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace NextDAADDebug
{
    public sealed class DebuggerView
    {
        const int Cols = 100, Rows = 40, TopY = 2, TopH = 20, LeftW = 27, RightX = 28, BottomY = 22;
        static readonly string[] TopTabs = { "Condacts", "Source" };
        static readonly string[] BottomTabs = { "Watches", "Flags", "Objects", "Parser", "Database", "Breakpoints" };
        static readonly string[] DbTabs = { "Messages", "SysMess", "Locations", "Objects", "Vocab", "Tokens", "Connections" };

        readonly Settings settings;
        readonly string settingsPath;
        readonly SourceCache sources;
        int topTab, bottomTab, dbTab, level = -1;
        int stackTop, condTop, srcTop, flagTop, objTop, watchTop, dbTop, bpTop;
        bool wasHalted;
        Popup popup;
        Action<Popup, PopupResult> onPopup;
        Breakpoint[] lastBps;
        string lastSaved;
        Ddb rowsDdb;
        int rowsTab = -1;
        List<string> rows = new List<string>();

        public DebuggerView(Settings settings, string settingsPath, string sourceRoot)
        {
            this.settings = settings;
            this.settingsPath = settingsPath;
            sources = new SourceCache(sourceRoot);
        }

        public bool PopupOpen => popup != null;

        public void Draw(Ui ui, Snapshot s, Action<Command> post, bool inputAvailable = true)
        {
            bool newHalt = s.Halted && !wasHalted;
            wasHalted = s.Halted;
            if (newHalt || level < 0 || level >= s.Stack.Length) level = s.Stack.Length - 1;
            bool hadPopup = popup != null;
            ui.Blocked = hadPopup;
            Toolbar(ui, s, post, inputAvailable);
            StatusLine(ui, s);
            StackPane(ui, s);
            int tab = ui.Tabs(RightX, TopY, TopTabs, topTab);
            bool follow = newHalt || tab != topTab;           // re-centre on the current condact
            topTab = tab;
            if (topTab == 0) CondactPane(ui, s, follow);
            else SourcePane(ui, s, post, follow);
            bottomTab = ui.Tabs(0, BottomY, BottomTabs, bottomTab);
            int y0 = BottomY + 1, h = Rows - y0;
            switch (bottomTab)
            {
                case 0: WatchPane(ui, s, y0, h); break;
                case 1: FlagPane(ui, s, post, y0, h); break;
                case 2: ObjectPane(ui, s, post, y0, h); break;
                case 3: ParserPane(ui, s, y0); break;
                case 4: DatabasePane(ui, s, y0, h); break;
                default: BreakpointPane(ui, s, post, y0, h); break;
            }
            if (popup != null)
            {
                ui.Blocked = !hadPopup;      // a popup opened this frame gets no input until the next
                var p = popup;
                var r = p.Draw(ui);
                if (r != PopupResult.Open)
                {
                    var cb = onPopup;
                    popup = null;
                    onPopup = null;
                    if (cb != null) cb(p, r);
                }
            }
            lastBps = s.Breakpoints;
            SaveIfChanged();
        }

        void Ask(Popup p, Action<Popup, PopupResult> cb)
        {
            popup = p;
            onPopup = cb;
        }

        public void SaveIfChanged()
        {
            if (settingsPath == null || lastBps == null) return;
            string text = settings.Serialize(lastBps);
            if (text == lastSaved) return;
            lastSaved = text;
            try { File.WriteAllText(settingsPath, text, new UTF8Encoding(false)); }
            catch (Exception ex) { Log.Write("settings not saved: " + ex.Message); }
        }

        void Toolbar(Ui ui, Snapshot s, Action<Command> post, bool inputAvailable)
        {
            bool h = s.Halted;
            int x = 0;
            x = Btn(ui, x, "Run", h, () => post(Command.Of(CommandKind.Run)));
            x = Btn(ui, x, "Break", s.Active && !h, () => post(Command.Of(CommandKind.Break)));
            x = Btn(ui, x, "Step", h, () => post(Command.Of(CommandKind.Step)));
            x = Btn(ui, x, "Step entry", h, () => post(Command.Of(CommandKind.StepEntry)));
            x = Btn(ui, x, "Step out", h, () => post(Command.Of(CommandKind.StepOut)));
            Btn(ui, x, "Run to PARSE", h, () => post(Command.Of(CommandKind.RunToParse)));
            if (inputAvailable) ui.S.Text(Cols - 22, 0, "Ctrl+Alt+A/B/N/R", Theme.Dim, Theme.Bg);
            else ui.S.Text(Cols - 30, 0, "display only - Ctrl+Alt+B/N/R", Theme.Dim, Theme.Bg);
        }

        static int Btn(Ui ui, int x, string label, bool enabled, Action act)
        {
            if (ui.Button(x, 0, label, enabled)) act();
            return x + label.Length + 3;
        }

        static void StatusLine(Ui ui, Snapshot s)
        {
            if (s.Problem != null) ui.S.Text(0, 1, s.Problem, Theme.Error, Theme.Bg, Cols);
            else ui.S.Text(0, 1, s.Status, s.Halted ? Theme.Changed : Theme.Text, Theme.Bg, Cols);
        }

        void StackPane(Ui ui, Snapshot s)
        {
            ui.S.Text(0, TopY, "Process stack", Theme.Accent, Theme.Bg);
            int n = s.Stack.Length, y = TopY + 1, h = TopH - 1;
            if (n == 0) { ui.S.Text(0, y, s.Active ? "(empty)" : "waiting for NextDAAD", Theme.Dim, Theme.Bg, LeftW); return; }
            int hit = ui.List(ref stackTop, 0, y, LeftW, h, n);
            if (hit >= 0) level = n - 1 - hit;
            for (int r = 0; r < h && stackTop + r < n; r++)
            {
                int lv = n - 1 - (stackTop + r);
                var f = s.Stack[lv];
                string verb = "", noun = "";
                if (s.Ddb != null && f.EntryPtr >= 0)
                {
                    verb = CondactFormatter.Word(s.Ddb, s.Ddb.Byte(f.EntryPtr), WordType.Verb);
                    noun = CondactFormatter.Word(s.Ddb, s.Ddb.Byte(f.EntryPtr + 1), WordType.Noun);
                }
                string line = (lv == level ? ">" : " ") + lv + " PRO " + f.Proc + " " + verb + " " + noun;
                SourceLoc loc;
                if (s.Map != null && s.Map.Entries.TryGetValue(f.EntryPtr, out loc)) line += " :" + loc.Line;
                ui.S.Text(0, y + r, line.PadRight(LeftW), Theme.Text, lv == level ? Theme.Current : Theme.Bg, LeftW);
            }
        }

        // Top level: the condact at HL. Lower levels: the one ending at the saved condactPtr (their PROCESS).
        static int CurrentIndex(Snapshot s, int level, List<DecodedCondact> list)
        {
            bool top = level == s.Stack.Length - 1;
            int target = top ? s.Offset : s.Stack[level].CondactPtr;
            for (int i = 0; i < list.Count; i++)
                if (top ? list[i].Offset == target : list[i].Offset + list[i].Length == target) return i;
            return -1;
        }

        void CondactPane(Ui ui, Snapshot s, bool follow)
        {
            int y = TopY + 1, w = Cols - RightX, h = TopH - 1;
            if (s.Ddb == null || level < 0 || level >= s.Stack.Length)
            {
                ui.S.Text(RightX, y, s.Active ? "no process running" : "waiting for NextDAAD", Theme.Dim, Theme.Bg, w);
                return;
            }
            var list = s.Ddb.EntryCondacts(s.Ddb.EntryCondactStart(s.Stack[level].EntryPtr));
            int cur = CurrentIndex(s, level, list);
            if (follow && cur >= 0) condTop = Math.Max(0, cur - h / 2);
            ui.List(ref condTop, RightX, y, w, h, list.Count);
            for (int r = 0; r < h && condTop + r < list.Count; r++)
            {
                int i = condTop + r;
                var c = list[i];
                string text = CondactFormatter.Rich(c, s.Ddb, s.Flags);
                if (i == cur && level == s.Stack.Length - 1 && s.IndirPending >= 0) text += "  [INDIR arg2=" + s.IndirPending + "]";
                SourceLoc loc;
                string where = s.Map != null && s.Map.TryLocate(c.Offset, out loc) ? loc.Line.ToString() : c.Offset.ToString("X4");
                string line = (i == cur ? (char)0x10 : ' ') + where.PadLeft(5) + " " + text;
                ui.S.Text(RightX, y + r, line.PadRight(w), Theme.Text, i == cur ? Theme.Current : Theme.Bg, w);
            }
        }

        bool CurrentLoc(Snapshot s, out SourceLoc loc)
        {
            loc = new SourceLoc();
            if (s.Map == null || s.Ddb == null || level < 0 || level >= s.Stack.Length) return false;
            var list = s.Ddb.EntryCondacts(s.Ddb.EntryCondactStart(s.Stack[level].EntryPtr));
            int i = CurrentIndex(s, level, list);
            return i >= 0 && s.Map.TryLocate(list[i].Offset, out loc);
        }

        static bool HasLineBp(Snapshot s, int file, int line)
        {
            foreach (var b in s.Breakpoints) if (b.Kind == BreakKind.SourceLine && b.A == file && b.B == line) return true;
            return false;
        }

        void SourcePane(Ui ui, Snapshot s, Action<Command> post, bool follow)
        {
            int y = TopY + 1, w = Cols - RightX, h = TopH - 1;
            if (s.Map == null) { ui.S.Text(RightX, y, s.MapProblem ?? "no source map", Theme.Dim, Theme.Bg, w); return; }
            SourceLoc cur;
            bool hasCur = CurrentLoc(s, out cur);
            int file = hasCur ? cur.File : 0;
            string path;
            if (!s.Map.Files.TryGetValue(file, out path)) { ui.S.Text(RightX, y, "file " + file + " not in the source map", Theme.Dim, Theme.Bg, w); return; }
            string[] lines = sources.Lines(path);
            if (follow && hasCur) srcTop = Math.Max(0, cur.Line - 1 - h / 2);
            int hit = ui.List(ref srcTop, RightX, y, w, h, lines.Length);
            if (hit >= 0 && ui.In.Col - RightX < 2)
            {
                var bp = new Breakpoint { Kind = BreakKind.SourceLine, A = file, B = hit + 1 };
                if (HasLineBp(s, file, hit + 1)) post(Command.For(CommandKind.RemoveBreakpoint, bp));
                else if (s.Map.OffsetsForLine(file, hit + 1).Count > 0) post(Command.For(CommandKind.AddBreakpoint, bp));
            }
            for (int r = 0; r < h && srcTop + r < lines.Length; r++)
            {
                int ln = srcTop + r + 1;
                bool isCur = hasCur && cur.Line == ln;
                byte bg = isCur ? Theme.Current : Theme.Bg;
                ui.S.Put(RightX, y + r, HasLineBp(s, file, ln) ? (byte)0x07 : (byte)' ', Theme.Break, bg);
                ui.S.Put(RightX + 1, y + r, isCur ? (byte)0x10 : (byte)' ', Theme.Text, bg);
                ui.S.Text(RightX + 2, y + r, (ln.ToString().PadLeft(4) + " " + lines[ln - 1]).PadRight(w - 2), Theme.Text, bg, w - 2);
            }
        }

        void ToggleWatch(bool obj, int n)
        {
            int i = settings.Watches.FindIndex(w => w.IsObject == obj && w.Number == n);
            if (i >= 0) settings.Watches.RemoveAt(i);
            else settings.Watches.Add(new Watch { IsObject = obj, Number = n });
        }

        void AddWatch(bool obj, int n)
        {
            if (n >= 0 && n < 256 && !settings.Watches.Exists(w => w.IsObject == obj && w.Number == n)) settings.Watches.Add(new Watch { IsObject = obj, Number = n });
        }

        void WatchPane(Ui ui, Snapshot s, int y0, int h)
        {
            if (ui.Button(0, y0, "+ Flag")) Ask(new Picker("Watch flag", Lists.Flags(s.Ddb, s.Map)), (p, r) => { if (r == PopupResult.Ok) AddWatch(false, ((Picker)p).Selected); });
            if (ui.Button(10, y0, "+ Object")) Ask(new Picker("Watch object", Lists.Objects(s.Ddb)), (p, r) => { if (r == PopupResult.Ok) AddWatch(true, ((Picker)p).Selected); });
            if (ui.Button(22, y0, "+ Symbol"))
                Ask(new Picker("Watch symbol", Lists.Symbols(s.Map)), (p, r) =>
                {
                    if (r != PopupResult.Ok) return;
                    int v = ((Picker)p).Selected;
                    Ask(new Picker("Watch " + v + " as", Lists.WatchKinds()), (p2, r2) => { if (r2 == PopupResult.Ok) AddWatch(((Picker)p2).Selected == 1, v); });
                });
            int y = y0 + 1, lh = h - 1, n = settings.Watches.Count;
            int hit = ui.List(ref watchTop, 0, y, Cols, lh, n);
            if (hit >= 0 && ui.In.Col < 3) { settings.Watches.RemoveAt(hit); return; }
            for (int r = 0; r < lh && watchTop + r < n; r++)
            {
                var w = settings.Watches[watchTop + r];
                if (w.Number < 0 || w.Number > 255) continue;
                string text;
                bool changed;
                if (w.IsObject)
                {
                    int loc = s.ObjTable[w.Number * 6];
                    changed = s.ChangedBaseObj != null && s.ChangedBaseObj[w.Number * 6] != loc;
                    text = "obj  " + w.Number.ToString().PadLeft(3) + " " + Fit(CondactFormatter.ObjectName(s.Ddb, w.Number), 20) + " @ " + loc + " " + (CondactFormatter.LocationName(s.Ddb, loc) ?? "");
                }
                else
                {
                    int v = s.Flags[w.Number];
                    changed = s.ChangedBase != null && s.ChangedBase[w.Number] != v;
                    text = "flag " + w.Number.ToString().PadLeft(3) + " " + Fit(Lists.FlagLabel(w.Number, s.Map), 20) + " = " + v + "  " + Lists.FlagHint(w.Number, v, s.Ddb);
                }
                ui.S.Text(0, y + r, (" x " + text).PadRight(Cols), changed ? Theme.Changed : Theme.Text, Theme.Bg, Cols);
            }
        }

        // Row: " + " nnnn " " label(20) " " value(5): value occupies columns 29-33.
        void FlagPane(Ui ui, Snapshot s, Action<Command> post, int y0, int h)
        {
            ui.S.Text(0, y0, " w  flag name                 value", Theme.Accent, Theme.Bg);
            if (ui.Button(Cols - 10, y0, "Go to #")) Ask(new DigitPad("Go to flag", flagTop, 0, 255), (p, r) => { if (r == PopupResult.Ok) flagTop = ((DigitPad)p).Value; });
            int y = y0 + 1, lh = h - 1;
            int wheel = ui.Wheel(29, y, 5, lh);
            int hit;
            if (wheel != 0 && s.Halted)
            {
                int wf = flagTop + (ui.In.Row - y);
                if (wf < 256) post(Command.Of(CommandKind.SetFlag, wf, Math.Max(0, Math.Min(255, s.Flags[wf] + wheel))));
                int saved = ui.In.Wheel;
                ui.In.Wheel = 0;                  // the list must not scroll for this event
                hit = ui.List(ref flagTop, 0, y, Cols, lh, 256);
                ui.In.Wheel = saved;
            }
            else hit = ui.List(ref flagTop, 0, y, Cols, lh, 256);
            if (hit >= 0)
            {
                int col = ui.In.Col, f = hit;
                if (col < 3) ToggleWatch(false, f);
                else if (col >= 29 && col <= 33 && s.Halted)
                    Ask(new DigitPad("Flag " + f, s.Flags[f], 0, 255), (p, r) => { if (r == PopupResult.Ok) post(Command.Of(CommandKind.SetFlag, f, ((DigitPad)p).Value)); });
            }
            for (int r = 0; r < lh && flagTop + r < 256; r++)
            {
                int f = flagTop + r, v = s.Flags[f];
                bool changed = s.ChangedBase != null && s.ChangedBase[f] != v;
                bool watched = settings.Watches.Exists(w => !w.IsObject && w.Number == f);
                string line = (watched ? " * " : " + ") + f.ToString().PadLeft(4) + " " + Fit(Lists.FlagLabel(f, s.Map), 20) + " " + v.ToString().PadLeft(5) + "  " + Lists.FlagHint(f, v, s.Ddb);
                ui.S.Text(0, y + r, line.PadRight(Cols), changed ? Theme.Changed : Theme.Text, Theme.Bg, Cols);
            }
        }

        // Row: " + " nnnn " " name(16) " " loc(4) " " where(18): location click area is columns 25-47.
        void ObjectPane(Ui ui, Snapshot s, Action<Command> post, int y0, int h)
        {
            ui.S.Text(0, y0, " w   obj name             loc  where               wt C W attrs", Theme.Accent, Theme.Bg);
            int n = s.NumObjects > 0 ? s.NumObjects : s.Ddb != null ? s.Ddb.NumObjects : 0;
            n = Math.Min(n, s.ObjTable.Length / 6);
            if (ui.Button(Cols - 10, y0, "Go to #")) Ask(new DigitPad("Go to object", objTop, 0, Math.Max(0, n - 1)), (p, r) => { if (r == PopupResult.Ok) objTop = ((DigitPad)p).Value; });
            int y = y0 + 1, lh = h - 1;
            int hit = ui.List(ref objTop, 0, y, Cols, lh, n);
            if (hit >= 0)
            {
                int col = ui.In.Col, o = hit;
                if (col < 3) ToggleWatch(true, o);
                else if (col >= 25 && col <= 47 && s.Halted && s.Ddb != null)
                    Ask(new Picker("Move object " + o, Lists.Locations(s.Ddb)), (p, r) => { if (r == PopupResult.Ok) post(Command.Of(CommandKind.SetObjectLocation, o, ((Picker)p).Selected)); });
            }
            for (int r = 0; r < lh && objTop + r < n; r++)
            {
                int o = objTop + r, b = o * 6, loc = s.ObjTable[b], attr = s.ObjTable[b + 1];
                bool changed = s.ChangedBaseObj != null && s.ChangedBaseObj[b] != loc;
                bool watched = settings.Watches.Exists(w => w.IsObject && w.Number == o);
                string line = (watched ? " * " : " + ") + o.ToString().PadLeft(4) + " " + Fit(CondactFormatter.ObjectName(s.Ddb, o), 16) + " " + loc.ToString().PadLeft(4) + " " + Fit(CondactFormatter.LocationName(s.Ddb, loc), 18)
                    + " " + Ddb.Weight(attr).ToString().PadLeft(3) + " " + (Ddb.IsContainer(attr) ? "C" : "-") + " " + (Ddb.IsWearable(attr) ? "W" : "-") + " " + s.ObjTable[b + 2].ToString("X2") + s.ObjTable[b + 3].ToString("X2");
                ui.S.Text(0, y + r, line.PadRight(Cols), changed ? Theme.Changed : Theme.Text, Theme.Bg, Cols);
            }
        }

        static void ParserPane(Ui ui, Snapshot s, int y0)
        {
            var rowsSpec = new[] { Tuple.Create("Verb", 33, WordType.Verb), Tuple.Create("Noun1", 34, WordType.Noun), Tuple.Create("Adjective1", 35, WordType.Adjective), Tuple.Create("Adverb", 36, WordType.Adverb), Tuple.Create("Preposition", 43, WordType.Preposition), Tuple.Create("Noun2", 44, WordType.Noun), Tuple.Create("Adjective2", 45, WordType.Adjective) };
            for (int i = 0; i < rowsSpec.Length; i++)
            {
                var t = rowsSpec[i];
                int v = s.Flags[t.Item2];
                ui.S.Text(2, y0 + 1 + i, t.Item1.PadRight(14) + "flag " + t.Item2 + " = " + v.ToString().PadLeft(3) + "  " + CondactFormatter.Word(s.Ddb, v, t.Item3), Theme.Text, Theme.Bg);
            }
        }

        void DatabasePane(Ui ui, Snapshot s, int y0, int h)
        {
            int t = ui.Tabs(0, y0, DbTabs, dbTab);
            if (t != dbTab) { dbTab = t; dbTop = 0; }
            var list = DbRows(s.Ddb, dbTab);
            if (ui.Button(Cols - 10, y0, "Go to #")) Ask(new DigitPad("Go to row", dbTop, 0, Math.Max(0, list.Count - 1)), (p, r) => { if (r == PopupResult.Ok) dbTop = ((DigitPad)p).Value; });
            int y = y0 + 1;
            if (dbTab == 4)
            {
                char ch = ui.AzStrip(0, y);
                if (ch != '\0')
                {
                    int i = list.FindIndex(x => x.Length > 0 && char.ToUpperInvariant(x[0]) == ch);
                    if (i >= 0) dbTop = i;
                }
                y++;
            }
            int lh = y0 + h - y;
            ui.List(ref dbTop, 0, y, Cols, lh, list.Count);
            for (int r = 0; r < lh && dbTop + r < list.Count; r++) ui.S.Text(0, y + r, list[dbTop + r], Theme.Text, Theme.Bg, Cols);
        }

        List<string> DbRows(Ddb d, int tab)
        {
            if (d == rowsDdb && tab == rowsTab) return rows;
            rowsDdb = d;
            rowsTab = tab;
            rows = new List<string>();
            if (d == null) return rows;
            switch (tab)
            {
                case 0: for (int i = 0; i < d.NumMessages; i++) rows.Add(Num(i) + OneLine(d.Message(i))); break;
                case 1: for (int i = 0; i < d.NumSysMessages; i++) rows.Add(Num(i) + OneLine(d.SysMessage(i))); break;
                case 2: for (int i = 0; i < d.NumLocations; i++) rows.Add(Num(i) + OneLine(d.Location(i))); break;
                case 3:
                    for (int i = 0; i < d.NumObjects; i++)
                        rows.Add(Num(i) + OneLine(d.ObjectText(i)) + "  [" + CondactFormatter.Word(d, d.ObjectNoun(i), WordType.Noun) + " " + CondactFormatter.Word(d, d.ObjectAdjective(i), WordType.Adjective) + "]");
                    break;
                case 4:
                    foreach (var v in d.Vocabulary.OrderBy(v => v.Word, StringComparer.Ordinal)) rows.Add(v.Word.PadRight(6) + v.Number.ToString().PadLeft(4) + "  " + v.Type);
                    break;
                case 5: for (int i = 0; i < 128; i++) rows.Add(Num(i) + "'" + d.Token(i) + "'"); break;
                default:
                    for (int l = 0; l < d.NumLocations; l++)
                        rows.Add(Num(l) + string.Join(", ", d.Connections(l).Select(c => CondactFormatter.Word(d, c.Word, WordType.Verb) + " -> " + c.Destination)));
                    break;
            }
            return rows;
        }

        void BreakpointPane(Ui ui, Snapshot s, Action<Command> post, int y0, int h)
        {
            if (ui.Button(0, y0, "Add")) StartWizard(s, post);
            ui.S.Text(8, y0, "click [x] to enable/disable, del to remove; source lines: Source tab margin", Theme.Dim, Theme.Bg);
            int y = y0 + 1, lh = h - 1, n = s.Breakpoints.Length;
            int hit = ui.List(ref bpTop, 0, y, Cols, lh, n);
            if (hit >= 0)
            {
                var b = s.Breakpoints[hit];
                if (ui.In.Col < 4) post(Command.For(CommandKind.ToggleBreakpoint, b));
                else if (ui.In.Col >= Cols - 6) post(Command.For(CommandKind.RemoveBreakpoint, b));
            }
            for (int r = 0; r < lh && bpTop + r < n; r++)
            {
                var b = s.Breakpoints[bpTop + r];
                ui.S.Text(0, y + r, ((b.Enabled ? "[x] " : "[ ] ") + b.Describe(s.Ddb, s.Map)).PadRight(Cols - 6), b.Enabled ? Theme.Text : Theme.Dim, Theme.Bg, Cols - 6);
                ui.S.Text(Cols - 6, y + r, " del  ", Theme.Error, Theme.Bg);
            }
        }

        void StartWizard(Snapshot s, Action<Command> post)
        {
            var wz = new BreakpointWizard(s.Ddb, s.Map);
            Action<Popup, PopupResult> step = null;
            step = (p, r) =>
            {
                wz.Feed(r);
                if (wz.Current != null) Ask(wz.Current, step);
                else if (wz.Result != null) post(Command.For(CommandKind.AddBreakpoint, wz.Result));
            };
            Ask(wz.Current, step);
        }

        static string Num(int i) => i.ToString().PadLeft(4) + "  ";
        static string OneLine(string t) => t == null ? "" : t.Replace("\n", " | ");

        static string Fit(string s, int n)
        {
            s = s ?? "";
            return s.Length > n ? s.Substring(0, n) : s.PadRight(n);
        }
    }
}
