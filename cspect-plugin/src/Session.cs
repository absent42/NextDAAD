using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace NextDAADDebug
{
    public enum CommandKind { Run, Break, Step, StepEntry, StepOut, RunToParse, SetFlag, SetObjectLocation, AddBreakpoint, RemoveBreakpoint, ToggleBreakpoint }

    public sealed class Command
    {
        public CommandKind Kind;
        public int A, B;
        public Breakpoint Bp;
        public static Command Of(CommandKind k, int a = 0, int b = 0) => new Command { Kind = k, A = a, B = b };
        public static Command For(CommandKind k, Breakpoint bp) => new Command { Kind = k, Bp = bp };
    }

    // Immutable once published: the UI thread only ever reads it.
    public sealed class Snapshot
    {
        public long Serial;
        public bool Active, Halted;
        public string Status = "waiting for NextDAAD", Problem, MapProblem;
        public ProcFrame[] Stack = new ProcFrame[0];
        public int Offset = -1, IndirPending = -1, NumObjects;
        public byte[] Flags = new byte[256], ChangedBase;
        public byte[] ObjTable = new byte[256 * EngineReader.ObjSize], ChangedBaseObj;
        public Ddb Ddb;
        public SourceMap Map;
        public Breakpoint[] Breakpoints = new Breakpoint[0];
    }

    public interface IHalter
    {
        void Halt();
        void Resume();
    }

    public sealed class NullHalter : IHalter
    {
        public void Halt() { }
        public void Resume() { }
    }

    // Emulator-thread state: hooks call OnExecHook/OnErrorHook, Tick calls Pump.
    public sealed class DebugSession
    {
        public const string MismatchText = "symbol file does not match this interpreter build";
        readonly IMachine m;
        readonly EngineReader reader;
        readonly IHalter halter;
        readonly HookInfo execHook, errorHook;
        readonly SourceMap map;
        readonly string mapProblem;
        readonly TraceWriter trace;
        readonly bool interactive;
        readonly ConcurrentQueue<Command> commands = new ConcurrentQueue<Command>();
        public readonly BreakController Controller = new BreakController();
        public bool SkipRefire = PlatformFacts.RefireOnResume;
        public string Problem;

        Ddb ddb;
        byte[] ddbHeader;
        bool mapUsable, guardPassed, halted, refireArmed;
        string mapState, status = "waiting for NextDAAD";
        int ranPast, haltOffset = -1, haltNumObj, haltIndir = -1;
        ExecEvent last;
        byte[] haltFlags, haltObj, baseFlags, baseObj;
        long serial;
        Snapshot latest = new Snapshot();
        DateTime lastPublish = DateTime.MinValue, lastMismatchCheck = DateTime.MinValue;

        public DebugSession(IMachine machine, SymbolFile symbols, IHalter halter, SourceMap map, string mapProblem, TraceWriter trace, bool interactive, IEnumerable<Breakpoint> breakpoints)
        {
            m = machine;
            reader = new EngineReader(machine, symbols);
            this.halter = halter;
            execHook = symbols.Hook("eng_exec");
            errorHook = symbols.Hook("err_raise");
            this.map = map;
            this.mapProblem = mapProblem;
            this.trace = trace;
            this.interactive = interactive;
            Controller.BreakpointsActive = interactive;
            if (breakpoints != null) foreach (var b in breakpoints) Controller.Breakpoints.Add(b.Clone());
            mapState = map == null ? (mapProblem ?? "no source map") : null;
            Publish(true);
        }

        public Snapshot Latest => Volatile.Read(ref latest);
        public bool Halted => halted;
        public void Post(Command c) => commands.Enqueue(c);

        public void OnExecHook()
        {
            if (!reader.GuardOk(execHook)) return;
            if (halted) { ranPast++; return; }
            guardPassed = true;
            if (Problem == MismatchText) Problem = null;
            EnsureDdb();
            int off = m.Registers().HL;
            if (refireArmed)
            {
                refireArmed = false;
                if (SkipRefire && off == haltOffset) return;
            }
            var e = new ExecEvent { Offset = off, Stack = reader.Stack(), Flags = reader.Flags(), ObjTable = reader.ObjectTable() };
            e.Condact = ddb.DecodeAt(off);
            var eff = e.Condact;
            for (int i = 0; i < 16 && eff.IsMarker; i++) eff = ddb.DecodeAt(eff.Offset + 1);
            e.Effective = eff;
            if (trace != null) trace.Write(e.Top, e.Condact, ddb);
            last = e;
            string reason = Controller.OnExec(e);
            if (reason != null && interactive) HaltNow(reason);
        }

        public void OnErrorHook()
        {
            if (halted || !reader.GuardOk(errorHook)) return;
            string reason = Controller.OnError(m.Registers().A);
            if (reason != null && interactive) HaltNow(reason);
        }

        void HaltNow(string reason)
        {
            halted = true;
            ranPast = 0;
            haltOffset = last != null ? last.Offset : -1;
            status = "HALTED - " + reason;
            baseFlags = haltFlags;
            baseObj = haltObj;
            haltFlags = last != null ? (byte[])last.Flags.Clone() : null;
            haltObj = last != null ? (byte[])last.ObjTable.Clone() : null;
            haltNumObj = reader.NumObjects();
            haltIndir = reader.IndirPending();
            Publish(true);
            halter.Halt();
        }

        public void Pump()
        {
            Command c;
            while (commands.TryDequeue(out c)) Apply(c);
            if (!guardPassed && DateTime.UtcNow - lastMismatchCheck > TimeSpan.FromSeconds(1))
            {
                lastMismatchCheck = DateTime.UtcNow;
                if (Ddb.LooksLikeNextDaad(reader.DdbHeader()) && !reader.GuardOk(execHook)) Problem = MismatchText;
            }
            Publish(false);
        }

        void Apply(Command c)
        {
            switch (c.Kind)
            {
                case CommandKind.Run: Resume(RunMode.Run); break;
                case CommandKind.Step: Resume(RunMode.Step); break;
                case CommandKind.StepEntry: Resume(RunMode.StepEntry); break;
                case CommandKind.StepOut: Resume(RunMode.StepOut); break;
                case CommandKind.RunToParse: Resume(RunMode.RunToParse); break;
                case CommandKind.Break:
                    if (!halted && interactive) Controller.SetMode(RunMode.Step, 0);
                    break;
                case CommandKind.SetFlag:
                    if (halted) { reader.WriteFlag(c.A, (byte)c.B); Refresh(); }
                    break;
                case CommandKind.SetObjectLocation:
                    if (halted) { reader.WriteObjectLocation(c.A, (byte)c.B); Refresh(); }
                    break;
                case CommandKind.AddBreakpoint:
                    if (c.Bp != null && !Controller.Breakpoints.Exists(b => b.SameAs(c.Bp)))
                    {
                        var b = c.Bp.Clone();
                        Resolve(b);
                        Controller.Breakpoints.Add(b);
                    }
                    break;
                case CommandKind.RemoveBreakpoint:
                    if (c.Bp != null) Controller.Breakpoints.RemoveAll(b => b.SameAs(c.Bp));
                    break;
                case CommandKind.ToggleBreakpoint:
                    if (c.Bp != null) foreach (var b in Controller.Breakpoints) if (b.SameAs(c.Bp)) b.Enabled = !b.Enabled;
                    break;
            }
            Publish(true);
        }

        void Resume(RunMode mode)
        {
            if (!halted) return;
            Controller.SetMode(mode, last != null ? last.Stack.Length : 0);
            halted = false;
            refireArmed = true;
            status = "running";
            halter.Resume();
        }

        // An edit is not a change for FlagChange/ObjectMoved: the previous event sees it too.
        void Refresh()
        {
            if (last == null) return;
            last.Flags = reader.Flags();
            last.ObjTable = reader.ObjectTable();
        }

        void EnsureDdb()
        {
            byte[] h = reader.DdbHeader();
            if (ddbHeader != null && Same(h, ddbHeader)) return;
            ddbHeader = h;
            ddb = new Ddb(reader.DdbImage());
            Controller.SetDdb(ddb);
            mapUsable = map != null && map.Matches(ddb.Image);
            mapState = map == null ? (mapProblem ?? "no source map") : mapUsable ? null : "source map is out of date - rebuild";
            foreach (var b in Controller.Breakpoints) Resolve(b);
        }

        void Resolve(Breakpoint b)
        {
            if (b.Kind == BreakKind.SourceLine) b.Offsets = mapUsable ? map.OffsetsForLine(b.A, b.B).ToArray() : new int[0];
        }

        static bool Same(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }

        public void ForcePublish() => Publish(true);

        void Publish(bool force)
        {
            if (!force && DateTime.UtcNow - lastPublish < TimeSpan.FromMilliseconds(100)) return;
            lastPublish = DateTime.UtcNow;
            var s = new Snapshot
            {
                Serial = ++serial,
                Active = guardPassed,
                Halted = halted,
                Problem = Problem,
                Status = halted && ranPast > 0 ? status + " (" + ranPast + " condacts ran past)" : status,
                Ddb = ddb,
                Map = mapUsable ? map : null,
                MapProblem = mapState,
                Breakpoints = Controller.Breakpoints.Select(b => b.Clone()).ToArray(),
                ChangedBase = baseFlags,
                ChangedBaseObj = baseObj,
            };
            if (guardPassed)
            {
                if (halted && last != null)
                {
                    s.Offset = last.Offset;
                    s.Stack = last.Stack;
                    s.Flags = last.Flags;
                    s.ObjTable = last.ObjTable;
                    s.NumObjects = haltNumObj;
                    s.IndirPending = haltIndir;
                }
                else
                {
                    s.Stack = reader.Stack();
                    s.Flags = reader.Flags();
                    s.ObjTable = reader.ObjectTable();
                    s.Offset = last != null ? last.Offset : -1;
                    s.NumObjects = reader.NumObjects();
                    s.IndirPending = reader.IndirPending();
                }
            }
            Volatile.Write(ref latest, s);
        }

        public void Reset()
        {
            guardPassed = halted = false;
            ddbHeader = null;
            ddb = null;
            last = null;
            ranPast = 0;
            baseFlags = baseObj = haltFlags = haltObj = null;
            Controller.SetMode(RunMode.Run, 0);
            Controller.SetDdb(null);
            mapUsable = false;
            status = "waiting for NextDAAD";
            Publish(true);
        }
    }
}
