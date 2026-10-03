using System;
using System.Collections.Generic;
using System.IO;

namespace NextDAADDebug.Tests
{
    // Reads assembled bytes out of a screenless NEX at a logical address in the load-time mapping.
    static class NexImage
    {
        public static byte[] ReadLogical(string nexPath, int addr, int count)
        {
            byte[] nex = File.ReadAllBytes(nexPath);
            if (nex[10] != 0) throw new InvalidOperationException("screenless NEX expected");
            var order = new List<int> { 5, 2, 0, 1, 3, 4 };
            for (int b = 6; b < 112; b++) order.Add(b);
            var off = new Dictionary<int, int>();
            int pos = 512;
            foreach (int b in order) if (nex[18 + b] != 0) { off[b] = pos; pos += 16384; }
            int bank = addr < 0x8000 ? 5 : addr < 0xC000 ? 2 : 0;
            var r = new byte[count];
            Array.Copy(nex, off[bank] + (addr & 0x3FFF), r, 0, count);
            return r;
        }
    }
}
