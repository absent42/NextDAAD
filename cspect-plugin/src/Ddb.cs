using System;
using System.Collections.Generic;
using System.Text;

namespace NextDAADDebug
{
    public enum WordType { Verb = 0, Adverb = 1, Noun = 2, Adjective = 3, Preposition = 4, Conjunction = 5, Pronoun = 6 }

    public struct VocabEntry { public string Word; public int Number; public WordType Type; }

    public struct Connection { public int Word; public int Destination; }

    public struct EntryInfo { public int HeaderOffset; public int Verb; public int Noun; public int CondactOffset; }

    public sealed class DecodedCondact
    {
        public int Offset;
        public int Length;
        public byte Raw;
        public int Number;
        public bool Indirect;
        public bool IsMarker;
        public bool IsEnd;
        public int[] Args = new int[0];
        public CondactInfo Info => IsMarker || IsEnd ? null : Condacts.Table[Number];
    }

    // Pure decoder over a NextDAAD DDB image; header pointers are file offsets.
    // Out-of-range reads return 0 so a garbage image never throws.
    public sealed class Ddb
    {
        public const int HeaderSize = 34;
        readonly byte[] b;
        List<string> tokens;
        List<VocabEntry> vocab;

        public Ddb(byte[] image) { b = image ?? new byte[0]; }

        public byte[] Image => b;
        public int Byte(int o) => o >= 0 && o < b.Length ? b[o] : 0;
        public int Word(int o) => Byte(o) | (Byte(o + 1) << 8);

        public int Version => Byte(0);
        public int Machine => Byte(1) >> 4;
        public int Language => Byte(1) & 0x0F;
        public int NumObjects => Byte(3);
        public int NumLocations => Byte(4);
        public int NumMessages => Byte(5);
        public int NumSysMessages => Byte(6);
        public int NumProcesses => Byte(7);
        int TokensPtr => Word(8);
        int ProcList => Word(10);
        int ObjList => Word(12);
        int LocList => Word(14);
        int MsgList => Word(16);
        int SysList => Word(18);
        int ConList => Word(20);
        int VocabPtr => Word(22);
        int ObjLocPtr => Word(24);
        int ObjNamePtr => Word(26);
        int ObjAttrPtr => Word(28);
        int ObjExtrPtr => Word(30);

        public static bool LooksLikeNextDaad(byte[] h) =>
            h != null && h.Length >= HeaderSize && (h[0] == 2 || h[0] == 3) && (h[1] >> 4) == 0x0C && h[2] == 95;

        // Token n is the (n+1)th bit-7-terminated string: string 0 is a placeholder (src/overlay0.asm skips n+1).
        public string Token(int n)
        {
            if (tokens == null) tokens = ReadTokens();
            return n >= 0 && n < tokens.Count ? tokens[n] : "?";
        }

        List<string> ReadTokens()
        {
            var list = new List<string>();
            var sb = new StringBuilder();
            int p = TokensPtr, strings = 0;
            while (list.Count < 128 && p >= 0 && p < b.Length && p - TokensPtr < 8192)
            {
                byte c = b[p++];
                sb.Append((char)(c & 0x7F));
                if ((c & 0x80) != 0)
                {
                    if (strings++ > 0) list.Add(sb.ToString());
                    sb.Clear();
                }
            }
            return list;
        }

        // Bytes are XOR $FF; $0A ends; >= 128 is a token; $0D is a newline; other controls show as {XX}.
        public string Text(int ptr)
        {
            var sb = new StringBuilder();
            int p = ptr;
            for (int guard = 0; guard < 2048 && p >= 0 && p < b.Length; guard++)
            {
                int c = b[p++] ^ 0xFF;
                if (c == 0x0A) break;
                if (c >= 128) { sb.Append(Token(c & 0x7F)); continue; }
                if (c == 0x0D) { sb.Append('\n'); continue; }
                if (c < 32) { sb.Append('{').Append(c.ToString("X2")).Append('}'); continue; }
                sb.Append((char)c);
            }
            return sb.ToString();
        }

        string TableText(int table, int count, int n) => n >= 0 && n < count ? Text(Word(table + 2 * n)) : null;
        public string Message(int n) => TableText(MsgList, NumMessages, n);
        public string SysMessage(int n) => TableText(SysList, NumSysMessages, n);
        public string Location(int n) => TableText(LocList, NumLocations, n);
        public string ObjectText(int n) => TableText(ObjList, NumObjects, n);

