using System.IO;
using System.Linq;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class SessionTests
    {
        // DBGFIX PRO 0 entry 0: LET 100 7 / LET @100 3 / DEBUG / PROCESS 1 / (end)
        //          PRO 0 entry 1: PARSE 0 / SYSMESS 6 / REDO
        //          PRO 0 entry 2: PROCESS 2 / REDO
        //          PRO 1 entry 0: CLS / DESC @38 / DONE
        //          PRO 2 entry 1: GET 0 / DONE (GET LAMP)

        [Fact]
        public void ForeignCodeIsIgnored()
        {
            var r = new Rig();
            r.Run(CommandKind.Break);
            r.M.Mem[0x9E21] ^= 0xFF;                       // different code at the hook address
            r.Exec(0, 0, 0);
            Assert.Equal(0, r.H.Halts);
            Assert.False(r.Snap().Active);
            r.InstallCode();
            r.M.NextRegs[0x54] = 9;                        // right bytes, wrong page in the slot
            r.Exec(0, 0, 0);
            Assert.Equal(0, r.H.Halts);
            Assert.False(r.Snap().Active);
        }

        [Fact]
        public void BreakHaltsAtNextCondact()
        {
            var r = new Rig();
            r.Exec(0, 0, 0);
            Assert.Equal(0, r.H.Halts);
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 1);
            Assert.Equal(1, r.H.Halts);
            var s = r.Snap();
            Assert.True(s.Halted);
            Assert.Equal(r.Cond(0, 0, 1).Offset, s.Offset);
            Assert.Contains("step", s.Status);
        }

        [Fact]
        public void ReleaseHaltResumesOnce()
        {
            var r = new Rig();
            r.Exec(0, 0, 0);
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 1);
            Assert.True(r.S.Halted);
            r.S.ReleaseHalt();
            r.S.ReleaseHalt();
            Assert.False(r.S.Halted);
            Assert.Equal(1, r.H.Resumes);
        }

        [Fact]
        public void RunResumes()
        {
            var r = new Rig();
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 0);
            r.Run(CommandKind.Run);
            Assert.Equal(1, r.H.Resumes);
            Assert.False(r.S.Halted);
            r.Exec(0, 0, 1);
            Assert.Equal(1, r.H.Halts);
        }

        [Fact]
        public void DebugMarkerBreakpoint()
        {
            var r = new Rig(true, true, false, new Breakpoint { Kind = BreakKind.DebugMarker });
            r.Exec(0, 0, 0);
            r.Exec(0, 0, 1);
            Assert.Equal(0, r.H.Halts);
            r.Exec(0, 0, 2);
            Assert.Equal(1, r.H.Halts);
            Assert.Contains("DEBUG marker", r.Snap().Status);
        }

        [Fact]
        public void NoWindowModeNeverHalts()
        {
            var r = new Rig(false, true, false, new Breakpoint { Kind = BreakKind.DebugMarker });
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 2);
            Assert.Equal(0, r.H.Halts);
        }

        [Fact]
        public void StepOutStopsOnReturn()
        {
            var r = new Rig();
            var caller = new ProcFrame(0, r.Entry(0, 0).HeaderOffset, r.Cond(0, 0, 4).Offset);
            r.Run(CommandKind.Break);
            r.Exec(1, 0, 0, caller);                       // halted inside PRO 1, depth 2
            r.Run(CommandKind.StepOut);
            r.Exec(1, 0, 1, caller);
            r.Exec(1, 0, 2, caller);
            Assert.Equal(1, r.H.Halts);
            r.Exec(0, 0, 4);                               // back in PRO 0 at (end), depth 1
            Assert.Equal(2, r.H.Halts);
            Assert.Contains("returned to level 0", r.Snap().Status);
        }

        [Fact]
        public void StepEntryStopsAtEntryStart()
        {
            var r = new Rig();
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 0);
            r.Run(CommandKind.StepEntry);
            r.Exec(0, 0, 1);
            r.Exec(0, 0, 4);
            Assert.Equal(1, r.H.Halts);
            r.Exec(0, 1, 0);                               // PARSE 0 starts entry 1
            Assert.Equal(2, r.H.Halts);
        }

        [Fact]
        public void RunToParseStopsAfterParse()
        {
            var r = new Rig();
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 0);
            r.Run(CommandKind.RunToParse);
            r.Exec(0, 1, 0);                               // PARSE itself does not stop
            Assert.Equal(1, r.H.Halts);
            r.Exec(0, 2, 0);                               // valid PARSE falls to entry 2: PROCESS 2
            Assert.Equal(2, r.H.Halts);
            Assert.Contains("after PARSE", r.Snap().Status);
        }

        [Fact]
        public void FlagChangeCreditsPreviousCondact()
        {
            var r = new Rig(true, true, false, new Breakpoint { Kind = BreakKind.FlagChange, A = 100 });
            r.Exec(0, 0, 0);
            r.Flag(100, 7);
            r.Exec(0, 0, 1);
            Assert.Equal(1, r.H.Halts);
            string st = r.Snap().Status;
            Assert.Contains("flag 100 changed 0 -> 7", st);
            Assert.Contains("(by LET 100 7)", st);
        }

        [Fact]
        public void FlagCompareIsEdgeTriggered()
        {
            var r = new Rig(true, true, false, new Breakpoint { Kind = BreakKind.FlagCompare, A = 7, Op = CompareOp.Eq, B = 3 });
            r.Exec(0, 0, 0);
            r.Flag(7, 3);
            r.Exec(0, 0, 1);
            Assert.Equal(1, r.H.Halts);
            r.Run(CommandKind.Run);
            r.Exec(0, 0, 2);
            Assert.Equal(1, r.H.Halts);                    // still 3: no new halt
        }

        [Fact]
        public void ObjectMovedBreakpoint()
        {
            var r = new Rig(true, true, false, new Breakpoint { Kind = BreakKind.ObjectMoved, A = 0 });
            r.Exec(2, 1, 0);
            r.M.Mem[0xA300] = 254;
            r.Exec(2, 1, 1);
            Assert.Equal(1, r.H.Halts);
            Assert.Contains("object 0 moved 0 -> 254 (by GET 0)", r.Snap().Status);
        }

        [Fact]
        public void ProcessBreakpointWithVerbFilter()
        {
            var r = new Rig(true, true, false, new Breakpoint { Kind = BreakKind.Process, A = 2, B = 20, C = 50 });
            r.Exec(2, 0, 0);                               // _ _ entry: no
            Assert.Equal(0, r.H.Halts);
            r.Exec(2, 1, 0);                               // GET LAMP entry start: yes
            Assert.Equal(1, r.H.Halts);
            r.Run(CommandKind.Run);
            r.Exec(2, 1, 1);                               // same entry, not its start
            Assert.Equal(1, r.H.Halts);
        }

        [Fact]
        public void CondactBreakpoint()
        {
            var r = new Rig(true, true, false, new Breakpoint { Kind = BreakKind.Condact, A = 29 });
            r.Exec(0, 0, 0);
            r.Exec(1, 0, 0);
            Assert.Equal(1, r.H.Halts);
            Assert.Contains("CLS", r.Snap().Status);
        }

        [Fact]
        public void SourceLineBreakpointResolvesOffsets()
        {
            var r = new Rig();
            r.Exec(0, 0, 0);                               // loads DDB and validates the map
            var map = r.Snap().Map;
            Assert.NotNull(map);
            SourceLoc loc;
            Assert.True(map.TryLocate(r.Cond(0, 1, 0).Offset, out loc));
            r.Add(new Breakpoint { Kind = BreakKind.SourceLine, A = loc.File, B = loc.Line });
            Assert.Equal(new[] { r.Cond(0, 1, 0).Offset }, r.Snap().Breakpoints[0].Offsets);
            r.Exec(0, 1, 0);
            Assert.Equal(1, r.H.Halts);
        }

        [Fact]
        public void DdbReloadsWhenHeaderChanges()
        {
            var r = new Rig();
            r.Exec(0, 0, 0);
            r.Add(new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = MapLine(r, 0, 1, 0) });
            var first = r.Snap();
            Assert.NotNull(first.Map);
            Assert.Single(first.Breakpoints[0].Offsets);
            r.M.Phys[0x40000 + 5] ^= 1;                    // different header: another database
            r.Exec(0, 0, 0);
            var second = r.Snap();
            Assert.NotSame(first.Ddb, second.Ddb);
            Assert.Null(second.Map);
            Assert.Contains("out of date", second.MapProblem);
            Assert.Empty(second.Breakpoints[0].Offsets);
        }

        static int MapLine(Rig r, int proc, int entry, int index)
        {
            SourceLoc loc;
            SourceMap.Parse(File.ReadAllText(Repo.Fixture("DBGFIX.DSM"))).TryLocate(r.Cond(proc, entry, index).Offset, out loc);
            return loc.Line;
        }

        [Fact]
        public void EditsOnlyWhileHalted()
        {
            var r = new Rig();
            r.Exec(0, 0, 0);
            r.Run(CommandKind.SetFlag, 100, 42);
            Assert.Equal(0, r.M.Mem[0xA200 + 100]);
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 1);
            r.Run(CommandKind.SetFlag, 100, 42);
            r.Run(CommandKind.SetObjectLocation, 1, 5);
            Assert.Equal(42, r.M.Mem[0xA200 + 100]);
            Assert.Equal(5, r.M.Mem[0xA300 + 6]);
            Assert.Equal(42, r.Snap().Flags[100]);
        }

        [Fact]
        public void RuntimeErrorBreakpoint()
        {
            var r = new Rig(true, true, false, new Breakpoint { Kind = BreakKind.RuntimeError });
            r.Exec(3, 0, 0);
            r.Error(3);
            Assert.Equal(1, r.H.Halts);
            Assert.Contains("runtime error E3", r.Snap().Status);
        }

        [Fact]
        public void TraceWritesEveryCondact()
        {
            var r = new Rig(false, true, true);
            r.Exec(0, 0, 0);
            r.Exec(0, 0, 2);
            r.CloseTrace();
            var lines = File.ReadAllLines(r.TracePath).Select(l => l.Split(new[] { ' ' }, 4)[3]).ToArray();
            Assert.Equal(new[] { "LET 100 7", "DEBUG", "PROCESS 1" }, lines);
        }

        [Fact]
        public void MismatchReported()
        {
            var r = new Rig();
            r.M.Mem[0x9E21] ^= 0xFF;
            r.S.Pump();
            Assert.Equal(DebugSession.MismatchText, r.Snap().Problem);
        }

        [Fact]
        public void BreakpointsAddRemoveToggle()
        {
            var r = new Rig();
            var bp = new Breakpoint { Kind = BreakKind.FlagChange, A = 5 };
            r.Add(bp);
            r.Add(bp);
            Assert.Single(r.Snap().Breakpoints);
            r.S.Post(Command.For(CommandKind.ToggleBreakpoint, bp)); r.S.Pump();
            Assert.False(r.Snap().Breakpoints[0].Enabled);
            r.S.Post(Command.For(CommandKind.RemoveBreakpoint, bp)); r.S.Pump();
            Assert.Empty(r.Snap().Breakpoints);
        }

        [Fact]
        public void ResetForgetsInterpreter()
        {
            var r = new Rig();
            r.Exec(0, 0, 0);
            Assert.True(r.Snap().Active);
            r.S.Reset();
            var s = r.Snap();
            Assert.False(s.Active);
            Assert.Null(s.Ddb);
        }
    }
}
