using Xunit;

namespace NextDAADDebug.Tests
{
    public class MouseGuardTests
    {
        const int B = MouseGuard.PortButtons, X = MouseGuard.PortX, Y = MouseGuard.PortY;

        static bool Answer(MouseGuard g, int port, out byte v) => g.TryAnswer(port, out v);

        static void AssertPass(MouseGuard g)
        {
            byte v;
            Assert.False(Answer(g, B, out v));
            Assert.False(Answer(g, X, out v));
            Assert.False(Answer(g, Y, out v));
        }

        static void AssertIdle(MouseGuard g, byte buttons, byte x, byte y)
        {
            byte v;
            Assert.True(Answer(g, B, out v)); Assert.Equal(buttons, v);
            Assert.True(Answer(g, X, out v)); Assert.Equal(x, v);
            Assert.True(Answer(g, Y, out v)); Assert.Equal(y, v);
        }

        [Fact]
        public void IdleGuardPassesThrough()
        {
            var g = new MouseGuard();
            g.PassThrough(0xF7, 10, 20);
            g.Sample(false, false);
            AssertPass(g);
        }

        [Fact]
        public void PressOverWindowAnswersIdleUntilRelease()
        {
            var g = new MouseGuard();
            g.PassThrough(0x37, 10, 20);            // wheel 3, bit 3 clear, no buttons
            g.Sample(true, false);                  // hover: buttons idle, X/Y still live
            byte v;
            Assert.True(g.Armed);
            Assert.True(Answer(g, B, out v)); Assert.Equal(0x37, v);
            Assert.False(Answer(g, X, out v));
            g.Sample(true, true);                   // press
            Assert.True(g.Owning);
            g.PassThrough(0x35, 90, 200);           // CSpect sees the left button and the drag
            AssertIdle(g, 0x37, 10, 20);
            g.Sample(false, true);                  // still held, pointer left the window
            g.PassThrough(0x35, 120, 210);
            AssertIdle(g, 0x37, 10, 20);
            g.Sample(false, false);                 // host release
            Assert.True(g.Owning);
            g.PassThrough(0x37, 120, 210);          // CSpect's buttons up
            Assert.False(g.Owning);
            AssertPass(g);
        }

