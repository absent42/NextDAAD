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
