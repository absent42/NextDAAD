using System;
using System.Collections.Generic;
using System.IO;
using Xunit;

namespace NextDAADDebug.Tests
{
    static class UiDriver
    {
        public static Ui NewUi() => new Ui(new CellScreen(100, 40));
        public static UiInput At(int x, int y, bool click = true) => new UiInput { Col = x, Row = y, LeftClick = click, HasEvent = true };

        // Draw idle, find the text (rows fromRow-toRow), draw again clicking its middle;
        // returns the second draw's result.
        public static T Click<T>(Ui ui, Func<Ui, T> draw, string text, int fromRow = 0, int toRow = int.MaxValue)
        {
            ui.Begin(new UiInput());
            draw(ui);
            int x, y;
            Assert.True(ui.S.Find(text, out x, out y, fromRow, toRow), "not on screen: '" + text + "'");
            ui.Begin(At(x + text.Length / 2, y));
            return draw(ui);
        }
    }

    public class UiTests
    {
        static Ddb Fix() => new Ddb(File.ReadAllBytes(Repo.Fixture("DBGFIX.DDB")));

        [Fact]
        public void HeldButtonClicksOnce()
        {
            var m = new MouseTracker();
            Func<int, UiInput> f = b => m.Next(16, 16, b, 0, 100, 40, 8, 16);
            Assert.True(f(1).LeftClick);
            Assert.False(f(1).LeftClick);
            Assert.False(f(0).LeftClick);
            Assert.True(f(1).LeftClick);
            Assert.True(f(3).RightClick);
        }

        [Fact]
        public void OutsideMouseHitsNothing()
        {
            var m = new MouseTracker();
            var a = m.Next(-1, -1, 1, 0, 100, 40, 8, 16);
            Assert.Equal(-1, a.Col);
            Assert.False(a.LeftClick);
            var b = m.Next(900, 700, 0, 0, 100, 40, 8, 16);
            var c = m.Next(900, 700, 1, 0, 100, 40, 8, 16);
            Assert.False(c.LeftClick);
            var ui = UiDriver.NewUi();
            ui.Begin(c);
            Assert.False(ui.Button(0, 0, "Run"));
        }

        [Fact]
        public void WheelIsPerFrameSteps()
        {
            var d = new MouseTracker();
            Assert.Equal(1, d.Next(8, 8, 0, 3, 100, 40, 8, 16).Wheel);
            Assert.Equal(0, d.Next(8, 8, 0, 0, 100, 40, 8, 16).Wheel);
            Assert.Equal(-1, d.Next(8, 8, 0, -1, 100, 40, 8, 16).Wheel);
        }

        const float Off = -3.4028235e38f;      // ImGui MousePos when the window is not hovered

        [Fact]
        public void ImGuiMouseIsRelativeToImage()
        {
            var m = new ImGuiMouse();
            m.Sample(100.5f, 52f, 8f, 4f, false, false, 0);
            var u = m.Take(100, 40, 8, 16);
            Assert.Equal(11, u.Col);                 // (100.5 - 8) / 8
            Assert.Equal(3, u.Row);                  // (52 - 4) / 16
            m.Sample(7f, 3f, 8f, 4f, true, false, 0);
            u = m.Take(100, 40, 8, 16);
            Assert.Equal(-1, u.Col);                 // left of / above the image
            Assert.False(u.LeftClick);
            m.Sample(8f + 800f, 20f, 8f, 4f, true, false, 0);
            Assert.Equal(-1, m.Take(100, 40, 8, 16).Col);
        }

        [Fact]
        public void ImGuiMouseNotHoveredHitsNothing()
        {
            var m = new ImGuiMouse();
            m.Sample(Off, Off, 0, 0, true, true, 1);
            var u = m.Take(100, 40, 8, 16);
            Assert.Equal(-1, u.Col);
            Assert.Equal(-1, u.Row);
            Assert.False(u.LeftClick);
            Assert.False(u.RightClick);
            m.Sample(float.NaN, 10, 0, 0, false, false, 0);
            Assert.Equal(-1, m.Take(100, 40, 8, 16).Col);
        }

        [Fact]
        public void ImGuiButtonsAreEdges()
        {
            var m = new ImGuiMouse();
            Func<bool, bool, UiInput> f = (l, r) => { m.Sample(16, 16, 0, 0, l, r, 0); return m.Take(100, 40, 8, 16); };
            Assert.True(f(true, false).LeftClick);
            Assert.False(f(true, false).LeftClick);
            Assert.False(f(false, false).LeftClick);
            Assert.True(f(false, true).RightClick);
        }

