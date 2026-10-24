using System;
using Xunit;

namespace NextDAADDebug.Tests
{
    public interface IWin34 { void Close(); }
    public interface ICs34 { IWin34 OpenWindow(string title, int w, int h); }
    public interface IWin40 { bool SetImGuiDraw(Action draw); }
    public interface ICs40 { IWin40 OpenWindow(string title, int w, int h); }

    public class WindowHostTests
    {
        [Fact]
        public void GateNeedsOpenWindowAndSetImGuiDraw()
        {
            Assert.False(VersionGate.WindowSupported(typeof(IDisposable)));
            Assert.False(VersionGate.WindowSupported(typeof(ICs34)));
            Assert.True(VersionGate.WindowSupported(typeof(ICs40)));
            Assert.True(VersionGate.WindowSupported(typeof(Plugin.iCSpect)));    // the referenced CSpect 4.0 Plugin.dll
        }

        sealed class FakeSurface : ISurface
        {
            public int Closes, Presents;
            public bool IsClosed;
            public int X { get; set; }
            public int Y { get; set; }
            public bool Closed => IsClosed;
            public void Present(uint[] pixels) { Presents++; }
            public void Close() { Closes++; IsClosed = true; }
        }

        // Cell centre in window pixels, image at (0,0).
        static void ClickCell(WindowHost h, int col, int row)
        {
            h.Sample(col * 8 + 4, row * 16 + 8, 0, 0, true, false, 0);
            h.Sample(col * 8 + 4, row * 16 + 8, 0, 0, false, false, 0);
        }

        [Fact]
        public void PresentsOnlyOnInputOrNewSnapshot()
        {
            var surf = new FakeSurface();
            var host = new WindowHost(() => surf, Settings.Defaults(), null, ".");
            var snap = new Snapshot { Serial = 1 };
            host.Frame(snap, c => { });
            host.Frame(snap, c => { });
            Assert.Equal(1, surf.Presents);
            host.Sample(-3.4028235e38f, -3.4028235e38f, 0, 0, false, false, 0);
            host.Frame(snap, c => { });
            Assert.Equal(1, surf.Presents);                 // still outside: no event
            host.Sample(40, 40, 0, 0, false, false, 0);
            host.Frame(snap, c => { });
            Assert.Equal(2, surf.Presents);
            host.Frame(new Snapshot { Serial = 2 }, c => { });
            Assert.Equal(3, surf.Presents);
        }

        [Fact]
        public void TypedTextReachesOpenPicker()
        {
            var surf = new FakeSurface();
            var posted = new System.Collections.Generic.List<Command>();
            var host = new WindowHost(() => surf, Settings.Defaults(), null, ".");
            var snap = new Snapshot { Serial = 1, Active = true };
            host.Frame(snap, posted.Add);
            ClickCell(host, 50, 22);                        // Breakpoints tab
            host.Frame(snap, posted.Add);
            Assert.False(host.TypingWanted);
            ClickCell(host, 2, 23);                         // Add
            host.Frame(snap, posted.Add);
            Assert.True(host.TypingWanted);
            host.QueueTyped("nothing like this");
            host.Frame(snap, posted.Add);
            Assert.True(host.TypingWanted);
            Assert.NotNull(host.TypedNote);
            host.TypedText = "runtime";
            host.QueueTyped("runtime");
            host.Frame(snap, posted.Add);
            Assert.False(host.TypingWanted);
            Assert.Equal("", host.TypedText);
            Assert.Contains(posted, c => c.Kind == CommandKind.AddBreakpoint && c.Bp.Kind == BreakKind.RuntimeError);
        }

        [Fact]
        public void EscapeCancelsPopup()
        {
            var surf = new FakeSurface();
            var posted = new System.Collections.Generic.List<Command>();
            var host = new WindowHost(() => surf, Settings.Defaults(), null, ".");
            var snap = new Snapshot { Serial = 1, Active = true };
            host.Frame(snap, posted.Add);
            ClickCell(host, 50, 22);
            host.Frame(snap, posted.Add);
            ClickCell(host, 2, 23);
            host.Frame(snap, posted.Add);
            Assert.True(host.TypingWanted);
            host.QueueCancel();
            host.Frame(snap, posted.Add);
            Assert.False(host.TypingWanted);
            Assert.Empty(posted);
        }

        [Fact]
        public void DrawFailureDisablesWindow()
        {
            var surf = new FakeSurface();
            var host = new WindowHost(() => surf, Settings.Defaults(), null, ".");
            host.Frame(new Snapshot(), c => { });
            host.DrawFailed(new Exception("boom"));
            Assert.Throws<InvalidOperationException>(() => host.Frame(new Snapshot(), c => { }));
        }

        [Fact]
        public void ToggleOnlyActsInFrame()
        {
            var surf = new FakeSurface();
            int opens = 0;
            var host = new WindowHost(() => { opens++; return surf; }, Settings.Defaults(), null, ".");
            var snap = new Snapshot();
            host.Frame(snap, c => { });
            Assert.Equal(1, opens);
            host.Toggle();
            Assert.Equal(0, surf.Closes);
            host.Frame(snap, c => { });
            Assert.Equal(1, surf.Closes);
            host.Frame(snap, c => { });
            Assert.Equal(1, opens);
            host.Toggle();
            host.Frame(snap, c => { });
            Assert.Equal(2, opens);
        }

        [Fact]
        public void ToggleIgnoredWhenCloseCannotWork()
        {
            var surf = new FakeSurface();
            int opens = 0;
            var host = new WindowHost(() => { opens++; return surf; }, Settings.Defaults(), null, ".", false);
            var snap = new Snapshot();
            host.Frame(snap, c => { });
            host.Toggle();
            host.Frame(snap, c => { });
            host.Toggle();
            host.Frame(snap, c => { });
            Assert.Equal(1, opens);
            Assert.Equal(0, surf.Closes);
        }
    }
}
