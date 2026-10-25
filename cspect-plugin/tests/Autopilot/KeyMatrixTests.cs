using System;
using NextDAADDebug.Autopilot;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class KeyMatrixTests
    {
        static readonly int[] Ports = { 0x00FE, 0xFEFE, 0xFDFE, 0xFBFE, 0xF7FE, 0xEFFE, 0xDFFE, 0xBFFE, 0x7FFE };

        static bool Read(KeyFeeder f, int port, out byte v) => f.TryAnswerPort(port, out v);

        [Fact]
        public void Keys_IdlePassesThrough()
        {
            var f = new KeyFeeder();
            foreach (int p in Ports) { byte v; Assert.False(Read(f, p, out v)); }
            f.Frame();
            foreach (int p in Ports) { byte v; Assert.False(Read(f, p, out v)); }
        }

        [Fact]
        public void Keys_HoldsThenGaps()
        {
            var f = new KeyFeeder();
            f.Enqueue("L");
            for (int i = 0; i < 3; i++)
            {
                f.Frame();
                byte v;
                Assert.True(Read(f, 0xBFFE, out v));
                Assert.Equal(0xFD, v);
            }
            for (int i = 0; i < 3; i++)
            {
                f.Frame();
                byte v;
                Assert.False(Read(f, 0xBFFE, out v));
            }
        }

        [Fact]
        public void Keys_HeldKeyOnlyAnswersItsRow()
        {
            var f = new KeyFeeder();
            f.Enqueue("L");
            f.Frame();
            byte v;
            Assert.False(Read(f, 0xFEFE, out v));
            Assert.False(Read(f, 0x7FFE, out v));
        }

        [Fact]
        public void Keys_EnterAndSpaceRows()
        {
            var f = new KeyFeeder();
            f.Enqueue("\n");
            f.Frame();
            byte v;
            Assert.True(Read(f, 0xBFFE, out v));
            Assert.Equal(0xFE, v);

            var g = new KeyFeeder();
            g.Enqueue(" ");
            g.Frame();
            Assert.True(Read(g, 0x7FFE, out v));
            Assert.Equal(0xFE, v);
        }

        [Fact]
        public void Keys_AllRowsPortSeesPress()
        {
            var f = new KeyFeeder();
            f.Enqueue("L");
            f.Frame();
            byte v;
            Assert.True(Read(f, 0x00FE, out v));
            Assert.Equal(0xFD, v);
        }

        [Fact]
        public void Keys_OtherPortsIgnored()
        {
            var f = new KeyFeeder();
            f.Enqueue("L");
            f.Frame();
            byte v;
            Assert.False(Read(f, 0x1234, out v));
            Assert.False(Read(f, 0x00FF, out v));
        }

        [Fact]
        public void Keys_UnmappedCharRejected()
        {
            KeyPress k;
            Assert.False(KeyMatrix.TryMap('~', out k));
            var e = Assert.Throws<ArgumentException>(() => new KeyFeeder().Enqueue("a~"));
            Assert.Contains("~", e.Message);
        }

        [Fact]
        public void Keys_SentAfterOneHeldFrame()
        {
            var f = new KeyFeeder();
            f.Enqueue("L");
            Assert.False(f.Sent);
            f.Frame();
            Assert.False(f.Sent);
            f.Frame();
            Assert.True(f.Sent);
            Assert.True(f.Busy);
            f.Enqueue("ab");
            Assert.False(f.Sent);
        }

        [Fact]
        public void Keys_BusyUntilDrained()
        {
            var f = new KeyFeeder(2, 1);
            Assert.False(f.Busy);
            f.Enqueue("ab");
            Assert.True(f.Busy);
            for (int i = 0; i < 20 && f.Busy; i++) f.Frame();
            Assert.False(f.Busy);
        }

        [Fact]
        public void Keys_SequenceDeliversEachKey()
        {
            var f = new KeyFeeder(1, 1);
            f.Enqueue("l\n");
            byte v;
            f.Frame();
            Assert.True(Read(f, 0xBFFE, out v)); Assert.Equal(0xFD, v);
            f.Frame();
            Assert.False(Read(f, 0xBFFE, out v));
            f.Frame();
            Assert.True(Read(f, 0xBFFE, out v)); Assert.Equal(0xFE, v);
        }

        [Fact]
        public void KeyMatrix_MapsAllRowsLikeTheSpectrum()
        {
            KeyPress k;
            Assert.True(KeyMatrix.TryMap('z', out k)); Assert.Equal(0, k.Row); Assert.Equal(1, k.Bit);
            Assert.True(KeyMatrix.TryMap('A', out k)); Assert.Equal(1, k.Row); Assert.Equal(0, k.Bit);
            Assert.True(KeyMatrix.TryMap('t', out k)); Assert.Equal(2, k.Row); Assert.Equal(4, k.Bit);
            Assert.True(KeyMatrix.TryMap('1', out k)); Assert.Equal(3, k.Row); Assert.Equal(0, k.Bit);
            Assert.True(KeyMatrix.TryMap('0', out k)); Assert.Equal(4, k.Row); Assert.Equal(0, k.Bit);
            Assert.True(KeyMatrix.TryMap('6', out k)); Assert.Equal(4, k.Row); Assert.Equal(4, k.Bit);
            Assert.True(KeyMatrix.TryMap('p', out k)); Assert.Equal(5, k.Row); Assert.Equal(0, k.Bit);
            Assert.True(KeyMatrix.TryMap('b', out k)); Assert.Equal(7, k.Row); Assert.Equal(4, k.Bit);
        }

        [Fact]
        public void Keys_AnswerIsAllocationFree()
        {
            var f = new KeyFeeder();
            f.Enqueue("L");
            f.Frame();
            byte v;
            Assert.True(f.TryAnswerPort(0xBFFE, out v));
            // net48 lacks GC.GetAllocatedBytesForCurrentThread; use the AppDomain monitor.
            AppDomain.MonitoringIsEnabled = true;
            // The counter is process-wide (parallel tests allocate): take the minimum of several runs.
            long grew = long.MaxValue;
            for (int attempt = 0; attempt < 5; attempt++)
            {
                long before = AppDomain.CurrentDomain.MonitoringTotalAllocatedMemorySize;
                int hits = 0;
                for (int i = 0; i < 10000; i++)
                {
                    if (f.TryAnswerPort(0xBFFE, out v)) hits++;
                    f.TryAnswerPort(0xFEFE, out v);
                }
                grew = Math.Min(grew, AppDomain.CurrentDomain.MonitoringTotalAllocatedMemorySize - before);
                Assert.Equal(10000, hits);
            }
            Assert.True(grew < 100000, "allocated " + grew + " bytes");
        }
    }
}
