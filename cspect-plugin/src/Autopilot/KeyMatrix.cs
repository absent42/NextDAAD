using System;
using System.Collections.Generic;

namespace NextDAADDebug.Autopilot
{
    // Row 0-7 is in kb_tick order $FE,$FD,$FB,$F7,$EF,$DF,$BF,$7F; Bit 0-4.
    public struct KeyPress
    {
        public int Row;
        public int Bit;
        public bool Caps;
        public bool Sym;
    }

    public static class KeyMatrix
    {
        // Spectrum half-rows, bit 0 first; '\n' is ENTER, ' ' is SPACE, '^' CAPS, '~' SYM (never typed).
        static readonly string[] Rows =
        {
            "^ZXCV", "ASDFG", "QWERT", "12345", "09876", "POIUY", "\nLKJH", " ~MNB"
        };

        public static bool TryMap(char c, out KeyPress k)
        {
            char u = char.ToUpperInvariant(c);
            k = default(KeyPress);
            if (u == '^' || u == '~') return false;
            for (int r = 0; r < Rows.Length; r++)
            {
                int b = Rows[r].IndexOf(u);
                if (b >= 0) { k.Row = r; k.Bit = b; return true; }
            }
            return false;
        }
    }

    // Answers keyboard port reads for one injected key at a time; Frame() is called once per emulated frame.
    public sealed class KeyFeeder
    {
        readonly int holdFrames, gapFrames;
        readonly Queue<KeyPress> queue = new Queue<KeyPress>();
        KeyPress cur;
        bool held;
        int left, gapLeft;

        public KeyFeeder(int holdFrames = 3, int gapFrames = 3)
        {
            this.holdFrames = Math.Max(1, holdFrames);
            this.gapFrames = Math.Max(1, gapFrames);
        }

        public bool Busy => held || gapLeft > 0 || queue.Count > 0;

        // The last key has been held for at least one Frame() (a running frame); the rest of the hold and gap may remain.
        public bool Sent => queue.Count == 0 && (!held || left < holdFrames);

        public void Enqueue(string text)
        {
            var keys = new List<KeyPress>();
            foreach (char c in text)
            {
                KeyPress k;
                if (!KeyMatrix.TryMap(c, out k))
                    throw new ArgumentException("character cannot be typed: '" + c + "'");
                keys.Add(k);
            }
            foreach (KeyPress k in keys) queue.Enqueue(k);
        }

        public void Frame()
        {
            if (held)
            {
                if (--left == 0) { held = false; gapLeft = gapFrames - 1; }
                return;
            }
            if (gapLeft > 0) { gapLeft--; return; }
            if (queue.Count > 0) { cur = queue.Dequeue(); held = true; left = holdFrames; }
        }

        // Allocation-free and log-free: the game polls the keyboard hundreds of times per frame.
        public bool TryAnswerPort(int port, out byte value)
        {
            value = 0xFF;
            if (!held || (port & 0xFF) != 0xFE) return false;
            int sel = (port >> 8) & 0xFF;
            bool hit = false;
            if ((sel & (1 << cur.Row)) == 0) { value &= (byte)~(1 << cur.Bit); hit = true; }
            if (cur.Caps && (sel & 1) == 0) { value &= 0xFE; hit = true; }
            if (cur.Sym && (sel & 0x80) == 0) { value &= 0xFD; hit = true; }
            return hit;
        }
    }
}
