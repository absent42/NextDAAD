using System;

namespace NextDAADDebug
{
    // Interpreter state through IMachine. Sizes from src/nextdaad.inc (PROC_DEPTH, PREC_SIZE, OBJ_SIZE).
    public sealed class EngineReader
    {
        public const int DdbPhysical = 0x40000, DdbMax = 0x10000, ProcDepth = 10, PrecSize = 5, ObjSize = 6;
        readonly IMachine m;
        readonly SymbolFile s;

        public EngineReader(IMachine machine, SymbolFile symbols)
        {
            m = machine;
            s = symbols;
        }

        // The hook's 8K page must be in its MMU slot and the code bytes must match the build.
        public bool GuardOk(HookInfo h)
        {
            if (m.GetNextRegister((byte)(0x50 + (h.Address >> 13))) != h.Page) return false;
            byte[] live = m.Peek(h.Address, h.Check.Length);
            for (int i = 0; i < live.Length; i++) if (live[i] != h.Check[i]) return false;
            return true;
        }

        public byte[] Flags() => m.Peek(s["flags"], 256);
        public byte[] ObjectTable() => m.Peek(s["objTable"], 256 * ObjSize);
        public int NumObjects() => m.Peek(s["numObj"]);

        public ProcFrame[] Stack()
        {
            int sp = Math.Min((int)m.Peek(s["procSP"]), ProcDepth);
            byte[] raw = m.Peek(s["procStack"], ProcDepth * PrecSize);
            var r = new ProcFrame[sp];
            for (int i = 0; i < sp; i++)
            {
                int o = i * PrecSize;
                r[i] = new ProcFrame(raw[o], raw[o + 1] | raw[o + 2] << 8, raw[o + 3] | raw[o + 4] << 8);
            }
            return r;
        }

        // Pending V3 INDIR second-argument override, or -1.
        public int IndirPending() => m.Peek(s["indirValid"]) != 0 ? m.Peek(s["indirArg2"]) : -1;

        public byte[] DdbHeader() => m.PeekPhysical(DdbPhysical, Ddb.HeaderSize);
        public byte[] DdbImage() => m.PeekPhysical(DdbPhysical, DdbMax);
        public void WriteFlag(int n, byte v) => m.Poke((ushort)(s["flags"] + n), v);
        public void WriteObjectLocation(int o, byte loc) => m.Poke((ushort)(s["objTable"] + ObjSize * o), loc);
    }
}
