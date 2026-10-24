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
            public int Closes;
            public bool IsClosed;
            public int MouseX => -1;
            public int MouseY => -1;
            public int Buttons => 0;
            public int Wheel => 0;
            public int X { get; set; }
            public int Y { get; set; }
            public bool Closed => IsClosed;
            public bool InputSupported => false;
            public bool PositionSupported => false;
            public void ResetWheel() { }
            public void Blit(uint[] pixels) { }
            public void Close() { Closes++; IsClosed = true; }
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
