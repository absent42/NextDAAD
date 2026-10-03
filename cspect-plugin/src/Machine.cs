namespace NextDAADDebug
{
    public struct CpuRegs
    {
        public ushort PC, HL, AF;
        public byte A => (byte)(AF >> 8);
    }

    // Everything the debugger needs from the emulator; CSpectMachine is the real one.
    public interface IMachine
    {
        byte Peek(ushort address);
        byte[] Peek(ushort address, int count);
        byte[] PeekPhysical(int address, int count);
        void Poke(ushort address, byte value);
        byte GetNextRegister(byte register);
        CpuRegs Registers();
    }

    // One procStack record: proc(1) entryPtr(2) condactPtr(2) (src/nextdaad.inc PREC_SIZE).
    public struct ProcFrame
    {
        public readonly int Proc, EntryPtr, CondactPtr;

        public ProcFrame(int proc, int entryPtr, int condactPtr)
        {
            Proc = proc;
            EntryPtr = entryPtr;
            CondactPtr = condactPtr;
        }
    }
}
