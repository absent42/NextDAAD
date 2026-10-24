using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace NextDAADDebug.Autopilot
{
    public enum StepKind
    {
        WaitStatus, WaitScreen, WaitGame, ExpectStatus, ExpectScreen, ExpectGame, ExpectLog, ExpectColour,
        Click, ClickCell, Wheel, Type, Key, Hotkey, Game, Dump, Note, Measure, Quit
    }

    public sealed class Step
    {
        public int Line;
        public StepKind Kind;
        public string Text;
        public bool Not;
        public int Timeout = 10;
        public int Col, Row, FromRow = 0, ToRow = 39;
        public int Amount;
        public string Theme;   // expect colour: theme colour name
        public string Raw;
    }

    // One command per line; '#' comments; "quoted text" with \" \\ \n escapes.
    public static class ScriptParser
    {
        static readonly string[] Measures = { "halted-state", "ticks-while-halted", "step-advances" };

        public static List<Step> Parse(string text)
        {
            var steps = new List<Step>();
            string[] lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            for (int i = 0; i < lines.Length; i++)
            {
                List<string> t;
                try { t = Tokenize(lines[i]); }
                catch (FormatException e) { throw new FormatException("line " + (i + 1) + ": " + e.Message); }
                if (t.Count == 0) continue;
                var s = new Step { Line = i + 1, Raw = lines[i].Trim() };
                try { Build(s, t); }
                catch (FormatException e) { throw new FormatException("line " + s.Line + ": " + e.Message); }
                steps.Add(s);
            }
            return steps;
        }

        // Quoted tokens keep a leading '"' marker so they can be told from bare words.
        static List<string> Tokenize(string line)
        {
            var r = new List<string>();
            int i = 0;
            while (i < line.Length)
            {
                char c = line[i];
                if (char.IsWhiteSpace(c)) { i++; continue; }
                if (c == '#') break;
                if (c == '"')
                {
                    var sb = new StringBuilder("\"");
                    i++;
                    bool closed = false;
                    while (i < line.Length)
                    {
                        c = line[i++];
                        if (c == '"') { closed = true; break; }
                        if (c == '\\' && i < line.Length)
                        {
                            char e = line[i++];
                            sb.Append(e == 'n' ? '\n' : e);
                        }
                        else sb.Append(c);
                    }
                    if (!closed) throw new FormatException("unterminated quote");
                    r.Add(sb.ToString());
                }
                else
                {
                    int j = i;
                    while (j < line.Length && !char.IsWhiteSpace(line[j])) j++;
                    r.Add(line.Substring(i, j - i));
                    i = j;
                }
            }
            return r;
        }

        static bool Quoted(string tok) => tok.Length > 0 && tok[0] == '"';
        static string Unq(string tok) => tok.Substring(1);

        static string NeedText(List<string> t, int i, string what)
        {
            if (i >= t.Count || !Quoted(t[i])) throw new FormatException("expected quoted " + what);
            return Unq(t[i]);
        }

        static int NeedInt(List<string> t, int i, string what)
        {
            int v;
            if (i >= t.Count || !int.TryParse(t[i], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out v))
                throw new FormatException("expected number for " + what);
            return v;
        }

        static void Cell(string tok, Step s)
        {
            string[] p = tok.Length > 1 && tok[0] == '@' ? tok.Substring(1).Split(',') : null;
            int c, r;
            if (p == null || p.Length != 2 || !int.TryParse(p[0], out c) || !int.TryParse(p[1], out r))
                throw new FormatException("expected @col,row");
            s.Col = c;
            s.Row = r;
        }

        static void NoMore(List<string> t, int n)
        {
            if (t.Count > n) throw new FormatException("unexpected '" + t[n].TrimStart('"') + "'");
        }

        static void Build(Step s, List<string> t)
        {
            string cmd = t[0];
            switch (cmd)
            {
                case "wait":
                {
                    s.Kind = Source(t, 1, StepKind.WaitStatus, StepKind.WaitScreen, StepKind.WaitGame, false);
                    s.Text = NeedText(t, 2, "text");
                    if (t.Count > 3)
                    {
                        if (t[3] != "timeout") throw new FormatException("expected 'timeout N'");
                        s.Timeout = NeedInt(t, 4, "timeout");
                        NoMore(t, 5);
                    }
                    break;
                }
                case "expect":
                {
                    s.Kind = Source(t, 1, StepKind.ExpectStatus, StepKind.ExpectScreen, StepKind.ExpectGame, true);
                    int i = 2;
                    if (s.Kind == StepKind.ExpectColour)
                    {
                        s.Text = NeedText(t, i, "text");
                        if (t.Count != 4) throw new FormatException("expected a theme colour name");
                        s.Theme = t[3];
                        break;
                    }
                    if (i < t.Count && t[i] == "not") { s.Not = true; i++; }
                    s.Text = NeedText(t, i, "text");
                    NoMore(t, i + 1);
                    break;
                }
                case "click":
                {
                    if (t.Count > 1 && !Quoted(t[1]))
                    {
                        s.Kind = StepKind.ClickCell;
                        Cell(t[1], s);
                        NoMore(t, 2);
                        break;
                    }
                    s.Kind = StepKind.Click;
                    s.Text = NeedText(t, 1, "text");
                    if (t.Count > 2)
                    {
                        if (t[2] != "rows" || t.Count != 4) throw new FormatException("expected 'rows A-B'");
                        string[] ab = t[3].Split('-');
                        int a, b;
                        if (ab.Length != 2 || !int.TryParse(ab[0], out a) || !int.TryParse(ab[1], out b) || a > b)
                            throw new FormatException("bad row range");
                        s.FromRow = a;
                        s.ToRow = b;
                    }
                    break;
                }
                case "wheel":
                    s.Kind = StepKind.Wheel;
                    s.Amount = NeedInt(t, 1, "wheel amount");
                    if (t.Count < 4 || t[2] != "at") throw new FormatException("expected 'at \"text\"' or 'at @col,row'");
                    if (Quoted(t[3])) s.Text = Unq(t[3]); else Cell(t[3], s);
                    NoMore(t, 4);
                    break;
                case "type":
                    s.Kind = StepKind.Type;
                    s.Text = NeedText(t, 1, "text");
                    NoMore(t, 2);
                    break;
                case "key":
                    s.Kind = StepKind.Key;
                    s.Text = OneOf(t, "enter", "esc");
                    break;
                case "hotkey":
                    s.Kind = StepKind.Hotkey;
                    s.Text = OneOf(t, "a", "b", "n", "r");
                    break;
                case "game":
                    s.Kind = StepKind.Game;
                    s.Text = NeedText(t, 1, "text");
                    NoMore(t, 2);
                    break;
                case "dump":
                    s.Kind = StepKind.Dump;
                    if (t.Count != 2 || Quoted(t[1])) throw new FormatException("expected a dump name");
                    s.Text = t[1];
                    break;
                case "note":
                    s.Kind = StepKind.Note;
                    s.Text = NeedText(t, 1, "text");
                    NoMore(t, 2);
                    break;
                case "measure":
                    s.Kind = StepKind.Measure;
                    s.Text = OneOf(t, Measures);
                    break;
                case "quit":
                    s.Kind = StepKind.Quit;
                    NoMore(t, 1);
                    break;
                default:
                    throw new FormatException("unknown command '" + cmd + "'");
            }
        }

        static string OneOf(List<string> t, params string[] allowed)
        {
            if (t.Count != 2 || Array.IndexOf(allowed, t[1]) < 0)
                throw new FormatException("expected one of " + string.Join("|", allowed));
            return t[1];
        }

        static StepKind Source(List<string> t, int i, StepKind status, StepKind screen, StepKind game, bool allowLog)
        {
            string w = i < t.Count ? t[i] : "";
            if (w == "status") return status;
            if (w == "screen") return screen;
            if (w == "game") return game;
            if (allowLog && w == "log") return StepKind.ExpectLog;
            if (allowLog && w == "colour") return StepKind.ExpectColour;
            throw new FormatException("expected " + (allowLog ? "status|screen|game|log|colour" : "status|screen|game"));
        }
    }
}
