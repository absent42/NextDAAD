using System;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class WindowHostTests
    {
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
