using System;
using System.Collections.Generic;
using System.IO;
using NextDAADDebug.Autopilot;
using Xunit;

namespace NextDAADDebug.Tests
{
    sealed class FakeAutopilotHost : IAutopilotHost
    {
        public CellScreen Screen { get; set; } = new CellScreen(40, 10);
        public string Status { get; set; } = "";
        public string[] Game = { "" };
        public bool GameThrows;
        public string Log = "";
        public readonly List<UiInput> Injected = new List<UiInput>();
        public readonly List<string> Calls = new List<string>();
        public KeyFeeder Keys { get; } = new KeyFeeder(1, 1);
        public int State;
        public int TicksWhileHalted { get; set; }
        public int CurrentOffset { get; set; }

        public string[] GameRows()
        {
            if (GameThrows) throw new InvalidOperationException("tmCols is 0");
            return Game;
        }

        public string LogText() => Log;
        public void Inject(UiInput input) => Injected.Add(input);
        public bool PopupOpen = true;
        public Action<char> OnHotkey;
        public bool Type(string text) { Calls.Add("Type:" + text); return PopupOpen; }
        public bool Accept() { Calls.Add("Accept"); return PopupOpen; }
        public bool Cancel() { Calls.Add("Cancel"); return PopupOpen; }
        public void Hotkey(char k) { Calls.Add("Hotkey:" + k); OnHotkey?.Invoke(k); }
        public int DebuggerState() => State;
        public void Quit() => Calls.Add("Quit");
    }

    public class EngineTests : IDisposable
    {
        readonly string dir = Path.Combine(Path.GetTempPath(), "ndap-" + Guid.NewGuid().ToString("N"));
        readonly FakeAutopilotHost host = new FakeAutopilotHost();
        double now;

        public void Dispose()
        {
            try { Directory.Delete(dir, true); } catch (IOException) { }
        }

        Engine Make(string script) =>
            new Engine(ScriptParser.Parse(script), host, new ResultWriter(dir), () => now);

        string[] Lines() => File.ReadAllLines(Path.Combine(dir, "autopilot-result.txt"));

        static void Run(Engine e, int frames = 20)
        {
            for (int i = 0; i < frames && !e.Finished; i++) e.Frame();
        }

        [Fact]
        public void Engine_WaitScreenPassesWhenTextAppears()
        {
            var e = Make("wait screen \"Hall.\"");
            e.Frame();
            e.Frame();
            Assert.False(e.Finished);
            host.Screen.Text(3, 2, "Hall.", Theme.Text, Theme.Bg);
            e.Frame();
            Assert.True(e.Finished);
            Assert.Equal(0, e.Failures);
            Assert.StartsWith("STEP 1 PASS line 1 |", Lines()[0]);
        }

        [Fact]
        public void Engine_WaitTimeoutAbortsLeg()
        {
            var e = Make("wait status \"HALTED\" timeout 5\ntype \"x\"\nexpect screen \"y\"");
            e.Frame();
            now = 4.9;
            e.Frame();
            Assert.False(e.Finished);
            now = 5.0;
            e.Frame();
            Assert.True(e.Finished);
            Assert.Equal(1, e.Failures);
            var l = Lines();
            Assert.StartsWith("STEP 1 FAIL line 1 |", l[0]);
            Assert.StartsWith("STEP 2 SKIPPED line 2 |", l[1]);
            Assert.StartsWith("STEP 3 SKIPPED line 3 |", l[2]);
            Assert.Equal("DONE failures=1", l[l.Length - 1]);
            Assert.DoesNotContain("Type:x", host.Calls);
        }

        [Fact]
        public void Engine_ExpectFailureContinues()
        {
            host.Status = "RUNNING";
            var e = Make("expect status \"HALTED\"\nexpect status \"RUN\"");
            Run(e);
            Assert.True(e.Finished);
            Assert.Equal(1, e.Failures);
            var l = Lines();
            Assert.StartsWith("STEP 1 FAIL", l[0]);
            Assert.Contains("actual RUNNING", l[0]);
            Assert.StartsWith("STEP 2 PASS", l[1]);
        }