        // 7-byte entries: 5 chars XOR $FF space padded, number, type; raw 0 ends (src/main.asm voc_find).
        public IReadOnlyList<VocabEntry> Vocabulary
        {
            get
            {
                if (vocab != null) return vocab;
                vocab = new List<VocabEntry>();
                int p = VocabPtr;
                while (p >= 0 && p + 7 <= b.Length && b[p] != 0 && vocab.Count < 4096)
                {
                    var sb = new StringBuilder();
                    for (int i = 0; i < 5; i++) sb.Append((char)((b[p + i] ^ 0xFF) & 0xFF));
                    vocab.Add(new VocabEntry { Word = sb.ToString().TrimEnd(), Number = b[p + 5], Type = (WordType)Math.Min((int)b[p + 6], 6) });
                    p += 7;
                }
                return vocab;
            }
        }

        // 255 is "no word". A verb slot also matches movement nouns below 20 (DAAD convertible nouns).
        public string WordFor(int number, WordType type)
        {
            if (number == 255) return "_";
            foreach (var v in Vocabulary) if (v.Number == number && v.Type == type) return v.Word;
            if (type == WordType.Verb && number < 20)
                foreach (var v in Vocabulary) if (v.Number == number && v.Type == WordType.Noun) return v.Word;
            return null;
        }

        // Pairs (word, destination) ending at $FF (src/overlay0.asm MOVE).
        public List<Connection> Connections(int loc)
        {
            var r = new List<Connection>();
            if (loc < 0 || loc >= NumLocations) return r;
            int p = Word(ConList + 2 * loc);
            while (p >= 0 && p + 1 < b.Length && b[p] != 0xFF && r.Count < 256)
            {
                r.Add(new Connection { Word = b[p], Destination = b[p + 1] });
                p += 2;
            }
            return r;
        }

        bool ObjOk(int o) => o >= 0 && o < NumObjects;
        public int ObjectInitialLocation(int o) => ObjOk(o) ? Byte(ObjLocPtr + o) : 252;
        public int ObjectAttr(int o) => ObjOk(o) ? Byte(ObjAttrPtr + o) : 0;
        public int ObjectExtAttr(int o) => ObjOk(o) ? Word(ObjExtrPtr + 2 * o) : 0;
        public int ObjectNoun(int o) => ObjOk(o) ? Byte(ObjNamePtr + 2 * o) : 255;
        public int ObjectAdjective(int o) => ObjOk(o) ? Byte(ObjNamePtr + 2 * o + 1) : 255;
        public static int Weight(int attr) => attr & 0x3F;
        public static bool IsContainer(int attr) => (attr & 0x40) != 0;
        public static bool IsWearable(int attr) => (attr & 0x80) != 0;

        // Entry headers: verb, noun, condact pointer; verb 0 ends the table (src/engine.asm eng_step).
        public List<EntryInfo> Entries(int proc)
        {
            var r = new List<EntryInfo>();
            if (proc < 0 || proc >= NumProcesses) return r;
            int p = Word(ProcList + 2 * proc);
            while (p >= 0 && p + 3 < b.Length && b[p] != 0 && r.Count < 1024)
            {
                r.Add(new EntryInfo { HeaderOffset = p, Verb = b[p], Noun = b[p + 1], CondactOffset = Word(p + 2) });
                p += 4;
            }
            return r;
        }

        public int EntryCondactStart(int entryHeader) => Word(entryHeader + 2);

        public DecodedCondact DecodeAt(int off)
        {
            byte raw = (byte)Byte(off);
            var d = new DecodedCondact { Offset = off, Raw = raw, Length = 1 };
            if (raw == Condacts.EndOfEntry) { d.IsEnd = true; return d; }
            if (raw == Condacts.DebugMarker) { d.IsMarker = true; return d; }
            d.Number = raw & 0x7F;
            d.Indirect = (raw & 0x80) != 0;
            int n = Condacts.Table[d.Number].Argc;
            var args = new List<int>();
            for (int i = 0; i < n; i++) args.Add(Byte(off + 1 + i));
            // XMESSAGE shape: EXTERN lsb 3 msb consumes a third byte (src/engine.asm eng_exec)
            if (d.Number == Condacts.Extern && n == 2 && args[1] == 3) args.Add(Byte(off + 3));
            d.Args = args.ToArray();
            d.Length = 1 + d.Args.Length;
            return d;
        }

        public List<DecodedCondact> EntryCondacts(int start)
        {
            var list = new List<DecodedCondact>();
            int p = start;
            for (int guard = 0; guard < 256 && p >= 0 && p < b.Length; guard++)
            {
                var d = DecodeAt(p);
                list.Add(d);
                p += d.Length;
                if (d.IsEnd) break;
                if (!d.IsMarker && Condacts.IsTerminatorByte(d.Raw)) break;
            }
            return list;
        }
    }
}
