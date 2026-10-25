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
            g.Sample(false, false);                 // release
            Assert.False(g.Owning);
            g.PassThrough(0x37, 120, 210);
            AssertPass(g);
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
    }
}