        [Fact]
        public void Engine_ExpectNot()
        {
            host.Screen.Text(0, 0, "Error 3", Theme.Error, Theme.Bg);
            var e = Make("expect screen not \"Error\"\nexpect screen not \"Fine\"");
            Run(e);
            Assert.Equal(1, e.Failures);
            var l = Lines();
            Assert.StartsWith("STEP 1 FAIL", l[0]);
            Assert.StartsWith("STEP 2 PASS", l[1]);
        }

        [Fact]
        public void Engine_ClickMissingTextFails()
        {
            var e = Make("click \" Step \"");
            Run(e);
            Assert.True(e.Finished);
            Assert.Equal(1, e.Failures);
            Assert.Empty(host.Injected);
            Assert.True(File.Exists(Path.Combine(dir, "dumps", "001.txt")));
        }

        [Fact]
        public void Engine_ClickFirstMatchInRange()
        {
            host.Screen.Text(2, 1, "[Go]", Theme.Button, Theme.Bg);
            host.Screen.Text(10, 6, "[Go]", Theme.Button, Theme.Bg);
            var e = Make("click \"[Go]\" rows 5-9");
            Run(e);
            Assert.Equal(0, e.Failures);
            var press = host.Injected.Find(u => u.LeftClick);
            Assert.NotNull(press);
            Assert.Equal(12, press.Col);
            Assert.Equal(6, press.Row);
        }

        [Fact]
        public void Engine_ClickProducesPressThenRelease()
        {
            host.Screen.Text(4, 3, " Step ", Theme.Button, Theme.Bg);
            var e = Make("click \" Step \"");
            e.Frame();
            Assert.Single(host.Injected);
            e.Frame();
            Assert.False(e.Finished);
            e.Frame();
            Assert.True(e.Finished);
            Assert.Equal(3, host.Injected.Count);
            UiInput a = host.Injected[0], b = host.Injected[1], c = host.Injected[2];
            Assert.True(a.HasEvent && !a.LeftClick && a.Col == 7 && a.Row == 3);
            Assert.True(b.HasEvent && b.LeftClick && b.Col == 7 && b.Row == 3);
            Assert.True(!c.LeftClick && c.Col == 7 && c.Row == 3);
            Assert.Equal(0, e.Failures);
        }

        [Fact]
        public void Engine_TypeAndKeys()
        {
            var e = Make("type \"GET LAMP\"\nkey esc\nkey enter\nhotkey n");
            Run(e);
            Assert.Equal(new[] { "Type:GET LAMP", "Cancel", "Accept", "Hotkey:n" }, host.Calls.ToArray());
            Assert.Equal(0, e.Failures);
        }

        [Fact]
        public void Engine_PopupRefusalsFail()
        {
            host.PopupOpen = false;
            var e = Make("type \"12\"\nkey enter\nkey esc");
            Run(e);
            Assert.Equal(3, e.Failures);
            var l = Lines();
            Assert.Contains("actual not accepted: 12", l[0]);
            Assert.Contains("actual nothing to accept", l[1]);
            Assert.Contains("actual no popup open", l[2]);
        }

        [Fact]
        public void Engine_StepAdvancesYes()
        {
            host.State = 1;
            host.CurrentOffset = 10;
            host.OnHotkey = k => { host.CurrentOffset = 14; host.State = 1; };
            var e = Make("measure step-advances");
            Run(e);
            Assert.Equal(0, e.Failures);
            Assert.Contains("FACT step-advances=yes 10->14 halted=1->1", Lines());
        }

        [Fact]
        public void Engine_StepAdvancesNo()
        {
            host.State = 1;
            host.CurrentOffset = 10;
            host.OnHotkey = k => host.State = 0;
            var e = Make("measure step-advances");
            e.Frame();
            e.Frame();
            Assert.False(e.Finished);
            now = 2;
            e.Frame();
            Assert.True(e.Finished);
            Assert.Equal(0, e.Failures);
            Assert.Contains("FACT step-advances=no 10 halted=1->0", Lines());
        }

        [Fact]
        public void Engine_StepAdvancesNotHalted()
        {
            host.State = 0;
            var e = Make("measure step-advances");
            Run(e);
            Assert.Equal(0, e.Failures);
            Assert.DoesNotContain("Hotkey:n", host.Calls);
            Assert.Contains("FACT step-advances=not halted", Lines());
        }

