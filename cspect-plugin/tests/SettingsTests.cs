using System.IO;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class SettingsTests
    {
        [Fact]
        public void MissingFileGivesDefaults()
        {
            var s = Settings.Load(Path.Combine(Path.GetTempPath(), "nope-" + System.Guid.NewGuid() + ".txt"));
            Assert.Equal(2, s.Breakpoints.Count);
            Assert.Contains(s.Breakpoints, b => b.Kind == BreakKind.DebugMarker && b.Enabled);
            Assert.Contains(s.Breakpoints, b => b.Kind == BreakKind.RuntimeError && b.Enabled);
        }

        [Fact]
        public void OutOfRangeWatchesDropped()
        {
            string path = Path.GetTempFileName();
            File.WriteAllText(path, Settings.Magic + "\t1\nwatch\tflag\t300\nwatch\tobject\t-2\nwatch\tflag\t5\n");
            Assert.Single(Settings.Load(path).Watches);
        }

        [Fact]
        public void InvalidBreakpointsDropped()
        {
            string path = Path.GetTempFileName();
            File.WriteAllText(path, Settings.Magic + "\t1\n"
                + "bp\tFlagChange\t1\t300\t-1\t-1\tEq\n"
                + "bp\t99\t1\t0\t-1\t-1\tEq\n"
                + "bp\tObjectMoved\t1\t-1\t-1\t-1\tEq\n"
                + "bp\tCondact\t1\t128\t-1\t-1\tEq\n"
                + "bp\tProcess\t1\t3\t256\t-1\tEq\n"
                + "bp\tSourceLine\t1\t0\t0\t-1\tEq\n"
                + "bp\tFlagCompare\t1\t5\t300\t-1\tEq\n"
                + "bp\tFlagCompare\t1\t5\t7\t-1\t9\n"
                + "bp\tFlagChange\t1\t40\t-1\t-1\tEq\n"
                + "bp\tProcess\t1\t2\t-1\t-1\tEq\n"
                + "bp\tSourceLine\t1\t0\t12\t-1\tEq\n");
            var s = Settings.Load(path);
            Assert.Equal(3, s.Breakpoints.Count);
            Assert.Equal(BreakKind.FlagChange, s.Breakpoints[0].Kind);
            Assert.Equal(BreakKind.Process, s.Breakpoints[1].Kind);
            Assert.Equal(12, s.Breakpoints[2].B);
        }

        [Fact]
        public void RoundTrip()
        {
            string path = Path.GetTempFileName();
            var s = new Settings { WinX = 120, WinY = 80 };
            s.Watches.Add(new Watch { IsObject = true, Number = 3 });
            s.Watches.Add(new Watch { Number = 100 });
            var bps = new[] {
                new Breakpoint { Kind = BreakKind.FlagCompare, A = 7, Op = CompareOp.Gt, B = 9, Enabled = false },
                new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 77 } };
            s.Save(path, bps);
            var t = Settings.Load(path);
            Assert.Equal(120, t.WinX);
            Assert.Equal(80, t.WinY);
            Assert.Equal(2, t.Watches.Count);
            Assert.True(t.Watches[0].IsObject);
            Assert.Equal(100, t.Watches[1].Number);
            Assert.Equal(2, t.Breakpoints.Count);
            Assert.True(t.Breakpoints[0].SameAs(bps[0]));
            Assert.False(t.Breakpoints[0].Enabled);
            Assert.Equal(77, t.Breakpoints[1].B);
        }

        [Fact]
        public void CorruptFileGivesDefaults()
        {
            string path = Path.GetTempFileName();
            File.WriteAllText(path, "NEXTDAAD-DEBUGGER\t1\nbp\tNoSuchKind\t1\t0\t0\t0\tEq\n");
            Assert.Equal(2, Settings.Load(path).Breakpoints.Count);
        }
    }
}
