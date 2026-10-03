using System;
using System.Collections.Generic;
using System.IO;

namespace NextDAADDebug.Tests
{
    sealed class FakeMachine : IMachine
    {
        public readonly byte[] Mem = new byte[65536];
        public readonly byte[] Phys = new byte[0x200000];
        public readonly byte[] NextRegs = new byte[256];
        public CpuRegs Regs;

        public byte Peek(ushort a) => Mem[a];

        public byte[] Peek(ushort a, int n)
        {
            var r = new byte[n];
            for (int i = 0; i < n; i++) r[i] = Mem[(a + i) & 0xFFFF];
            return r;
        }

        public byte[] PeekPhysical(int a, int n)
        {
            var r = new byte[n];
            Array.Copy(Phys, a, r, 0, n);
            return r;
        }

        public void Poke(ushort a, byte v) => Mem[a] = v;
        public byte GetNextRegister(byte r) => NextRegs[r];
        public CpuRegs Registers() => Regs;
    }

    sealed class FakeHalter : IHalter
    {
        public int Halts, Resumes;
        public void Halt() => Halts++;
        public void Resume() => Resumes++;
    }

    // DBGFIX loaded at physical $40000, hook code installed, one-call condact execution.
    sealed class Rig
    {
        public readonly FakeMachine M = new FakeMachine();
        public readonly FakeHalter H = new FakeHalter();
        public readonly SymbolFile Sym = SymbolFile.Parse(ParserTests.Sym());
        public readonly Ddb Ddb;
        public readonly DebugSession S;
        public readonly string TracePath;
        readonly TraceWriter trace;

        public Rig(bool interactive = true, bool withMap = true, bool withTrace = false, params Breakpoint[] bps)
        {
            byte[] img = File.ReadAllBytes(Repo.Fixture("DBGFIX.DDB"));
            Array.Copy(img, 0, M.Phys, 0x40000, img.Length);
            Ddb = new Ddb(img);
            InstallCode();
            SourceMap map = withMap ? SourceMap.Parse(File.ReadAllText(Repo.Fixture("DBGFIX.DSM"))) : null;
            if (withTrace) { TracePath = Path.GetTempFileName(); trace = new TraceWriter(TracePath); }
            S = new DebugSession(M, Sym, H, map, null, trace, interactive, bps);
        }

        public void InstallCode()
        {
            foreach (string name in SymbolFile.RequiredHooks)
            {
                var h = Sym.Hook(name);
                Array.Copy(h.Check, 0, M.Mem, h.Address, h.Check.Length);
                M.NextRegs[0x50 + (h.Address >> 13)] = h.Page;
            }
        }

        public void CloseTrace() => trace.Dispose();

        public void SetStack(params ProcFrame[] frames)
        {
            int st = Sym["procStack"];
            for (int i = 0; i < frames.Length; i++)
            {
                int o = st + i * 5;
                M.Mem[o] = (byte)frames[i].Proc;
                M.Mem[o + 1] = (byte)frames[i].EntryPtr;
                M.Mem[o + 2] = (byte)(frames[i].EntryPtr >> 8);
                M.Mem[o + 3] = (byte)frames[i].CondactPtr;
                M.Mem[o + 4] = (byte)(frames[i].CondactPtr >> 8);
            }
            M.Mem[Sym["procSP"]] = (byte)frames.Length;
        }

        public EntryInfo Entry(int proc, int entry) => Ddb.Entries(proc)[entry];
        public DecodedCondact Cond(int proc, int entry, int index) => Ddb.EntryCondacts(Entry(proc, entry).CondactOffset)[index];

        // eng_exec at condact 'index' of PRO proc entry 'entry'; 'below' are the calling levels.
        public void Exec(int proc, int entry, int index, params ProcFrame[] below)
        {
            var e = Entry(proc, entry);
            var c = Cond(proc, entry, index);
            var frames = new List<ProcFrame>(below) { new ProcFrame(proc, e.HeaderOffset, c.Offset) };
            SetStack(frames.ToArray());
            M.Regs = new CpuRegs { HL = (ushort)c.Offset, PC = Sym.Hook("eng_exec").Address };
            S.OnExecHook();
        }

        public void Error(int code)
        {
            M.Regs = new CpuRegs { AF = (ushort)(code << 8), PC = Sym.Hook("err_raise").Address };
            S.OnErrorHook();
        }

        public void Flag(int n, byte v) => M.Mem[0xA200 + n] = v;
        public void Run(CommandKind k, int a = 0, int b = 0) { S.Post(Command.Of(k, a, b)); S.Pump(); }
        public void Add(Breakpoint bp) { S.Post(Command.For(CommandKind.AddBreakpoint, bp)); S.Pump(); }
        public Snapshot Snap() { S.ForcePublish(); return S.Latest; }
    }
}