        [Fact]
        public void ImGuiShortClickBetweenTicksIsKept()
        {
            var m = new ImGuiMouse();
            m.Sample(16, 16, 0, 0, false, false, 0);
            m.Take(100, 40, 8, 16);
            m.Sample(16, 16, 0, 0, true, false, 0);    // two draws in one OSTick: press then release
            m.Sample(16, 16, 0, 0, false, false, 0);
            Assert.True(m.Take(100, 40, 8, 16).LeftClick);
            m.Sample(16, 16, 0, 0, false, false, 0);
            m.Sample(16, 16, 0, 0, true, false, 0);
            Assert.True(m.Take(100, 40, 8, 16).LeftClick);
        }

        [Fact]
        public void ImGuiWheelAccumulatesAndUpIsPositive()
        {
            var m = new ImGuiMouse();
            m.Sample(16, 16, 0, 0, false, false, 1);
            m.Sample(16, 16, 0, 0, false, false, 1);
            var u = m.Take(100, 40, 8, 16);
            Assert.Equal(1, u.Wheel);
            Assert.True(u.HasEvent);
            Assert.Equal(0, m.Take(100, 40, 8, 16).Wheel);   // consumed
            m.Sample(16, 16, 0, 0, false, false, -1);
            Assert.Equal(-1, m.Take(100, 40, 8, 16).Wheel);
        }

        [Fact]
        public void ButtonClickAndBlocked()
        {
            var ui = UiDriver.NewUi();
            Assert.True(UiDriver.Click(ui, u => u.Button(5, 3, "Step"), "Step"));
            ui.Begin(UiDriver.At(6, 3));
            ui.Blocked = true;
            Assert.False(ui.Button(5, 3, "Step"));
            ui.Begin(UiDriver.At(6, 3));
            Assert.False(ui.Button(5, 3, "Step", false));
        }

        [Fact]
        public void ListScrollsAndClicks()
        {
            var ui = UiDriver.NewUi();
            int top = 0;
            ui.Begin(new UiInput { Col = 1, Row = 1, Wheel = -1, HasEvent = true });
            Assert.Equal(-1, ui.List(ref top, 0, 0, 10, 5, 20));
            Assert.Equal(3, top);
            ui.Begin(UiDriver.At(2, 2));
            Assert.Equal(5, ui.List(ref top, 0, 0, 10, 5, 20));
            top = 99;
            ui.Begin(new UiInput());
            ui.List(ref top, 0, 0, 10, 5, 20);
            Assert.Equal(15, top);
        }

        [Fact]
        public void TabsSwitch()
        {
            var ui = UiDriver.NewUi();
            var names = new[] { "Condacts", "Source" };
            Assert.Equal(1, UiDriver.Click(ui, u => u.Tabs(0, 0, names, 0), "Source"));
        }

        [Fact]
        public void DigitPadTypesAndClamps()
        {
            var ui = UiDriver.NewUi();
            var pad = new DigitPad("Value", 7, 0, 255);
            UiDriver.Click(ui, pad.Draw, " 4 ");
            Assert.Equal(4, pad.Value);                    // first digit replaces 7
            UiDriver.Click(ui, pad.Draw, " 2 ");
            Assert.Equal(42, pad.Value);
            UiDriver.Click(ui, pad.Draw, " 9 ");
            Assert.Equal(9, pad.Value);                    // 429 > 255 starts again
            UiDriver.Click(ui, pad.Draw, " +1 ");
            Assert.Equal(10, pad.Value);
            Assert.Equal(PopupResult.Ok, UiDriver.Click(ui, pad.Draw, " OK "));
            var p2 = new DigitPad("Value", 3, 0, 9);
            Assert.Equal(PopupResult.Cancel, UiDriver.Click(ui, p2.Draw, "Cancel"));
            ui.Begin(new UiInput { Col = 0, Row = 0, RightClick = true, HasEvent = true });
            Assert.Equal(PopupResult.Cancel, p2.Draw(ui));
        }

