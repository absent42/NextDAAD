using System;
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
        //          PRO 1 entry 0: CLS / ABILITY 10 50 / DESC @38 / DONE
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
        public void SharedLineBreakpointFiresOnlyForItsEntry()
        {
            const string dsm = "NDRC-DSM\t2\nddb\tF27FE0F4\t459\nfile\t0\tDBGFIX.DSF\n" +
                               "entry\t0425\t0\t101\nentry\t0429\t0\t120\n" +
                               "cond\t03F8\t0425\t0\t101\t9\ncond\t03F8\t0429\t0\t120\t9\n";
            var r = new Rig(SourceMap.Parse(dsm));
            r.Exec(0, 0, 0);                               // loads the DDB and validates the map
            r.Add(new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 120 });
            var bp = r.Snap().Breakpoints[0];
            Assert.Equal(new[] { 0x3F8 }, bp.Offsets);
            Assert.Equal(new[] { 0x429 }, bp.Entries);
            r.Exec(0, 0, 0);                               // first owner (0x0425) runs the shared condact
            Assert.Equal(0, r.H.Halts);
            r.SetStack(new ProcFrame(0, 0x429, 0x3F8));    // second owner runs it
            r.M.Regs = new CpuRegs { HL = 0x3F8, PC = r.Sym.Hook("eng_exec").Address };
            r.S.OnExecHook();
            Assert.Equal(1, r.H.Halts);
        }

        // INDIR prefix at 0x100 (2 bytes), target at 0x102, both mapped to one line of entry 0x50.
        static ExecEvent IndirEvent(int offset, int number, int length, int entry = 0x50) => new ExecEvent
        {
            Offset = offset,
            Stack = new[] { new ProcFrame(0, entry, offset) },
            Condact = new DecodedCondact { Offset = offset, Number = number, Length = length },
        };

        static BreakController IndirController()
        {
            var map = SourceMap.Parse("NDRC-DSM\t2\nddb\tCBF43926\t9\nfile\t0\tG.DSF\ncond\t0100\t0050\t0\t10\t9\ncond\t0102\t0050\t0\t10\t9\n");
            var hits = map.OffsetsForLine(0, 10);
            var c = new BreakController();
            c.Breakpoints.Add(new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 10, Offsets = hits.Select(h => h.Offset).ToArray(), Entries = hits.Select(h => h.Entry).ToArray() });
            return c;
        }

        [Fact]
        public void IndirLineBreakpointHaltsOnce()
        {
            var c = IndirController();
            Assert.Contains("source line 10", c.OnExec(IndirEvent(0x100, Condacts.Indir, 2)));
            Assert.Null(c.OnExec(IndirEvent(0x102, 29, 1)));                       // the target, same line
            Assert.Contains("source line 10", c.OnExec(IndirEvent(0x100, Condacts.Indir, 2)));   // next pass halts again
        }

        [Fact]
        public void LineBreakpointStillHaltsAtTargetWithoutIndirPrefix()
        {
            var c = IndirController();
            Assert.Null(c.OnExec(IndirEvent(0x80, 29, 2)));
            Assert.Contains("source line 10", c.OnExec(IndirEvent(0x102, 29, 1)));
            c = new BreakController();                                            // v1 map: any entry matches
            c.Breakpoints.Add(new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 10, Offsets = new[] { 0x100, 0x102 }, Entries = new[] { -1, -1 } });
            Assert.NotNull(c.OnExec(IndirEvent(0x100, Condacts.Indir, 2)));
            Assert.NotNull(c.OnExec(IndirEvent(0x102, 29, 1, 0x60)));             // different entry: not the same line pass
        }

        [Fact]
        public void SteppingStopsOnBothIndirExecutions()
        {
            var c = IndirController();
            c.SetMode(RunMode.Step, 0);
            Assert.Equal("step", c.OnExec(IndirEvent(0x100, Condacts.Indir, 2)));
            c.SetMode(RunMode.Step, 0);
            Assert.Equal("step", c.OnExec(IndirEvent(0x102, 29, 1)));
        }

        [Fact]
        public void LoadedMapIsUncheckedUntilTheDatabaseIsRead()
        {
            var r = new Rig();
            var s = r.Snap();
            Assert.Null(s.Ddb);
            Assert.Null(s.Map);
            Assert.Equal("source map not checked yet - waiting for NextDAAD", s.MapProblem);
            r.Exec(0, 0, 0);
            Assert.NotNull(r.Snap().Map);
            Assert.Null(r.Snap().MapProblem);
            r.S.Reset();
            Assert.Equal(DebugSession.MapUncheckedText, r.Snap().MapProblem);
            Assert.Equal("no source map", new Rig(true, false).Snap().MapProblem);
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

        // Part 1 is the fixture image; part 2 is the same image with header byte 5 changed.
        static SourceMap[] PartMaps()
        {
            byte[] p1 = File.ReadAllBytes(Repo.Fixture("DBGFIX.DDB"));
            byte[] p2 = (byte[])p1.Clone();
            p2[5] ^= 1;
            Func<byte[], string, string> dsm = (img, file) => "NDRC-DSM\t2\nddb\t" + Crc32.Compute(img, 0, 0x459).ToString("X8") + "\t459\nfile\t0\t" + file + "\n" +
                "entry\t0425\t0\t101\ncond\t03F8\t0425\t0\t101\t9\n";
            return new[] { SourceMap.Parse(dsm(p1, "DBGFIX.DSF")), SourceMap.Parse(dsm(p2, "PART2/PART2.DSF")) };
        }

        [Fact]
        public void ActiveMapFollowsLoadedPart()
        {
            var maps = PartMaps();
            var r = new Rig(maps);
            r.Exec(0, 0, 0);
            Assert.Same(maps[0], r.Snap().Map);
            Assert.Equal("DBGFIX.DSF", r.Snap().Map.Files[0]);
            r.M.Phys[0x40000 + 5] ^= 1;                    // part 2 header
            r.Exec(0, 0, 0);
            Assert.Same(maps[1], r.Snap().Map);
            Assert.Equal("PART2/PART2.DSF", r.Snap().Map.Files[0]);
            Assert.Null(r.Snap().MapProblem);
            r.M.Phys[0x40000 + 5] ^= 3;                    // a part with no map
            r.Exec(0, 0, 0);
            Assert.Null(r.Snap().Map);
            Assert.Equal("source map is out of date - rebuild", r.Snap().MapProblem);
        }

        [Fact]
        public void PartOneLineBreakpointIgnoredInPartTwo()
        {
            var r = new Rig(PartMaps());
            r.Exec(0, 0, 0);
            r.Add(new Breakpoint { Kind = BreakKind.SourceLine, Path = "dbgfix.dsf", B = 101 });
            Assert.Equal(new[] { 0x3F8 }, r.Snap().Breakpoints[0].Offsets);
            r.M.Phys[0x40000 + 5] ^= 1;                    // part 2 also maps file 0 line 101 at 0x3F8
            r.Exec(0, 0, 0);
            Assert.Empty(r.Snap().Breakpoints[0].Offsets);
            Assert.Equal(0, r.H.Halts);
        }

        [Fact]
        public void LegacyIndexBreakpointTakesThePathOfTheFirstMap()
        {
            var r = new Rig(PartMaps(), true, false, new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 101 });
            Assert.Equal("line 101 of file 0", r.Snap().Breakpoints[0].Describe(r.Ddb, null));
            r.Exec(0, 0, 0);
            var bp = r.Snap().Breakpoints[0];
            Assert.Equal(new[] { 0x3F8 }, bp.Offsets);
            Assert.Equal("DBGFIX.DSF", bp.Path);
            Assert.Equal("line 101 of DBGFIX.DSF", bp.Describe(r.Ddb, null));
            Assert.Equal(1, r.H.Halts);                    // line 101 is this condact
            r.Run(CommandKind.Run);
            r.M.Phys[0x40000 + 5] ^= 1;                    // part 2 maps its own file 0 line 101 at 0x3F8
            r.Exec(0, 0, 0);
            Assert.Empty(r.Snap().Breakpoints[0].Offsets);
            Assert.Equal(1, r.H.Halts);
        }

        [Fact]
        public void ConvertedLegacyRowMergesWithItsPathRow()
        {
            var r = new Rig(PartMaps(), true, false,
                new Breakpoint { Kind = BreakKind.SourceLine, Path = "DBGFIX.DSF", B = 101 },
                new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 101 });
            r.Exec(0, 0, 0);
            Assert.Single(r.Snap().Breakpoints);
        }

        [Theory]
        [InlineData(false, true, true)]
        [InlineData(true, false, true)]
        [InlineData(false, false, false)]
        public void MergedLegacyRowIsEnabledIfEitherRowWas(bool pathOn, bool legacyOn, bool merged)
        {
            var r = new Rig(PartMaps(), true, false,
                new Breakpoint { Kind = BreakKind.SourceLine, Path = "DBGFIX.DSF", B = 101, Enabled = pathOn },
                new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 101, Enabled = legacyOn });
            r.Exec(0, 0, 0);
            var bp = Assert.Single(r.Snap().Breakpoints);
            Assert.Equal("DBGFIX.DSF", bp.Path);
            Assert.Equal(merged, bp.Enabled);
        }

        [Fact]
        public void LegacyIndexOutsideTheMapStaysUnresolved()
        {
            var r = new Rig(PartMaps(), true, false, new Breakpoint { Kind = BreakKind.SourceLine, A = 4, B = 101 });
            r.Exec(0, 0, 0);
            var bp = r.Snap().Breakpoints[0];
            Assert.Null(bp.Path);
            Assert.Empty(bp.Offsets);
        }

        [Fact]
        public void StatusReadsRunningOnceTheInterpreterRuns()
        {
            var r = new Rig();
            Assert.Equal(DebugSession.WaitingText, r.Snap().Status);
            r.M.Mem[0x9E21] ^= 0xFF;                       // a loader intro: not NextDAAD's code at the hook
            r.Exec(0, 0, 0);
            Assert.Equal(DebugSession.WaitingText, r.Snap().Status);
            r.InstallCode();
            r.Exec(0, 0, 0);
            Assert.Equal("running", r.Snap().Status);
            Assert.Equal(0, r.H.Halts);
            r.S.Reset();
            Assert.Equal(DebugSession.WaitingText, r.Snap().Status);
            r.Exec(0, 0, 0);
            Assert.Equal("running", r.Snap().Status);
        }

        [Fact]
        public void FirstCondactHaltKeepsTheHaltText()
        {
            var r = new Rig();
            r.Run(CommandKind.Break);
            r.Exec(0, 0, 0);
            Assert.Equal("HALTED - step", r.Snap().Status);
        }

        [Fact]
        public void LineBreakpointAddedWhileHaltedAtIndirSkipsItsTarget()
        {
            var c = IndirController();
            var bp = c.Breakpoints[0];
            c.Breakpoints.Clear();
            c.SetMode(RunMode.Step, 0);
            Assert.Equal("step", c.OnExec(IndirEvent(0x100, Condacts.Indir, 2)));   // halted at the prefix
            c.Breakpoints.Add(bp);                                                  // line 10 added there
            Assert.Null(c.OnExec(IndirEvent(0x102, 29, 1)));                        // its target: same pass
            bp.Enabled = false;
            c.SetMode(RunMode.Step, 0);
            Assert.Equal("step", c.OnExec(IndirEvent(0x100, Condacts.Indir, 2)));
            bp.Enabled = true;                                                      // enabled while there
            Assert.Null(c.OnExec(IndirEvent(0x102, 29, 1)));
        }

        static string WriteMaps(params string[] namesAndTexts)
        {
            string dir = Path.Combine(Path.GetTempPath(), "dsm-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            for (int i = 0; i < namesAndTexts.Length; i += 2) File.WriteAllText(Path.Combine(dir, namesAndTexts[i]), namesAndTexts[i + 1]);
            return dir;
        }

        [Fact]
        public void MapSetLoadsPartsAndReportsProblems()
        {
            string good = File.ReadAllText(Repo.Fixture("DBGFIX.DSM"));
            var s = MapSet.Load(WriteMaps("GAME.DSM", good, "GAME2.DSM", "NDRC-DSM\t2\nfile\t0\tX.DSF\n", "GAME4.DSM", good));
            Assert.Equal(2, s.Maps.Count);
            Assert.Equal(new[] { "GAME2.DSM: missing ddb record" }, s.Problems.ToArray());
            Assert.Equal(new[] { "GAME3.DSM" }, s.Missing.ToArray());
            Assert.Equal(", source maps loaded (2)", s.LogText);
            Assert.Equal("GAME2.DSM: missing ddb record", s.NoMatchText);
            var one = MapSet.Load(WriteMaps("GAME.DSM", good));
            Assert.Equal(", source map loaded", one.LogText);
            Assert.Equal(MapSet.OutOfDateText, one.NoMatchText);
            Assert.Empty(one.Missing);
            var none = MapSet.Load(WriteMaps());
            Assert.Equal(", no source map", none.LogText);
            Assert.Equal("no source map", none.NothingLoadedText);
            var bad = MapSet.Load(WriteMaps("GAME.DSM", "junk"));
            Assert.Empty(bad.Maps);
            Assert.StartsWith("GAME.DSM: ", bad.NothingLoadedText);
        }

        [Fact]
        public void MissingPartOneMapIsNamedWhenItsDatabasePlays()
        {
            string good = File.ReadAllText(Repo.Fixture("DBGFIX.DSM"));
            string other = good.Replace("ddb\tF27FE0F4", "ddb\t00000000");
            var r = new Rig(MapSet.Load(WriteMaps("GAME2.DSM", other)));
            r.Exec(0, 0, 0);
            Assert.Null(r.Snap().Map);
            Assert.Equal("source map is missing (GAME.DSM) - rebuild", r.Snap().MapProblem);
        }

        [Fact]
        public void LineBreakpointIdentityIgnoresSlashAndCase()
        {
            var map = PartMaps()[1];
            var byPath = new Breakpoint { Kind = BreakKind.SourceLine, Path = "part2\\part2.dsf", B = 7 };
            Assert.True(byPath.SameAs(new Breakpoint { Kind = BreakKind.SourceLine, Path = "PART2/PART2.DSF", B = 7 }));
            Assert.False(byPath.SameAs(new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 7 }));
            Assert.True(byPath.IsLine(map, "PART2/PART2.DSF", 7));
            Assert.True(new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 7 }.IsLine(map, "PART2/PART2.DSF", 7));
            Assert.False(new Breakpoint { Kind = BreakKind.SourceLine, A = 0, B = 7 }.IsLine(null, "PART2/PART2.DSF", 7));
        }

        [Fact]
        public void PathCaseCountsWhereTheFileSystemCountsIt()
        {
            Assert.True(SourceMap.SamePath("inc\\a.dsf", "INC/A.DSF", true));
            Assert.False(SourceMap.SamePath("inc/a.dsf", "inc/A.DSF", false));
            Assert.True(SourceMap.SamePath("inc\\A.DSF", "inc/A.DSF", false));
            var map = SourceMap.Parse("NDRC-DSM\t2\nddb\t00000000\t1\nfile\t0\tinc/a.dsf\nfile\t1\tinc/A.DSF\n");
            Assert.Equal(1, map.FileIndex("inc/A.DSF", false));
            Assert.Equal(0, map.FileIndex("inc/A.DSF", true));
            Assert.Equal(Path.DirectorySeparatorChar == '\\', SourceMap.SamePath("a.dsf", "A.DSF"));
        }

        [Fact]
        public void NoMapsReportsNoSourceMap()
        {
            Assert.Equal("no source map", new Rig(new SourceMap[0]).Snap().MapProblem);
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