        [Fact]
        public void Engine_DumpLineNamesDump()
        {
            var e = Make("dump before-click");
            Run(e);
            Assert.Contains("actual dump before-click 001", Lines()[0]);
        }

        [Fact]
        public void Engine_GameWaitsForFeeder()
        {
            var e = Make("game \"LOOK\\n\"");
            e.Frame();
            Assert.True(host.Keys.Busy);
            e.Frame();
            Assert.False(e.Finished);
            for (int i = 0; i < 40 && host.Keys.Busy; i++) host.Keys.Frame();
            Assert.False(host.Keys.Busy);
            e.Frame();
            Assert.True(e.Finished);
            Assert.Equal(0, e.Failures);
        }

        [Fact]
        public void Engine_ExpectColour()
        {
            host.Screen.Text(0, 4, "flag 5", Theme.Changed, Theme.Bg);
            host.Screen.Text(0, 5, "flag 6", Theme.Text, Theme.Bg);
            var e = Make("expect colour \"flag 5\" Changed\nexpect colour \"flag 6\" Changed\nexpect colour \"flag 6\" Purple");
            Run(e);
            Assert.Equal(2, e.Failures);
            var l = Lines();
            Assert.StartsWith("STEP 1 PASS", l[0]);
            Assert.StartsWith("STEP 2 FAIL", l[1]);
            Assert.Contains("Text", l[1]);
            Assert.StartsWith("STEP 3 FAIL", l[2]);
            Assert.Contains("unknown theme colour", l[2]);
        }

        [Fact]
        public void Engine_MeasureWritesFactNotFailure()
        {
            host.State = 2;
            host.TicksWhileHalted = 17;
            var e = Make("measure halted-state\nmeasure ticks-while-halted");
            Run(e);
            Assert.Equal(0, e.Failures);
            var l = Lines();
            Assert.Contains("FACT halted-state=2", l);
            Assert.Contains("FACT ticks-while-halted=17", l);
            Assert.Equal("DONE failures=0", l[l.Length - 1]);
        }

        [Fact]
        public void Engine_QuitCallsHostAfterFinish()
        {
            var e = Make("note \"hi\"\nquit");
            Run(e);
            Assert.True(e.Finished);
            Assert.Equal("Quit", host.Calls[host.Calls.Count - 1]);
            Assert.Equal("DONE failures=0", Lines()[Lines().Length - 1]);
        }

        [Fact]
        public void Engine_UnreadableGameNeverThrows()
        {
            host.GameThrows = true;
            var e = Make("expect game \"x\"\nwait game \">\" timeout 1");
            e.Frame();
            e.Frame();
            Assert.False(e.Finished);
            now = 1;
            e.Frame();
            Assert.True(e.Finished);
            Assert.Equal(2, e.Failures);
            Assert.Contains("(game screen not readable)", Lines()[0]);
        }

        [Fact]
        public void ResultWriter_FormatsLines()
        {
            var w = new ResultWriter(dir);
            var s = ScriptParser.Parse("wait status \"HALTED\"\n\nexpect game \"GET\"");
            w.Result(s[0], "PASS", "status contains \"HALTED\"", "HALTED - step");
            w.Result(s[1], "FAIL", "game contains \"GET\"", "a\nb");
            w.Fact("halted-state", "1");
            var screen = new CellScreen(4, 2);
            screen.Clear(Theme.Bg);
            screen.Text(0, 1, "ab", Theme.Text, Theme.Bg);
            w.Dump(2, screen, new[] { "Hall." });
            w.Finish(1);
            Assert.Equal(new[]
            {
                "STEP 1 PASS line 1 | wait status \"HALTED\" | expected status contains \"HALTED\" | actual HALTED - step",
                "STEP 2 FAIL line 3 | expect game \"GET\" | expected game contains \"GET\" | actual a\\nb",
                "FACT halted-state=1",
                "DONE failures=1",
            }, Lines());
            Assert.Equal(new[] { "", "ab", "", "Hall." }, File.ReadAllLines(Path.Combine(dir, "dumps", "002.txt")));
        }
    }
}