        [Fact]
        public void PickerJumpsAndSelects()
        {
            var ui = UiDriver.NewUi();
            var items = Lists.Words(Fix(), WordType.Noun, false);
            var pk = new Picker("Noun", items);
            UiDriver.Click(ui, pk.Draw, "L");              // first 'L' on screen is the A-Z strip
            int lamp = items.FindIndex(p => p.Label.StartsWith("LAMP"));
            Assert.True(pk.Top <= lamp && lamp < pk.Top + 24);   // short list: scroll clamps, LAMP stays visible
            Assert.Equal(PopupResult.Ok, UiDriver.Click(ui, pk.Draw, "LAMP  50"));
            Assert.Equal(50, pk.Selected);
        }

        [Fact]
        public void PickerJumpScrollsLongList()
        {
            var ui = UiDriver.NewUi();
            var items = new System.Collections.Generic.List<PickItem>();
            for (int i = 0; i < 60; i++) items.Add(new PickItem((i < 40 ? "A" : "L") + i, i));
            var pk = new Picker("Jump", items);
            UiDriver.Click(ui, pk.Draw, "L");
            Assert.Equal(36, pk.Top);                      // jump to item 40 clamped to count - 24
        }

        [Fact]
        public void WizardBuildsProcessBreakpoint()
        {
            var ui = UiDriver.NewUi();
            var wz = new BreakpointWizard(Fix(), null);
            foreach (string label in new[] { "Process / entry", "PRO 2", "GET  20", "LAMP  50" })
                wz.Feed(UiDriver.Click(ui, wz.Current.Draw, label));
            Assert.Null(wz.Current);
            Assert.Equal(BreakKind.Process, wz.Result.Kind);
            Assert.Equal(2, wz.Result.A);
            Assert.Equal(20, wz.Result.B);
            Assert.Equal(50, wz.Result.C);
        }

        [Fact]
        public void WizardBuildsFlagCompare()
        {
            var ui = UiDriver.NewUi();
            var wz = new BreakpointWizard(Fix(), null);
            foreach (string label in new[] { "Flag compare", "Dark", "<>", " 5 ", " OK " })
                wz.Feed(UiDriver.Click(ui, wz.Current.Draw, label));
            Assert.Equal(BreakKind.FlagCompare, wz.Result.Kind);
            Assert.Equal(0, wz.Result.A);
            Assert.Equal(CompareOp.Ne, wz.Result.Op);
            Assert.Equal(5, wz.Result.B);
        }

        [Fact]
        public void WizardCancel()
        {
            var ui = UiDriver.NewUi();
            var wz = new BreakpointWizard(Fix(), null);
            wz.Feed(UiDriver.Click(ui, wz.Current.Draw, "Cancel"));
            Assert.Null(wz.Current);
            Assert.Null(wz.Result);
        }

        [Fact]
        public void DigitPadAcceptsTypedNumberInRange()
        {
            var pad = new DigitPad("Value", 7, 0, 255);
            Assert.True(pad.Type(" 42 "));
            Assert.Equal(42, pad.Value);
            Assert.False(pad.Type("256"));
            Assert.False(pad.Type("-1"));
            Assert.False(pad.Type("4x"));
            Assert.False(pad.Type(""));
            Assert.Equal(42, pad.Value);
            var small = new DigitPad("Row", 3, 2, 9);
            Assert.False(small.Type("1"));
            Assert.True(small.Type("9"));
            Assert.Equal(9, small.Value);
        }

        [Fact]
        public void PickerAcceptsTypedPrefix()
        {
            var pk = new Picker("Noun", new List<PickItem> { new PickItem("  7  Lamp", 7), new PickItem(" 70  Box", 70), new PickItem("LAMP", 1), new PickItem("lantern", 2) });
            Assert.True(pk.Type("la"));
            Assert.Equal(1, pk.Selected);                // first label starting with the text, any case
            Assert.True(pk.Type("7"));
            Assert.Equal(7, pk.Selected);                // padded number labels match without the padding
            Assert.True(pk.Type("70"));
            Assert.Equal(70, pk.Selected);
            Assert.False(pk.Type("zz"));
            Assert.False(pk.Type("  "));
            Assert.Equal(70, pk.Selected);
        }

        [Fact]
        public void ListsLabels()
        {
            Assert.Equal("Verb", Lists.FlagLabel(33, null));
            Assert.Equal("", Lists.FlagLabel(100, null));
            Assert.Equal("GET", Lists.FlagHint(33, 20, Fix()));
            Assert.Equal(4 + 2, Lists.Locations(Fix()).Count);
            Assert.Equal(128, Lists.CondactNames().Count);
        }
    }
}
