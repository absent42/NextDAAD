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
