using System;
using System.Collections.Generic;
using System.IO;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class ViewTests
    {
        static Snapshot Snap(bool halted = true)
        {
            var d = new Ddb(File.ReadAllBytes(Repo.Fixture("DBGFIX.DDB")));
            var map = SourceMap.Parse(File.ReadAllText(Repo.Fixture("DBGFIX.DSM")));
            var e = d.Entries(0)[0];
            var c = d.EntryCondacts(e.CondactOffset);
            var flags = new byte[256];
            flags[100] = 7; flags[7] = 3; flags[33] = 20; flags[34] = 50;
            var obj = new byte[256 * 6];
            obj[6] = 254;
            return new Snapshot
            {
                Serial = 1, Active = true, Halted = halted, Status = "HALTED - DEBUG marker",
                Stack = new[] { new ProcFrame(0, e.HeaderOffset, c[2].Offset) }, Offset = c[2].Offset,
                NumObjects = 2, Flags = flags, ObjTable = obj, Ddb = d, Map = map,
                Breakpoints = new[] { new Breakpoint { Kind = BreakKind.DebugMarker } },
            };
        }

        readonly List<Command> posted = new List<Command>();
        readonly DebuggerView view = new DebuggerView(Settings.Defaults(), null, Path.GetDirectoryName(Repo.Fixture("DBGFIX.DSF")));
        readonly Ui ui = UiDriver.NewUi();

        int Draw(Ui u, Snapshot s) { view.Draw(u, s, posted.Add); return 0; }
        void Click(Snapshot s, string text) => UiDriver.Click(ui, u => Draw(u, s), text);
        void Pad(Snapshot s, string text) => UiDriver.Click(ui, u => Draw(u, s), text, 14, 25);    // DigitPad box rows
        void Pick(Snapshot s, string text) => UiDriver.Click(ui, u => Draw(u, s), text, 5, 34);    // Picker box rows

        bool OnScreen(string text)
        {
            int x, y;
            return ui.S.Find(text, out x, out y);
        }

        [Fact]
        public void RendersToolbarStackAndCondacts()
        {
            var s = Snap();
            ui.Begin(new UiInput());
            Draw(ui, s);
            Assert.True(OnScreen("Run to PARSE"));
            Assert.True(OnScreen("HALTED - DEBUG marker"));
            Assert.True(OnScreen(">0 PRO 0 _ _"));
            Assert.True(OnScreen("LET 100 7"));
            Assert.True(OnScreen("LET @100(=7) 3"));
            Assert.True(OnScreen("PROCESS 1"));
        }

        [Fact]
        public void HotkeyHintShown()
        {
            ui.Begin(new UiInput());
            Draw(ui, Snap());
            Assert.True(OnScreen("Ctrl+Alt+A/B/N/R"));
        }

        [Fact]
        public void TypedNumberSetsFlag()
        {
            var s = Snap();
            Click(s, " Flags ");
            Assert.False(view.TypingWanted);
            Assert.False(view.Type("5"));
            int x, y;
            ui.Begin(new UiInput());
            Draw(ui, s);
            Assert.True(ui.S.Find(" +    7 ", out x, out y, 23, 40));
            ui.Begin(UiDriver.At(31, y));
            Draw(ui, s);
            Assert.True(view.TypingWanted);
            Assert.False(view.Type("300"));
            Assert.True(view.PopupOpen);
            Assert.True(view.Type("42"));
            Assert.False(view.PopupOpen);
            Assert.Contains(posted, c => c.Kind == CommandKind.SetFlag && c.A == 7 && c.B == 42);
        }

        [Fact]
        public void AcceptKeepsPadValue()
        {
            var s = Snap();
            Assert.False(view.Accept());
            Click(s, " Flags ");
            int x, y;
            ui.Begin(new UiInput());
            Draw(ui, s);
            Assert.True(ui.S.Find(" +    7 ", out x, out y, 23, 40));
            ui.Begin(UiDriver.At(31, y));
            Draw(ui, s);
            Assert.True(view.PopupOpen);
            Assert.True(view.Accept());
            Assert.False(view.PopupOpen);
            Assert.Contains(posted, c => c.Kind == CommandKind.SetFlag && c.A == 7 && c.B == 3);
            Assert.False(view.Accept());
        }

        [Fact]
        public void AcceptPickerNeedsSelection()
        {
            var s = Snap();
            Click(s, "Breakpoints");
            Click(s, " Add ");
            Assert.True(view.PopupOpen);
            Assert.False(view.Accept());
            Assert.True(view.PopupOpen);
        }

        [Fact]
        public void TypedPrefixPicksAndChainsWizard()
        {
            var s = Snap();
            Click(s, "Breakpoints");
            Click(s, " Add ");
            Assert.True(view.TypingWanted);
            Assert.True(view.Type("runtime"));
            Assert.Contains(posted, c => c.Kind == CommandKind.AddBreakpoint && c.Bp.Kind == BreakKind.RuntimeError);
            Click(s, " Add ");
            Assert.True(view.Type("flag c"));
            Assert.True(view.PopupOpen);                // wizard moved on to the flag picker
            view.CancelPopup();
            Assert.False(view.PopupOpen);
            Assert.False(view.TypingWanted);
        }

        [Fact]
        public void StepPostsCommand()
        {
            Click(Snap(), " Step ");
            Assert.Single(posted);
            Assert.Equal(CommandKind.Step, posted[0].Kind);
        }

        [Fact]
        public void RunningDisablesStep()
        {
            Click(Snap(false), " Step ");
            Assert.Empty(posted);
        }

        [Fact]
        public void SourceTabMarksCurrentLine()
        {
            var s = Snap();
            Click(s, " Source ");
            int x, y;
            Assert.True(ui.S.Find("        DEBUG", out x, out y));     // the DSF line, not the status line
            Assert.Equal(0x10, ui.S[29, y].Glyph);
        }

        [Fact]
        public void SourceTabNamesTheFileRightOfTheTabs()
        {
            Click(Snap(), " Source ");
            int x, y;
            Assert.True(ui.S.Find(" Source  DBGFIX.DSF", out x, out y));
            Assert.Equal(2, y);
            Assert.Equal(Theme.Dim, ui.S[48, 2].Fg);
            ui.Begin(new UiInput());
            Draw(ui, new Snapshot { MapProblem = MapSet.OutOfDateText });
            Assert.False(OnScreen("DBGFIX.DSF"));
        }

        [Fact]
        public void LongSourcePathKeepsItsFileName()
        {
            // 52 columns right of the tabs: a longer path loses its head, not the file name.
            string fit = "inc/" + new string('d', 37) + "/DBGFIX.DSF", wide = "x" + fit;
            Assert.Equal(52, fit.Length);
            Assert.Equal(fit, DebuggerView.FitPath(fit, 52));
            Assert.Equal("..." + wide.Substring(wide.Length - 49), DebuggerView.FitPath(wide, 52));
            var s = Snap();
            s.Map = SourceMap.Parse(File.ReadAllText(Repo.Fixture("DBGFIX.DSM")).Replace("\tDBGFIX.DSF", "\t" + wide));
            Click(s, " Source ");
            int x, y;
            Assert.True(ui.S.Find("..." + wide.Substring(wide.Length - 49), out x, out y));
            Assert.Equal(48, x);
            Assert.Equal(2, y);
            Assert.Equal((byte)'F', ui.S[99, 2].Glyph);
        }

        void ClickMargin(Snapshot s, int line)
        {
            ui.Begin(new UiInput());
            Draw(ui, s);
            int x, y;
            Assert.True(ui.S.Find(line.ToString().PadLeft(4) + " ", out x, out y, 3, 21));
            ui.Begin(UiDriver.At(28, y));
            Draw(ui, s);
        }

        [Fact]
        public void MarginClickAddsAndRemovesEveryRowOfTheLine()
        {
            var s = Snap();
            Click(s, " Source ");
            ClickMargin(s, 103);                                  // DEBUG
            Assert.Single(posted);
            Assert.Equal(CommandKind.AddBreakpoint, posted[0].Kind);
            Assert.Equal("DBGFIX.DSF", posted[0].Bp.Path);
            Assert.Equal(103, posted[0].Bp.B);
            posted.Clear();
            ClickMargin(s, 100);                                  // /PRO 0 compiles to nothing
            Assert.Empty(posted);
            s.Breakpoints = new[] {
                new Breakpoint { Kind = BreakKind.SourceLine, Path = "DBGFIX.DSF", B = 103 },
                new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 103 } };
            ClickMargin(s, 103);
            Assert.Equal(2, posted.Count);
            Assert.All(posted, c => Assert.Equal(CommandKind.RemoveBreakpoint, c.Kind));
            Assert.Same(s.Breakpoints[1], posted[1].Bp);
        }

        [Fact]
        public void SourceTabFollowsRunningEntryOnSharedTail()
        {
            // Offset 0x0402 is entry 1's first condact; the map also lists entry 0 as an owner, first.
            const string dsm = "NDRC-DSM\t2\nddb\tF27FE0F4\t459\nfile\t0\tDBGFIX.DSF\n" +
                               "cond\t0402\t0425\t0\t103\t9\ncond\t0402\t0429\t0\t106\t9\n";
            var s = Snap();
            var d = s.Ddb;
            var e = d.Entries(0)[1];
            s.Map = SourceMap.Parse(dsm);
            s.Stack = new[] { new ProcFrame(0, e.HeaderOffset, 0x402) };
            s.Offset = 0x402;
            Click(s, " Source ");
            int x, y;
            Assert.True(ui.S.Find("        SYSMESS 6", out x, out y));
            Assert.Equal(0x10, ui.S[29, y].Glyph);
            Assert.True(ui.S.Find("        DEBUG", out x, out y));
            Assert.NotEqual(0x10, ui.S[29, y].Glyph);
        }

        [Fact]
        public void SourceTabFollowsSelectedLowerLevelOnSharedTail()
        {
            // Level 0 (PRO 0 entry 0) sits on its PROCESS 1 at 0x03FF, which another entry also owns, listed first.
            var s = Snap();
            int h0 = s.Ddb.Entries(0)[0].HeaderOffset, h1 = s.Ddb.Entries(1)[0].HeaderOffset;
            string dsm = "NDRC-DSM\t2\nddb\tF27FE0F4\t459\nfile\t0\tDBGFIX.DSF\n" +
                         "cond\t03FF\t" + h1.ToString("X4") + "\t0\t107\t9\n" +
                         "cond\t03FF\t" + h0.ToString("X4") + "\t0\t104\t9\n" +
                         "cond\t040A\t" + h1.ToString("X4") + "\t0\t111\t9\n";
            s.Map = SourceMap.Parse(dsm);
            s.Stack = new[] { new ProcFrame(0, h0, 0x401), new ProcFrame(1, h1, 0x40A) };
            s.Offset = 0x40A;
            ui.Begin(new UiInput());
            Draw(ui, s);
            Click(s, " 0 PRO 0");                                  // select the lower level
            Click(s, " Source ");
            int x, y;
            Assert.True(ui.S.Find(" 104         PROCESS 1", out x, out y));
            Assert.Equal(0x10, ui.S[29, y].Glyph);
            Assert.True(ui.S.Find(" 107         REDO", out x, out y));
            Assert.NotEqual(0x10, ui.S[29, y].Glyph);
            Assert.True(ui.S.Find(" 111 > _ _   CLS", out x, out y));
            Assert.NotEqual(0x10, ui.S[29, y].Glyph);
        }

        [Fact]
        public void SourceTabSaysWhetherAMapWasLoaded()
        {
            var s = new Snapshot { MapProblem = DebugSession.MapUncheckedText };
            Click(s, " Source ");
            Assert.True(OnScreen("source map not checked yet - waiting for NextDAAD"));
            Assert.False(OnScreen("no source map"));
            ui.Begin(new UiInput());
            Draw(ui, new Snapshot { MapProblem = "no source map" });
            Assert.True(OnScreen("no source map"));
        }

        [Fact]
        public void EditFlagViaDigitPad()
        {
            var s = Snap();
            Click(s, " Flags ");
            Click(s, "Go to #");
            Pad(s, " 1 ");
            Pad(s, " 0 ");
            Pad(s, " 0 ");
            Pad(s, " OK ");
            int x, y;
            ui.Begin(new UiInput());
            Draw(ui, s);
            Assert.True(ui.S.Find(" 100 fCounter", out x, out y));
            ui.Begin(UiDriver.At(31, y));
            Draw(ui, s);
            Pad(s, " 4 ");
            Pad(s, " 2 ");
            Pad(s, " OK ");
            Assert.Contains(posted, c => c.Kind == CommandKind.SetFlag && c.A == 100 && c.B == 42);
        }

        [Fact]
        public void WizardAddsBreakpoint()
        {
            var s = Snap();
            Click(s, "Breakpoints");
            Click(s, " Add ");
            Pick(s, "Runtime error");
            Assert.Contains(posted, c => c.Kind == CommandKind.AddBreakpoint && c.Bp.Kind == BreakKind.RuntimeError);
        }

        [Fact]
        public void WaitingSnapshot()
        {
            ui.Begin(new UiInput());
            Draw(ui, new Snapshot());
            Assert.True(OnScreen("waiting for NextDAAD"));
        }

        [Fact]
        public void ProblemShownInErrorColour()
        {
            var s = new Snapshot { Problem = "symbol file does not match this interpreter build" };
            ui.Begin(new UiInput());
            Draw(ui, s);
            Assert.Equal(Theme.Error, ui.S[0, 1].Fg);
        }

        [Fact]
        public void DatabaseVocabTab()
        {
            var s = Snap();
            Click(s, "Database");
            Click(s, " Vocab ");
            Assert.True(OnScreen("LAMP"));
        }

        [Fact]
        public void ParserTabDecodesWords()
        {
            var s = Snap();
            Click(s, " Parser ");
            Assert.True(OnScreen("GET"));
            Assert.True(OnScreen("LAMP"));
        }

        [Fact]
        public void ClickOpeningPopupDoesNotActivateIt()
        {
            var s = Snap();
            Click(s, " Objects ");
            ui.Begin(UiDriver.At(30, 24));
            Draw(ui, s);
            Assert.True(view.PopupOpen);
            Assert.Empty(posted);
        }

        [Fact]
        public void SymbolButtonOpensWithoutPicking()
        {
            var settings = Settings.Defaults();
            var v = new DebuggerView(settings, null, ".");
            var s = Snap();
            var u = UiDriver.NewUi();
            u.Begin(UiDriver.At(25, 23));
            v.Draw(u, s, c => { });
            Assert.True(v.PopupOpen);
            Assert.Empty(settings.Watches);
        }

        [Fact]
        public void SaveBeforeDrawWritesNothing()
        {
            string path = Path.Combine(Path.GetTempPath(), "nodraw-" + Guid.NewGuid() + ".txt");
            new DebuggerView(Settings.Defaults(), path, ".").SaveIfChanged();
            Assert.False(File.Exists(path));
        }

        [Fact]
        public void OutOfRangeWatchesDoNotThrow()
        {
            var settings = Settings.Defaults();
            settings.Watches.Add(new Watch { Number = 300 });
            settings.Watches.Add(new Watch { IsObject = true, Number = -1 });
            var v = new DebuggerView(settings, null, ".");
            var u = UiDriver.NewUi();
            u.Begin(new UiInput());
            v.Draw(u, Snap(), c => { });
        }

        [Fact]
        public void WheelOverFlagValueAdjusts()
        {
            var s = Snap();
            Click(s, " Flags ");
            int x, y;
            Click(s, "Go to #");
            Pad(s, " 1 "); Pad(s, " 0 "); Pad(s, " 0 "); Pad(s, " OK ");
            ui.Begin(new UiInput());
            Draw(ui, s);
            Assert.True(ui.S.Find(" 100 fCounter", out x, out y));
            ui.Begin(new UiInput { Col = 31, Row = y, Wheel = 1, HasEvent = true });
            Draw(ui, s);
            Assert.Contains(posted, c => c.Kind == CommandKind.SetFlag && c.A == 100 && c.B == 8);
            ui.Begin(new UiInput());
            Draw(ui, s);
            Assert.True(OnScreen(" 100 fCounter"));       // list did not scroll
        }

        [Fact]
        public void SavesSettingsWhenChanged()
        {
            string path = Path.GetTempFileName();
            var settings = Settings.Defaults();
            var v = new DebuggerView(settings, path, ".");
            var u = UiDriver.NewUi();
            u.Begin(new UiInput());
            v.Draw(u, Snap(), c => { });
            Assert.Contains("bp\tDebugMarker", File.ReadAllText(path));
        }
    }
}