        [Fact]
        public void ReleaseHoldsIdleUntilCSpectShowsUp()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);
            g.PassThrough(0xFD, 1, 2);              // CSpect shows the press
            g.Sample(true, false);                  // host release seen by the window first
            AssertIdle(g, 0xFF, 1, 2);
            g.PassThrough(0xFD, 5, 6);              // CSpect still shows it down
            AssertIdle(g, 0xFF, 1, 2);
            g.PassThrough(0xFF, 5, 6);
            Assert.False(g.Owning);
            byte v;
            Assert.False(Answer(g, X, out v));
            g.Sample(true, false);                  // still over the window: armed again
            Assert.True(g.Armed);
        }

        [Fact]
        public void PressAgainWhileReleasingKeepsOwning()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);
            g.PassThrough(0xFD, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);                   // pressed again before CSpect saw the release
            g.PassThrough(0xFF, 1, 2);              // one up frame between the presses
            Assert.True(g.Owning);
            g.PassThrough(0xFD, 1, 2);
            g.Sample(true, false);
            g.PassThrough(0xFF, 1, 2);
            Assert.False(g.Owning);
        }

        [Fact]
        public void RePressAfterCSpectSawTheReleaseIsStillGuarded()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);
            g.PassThrough(0xFD, 1, 2);
            g.Sample(true, false);                  // host release
            g.PassThrough(0xFF, 3, 4);              // emulator Tick ends ownership before the next draw
            Assert.False(g.Owning);
            Assert.True(g.Armed);
            byte v;
            Assert.True(Answer(g, B, out v));
            g.PassThrough(0xFD, 3, 4);              // re-press reaches CSpect first
            Assert.True(Answer(g, B, out v)); Assert.Equal(0xFF, v);
            g.Sample(true, true);
            Assert.True(g.Owning);
            AssertIdle(g, 0xFF, 3, 4);
        }

        [Fact]
        public void ReleasingEndsWhenCSpectKeepsShowingAButton()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);
            g.PassThrough(0xFD, 1, 2);
            g.Sample(false, false);                 // host release, then a press held in CSpect's window
            for (int i = 0; i < MouseGuard.ReleaseFrames; i++) { g.PassThrough(0xFD, 1, 2); g.Sample(false, false); }
            Assert.True(g.Owning);
            g.PassThrough(0xFD, 7, 8);
            Assert.False(g.Owning);
            Assert.False(g.Armed);
            AssertPass(g);
            g.Sample(true, false);                  // pointer back over the window while CSpect shows the button
            Assert.False(g.Armed);
        }

        [Fact]
        public void ReleaseCapRestartsOnEachRelease()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);
            g.Sample(true, false);
            for (int i = 0; i < MouseGuard.ReleaseFrames; i++) g.PassThrough(0xFD, 1, 2);
            g.Sample(true, true);                   // pressed again: not releasing any more
            g.PassThrough(0xFD, 1, 2);
            g.Sample(true, false);
            for (int i = 0; i < MouseGuard.ReleaseFrames; i++) g.PassThrough(0xFD, 1, 2);
            Assert.True(g.Owning);
        }

        [Fact]
        public void ConcurrentSamplesAndTicksKeepAConsistentState()
        {
            var g = new MouseGuard();
            var t = new System.Threading.Thread(() =>
            {
                for (int i = 0; i < 200000; i++) g.PassThrough((byte)((i & 8) != 0 ? 0xFD : 0xFF), (byte)i, (byte)i);
            });
            t.Start();
            for (int i = 0; i < 200000; i++) g.Sample((i & 1) == 0, (i & 4) != 0);
            t.Join();
            g.Sample(false, false);
            g.PassThrough(0xFF, 0, 0);
            Assert.False(g.Owning);
            Assert.False(g.Armed);
        }

        [Fact]
        public void ReleaseAfterDragOutHoldsIdleUntilCSpectShowsUp()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);
            g.PassThrough(0xFD, 1, 2);
            g.Sample(false, true);                  // dragged out
            g.Sample(false, false);                 // released outside
            AssertIdle(g, 0xFF, 1, 2);
            g.PassThrough(0xFF, 9, 9);
            AssertPass(g);
            Assert.False(g.Armed);
        }

        [Fact]
        public void PressSeenByCSpectFirstStillOwned()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.PassThrough(0xFD, 1, 2);              // CSpect's frame saw the press before the draw did
            byte v;
            Assert.True(Answer(g, B, out v)); Assert.Equal(0xFF, v);
            g.Sample(true, true);
            Assert.True(g.Owning);
            AssertIdle(g, 0xFF, 1, 2);
        }

        [Fact]
        public void PressStartingOutsidePassesThroughOverWindow()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(false, true);                  // pressed outside, window sees the button
            g.PassThrough(0xFD, 1, 2);
            g.Sample(true, true);                   // dragged over the window
            Assert.False(g.Owning);
            AssertPass(g);
            g.Sample(true, false);                  // released over the window
            Assert.False(g.Armed);                  // CSpect still showed the button
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            Assert.True(g.Armed);
        }

        [Fact]
        public void PressStartingInAnotherWindowPassesThrough()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFD, 1, 2);              // held in CSpect's window; the debugger sees no button
            g.Sample(true, false);
            Assert.False(g.Armed);
            g.Sample(true, true);
            Assert.False(g.Owning);
            AssertPass(g);
        }

        [Fact]
        public void NoSampleYetFreezesNothing()
        {
            var g = new MouseGuard();
            g.Sample(true, false);
            g.Sample(true, true);
            byte v;
            Assert.True(Answer(g, B, out v)); Assert.Equal(0xFF, v);
            Assert.False(Answer(g, X, out v));
            Assert.False(Answer(g, Y, out v));
            g.Sample(true, false);                  // nothing to wait for without CSpect's values
            Assert.False(g.Owning);
        }

        [Fact]
        public void SamplingReadIsNotAnswered()
        {
            var g = new MouseGuard();
            g.Sample(true, false);
            g.Sample(true, true);
            g.Sampling = true;
            AssertPass(g);
            g.Sampling = false;
            byte v;
            Assert.True(Answer(g, B, out v));
        }

        [Fact]
        public void StaleWindowReleases()
        {
            var g = new MouseGuard();
            g.Sample(true, false);
            g.Sample(true, true);
            for (int i = 0; i < MouseGuard.StaleFrames; i++) g.Frame();
            Assert.True(g.Owning);
            g.Frame();
            Assert.False(g.Owning);
            AssertPass(g);
        }

        [Fact]
        public void MissedReleaseEndsOnCSpectButtonsUp()
        {
            var g = new MouseGuard();
            g.PassThrough(0xFF, 1, 2);
            g.Sample(true, false);
            g.Sample(true, true);
            for (int i = 0; i < MouseGuard.UpFrames; i++) { g.PassThrough(0xFF, 1, 2); g.Sample(false, true); }
            Assert.True(g.Owning);
            g.PassThrough(0xFF, 1, 2);
            Assert.False(g.Owning);
        }

        [Fact]
        public void WindowHostForwardsBoundsToGuard()
        {
            var host = new WindowHost(() => null, Settings.Defaults(), null, ".");
            var g = new MouseGuard();
            host.Guard = g;
            host.SampleGuard(-3.4028235e38f, -3.4028235e38f, 800, 672, false);
            Assert.False(g.Armed);
            host.SampleGuard(799, 671, 800, 672, false);
            Assert.True(g.Armed);
            host.SampleGuard(800, 10, 800, 672, false);
            Assert.False(g.Armed);
            host.SampleGuard(float.NaN, 10, 800, 672, false);
            Assert.False(g.Armed);
        }

        sealed class Surface : ISurface
        {
            public bool IsClosed;
            public int X { get; set; }
            public int Y { get; set; }
            public bool Closed => IsClosed;
            public void Present(uint[] pixels) { }
            public void Close() { IsClosed = true; }
            public void Release() { }
        }

        static MouseGuard Owned(WindowHost host)
        {
            var g = new MouseGuard();
            host.Guard = g;
            host.SampleGuard(10, 10, 800, 672, false);
            host.SampleGuard(10, 10, 800, 672, true);
            Assert.True(g.Owning);
            return g;
        }

        [Fact]
        public void HidingTheWindowReleasesTheGuard()
        {
            var surf = new Surface();
            var host = new WindowHost(() => surf, Settings.Defaults(), null, ".");
            host.Frame(new Snapshot { Serial = 1 }, c => { });
            var g = Owned(host);
            host.Toggle();
            host.Frame(new Snapshot { Serial = 1 }, c => { });
            Assert.True(surf.IsClosed);
            Assert.False(g.Owning);
            AssertPass(g);
        }

        [Fact]
        public void ClosingTheWindowReleasesTheGuard()
        {
            var surf = new Surface();
            var host = new WindowHost(() => surf, Settings.Defaults(), null, ".");
            host.Frame(new Snapshot { Serial = 1 }, c => { });
            var g = Owned(host);
            surf.IsClosed = true;                   // close box
            host.Frame(new Snapshot { Serial = 1 }, c => { });
            Assert.False(g.Owning);
            g = Owned(host);
            host.Close();                           // CSpect quitting
            Assert.False(g.Owning);
        }

        [Fact]
        public void DrawFailureReleasesTheGuard()
        {
            var surf = new Surface();
            var host = new WindowHost(() => surf, Settings.Defaults(), null, ".");
            host.Frame(new Snapshot { Serial = 1 }, c => { });
            var g = Owned(host);
            host.DrawFailed(new System.Exception("x"));
            Assert.Throws<System.InvalidOperationException>(() => host.Frame(new Snapshot { Serial = 1 }, c => { }));
            Assert.False(g.Owning);
        }

        // MousePorts: the plugin's Read routing and per-Tick sampling, with a fake InPort.
        [Fact]
        public void PortsRegisterTheThreeMousePorts()
        {
            var list = new System.Collections.Generic.List<Plugin.sIO>();
            MousePorts.Register(list);
            Assert.Equal(3, list.Count);
            foreach (var io in list) Assert.Equal(Plugin.eAccess.Port_Read, io.Type);
        }

        [Fact]
        public void ReadRoutesOnlyMouseIdPortReads()
        {
            var g = new MouseGuard();
            var mp = new MousePorts(g, p => 0xFF);
            bool valid;
            byte v;
            Assert.False(mp.Read(Plugin.eAccess.Port_Read, 0x7FFE, 3, out valid, out v));      // autopilot keyboard id
            Assert.False(mp.Read(Plugin.eAccess.Memory_EXE, B, MousePorts.Id, out valid, out v));
            Assert.True(mp.Read(Plugin.eAccess.Port_Read, B, MousePorts.Id, out valid, out v));
            Assert.False(valid);                    // idle guard passes through
            g.Sample(true, false);
            Assert.True(mp.Read(Plugin.eAccess.Port_Read, B, MousePorts.Id, out valid, out v));
            Assert.True(valid);
            Assert.Equal(0xFF, v);
        }

        [Fact]
        public void TickSamplesPastTheGuard()
        {
            var g = new MouseGuard();
            MousePorts mp = null;
            int calls = 0;
            mp = new MousePorts(g, p =>
            {
                calls++;
                Assert.True(g.Sampling);
                bool valid;
                byte v;
                Assert.True(mp.Read(Plugin.eAccess.Port_Read, p, MousePorts.Id, out valid, out v));
                Assert.False(valid);                // CSpect's own value, not the guard's
                return p == B ? (byte)0x07 : p == X ? (byte)0x11 : (byte)0x22;
            });
            g.Sample(true, false);
            g.Sample(true, true);                   // owning before any sample: X/Y not frozen yet
            mp.Tick(true);
            Assert.Equal(3, calls);
            Assert.False(g.Sampling);
            g.Release();
            g.Sample(true, false);
            g.Sample(true, true);
            AssertIdle(g, 0x07, 0x11, 0x22);
        }

        [Fact]
        public void DeadHostDropsTheGuard()
        {
            var g = new MouseGuard();
            int calls = 0;
            var mp = new MousePorts(g, p => { calls++; return 0xFF; });
            g.Sample(true, false);
            mp.Tick(false);
            Assert.Null(mp.Guard);
            Assert.False(g.Armed);
            bool valid;
            byte v;
            Assert.True(mp.Read(Plugin.eAccess.Port_Read, B, MousePorts.Id, out valid, out v));
            Assert.False(valid);
            mp.Tick(true);
            Assert.Equal(0, calls);
        }

        [Fact]
        public void FailingInPortDropsTheGuard()
        {
            var g = new MouseGuard();
            var mp = new MousePorts(g, p => { throw new System.InvalidOperationException("no port"); });
            g.Sample(true, false);
            mp.Tick(true);
            Assert.Null(mp.Guard);
            Assert.False(g.Sampling);
            Assert.False(g.Armed);
        }
    }
}
